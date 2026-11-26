# WeCom KVM notification bridge V2.2.2

Based on the V2.2.1 Windows listener and V2.2 Linux receiver. Adds an incoming-call event based on two observed windows: process `wxwork`, class `WXworkWindow`, no owner, visible non-minimized top-level window, TOPMOST + TOOLWINDOW. Does not inspect title, chat, caller, screen coordinates or database. Voice and video share one event type. This is an observed fingerprint, not a documented WeCom API; other windows may match, and future versions or disconnected sessions may differ.

## Upgrade an existing installation

Ubuntu (run from this extracted directory):

```bash
cp windows/wecom-watch.ps1 windows/install-windows.ps1 ~/VMShare/WeComBridge/
cp linux/host_listener.py ~/.local/lib/wecom-bridge/host_listener.py
systemctl --user restart wecom-notify-bridge.service
```

Windows PowerShell (stop old listener before reinstall):

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'wecom-watch\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'Z:\WeComBridge\install-windows.ps1' -ShareDrive 'Z:'
Get-Content "$env:LOCALAPPDATA\WeComNotifyBridge\bridge.log" -Tail 10
```

Expected startup: `listener_started version=2.2.2`, `shell_hook_registered`, `popup_detection_enabled=False`, `call_detection_enabled=True interval_ms=200`, `flash_quiet_seconds=3`.

Ordinary flash grouping unchanged; calls bypass its cooldown and are reported once per visible PID/HWND, with retry on shared-file write failure while the window remains visible. Calls present when the listener starts are also detected. If a call window disappears and reappears, it can be reported again. Optional legacy popup heuristic remains disabled by default.

## Test

Ubuntu: `journalctl --user -u wecom-notify-bridge -f`

Windows: test the receiver directly (does not test window detection):

```powershell
Add-Content -LiteralPath 'Z:\WeComBridge\events.log' -Value "$(Get-Date -Format o)`tincoming_call" -Encoding UTF8
```

Expected Ubuntu notification: 企业微信 / 收到语音或视频通话邀请 (critical urgency requested; GNOME decides presentation).

Then test real voice/video calls separately; expect `call_detected`, `event_sent source=incoming_call`, `call_window_gone`. Test right-click and emoji panel, ordinary messages, and disconnected RDP separately. Existing timestamp-only events remain supported. The new receiver intentionally ignores historical events at startup, as before.

Validation: Linux event parsing and notification command tested with mocked subprocess; PowerShell UTF-8 BOM and shell installer syntax checked. Windows runtime/Win32 behavior and actual GNOME rendering not tested here. No additional network port, Windows admin permissions, or KVM changes needed. To roll back restore V2.2.1 Windows script and V2.2 Linux receiver, restart service and reinstall listener.
