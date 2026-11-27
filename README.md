# WeCom KVM notification bridge V2.2.3

Forwards WeCom taskbar flash events and incoming voice/video call notifications from a Windows KVM guest to Ubuntu GNOME over VirtioFS. Incoming calls are detected using an observed window fingerprint: process `wxwork` or `wecom`, class `WXworkWindow`, no owner, visible non-minimized top-level non-child window, TOPMOST + TOOLWINDOW, and no `WS_EX_NOACTIVATE` flag. Does not inspect title, chat, caller, screen coordinates or database. Voice and video share one event type. This is an observed fingerprint, not a documented WeCom API; other windows may match, and future versions or disconnected sessions may differ.

## Changes in V2.2.3

- Fix false incoming-call notifications when hovering over the tag/emoji submenu in a conversation context menu.
- Exclude windows with `WS_EX_NOACTIVATE` (`0x08000000`). Observed real call windows use `0x00000088`; the false-positive popup uses `0x08000088`.
- Preserve 3-second taskbar flash grouping, the 200 ms call detection interval, per-window call deduplication and the existing event format. No new delay, size or position restriction is introduced.
- The Linux receiver and installation scripts are unchanged from V2.2.2.

## Upgrade from V2.2.2

Only the Windows listener needs to be replaced. On Ubuntu, from this repository or the extracted source archive:

```bash
cp windows/wecom-watch.ps1 ~/VMShare/WeComBridge/
```

Then stop and reinstall the Windows listener using the PowerShell commands below. No Ubuntu service restart is required for this incremental upgrade.

## Upgrade an earlier installation

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

Expected startup: `listener_started version=2.2.3`, `shell_hook_registered`, `popup_detection_enabled=False`, `call_detection_enabled=True interval_ms=200`, `flash_quiet_seconds=3`.

Ordinary flash grouping unchanged; calls bypass its cooldown and are reported once per visible PID/HWND, with retry on shared-file write failure while the window remains visible. Calls present when the listener starts are also detected. If a call window disappears and reappears, it can be reported again. Optional legacy popup heuristic remains disabled by default.

## Test

Ubuntu: `journalctl --user -u wecom-notify-bridge -f`

Windows: test the receiver directly (does not test window detection):

```powershell
Add-Content -LiteralPath 'Z:\WeComBridge\events.log' -Value "$(Get-Date -Format o)`tincoming_call" -Encoding UTF8
```

Expected Ubuntu notification: 企业微信 / 收到语音或视频通话邀请 (critical urgency requested; GNOME decides presentation).

Then test real voice/video calls separately; expect `call_detected`, `event_sent source=incoming_call`, `call_window_gone`. Test right-click, the emoji panel, the conversation context menu's tag/emoji submenu (no call notification expected), ordinary messages, and disconnected RDP separately. Existing timestamp-only events remain supported. The new receiver intentionally ignores historical events at startup, as before.

Validation: the V2.2.3 correction was verified by the maintainer in the Windows guest. The original V2.2.2 Linux event parsing and notification command were tested with a mocked subprocess. The window fingerprint remains version- and session-dependent; disconnected RDP behavior is not guaranteed. No additional network port, Windows admin permissions, or KVM changes are needed.

To roll back from V2.2.3, restore `windows/wecom-watch.ps1` from tag `v2.2.2` and reinstall the Windows listener. The Linux receiver does not need to change.

## Version history

- V2.2.3: exclude non-activating label/emoji popups from incoming-call detection.
- [V2.2.2](https://github.com/xht0708/wecom-kvm-bridge/releases/tag/v2.2.2): initial stable baseline, including incoming-call detection.
