#!/bin/bash
# install.sh -- set up a macOS MooseNet node (build VM + tray app at login). Run as your normal user:
#   bash install.sh [path/to/constellation-desktop binary]
# Needs Homebrew (https://brew.sh). Installs Lima, creates an x86_64 Linux VM "moosenet-builder" with the same
# golden toolchain as the Windows/AWS nodes, and adds a LaunchAgent so the tray starts at login.
# Intel Macs run the VM natively. Apple Silicon emulates x86_64 (QEMU) so results match the build door; expect
# builds ~3-5x slower than an Intel/AMD node of the same core count.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NODE="$HOME/Library/Application Support/MooseNet/node"
BIN_SRC=${1:-"$HERE/constellation-desktop"}
mkdir -p "$NODE/control" "$NODE/logs" "$NODE/exchange/inbox" "$NODE/exchange/outbox" "$NODE/bin"

echo "== 1. Lima"
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 2; }
command -v limactl >/dev/null || brew install lima
[ "$(uname -m)" = "arm64" ] && { brew list qemu >/dev/null 2>&1 || brew install qemu; }

echo "== 2. VM (x86_64, $(sysctl -n hw.ncpu) host CPUs)"
CPUS=$(( $(sysctl -n hw.ncpu) / 2 )); [ $CPUS -lt 2 ] && CPUS=2
if ! limactl list -q 2>/dev/null | grep -qx moosenet-builder; then
  cat > "$NODE/moosenet-builder.yaml" <<YAML
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
arch: "x86_64"
cpus: $CPUS
memory: "16GiB"
disk: "200GiB"
mounts:
  - location: "$NODE/exchange"
    writable: true
  - location: "$HERE/../linux"
    writable: false
containerd: { system: false, user: false }
YAML
  limactl create --name moosenet-builder "$NODE/moosenet-builder.yaml"
fi
limactl start moosenet-builder

echo "== 3. golden toolchain inside the VM (10-20 min; much longer under emulation)"
limactl shell moosenet-builder sudo bash "$HERE/../linux/bootstrap.sh"

echo "== 4. tray app + LaunchAgent"
cp "$BIN_SRC" "$NODE/bin/constellation-desktop"; chmod 0755 "$NODE/bin/constellation-desktop"
xattr -d com.apple.quarantine "$NODE/bin/constellation-desktop" 2>/dev/null || true
PL="$HOME/Library/LaunchAgents/io.moosenet.constellation-desktop.plist"
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.moosenet.constellation-desktop</string>
  <key>ProgramArguments</key><array><string>$NODE/bin/constellation-desktop</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
launchctl unload "$PL" 2>/dev/null || true
launchctl load "$PL"
echo "DONE. The tray icon is in the menu bar. Builds stay off until 'Builder enabled' is ticked."
