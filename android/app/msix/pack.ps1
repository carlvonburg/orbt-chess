# Packs Compose's app image (createDistributable) into an MSIX for the Microsoft Store, with the
# Windows SDK's makepri and makeappx. Unsigned: the Store signs it. Gradle runs it
# (`:app:packageMsix`); sign-for-testing.ps1 makes an installable copy.
param(
    [Parameter(Mandatory)] [string] $AppImage,
    [Parameter(Mandatory)] [string] $Output,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $IdentityName,
    [Parameter(Mandatory)] [string] $Publisher,
    [Parameter(Mandatory)] [string] $PublisherDisplayName
)
$ErrorActionPreference = 'Stop'

# The newest Windows SDK's x64 tools.
function SdkTool([string] $name) {
    $tool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$name" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } | Select-Object -Last 1
    if (-not $tool) { throw "No ${name}: install the Windows 10/11 SDK." }
    $tool.FullName
}

$staging = Join-Path ([System.IO.Path]::GetDirectoryName($Output)) 'msix-staging'
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
Copy-Item -Recurse $AppImage $staging
Copy-Item -Recurse (Join-Path $PSScriptRoot 'Assets') (Join-Path $staging 'Assets')

$escape = [System.Security.SecurityElement]
$manifest = (Get-Content -Raw (Join-Path $PSScriptRoot 'AppxManifest.xml')).
    Replace('@IDENTITY_NAME@', $escape::Escape($IdentityName)).
    Replace('@PUBLISHER@', $escape::Escape($Publisher)).
    Replace('@PUBLISHER_DISPLAY_NAME@', $escape::Escape($PublisherDisplayName)).
    Replace('@VERSION@', $Version)
[System.IO.File]::WriteAllText((Join-Path $staging 'AppxManifest.xml'), $manifest)

# resources.pri: how Windows picks the logo's target-size and unplated variants.
$makepri = SdkTool 'makepri.exe'
$config = Join-Path ([System.IO.Path]::GetDirectoryName($Output)) 'priconfig.xml'
& $makepri createconfig /cf $config /dq en-US /pv 10.0.0 /o
if ($LASTEXITCODE) { throw "makepri createconfig failed" }
& $makepri new /pr $staging /cf $config /of (Join-Path $staging 'resources.pri') /o
if ($LASTEXITCODE) { throw "makepri new failed" }

& (SdkTool 'makeappx.exe') pack /d $staging /p $Output /o
if ($LASTEXITCODE) { throw "makeappx pack failed" }
