param(
    [string]$ShareRoot = 'Z:\WeComBridge',
    [switch]$DebugFlash,
    [double]$FlashQuietSeconds = 3.0,
    [switch]$EnablePopupDetection
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'WeComNotifyBridge'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$log = Join-Path $stateDir 'bridge.log'
$eventFile = Join-Path $ShareRoot 'events.log'

# Only one listener per interactive session. The hook requires a Windows desktop session.
$created = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\WeComNotifyBridge', [ref]$created)
if (-not $created) {
    $mutex.Dispose()
    exit 0
}

$hook = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -ReferencedAssemblies @('System', 'System.Windows.Forms', 'System.Drawing') -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class WeComWindowProbe {
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int maxCount);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    private static bool IsIncomingCallWindow(IntPtr hwnd) {
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return false;
        if (!IsWeComProcess(ProcessName(hwnd))) return false;
        var name = new StringBuilder(256);
        if (GetClassName(hwnd, name, name.Capacity) == 0) return false;
        if (!String.Equals(name.ToString(), "WXworkWindow", StringComparison.OrdinalIgnoreCase)) return false;
        if (GetWindow(hwnd, 4) != IntPtr.Zero) return false; // GW_OWNER
        uint style = unchecked((uint)GetWindowLong(hwnd, -16));
        uint exstyle = unchecked((uint)GetWindowLong(hwnd, -20));
        // Observed call popup: top-level, TOPMOST | TOOLWINDOW; not a child.
        // Exclude non-activating menu popups (observed label picker: 0x08000088).
        // Observed incoming call popup: 0x00000088.
        const uint WS_EX_NOACTIVATE = 0x08000000u;
        return (style & 0x40000000u) == 0 &&
               (exstyle & 0x88u) == 0x88u &&
               (exstyle & WS_EX_NOACTIVATE) == 0;
    }
    public static string[] GetCallHandles() {
        var items = new List<string>();
        EnumWindows((hwnd, _) => {
            if (IsIncomingCallWindow(hwnd)) {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid != 0) items.Add(pid.ToString() + ":" + hwnd.ToInt64().ToString("X"));
            }
            return true;
        }, IntPtr.Zero);
        return items.ToArray();
    }

    public static string ForegroundProcessName() {
        return ProcessName(GetForegroundWindow());
    }

    public static string ProcessName(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return "unknown";
        try {
            using (Process p = Process.GetProcessById((int)pid)) {
                return p.ProcessName.ToLowerInvariant();
            }
        } catch { return "unknown"; }
    }
    public static bool IsWeComProcess(string processName) {
        return processName == "wxwork" || processName == "wecom";
    }
    // Original popup heuristic preserved. Window handles only; no message text/titles.
    public static string[] GetPopupHandles() {
        var items = new List<string>();
        int left = GetSystemMetrics(76);
        int top = GetSystemMetrics(77);
        int width = GetSystemMetrics(78);
        int height = GetSystemMetrics(79);
        if (width < 500 || height < 400) return items.ToArray();
        EnumWindows((hwnd, _) => {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            Rect r;
            if (!GetWindowRect(hwnd, out r)) return true;
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            if (w < 120 || w > 850 || h < 45 || h > 450) return true;
            if (r.Left < left + width * 0.40) return true;
            if (r.Top < top + height * 0.45) return true;
            if (r.Right > left + width + 50) return true;
            if (r.Bottom > top + height + 50) return true;
            if (IsWeComProcess(ProcessName(hwnd)) && !IsIncomingCallWindow(hwnd)) {
                items.Add(hwnd.ToInt64().ToString("X"));
            }
            return true;
        }, IntPtr.Zero);
        return items.ToArray();
    }
}

// Receives taskbar flash notifications without injecting into WeCom or Explorer.
// The SHELLHOOK message API is not guaranteed on all Windows versions/sessions.
public sealed class WeComShellHook : NativeWindow, IDisposable {
    private const long HSHELL_FLASH = 0x8006;
    private readonly uint messageId;
    private readonly ConcurrentQueue<IntPtr> queue = new ConcurrentQueue<IntPtr>();
    private bool registered;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessage(string text);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterShellHookWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DeregisterShellHookWindow(IntPtr hwnd);

    public WeComShellHook() {
        messageId = RegisterWindowMessage("SHELLHOOK");
        if (messageId == 0) throw new InvalidOperationException("RegisterWindowMessage failed");
        CreateParams cp = new CreateParams();
        cp.Caption = "WeComNotifyBridgeShellHook";
        CreateHandle(cp);
        registered = RegisterShellHookWindow(Handle);
        if (!registered) {
            int code = Marshal.GetLastWin32Error();
            DestroyHandle();
            throw new InvalidOperationException("RegisterShellHookWindow failed: " + code);
        }
    }
    protected override void WndProc(ref Message m) {
        if ((uint)m.Msg == messageId && m.WParam.ToInt64() == HSHELL_FLASH) {
            queue.Enqueue(m.LParam);
        }
        base.WndProc(ref m);
    }
    public IntPtr[] Drain() {
        var result = new List<IntPtr>();
        IntPtr item;
        while (queue.TryDequeue(out item)) result.Add(item);
        return result.ToArray();
    }
    public void Dispose() {
        if (Handle != IntPtr.Zero) {
            if (registered) DeregisterShellHookWindow(Handle);
            registered = false;
            DestroyHandle();
        }
    }
}
'@

    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) listener_started version=2.2.3" -Encoding UTF8
    try {
        $hook = [WeComShellHook]::new()
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) shell_hook_registered" -Encoding UTF8
    } catch {
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) shell_hook_unavailable $($_.Exception.Message)" -Encoding UTF8
        # Only use the optional popup fallback when explicitly enabled.
    }

    $previous = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($EnablePopupDetection) {
        foreach ($h in [WeComWindowProbe]::GetPopupHandles()) { [void]$previous.Add($h) }
    }
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) popup_detection_enabled=$($EnablePopupDetection.IsPresent)" -Encoding UTF8
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) call_detection_enabled=True interval_ms=200" -Encoding UTF8
    if ($null -eq $hook) {
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) flash_detection_unavailable; call detection continues" -Encoding UTF8
    }
    $callReported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $callRetryAt = @{}
    $nextCallCheck = [DateTime]::UtcNow
    # A flash request may produce multiple HSHELL_FLASH messages (one per blink).
    # Treat messages for the same hwnd as one continuous burst until a quiet gap.
    $lastFlashByWindow = @{}
    $script:lastSent = [DateTime]::MinValue
    $nextPopupCheck = [DateTime]::UtcNow
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) flash_quiet_seconds=$FlashQuietSeconds" -Encoding UTF8

    function Send-BridgeEvent {
        param([string]$Source)
        $isCall = $Source -eq 'incoming_call'
        # Only coalesce nearly simultaneous popup + flash reports of the same UI event.
        # Do NOT suppress all new incoming events for 15 seconds as in V2.1.
        $elapsed = ([DateTime]::UtcNow - $script:lastSent).TotalSeconds
        if ((-not $isCall) -and ($elapsed -lt 0.75)) {
            if ($DebugFlash) {
                Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) event_coalesced source=$Source" -Encoding UTF8
            }
            return $false
        }
        try {
            if (Test-Path -LiteralPath $ShareRoot -PathType Container) {
                $eventLine = Get-Date -Format o
                if ($isCall) { $eventLine += "`tincoming_call" }
                Add-Content -LiteralPath $eventFile -Value $eventLine -Encoding UTF8
                if (-not $isCall) { $script:lastSent = [DateTime]::UtcNow }
                Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) event_sent source=$Source" -Encoding UTF8
                return $true
            } else {
                Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) share_not_ready source=$Source" -Encoding UTF8
            }
        } catch {
            Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) write_failed source=$Source error=$($_.Exception.Message)" -Encoding UTF8
        }
        return $false
    }

    while ($true) {
        # Pump Windows messages so the invisible NativeWindow receives HSHELL_FLASH.
        [System.Windows.Forms.Application]::DoEvents()
        if ($null -ne $hook) {
            foreach ($hwnd in $hook.Drain()) {
                $name = [WeComWindowProbe]::ProcessName($hwnd)
                if ([WeComWindowProbe]::IsWeComProcess($name)) {
                    $now = [DateTime]::UtcNow
                    $key = $hwnd.ToInt64().ToString('X')
                    $newBurst = (-not $lastFlashByWindow.ContainsKey($key)) -or
                        (($now - $lastFlashByWindow[$key]).TotalSeconds -ge $FlashQuietSeconds)
                    $lastFlashByWindow[$key] = $now
                    if ($newBurst) {
                        $foreground = [WeComWindowProbe]::ForegroundProcessName()
                        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) shell_flash_detected process=$name burst=start hwnd=$key foreground=$foreground" -Encoding UTF8
                        [void](Send-BridgeEvent -Source 'shell_flash')
                    } elseif ($DebugFlash) {
                        Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) flash_pulse_merged process=$name" -Encoding UTF8
                    }
                } elseif ($DebugFlash) {
                    # Diagnostic only: process name, not titles/notification contents.
                    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) shell_flash_other process=$name" -Encoding UTF8
                }
            }
        }

        if ([DateTime]::UtcNow -ge $nextCallCheck) {
            $currentCalls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($key in [WeComWindowProbe]::GetCallHandles()) {
                [void]$currentCalls.Add($key)
                if ($callReported.Contains($key)) { continue }
                if ($callRetryAt.ContainsKey($key) -and [DateTime]::UtcNow -lt $callRetryAt[$key]) { continue }
                if (-not $callRetryAt.ContainsKey($key)) {
                    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) call_detected key=$key class=WXworkWindow" -Encoding UTF8
                }
                if (Send-BridgeEvent -Source 'incoming_call') {
                    [void]$callReported.Add($key)
                    $callRetryAt.Remove($key)
                } else {
                    $callRetryAt[$key] = [DateTime]::UtcNow.AddSeconds(1)
                }
            }
            foreach ($key in @($callReported)) {
                if (-not $currentCalls.Contains($key)) {
                    [void]$callReported.Remove($key)
                    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) call_window_gone key=$key" -Encoding UTF8
                }
            }
            foreach ($key in @($callRetryAt.Keys)) {
                if (-not $currentCalls.Contains($key)) { $callRetryAt.Remove($key) }
            }
            $nextCallCheck = [DateTime]::UtcNow.AddMilliseconds(200)
        }

        if ($EnablePopupDetection -and ([DateTime]::UtcNow -ge $nextPopupCheck)) {
            $current = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($h in [WeComWindowProbe]::GetPopupHandles()) {
                [void]$current.Add($h)
                if (-not $previous.Contains($h)) { [void](Send-BridgeEvent -Source 'popup') }
            }
            $previous = $current
            $nextPopupCheck = [DateTime]::UtcNow.AddMilliseconds(650)
        }
        Start-Sleep -Milliseconds 80
    }
} catch {
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) listener_error: $($_.Exception.Message)" -Encoding UTF8
    throw
} finally {
    if ($null -ne $hook) { $hook.Dispose() }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
