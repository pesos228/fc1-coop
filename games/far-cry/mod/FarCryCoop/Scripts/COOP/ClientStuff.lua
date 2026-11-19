-- FarCryCoop: client side of the co-op rules = single-player ClientStuff plus weapon preload.
Script:LoadScript("scripts/Default/ClientStuff.lua");
Script:LoadScript("scripts/COOP/Monitor.lua");
Script:LoadScript("scripts/COOP/LevelEnd.lua");
Script:LoadScript("scripts/COOP/Version.lua");

-- Campaign missions list only a few weapons in <Weapons><Used>; the server loads the rest on demand,
-- a remote client never does, so it cannot select, draw or fire them. OnInit runs after the level
-- is loaded and before the server sends the player, so load every weapon class here.
COOP_UPDATE_RATE = 50
Coop_DefaultClientOnInit = ClientStuff.OnInit;
function ClientStuff:OnInit()
	Coop_DefaultClientOnInit(self);
	COOP_MyItems, COOP_MyItemsOn = nil, nil; -- the last session's or map's (ITEMS)
	-- written by Player settings (MenuScreens/CoopPlayer.lua): COOP_Color, COOP_Weapons, COOP_LoadoutMode
	-- (used by the host only). A console line (join_<pid>.txt, the harness) sets them first: two games
	-- on one PC share this file.
	if (not COOP_Color) then Script:LoadScript("Mods/FarCryCoop/prefs.lua"); end
	if (CoopApplySteamName) then CoopApplySteamName(); end -- the Steam name over prefs.lua's p_name
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
	-- host changes it for everyone (it starts with CoopMap or coop_map, not coop_start, so
	-- without this a mission end loaded the next map as single player and dropped the clients)
	if (not Game:IsServer()) then COOP_Joined = 1; end
	CoopWrapStartLevel();
	-- the skip key votes (COOP gamerules CoopCountSkipVote) instead of skipping for this player only
	if (Input) then Input:BindCommandToKey("#CoopSkipVote()", "spacebar", 1); end
	CoopBindVoteKeys(); -- F3 / F4, or the keys of Options > Controls (MenuScreens/CoopVote.lua)
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
-- at 4:3 and 16:9 (CCamera::Update, SDK Cry_Camera.h); 45 leaves room for the body's width. The
-- player may choose another angle (MenuScreens/CoopView.lua): half of the angle, as half of 90.
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
	local seecos, fov = COOP_SEE_COS, Game:GetCameraFov(); -- radians; cos takes radians here
	if (fov and fov > 0.5 and fov < 3) then seecos = cos(fov * 0.5); end
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
			if (l < COOP_SEE_DIST and (x * dx + y * dy) >= seecos * l * dl
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

-- The mod's version (COOP Version.lua): say ours, the host answers with its own (COOPVER) or turns us
-- away with a reason that says both (COOP gamerules CoopSetVersion). A host from before this check
-- never answers: after COOP_VER_WAIT seconds say so on the HUD, every 30 s. Not by leaving:
-- Game:Disconnect from here destroys the client inside its own update and the game crashed
-- (runs/20261119-085845); the SDK console has no deferred command.
COOP_HostVersion, COOP_VerAsked, COOP_VerOld = nil, nil, nil; -- nothing from an earlier connection
function CoopSendVersion()
	if (Game:IsServer()) then COOP_HostVersion = COOP_VERSION; return; end
	COOP_HostVersion, COOP_VerAsked, COOP_VerOld = nil, _time, nil; -- asked again on every spawn: maybe another host
	Client:SendCommand("COOPVER "..COOP_VERSION);
end
ClientStuff.ServerCommandTable["COOPVER"] = function(String, tk)
	COOP_HostVersion, COOP_VerAsked, COOP_VerOld = tk[2], nil, nil;
end
function CoopCheckHostVersion()
	local t = COOP_VerOld or COOP_VerAsked;
	if (not t or COOP_HostVersion) then return; end
	if (t > _time) then t = _time; end -- _time restarts with a map load
	if (_time - t < (COOP_VerOld and 30 or COOP_VER_WAIT)) then
		if (COOP_VerOld) then COOP_VerOld = t; else COOP_VerAsked = t; end
		return;
	end
	if (not COOP_VerOld) then CoopMonEvent("C", "version: the host never said its version"); end
	COOP_VerAsked, COOP_VerOld = nil, _time;
	if (Hud and Hud.AddMessage) then
		Hud:AddMessage(format("The host runs an older FC1 Co-op (yours is %s): everyone needs the same version", COOP_VERSION));
	end
end

Coop_DefaultClientOnUpdate = ClientStuff.OnUpdate;
function ClientStuff:OnUpdate()
	Coop_DefaultClientOnUpdate(self);
	-- a use-trigger hint the server sends once a second while we stand in it (MHUD label)
	if (COOP_LabelUntil and _time < COOP_LabelUntil and _time + 3 > COOP_LabelUntil and Hud) then Hud.label = COOP_Label; end
	CoopMonitor("C");
	call(CoopCheckHostVersion, {}, "x", function(msg) System:LogAlways("coop: version check error: "..tostring(msg)); end);
	call(CoopDrawGates, {}, "x", function(msg) if (not COOP_GateErr) then COOP_GateErr = 1; System:LogAlways("coop: gate ring error: "..tostring(msg)); end end);
	CoopShowSpawnWeapon();
	CoopApplyMyItems();
	CoopHookHud();
	if (CoopViewTick) then -- field of view (MenuScreens/CoopView.lua)
		call(CoopViewTick, {}, "x", function(msg) if (not COOP_ViewErr) then COOP_ViewErr = 1; System:LogAlways("coop: view error: "..tostring(msg)); end end);
	end
	CoopHookPerception();
	CoopWrapClientSeat();
	CoopWrapClientAIDriver();
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
		call(CoopWrapClientReloads, {}, "x", function(msg)
			if (not COOP_ReloadErrorLogged) then COOP_ReloadErrorLogged = 1; System:LogAlways("coop: reload wrap error: "..tostring(msg)); end
		end);
	end
end

-- CPlayer::UpdateWeapon reloads by itself when the clip is empty, unless the player is under water
-- (m_stats.underwater, eye position below the water level) or swims (SDK XPlayer.cpp). An AI's eye
-- position is its feet (no camera offset): on the server an AI never reloads with its feet in water.
-- Its copy here has a player's eye height and counts as under water only 1.5-1.9 m deeper, and the
-- clip reaches it as "empty or not" (CPlayer::Write): it reloaded every frame, BasicWeapon.Client:Reload
-- restarting the reload animation on layer 4 up to 170 times a second (upper body stuck on its first
-- frame). The server's rule is kept here: no reload animation for a copy whose feet are under water
-- (Game:GetWaterHeight(pos): sea and water volumes, as the engine's level for the entity).
-- CWeaponClass caches Client:Reload when the class loads, so the copy's StartAnimation is wrapped.
-- tests/ai-water-reload.txt
function CoopWrapClientReload(e)
	e.COOP_ReloadWrapped = 1;
	e.COOP_OrigStartAnim = e.StartAnimation;
	e.StartAnimation = function(...)
		local self, anim = arg[1], arg[3];
		-- not the server's own ("ANIM"): an AI walking out of the water reloads on the server while its
		-- copy here, a little behind, still has its feet in
		if (not COOP_AnimFromServer and type(anim) == "string" and arg[4] == 4 and strfind(anim, "reload", 1, 1)) then
			local p = self:GetPos();
			local z = p.z; -- GetPos returns a shared table
			if (z < Game:GetWaterHeight(p)) then return; end
		end
		return call(self.COOP_OrigStartAnim, arg);
	end
end
function CoopWrapClientReloads()
	for i, e in System:GetEntities() do
		if (e.ai and e.cnt and not e.COOP_ReloadWrapped) then CoopWrapClientReload(e); end
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
-- An AI is seated only when the server says so ("VSEAT", COOP gamerules CoopWrapUserEntered, and
-- CoopSendSeats for the crews already seated when we join), at the bind if VSEAT came first.
-- VC:OnBind marks every bind with time -20, a mercenary that just starts to get in too: seated at
-- the bind, it sat 1-4 s before the server had it in the seat (frozen in the sit pose while it
-- still walked, tests/board-early.txt).
COOP_SeatPending = {} -- entity id -> vehicle id: VSEAT came before the bind
function CoopSeatUser(v, tbl)
	-- once per bind (VC:AddUserT stamps entertime): the bind and VSEAT may both seat the same AI
	if (tbl.entertime and tbl.COOP_SeatedAt == tbl.entertime and tbl.COOP_SeatedEnt == tbl.entity) then return; end
	tbl.COOP_SeatedAt, tbl.COOP_SeatedEnt = tbl.entertime, tbl.entity;
	-- as the server's cnt:SetUser does: the client only gets the bind, and the AI's own physics stayed
	-- on and pulled it to its body every frame (Steam's boat driver flipped between its seat and the
	-- sea floor near 0,0 of the map in about 1 of 4 runs, tests/steam-boat-crew.txt). VC:ReleaseUser
	-- (cnt:ReleaseUser) turns it on again when it gets out.
	tbl.entity:ActivatePhysics(0);
	tbl.entity:SetPos(v:GetHelperPos(tbl.in_helper, 1));
	-- the server's sit animation ("ANIM") went out when it seated the crew at the map start,
	-- before this client was in: the gunner stood in the boat
	if (tbl.sit_anim) then
		tbl.entity:StartAnimation(0, tbl.sit_anim, 0, 0, 1);
		tbl.entity:ForceCharacterUpdate(0);
		CoopMonEvent("C", "anim "..tbl.entity:GetName().." "..tbl.sit_anim);
	end
end
function CoopWrapClientSeat()
	if (not VC or VC.COOP_ClientSeat or Game:IsServer()) then return; end
	VC.COOP_ClientSeat = 1;
	local old = VC.AddUserT;
	VC.AddUserT = function(self, tbl)
		local r = %old(self, tbl);
		if (type(tbl) == "table" and tbl.entity and tbl.state == 1 and tbl.time and tbl.time <= -10) then
			if (COOP_SeatPending[tbl.entity.id] == self.id or not tbl.in_anim) then
				-- a seat with no entering animation is bound only in VC:UserEntered, when the AI is
				-- already in it: seat at the bind. Left unseated until VSEAT, Steam's boat driver
				-- got "pos is invalid" every frame for the rest of the run in 2 of 7
				-- (tests/steam-boat-crew.txt).
				COOP_SeatPending[tbl.entity.id] = nil;
				CoopSeatUser(self, tbl);
			end
		end
		return r;
	end
end
ClientStuff.ServerCommandTable["VSEAT"] = function(String, tk)
	if (Game:IsServer() or not VC) then return; end
	local v, e = System:GetEntity(tonumber(tk[2]) or 0), System:GetEntity(tonumber(tk[3]) or 0);
	if (not v or not e) then return; end
	local seats = {v.driverT, v.gunnerT};
	for i, t in (v.passengersTT or {}) do tinsert(seats, t); end
	for i, t in seats do
		if (type(t) == "table" and t.entity == e) then
			COOP_SeatPending[e.id] = nil;
			CoopSeatUser(v, t);
			return;
		end
	end
	COOP_SeatPending[e.id] = v.id;
end
CoopWrapClientSeat();

-- The server drives every vehicle and helicopter; a client's copy never gets its AI on. The map's
-- events run on the client too (Gunship Event_GoPath / GoPatrol / GoAttack / Reinforcment, the
-- vehicles' paths, VehicleCommon's own enter/leave) and call VC.AIDriver(self, 1). A helicopter's
-- AI then flew the copy itself between server updates (MoveLikeAHelicopter, aircontrol 1): upright
-- and falling, the server's attitude every other frame (Training Gunship3, tests/heli-flight.txt).
-- Switching the whole AI system off (ai_systemupdate 0) does not stop it (1459 jumps in 20 s);
-- the entity's own AIEVENT_DISABLE does. Disabling still goes through.
function CoopWrapClientAIDriver()
	if (not VC or Game:IsServer() or (VC.COOP_AIDriver and VC.AIDriver == VC.COOP_AIDriver)) then return; end
	local old = VC.AIDriver;
	VC.COOP_AIDriver = function(self, enable)
		if (enable ~= 0 and not Server) then return; end
		return %old(self, enable);
	end
	VC.AIDriver = VC.COOP_AIDriver;
end
CoopWrapClientAIDriver();

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
-- Dead: "Press Mouse 1 to respawn" (owner, 2026-11-19: nothing said how to get back up). The
-- server respawns a dead player who presses fire (SDK CXServerSlot: ACTION_FIRE0 while not alive ->
-- GameRules:OnClientRequestRespawn); the host's own click counts once GameRules.TimeRespawn (3 s)
-- has passed, so the hint shows after that for everyone. The key is the one bound to fire in the
-- dead player's action map ("player_dead", Options > Controls changes it with the others), named
-- as the Controls list names it ("@control<key id>", localized by WriteHudString).
-- COOP_RespawnHint is the text drawn this frame (nil: nothing), read by tests/respawn-hint.txt.
COOP_RESPAWN_HINT_DELAY = 3
COOP_RESPAWN_HINT_FADE = 0.5
function CoopFireKeyLabel()
	local acts = Game:GetActions() or {};
	for i, A in acts do
		if (A.name == "FIRE0") then
			local b = Input:GetBinding("player_dead", A.id);
			if (not b or not b[1]) then b = Input:GetBinding((A.actionmaps and A.actionmaps[1]) or "default", A.id); end
			if (b and b[1] and b[1].key_id) then
				if (b[1].mod and b[1].mod_id) then return "@control"..b[1].mod_id.." + @control"..b[1].key_id; end
				return "@control"..b[1].key_id;
			end
			break;
		end
	end
	return "@control65536"; -- mouse 1, the default
end
function CoopDrawRespawnHint(hud)
	COOP_RespawnHint = nil;
	local me = _localplayer;
	if (not me or me.classname ~= "Player" or not me.cnt or (me.cnt.health or 0) > 0) then COOP_DeadId = nil; return; end
	if (COOP_DeadId ~= me.id or not COOP_DeadAt or _time < COOP_DeadAt) then -- _time restarts with a map load
		COOP_DeadId, COOP_DeadAt, COOP_DeadKey = me.id, _time, CoopFireKeyLabel(); -- the key: once per death
	end
	local t = _time - COOP_DeadAt - COOP_RESPAWN_HINT_DELAY;
	if (t < 0 or tonumber(cl_display_hud) == 0 or hud.bHide) then return; end
	local a = min(1, t / COOP_RESPAWN_HINT_FADE);
	local s = "Press "..COOP_DeadKey.." to respawn";
	Game:SetHUDFont("default", "default");
	local w = Game:GetHudStringSize(s, 18, 18);
	Game:WriteHudString(400 - w * 0.5, 420, s, 1, 1, 1, a, 18, 18);
	COOP_RespawnHint = s;
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
	CoopDrawRespawnHint(hud);
	CoopDrawExit();
	CoopDrawVoice(hud);
	CoopDrawVote(hud);
end

-- Voice chat (asi/voice.c, push-to-talk: K, or the key set in Options > Controls, MenuScreens/
-- CoopVoice.lua): the ASI says who talks. A box per speaker above the health bars, as Source games
-- list speakers (one that stops fades out, the others slide into its place), drawn as the game's
-- own HUD is: a dark fill with a thin dull green outline; the Steam avatar (avatars/<SteamID
-- hex>.dds, written by the ASI; an empty frame without Steam) and the name. We come first while our
-- key is held. Also in cutscenes, when the rest of the HUD is hidden.
COOP_VoiceTalk = COOP_VoiceTalk or {}   -- speaker id (SteamID hex, "" is us) -> {name, t, since, off, y}
COOP_VoiceAvatar = COOP_VoiceAvatar or {} -- speaker id ("" is us) -> avatar file name
COOP_VoiceTex = COOP_VoiceTex or {}     -- avatar file name -> texture id, 0 if it did not load
COOP_VOICE_KEEP = 1.5 -- s: the ASI says "talks" every 0.5 s while one talks; silent longer: done
COOP_VOICE_FADE = 0.4 -- s: a box fades out over this
COOP_VOICE_SLIDE = 12 -- per s: how fast a box moves to its new place
function CoopVoiceSet(id, name, on)
	local v = COOP_VoiceTalk[id];
	if (on == 1) then
		if (v and not v.off and CoopVoiceFresh(v.t)) then v.t, v.name = _time, name; -- keeps its place
		else COOP_VoiceTalk[id] = {name = name, t = _time, since = _time}; end
	elseif (v and not v.off) then
		v.off = _time;
	end
end
function CoopVoice_Talk(id, name, on, av)
	if (av and av ~= "") then COOP_VoiceAvatar[id] = av; end
	CoopVoiceSet(id, name, on);
end
function CoopVoice_Me(name, on, av)
	if (av and av ~= "") then COOP_VoiceAvatar[""] = av; end
	CoopVoiceSet("", name, on);
end
function CoopVoice_Avatar(id, av)
	COOP_VoiceAvatar[id] = av;
end
function CoopVoiceFresh(t) -- refreshed lately (_time starts again with a map: older is newer)
	return t and t <= _time and _time - t < COOP_VOICE_KEEP;
end
function CoopVoiceTalking(id) -- for the harness: 1 while a box is up and not fading
	local v = COOP_VoiceTalk[id];
	if (v and not v.off and CoopVoiceFresh(v.t)) then return 1; end
	return nil; -- a value: tostring(CoopVoiceTalking(id)) errs on none (Lua 4)
end
function CoopVoiceTexture(av)
	if (not av or av == "") then return nil; end
	local t = COOP_VoiceTex[av];
	if (not t) then
		t = System:LoadImage("Mods/FarCryCoop/avatars/"..av..".dds") or 0;
		COOP_VoiceTex[av] = t;
	end
	if (t == 0) then return nil; end
	return t;
end
-- the boxes sit over the health bars' block (x 560-722 in 800x600 units), the lowest one ends at
-- y 536, 4 apart
COOP_VOICE_X, COOP_VOICE_W, COOP_VOICE_H, COOP_VOICE_BOTTOM = 560, 162, 26, 536
COOP_VOICE_LINE = {0.3, 0.56, 0.43, 0.8} -- the outline of the HUD's bars and radar
function CoopVoiceFrame(x, y, w, h, a)
	local c = COOP_VOICE_LINE;
	System:DrawImageColor(COOP_VoiceBox, x, y, w, 1, 4, c[1], c[2], c[3], c[4] * a);
	System:DrawImageColor(COOP_VoiceBox, x, y + h - 1, w, 1, 4, c[1], c[2], c[3], c[4] * a);
	System:DrawImageColor(COOP_VoiceBox, x, y + 1, 1, h - 2, 4, c[1], c[2], c[3], c[4] * a);
	System:DrawImageColor(COOP_VoiceBox, x + w - 1, y + 1, 1, h - 2, 4, c[1], c[2], c[3], c[4] * a);
end
function CoopVoiceFit(name, w) -- the name cut to w with ".." (15 px font)
	if (Game:GetHudStringSize(name, 15, 15) <= w) then return name; end
	local n = strlen(name);
	while (n > 1 and Game:GetHudStringSize(strsub(name, 1, n).."..", 15, 15) > w) do n = n - 1; end
	return strsub(name, 1, n)..".."
end
function CoopDrawVoice(hud)
	local dt = _time - (COOP_VoiceDrawnAt or _time);
	COOP_VoiceDrawnAt = _time;
	if (dt < 0 or dt > 0.5) then dt = 0.5; end -- a new map, a pause: just snap
	-- talking or fading out; gone after the fade (an "off" lost on the way: the refresh stops)
	local rows = {};
	for id, v in COOP_VoiceTalk do
		if (not v.off and not CoopVoiceFresh(v.t)) then v.off = (v.t and v.t <= _time) and v.t + COOP_VOICE_KEEP or _time; end
		if (v.off and (v.off > _time or _time - v.off >= COOP_VOICE_FADE)) then COOP_VoiceTalk[id] = nil;
		else tinsert(rows, {id = id, v = v}); end
	end
	-- us first, then who started first; a fading box keeps its place until it is gone
	sort(rows, function(a, b)
		if (a.id == "" or b.id == "") then return a.id == ""; end
		if (a.v.since ~= b.v.since) then return a.v.since < b.v.since; end
		return a.id < b.id; -- started in the same frame: still one order
	end);
	local n = getn(rows);
	-- shown with the HUD hidden too: cutscenes set cl_display_hud 0 (Hud.OnUpdate still runs), and
	-- the players talk through them (owner, 2026-11-19)
	if (n == 0) then return; end
	if (not COOP_VoiceBox) then COOP_VoiceBox = System:LoadImage("Textures/white16x16.dds") or 0; end
	if (COOP_VoiceBox == 0) then return; end
	Game:SetHUDFont("default", "default");
	local x = COOP_VOICE_X;
	for i = 1, n do
		local v = rows[i].v;
		local y = COOP_VOICE_BOTTOM - (n - i + 1) * (COOP_VOICE_H + 4) + 4;
		if (not v.y) then v.y = y; else v.y = v.y + (y - v.y) * min(1, dt * COOP_VOICE_SLIDE); end
		local a = 1;
		if (v.off) then a = max(0, 1 - (_time - v.off) / COOP_VOICE_FADE); end
		local yy = floor(v.y + 0.5);
		System:DrawImageColor(COOP_VoiceBox, x, yy, COOP_VOICE_W, COOP_VOICE_H, 4, 0, 0, 0, 0.45 * a);
		CoopVoiceFrame(x, yy, COOP_VOICE_W, COOP_VOICE_H, a);
		local tex = CoopVoiceTexture(COOP_VoiceAvatar[rows[i].id]);
		if (tex) then System:DrawImageColor(tex, x + 4, yy + 4, 18, 18, 4, 1, 1, 1, a); end
		CoopVoiceFrame(x + 3, yy + 3, 20, 20, a);
		Game:WriteHudString(x + 30, yy + 5, CoopVoiceFit(v.name or "", COOP_VOICE_W - 36), 0.9, 0.92, 0.86, a, 15, 15);
	end
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
	-- (COOP gamerules CoopSetKey): COOP_PlayerKey (the Steam ID, steam.c), else the player name we asked
	-- for (the server renames a second "Jack Carver" to "Jack Carver_")
	Client:SendCommand("COOPID "..tostring(COOP_PlayerKey or getglobal("p_name") or ""));
	CoopSendVersion();
	-- the name others see by our voice (the ASI's voice chat, asi/voice.c); the player's own name is
	-- still "" here
	local vname = _localplayer and _localplayer:GetName();
	if (not vname or vname == "") then vname = getglobal("p_name"); end
	System:ExecuteCommand("coop_voice name "..tostring(vname or "Player"));
	if (CoopVoiceApply) then CoopVoiceApply(); end -- the talk key of Options > Controls
	if (CoopVoicePatchMenus) then CoopVoicePatchMenus(); end -- the chat line holds the key
	if (CoopViewPatchMenus) then CoopViewPatchMenus(); end -- Options > Game: field of view
	-- player settings (prefs.lua; COOP gamerules CoopSetPrefs); the host sends them too, over loopback
	if (COOP_Color) then Client:SendCommand("PREF "..COOP_Color.." "..tostring(COOP_Weapons or "")); end
	-- again once connected: asked in OnInit only, the server kept sending the default 20
	if (Client and Client.SetUpdateRate) then Client:SetUpdateRate(COOP_UPDATE_RATE); end
end

-- shirt color of a player from Player settings (COOP gamerules CoopApplyPrefs). Multiplayer turns on
-- the color mask shader with the "FX" command (BasicPlayer.SecondShader_TeamColoring, effect 2);
-- the single-player rules never do. The shader's ColorR/G/B come from entity.cnt:GetColor(),
-- which the single-player spawn leaves white and Lua cannot set: UpdatePlayerEffectParams is
-- wrapped to use the player's color (entity.COOP_Color) instead.
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

-- The zone of a gate (COOP gamerules COOP_GATES): "GATE <trigger id> <x1> <y1> <x2> <y2> <z>"
-- every 2 s while it waits, "GATE <id> off" once it fired. Its outline in sparks on the floor shows
-- where to stand; it goes after 5 s without news (a lost "off", a new map). The host draws it too.
COOP_GateMarks = {}
ClientStuff.ServerCommandTable["GATE"] = function(String, tk)
	local id = tonumber(tk[2]);
	if (not id) then return; end
	if (tk[3] == "off") then COOP_GateMarks[id] = nil; return; end
	local x1, y1, x2, y2, z = tonumber(tk[3]), tonumber(tk[4]), tonumber(tk[5]), tonumber(tk[6]), tonumber(tk[7]);
	if (not (x1 and y1 and x2 and y2 and z)) then return; end
	if (not COOP_GateMarks[id]) then CoopMonEvent("C", format("gate %d zone %.1f,%.1f - %.1f,%.1f z %.1f", id, x1, y1, x2, y2, z)); end
	-- the outline, a spark every 0.45 m or so
	local corners = {{x1, y1}, {x2, y1}, {x2, y2}, {x1, y2}, {x1, y1}};
	local pts, k = {}, 0;
	for c = 1, 4 do
		local ax, ay, bx, by = corners[c][1], corners[c][2], corners[c + 1][1], corners[c + 1][2];
		local n = max(1, floor(sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 0.45 + 0.5));
		for i = 0, n - 1 do
			k = k + 1;
			pts[k] = {x = ax + (bx - ax) * i / n, y = ay + (by - ay) * i / n, z = z + 0.05};
		end
	end
	COOP_GateMarks[id] = {x = (x1 + x2) / 2, y = (y1 + y2) / 2, pts = pts, n = k, t = _time + 5};
end
function CoopDrawGates()
	if (not next(COOP_GateMarks)) then return; end
	local at = COOP_GateDrawAt or 0;
	if (at > _time and at - _time <= 0.2) then return; end -- _time restarts with a map load
	COOP_GateDrawAt = _time + 0.15;
	if (not COOP_GateSpark) then
		COOP_GateSpark = {focus = 0, start_color = {0.35, 1, 0.45}, end_color = {0.1, 0.6, 0.2}, speed = 0, count = 1,
			size = 0.1, size_speed = 0, gravity = {x = 0, y = 0, z = 0.35}, rotation = {x = 0, y = 0, z = 0},
			lifetime = 0.9, frames = 0, blend_type = 2, draw_last = 1, tid = System:LoadTexture("Textures/Decal/Spark.dds")};
	end
	local me = _localplayer and _localplayer:GetPos();
	for id, g in COOP_GateMarks do
		if (g.t < _time or g.t > _time + 6) then -- old news, or from before a map load (_time restarts)
			COOP_GateMarks[id] = nil;
		elseif (not me or (me.x - g.x) * (me.x - g.x) + (me.y - g.y) * (me.y - g.y) < 60 * 60) then
			for i = 1, g.n do
				Particle:CreateParticle(g.pts[i], {x = 0, y = 0, z = 1}, COOP_GateSpark);
			end
		end
	end
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

-- where the spawn-sleepers lie on the server ("AIPOS <id> x y z ...", COOP gamerules
-- CoopSyncSleepers): ours may still be at the level's heights (REINF_ONE2 in the air inside Gunship5)
ClientStuff.ServerCommandTable["AIPOS"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 3]) do
		local e = System:GetEntity(tonumber(tk[i]) or 0);
		if (e and e.ai and not e.theVehicle and e.cnt and e.cnt.health and e.cnt.health > 0) then -- a seat is ours
			e:SetPos({x = tonumber(tk[i + 1]) or 0, y = tonumber(tk[i + 2]) or 0, z = tonumber(tk[i + 3]) or 0});
		end
		i = i + 4;
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

-- an AI's own animation system on or off, as on the server (COOP gamerules CoopSendAnimSys)
ClientStuff.ServerCommandTable["AISYS"] = function(String, tk)
	if (Game:IsServer()) then return; end
	local i = 2;
	while (tk[i + 1]) do
		local e = System:GetEntity(tonumber(tk[i]) or 0);
		local v = tonumber(tk[i + 1]);
		if (e and e.cnt and v and e.cnt.AnimationSystemEnabled ~= v) then
			e.cnt.AnimationSystemEnabled = v;
			CoopMonEvent("C", "animsys "..e:GetName().." "..v);
		end
		i = i + 2;
	end
end

-- AI animation started by the server (COOP gamerules CoopAnimStarted), on the server's layer. A
-- listen host played it already: replayed on layer 3 it left looped animations over its own AI's walk.
-- A copy here has no AI object, and the engine goes back to the last looped animation of layers 0 and
-- 3 after a one-shot one there only for an entity with one (layer 0 was off on the copy too): the ASI
-- turns that on for the copy ("idle3", FarCryCoopNet.asi), or a merc's job pose ended with its start
-- animation (push-ups) or left it in the bind pose (sitting).
ClientStuff.ServerCommandTable["ANIM"] = function(String, toktable)
	local e = System:GetEntity(tonumber(toktable[2]) or 0);
	if (e and toktable[3] and not Game:IsServer()) then
		if (not e.COOP_Idle3 and COOP_AsiPid) then
			e.COOP_Idle3 = 1;
			appendto("Mods/FarCryCoop/seek_"..COOP_AsiPid..".txt");
			write("idle3 "..e.id.."\n");
			writeto();
		end
		COOP_AnimFromServer = 1; -- CoopWrapClientReload
		call(e.StartAnimation, {e, 0, toktable[3], tonumber(toktable[4]) or 3, 0.1}, "x", function(msg) System:LogAlways("coop: ANIM error: "..tostring(msg)); end);
		COOP_AnimFromServer = nil;
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

-- Votes (COOP gamerules CoopCallVote; called from the in-game menu, MenuScreens/CoopVote.lua):
-- a box on the left of the screen while one is on, as TF2 shows it, drawn as the voice boxes are
-- (the game's HUD: a dark fill, a thin dull green outline): the question, the keys with the yes
-- and no count, the time left as a bar. The result stays a few seconds. The keys (F3 yes, F4 no
-- by default; F1 is the game's view change) are kept by MenuScreens/CoopVote.lua.
-- COOP_VoteBox is what the box shows, read by tests/votes.txt.
COOP_VOTE_RESULT_TIME = 4
COOP_VOTE_X, COOP_VOTE_Y, COOP_VOTE_W, COOP_VOTE_H = 8, 150, 236, 66
function CoopVoteYes() CoopCastMyVote(1); end
function CoopVoteNo() CoopCastMyVote(0); end
function CoopCastMyVote(v)
	local b = COOP_VoteBox;
	if (not Client or not b or b.result) then return; end
	b.mine = v;
	Client:SendCommand("CASTVOTE "..v);
	CoopMonEvent("C", "vote "..v);
end
function CoopBindVoteKeys()
	if (not Input) then return; end
	if (CoopVoteKeysLoad) then CoopVoteKeysLoad(); end
	Input:BindCommandToKey("#CoopVoteYes()", strlower(tostring(COOP_VoteYesKey or "f3")), 1);
	Input:BindCommandToKey("#CoopVoteNo()", strlower(tostring(COOP_VoteNoKey or "f4")), 1);
end
ClientStuff.ServerCommandTable["VOTEUP"] = function(String, tk)
	local s, e, secs, y, n, need, text = strfind(String, "^VOTEUP (%d+) (%d+) (%d+) (%d+) (.*)$");
	if (not s) then return; end
	local b = COOP_VoteBox;
	local mine = b and not b.result and b.text == text and b.mine or nil;
	COOP_VoteBox = {text = text, yes = tonumber(y), no = tonumber(n), need = tonumber(need),
		ends = _time + tonumber(secs), len = max(1, tonumber(secs)), mine = mine};
	if (b and not b.result and b.text == text) then COOP_VoteBox.len = b.len; end
	if (not (b and b.text == text and not b.result)) then CoopMonEvent("C", "vote on: "..text); end
end
ClientStuff.ServerCommandTable["VOTEEND"] = function(String, tk)
	local s, e, ok, text = strfind(String, "^VOTEEND (%d) (.*)$");
	if (not s) then return; end
	COOP_VoteBox = {text = text, result = (ok == "1") and 1 or 0, ends = _time + COOP_VOTE_RESULT_TIME};
	CoopMonEvent("C", "vote "..((ok == "1") and "passed" or "failed")..": "..text);
end
ClientStuff.ServerCommandTable["VOTEMSG"] = function(String, tk)
	local text = strsub(String, 9);
	if (Hud and Hud.AddMessage) then Hud:AddMessage(text); end
	CoopMonEvent("C", "vote message: "..text);
end
function CoopDrawVote(hud)
	local b = COOP_VoteBox;
	if (not b) then return; end
	-- shown its time (a vote whose end got lost: 2 s more), or from the last map (_time restarts)
	if (_time > b.ends + (b.result and 0 or 2) or b.ends > _time + 120) then COOP_VoteBox = nil; return; end
	if (tonumber(cl_display_hud) == 0 or hud.bHide) then return; end
	if (not COOP_VoiceBox) then COOP_VoiceBox = System:LoadImage("Textures/white16x16.dds") or 0; end
	if (COOP_VoiceBox == 0) then return; end
	local x, y, w, h = COOP_VOTE_X, COOP_VOTE_Y, COOP_VOTE_W, COOP_VOTE_H;
	local a = 1;
	if (b.result) then a = min(1, (b.ends - _time) / 0.5); h = 58; end
	System:DrawImageColor(COOP_VoiceBox, x, y, w, h, 4, 0, 0, 0, 0.5 * a);
	CoopVoiceFrame(x, y, w, h, a);
	Game:SetHUDFont("default", "default");
	Game:WriteHudString(x + 8, y + 5, "Vote", 0.62, 0.8, 0.5, a, 13, 13);
	Game:WriteHudString(x + 8, y + 20, CoopVoiceFit(b.text or "", w - 16), 0.95, 0.95, 0.9, a, 15, 15);
	if (b.result) then
		local t, r, g = "Vote failed", 0.95, 0.4;
		if (b.result == 1) then t, r, g = "Vote passed", 0.5, 0.95; end
		Game:WriteHudString(x + 8, y + 38, t, r, g, 0.4, a, 14, 14);
		return;
	end
	local yk, nk = strupper(tostring(COOP_VoteYesKey or "f3")), strupper(tostring(COOP_VoteNoKey or "f4"));
	local ys, ns = format("%s Yes: %d", yk, b.yes or 0), format("%s No: %d", nk, b.no or 0);
	local ya, na = 0.75, 0.75;
	if (b.mine == 1) then ya = 1; elseif (b.mine == 0) then na = 1; end
	Game:WriteHudString(x + 8, y + 38, ys, 0.6 * ya, 0.95 * ya, 0.5 * ya, a, 14, 14);
	Game:WriteHudString(x + 8 + w * 0.5, y + 38, ns, 0.95 * na, 0.5 * na, 0.45 * na, a, 14, 14);
	-- the time left
	local f = max(0, min(1, (b.ends - _time) / (b.len or 30)));
	System:DrawImageColor(COOP_VoiceBox, x + 8, y + h - 8, (w - 16) * f, 3, 4, COOP_VOICE_LINE[1], COOP_VOICE_LINE[2], COOP_VOICE_LINE[3], 0.9 * a);
end
