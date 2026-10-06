# KOReader Tailscale Plugin

A minimalistic Tailscale plugin for KOReader. Install it, paste an auth key, and your
e-reader joins your tailnet.

**[⬇ Download the latest release](https://github.com/TimmyKug/koreader-tailscale/releases/latest/download/tailscale.koplugin.zip)**
· [Project page](https://timothykugler.de/koreader-tailscale/)
· [Releases](https://github.com/TimmyKug/koreader-tailscale/releases)

<p>
  <img src="docs/screenshots/network-menu.png" width="49%" alt="KOReader network settings menu with a Tailscale entry">
  <img src="docs/screenshots/tailscale-menu.png" width="49%" alt="Tailscale menu: Start Service and Connect, Disconnect and Stop Service, Setup, Advanced">
</p>

## What it is

One KOReader plugin, one menu. It downloads the official Tailscale ARM binaries onto the
device, stores the auth key, runs `tailscaled` in kernel-TUN mode, and brings the device
up on your tailnet with `tailscale up --ssh`.

Everything lives inside the plugin folder — binaries, node state and logs all sit in
`tailscale.koplugin/bin/`. There is no KUAL extension to install, no userspace proxy
mode, and nothing scattered across the rest of the device. Deleting the folder removes
the whole thing.

That buys you the usual things a tailnet is good for from an e-reader:

- SSH into a jailbroken Kindle from anywhere
- reach a private OPDS catalogue or home library server from KOReader
- keep the reader on a private network instead of exposing services publicly

The plugin provides the network path only. It does not bundle an OPDS server, Syncthing
or an SSH server — those live elsewhere on your tailnet.

## How to set it up

1. Download [`tailscale.koplugin.zip`](https://github.com/TimmyKug/koreader-tailscale/releases/latest/download/tailscale.koplugin.zip)
   from the latest release and unzip it into KOReader's `plugins/` directory, so you end
   up with `plugins/tailscale.koplugin/`. On Kindle that is usually
   `/mnt/us/koreader/plugins/`. (Cloning the repo and copying the folder works too.)
2. Restart KOReader so the plugin is picked up.
3. Generate an auth key at
   [tailscale.com/admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys).
4. On the device, open the network menu → **Tailscale → Setup → Install / Update
   Binaries**. This pulls the current stable release from `pkgs.tailscale.com`, so the
   device needs Wi-Fi. It can take a few minutes.
5. **Tailscale → Setup → Set Auth Key** and paste the key.

   <img src="docs/screenshots/auth-key-dialog.png" width="400" alt="Set Tailscale Auth Key dialog with the key field and Save button">

6. **Tailscale → Start Service and Connect**. The device should appear in the Tailscale
   admin console; from there `ssh root@<tailscale-ip>` works.
7. Disable key expiry for the device in the admin console. Without it you have to paste a
   fresh key every time the key expires.

**Disconnect and Stop Service** is the reverse: it runs `tailscale down`, stops the
daemon and cleans up.

### The menu

| Item | Does |
|---|---|
| Start Service and Connect | starts `tailscaled` if needed, then `tailscale up --ssh` |
| Disconnect and Stop Service | `tailscale down`, stop the daemon, clean up |
| Setup → Set Auth Key | saves the key used for first registration |
| Setup → Install / Update Binaries | fetches or updates the bundled binaries |
| Advanced → Start / Stop Service | daemon only |
| Advanced → Connect / Disconnect | client only |
| Advanced → Connection Status | shows `tailscale status` |

<p>
  <img src="docs/screenshots/setup-menu.png" width="49%" alt="Setup submenu: Set Auth Key, Install / Update Binaries">
  <img src="docs/screenshots/advanced-menu.png" width="49%" alt="Advanced submenu: Start Service, Stop Service, Connect to Tailnet, Disconnect from Tailnet, Connection Status">
</p>

**Install / Update Binaries** checks the latest stable ARM package, skips the work if the
installed version is already current, and backs up existing binaries as `*.bak` before
replacing them.

## Compatibility

Two hard requirements:

- the device kernel needs a working TUN device at `/dev/net/tun` — there is no
  userspace-networking fallback
- the plugin installs the 32-bit `arm` build, which is what KOReader on Kindle runs on; a
  device with a 64-bit-only userland is not handled

One SSH command answers the question for any device: `ls -l /dev/net/tun`. If it is
there, the plugin should work.

| Device | Status |
|---|---|
| Kindle Paperwhite 5 (11th gen, `armv7l`) | **Tested** — this is the device it was built and used on |
| Kindle Paperwhite 4 (10th gen), Oasis 2 & 3, Kindle 10th/11th gen, Scribe | Expected to work — same jailbreak era and kernel generation, but untested |
| Older Kindles (Paperwhite 1–3, Voyage, Touch) | Unverified — TUN support is not a given on these kernels, so check first |
| Kobo and other KOReader devices | May work with kernel TUN and a 32-bit userland, but not a target here |

The Kindle must be jailbroken with KOReader installed.

## Switching accounts

Tailscale stores the device's tailnet identity in `tailscale.koplugin/bin/tailscaled.state`.
Restarting KOReader or the device does **not** clear it, so connecting to a different
account needs a reset:

1. **Disconnect and Stop Service**.
2. Rename `tailscaled.state` to `tailscaled.state.old` in `bin/`. Renaming keeps the reset
   reversible.
3. **Set Auth Key** with a fresh key from the account you want to join.
4. **Start Service and Connect**.
5. Once that works, remove the old device entry from the previous admin console.

## Troubleshooting

- Logs are written to `tailscale.koplugin/bin/`. `tailscale_start.log` has the connection
  errors, `tailscaled_tun.log` the daemon ones.
- Keep the screen awake while testing — Kindle drops Wi-Fi when it sleeps.
- SSH tends not to work while the device is plugged in over USB.
- If the download fails, check Wi-Fi and retry from KOReader.
- The connect commands have bounded timeouts, so a dead network, stale identity or
  rejected key returns an error instead of leaving KOReader stuck on "connecting".

## Releases

Releases are built by GitHub Actions (`.github/workflows/release.yml`). To cut one, push a
tag such as `v1.0.0`, or run the **Release** workflow from the Actions tab and enter a
version. The workflow stamps the version into `_meta.lua`, zips `tailscale.koplugin/`
and attaches it to the release.

## Support

The plugin is free and always will be. If it saved you an afternoon, you can
[buy me a coffee](https://buymeacoffee.com/timmykug).

## Credits

Based on [mitanshu7's Tailscale KUAL extension](https://github.com/mitanshu7/tailscale_kual),
reworked into a self-contained KOReader plugin.

## License

MIT, see [LICENSE](LICENSE). The original KUAL extension is also MIT.
