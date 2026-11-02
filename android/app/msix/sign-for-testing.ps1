# Signs a copy of the MSIX with a self-signed certificate, to install it on this PC
# (Add-AppxPackage) before the Store signs the real one. The certificate's subject is the
# package's Publisher; it lives in the current user's store and is trusted on this PC only
# (asks for administrator once, to add it to Trusted People). Never commit it or its key.
#   powershell -ExecutionPolicy Bypass -File android/app/msix/sign-for-testing.ps1
param(
    [string] $Msix = (Join-Path $PSScriptRoot '..\build\compose\binaries\main\msix\ORBT-Chess-windows-x64.msix')
)
$ErrorActionPreference = 'Stop'

$manifest = [xml](Get-Content -Raw (Join-Path $PSScriptRoot '..\build\compose\binaries\main\msix\msix-staging\AppxManifest.xml'))
$publisher = $manifest.Package.Identity.Publisher

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $publisher -and $_.FriendlyName -eq 'ORBT Chess MSIX test' } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -FriendlyName 'ORBT Chess MSIX test' `
        -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cert.Thumbprint
if (-not $trusted) {
    $cer = Join-Path $env:TEMP 'orbt-msix-test.cer'
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command Import-Certificate -FilePath '$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    Remove-Item $cer
}

$signed = [System.IO.Path]::ChangeExtension($Msix, '.test-signed.msix')
Copy-Item $Msix $signed -Force
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } | Select-Object -Last 1
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint /s My $signed
if ($LASTEXITCODE) { throw "signtool failed" }
Write-Host "Signed: $signed"
Write-Host "Install: Add-AppxPackage '$signed'"
