# Tailscale KOReader Plugin

Connect your KOReader device to a Tailscale VPN network using kernel TUN mode.
This version of the plugin is intentionally simplified for a Kindle setup where
TUN support is known to work, so there is no userspace or proxy mode.

## Credits

This plugin is based on mitanshu7's kual extension for tailscale (https://github.com/mitanshu7/tailscale_kual.git)

## Prerequisites

1. Jailbroken Kindle (or any KOReader-supported device). ([see](https://kindlemodding.gitbook.io/kindlemodding))
2. [KOReader](https://koreader.rocks) installed.
3. Wi-Fi connectivity on the device.
4. A [Tailscale account](https://tailscale.com) and an auth key.

## Tested on

Jailbroken Kindle PaperWhite 11th Generation — `armv7l`.

## Installation

1. Copy the `tailscale.koplugin/` folder into KOReader's `plugins/` directory
   (typically `/mnt/us/koreader/plugins/` on Kindle).

2. Restart KOReader (or reload plugins via the plugin manager).

3. Open **KOReader menu → Tools → Tailscale → Setup → Install / Update Binaries**.
   This downloads the latest `tailscale` and `tailscaled` ARM binaries from
   `pkgs.tailscale.com` directly onto the device over Wi-Fi.

4. Open **Tailscale → Setup → Set Auth Key** and paste your
   [Tailscale auth key](https://tailscale.com/kb/1085/auth-keys).
   Get one from [tailscale.com/admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys).

5. Open **Start Service and Connect**. This will start `tailscaled` in kernel TUN mode
   if needed, then connect the device to your tailnet.

6. Your device will appear in your
   [Tailscale admin console](https://login.tailscale.com/admin/machines)
   with a fixed IP. SSH in with `ssh root@<tailscale-ip>`.

7. **Recommended:** In the admin console, find your device, open the three-dot
   menu, and select **Disable key expiry**. After this, the device reconnects
   automatically on every reboot without needing the auth key again.

All binaries and state files are stored inside the plugin's own `bin/` directory.
The plugin is completely self-contained and requires no other extensions.

## How It Works

The plugin uses `tailscaled` in kernel TUN mode only. That gives the Kindle
normal device-wide Tailscale connectivity, which keeps the KOReader side simple:
apps can connect directly to tailnet addresses without extra proxy setup.

There are two primary actions in the menu:

- **Start Service and Connect**: starts `tailscaled` in kernel TUN mode if it is not
  already running, then runs `tailscale up`.
- **Disconnect and Stop Service**: runs `tailscale down` and then stops `tailscaled`.

Setup actions are grouped separately:

- **Set Auth Key**: saves the auth key used for first-time registration.
- **Install / Update Binaries**: downloads or updates the bundled Tailscale binaries.

Advanced actions are still available separately:

- **Start Service**: starts only the daemon, which is useful if you want to
  bring it up separately for debugging.
- **Stop Service**: stops only the daemon.
- **Connect to Tailnet**: runs `tailscale up` without starting `tailscaled` for you.
- **Disconnect from Tailnet**: runs `tailscale down` without stopping `tailscaled`.
- **Connection Status**: displays `tailscale status`.

## Updating Binaries

**Install / Update Binaries** handles both fresh installs and upgrades:

- Fetches the latest version from `pkgs.tailscale.com`.
- Skips the download if already up to date.
- Backs up existing binaries as `*.bak` before replacing them.
- Creates an empty `auth.key` placeholder on a fresh install.

## Resetting

To start completely fresh:

1. Use **Disconnect and Stop Service** via the menu.
2. Remove the device from the [Tailscale admin console](https://login.tailscale.com/admin/machines).
3. Delete the state and log files from the plugin's `bin/` directory:
   `tailscaled.state`, `*.log`, and `auth.key`.

## Troubleshooting

- Log files are written to the plugin's `bin/` directory alongside the binaries.
- Keep the device screen on — Kindle suspends Wi-Fi when the screen is off.
- SSH does not work while the device is connected via USB cable.
- Check open/closed issues on GitHub if something does not work out of the box.
