-- FarCryCoop: client side of the co-op rules = single-player ClientStuff plus weapon preload.
Script:LoadScript("scripts/Default/ClientStuff.lua");
Script:LoadScript("scripts/COOP/Monitor.lua");
Script:LoadScript("scripts/COOP/LevelEnd.lua");

-- Campaign missions list only a few weapons in <Weapons><Used>; the server loads the rest on demand,
-- a remote client never does, so it cannot select, draw or fire them. OnInit runs after the level
-- is loaded and before the server sends the player, so load every weapon class here.
COOP_UPDATE_RATE = 50
Coop_DefaultClientOnInit = ClientStuff.OnInit;
function ClientStuff:OnInit()
	Coop_DefaultClientOnInit(self);
	COOP_MyItems, COOP_MyItemsOn = nil, nil; -- the last session's or map's (ITEMS)
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
	-- a joined player must not start the next level itself at a mission end (CoopStartLevel); the
	-- host changes it for everyone (it starts with CoopMap from the launcher, not coop_start, so
	-- without this a mission end loaded the next map as single player and dropped the clients)
	if (not Game:IsServer()) then COOP_Joined = 1; end
	CoopWrapStartLevel();
	-- the skip key votes (COOP gamerules CoopCountSkipVote) instead of skipping for this player only
	if (Input) then Input:BindCommandToKey("#CoopSkipVote()", "spacebar", 1); end
	COOP_SeqPlayed = {}; -- a new map: its sequences (SEQ, SEQAT)
	CoopMonEvent("C", "map");
end

-- our vote to skip the cutscene that is playing: only while one plays (its NO_HUD flag hides the
-- HUD, CMovieUser::BeginCutScene, SDK); pressed again, the vote is taken back
function CoopSkipVote()
	if (tonumber(getglobal("cl_display_hud")) ~= 0 or not Client) then return; end
	COOP_MySkipVote = (not COOP_MySkipVote) and 1 or nil;
	Client:SendCommand("SKIPVOTE "..(COOP_MySkipVote or 0));
	CoopMonEvent("C", "skip vote "..(COOP_MySkipVote or 0));
end
-- The single-player skip still worked for one player: the host pressed space and only its own
-- cutscene stopped (2026-10-29, the binding above had not held). Whatever the key, it runs the
-- SkipCutScene console command, which is Lua Movie:StopAllCutScenes() (SDK GameActionInput.cpp):
-- every such call votes instead. The vote's own stop goes through CoopStopCutScenes (COOP gamerules
-- CoopCountSkipVote, SEQSKIP here). Once: this file reloads with every map.
if (not COOP_OrigStopAllCutScenes) then
	COOP_OrigStopAllCutScenes = Movie.StopAllCutScenes;
	Movie.StopAllCutScenes = function(self) CoopSkipVote(); end
end
function CoopStopCutScenes() COOP_OrigStopAllCutScenes(Movie); end

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

-- AI placed asleep (bSleepOnSpawn) wake up in single player once they are on the local player's
-- screen (Training's first village: 0 of 5 move with the player's back to it, 3 of 5 facing it;
-- docs/findings.md). The server only knows what its own player sees, so a remote client tells it
-- which sleepers it sees ("SEEN <id> ...", COOP gamerules CoopWakeSeen): in front of its eyes
-- (COOP_SEE_COS of the horizontal angle), closer than COOP_SEE_DIST and not behind terrain or
-- static geometry (RayTraceCheck to the chest or the head). Each sleeper is sent once per map.
-- System:GetViewCameraPos is no use here: on a client in the background it gave a spot 95 m away.
COOP_SEE_DIST = 100 -- ponytail: the renderer's distance for characters is not known; tune
-- the game's 90 degree field of view (Game:GetCameraFov) is ~42 degrees either side horizontally
-- at 4:3 and 16:9 (CCamera::Update, SDK Cry_Camera.h); 45 leaves room for the body's width
COOP_SEE_COS = 0.707
function CoopReportSeen()
	local P = _localplayer;
	if (Game:IsServer() or not P or not P.cnt or not BasicPlayer.IsAlive(P)) then return; end
	local nxt = COOP_NextSeen or 0;
	if (_time < nxt and _time + 2 > nxt) then return; end
	if (_time + 2 <= nxt) then COOP_SeenSent = {}; end -- _time restarted: a new map
	COOP_NextSeen = _time + 0.25;
	COOP_SeenSent = COOP_SeenSent or {};
	local c = P:GetCameraPosition();
	local cx, cy, cz = c.x, c.y, c.z;
	c = {x = cx, y = cy, z = cz};
	local d = P:GetDirectionVector();
	local dx, dy = d.x, d.y;
	local dl = sqrt(dx * dx + dy * dy);
	if (dl < 0.01) then return; end
	local words, k = {}, 0;
	for i, e in System:GetEntities() do
		if (e.Properties and e.Properties.bSleepOnSpawn == 1 and e.cnt and e.cnt.health and e.cnt.health > 0
			and not COOP_SeenSent[e.id]) then
			local p = e:GetPos();
			local x, y, z = p.x - cx, p.y - cy, p.z - cz;
			local l = sqrt(x * x + y * y);
			if (l < COOP_SEE_DIST and (x * dx + y * dy) >= COOP_SEE_COS * l * dl
				and (System:RayTraceCheck(c, {x = p.x, y = p.y, z = p.z + 1}, P.id, e.id)
					or System:RayTraceCheck(c, {x = p.x, y = p.y, z = p.z + 1.6}, P.id, e.id))) then
				COOP_SeenSent[e.id] = 1;
				k = k + 1; words[k] = tostring(e.id);
			end
		end
	end
	if (k > 0) then
		CoopMonEvent("C", format("seen %d sleepers from %.0f %.0f yaw %.0f: %s", k, cx, cy, P:GetAngles().z, words[1]));
		-- a command is cut at 255 characters (COOP gamerules CoopSendPacked)
		local msg = "SEEN";
		for i = 1, k do
			if (msg ~= "SEEN" and strlen(msg) + 1 + strlen(words[i]) > 240) then Client:SendCommand(msg); msg = "SEEN"; end
			msg = msg.." "..words[i];
		end
		Client:SendCommand(msg);
	end
end

Coop_DefaultClientOnUpdate = ClientStuff.OnUpdate;
function ClientStuff:OnUpdate()
	Coop_DefaultClientOnUpdate(self);
	-- a use-trigger hint the server sends once a second while we stand in it (MHUD label)
	if (COOP_LabelUntil and _time < COOP_LabelUntil and _time + 3 > COOP_LabelUntil and Hud) then Hud.label = COOP_Label; end
	CoopMonitor("C");
	CoopShowSpawnWeapon();
	CoopApplyMyItems();
	CoopHookHud();
	CoopHookPerception();
	CoopWrapClientSeat();
	call(CoopExitClientTick, {}, "x", function(msg)
		if (not COOP_ExitErrorLogged) then COOP_ExitErrorLogged = 1; System:LogAlways("coop: exit zone error: "..tostring(msg)); end
	end);
	call(CoopReportSeen, {}, "x", function(msg)
		if (not COOP_SeenErrorLogged) then COOP_SeenErrorLogged = 1; System:LogAlways("coop: seen sleepers error: "..tostring(msg)); end
	end);
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

-- A crew the server seats when the map loads (VC:OnBind: AddUserT with time -20) reaches a client
-- only as the bind. The seat position comes from VC:UserEntered, which VC:UpdateEnteringUser calls
-- from the server's vehicle update alone (VC:UpdateEnteringLeaving), so the client's copy stayed
-- bound with no place in the vehicle: Steam's boat gunner stood at its level spot, 240 m from the
-- boat, and logged "pos is invalid" every frame (tests/steam-boat-crew.txt). Seat it as
-- UserEntered does, sit animation included. VehicleCommon.lua loads at startup (main.lua), the
-- per-frame call only wraps a reloaded VC again.
function CoopWrapClientSeat()
	if (not VC or VC.COOP_ClientSeat or Game:IsServer()) then return; end
	VC.COOP_ClientSeat = 1;
	local old = VC.AddUserT;
	VC.AddUserT = function(self, tbl)
		local r = %old(self, tbl);
		if (type(tbl) == "table" and tbl.entity and tbl.state == 1 and tbl.time and tbl.time <= -10) then
			tbl.entity:SetPos(self:GetHelperPos(tbl.in_helper, 1));
			-- the server's sit animation ("ANIM") went out when it seated the crew at the map start,
			-- before this client was in: the gunner stood in the boat
			if (tbl.sit_anim) then
				tbl.entity:StartAnimation(0, tbl.sit_anim, 0, 0, 1);
				tbl.entity:ForceCharacterUpdate(0);
				CoopMonEvent("C", "anim "..tbl.entity:GetName().." "..tbl.sit_anim);
			end
		end
		return r;
	end
end
CoopWrapClientSeat();

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

-- our keycards, mission objects and explosives (COOP gamerules CoopSendItems), for the HUD: put on
-- our player now, and again on a new one (a respawn)
ClientStuff.ServerCommandTable["ITEMS"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local c = {keycards = {}, objects = {}, explosives = {}};
	gsub(tk[2] or "-", "([^,]+)", function(k) if (k ~= "-") then %c.keycards[tonumber(k) or k] = 1; end end);
	gsub(tk[3] or "-", "([^,]+)", function(k) if (k ~= "-") then %c.objects[k] = 1; end end);
	for i = 1, (tonumber(tk[4]) or 0) do c.explosives[i] = 1; end
	COOP_MyItems, COOP_MyItemsOn = c, nil;
	CoopApplyMyItems();
end
function CoopApplyMyItems()
	-- never on a host: its player is the server's entity, with the real items
	if (Game:IsServer() or not COOP_MyItems or not _localplayer or COOP_MyItemsOn == _localplayer) then return; end
	COOP_MyItemsOn = _localplayer;
	_localplayer.keycards, _localplayer.objects, _localplayer.explosives = COOP_MyItems.keycards, COOP_MyItems.objects, COOP_MyItems.explosives;
end

-- The name and health of the player under the crosshair, "<name> <health>%" (docs/specs/player-info.md);
-- drawn after Hud:OnUpdate every frame. GetViewIntersection gives no entity for another player on a
-- client (its ray goes through them), so we take only its point, which stops the ray at walls, and
-- look for a player whose body the ray passes on the way: a standing cylinder around the feet.
-- COOP_InfoText is the text drawn this frame (nil: nothing), read by tests/player-info.txt.
COOP_INFO_RANGE = 50
COOP_INFO_RADIUS = 0.5 -- around the body axis
COOP_INFO_HEIGHT = 1.9
COOP_INFO_FADE = 0.5 -- seconds it stays, fading, after the crosshair leaves
function CoopAimedPlayer(me)
	local c = me:GetCameraPosition();
	local cx, cy, cz = c.x, c.y, c.z; -- a shared table
	local o = me.cnt:GetViewIntersection();
	-- one by one: a multiple assignment here gave dx the value meant for dy (Lua 4)
	local dx, dy, dz, far = 0, 0, 0, COOP_INFO_RANGE;
	-- the host's ray stops at a player: take him (a client's goes through)
	if (o and type(o.ent) == "table" and o.ent.classname == "Player" and o.ent ~= me and not o.ent.ai and o.ent.cnt and (o.ent.cnt.health or 0) > 0) then return o.ent; end
	-- len is counted from the eye, not the camera: the distance from the camera
	local d = o and sqrt((o.x - cx) * (o.x - cx) + (o.y - cy) * (o.y - cy) + (o.z - cz) * (o.z - cz)) or 0;
	if (d > 0.01) then
		dx = (o.x - cx) / d;
		dy = (o.y - cy) / d;
		dz = (o.z - cz) / d;
		far = min(d + 0.6, COOP_INFO_RANGE);
	else -- nothing in the way (sky): along the view; yaw 0 looks along -y, 90 along +x; pitch 10 looks down
		local a = me:GetAngles();
		dx = sin(a.z) * cos(a.x);
		dy = -cos(a.z) * cos(a.x);
		dz = -sin(a.x);
	end
	local hh = dx * dx + dy * dy;
	if (hh < 0.0001) then return; end -- straight up or down
	if (not COOP_InfoPlayers or _time > COOP_InfoPlayersAt + 1 or _time < COOP_InfoPlayersAt) then
		COOP_InfoPlayers, COOP_InfoPlayersAt = CoopMonPlayers(), _time; -- _time restarts with every map load
	end
	local best, bestT;
	for i, P in COOP_InfoPlayers do
		if (P ~= me and System:GetEntity(P.id) == P and P.cnt and P.cnt.health and P.cnt.health > 0) then -- the list is up to 1 s old
			local p = P:GetPos();
			local wx, wy = p.x - cx, p.y - cy;
			local t = (wx * dx + wy * dy) / hh; -- along the ray, where it passes the body axis closest
			local mx, my = wx - t * dx, wy - t * dy;
			local z = cz + t * dz - p.z;
			if (t > 0 and t <= far and mx * mx + my * my <= COOP_INFO_RADIUS * COOP_INFO_RADIUS and z >= 0 and z <= COOP_INFO_HEIGHT and (not bestT or t < bestT)) then
				best, bestT = P, t;
			end
		end
	end
	return best;
end
function CoopDrawPlayerInfo(hud)
	COOP_InfoText = nil;
	if (COOP_InfoAt and _time < COOP_InfoAt) then COOP_InfoLast = nil; end -- from the last map (_time restarts)
	local me = _localplayer;
	if (tonumber(cl_display_hud) == 0 or hud.bHide or not me or not me.cnt or not me.cnt.GetViewIntersection or (me.cnt.health or 0) <= 0) then return; end
	local P = CoopAimedPlayer(me);
	if (P) then
		local name = P:GetName() or "";
		if (name ~= "") then name = name.." "; end
		COOP_InfoLast, COOP_InfoAt = name..max(1, floor(P.cnt.health * 100 / max(P.cnt.max_health or 255, 1) + 0.5)).."%", _time; -- alive: never 0%
	end
	if (not COOP_InfoLast or _time < COOP_InfoAt or _time > COOP_InfoAt + COOP_INFO_FADE) then return; end
	local a = 1 - (_time - COOP_InfoAt) / COOP_INFO_FADE;
	Game:SetHUDFont("default", "default");
	local w = Game:GetHudStringSize(COOP_InfoLast, 16, 16);
	Game:WriteHudString(400 - w * 0.5, 320, COOP_InfoLast, 1, 1, 1, a, 16, 16);
	COOP_InfoText = COOP_InfoLast;
end
-- Hud.OnUpdate gets replaced after the COOP Hud script ran (the Hud is reloaded with the level,
-- the harness agent wraps it too): wrap whatever is there now.
function CoopHookHud()
	if (not Hud or not Hud.OnUpdate or Hud.OnUpdate == Hud.COOP_DrawsInfo) then return; end
	local stock = Hud.OnUpdate;
	Hud.OnUpdate = function(self) %stock(self); CoopDrawHud(self); end
	Hud.COOP_DrawsInfo = Hud.OnUpdate;
end
function CoopDrawHud(hud)
	if (COOP_HudDrawnAt == _time) then return; end -- once a frame: another wrapper of Hud.OnUpdate (the harness) can make ours run twice
	COOP_HudDrawnAt = _time;
	CoopDrawPlayerInfo(hud);
	CoopDrawExit();
end

-- The danger meter by the radar (Hud:DrawStealthMeter) reads AI:GetPerception(): on a client, no AI
-- runs and the value is the server's for our player (COOP gamerules CoopSendPerception, "PERC <v>").
-- Never on a host: its AI is the real one (a game that was a client before gets the stock one back).
ClientStuff.ServerCommandTable["PERC"] = function(String, tk)
	if (Game:IsServer()) then return; end
	COOP_MyPerc = tonumber(tk[2]) or 0;
end
function CoopMyPerception(self)
	return COOP_MyPerc or 0;
end
function CoopHookPerception()
	if (not AI) then return; end
	if (AI.GetPerception ~= CoopMyPerception) then COOP_StockPerception = AI.GetPerception; end
	if (Game:IsServer()) then
		if (AI.GetPerception == CoopMyPerception and COOP_StockPerception) then AI.GetPerception = COOP_StockPerception; end
		COOP_MyPerc = nil;
	elseif (AI.GetPerception ~= CoopMyPerception) then
		AI.GetPerception = CoopMyPerception;
	end
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
	if (op == "label") then -- as is: Hud.label takes "@name" like the stock trigger gives it
		COOP_Label, COOP_LabelUntil = text, _time + 1.5;
		return;
	end
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

-- AI and other players' health from the server ("AIHP <id> <hp> ...", COOP gamerules
-- CoopSyncAIHealth): the engine sends health only for our own player, and ours we leave to it.
-- The dead stay dead: deaths come by themselves.
ClientStuff.ServerCommandTable["AIHP"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 1]) do
		local e, hp = System:GetEntity(tonumber(tk[i]) or 0), tonumber(tk[i + 1]);
		if (e and (e.ai or (e.classname == "Player" and e ~= _localplayer)) and e.cnt and e.cnt.health and e.cnt.health > 0 and hp and hp > 0) then e.cnt.health = hp; end
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
			local pickup = BasePickup and e.Physicalize == BasePickup.Physicalize; -- pickup classes copy BasePickup's functions
			if (pickup) then e:EnablePhysics(0); end
			e:SetPos({x = tonumber(tk[i + 1]) or 0, y = tonumber(tk[i + 2]) or 0, z = tonumber(tk[i + 3]) or 0});
			e:SetAngles({x = tonumber(tk[i + 4]) or 0, y = tonumber(tk[i + 5]) or 0, z = tonumber(tk[i + 6]) or 0});
			local boat = e.classname == "Boat" or e.classname == "InflatableBoat" or e.classname == "BoatPatrol";
			if (not pickup and not boat) then e:AwakePhysics(0); end -- a boat floats; asleep, it did not follow its crew
		end
		i = i + 7;
	end
end

-- a helicopter's mounted gun, bound to it on the server only ("MWBIND <gun> <heli> ...", COOP
-- gamerules CoopSyncHeliGuns): bind our copy the way Gunship:InitMountedWeapon does
ClientStuff.ServerCommandTable["MWBIND"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 1]) do
		local gun, heli = System:GetEntity(tonumber(tk[i]) or 0), System:GetEntity(tonumber(tk[i + 1]) or 0);
		if (gun and heli and gun.COOP_BoundTo ~= heli.id and heli.GetHelperPos) then
			heli:Bind(gun);
			gun:SetPos(heli:GetHelperPos("gun", 1));
			gun:SetAngles({x = 0, y = 0, z = 180});
			gun.isBound = heli;
			gun.COOP_BoundTo = heli.id;
			CoopMonEvent("C", "heli gun "..gun.id.." on "..heli:GetName());
		end
		i = i + 2;
	end
end

-- a helicopter's rotor started or stopped on the server ("HROTOR <heli> <0|1> ...", COOP gamerules
-- CoopSyncHeliRotors): do the same to our copy; stopping takes the engine sound away as HC:Land does
ClientStuff.ServerCommandTable["HROTOR"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 1]) do
		local heli, on = System:GetEntity(tonumber(tk[i]) or 0), tonumber(tk[i + 1]);
		if (heli and heli.rotorOn and HC and heli.rotorOn ~= on) then
			if (on == 1) then
				HC.StartRotor(heli);
			else
				HC.StopRotor(heli);
				if (heli.Properties.bFadeEngineSound == 0) then
					heli.CurrEngineFade = heli.FadeEngineTime;
					heli.FadeDir = 2;
				else
					if (heli.sound_engine_stop) then heli:PlaySound(heli.sound_engine_stop); end
					if (heli.sound_engine) then Sound:StopSound(heli.sound_engine); end
				end
			end
			CoopMonEvent("C", "heli rotor "..heli:GetName().." "..on);
		end
		i = i + 2;
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
	COOP_MySkipVote = nil; -- a new vote (CoopSkipVote)
	COOP_SeqPlayed[strsub(String, 5)] = 1; -- a SEQAT for it comes too late (CoopSendSequences)
	if (not Game:IsServer()) then Movie:PlaySequence(strsub(String, 5)); end
end
-- a sequence that started before we joined, with the time since its start (COOP gamerules
-- CoopSendSequences): play it and let the ASI move it to that time (seek_<pid>.txt, the ASI's
-- seekTick); Lua's Movie cannot. Without the ASI it plays from the start.
COOP_SeqPlayed = {};
ClientStuff.ServerCommandTable["SEQAT"] = function(String, tk)
	local name = strsub(String, strlen("SEQAT "..tostring(tk[2]).." ") + 1);
	if (Game:IsServer() or COOP_SeqPlayed[name]) then return; end
	COOP_SeqPlayed[name] = 1;
	Movie:PlaySequence(name);
	CoopMonEvent("C", "sequence at "..tostring(tk[2]).." ms "..name);
	if (COOP_AsiPid) then
		appendto("Mods/FarCryCoop/seek_"..COOP_AsiPid..".txt");
		write(tostring(tk[2]).." "..name.."\n");
		writeto();
	end
end
-- a line from the server shown as a subtitle: seen in a cutscene too (COOP gamerules CoopCountSkipVote)
ClientStuff.ServerCommandTable["MSUB"] = function(String, toktable)
	if (Hud and Hud.AddSubtitle) then Hud:AddSubtitle(strsub(String, 6), 3); end
	CoopMonEvent("C", "subtitle "..strsub(String, 6));
end
-- the players voted to skip the cutscene (COOP gamerules CoopCountSkipVote)
ClientStuff.ServerCommandTable["SEQSKIP"] = function(String, toktable)
	COOP_MySkipVote = nil;
	CoopMonEvent("C", "cutscene skipped");
	if (not Game:IsServer()) then CoopStopCutScenes(); end
end
ClientStuff.ServerCommandTable["SEQSTOP"] = function(String, toktable)
	if (not Game:IsServer()) then Movie:StopSequence(strsub(String, 9)); end
end
