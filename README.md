# KOReader Tailscale Plugin for Kindle, Kobo, and Other E-Readers

Self-contained KOReader plugin that installs and runs Tailscale on a compatible e-reader for private tailnet access, SSH, and self-hosted reading workflows.

Project page: https://timmykug.github.io/koreader-tailscale-plugin/

## What This Project Does

`koreader-tailscale-plugin` adds a small **KOReader plugin** menu that lets you:

- install or update official Tailscale ARM binaries directly on the device
- save a Tailscale auth key for first-time registration
- start and stop `tailscaled`
- connect and disconnect the device from your tailnet
- inspect connection status from inside KOReader

The plugin keeps its binaries, state, and logs inside `tailscale.koplugin/bin/`, so the setup stays local to the plugin instead of spreading files across other extensions.

## Why Someone Would Use It

This repository is for people who want **Tailscale on an e-reader** without building a larger custom stack around KOReader.

Typical reasons to use it:

- reach a private **self-hosted library** or **OPDS** catalog from KOReader over Tailscale
- get **remote access** to a jailbroken **Kindle** over **SSH**
- keep an e-reader on a private network for home lab, NAS, or ebook workflows
- pair KOReader with broader self-hosted setups that also involve **Syncthing**, OPDS, or SSH

The plugin does not bundle Syncthing, an OPDS server, or an SSH server. It provides the network path that makes those services reachable from the device when they already exist elsewhere on your tailnet.

## Who It Is For

- KOReader users on a jailbroken Kindle who want direct tailnet access from the reader
- People running private ebook infrastructure and wanting cleaner access from an e-reader
- Anyone who prefers a focused KOReader integration over a more general Tailscale packaging project

## What Makes This Repo Different

This implementation is intentionally narrower than similar `koreader-tailscale` repositories:

- it is a KOReader-first plugin, not a KUAL extension
- it is self-contained, with binaries and state stored inside the plugin directory
- it uses a **kernel-TUN-only** approach instead of mixing in userspace or proxy modes
- it downloads current binaries from `pkgs.tailscale.com` directly on the device
- it is optimized for a practical remote access workflow rather than a broad configuration surface

If you want the simplest path to direct Tailscale connectivity on a compatible KOReader device, that minimal approach is the point of this repository.

## Compatibility

The current implementation is tested on:

- jailbroken Kindle Paperwhite 11th Generation
- architecture: `armv7l`

It should be considered **Kindle-first**. **Kobo** and other KOReader devices may work if they have compatible kernel TUN support, but that is not the main target of this repository.

## Installation

1. Copy `tailscale.koplugin/` into KOReader's `plugins/` directory.
   On Kindle this is usually `/mnt/us/koreader/plugins/`.
2. Restart KOReader, or reload plugins from the plugin manager.
3. Open `KOReader menu -> Tools -> Tailscale -> Setup -> Install / Update Binaries`.
4. Open `Tailscale -> Setup -> Set Auth Key` and paste a Tailscale auth key.
5. Tap `Start Service and Connect` to launch `tailscaled` and run `tailscale up`.
6. Confirm the device appears in the Tailscale admin console, then connect with `ssh root@<tailscale-ip>` if needed.
7. For persistent reconnects, disable key expiry for the device in the Tailscale admin console after the first successful login.

## How It Works

The plugin runs `tailscaled` in kernel TUN mode and exposes a small KOReader menu around that workflow.

Primary actions:

- `Start Service and Connect`: start `tailscaled` if needed, then run `tailscale up --ssh`
- `Disconnect and Stop Service`: run `tailscale down`, stop `tailscaled`, and clean up

Setup actions:

- `Set Auth Key`: save the auth key used for first registration
- `Install / Update Binaries`: fetch or update the bundled `tailscale` and `tailscaled` binaries

Advanced actions:

- `Start Service`
- `Stop Service`
- `Connect to Tailnet`
- `Disconnect from Tailnet`
- `Connection Status`

## Practical Use Cases

- Use KOReader with a private OPDS catalog on a home server without exposing it publicly.
- SSH into a Kindle over Tailscale for maintenance, logs, or file transfer.
- Keep an e-reader inside a private network so it can reach self-hosted tools while away from home.
- Support a broader reading setup where KOReader, Syncthing, SSH, and OPDS are all part of the same tailnet workflow.

## Updating Binaries

`Install / Update Binaries`:

- checks the latest stable ARM package published by Tailscale
- skips work if the installed version is already current
- backs up existing binaries as `*.bak` before replacement
- creates an empty `auth.key` on first install

## Resetting

To start fresh:

1. Use `Disconnect and Stop Service`.
2. Remove the device from the Tailscale admin console.
3. Delete `tailscaled.state`, `*.log`, and `auth.key` from `tailscale.koplugin/bin/`.

## Troubleshooting

- Logs are written to `tailscale.koplugin/bin/`.
- Keep the device screen on while testing because Kindle may suspend Wi-Fi when the screen sleeps.
- SSH may not work while the device is connected over USB.
- If binary download fails, check Wi-Fi connectivity and try again from KOReader.

## Credits

This plugin is based on [mitanshu7's kual extension for tailscale](https://github.com/mitanshu7/tailscale_kual.git), then simplified into a self-contained KOReader plugin workflow.
