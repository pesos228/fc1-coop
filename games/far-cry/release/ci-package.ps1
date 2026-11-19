# Build the test package of the current commit, as CI does after a push (.github/workflows/package.yml),
# or locally. The package is one folder, FarCryCoop, to drop into <game>\Mods: FarCryCoop.pak,
# ModDesc.txt, Bin32\CryGame.dll (FarCryCoopNet built here: the game loads a mod's own CryGame.dll
# with -MOD, and this one loads the game's and hooks it; nothing goes into the game's Bin32) and
# Steam\steam_api.dll when the repo has it, plus the notes.
# Usage: pwsh games/far-cry/release/ci-package.ps1 [-Out dist]
param([string]$Out = 'dist')
$ErrorActionPreference = 'Stop'
$far = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path # absolute: .NET (deploy.ps1's ZipFile) does not follow PowerShell's location
$pkg = Join-Path $Out 'package'
$stage = Join-Path $pkg 'FarCryCoop' # <game>\Mods\FarCryCoop
$tmp = Join-Path $Out 'tmp'
foreach ($d in $pkg, $tmp) {
  if (Test-Path $d) { Remove-Item -Recurse -Force $d }
  New-Item -ItemType Directory -Force $d | Out-Null
}
New-Item -ItemType Directory -Force "$stage\Bin32" | Out-Null

# one version: COOP_VERSION (Scripts/COOP/Version.lua, the connect check) and the Mods menu's
$mod = Join-Path $far 'mod\FarCryCoop'
$ver = [regex]::Match((Get-Content -Raw "$mod\Scripts\COOP\Version.lua"), 'COOP_VERSION\s*=\s*"([^"]+)"').Groups[1].Value
$desc = [regex]::Match((Get-Content -Raw "$mod\ModDesc.txt"), '_Version_\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ver -or $ver -ne $desc) { throw "COOP_VERSION '$ver' and ModDesc.txt _Version_ '$desc' differ" }

# the mod's scripts as the game reads them (FarCryCoop.pak); deploy.ps1 writes <game>\Mods\FarCryCoop
$game = Join-Path $tmp 'game'
& "$far\mod\deploy.ps1" -Game $game | Out-Null
Copy-Item "$game\Mods\FarCryCoop\*" $stage

# FarCryCoopNet: x86, no CRT (as tools\fcc\build-asi.cmd), as the mod's Bin32\CryGame.dll
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath }
if (-not $vs) { $vs = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools" }
$vcvars = "$vs\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvars)) { throw "no MSVC: $vcvars" }
$src = Resolve-Path "$far\asi\FarCryCoopNet.c"
$obj = Join-Path (Resolve-Path $tmp) 'FarCryCoopNet.obj'
$asi = Join-Path (Resolve-Path "$stage\Bin32") 'CryGame.dll'
cmd /c "`"$vcvars`" x86 >nul && cl /nologo /c /O1 /GS- /W3 /Zl `"/Fo$obj`" `"$src`" && link /nologo /dll /nodefaultlib /entry:DllMain /safeseh:no /machine:x86 `"/implib:$tmp\CryGame.lib`" `"/out:$asi`" `"$obj`" kernel32.lib user32.lib winmm.lib"
if ($LASTEXITCODE) { throw 'ASI build failed' }

# Steam inside the game (AppID 13520, FarCryCoopNet.asi) is on when steam_api.dll is in
# Mods\FarCryCoop\Steam: the Steamworks SDK's x86 redistributable, the version the ASI was built for
$steam = Join-Path $PSScriptRoot 'redist\steam_api.dll'
if (Test-Path $steam) {
  $sha = (Get-FileHash $steam -Algorithm SHA256).Hash.ToLower()
  if ($sha -ne '1cb8b7cb77923762d4e49b27e44295369a79e93b5d4282c5e840b268d28fe771') { throw "steam_api.dll: unexpected SHA-256 $sha" }
  New-Item -ItemType Directory -Force "$stage\Steam" | Out-Null
  Copy-Item $steam "$stage\Steam"
} else {
  Write-Warning 'no games/far-cry/release/redist/steam_api.dll: the package plays by IP and LAN only'
}

Copy-Item "$PSScriptRoot\TEST-BUILD.md", "$PSScriptRoot\TEST-BUILD.ru.md" $pkg
$commit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (git rev-parse HEAD) }
Set-Content "$stage\VERSION.txt" -Encoding ascii "FarCryCoop test build, commit $commit"
Remove-Item -Recurse -Force $tmp
Get-ChildItem $pkg -Recurse -File | Select-Object @{n = 'File'; e = { $_.FullName.Substring((Resolve-Path $pkg).Path.Length + 1) } }, Length
