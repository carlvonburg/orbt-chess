# The MSIX package's tile and Start menu images, rendered from the app icon's largest frame in
# ../icons/orbt.ico (Design/AppIcon-light.svg, as the MSI's). Run again when the icon changes and
# commit the PNGs: powershell -ExecutionPolicy Bypass -File android/app/msix/assets.ps1
Add-Type -AssemblyName System.Drawing
$here = $PSScriptRoot
$icon = New-Object System.Drawing.Icon((Join-Path $here '..\icons\orbt.ico'), 256, 256)
$source = $icon.ToBitmap()

# The icon, `size` pixels square, centered on a transparent `width` × `height` image.
function Render([string] $name, [int] $width, [int] $height, [int] $size) {
    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($source, [int](($width - $size) / 2), [int](($height - $size) / 2), $size, $size)
    $g.Dispose()
    $bitmap.Save((Join-Path $here "Assets\$name"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

New-Item -ItemType Directory -Force (Join-Path $here 'Assets') | Out-Null
# Tiles leave a margin around the icon, as Windows' own; the small logo and its target sizes
# (taskbar, Start's list, Explorer) fill their square. "unplated" variants are drawn without a
# tile behind them, which the taskbar uses.
Render 'StoreLogo.png' 50 50 50
Render 'Square150x150Logo.png' 150 150 100
Render 'Wide310x150Logo.png' 310 150 100
Render 'Square44x44Logo.png' 44 44 44
foreach ($size in 16, 24, 32, 48, 256) {
    Render "Square44x44Logo.targetsize-$size.png" $size $size $size
    Render "Square44x44Logo.targetsize-${size}_altform-unplated.png" $size $size $size
}
$source.Dispose()
$icon.Dispose()
