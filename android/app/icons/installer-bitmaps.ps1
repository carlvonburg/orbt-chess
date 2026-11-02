# The Windows installer's pictures, in place of WiX's red CD: installer-dialog.bmp (493x312, the
# welcome and finish pages; their text starts at x 180, so the picture is the left 164 px) and
# installer-banner.bmp (493x58, the top of the other pages; their title is on the left). The app
# icon's indigo (Design/COLORS.md, App icon) and the icon itself, from orbt.ico.
# Run again after changing the icon: powershell -File installer-bitmaps.ps1 (Windows PowerShell).
Add-Type -AssemblyName System.Drawing
$here = $PSScriptRoot
$icon = (New-Object System.Drawing.Icon (Join-Path $here 'orbt.ico'), 256, 256).ToBitmap()

function New-Canvas($width, $height) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.InterpolationMode = 'HighQualityBicubic'
    $graphics.PixelOffsetMode = 'HighQuality'
    $graphics.Clear([System.Drawing.Color]::White)
    return $bitmap, $graphics
}

# The welcome and finish pages: an indigo panel on the left with the icon, white behind the text.
$bitmap, $graphics = New-Canvas 493 312
$panel = New-Object System.Drawing.Rectangle 0, 0, 164, 312
$gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush $panel,
    ([System.Drawing.ColorTranslator]::FromHtml('#6B64B8')),
    ([System.Drawing.ColorTranslator]::FromHtml('#3F3A8C')), 90.0
$graphics.FillRectangle($gradient, $panel)
$graphics.DrawImage($icon, 22, 86, 120, 120)
$graphics.Dispose()
$bitmap.Save((Join-Path $here 'installer-dialog.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)

# The other pages' banner: white, the icon on the right.
$bitmap, $graphics = New-Canvas 493 58
$graphics.DrawImage($icon, 433, 7, 44, 44)
$graphics.Dispose()
$bitmap.Save((Join-Path $here 'installer-banner.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)
