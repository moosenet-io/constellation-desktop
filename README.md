# Constellation Desktop

A system-tray app that turns a desktop into an opt-in MooseNet node: a sandboxed Linux build worker, a Tdarr transcode
node, and one-click **Game Mode** so the machine is yours the moment you want it.

- **Windows**: WSL2 build distro + a per-minute controller task; tray in the notification area.
- **macOS** (Intel and Apple Silicon): Lima VM build worker (x86_64; emulated on Apple Silicon so results match
  the build door) + menu-bar app started at login.

## What it does
- Status at a glance (building / idle / transcoding / game mode / off).
- Game Mode (manual or automatic when a Steam game is running): stops builds and transcodes safely, at once.
- Builder and Tdarr switches, CPU/RAM caps for the build VM, Tailscale / WireGuard shortcuts, job-server test.
- Pull-only: the node fetches signed, checksummed jobs; nothing listens for inbound connections. The build user has
  no network access; the Windows/macOS file system is not exposed to the VM except one exchange folder.
- Self-updates from this repository's GitHub Releases (sha256-verified against `SHA256SUMS`).

## Install
- **Windows**: download `constellation-desktop_windows_amd64.zip`, unzip to a folder, run `setup-windows.ps1`
  (needs WSL; `wsl --install --no-distribution` as admin first), then start `MooseNetTray.exe`.
- **macOS**: download the zip for your Mac, unzip, run `bash mac/install.sh mac/constellation-desktop`.
  The app is not notarized yet: the first launch may need right-click > Open.

## Control files
The tray, the reconciler and the fleet all use the same switch files in the node's `control` folder:
`BUILDER_ON`, `TDARR_ON`, `GAME_MODE`, `RUNNER_OFF` (Windows), `APPLY_VMCONFIG`, `CANCEL`.

## Building
`go build .` on the target OS (macOS needs CGO for the menu bar). Releases are built by GitHub Actions on `v*` tags.
