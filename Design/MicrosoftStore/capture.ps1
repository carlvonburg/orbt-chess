# capture.ps1 <out.png> [-Width w -Height h]
# The ORBT Chess window as Windows draws it (its frame and title bar), for the Store's screenshots:
# moved to the top left and sized (once, with -Width and -Height, in physical pixels), brought to
# the front, then copied from the screen within DWM's frame bounds (without the invisible resize
# border). storeshots.py rounds its corners as Windows 11 does.
param([Parameter(Mandatory)][string]$Out, [int]$Width = 0, [int]$Height = 0)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
}
"@
[Win]::SetProcessDPIAware() | Out-Null

$window = Get-Process java, javaw, "ORBT Chess" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq "ORBT Chess" } | Select-Object -First 1
if (-not $window) { throw "no ORBT Chess window" }
$h = $window.MainWindowHandle
[Win]::ShowWindow($h, 9) | Out-Null  # SW_RESTORE

if ($Width -gt 0) {
    # The window rect includes the invisible border; size the visible frame to Width x Height.
    $outer = New-Object Win+RECT; $frame = New-Object Win+RECT
    [Win]::GetWindowRect($h, [ref]$outer) | Out-Null
    [Win]::DwmGetWindowAttribute($h, 9, [ref]$frame, 16) | Out-Null  # DWMWA_EXTENDED_FRAME_BOUNDS
    $dl = $frame.Left - $outer.Left; $dt = $frame.Top - $outer.Top
    $dw = ($outer.Right - $outer.Left) - ($frame.Right - $frame.Left)
    $dh = ($outer.Bottom - $outer.Top) - ($frame.Bottom - $frame.Top)
    [Win]::SetWindowPos($h, [IntPtr]::Zero, 40 - $dl, 0 - $dt, $Width + $dw, $Height + $dh, 0x0004) | Out-Null  # SWP_NOZORDER
}
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700

$r = New-Object Win+RECT
[Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
$w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hh))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"$Out ${w}x$hh"
