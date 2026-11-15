# redist

`steam_api.dll` — the x86 Steam API from Valve's Steamworks SDK v1.65 (`redistributable_bin`), unchanged
(SHA-256 `1cb8b7cb77923762d4e49b27e44295369a79e93b5d4282c5e840b268d28fe771`, checked by `ci-package.ps1`).
Valve's redistributable, shipped as the Steamworks SDK allows; Far Cry 1.4 itself has no Steam API.
The package puts it into `Mods\FarCryCoop\Steam`, where `FarCryCoopNet` looks for it.
To update: copy the DLL from a newer SDK, update the hash in `ci-package.ps1` and here, re-run the `steam` area.
