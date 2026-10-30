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
	if (COOP_Difficulty) then CoopApplyDifficulty(tonumber(COOP_Difficulty)); end -- the launcher sets it
	local mission = Game:GetMapDefaultMission(name);
	if (not mission) then
		System:LogAlways("coop_map: map '"..tostring(name).."' not found");
		return;
	end
	AvailableMODList.COOP.mission = mission;
	setglobal("g_GameType", "COOP");
	-- cutscene sequences need input and sound, which a dedicated server lacks (crashes in
	-- CMovieUser::BeginCutScene and CryMovie sound tracks); remote clients never see them anyway.
	-- A listen host (it has Input) plays them as in single player.
	if (not Input) then setglobal("mov_NoCutscenes", 1); end
	local running = COOP_Map;
	COOP_Map = name; -- before loading: the COOP gamerules (and the monitor) read it on load
	if (running) then
		Game:LoadLevelMPServer(name, mission); -- server already up: keep the clients connected
	else
		Game:LoadLevelListen(name);
	end
end
-- %% (quoted argument, as start_server does): with %line the game client passed the map name
-- unquoted, so "coop_map pier" ran CoopMap(pier) with an undefined variable and did nothing
Game:AddCommand("coop_map", "CoopMap(%%)","coop_map <campaign map>: start a campaign map as a co-op server");
Game:AddCommand("coop_restart", "if (COOP_Map) then CoopMap(COOP_Map) end", "coop_restart: reload the current co-op map, clients stay connected");

-- Co-op saves (written by CoopSave, COOP gamerules): Mods\FarCryCoop\save_<name>.lua. Loading
-- lives here and not in the gamerules: the launcher continues a campaign with CoopLoad("<name>")
-- from the menu, before any co-op map (and its gamerules) is loaded.
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
	if (COOP_Map) then
		COOP_PendingMap = save.map; -- GameRules:OnUpdate loads it, never from inside an entity script
	else
		CoopMap(save.map); -- from the launcher: no server yet, the host's game starts it
	end
	CoopSaveMessage("loading "..name);
end
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
	-- a host started by CoopMap (the launcher) has COOP_Map, which stays set after leaving: only
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
		-- as the multiplayer map cycle does
		COOP_PendingMap = map;
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
