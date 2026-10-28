-- FarCryCoop: client side of the co-op rules = single-player ClientStuff plus weapon preload.
Script:LoadScript("scripts/Default/ClientStuff.lua");
Script:LoadScript("scripts/COOP/Monitor.lua");

-- Campaign missions list only a few weapons in <Weapons><Used>; the server loads the rest on demand,
-- a remote client never does, so it cannot select, draw or fire them. OnInit runs after the level
-- is loaded and before the server sends the player, so load every weapon class here.
COOP_UPDATE_RATE = 50
Coop_DefaultClientOnInit = ClientStuff.OnInit;
function ClientStuff:OnInit()
	Coop_DefaultClientOnInit(self);
	-- written by the launcher: COOP_Color, COOP_Weapons, COOP_LoadoutMode (used by the host only).
	-- The launcher's console line (join_<pid>.txt) sets them first: two games on one PC share this file.
	if (not COOP_Color) then Script:LoadScript("Mods/FarCryCoop/prefs.lua"); end
	for name, def in WeaponClassesEx do
		Game:AddWeapon(name);
	end
	-- A snapshot holds only 8992 bits and a campaign map has hundreds of entities: ask for more
	-- snapshots than the default 20 a second (the server caps it at sv_maxupdaterate, 50)
	if (Client and Client.SetUpdateRate) then Client:SetUpdateRate(COOP_UPDATE_RATE); end
	-- A listen host plays the level intro as in single player: Mission:OnMapChange plays it only
	-- when g_MapChanged is set, which single player's ClientStuff:OnMapChange does on a map change
	if (Game:IsServer()) then g_MapChanged = 1; end
	-- a joined player must not start the next level itself at a mission end (CoopStartLevel)
	if (not Game:IsServer()) then COOP_Joined = 1; CoopWrapStartLevel(); end
	CoopMonEvent("C", "map");
end

-- The weapon a client spawned with stayed invisible until the player switched weapons (River,
-- 3 of 3 first spawns): BasicWeapon.Client:OnActivate shows the first-person weapon only for a
-- living _localplayer, and here the spawn's weapon is activated before the client has its own
-- health from the server; the weapon then stays selected, so nothing activates it again. Once
-- per spawn (a respawn is a new entity), 1 s after the player is alive with a weapon, show it
-- the same way, unless a scope or the binoculars keep it hidden on purpose.
function CoopShowSpawnWeapon()
	local P = _localplayer;
	if (not P or P.COOP_SpawnWeaponDone or not P.cnt or not P.cnt.weapon or not BasicPlayer.IsAlive(P)) then return; end
	P.COOP_SpawnWeaponAt = P.COOP_SpawnWeaponAt or _time;
	if (_time - P.COOP_SpawnWeaponAt < 1 and _time >= P.COOP_SpawnWeaponAt) then return; end
	P.COOP_SpawnWeaponDone = 1;
	if (P.cnt.drawfpweapon ~= 1 and not P.cnt.aiming and not ClientStuff.vlayers:IsActive("Binoculars")
		and not ClientStuff.vlayers:IsActive("WeaponScope")) then
		BasicWeapon.Show(P.cnt.weapon, P);
		CoopMonEvent("C", "spawn weapon shown "..tostring(P.cnt.weapon.name));
	end
end

Coop_DefaultClientOnUpdate = ClientStuff.OnUpdate;
function ClientStuff:OnUpdate()
	Coop_DefaultClientOnUpdate(self);
	CoopMonitor("C");
	CoopShowSpawnWeapon();
	local nxt = COOP_NextBoatSeats or 0;
	if (not Game:IsServer() and (_time > nxt or _time + 2 < nxt)) then -- the host does it in gamerules
		COOP_NextBoatSeats = _time + 1; -- second test: _time restarts with every map load
		CoopBoatSeats();
	end
end

-- The server dropped a player from a vehicle (COOP gamerules CoopWrapReleaseUser). The paraglider
-- has no client OnUnBind, so without this the client kept gliding where the server had no
-- paraglider. Vehicles that do have OnUnBind already let go: their seat is empty by now.
ClientStuff.ServerCommandTable["VEHOUT"] = function(String, toktable)
	if (Game:IsServer() or not VC) then return; end
	local v, p = System:GetEntity(tonumber(toktable[2]) or 0), System:GetEntity(tonumber(toktable[3]) or 0);
	if (not v or not p) then return; end
	local seats = {v.driverT, v.gunnerT};
	for i, t in (v.passengersTT or {}) do tinsert(seats, t); end
	for i, t in seats do
		if (type(t) == "table" and t.entity == p) then
			CoopMonEvent("C", "vehout "..v:GetName());
			VC.ReleaseUser(v, t);
		end
	end
end

-- Client-side hit detection: the shooter's own client decides what its bullets hit and tells
-- the server ("CHIT", handled in COOP GameRules:OnClientCmd), so aiming does not depend on the
-- host's connection. CWeaponClass caches each weapon's Client.OnHit when the class loads, so the
-- hook sits on the global ExecuteMaterial2(hit, effect), which Client:OnHit calls for every hit.
if (not COOP_OrigExecuteMaterial2) then
	COOP_OrigExecuteMaterial2 = ExecuteMaterial2;
	ExecuteMaterial2 = function(hit, effect)
		CoopReportHit(hit);
		return COOP_OrigExecuteMaterial2(hit, effect);
	end
end
function CoopReportHit(hit)
	local t, s = hit.target, hit.shooter;
	if (s ~= _localplayer or not t or t == s or t.type ~= "Player" or not BasicPlayer.IsAlive(t)) then return end
	Hud.hit = 5; -- red crosshair right away, as in single player
	if (Game:IsServer()) then return end -- listen-server host: its shots are already server-side
	local p, d = hit.pos, hit.dir;
	local mat = hit.target_material and hit.target_material.type or "flesh";
	Client:SendCommand(format("CHIT %d %.2f %d %s %.2f %.2f %.2f %.3f %.3f %.3f", t.id, hit.damage or 0,
		hit.ipart or -1, mat, p.x, p.y, p.z, d.x, d.y, d.z));
end

-- coop_noclip from the server: switch fly mode for our own (predicted) player too
ClientStuff.ServerCommandTable["NOCLIP"] = function(String, toktable)
	if (_localplayer and CoopSetNoclip) then CoopSetNoclip(_localplayer, tonumber(toktable[2]) or 0); end
end

-- Mission objectives and messages from the server (COOP gamerules CoopWrapHud). The
-- listen-server host already ran them on its own Hud.
ClientStuff.ServerCommandTable["MHUD"] = function(String, toktable)
	if (Game:IsServer() or not Hud) then return; end
	local op = toktable[2];
	local text = strsub(String, strlen("MHUD "..tostring(op).." ") + 1);
	-- the dedicated server has no string table: Localize("X") gave it "@X", translate here
	if (strsub(text, 1, 1) == "@" and op ~= "radar") then text = Localize(strsub(text, 2)); end
	CoopMonEvent("C", "hud "..tostring(op).." "..text);
	if (op == "msg") then Hud:AddMessage(text);
	elseif (op == "push") then Hud:PushObjective({}, text);
	elseif (op == "done") then Hud:CompleteObjective(text);
	elseif (op == "flash") then Hud:FlashObjectives();
	elseif (op == "radar") then Hud:SetRadarObjective(text); end
end
-- ask for the objectives given before we joined
Coop_DefaultOnSetPlayer = ClientStuff.OnSetPlayer;
function ClientStuff:OnSetPlayer()
	Coop_DefaultOnSetPlayer(self);
	if (not Game:IsServer()) then Client:SendCommand("HUDSYNC"); end
	-- who we are, so the host gives us our own equipment back after a reconnect or a restart
	-- (COOP gamerules CoopSetKey): the launcher's COOP_PlayerKey, else the player name we asked
	-- for (the server renames a second "Jack Carver" to "Jack Carver_")
	Client:SendCommand("COOPID "..tostring(COOP_PlayerKey or getglobal("p_name") or ""));
	-- launcher settings (COOP gamerules CoopSetPrefs); the host sends them too, over loopback
	if (COOP_Color) then Client:SendCommand("PREF "..COOP_Color.." "..tostring(COOP_Weapons or "")); end
	-- again once connected: asked in OnInit only, the server kept sending the default 20
	if (Client and Client.SetUpdateRate) then Client:SetUpdateRate(COOP_UPDATE_RATE); end
end

-- shirt color of a player from the launcher (COOP gamerules CoopApplyPrefs). Multiplayer turns on
-- the color mask shader with the "FX" command (BasicPlayer.SecondShader_TeamColoring, effect 2);
-- the single-player rules never do. The shader's ColorR/G/B come from entity.cnt:GetColor(),
-- which the single-player spawn leaves white and Lua cannot set: UpdatePlayerEffectParams is
-- wrapped to use the launcher color (entity.COOP_Color) instead.
ClientStuff.ServerCommandTable["PCOLOR"] = function(String, toktable)
	local e = System:GetEntity(tonumber(toktable[2]) or 0);
	local c = MultiplayerUtils and MultiplayerUtils.ModelColor[(tonumber(toktable[3]) or 1) + 1];
	if (not e or not c or not e.pEffectStack) then return; end
	if (not COOP_OrigUpdateEffectParams) then
		COOP_OrigUpdateEffectParams = BasicPlayer.UpdatePlayerEffectParams;
		BasicPlayer.UpdatePlayerEffectParams = function(entity)
			COOP_OrigUpdateEffectParams(entity);
			local c = entity.COOP_Color;
			if (c and entity.pEffectStack[getn(entity.pEffectStack)] == 2) then
				entity:SetShaderFloat("ColorR", c[1], 0, 0);
				entity:SetShaderFloat("ColorG", c[2], 0, 0);
				entity:SetShaderFloat("ColorB", c[3], 0, 0);
			end
		end
	end
	-- the single-player Jack (p_model hero.cgf) has no color mask: everyone stayed white with the
	-- shader on. Other players get the multiplayer Jack, the model multiplayer colors.
	-- Our own player is seen from first person only, so it keeps its model.
	if (e ~= _localplayer and not e.COOP_MPModel) then
		e.COOP_MPModel = 1;
		e:LoadCharacter("objects/characters/pmodels/hero/hero_mp.cgf", 0);
	end
	e.COOP_Color = c;
	e.bUpdatePlayerEffectParams = 1;
	BasicPlayer.SecondShader_TeamColoring(e);
	CoopMonEvent("C", "color "..e:GetName().." "..toktable[3]);
end

-- the server moves our player (COOP CoopMovePlayer): our own game owns its position
ClientStuff.ServerCommandTable["TELE"] = function(String, tk)
	if (Game:IsServer() or not _localplayer) then return; end
	_localplayer:SetPos({x = tonumber(tk[2]) or 0, y = tonumber(tk[3]) or 0, z = tonumber(tk[4]) or 0});
	if (tk[7]) then _localplayer:SetAngles({x = tonumber(tk[5]) or 0, y = tonumber(tk[6]) or 0, z = tonumber(tk[7]) or 0}); end
	CoopMonEvent("C", "tele "..strsub(String, 6));
end

-- an entity hidden or shown by a mission event on the server (COOP gamerules CoopWrapHide)
ClientStuff.ServerCommandTable["HIDE"] = function(String, toktable)
	local e = System:GetEntity(tonumber(toktable[2]) or 0);
	if (Game:IsServer() or not e) then return; end
	e:Hide(tonumber(toktable[3]) or 0);
	CoopMonEvent("C", "hide "..e:GetName().." "..tostring(toktable[3]));
end

-- AI health from the server ("AIHP <id> <hp> ...", COOP gamerules CoopSyncAIHealth): the engine
-- sends health only for our own player. A dead AI stays dead: deaths come by themselves.
ClientStuff.ServerCommandTable["AIHP"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 1]) do
		local e, hp = System:GetEntity(tonumber(tk[i]) or 0), tonumber(tk[i + 1]);
		if (e and e.ai and e.cnt and e.cnt.health and e.cnt.health > 0 and hp and hp > 0) then e.cnt.health = hp; end
		i = i + 2;
	end
end

-- where dropped weapons and physical props came to rest on the server ("PPOS <id> x y z ax ay az
-- ...", COOP gamerules CoopSyncDrops): our own copies may have fallen elsewhere (River: through a
-- boat's deck, rubble settled differently). A pickup's physics goes off here: asleep
-- (AwakePhysics 0) it woke up and fell through the deck again; the server's copy decides the
-- pickup, ours is only shown. A prop stays physical but asleep, so explosions still move it.
ClientStuff.ServerCommandTable["PPOS"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 6]) do
		local e = System:GetEntity(tonumber(tk[i]) or 0);
		if (e) then
			if (e.classname and strfind(e.classname, "^Pickup")) then e:EnablePhysics(0); end
			e:SetPos({x = tonumber(tk[i + 1]) or 0, y = tonumber(tk[i + 2]) or 0, z = tonumber(tk[i + 3]) or 0});
			e:SetAngles({x = tonumber(tk[i + 4]) or 0, y = tonumber(tk[i + 5]) or 0, z = tonumber(tk[i + 6]) or 0});
			if (not (e.classname and strfind(e.classname, "^Pickup"))) then e:AwakePhysics(0); end
		end
		i = i + 7;
	end
end

-- AI animation started by the server (melee swing, see COOP gamerules CoopUpdateMelee)
ClientStuff.ServerCommandTable["ANIM"] = function(String, toktable)
	local e = System:GetEntity(tonumber(toktable[2]) or 0);
	if (e and toktable[3]) then
		e:StartAnimation(0, toktable[3], 3, 0.1);
		CoopMonEvent("C", "anim "..e:GetName().." "..toktable[3]);
	end
end

-- sequences forwarded by the server (see COOP gamerules); names may contain spaces ("HIDE ALL").
-- Cutscenes play here too: only a dedicated server turns them off (it has no input or sound,
-- coop_map), and it still forwards every sequence it starts. A client has both.
if (not Game:IsServer()) then setglobal("mov_NoCutscenes", 0); end
ClientStuff.ServerCommandTable["SEQ"] = function(String, toktable)
	CoopMonEvent("C", "sequence "..strsub(String, 5));
	if (not Game:IsServer()) then Movie:PlaySequence(strsub(String, 5)); end
end
ClientStuff.ServerCommandTable["SEQSTOP"] = function(String, toktable)
	if (not Game:IsServer()) then Movie:StopSequence(strsub(String, 9)); end
end
