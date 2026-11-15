# Build the test package of the current commit, as CI does after a push (.github/workflows/package.yml),
# or locally: Mods\FarCryCoop (FarCryCoop.pak, ModDesc.txt, Steam\steam_api.dll when the repo has
# it), Bin32\FarCryCoopNet.asi (built here), Bin32\dinput8.dll (Ultimate ASI Loader, pinned by
# SHA-256), Bin32\FarCryCoop.bat and the notes. No launcher: the game's own Co-op menu starts and
# joins games (docs/specs/in-game-menu.md).
# Usage: pwsh games/far-cry/release/ci-package.ps1 [-Out dist] [-NoLoader]
param([string]$Out = 'dist', [switch]$NoLoader)
$ErrorActionPreference = 'Stop'
$far = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path # absolute: .NET (deploy.ps1's ZipFile) does not follow PowerShell's location
$stage = Join-Path $Out 'FarCryCoop'
$tmp = Join-Path $Out 'tmp'
foreach ($d in $stage, $tmp) {
  if (Test-Path $d) { Remove-Item -Recurse -Force $d }
  New-Item -ItemType Directory -Force $d | Out-Null
}
New-Item -ItemType Directory -Force "$stage\Bin32" | Out-Null

# the mod's scripts as the game reads them (Mods\FarCryCoop\FarCryCoop.pak)
& "$far\mod\deploy.ps1" -Game $stage | Out-Null

# FarCryCoopNet.asi: x86, no CRT (as tools\fcc\build-asi.cmd)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath }
if (-not $vs) { $vs = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools" }
$vcvars = "$vs\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvars)) { throw "no MSVC: $vcvars" }
$src = Resolve-Path "$far\asi\FarCryCoopNet.c"
$obj = Join-Path (Resolve-Path $tmp) 'FarCryCoopNet.obj'
$asi = Join-Path (Resolve-Path "$stage\Bin32") 'FarCryCoopNet.asi'
cmd /c "`"$vcvars`" x86 >nul && cl /nologo /c /O1 /GS- /W3 /Zl `"/Fo$obj`" `"$src`" && link /nologo /dll /nodefaultlib /entry:DllMain /safeseh:no /machine:x86 `"/out:$asi`" `"$obj`" kernel32.lib user32.lib winmm.lib"
if ($LASTEXITCODE) { throw 'ASI build failed' }

# the Ultimate ASI Loader (MIT) loads FarCryCoopNet.asi: the release's x86 build, checked by its hash
if (-not $NoLoader) {
  $tag = 'v9.7.4'
  $zip = Join-Path $tmp 'loader.zip'
  Invoke-WebRequest "https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/download/$tag/Ultimate-ASI-Loader-NoPDB.zip" -OutFile $zip
  $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($sha -ne '14b3a1ad018899571ac9aa01482977f3c6d49e6cba99f552d01c5acacd1315e1') { throw "ASI loader: unexpected SHA-256 $sha" }
  Expand-Archive $zip (Join-Path $tmp 'loader')
  # the x86 one (PE machine 0x14c): Far Cry is 32-bit and would not load an x64 build
  $dll = Get-ChildItem (Join-Path $tmp 'loader') -Recurse -Filter dinput8.dll | Where-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    [BitConverter]::ToUInt16($b, [BitConverter]::ToInt32($b, 0x3c) + 4) -eq 0x14c
  } | Select-Object -First 1
  if (-not $dll) { throw 'ASI loader: no x86 dinput8.dll in the archive' }
  Copy-Item $dll.FullName "$stage\Bin32\dinput8.dll"
  Invoke-WebRequest "https://raw.githubusercontent.com/ThirteenAG/Ultimate-ASI-Loader/$tag/license" -OutFile "$stage\Bin32\UltimateASILoader-LICENSE.txt"
}

# Steam inside the game (AppID 13520, FarCryCoopNet.asi) is on when steam_api.dll is in
# Mods\FarCryCoop\Steam: the Steamworks SDK's x86 redistributable, the version the ASI was built for
$steam = Join-Path $PSScriptRoot 'redist\steam_api.dll'
if (Test-Path $steam) {
  $sha = (Get-FileHash $steam -Algorithm SHA256).Hash.ToLower()
  if ($sha -ne '1cb8b7cb77923762d4e49b27e44295369a79e93b5d4282c5e840b268d28fe771') { throw "steam_api.dll: unexpected SHA-256 $sha" }
  New-Item -ItemType Directory -Force "$stage\Mods\FarCryCoop\Steam" | Out-Null
  Copy-Item $steam "$stage\Mods\FarCryCoop\Steam"
} else {
  Write-Warning 'no games/far-cry/release/redist/steam_api.dll: the package plays by IP and LAN only'
}

Set-Content "$stage\Bin32\FarCryCoop.bat" -Encoding ascii @(
  '@echo off', 'cd /d "%~dp0"',
  'start "" FarCry.exe -DEVMODE -MOD:FarCryCoop')
Copy-Item "$PSScriptRoot\TEST-BUILD.md", "$PSScriptRoot\TEST-BUILD.ru.md" $stage
$commit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (git rev-parse HEAD) }
Set-Content "$stage\VERSION.txt" -Encoding ascii "FarCryCoop test build, commit $commit"
Remove-Item -Recurse -Force $tmp
Get-ChildItem $stage -Recurse -File | Select-Object @{n = 'File'; e = { $_.FullName.Substring((Resolve-Path $stage).Path.Length + 1) } }, Length
