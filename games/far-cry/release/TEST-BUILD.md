# FarCryCoop test build

Built automatically from the latest commit after a push (`VERSION.txt`). Not a release: expect bugs. There is no launcher: everything is in the game's menu.

## Install
1. Far Cry 1.4 from Steam.
2. Copy the `Bin32` and `Mods` folders from the archive into the Far Cry folder (`steamapps\common\FarCry`), replacing files.
   - `Bin32\dinput8.dll` is the Ultimate ASI Loader; it loads `FarCryCoopNet.asi`. If you already have an ASI loader (`dinput8.dll` or `version.dll` from a widescreen fix), do not copy this one.
   - `Mods\FarCryCoop\Steam\steam_api.dll` turns Steam on inside the game (lobbies, Join, invites). Without the `Steam` folder the build plays by IP only.
3. Start: `Bin32\FarCryCoop.bat`, or in Steam: Far Cry properties → launch options `-MOD:FarCryCoop`.

## Playing
- **Main menu → Co-op.** Map or save, difficulty, players to wait for, max players, who can join (everyone / friends / invite only), password, weapon loadout. "Launch" starts the game and creates the Steam lobby.
- **Player settings:** shirt color and the 4 loadout weapons. The name is the Steam name (Cyrillic becomes Latin letters: the game cannot show Cyrillic).
- **Friends join** with "Join Game" in the Steam friends list, an invite, or "Join by IP" (port 49001). With a password the game asks for it.
- Update: copy a newer build over it. Remove: the `Mods\FarCryCoop` folder and `Bin32\FarCryCoopNet.asi`, `Bin32\dinput8.dll`, `Bin32\FarCryCoop.bat`.

## If something is wrong
Send `log.txt` from the Far Cry folder, the `netlog_*.txt` files from `Mods\FarCryCoop` and `VERSION.txt` from the archive.
