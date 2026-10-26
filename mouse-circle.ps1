# 設定値（ここを変更してください）
$Radius = 100       # px
$StepsPerCircle = 120
$IntervalMs = 20
$MaxDurationMinutes = 60

$ErrorActionPreference = 'Stop'

if ($Radius -le 0 -or $StepsPerCircle -lt 3 -or $IntervalMs -lt 1 -or $MaxDurationMinutes -le 0) {
    throw '設定値は Radius > 0、StepsPerCircle >= 3、IntervalMs >= 1、MaxDurationMinutes > 0 にしてください。'
}
$MaxDurationMs = [long]$MaxDurationMinutes * 60000

# Add-Type は同じ PowerShell セッションで再実行しても型を再定義しない。
if (-not ('MouseCircle.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace MouseCircle
{
    public static class Native
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int VK_ESCAPE = 0x1B;
        private const int WM_MOUSEMOVE = 0x0200;
        private const int WM_LBUTTONDOWN = 0x0201;
        private const int WM_RBUTTONDOWN = 0x0204;
        private const uint LLMHF_INJECTED = 1;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
        private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        private const uint QS_ALLINPUT = 0x04FF;
        private const uint MWMO_INPUTAVAILABLE = 0x0004;
        private const int SM_XVIRTUALSCREEN = 76;
        private const int SM_YVIRTUALSCREEN = 77;
        private const int SM_CXVIRTUALSCREEN = 78;
        private const int SM_CYVIRTUALSCREEN = 79;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt;
            public uint mouseData, flags, time;
            public UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public uint vkCode, scanCode, flags, time;
            public UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public MOUSEINPUT mi;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam, lParam;
            public uint time;
            public POINT pt;
            public uint lPrivate;
        }

        private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        private static readonly HookProc MouseCallback = OnMouse;
        private static readonly HookProc KeyboardCallback = OnKeyboard;
        private static int stopReason;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string moduleName);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint MsgWaitForMultipleObjectsEx(uint count, IntPtr handles, uint milliseconds, uint wakeMask, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PeekMessage(out MSG message, IntPtr window, uint min, uint max, uint remove);
        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG message);
        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG message);

        private static IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int message = unchecked((int)wParam.ToInt64());
                if (message == WM_LBUTTONDOWN) Interlocked.CompareExchange(ref stopReason, 2, 0);
                else if (message == WM_RBUTTONDOWN) Interlocked.CompareExchange(ref stopReason, 3, 0);
                else if (message == WM_MOUSEMOVE)
                {
                    MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    // SendInput による自身の移動は注入イベント。物理移動だけを停止条件にする。
                    if ((data.flags & LLMHF_INJECTED) == 0)
                        Interlocked.CompareExchange(ref stopReason, 4, 0);
                }
            }
            return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }

        private static IntPtr OnKeyboard(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int message = unchecked((int)wParam.ToInt64());
                if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)
                {
                    KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    if (data.vkCode == VK_ESCAPE) Interlocked.CompareExchange(ref stopReason, 1, 0);
                }
            }
            return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }

        // 返り値: 1=Esc, 2=左クリック, 3=右クリック, 4=物理移動, 5=WM_QUIT, 6=時間制限
        public static int Run(int radius, int steps, int intervalMs, long maxDurationMs)
        {
            POINT center;
            if (!GetCursorPos(out center)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetCursorPos failed");

            int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (width < 2 || height < 2) throw new InvalidOperationException("Virtual desktop size is invalid.");

            stopReason = 0;
            IntPtr module = GetModuleHandle(null);
            IntPtr mouseHook = IntPtr.Zero;
            IntPtr keyboardHook = IntPtr.Zero;
            try
            {
                mouseHook = SetWindowsHookEx(WH_MOUSE_LL, MouseCallback, module, 0);
                if (mouseHook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Mouse hook installation failed");
                keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardCallback, module, 0);
                if (keyboardHook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Keyboard hook installation failed");

                Stopwatch timer = Stopwatch.StartNew();
                long nextTick = 0;
                int step = 0;
                while (Volatile.Read(ref stopReason) == 0)
                {
                    MSG message;
                    while (PeekMessage(out message, IntPtr.Zero, 0, 0, 1))
                    {
                        if (message.message == 0x0012) Interlocked.CompareExchange(ref stopReason, 5, 0);
                        if (Volatile.Read(ref stopReason) != 0) break;
                        TranslateMessage(ref message);
                        DispatchMessage(ref message);
                    }
                    if (Volatile.Read(ref stopReason) != 0) break;

                    long now = timer.ElapsedMilliseconds;
                    if (now >= maxDurationMs)
                    {
                        Interlocked.CompareExchange(ref stopReason, 6, 0);
                        break;
                    }
                    if (now < nextTick)
                    {
                        uint wait = (uint)Math.Min(Math.Min(nextTick - now, maxDurationMs - now), int.MaxValue);
                        uint result = MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                        if (result == 0xFFFFFFFF) throw new Win32Exception(Marshal.GetLastWin32Error(), "Message wait failed");
                        continue;
                    }

                    double angle = 2.0 * Math.PI * step / steps;
                    int x = center.X + (int)Math.Round(radius * Math.Cos(angle));
                    int y = center.Y + (int)Math.Round(radius * Math.Sin(angle));
                    x = Math.Max(left, Math.Min(left + width - 1, x));
                    y = Math.Max(top, Math.Min(top + height - 1, y));
                    INPUT input = new INPUT();
                    input.type = 0;
                    input.mi.dx = (int)Math.Round((double)(x - left) * 65535 / (width - 1));
                    input.mi.dy = (int)Math.Round((double)(y - top) * 65535 / (height - 1));
                    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
                    input.mi.dwExtraInfo = new UIntPtr(0x4D434952); // MCIR
                    if (SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed");

                    step = (step + 1) % steps;
                    nextTick += intervalMs;
                    if (nextTick < timer.ElapsedMilliseconds) nextTick = timer.ElapsedMilliseconds + intervalMs;
                }
                return Volatile.Read(ref stopReason);
            }
            finally
            {
                if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
                if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
                GC.KeepAlive(KeyboardCallback);
                GC.KeepAlive(MouseCallback);
            }
        }
    }
}
'@
}

Write-Host "円運動を開始します（半径 ${Radius}px、${StepsPerCircle}分割、間隔 ${IntervalMs}ms）。"
Write-Host "停止方法: Esc / 左クリック / 右クリック / 物理的なマウス移動 / ${MaxDurationMinutes}分経過"

try {
    $reason = [MouseCircle.Native]::Run($Radius, $StepsPerCircle, $IntervalMs, $MaxDurationMs)
    $description = switch ($reason) {
        1 { 'Escキー' }
        2 { '左クリック' }
        3 { '右クリック' }
        4 { '物理的なマウス移動' }
        5 { 'メッセージループの終了' }
        6 { '時間制限' }
        default { "不明 ($reason)" }
    }
    Write-Host "停止理由: $description"
}
catch {
    Write-Error "エラーにより停止しました: $_"
    exit 1
}
