# Tailscale KOReader Plugin

Connect your KOReader device to a Tailscale VPN network — SSH in from anywhere, or route KOReader's traffic through your tailnet.

## Prerequisites

1. Jailbroken Kindle (or any KOReader-supported device). ([see](https://kindlemodding.gitbook.io/kindlemodding))
2. [KOReader](https://koreader.rocks) installed.
3. Wi-Fi connectivity on the device.
4. A [Tailscale account](https://tailscale.com) and an auth key.

## Tested on

PaperWhite 7th Generation (PW3) — `armv7l`, Linux 3.0.35-lab126.

## Installation

1. Copy the `tailscale.koplugin/` folder into KOReader's `plugins/` directory
   (typically `/mnt/us/koreader/plugins/` on Kindle).

2. Restart KOReader (or reload plugins via the plugin manager).

3. Open **KOReader menu → Tools → Tailscale → Install / Update Binaries**.
   This downloads the latest `tailscale` and `tailscaled` ARM binaries from
   `pkgs.tailscale.com` directly onto the device over Wi-Fi.

4. Go to **Tailscale → Configure → Set Auth Key** and paste your
   [Tailscale auth key](https://tailscale.com/kb/1085/auth-keys).
   Get one from [tailscale.com/admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys).

5. Open **Start Tailscaled** and pick a mode (see [Modes](#tailscaled-modes) below).

6. Open **Start Tailscale (Connect)**. Your device will appear in your
   [Tailscale admin console](https://login.tailscale.com/admin/machines)
   with a fixed IP. SSH in with `ssh root@<tailscale-ip>`.

7. **Recommended:** In the admin console, find your device, open the three-dot
   menu, and select **Disable key expiry**. After this, the device reconnects
   automatically on every reboot without needing the auth key again.

All binaries and state files are stored inside the plugin's own `bin/` directory.
The plugin is completely self-contained and requires no other extensions.

## Tailscaled Modes

Open **Start Tailscaled** in the KOReader menu — it is a submenu with three options.

### 1. Standard (Userspace) — default

Runs `tailscaled -tun userspace-networking`. The device joins your tailnet and
is reachable by its Tailscale IP (good for SSH). Outgoing connections from the
device to other tailnet nodes may not work on all firmware versions.

### 2. Proxy Mode (SOCKS5/HTTP)

Runs `tailscaled` in userspace-networking mode and also starts a SOCKS5 and
HTTP proxy on `localhost:1055`. Apps that honour a proxy setting (including
KOReader's own network requests) can route traffic through Tailscale.

After starting in proxy mode and connecting, configure KOReader's proxy:

- **KOReader menu → Settings → Network → Proxy Settings**
- Type: **SOCKS5** (or HTTP), Host: `localhost`, Port: `1055`

To use a different address, open **Configure → Set Proxy Address** before starting.

### 3. Kernel TUN

Runs `tailscaled` without `userspace-networking`, relying on the kernel's
TUN/TAP module for full system-wide VPN connectivity. **Not available on all
Kindle firmware versions** — if it fails, use Proxy Mode instead.

## Updating Binaries

**Install / Update Binaries** handles both fresh installs and upgrades:

- Fetches the latest version from `pkgs.tailscale.com`.
- Skips the download if already up to date.
- Backs up existing binaries as `*.bak` before replacing them.
- Creates an empty `auth.key` placeholder on a fresh install.

## Resetting

To start completely fresh:

1. Stop **Tailscale** and **Tailscaled** via the menu.
2. Remove the device from the [Tailscale admin console](https://login.tailscale.com/admin/machines).
3. Delete the state and log files from the plugin's `bin/` directory:
   `tailscaled.state`, `*.log`, and `auth.key`.

## Troubleshooting

- Log files are written to the plugin's `bin/` directory alongside the binaries.
- Keep the device screen on — Kindle suspends Wi-Fi when the screen is off.
- SSH does not work while the device is connected via USB cable.
- Check open/closed issues on GitHub if something does not work out of the box.
