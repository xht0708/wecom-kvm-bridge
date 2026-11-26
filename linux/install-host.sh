#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARE="${1:-$HOME/VMShare}"
mkdir -p "$SHARE/WeComBridge" "$HOME/.local/lib/wecom-bridge" "$HOME/.config/systemd/user"
touch "$SHARE/WeComBridge/events.log"
cp "$BASE/linux/host_listener.py" "$HOME/.local/lib/wecom-bridge/host_listener.py"
cp "$BASE/windows/wecom-watch.ps1" "$BASE/windows/install-windows.ps1" "$BASE/windows/test-wecom-flash.ps1" "$SHARE/WeComBridge/"

# Put a single literal path into systemd's ExecStart, supporting standard home folder.
# For alternate paths, edit the service unit's final argument after installation.
cat > "$HOME/.config/systemd/user/wecom-notify-bridge.service" <<EOF
[Unit]
Description=WeCom KVM notifications from VirtioFS to GNOME

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.local/lib/wecom-bridge/host_listener.py "$SHARE/WeComBridge/events.log"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

if ! command -v notify-send >/dev/null; then
  echo 'Missing notify-send: install it with sudo apt install libnotify-bin'
  exit 1
fi
systemctl --user daemon-reload
systemctl --user enable --now wecom-notify-bridge.service

echo "Host listener installed; Windows files copied to $SHARE/WeComBridge"
echo 'Test GNOME notification: notify-send "企业微信" "测试通知"'
echo 'Test with Windows: Add-Content -LiteralPath "Z:\WeComBridge\events.log" -Value (Get-Date -Format o) -Encoding UTF8'
echo 'Change Z: to your actual Windows VirtioFS drive letter.'
