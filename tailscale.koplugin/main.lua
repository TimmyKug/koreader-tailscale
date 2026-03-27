--[[
    Tailscale KOReader Plugin
    Connects a KOReader device to a Tailscale VPN network.

    Ported from kual-tailscale (KUAL extension) by Mitanshu.
    Completely self-contained: binaries and state live entirely under
    this plugin's own bin/ directory; no KUAL or other extension required.
--]]

local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local UIManager     = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger        = require("logger")
local lfs           = require("libs/libkoreader-lfs")
local _             = require("gettext")

local SOCKET_PATH = "/var/run/tailscale/tailscaled.sock"

local Tailscale = WidgetContainer:extend{
    name        = "tailscale",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Tailscale:init()
    self.bin_dir          = self.path .. "/bin"
    self.tailscale_bin    = self.bin_dir .. "/tailscale"
    self.tailscaled_bin   = self.bin_dir .. "/tailscaled"
    self.auth_key_file    = self.bin_dir .. "/auth.key"
    self.proxy_addr_file  = self.bin_dir .. "/proxy.address"

    self.ui.menu:registerToMainMenu(self)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Read the first non-empty line of a file, trimmed of whitespace.
function Tailscale:readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if line then
        line = line:match("^%s*(.-)%s*$")
        return line ~= "" and line or nil
    end
end

function Tailscale:writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

-- Run a shell command; return true on exit code 0.
function Tailscale:exec(cmd)
    logger.dbg("Tailscale exec:", cmd)
    local ret = os.execute(cmd)
    return ret == true or ret == 0
end

-- Run a shell command and capture stdout+stderr.
function Tailscale:capture(cmd)
    local f = io.popen(cmd .. " 2>&1")
    if not f then return "" end
    local out = f:read("*a")
    f:close()
    return out or ""
end

-- Show a transient InfoMessage (with optional auto-close timeout).
function Tailscale:showInfo(msg, timeout)
    UIManager:show(InfoMessage:new{
        text    = msg,
        timeout = timeout,
    })
end

-- Show a "please wait" InfoMessage, repaint, run fn(), then close it.
-- Returns the result of fn().
function Tailscale:withSpinner(msg, fn)
    local spinner = InfoMessage:new{ text = msg }
    UIManager:show(spinner)
    UIManager:forceRePaint()
    local ok, result = pcall(fn)
    UIManager:close(spinner)
    if not ok then
        self:showInfo(_("Error: ") .. tostring(result), 5)
    end
    return result
end

-- Return true if the named process is currently running.
function Tailscale:isRunning(name)
    local ret = os.execute("pgrep -x " .. name .. " >/dev/null 2>&1")
    return ret == true or ret == 0
end

-- ---------------------------------------------------------------------------
-- Daemon operations
-- ---------------------------------------------------------------------------

--[[
    Start tailscaled.  mode is one of:
        "userspace"  – userspace networking (default, no kernel TUN needed)
        "proxy"      – userspace networking + SOCKS5/HTTP proxy
        "tun"        – kernel TUN (requires kernel support)
--]]
function Tailscale:startTailscaled(mode)
    self:withSpinner(_("Starting tailscaled…"), function()
        -- Kill any running instance and remove stale socket so it is always
        -- safe to switch modes without an explicit stop first.
        os.execute("pkill tailscaled 2>/dev/null; sleep 2")
        os.execute("rm -f " .. SOCKET_PATH)

        local log
        local cmd_args

        if mode == "proxy" then
            local addr = self:readFile(self.proxy_addr_file) or "localhost:1055"
            log = self.bin_dir .. "/tailscaled_proxy.log"
            cmd_args = string.format(
                '--statedir="%s/" -tun userspace-networking --socks5-server="%s" --outbound-http-proxy-listen="%s"',
                self.bin_dir, addr, addr
            )
        elseif mode == "tun" then
            log = self.bin_dir .. "/tailscaled_tun.log"
            cmd_args = string.format('--statedir="%s/"', self.bin_dir)
        else -- userspace (default)
            log = self.bin_dir .. "/tailscaled.log"
            cmd_args = string.format('--statedir="%s/" -tun userspace-networking', self.bin_dir)
        end

        local cmd = string.format(
            'nohup "%s" %s >> "%s" 2>&1 &',
            self.tailscaled_bin, cmd_args, log
        )
        os.execute(cmd)
        os.execute("sleep 3")

        if self:isRunning("tailscaled") then
            local label = ({ userspace = "userspace", proxy = "proxy", tun = "kernel TUN" })[mode]
            self:showInfo(string.format(_("tailscaled started (%s)."), label), 3)
        else
            self:showInfo(_("tailscaled failed to start.\nSee log in plugin's bin/ directory."), 5)
        end
    end)
end

function Tailscale:stopTailscaled()
    self:withSpinner(_("Stopping tailscaled…"), function()
        -- Graceful kill, then cleanup, then force-remove socket.
        os.execute("pkill tailscaled 2>/dev/null; sleep 3")
        os.execute("rm -f " .. SOCKET_PATH)
        os.execute(string.format('"%s" -cleanup >> "%s/tailscaled_stop.log" 2>&1',
            self.tailscaled_bin, self.bin_dir))
        os.execute("rm -f " .. SOCKET_PATH)
        self:showInfo(_("tailscaled stopped."), 3)
    end)
end

-- ---------------------------------------------------------------------------
-- Client operations
-- ---------------------------------------------------------------------------

function Tailscale:startTailscale()
    self:withSpinner(_("Connecting to Tailscale…"), function()
        local log = self.bin_dir .. "/tailscale_start.log"

        -- Try reconnecting without an auth key first (works when the node is
        -- already registered and key expiry has been disabled).  A 15-second
        -- timeout prevents hanging on a fresh/reset node that would otherwise
        -- wait for a login URL indefinitely.
        local reconnect = string.format(
            'timeout 15 "%s" up --ssh >> "%s" 2>&1', self.tailscale_bin, log)
        if self:exec(reconnect) then
            self:showInfo(_("Connected to Tailscale!"), 3)
            return
        end

        -- Fall back to auth key for first-time registration or after a reset.
        local auth_key = self:readFile(self.auth_key_file)
        if not auth_key then
            self:showInfo(_("Reconnect failed and auth.key is empty.\nAdd your auth key via Configure > Set Auth Key."), 5)
            return
        end

        local auth_cmd = string.format(
            '"%s" up --ssh --auth-key="%s" >> "%s" 2>&1',
            self.tailscale_bin, auth_key, log)
        if self:exec(auth_cmd) then
            self:showInfo(_("Connected to Tailscale!"), 3)
        else
            self:showInfo(_("Auth key login failed.\nSee tailscale_start.log in plugin's bin/ directory."), 5)
        end
    end)
end

function Tailscale:stopTailscale()
    self:withSpinner(_("Disconnecting from Tailscale…"), function()
        local log = self.bin_dir .. "/tailscale_stop.log"
        if self:exec(string.format('"%s" down >> "%s" 2>&1', self.tailscale_bin, log)) then
            self:showInfo(_("Tailscale disconnected."), 3)
        else
            self:showInfo(_("tailscale down failed.\nSee tailscale_stop.log in plugin's bin/ directory."), 5)
        end
    end)
end

function Tailscale:showStatus()
    local out = self:capture(string.format('"%s" status', self.tailscale_bin))
    if out ~= "" then
        self:showInfo(out, 10)
    else
        self:showInfo(_("Could not get status. Is tailscaled running?"), 4)
    end
end

-- ---------------------------------------------------------------------------
-- Binary installer / updater
-- ---------------------------------------------------------------------------

function Tailscale:updateBinaries()
    self:withSpinner(_("Checking for latest Tailscale version…"), function()
        -- Ensure the bin directory exists.
        os.execute('mkdir -p "' .. self.bin_dir .. '"')

        -- Detect installed version.
        local current = "none"
        if lfs.attributes(self.tailscale_bin, "mode") == "file" then
            local ver = self:capture(string.format('"%s" version', self.tailscale_bin))
            local first = ver:match("^([^\n]+)")
            if first and first ~= "" then
                current = first:match("^%s*(.-)%s*$")
            end
        end

        -- Resolve latest version from Tailscale's stable package index.
        local index_html = self:capture(
            'curl -fsSL --user-agent "tailscale-koplugin-updater/1.0" '
            .. '"https://pkgs.tailscale.com/stable/?v=latest"'
        )
        local latest = index_html:match("tailscale_([%d%.]+)_arm%.tgz")
        if not latest then
            self:showInfo(_("Could not determine latest version.\nCheck network connectivity."), 5)
            return
        end

        if current ~= "none" and current == latest then
            self:showInfo(string.format(_("Already up to date (v%s)."), latest), 4)
            return
        end

        -- Download.
        local action = current == "none"
            and string.format(_("Installing v%s…"), latest)
            or  string.format(_("Updating %s → %s…"), current, latest)
        self:showInfo(action .. "\n" .. _("This may take several minutes."), 5)
        UIManager:forceRePaint()

        local tmp_dir = self.bin_dir .. "/tmp_update"
        local tarball = string.format("tailscale_%s_arm.tgz", latest)
        local url     = "https://pkgs.tailscale.com/stable/" .. tarball
        local tmp_tgz = tmp_dir .. "/ts.tgz"

        os.execute('mkdir -p "' .. tmp_dir .. '"')
        local dl_ok = self:exec(string.format(
            'curl -fsSL --user-agent "tailscale-koplugin-updater/1.0" -o "%s" "%s"',
            tmp_tgz, url
        ))
        if not dl_ok or lfs.attributes(tmp_tgz, "size") == 0 then
            self:showInfo(_("Download failed. Check network connectivity."), 5)
            os.execute('rm -rf "' .. tmp_dir .. '"')
            return
        end

        -- Extract.
        os.execute(string.format('tar -xzf "%s" -C "%s"', tmp_tgz, tmp_dir))

        -- Locate binaries robustly (tarball layout may vary).
        local ts_bin  = self:capture(string.format(
            'find "%s" -type f -name "tailscale"  | head -1', tmp_dir)):match("^(.-)%s*$")
        local tsd_bin = self:capture(string.format(
            'find "%s" -type f -name "tailscaled" | head -1', tmp_dir)):match("^(.-)%s*$")

        if ts_bin == "" or tsd_bin == "" then
            self:showInfo(_("Could not find binaries in the downloaded tarball."), 5)
            os.execute('rm -rf "' .. tmp_dir .. '"')
            return
        end

        -- Back up existing binaries before replacing (upgrade only).
        if current ~= "none" then
            if lfs.attributes(self.tailscale_bin,  "mode") == "file" then
                os.execute(string.format('cp "%s" "%s.bak"', self.tailscale_bin,  self.tailscale_bin))
            end
            if lfs.attributes(self.tailscaled_bin, "mode") == "file" then
                os.execute(string.format('cp "%s" "%s.bak"', self.tailscaled_bin, self.tailscaled_bin))
            end
        end

        -- Install.
        local install_ok =
            self:exec(string.format('cp "%s" "%s" && chmod +x "%s"', ts_bin,  self.tailscale_bin,  self.tailscale_bin))
            and
            self:exec(string.format('cp "%s" "%s" && chmod +x "%s"', tsd_bin, self.tailscaled_bin, self.tailscaled_bin))

        os.execute('rm -rf "' .. tmp_dir .. '"')

        if not install_ok then
            self:showInfo(_("Failed to install binaries. Check available disk space."), 5)
            return
        end

        -- Create an empty auth.key placeholder on a fresh install.
        if lfs.attributes(self.auth_key_file, "mode") ~= "file" then
            self:writeFile(self.auth_key_file, "")
        end

        if current == "none" then
            self:showInfo(string.format(
                _("Tailscale v%s installed!\nAdd your auth key via Configure > Set Auth Key."), latest), 5)
        else
            self:showInfo(string.format(_("Tailscale updated to v%s."), latest), 4)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Configuration helpers
-- ---------------------------------------------------------------------------

function Tailscale:setAuthKey()
    local current = self:readFile(self.auth_key_file) or ""
    local dlg
    dlg = InputDialog:new{
        title       = _("Set Tailscale Auth Key"),
        input       = current,
        input_hint  = _("tskey-auth-…"),
        description = _("Paste your Tailscale auth key.\nGet one from tailscale.com/admin → Settings → Keys."),
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text     = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local key = dlg:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dlg)
                        if self:writeFile(self.auth_key_file, key) then
                            self:showInfo(_("Auth key saved."), 2)
                        else
                            self:showInfo(_("Failed to save auth key."), 3)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
end

function Tailscale:setProxyAddress()
    local current = self:readFile(self.proxy_addr_file) or "localhost:1055"
    local dlg
    dlg = InputDialog:new{
        title       = _("Set Proxy Address"),
        input       = current,
        input_hint  = _("host:port"),
        description = _("SOCKS5/HTTP proxy address used in proxy mode.\nDefault: localhost:1055"),
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text     = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local addr = dlg:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dlg)
                        if addr == "" then addr = "localhost:1055" end
                        if self:writeFile(self.proxy_addr_file, addr) then
                            self:showInfo(string.format(_("Proxy address set to %s."), addr), 2)
                        else
                            self:showInfo(_("Failed to save proxy address."), 3)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function Tailscale:addToMainMenu(menu_items)
    menu_items.tailscale = {
        text = _("Tailscale"),
        sub_item_table = {
            {
                text = _("Start Tailscaled"),
                sub_item_table = {
                    {
                        text     = _("Standard (Userspace)"),
                        callback = function() self:startTailscaled("userspace") end,
                    },
                    {
                        text     = _("Proxy Mode (SOCKS5/HTTP)"),
                        callback = function() self:startTailscaled("proxy") end,
                    },
                    {
                        text     = _("Kernel TUN"),
                        callback = function() self:startTailscaled("tun") end,
                    },
                },
            },
            {
                text     = _("Start Tailscale (Connect)"),
                callback = function() self:startTailscale() end,
            },
            {
                text     = _("Stop Tailscale (Disconnect)"),
                callback = function() self:stopTailscale() end,
            },
            {
                text     = _("Stop Tailscaled"),
                callback = function() self:stopTailscaled() end,
            },
            {
                text     = _("Show Status"),
                callback = function() self:showStatus() end,
            },
            {
                text = _("Configure"),
                sub_item_table = {
                    {
                        text     = _("Set Auth Key"),
                        callback = function() self:setAuthKey() end,
                    },
                    {
                        text     = _("Set Proxy Address"),
                        callback = function() self:setProxyAddress() end,
                    },
                },
            },
            {
                text     = _("Install / Update Binaries"),
                callback = function() self:updateBinaries() end,
            },
        },
    }
end

return Tailscale
