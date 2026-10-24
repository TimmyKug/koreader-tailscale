--[[
    Tailscale KOReader Plugin
    Connects a KOReader device to a Tailscale VPN network.

    Ported from kual-tailscale (KUAL extension) by Mitanshu.
    Completely self-contained: binaries and state live entirely under
    this plugin's own bin/ directory; no KUAL or other extension required.
--]]

local Blitbuffer    = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device        = require("device")
local Font          = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom          = require("ui/geometry")
local GestureRange  = require("ui/gesturerange")
local InfoMessage   = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog   = require("ui/widget/inputdialog")
local Size          = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager     = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan  = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger        = require("logger")
local lfs           = require("libs/libkoreader-lfs")
local _             = require("gettext")

-- QRWidget only exists in newer KOReader; without it the login link is shown as text.
local has_qr, QRWidget = pcall(require, "ui/widget/qrwidget")

local SOCKET_PATH = "/var/run/tailscale/tailscaled.sock"
local TUN_PATH    = "/dev/net/tun"

-- How long to wait for a login link, and for the user to finish logging in.
local LOGIN_URL_TIMEOUT = 30
local LOGIN_TIMEOUT     = 300
local LOGIN_POLL        = 2

local Tailscale = WidgetContainer:extend{
    name        = "tailscale",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Tailscale:init()
    self.paths = {
        bin_dir = self.path .. "/bin",
        tailscale_bin = self.path .. "/bin/tailscale",
        tailscaled_bin = self.path .. "/bin/tailscaled",
        auth_key_file = self.path .. "/bin/auth.key",
        tailscaled_log = self.path .. "/bin/tailscaled_tun.log",
        tailscaled_stop_log = self.path .. "/bin/tailscaled_stop.log",
        tailscale_start_log = self.path .. "/bin/tailscale_start.log",
        tailscale_stop_log = self.path .. "/bin/tailscale_stop.log",
    }

    self.bin_dir = self.paths.bin_dir
    self.tailscale_bin = self.paths.tailscale_bin
    self.tailscaled_bin = self.paths.tailscaled_bin
    self.auth_key_file = self.paths.auth_key_file

    -- bin/ holds no tracked files, so a fresh copy may not have it yet.
    if lfs.attributes(self.bin_dir, "mode") ~= "directory" then
        lfs.mkdir(self.bin_dir)
    end

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

-- tailscaled runs in kernel-TUN mode only, so a kernel without TUN can never
-- work. Some kernels build TUN as a module, so try loading it before giving up.
function Tailscale:hasTun()
    if lfs.attributes(TUN_PATH, "mode") == "char device" then
        return true
    end
    os.execute("modprobe tun >/dev/null 2>&1")
    return lfs.attributes(TUN_PATH, "mode") == "char device"
end

-- Show why nothing will work and return false when TUN is missing.
function Tailscale:requireTun()
    if self:hasTun() then
        return true
    end
    self:showInfo(_("This device has no /dev/net/tun.\nIts kernel lacks TUN support, so Tailscale cannot run here."), 8)
    return false
end

-- Return tailscaled's BackendState (e.g. "Running", "NeedsLogin", "Stopped")
-- and the pending login URL, if any.
function Tailscale:backendState()
    local out = self:capture(string.format('"%s" status --json', self.tailscale_bin))
    local state = out:match('"BackendState"%s*:%s*"([^"]*)"')
    local url = out:match('"AuthURL"%s*:%s*"([^"]+)"')
    return state, url
end

function Tailscale:isSocketReady()
    return lfs.attributes(SOCKET_PATH, "mode") == "socket"
end

function Tailscale:waitForSocket(timeout_seconds)
    for _ = 1, timeout_seconds do
        os.execute("sleep 1")
        if self:isSocketReady() then
            return true
        end
    end
    return false
end

function Tailscale:ensureTailscaledRunning(restart)
    if restart then
        -- Kill any running instance and remove stale socket so it is always
        -- safe to restart without an explicit stop first.
        os.execute("pkill tailscaled 2>/dev/null; sleep 2")
        os.execute("rm -f " .. SOCKET_PATH)
    elseif self:isSocketReady() then
        return true
    end

    local cmd = string.format(
        'nohup "%s" --statedir="%s/" >> "%s" 2>&1 &',
        self.tailscaled_bin, self.bin_dir, self.paths.tailscaled_log
    )
    os.execute(cmd)

    -- Poll for the socket file (up to 10s) rather than a fixed sleep + pgrep,
    -- so slow devices don't get a false "failed" alert.
    return self:waitForSocket(10)
end

-- ---------------------------------------------------------------------------
-- Daemon operations
-- ---------------------------------------------------------------------------

function Tailscale:startTailscaled()
    if not self:requireTun() then return end
    self:withSpinner(_("Starting tailscaled…"), function()
        if self:ensureTailscaledRunning(true) then
            self:showInfo(_("tailscaled started (kernel TUN).\nNow tap \"Connect to Tailnet\" to join your network."), 5)
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
        os.execute(string.format('"%s" -cleanup >> "%s" 2>&1',
            self.tailscaled_bin, self.paths.tailscaled_stop_log))
        os.execute("rm -f " .. SOCKET_PATH)
        self:showInfo(_("tailscaled stopped."), 3)
    end)
end

-- ---------------------------------------------------------------------------
-- Client operations
-- ---------------------------------------------------------------------------

-- Bring the node up. Returns "qr" when it has to log in and there is no auth
-- key, so the caller can start the QR login once its spinner has closed.
function Tailscale:connectTailscaleInternal()
    local log = self.paths.tailscale_start_log
    local state = self:backendState()

    if state == "Running" then
        self:showInfo(_("Connected to Tailscale!"), 3)
        return
    end

    -- A node that has logged in before reconnects without any key. Tailscale's
    -- own timeout keeps this from hanging if the saved login turns out to be
    -- stale. A fresh or reset node needs a login, so skip straight to that.
    if state ~= "NeedsLogin" and state ~= "NoState" then
        local reconnect = string.format(
            '"%s" up --ssh --timeout=15s >> "%s" 2>&1', self.tailscale_bin, log)
        if self:exec(reconnect) then
            self:showInfo(_("Connected to Tailscale!"), 3)
            return
        end
    end

    -- An auth key, if one was saved, logs in without any interaction.
    local auth_key = self:readFile(self.auth_key_file)
    if not auth_key then
        return "qr"
    end

    -- The default Tailscale timeout is 0 (wait forever), so bound the auth
    -- attempt as well. This is especially important when stale state belongs
    -- to another tailnet or the saved key is expired.
    local auth_cmd = string.format(
        '"%s" up --ssh --timeout=30s --auth-key="%s" >> "%s" 2>&1',
        self.tailscale_bin, auth_key, log)
    if self:exec(auth_cmd) then
        self:showInfo(_("Connected to Tailscale!"), 3)
    else
        self:showInfo(_("Auth key login failed.\nSee tailscale_start.log in plugin's bin/ directory."), 5)
    end
end

-- ---------------------------------------------------------------------------
-- QR login
-- ---------------------------------------------------------------------------

-- A full-screen card with the login link as a QR code. Tapping it cancels.
function Tailscale:newLoginScreen(url, on_cancel)
    local Screen = Device.screen
    local text_width = math.floor(Screen:getWidth() * 0.8)
    local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.55)

    local body = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = _("Scan with your phone and log in to Tailscale.\nThis device joins your tailnet as soon as you approve it."),
            face = Font:getFace("cfont", 20),
            width = text_width,
            alignment = "center",
        },
        VerticalSpan:new{ width = Size.padding.fullscreen * 2 },
    }
    if has_qr then
        table.insert(body, QRWidget:new{ text = url, width = qr_size, height = qr_size })
        table.insert(body, VerticalSpan:new{ width = Size.padding.fullscreen * 2 })
    end
    table.insert(body, TextBoxWidget:new{
        text = url,
        face = Font:getFace("x_smallinfofont"),
        width = text_width,
        alignment = "center",
    })
    table.insert(body, VerticalSpan:new{ width = Size.padding.fullscreen })
    table.insert(body, TextBoxWidget:new{
        text = _("Tap to cancel."),
        face = Font:getFace("x_smallinfofont"),
        width = text_width,
        alignment = "center",
    })

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.fullscreen * 2,
        body,
    }
    local screen = InputContainer:new{
        modal = true,
        ges_events = {
            TapCancel = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
                },
            },
        },
        CenterContainer:new{ dimen = Screen:getSize(), frame },
    }
    function screen:onShow()
        UIManager:setDirty(self, function() return "ui", frame.dimen end)
        return true
    end
    function screen:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", frame.dimen end)
    end
    function screen:onTapCancel()
        on_cancel()
        return true
    end
    return screen
end

-- Log in without an auth key: `tailscale up` waits for a browser login, and
-- the plugin shows its login link as a QR code until tailscaled reports Running.
function Tailscale:loginWithQR()
    local log = self.paths.tailscale_start_log
    os.execute("pkill -x tailscale 2>/dev/null")
    os.execute(string.format('nohup "%s" up --ssh >> "%s" 2>&1 &', self.tailscale_bin, log))

    local started = os.time()
    local waiting = InfoMessage:new{ text = _("Getting a login link from Tailscale…") }
    UIManager:show(waiting)
    local screen, poll

    local function finish(msg, timeout)
        UIManager:unschedule(poll)
        if waiting then UIManager:close(waiting); waiting = nil end
        if screen then UIManager:close(screen); screen = nil end
        if msg then self:showInfo(msg, timeout) end
    end

    local function cancel(msg)
        os.execute("pkill -x tailscale 2>/dev/null")
        finish(msg, 4)
    end

    poll = function()
        local state, url = self:backendState()
        if state == "Running" then
            finish(_("Connected to Tailscale!"), 3)
            return
        end
        if url and not screen then
            if waiting then UIManager:close(waiting); waiting = nil end
            screen = self:newLoginScreen(url, function() cancel(_("Login cancelled.")) end)
            UIManager:show(screen)
        end
        local elapsed = os.time() - started
        if not screen and elapsed > LOGIN_URL_TIMEOUT then
            cancel(_("Could not get a login link.\nCheck Wi-Fi and see tailscale_start.log in the plugin's bin/ directory."))
            return
        end
        if elapsed > LOGIN_TIMEOUT then
            cancel(_("Login timed out. Try again."))
            return
        end
        UIManager:scheduleIn(LOGIN_POLL, poll)
    end
    UIManager:scheduleIn(LOGIN_POLL, poll)
end

function Tailscale:disconnectTailscaleInternal()
    local log = self.paths.tailscale_stop_log
    if self:exec(string.format('"%s" down >> "%s" 2>&1', self.tailscale_bin, log)) then
        self:showInfo(_("Disconnected from Tailscale."), 3)
        return true
    else
        self:showInfo(_("tailscale down failed.\nSee tailscale_stop.log in plugin's bin/ directory."), 5)
        return false
    end
end

function Tailscale:startTailscale()
    if not self:requireTun() then return end
    local next_step = self:withSpinner(_("Starting tailscaled and connecting…"), function()
        if not self:ensureTailscaledRunning(false) then
            self:showInfo(_("tailscaled failed to start in kernel TUN mode.\nSee tailscaled_tun.log in the plugin's bin/ directory."), 5)
            return
        end

        return self:connectTailscaleInternal()
    end)
    if next_step == "qr" then self:loginWithQR() end
end

function Tailscale:stopTailscale()
    self:withSpinner(_("Disconnecting from Tailscale and stopping tailscaled…"), function()
        local down_ok = self:disconnectTailscaleInternal()

        if self:isSocketReady() or self:isRunning("tailscaled") then
            os.execute("pkill tailscaled 2>/dev/null; sleep 3")
            os.execute("rm -f " .. SOCKET_PATH)
            os.execute(string.format('"%s" -cleanup >> "%s" 2>&1',
                self.tailscaled_bin, self.paths.tailscaled_stop_log))
            os.execute("rm -f " .. SOCKET_PATH)
        end

        if down_ok then
            self:showInfo(_("Tailscale disconnected and tailscaled stopped."), 3)
        else
            self:showInfo(_("tailscale down failed.\nSee tailscale_stop.log in plugin's bin/ directory."), 5)
        end
    end)
end

function Tailscale:connectTailscale()
    local next_step = self:withSpinner(_("Connecting to Tailscale…"), function()
        if not self:isSocketReady() and not self:isRunning("tailscaled") then
            self:showInfo(_("tailscaled is not running.\nUse Start Service or Start Service and Connect."), 5)
            return
        end

        return self:connectTailscaleInternal()
    end)
    if next_step == "qr" then self:loginWithQR() end
end

function Tailscale:disconnectTailscale()
    self:withSpinner(_("Disconnecting from Tailscale…"), function()
        self:disconnectTailscaleInternal()
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
    -- No point downloading binaries that can never start.
    if not self:requireTun() then return end
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
                _("Tailscale v%s installed!\nNow tap Start Service and Connect."), latest), 5)
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
        description = _("Optional. With a key saved, Start Service and Connect logs in without the QR code.\nGet one from tailscale.com/admin → Settings → Keys."),
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

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function Tailscale:addToMainMenu(menu_items)
    menu_items.tailscale = {
        text = _("Tailscale"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text     = _("Start Service and Connect"),
                callback = function() self:startTailscale() end,
            },
            {
                text     = _("Disconnect and Stop Service"),
                callback = function() self:stopTailscale() end,
            },
            {
                text = _("Setup"),
                sub_item_table = {
                    {
                        text     = _("Set Auth Key"),
                        callback = function() self:setAuthKey() end,
                    },
                    {
                        text     = _("Install / Update Binaries"),
                        callback = function() self:updateBinaries() end,
                    },
                },
            },
            {
                text = _("Advanced"),
                sub_item_table = {
                    {
                        text     = _("Start Service"),
                        callback = function() self:startTailscaled() end,
                    },
                    {
                        text     = _("Stop Service"),
                        callback = function() self:stopTailscaled() end,
                    },
                    {
                        text     = _("Connect to Tailnet"),
                        callback = function() self:connectTailscale() end,
                    },
                    {
                        text     = _("Disconnect from Tailnet"),
                        callback = function() self:disconnectTailscale() end,
                    },
                    {
                        text     = _("Connection Status"),
                        callback = function() self:showStatus() end,
                    },
                },
            },
        },
    }
end

return Tailscale
