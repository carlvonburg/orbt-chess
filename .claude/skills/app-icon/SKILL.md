---
name: app-icon
description: Change the ORBT app icon (apple/ORBT/AppIcon.icon) and every icon derived from it on Android, the desktop, the website and the welcome screen.
---
The Icon Composer document `apple/ORBT/AppIcon.icon` is the icon of every platform.

Keep it Icon Composer's:
- The `Assets/` SVGs are plain white shapes; their colors are fills in `icon.json`
  (`fill-specializations` for dark; the board's dark squares are the document fill).
- Glass, specular, shadows, tinted and clear come from the system, never baked into the SVGs.
- An open stroked path gets its chord filled, so draw strokes as filled outlines.

Render every appearance and look at each one:
```
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" apple/ORBT/AppIcon.icon --export-image --output-file out.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
```
Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

Then update what is derived from it:
- `Design/AppIcon-{light,dark,tinted}.svg` and the App icon section of `Design/COLORS.md`.
- `apple/ORBT/Assets.xcassets/AppIconImage.imageset`: ictool's Default rendition at 360 px.
- Android's adaptive icon, by hand: `android/androidApp/src/main/res/drawable/ic_launcher_{background,foreground,monochrome}.xml`
  (the cards and knight in the icon's 1024 units, its square the visible 72dp; also the splash).
- Desktop: `android/app/icons/orbt.ico` and `android/app/src/desktopMain/resources/orbt-icon.png`
  from `Design/AppIcon-light.svg` (how: `android/app/build.gradle.kts`); the MSI's
  `android/app/icons/installer-*.bmp` (`installer-bitmaps.ps1`); the MSIX's tiles
  `android/app/msix/Assets/*.png` (`android/app/msix/assets.ps1`).
- Website: `website/README.md` lists its icon files.
