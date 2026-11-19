-- this structure is used from C++ as well
-- gametype has to be upper case 

AvailableMODList=
{
	ASSAULT={	team=1, 		respawntime=1,	mission="ASSAULT", },
	FFA=		{	team=0, 		respawntime=0,	mission="FFA", },
	TDM=		{	team=1, 		respawntime=0,	mission="TDM", },
	-- FarCryCoop: campaign co-op. mission is set per map by coop_map (campaign mission name = map name).
	COOP=		{	team=0, 		respawntime=0,	mission="Training", },
};

-- Weapons in co-op behave as in single player (read by the mod's Weapons/RL.lua: the
-- multiplayer rocket launcher fires only after aiming and holding the button)
COOP_SPWeapons = 1

-- Player names. A name goes into Lua strings and console lines (p_name) and the game font has
-- Latin letters only, so a name keeps printable ASCII without quotes, ";", "#", "%", "@", "$" and
-- backslash, Cyrillic (UTF-8: a Steam name) is transliterated
-- (tests/menu-name.txt has the cases), anything else is dropped;
-- 20 characters at most, "Player" if nothing is left. Steam names can hold any text: this is the
-- only way one gets in. 20, "@" and "$": the host's own check (SDK XServerSlot
-- ConvertToValidPlayerName) keeps 20, turns "@" into "_" and garbles a "$" without a digit after
-- it; a name it changed would come back different and be renamed again on every map load.
COOP_NAME_MAX = 20
COOP_NAME_RU = {"a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p",
	"r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"} -- а..я
-- lower-case code points of the other letters: ё є і ї ґ
COOP_NAME_RU2 = {[1105] = "e", [1108] = "e", [1110] = "i", [1111] = "i", [1169] = "g"}

-- one Cyrillic letter (a code point) in Latin letters; "" for anything else
function CoopTranslit(cp)
	local upper;
	if (cp >= 1040 and cp <= 1071) then cp, upper = cp + 32, 1; -- А..Я
	elseif (cp >= 1024 and cp <= 1039) then cp, upper = cp + 80, 1; -- Ѐ..Џ (Ё Є І Ї)
	elseif (cp == 1168) then cp, upper = 1169, 1; end -- Ґ
	local t;
	if (cp >= 1072 and cp <= 1103) then t = COOP_NAME_RU[cp - 1071]; else t = COOP_NAME_RU2[cp] or ""; end
	if (upper and t ~= "") then t = strupper(strsub(t, 1, 1))..strsub(t, 2); end
	return t;
end

function CoopCleanName(s)
	s = tostring(s or "");
	local out, i, n = "", 1, strlen(s);
	while (i <= n) do
		local b, len, t = strbyte(s, i), 1, "";
		if (b >= 32 and b <= 126) then
			local c = strchar(b);
			if (not strfind(c, "[\"';#%%@%$\\]")) then t = c; end
		elseif (b >= 192 and b < 224 and i < n) then -- a two-byte character: Cyrillic is among them
			local b2 = strbyte(s, i + 1); -- (Lua 4: an error past the end, hence i < n)
			if (b2 >= 128 and b2 < 192) then
				len = 2;
				t = CoopTranslit((b - 192) * 64 + (b2 - 128));
			end
		elseif (b >= 224 and b < 240) then len = 3;
		elseif (b >= 240) then len = 4; end
		out = out..t;
		i = i + len;
	end
	out = gsub(out, "^%s+", "");
	out = strsub(out, 1, COOP_NAME_MAX);
	out = gsub(out, "%s+$", "");
	if (out == "") then out = "Player"; end
	return out;
end

-- With Steam the player's name is the Steam name (owner, 2026-11-15: nobody types somebody
-- else's name). The ASI sets COOP_SteamNameRaw once Steam is up (steam.c sendName) and calls
-- this; prefs.lua (Player settings) sets p_name too, so its loaders call it again.
function CoopApplySteamName()
	if (not COOP_SteamNameRaw) then return; end
	COOP_SteamName = CoopCleanName(COOP_SteamNameRaw);
	if (getglobal("p_name") ~= COOP_SteamName) then
		setglobal("p_name", COOP_SteamName);
		if (Client and Client.SetName) then Client:SetName(COOP_SteamName); end
	end
end
CoopApplySteamName(); -- a script reload: keep it

-- The Steam lobby of the game this host runs (MenuScreens/Coop.lua Launch sets COOP_Lobby:
-- max, access, pw, map). Its data follows the game, so the game list shows it as it is: the map,
-- the player count, a password or not. Lobby strings: "|" and "=" split the ASI's key=value list
-- and the console line must stay one line, so they keep printable ASCII without "|=\"';#%" and
-- backslash, 48 at most.
function CoopLobbyText(s)
	s = gsub(tostring(s or ""), "[^ -~]", "");
	s = gsub(s, "[|=\"';#%%\\]", "");
	return strsub(s, 1, 48);
end

-- a map as the menus show it: "carrier" (a level end's name) is "Carrier"
function CoopMapTitle(m)
	m = tostring(m or "");
	return strupper(strsub(m, 1, 1))..strlower(strsub(m, 2));
end

-- The game's name in Find game (Steam lobby "name", LAN sv_name): the host's own (Co-op screen,
-- "Server name") or "<player> - <map>". The own one keeps what the ASI lets through to the game
-- list (steam.c safeText): letters, digits, spaces and - _ . , ( ) ! ? : + / [ ], so the Internet
-- and the LAN list show the same name; no "$" (a digit after it is a color code in the game's
-- text) or "@" (a localization key). Spaces trimmed and single, 32 at most (the game's own server
-- name boxes: CreateServer.lua). Cyrillic is dropped (the game cannot show it): "" → the default.
COOP_SERVER_NAME_MAX = 32;
function CoopServerName(s)
	s = gsub(tostring(s or ""), "[^%w %-_%.,%(%)!%?:%+/%[%]]", "");
	s = gsub(s, "[^ -~]", ""); -- %w may take a letter of the system's code page
	s = gsub(gsub(gsub(s, "  +", " "), "^ ", ""), " $", "");
	return strsub(s, 1, COOP_SERVER_NAME_MAX);
end
function CoopGameName(map)
	return COOP_ServerName or (CoopLobbyText(getglobal("p_name") or "Player").." - "..CoopLobbyText(CoopMapTitle(map)));
end

-- "<max> <type>|name=...|map=...|..." for "coop_steam host" and "coop_steam update"
function CoopLobbyArgs()
	local L = COOP_Lobby;
	if (not L) then return ""; end
	-- the running map (a level end changes it); before the server is up, the one being launched
	-- (COOP_Map may be the last game's)
	local map = (Game:IsServer() and COOP_Map) or L.map;
	local n = 0;
	if (Server and Server.GetServerSlotMap and Game:IsServer()) then
		for i, s in Server:GetServerSlotMap() do n = n + 1; end
	end
	return format("%d %s|name=%s|map=%s|diff=%d|pw=%d|players=%d", L.max, L.access,
		CoopLobbyText(L.name or CoopGameName(map)), CoopLobbyText(CoopMapTitle(map)),
		tonumber(COOP_Difficulty) or 1, L.pw, max(n, 1));
end

-- once a second on the host (COOP gamerules OnUpdate): only what changed goes to Steam
function CoopLobbyUpdate()
	if (not COOP_Lobby or not Game:IsServer()) then return; end
	local a = CoopLobbyArgs();
	if (a == COOP_LobbySent) then return; end
	COOP_LobbySent = a;
	System:ExecuteCommand("coop_steam update "..a);
end

-- Difficulty, the five levels of the single-player menu (UI.PageCampaign:SetAIDifficulty in
-- Campaign.lua): the same globals, set here because a co-op game never goes through that menu.
-- {accuracy, aggression, health, accuracy may increase, AI speed}; the menu calls level 3 "Veteran".
COOP_DIFFICULTY = {
	{0.4, 0.3, 0.5, 0, 1.2},  -- 0 easy
	{0.5, 0.5, 0.7, 0, 1.5},  -- 1 medium
	{0.8, 0.8, 1.0, 0, 1.5},  -- 2 challenging
	{1.1, 1.1, 1.2, 1, 1.8},  -- 3 veteran
	{2.0, 2.0, 1.5, 1, 2.2},  -- 4 realistic
};
COOP_DIFFICULTY_NAMES = {easy = 0, medium = 1, challenging = 2, veteran = 3, brutal = 3, realistic = 4};

function CoopApplyDifficulty(level)
	local d = COOP_DIFFICULTY[level + 1];
	if (not d) then return; end
	setglobal("game_DifficultyLevel", level);
	setglobal("game_Accuracy", d[1]);
	setglobal("game_Aggression", d[2]);
	setglobal("game_Health", d[3]);
	setglobal("ai_allow_accuracy_decrease", 1);
	setglobal("ai_allow_accuracy_increase", d[4]);
	setglobal("ai_SOM_SPEED", d[5]);
end

-- #CoopDifficulty(2) or #CoopDifficulty("challenging"); without an argument it shows the level.
-- Enemies read it when they spawn: restart the map (coop_restart) after changing it.
function CoopDifficulty(v)
	if (v == nil or v == "") then
		System:LogAlways("coop_difficulty: "..tostring(COOP_Difficulty).." (0 easy, 1 medium, 2 challenging, 3 veteran, 4 realistic)");
		return;
	end
	local n = tonumber(v);
	if (not n and type(v) == "string") then n = COOP_DIFFICULTY_NAMES[strlower(v)]; end
	if (not n or not COOP_DIFFICULTY[n + 1]) then
		System:LogAlways("coop_difficulty: use 0-4 or easy, medium, challenging, veteran, realistic");
		return;
	end
	COOP_Difficulty = n;
	CoopApplyDifficulty(n);
	System:LogAlways("coop_difficulty: "..n.." set; coop_restart for enemies to use it");
end
Game:AddCommand("coop_difficulty", "CoopDifficulty(%%)", "coop_difficulty [0-4|name]: show or set the difficulty (0 easy ... 4 realistic)");

-- FarCryCoop: start a campaign map as a co-op server, e.g. "coop_map Pier"
function CoopMap(name)
	-- a new game (not the next level, CoopSaveLoadouts): the last game's save points are gone
	if (not COOP_MapChanging) then COOP_SavePoint, COOP_RespawnOwed = {}, {}; end
	COOP_MapChanging = nil;
	if (COOP_Difficulty) then CoopApplyDifficulty(tonumber(COOP_Difficulty)); end -- the Co-op menu sets it
	local mission = Game:GetMapDefaultMission(name);
	if (not mission) then
		System:LogAlways("coop_map: map '"..tostring(name).."' not found");
		return;
	end
	if (COOP_Exit and CoopExitUnfreezeAll) then CoopExitUnfreezeAll(COOP_Exit); end -- an exit left open (COOP LevelEnd) ends with its level
	COOP_Exit, COOP_ExitView = nil, nil;
	AvailableMODList.COOP.mission = mission;
	setglobal("g_GameType", "COOP");
	-- cutscene sequences need input and sound, which a dedicated server lacks (crashes in
	-- CMovieUser::BeginCutScene and CryMovie sound tracks); remote clients never see them anyway.
	-- A listen host (it has Input) plays them as in single player.
	if (not Input) then setglobal("mov_NoCutscenes", 1); end
	-- a sequence still playing runs on into the new level and the host crashes in CryMovie.dll
	-- (a Pier exit right after heli_fly_by, tests/level-change-sequence.txt); SDK CXGame::SoftReset
	-- stops them the same way
	if (Movie and Movie.StopAllSequences) then Movie:StopAllSequences(); end
	local running = COOP_Map;
	-- a new game started from the console takes nothing of an earlier menu game:
	-- no password, no player limit, no Steam lobby (MenuScreens/Coop.lua Launch sets them for its own)
	local menu = COOP_MenuLaunch;
	COOP_MenuLaunch = nil;
	if (not (running and Game:IsServer()) and not menu) then
		COOP_Lobby = nil;
		COOP_ServerName = nil;
		setglobal("sv_password", "");
		setglobal("sv_maxplayers", 16); -- the engine's default
	end
	COOP_Map = name; -- before loading: the COOP gamerules (and the monitor) read it on load
	-- the game's name in LAN lists (sv_name, empty by default): as the Steam lobby's (CoopGameName)
	setglobal("sv_name", CoopGameName(name));
	if (running and Game:IsServer()) then
		Game:LoadLevelMPServer(name, mission); -- server already up: keep the clients connected
	else
		Game:LoadLevelListen(name);
	end
end
-- %% (quoted argument, as start_server does): with %line the game client passed the map name
-- unquoted, so "coop_map pier" ran CoopMap(pier) with an undefined variable and did nothing
Game:AddCommand("coop_map", "CoopMap(%%)","coop_map <campaign map>: start a campaign map as a co-op server");
-- join a co-op game: "coop_connect 192.168.0.5" (port 49001 unless given). The menu joins with it
-- (MenuScreens/Coop.lua): the ASI marks this game as a co-op one from the console line
function CoopConnect(addr)
	addr = tostring(addr or "");
	if (addr == "" or strfind(addr, "[^%w%.:%-]")) then
		System:LogAlways("coop_connect: bad address");
		return;
	end
	if (not strfind(addr, ":")) then addr = addr..":49001"; end
	Game:Connect(addr, 1);
end
Game:AddCommand("coop_connect", "CoopConnect(%%)", "coop_connect <address>[:port]: join a co-op game");
-- the host kicks or bans without a vote (COOP gamerules CoopAdminKick)
Game:AddCommand("coop_kick", "CoopAdminKick(%%)", "coop_kick <player name>: the host kicks a player");
Game:AddCommand("coop_ban", "CoopAdminKick(%%, 1)", "coop_ban <player name>: the host bans a player (Mods/FarCryCoop/bans.lua)");
Game:AddCommand("coop_unban", "CoopAdminUnban(%%)", "coop_unban <name, key or all>: lift a ban");
Game:AddCommand("coop_bans", "CoopAdminBans()", "coop_bans: list the banned players");
Game:AddCommand("coop_restart", "if (COOP_Map) then CoopMap(COOP_Map) end", "coop_restart: reload the current co-op map, clients stay connected");

-- Co-op saves (written by CoopSave, COOP gamerules): Mods\FarCryCoop\save_<name>.lua. Loading
-- lives here and not in the gamerules: a campaign continues with CoopLoad("<name>")
-- (coop_loadgame) from the main menu, before any co-op map (and its gamerules) is loaded.
COOP_SAVE_PATH = "Mods/FarCryCoop/save_";

function CoopSaveMessage(text)
	System:LogAlways("coop: "..text);
	if (Hud and Hud.AddMessage) then call(Hud.AddMessage, {Hud, text}, "x", function() end); end
end

function CoopLoad(name)
	name = name or "quick";
	if (not Game:IsServer() and _localplayer) then return; end -- a joined player; from the menu it starts the server
	if (strfind(name, "[^%w_]")) then System:LogAlways("coop_load: bad name"); return; end
	COOP_LoadedSave = nil;
	call(dofile, {COOP_SAVE_PATH..name..".lua"}, "x", function(msg) System:LogAlways("coop_load: "..tostring(msg)); end);
	local save = COOP_LoadedSave;
	COOP_LoadedSave = nil;
	if (type(save) ~= "table" or not save.map) then CoopSaveMessage("no save "..name); return; end
	COOP_PendingLoad = save;
	if (save.difficulty) then COOP_Difficulty = save.difficulty; end -- CoopMap applies it
	if (COOP_Map and Game:IsServer()) then
		COOP_PendingMap = save.map; -- GameRules:OnUpdate loads it, never from inside an entity script
	else
		CoopMap(save.map); -- from the main menu: no server yet, the host's game starts it
	end
	CoopSaveMessage("loading "..name);
end
-- here, not in the COOP gamerules: the menu loads a save before any co-op map is up (MenuScreens/Coop.lua)
Game:AddCommand("coop_loadgame", "CoopLoad(%%)", "coop_loadgame <name>: load a co-op save (quick, auto or a name)");
function CoopQuickLoad() CoopLoad("quick"); end

-- Co-op campaign from the normal menus: #CoopStart() on the host, then start the campaign or a
-- level from the menu as in single player. Single player loads a level with the message
-- "StartLevel <map>" (Campaign.lua menu, and every mission end: UI:PlayCutScene(video,
-- "StartLevel <next map>")), which loads it as a new single-player game and drops every
-- joined player. While co-op is on, such a message runs CoopMap(<map>) instead: the first
-- one starts the co-op server, later ones change the map with the clients kept connected.
-- The level-end video is skipped (joined players would not see it anyway).
-- A joined player's game runs the same mission end and would start the next level as single
-- player on its own: it ignores the message, the host changes the level for everyone.
-- ponytail: COOP_Joined stays set after leaving; a joined player who then plays single player
-- with the mod on in the same session gets no level change at a mission end
function CoopStartLevel(msg)
	if (type(msg) ~= "string") then return; end
	-- most maps end with "StartLevelFade <map>" (Game.cpp: the same with a fade out)
	local s, e, map = strfind(msg, "^StartLevel%a*%s+(%S+)");
	if (not map) then return; end
	-- a host started by CoopMap (console, harness) has COOP_Map, which stays set after leaving: only
	-- while it serves a game, or New game from the menu would only set COOP_PendingMap
	if (not COOP_Started and not (COOP_Map and Game:IsMultiplayer() and Game:IsServer())) then
		if (COOP_Joined and not Game:IsServer()) then
			System:LogAlways("coop: ignored "..msg..", the host changes the level");
			return 1;
		end
		return;
	end
	System:LogAlways("coop: "..msg.." -> CoopMap("..map..")");
	if (COOP_Map) then
		-- a mission end calls this from a level entity's script: unloading the level under it
		-- crashed the host in CryEntitySystem. COOP gamerules load it on their next update,
		-- as the multiplayer map cycle does; first the players gather at the exit (COOP LevelEnd)
		local held = nil;
		if (CoopExitOpen and Game:IsServer()) then
			-- an error there must not lose the mission end: then the level changes at once
			held = call(CoopExitOpen, {map}, "x", function(msg) System:LogAlways("coop: exit error: "..tostring(msg)); end);
		end
		if (not held) then COOP_PendingMap = map; end
	else
		CoopMap(map); -- from the menu: no level running yet
	end
	return 1;
end
function CoopWrapStartLevel()
	if (not COOP_SendMessage) then
		COOP_SendMessage = Game.SendMessage;
		Game.SendMessage = function(self, msg)
			if (not CoopStartLevel(msg)) then return COOP_SendMessage(self, msg); end
		end
	end
	if (UI and not COOP_PlayCutScene) then
		COOP_PlayCutScene = UI.PlayCutScene;
		UI.PlayCutScene = function(self, video, msg)
			if (not CoopStartLevel(msg)) then return COOP_PlayCutScene(self, video, msg); end
		end
	end
end
function CoopStart()
	COOP_Started = 1;
	CoopWrapStartLevel();
	System:LogAlways("coop: on. Start the campaign or a level from the menu; friends join through LAN");
end
Game:AddCommand("coop_start", "CoopStart()", "coop_start: host the campaign; levels started from the menu or by a mission end become co-op");

-- FarCryCoop test commands for the host (server console) ------------------------------------

-- player entities of all connected slots; built without tinsert, which adds a field "n"
-- (Lua 4) that would show up as a number in "for i, P in CoopPlayers()"
function CoopPlayers()
	local t, k = {}, 0;
	for i, slot in Server:GetServerSlotMap() do
		local P = System:GetEntity(slot:GetPlayerId());
		if (P) then k = k + 1; t[k] = P; end
	end
	return t;
end

-- A remote player's own game moves it (client-side movement): SetPos on the server did not
-- move a client at all, so coop_gather / coop_goto / coop_load only ever moved the host.
-- The client moves its own player ("TELE x y z [ax ay az]", COOP ClientStuff).
-- The command is sent once, and a client that is loading, dead, in a vehicle or over terrain that has
-- not streamed in yet missed it or fell through (sweep: Swamp checkpoint 4 left the client 1087 m
-- away, Volcano checkpoint 3 44 m below). So every move of a remote player is watched
-- (COOP_TeleWatch, COOP GameRules CoopTeleWatch): the server sends it again until the player is there.
-- A seated player moved with SetPos stayed in the vehicle and died at once (sweep: Fort and Boat
-- checkpoints, the host starts in a Zodiac; it then respawned at the level start): leave the seat first.
function CoopLeaveSeat(P)
	local v = P.theVehicle;
	local u = v and VC.FindUserTable(v, P);
	if (u) then VC.ReleaseUser(v, u); end
end
function CoopMovePlayer(P, pos, ang, retry)
	if (P.theVehicle) then
		call(CoopLeaveSeat, {P}, "x", function(msg) System:LogAlways("coop: leaving the vehicle failed: "..tostring(msg)); end);
	end
	P:SetPos(pos);
	if (ang) then P:SetAngles(ang); end
	for i, slot in Server:GetServerSlotMap() do
		if (slot:GetPlayerId() == P.id) then
			local a = ang and format(" %.2f %.2f %.2f", ang.x, ang.y, ang.z) or "";
			slot:SendCommand(format("TELE %.2f %.2f %.2f", pos.x, pos.y, pos.z)..a);
			if (not retry and COOP_TeleWatch and slot:GetPlayerId() ~= (_localplayer and _localplayer.id)) then
				COOP_TeleWatch[slot:GetId()] = {pos = {x = pos.x, y = pos.y, z = pos.z}, ang = ang and {x = ang.x, y = ang.y, z = ang.z} or nil, tries = 0, t = _time};
			end
		end
	end
end

-- move every player next to pos and make it the respawn point
function CoopTeleport(pos, ang)
	_LastCheckPPos = new(pos);
	_LastCheckPAngles = new(ang);
	for i, P in CoopPlayers() do
		CoopMovePlayer(P, {x = pos.x + i, y = pos.y, z = pos.z}, ang); -- 1 m apart so players do not stack
	end
	System:LogAlways(format("coop: teleported to %.0f,%.0f,%.0f", pos.x, pos.y, pos.z));
end

-- move every other player next to the leader (default: the host's player, else the first one)
function CoopGather(leader)
	leader = leader or _localplayer or CoopPlayers()[1];
	if (not leader) then return; end
	local t = leader:GetPos();
	local k = 0;
	for i, P in CoopPlayers() do
		if (P ~= leader) then
			k = k + 1;
			CoopMovePlayer(P, {x = t.x, y = t.y, z = t.z + 0.3}); -- on the leader's spot: 1 m aside put a client into a wall
		end
	end
	System:LogAlways(format("coop: gathered %d players at %s", k, leader:GetName()));
end
Game:AddCommand("coop_gather", "CoopGather()", "coop_gather: move all players to the host");

-- campaign checkpoints are GameEvent entities (Properties.nId, nAllowedDeaths)
function CoopGoto(n)
	n = tonumber(n);
	local list = {};
	for i, e in System:GetEntities() do
		if (e.Properties and e.Properties.nId and e.Properties.nAllowedDeaths) then tinsert(list, e); end
	end
	sort(list, function(a, b) return a.Properties.nId < b.Properties.nId; end);
	for i = 1, getn(list) do
		local e = list[i];
		local t = e:GetPos(); -- GetPos/GetAngles return shared tables: copy the values
		local pos = {x = t.x, y = t.y, z = t.z};
		if (not n) then
			System:LogAlways(format("checkpoint %d at %.0f,%.0f,%.0f", e.Properties.nId, pos.x, pos.y, pos.z));
		elseif (e.Properties.nId == n) then
			t = e:GetAngles();
			CoopTeleport(pos, {x = t.x, y = t.y, z = t.z});
			return;
		end
	end
	if (n) then System:LogAlways("coop_goto: no checkpoint "..n); end
end
Game:AddCommand("coop_goto", "CoopGoto(%line)", "coop_goto [id]: list checkpoints, or move all players to checkpoint <id>");

function CoopSpawn(n)
	local pt = Server:GetRespawnPoint("Respawn"..tostring(n));
	if (not pt) then
		System:LogAlways("coop_spawn: no tagpoint Respawn"..tostring(n));
		return;
	end
	CoopTeleport({x = pt.x, y = pt.y, z = pt.z}, {x = pt.xA, y = pt.yA, z = pt.zA});
end
Game:AddCommand("coop_spawn", "CoopSpawn(%1)", "coop_spawn <n>: move all players to tagpoint Respawn<n>");

-- god mode is applied in COOP GameRules:OnUpdate
COOP_God = 0;
function CoopGod(on)
	COOP_God = tonumber(on) or (1 - COOP_God);
	System:LogAlways("coop_god "..COOP_God);
end
Game:AddCommand("coop_god", "CoopGod(%line)", "coop_god [0/1]: toggle god mode for all players");

-- refill every ammo type
function CoopAmmo()
	for i, P in CoopPlayers() do
		for ammotype, amount in MaxAmmo do
			if (P.Ammo and P.Ammo[ammotype]) then
				BasicPlayer.AddAmmo(P, ammotype, amount);
			end
		end
	end
	System:LogAlways("coop_ammo: all ammo types refilled");
end
Game:AddCommand("coop_ammo", "CoopAmmo()", "coop_ammo: refill every ammo type for all players");

-- noclip ("designer fly mode" of DevMode.lua): no gravity/inertia and no collision. Movement is
-- predicted on the client, so the server switches it for its copy of each player and tells
-- every client to do the same for its own player (ServerCommandTable["NOCLIP"] in COOP ClientStuff).
COOP_Noclip = 0;
function CoopSetNoclip(P, on)
	if (on == 1) then
		if (not P.COOP_SavedDyn) then P.COOP_SavedDyn = new(P.DynProp); end
		P.DynProp.gravity = 0; P.DynProp.inertia = 0;
		P.DynProp.swimming_gravity = 0; P.DynProp.swimming_inertia = 0; P.DynProp.air_control = 1;
		P.cnt:SetDynamicsProperties(P.DynProp);
		P:ActivatePhysics(0);
	elseif (P.COOP_SavedDyn) then
		P.DynProp = P.COOP_SavedDyn; P.COOP_SavedDyn = nil;
		P.cnt:SetDynamicsProperties(P.DynProp);
		P:ActivatePhysics(1);
	end
end
function CoopNoclip(on)
	COOP_Noclip = tonumber(on) or (1 - COOP_Noclip);
	for i, P in CoopPlayers() do CoopSetNoclip(P, COOP_Noclip); end
	for i, slot in Server:GetServerSlotMap() do slot:SendCommand("NOCLIP "..COOP_Noclip); end
	System:LogAlways("coop_noclip "..COOP_Noclip);
end
Game:AddCommand("coop_noclip", "CoopNoclip(%line)", "coop_noclip [0/1]: toggle noclip fly mode for all players");

-- give all players every weapon (9 slots, PLAYER_MAX_WEAPONS) plus full ammo
function CoopWeapons()
	for i, P in CoopPlayers() do
		for name, w in WeaponClassesEx do
			Game:AddWeapon(name);
			P.cnt:MakeWeaponAvailable(w.id);
		end
	end
	CoopAmmo();
	System:LogAlways("coop_weapons: all weapons given");
end
Game:AddCommand("coop_weapons", "CoopWeapons()", "coop_weapons: give all players every weapon and full ammo");
