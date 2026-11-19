# Pack games/far-cry/mod/FarCryCoop into <game>\Mods\FarCryCoop\FarCryCoop.pak (zip with forward-slash paths).
param([string]$Game = 'D:\SteamLibrary\steamapps\common\FarCry')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$src = Join-Path $PSScriptRoot 'FarCryCoop'
$dst = Join-Path $Game 'Mods\FarCryCoop'
New-Item -ItemType Directory -Force $dst | Out-Null
$pak = Join-Path $dst 'FarCryCoop.pak'
if (Test-Path $pak) { Remove-Item $pak }
$zip = [System.IO.Compression.ZipFile]::Open($pak, 'Create')
try {
  Get-ChildItem (Join-Path $src 'Scripts') -Recurse -File | ForEach-Object {
    $entry = $_.FullName.Substring($src.Length + 1).Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry) | Out-Null
  }
} finally { $zip.Dispose() }
# ModDesc.txt and ModPreview.dds: the title, author, version and picture in the game's Mods menu
Copy-Item (Join-Path $src 'ModDesc.txt') $dst -Force
Copy-Item (Join-Path $src 'ModPreview.dds') $dst -Force
Get-ChildItem $dst | Select-Object Name, Length
