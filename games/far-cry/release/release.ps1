# Build the player archive: Mods\FarCryCoop (pak + ModDesc), Bin32\FarCryCoopNet.asi, the
# Ultimate ASI Loader (dinput8.dll, x86, verified download in Tools\ultimate-asi-loader-9.7.4)
# with its license, a launcher and the install notes in both languages.
# Usage: & games\far-cry\release\release.ps1 [-Version 0.2-beta] [-Out E:\FarCryCoop\Temp\release]
param([string]$Version = '0.2-beta', [string]$Out = 'E:\FarCryCoop\Temp\release')
$ErrorActionPreference = 'Stop'
. E:\FarCryCoop\env.ps1
$far = Split-Path $PSScriptRoot
$stage = Join-Path $Out "FarCryCoop-$Version"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force "$stage\Bin32" | Out-Null

& "$far\mod\deploy.ps1" -Game $stage | Out-Null           # -> $stage\Mods\FarCryCoop
& "$far\asi\build.ps1"
if ($LASTEXITCODE) { throw 'ASI build failed' }
Copy-Item 'E:\FarCryCoop\Temp\asi\FarCryCoopNet.asi' "$stage\Bin32"
Copy-Item 'E:\FarCryCoop\Tools\ultimate-asi-loader-9.7.4\dinput8.dll' "$stage\Bin32"
Copy-Item 'E:\FarCryCoop\Downloads\ultimate-asi-loader-9.7.4\LICENSE.txt' "$stage\Bin32\UltimateASILoader-LICENSE.txt"
# Steam runs inside the game (FarCryCoopNet.asi, as Far Cry, AppID 13520) when steam_api.dll is in
# Mods\FarCryCoop\Steam: x86, from the Steamworks SDK (Valve-signed copy in Downloads\steamworks).
# The old separate bridge (steam\FarCryCoopSteam.exe, Spacewar) is no longer shipped.
$steam = "$stage\Mods\FarCryCoop\Steam"
New-Item -ItemType Directory -Force $steam | Out-Null
Copy-Item 'E:\FarCryCoop\Downloads\steamworks\steam_api.dll' $steam
Set-Content "$stage\Bin32\FarCryCoop.bat" -Encoding ascii @(
  '@echo off', 'cd /d "%~dp0"',
  'start "" FarCry.exe -DEVMODE -MOD:FarCryCoop')
& "$far\launcher\build.ps1"
if ($LASTEXITCODE) { throw 'Launcher build failed' }
Copy-Item 'E:\FarCryCoop\Temp\launcher\FarCryCoopLauncher.exe' $stage # not Bin32: its version.dll crashes it
Copy-Item "$PSScriptRoot\INSTALL.md", "$PSScriptRoot\INSTALL.ru.md" $stage

$zip = Join-Path $Out "FarCryCoop-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Get-ChildItem $stage -Recurse -File | Select-Object @{n = 'File'; e = { $_.FullName.Substring($stage.Length + 1) } }, Length
Get-Item $zip | Select-Object FullName, Length
