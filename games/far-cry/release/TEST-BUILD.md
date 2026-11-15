# FarCryCoop test build

Built automatically from the latest commit after a push (`FarCryCoop\VERSION.txt`). Not a release: expect bugs.

## Install
1. Far Cry 1.4 from Steam.
2. Copy the `FarCryCoop` folder into `Mods` in the Far Cry folder (`steamapps\common\FarCry\Mods`), replacing files. Nothing goes anywhere else.
3. Start it one of two ways:
   - in Steam: Far Cry properties → launch options `-MOD:FarCryCoop` (then Steam's "Join Game" also starts the game with the mod);
   - or in the game: the "Mods" menu → FarCryCoop (the game restarts with the mod).

`FarCryCoopNet.asi` and `dinput8.dll` (ASI Loader) left in `Bin32` by older builds can be deleted: they are not needed any more.

## Playing
- **Main menu → Co-op.** Map or save, difficulty, players to wait for, max players, who can join (everyone / friends / invite only), password, weapon loadout. "Launch" starts the game and creates the Steam lobby.
- **Player settings:** shirt color and the 4 loadout weapons. The name is the Steam name (Cyrillic becomes Latin letters: the game cannot show Cyrillic).
- **Friends join** with "Join Game" in the Steam friends list, an invite, or "Join by IP" (port 49001). With a password the game asks for it.
- Update: copy a newer build over it. Remove: the `Mods\FarCryCoop` folder.
- Without a `FarCryCoop\Steam` folder in the archive the build plays by IP only.

## If something is wrong
Send `log.txt` from the Far Cry folder, the `netlog_*.txt` files from `Mods\FarCryCoop` and `VERSION.txt`.
