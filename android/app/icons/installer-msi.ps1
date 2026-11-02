# Puts installer-dialog.bmp and installer-banner.bmp (installer-bitmaps.ps1) into a built MSI, in
# place of WiX's red CD. jpackage takes them from WiX's UI extension and Compose gives it no way to
# set WixUIDialogBmp and WixUIBannerBmp (it passes no --resource-dir when it packages its app
# image), so the packaged MSI's Binary table is rewritten instead (Windows Installer's own API, as
# the SDK's WiRunSQL.vbs). Run by :app:packageMsi; usage: installer-msi.ps1 <file.msi>.
param([Parameter(Mandatory)][string]$Msi)
$ErrorActionPreference = 'Stop'
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase((Resolve-Path $Msi).Path, 1) # msiOpenDatabaseModeTransact
$bitmaps = [ordered]@{ WixUI_Bmp_Dialog = 'installer-dialog.bmp'; WixUI_Bmp_Banner = 'installer-banner.bmp' }
foreach ($name in $bitmaps.Keys) {
    $find = $database.OpenView("SELECT ``Name`` FROM ``Binary`` WHERE ``Name`` = '$name'")
    $find.Execute()
    $found = $find.Fetch()
    $find.Close()
    if (-not $found) { throw "$Msi has no ${name}: WiX's UI changed, see installer-msi.ps1" }
    $record = $installer.CreateRecord(1)
    $record.SetStream(1, (Join-Path $PSScriptRoot $bitmaps[$name]))
    $update = $database.OpenView("UPDATE ``Binary`` SET ``Data`` = ? WHERE ``Name`` = '$name'")
    $update.Execute($record)
    $update.Close()
}
$database.Commit()
