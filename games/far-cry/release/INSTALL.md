# FarCryCoop 0.3 beta — campaign co-op for Far Cry (2004)

Play the Far Cry campaign together: one player hosts, friends join. Beta: expect bugs.

## Requirements
- Far Cry 1.4 (the Steam / GOG version is 1.4). Everyone needs the same mod version.
- Windows 10 or 11.

## Install (every player)
1. Copy the `Mods` and `Bin32` folders and `FarCryCoopLauncher.exe` from this archive into the Far Cry folder (for Steam: `steamapps\common\FarCry`). Allow merging.
2. `Bin32\dinput8.dll` is the Ultimate ASI Loader; it loads `FarCryCoopNet.asi`. If your `Bin32` already has an ASI loader (`version.dll` or `dinput8.dll` from a widescreen fix), do not copy `dinput8.dll`.
3. Start `FarCryCoopLauncher.exe` in the Far Cry folder. `Bin32\FarCryCoop.bat` still works without the launcher (it runs `FarCry.exe -DEVMODE -MOD:FarCryCoop`).

## Launcher
- Shirt color: pick one of 10 colors. Everyone sees it.
- Loadout: pick 4 of 11 weapons (the Machete is one of them). Loadout only works when the host turns it on. With the loadout on, every spawn gives your 4 weapons with full ammo. Weapons you take from enemies carry over to the next level, and your ammo is refilled there.
- Lobby: the host chooses a map and presses "Host lobby". Friends enter the host's IP and press "Join lobby". Everyone sees the players with their shirt colors and loadouts. The host presses "Start": the game starts for everyone, and friends connect once the host's map is loaded.
- Or press "Steam invite" and accept the host's invite in Steam.

## Inviting friends

There are three ways. Pick one.

### Way 1. Steam: no IP, no ports
Steam runs inside the game itself, as Far Cry: friends see you playing Far Cry and get the "Join Game" button. Steam carries the traffic through its own servers when a direct connection does not work. There is no separate window any more.
1. Everyone runs Steam, and you are Steam friends.
2. Host: in the launcher, choose a map, press "Host lobby", then "Start". Once the map is loaded, friends can join.
3. Friend: in the launcher press "Steam invite". Wait for the game's main menu.
4. Friend: in the Steam friends list, click the host → "Join Game". Or the host picks "Invite to game" in the Steam chat and the friend accepts.
5. The friend's game connects by itself, and a few seconds later the friend is on the map.

Limits: this way shows no lobby with colors, but color and loadout still work. Sessions are accepted only from Steam friends (or players in the host's Steam lobby), and only while the host runs a server.

### Way 2. Radmin VPN, Hamachi or ZeroTier: a shared "LAN"
1. Everyone installs the same program, for example Radmin VPN (free, no player limit).
2. The host creates a network (name and password), friends join it.
3. The host looks up their IP in that program (Radmin: `26.x.x.x`, Hamachi: `25.x.x.x`) and sends it to friends.
4. Host: "Host lobby". Friends: enter that IP and press "Join lobby". Everyone sees the players with colors and loadouts.
5. The host presses "Start". The game starts for everyone, and friends connect by themselves once the host's map is loaded.
6. When Windows asks about the firewall for `FarCryCoopLauncher.exe` and `FarCry.exe`, allow access (private and public networks: VPN adapters are often public).

### Way 3. Port forwarding on the router
The host forwards UDP 49001 (game) and TCP 49002 (lobby) to their PC and gives friends their external IP. Then go on as in way 2, from step 4.

### Without the launcher
Host: start `Bin32\FarCryCoop.bat`, open the console with `~` and type, for example, `#CoopMap("pier")`.
Maps: training, fort, pier, carrier, factory, research, treehouse, bunker, rebellion, steam, archive, control, swamp, catacombs, river, boat, dam, cooler, regulator, volcano.
Friend: start `FarCryCoop.bat`, then Multiplayer → LAN, or in the console: `connect <host IP>`.

## Beta test: what to check and what to send
1. Your shirt color shows for the other player (you see yourself in first person only).
2. With the loadout on: at the start and after death you get your 4 weapons with full ammo.
3. A weapon taken from an enemy carries over to the next level.
4. Lobby: "Start" starts the game for everyone, and friends connect by themselves.
5. Steam: "Join Game" connects without an IP.
6. Saves: a checkpoint, F6 and F7 work for the host; a save chosen in the launcher's map list starts the game on the saved spot.

If something does not work, send `log.txt` from the Far Cry folder and the `netlog_*.txt` files from `Mods\FarCryCoop` (Steam writes its lines there too, starting with `steam:`). To test alone, press "Test on one PC": the host's game opens on the left and loads the map, then a second game opens on the right and joins by itself, with the next shirt color.

## Saves (host)
- A checkpoint saves the game by itself (`auto`). **F6** is quicksave, **F7** quickload (`quick`). Console: `#CoopSave("name")`, `#CoopLoad("name")`.
- A load reloads the map: joined players stay connected and are put back where they were saved.
- To continue after you closed the game: in the launcher choose `save:auto` (or `save:quick`, or your name) instead of a map, and press Host lobby / Start. Friends join as usual.
- Saved: players' position, health, armor, weapons and ammo, which enemies are dead. Not saved: mission progress, triggers, pickups, vehicles. The mission starts from the beginning of the map, with the dead enemies gone.
- Files: `Mods\FarCryCoop\save_<name>.lua`.

## Useful console commands (host)
- `#CoopGod(1)` / `#CoopGod(0)` — god mode for everyone on/off
- `#CoopAmmo()` — full ammo, `#CoopWeapons()` — all weapons
- `#CoopGoto()` — list checkpoints, `#CoopGoto(3)` — move everyone to checkpoint 3
- `#CoopMap(COOP_Map)` — restart the map, friends stay connected
- `#CoopDifficulty(2)` — difficulty (0 easy, 1 medium, 2 challenging, 3 veteran, 4 realistic); the launcher sets it too. Restart the map for enemies to use it.

## Known limitations
- Cutscenes are off for joined players.
- Helicopters fly only for the host; joined players see them hanging in place.
- Barrels and crates: players cannot push them (the host neither); explosions move them.
- In-game chat and console type Latin letters only (the game works with any keyboard layout).

Source and bug reports: https://github.com/Bantila/FarCryCoop
Ultimate ASI Loader: https://github.com/ThirteenAG/Ultimate-ASI-Loader (MIT, see `Bin32\UltimateASILoader-LICENSE.txt`).
