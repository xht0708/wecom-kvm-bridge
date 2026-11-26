# Diagnostic only: asks Windows to flash the visible WeCom taskbar button.
# This does NOT simulate an incoming message or access any chat content.
$ErrorActionPreference = 'Stop'
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class WeComFlashTest {
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FlashInfo info);
    public static IntPtr FindWindow() {
        IntPtr best = IntPtr.Zero;
        long largest = 0;
        EnumWindows((hwnd, _) => {
            if (!IsWindowVisible(hwnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == 0) return true;
            try {
                using (var p = Process.GetProcessById((int)pid)) {
                    string name = p.ProcessName.ToLowerInvariant();
                    if (name != "wxwork" && name != "wecom") return true;
                }
            } catch { return true; }
            Rect r;
            if (!GetWindowRect(hwnd, out r)) return true;
            long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (area > largest) { largest = area; best = hwnd; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    public static void RequestFlash(IntPtr hwnd) {
        FlashInfo f = new FlashInfo();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FlashInfo));
        f.hwnd = hwnd;
        f.dwFlags = 3; // FLASHW_ALL
        f.uCount = 3;
        f.dwTimeout = 0;
        // Return value represents the old caption state; not a success flag.
        FlashWindowEx(ref f);
    }
}
'@
$hwnd = [WeComFlashTest]::FindWindow()
if ($hwnd -eq [IntPtr]::Zero) {
    throw '没有找到可见的 WXWork/WeCom 主窗口。请先打开企业微信主界面，然后重试。'
}
[WeComFlashTest]::RequestFlash($hwnd)
Write-Host "已对企业微信窗口 $hwnd 请求闪烁；请检查 bridge.log 中的 shell_flash_detected 和 event_sent。"
