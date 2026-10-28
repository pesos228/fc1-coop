-- FarCryCoop: campaign co-op rules. For now the single-player rules as they are:
-- they already handle per-slot connect, disconnect and checkpoint respawn.
Script:LoadScript("scripts/Default/gamerules.lua");
Script:LoadScript("scripts/COOP/Monitor.lua");
CoopMonEvent("S", "map "..tostring(COOP_Map)); -- this file runs on every map load

-- Load every weapon class on the server before players spawn: a player's weapon table
-- (CPlayer::m_mapPlayerWeapons) only has the classes loaded at that time, so weapons outside the
-- mission's <Weapons><Used> list could never be given (MakeWeaponAvailable returned -1).
-- On the first map load this file runs before WeaponClassesEx exists, so GameRules:OnUpdate
-- does it on its first tick (a loop here aborted the whole file: no co-op rules at all).
COOP_WeaponsLoaded = nil -- this file runs on every map load
function CoopPreloadWeapons()
	if (COOP_WeaponsLoaded or not WeaponClassesEx) then return; end
	COOP_WeaponsLoaded = 1;
	for name, def in WeaponClassesEx do
		Game:AddWeapon(name);
	end
end

-- On a dedicated server the AI puppets stay asleep: they stand still and never notice
-- anyone (the single-player game wakes them around its local player). Once a second wake
-- the puppets near any player. Hidden puppets (Event_Hide) are left to their mission triggers.
COOP_WAKE_RADIUS = 150 -- ponytail: fixed radius, tune if far snipers or patrols stay frozen
-- Puppets placed asleep (bSleepOnSpawn) wait for a mission trigger, and some of those triggers
-- never reach them on a dedicated server (Training's first village slept with the player
-- standing in it and shooting them). Wake them once a player is this close, or hits them.
COOP_SLEEPER_RADIUS = 40
COOP_NextWake = 0

-- AI animation keyframes without animations. A dedicated server never ticks character
-- animations (nothing is rendered), so no animation event ever arrives, and AI actions that wait
-- for one never happen: melee hits (KEYFRAME_APPLY_MELEE), drawing the gun (HOLD_GUN), the big
-- mutant's rocket (FIRE_*), job attachments. Every AI animation started from Lua goes through
-- entity:StartAnimation or entity:InsertAnimationPipe: those are wrapped per entity, and the
-- keyframes of that animation (entity.SoundEvents = AI_ANIM_KEYFRAMES of its KEYFRAME_TABLE,
-- {anim, frame, number}) run frame/COOP_ANIM_FPS seconds later through the normal keyframe
-- handler. The animation is also sent to the clients ("ANIM"): AI animations are not replicated.
-- A real keyframe (listen-server host watching that AI) cancels the pending fake one.
-- Animations the engine starts itself (jumps, locomotion) are not covered.
COOP_ANIM_FPS = 30
COOP_KeyDue = {} -- {t, id, number}
function CoopAnimStarted(e, anim)
	if (type(anim) ~= "string" or not e.cnt or e.cnt.health <= 0) then return; end
	-- behaviours re-insert the same animation while it plays: once per animation length
	e.COOP_AnimNext = e.COOP_AnimNext or {};
	if (_time < (e.COOP_AnimNext[anim] or 0) and e.COOP_AnimNext[anim] - _time < 30) then return; end
	e.COOP_AnimNext[anim] = _time + max(e:GetAnimationLength(anim) or 0, 0.3);
	-- idle animations of every AI on the map were ~5 reliable messages a second for nothing
	if (strsub(anim, 1, 4) ~= "idle") then Server:BroadcastCommand("ANIM "..e.id.." "..anim); end
	for i, ev in (e.SoundEvents or {}) do
		if (ev[1] == anim and type(ev[3]) == "number" and ev[3] ~= KEYFRAME_BREATH_SOUND) then
			tinsert(COOP_KeyDue, {t = _time + ev[2] / COOP_ANIM_FPS, id = e.id, number = ev[3]});
		end
	end
end
function CoopWrapAnim(e)
	e.COOP_AnimWrapped = 1;
	local start, pipe = e.StartAnimation, e.InsertAnimationPipe;
	e.StartAnimation = function(self, pos, anim, a, b, c)
		CoopAnimStarted(self, anim);
		return %start(self, pos, anim, a, b, c);
	end
	e.InsertAnimationPipe = function(self, anim, a, b, c, d)
		CoopAnimStarted(self, anim);
		return %pipe(self, anim, a, b, c, d);
	end
end
function CoopUpdateKeys()
	local keep, k = {}, 0;
	for i = 1, getn(COOP_KeyDue) do
		local d = COOP_KeyDue[i];
		if (_time >= d.t or d.t - _time > 10) then -- second test: _time restarted on map load
			local e = System:GetEntity(d.id);
			if (e and e.cnt and e.cnt.health > 0) then
				CoopMonEvent("S", "key "..e:GetName().." "..d.number); -- same as sp-monitor
				COOP_FakeKey = 1;
				BasicPlayer.Server_EventHandler[ScriptEvent_AnimationKey](e, {number = d.number});
				COOP_FakeKey = nil;
			end
		else
			k = k + 1; keep[k] = d;
		end
	end
	COOP_KeyDue = keep;
end
-- AI behaviours compare players with _localplayer (nil on a dedicated server, the host on a
-- listen server): "retaliate against who shot me", the trigen jump, cars and boats (which even
-- index _localplayer.theVehicle and break). While any behaviour function runs, _localplayer is
-- the player this AI deals with: the sender if it is a player, else its attention target if it
-- is a player, else the nearest player. Errors are caught so _localplayer is always restored,
-- and logged once per function.
COOP_AIPlayers = {}
function CoopAIPlayer(entity, sender)
	if (type(sender) == "table" and sender.classname == "Player") then return sender; end
	local t = AI:GetAttentionTargetOf(entity.id);
	if (type(t) == "table" and t.classname == "Player") then return t; end
	return CoopNearestPlayer(entity);
end
-- nearest living player to an entity
function CoopNearestPlayer(entity)
	local best, bd, p = nil, nil, entity:GetPos();
	for i, P in COOP_AIPlayers do
		if (BasicPlayer.IsAlive(P)) then
			local q = P:GetPos();
			local d = (p.x-q.x)*(p.x-q.x) + (p.y-q.y)*(p.y-q.y) + (p.z-q.z)*(p.z-q.z);
			if (not bd or d < bd) then best, bd = P, d; end
		end
	end
	return best;
end

-- A vehicle that drops a player on the server (the paraglider hit by the gunship, landing on
-- water) must drop him on the clients too: the paraglider's client table has no OnUnBind, so the
-- client kept gliding. Tell the clients ("VEHOUT <vehicle> <player>", COOP ClientStuff).
-- VC loads with the first vehicle class, so this is checked once a second.
-- Sent a second later and only if the player is really out of that vehicle: on a listen host
-- the host's own client code (same Lua state) also calls ReleaseUser while getting in, and an
-- immediate VEHOUT made the other clients pull the host off his paraglider.
COOP_VehOut = {}
function CoopWrapReleaseUser()
	if (not VC or VC.COOP_Wrapped) then return; end
	VC.COOP_Wrapped = 1;
	local old = VC.ReleaseUser;
	VC.ReleaseUser = function(self, aTable, a, b)
		local p = aTable and aTable.entity;
		local r = %old(self, aTable, a, b);
		if (p and p.classname == "Player") then COOP_VehOut[getn(COOP_VehOut) + 1] = {v = self.id, p = p.id}; end
		return r;
	end
end
function CoopSendVehOut()
	for i = 1, getn(COOP_VehOut) do
		local o = COOP_VehOut[i];
		local p = System:GetEntity(o.p);
		if (p and not (p.theVehicle and p.theVehicle.id == o.v)) then
			Server:BroadcastCommand("VEHOUT "..o.v.." "..o.p);
		end
	end
	COOP_VehOut = {};
end

-- Vehicles with fewer seats than players (issue #5). A paraglider has one seat, a buggy or a boat
-- two (InflatableBoat after CoopBoatSeats): the first players to reach them rode, the others had
-- nothing. Once players sit in one and every seat is taken, and no vehicle of that class at its
-- start spot (remembered while it was empty) has a free seat, spawn a copy on that spot, until the
-- vehicles that started there have a seat for every player. Only once the spot is clear (nothing
-- of that class within 6 m): a car spawned inside one that is still standing there would blow up.
-- Paraglider: Pier and Boat have 2, Rebellion 3, each at its own launch spot. The level's own
-- vehicles keep their mission events (DriverIn, PlayerEntered); the copies are only for getting
-- around. Not copied: FWDVehicle (7 seats; Swamp's Val4WD is one: AI driver, gunner and 5
-- passengers), Bigtrack (10), Forklift (mission puzzles). ponytail: copies are never removed
COOP_COPY_CLASSES = {Paraglider = 1, Buggy = 1, Boat = 1, InflatableBoat = 1}
function CoopSeatList(e)
	local t = {e.driverT};
	if (e.gunnerT) then t[getn(t) + 1] = e.gunnerT; end
	for i = 1, (e.passengerLimit or 0) do
		if (e.passengersTT and e.passengersTT[i]) then t[getn(t) + 1] = e.passengersTT[i]; end
	end
	return t;
end
function CoopVehicleCopies()
	local cars, players = {}, getn(CoopPlayers());
	for i, e in System:GetEntities() do
		if (COOP_COPY_CLASSES[e.classname] and e.driverT) then
			local seats, used, mine = CoopSeatList(e), 0, 0;
			for j = 1, getn(seats) do
				local p = seats[j].entity;
				if (p) then
					used = used + 1;
					if (p.classname == "Player") then mine = 1; end
				end
			end
			if (not e.COOP_Start and used == 0) then
				e.COOP_Start = {pos = new(e:GetPos()), ang = new(e:GetAngles())};
			end
			if (e.COOP_Start) then cars[getn(cars) + 1] = {e = e, seats = getn(seats), free = getn(seats) - used, mine = mine}; end
		end
	end
	for i = 1, getn(cars) do
		local taken = cars[i];
		if (taken.mine == 1 and taken.free == 0) then
			local s, free, here, clear = taken.e.COOP_Start.pos, 0, 0, 1;
			for j = 1, getn(cars) do
				local c = cars[j];
				if (c.e.classname == taken.e.classname) then
					local q = c.e.COOP_Start.pos;
					if ((q.x-s.x)*(q.x-s.x) + (q.y-s.y)*(q.y-s.y) + (q.z-s.z)*(q.z-s.z) < 400) then -- same spot (20 m)
						here = here + c.seats;
						free = free + c.free;
					end
					q = c.e:GetPos();
					if ((q.x-s.x)*(q.x-s.x) + (q.y-s.y)*(q.y-s.y) + (q.z-s.z)*(q.z-s.z) < 36) then clear = nil; end -- 6 m
				end
			end
			if (free == 0 and here < players and clear) then
				-- the position goes with the spawn: a SetPos after it did not reach the clients (they saw
				-- the copy at 0,0: an empty vehicle sends no updates)
				local g = Server:SpawnEntity(taken.e.classname, s);
				if (not g) then System:LogAlways("coop: could not spawn a "..taken.e.classname); return; end
				g:SetAngles(taken.e.COOP_Start.ang);
				g:EnableSave(0);
				g.COOP_Start = taken.e.COOP_Start;
				CoopMonEvent("S", "vehicle copy "..g:GetName().." ("..taken.e.classname..") at "..taken.e:GetName());
				return; -- one per second; the new one is free until someone takes it
			end
		end
	end
end

-- Level scripts move _localplayer (on the server: the host only) at a cutscene. Wrap exactly
-- those Mission functions (level survey in NOTES) and bring the others to the host's spot right
-- after them. A generic SetPos watch on the host fired at other moves too and put a client
-- into a wall. The Mission table is new on every level, so the flag lives in it.
COOP_CUTSCENE_MOVES = {"Event_Moveplayer", "Event_MoveplayerStartCutscene", "Event_MoveValForVaccine",
	"Event_MoveplayerControlCenter", "Event_MoveplayerHackingComputer", "Event_MoveplayerOutpostCoords",
	"Event_CutScene01", "Event_CutScene02", "moveplayercam"}
function CoopWrapCutsceneMoves()
	if (not Mission or Mission.COOP_MovesWrapped) then return; end
	Mission.COOP_MovesWrapped = 1;
	for i = 1, getn(COOP_CUTSCENE_MOVES) do
		local name = COOP_CUTSCENE_MOVES[i];
		local old = Mission[name];
		if (old) then
			Mission[name] = function(self, a, b)
				local r = %old(self, a, b);
				if (_localplayer) then
					CoopGather(_localplayer);
					CoopMonEvent("S", "gather after "..%name);
				end
				return r;
			end
		end
	end
end

-- Checkpoints: GameEvent:OnTimer (Event_Save of a mission's save trigger) reads _localplayer, so
-- on a dedicated server it failed and never set _LastCheckPPos: players respawned at the map
-- start. Run it with the nearest living player as _localplayer; everyone respawns there.
function CoopWrapGameEvent(e)
	e.COOP_Wrapped = 1;
	local old = e.OnTimer;
	e.OnTimer = function(self, a, b)
		local saved = _localplayer;
		_localplayer = CoopNearestPlayer(self) or saved;
		if (_localplayer) then
			call(%old, {self, a, b}, "x", function(msg) System:LogAlways("coop: checkpoint error: "..tostring(msg)); end);
			if (_LastCheckPPos and not self.bSaveNow) then
				CoopMonEvent("S", format("checkpoint %s at %.1f,%.1f,%.1f", self:GetName(), _LastCheckPPos.x, _LastCheckPPos.y, _LastCheckPPos.z));
			end
		end
		_localplayer = saved;
	end
end
function CoopWrapBehaviour(bname, fname, old)
	local where = bname.."."..fname;
	return function(...)
		local saved, entity, where = _localplayer, arg[2], %where; -- Lua 4: upvalues reach one level only
		if (type(entity) == "table" and entity.id) then
			_localplayer = CoopAIPlayer(entity, arg[3]) or saved;
		end
		local r = call(%old, arg, "x", function(msg)
			if (not COOP_AIErrors[%where]) then
				COOP_AIErrors[%where] = 1;
				System:LogAlways("coop: AI error in "..%where..": "..tostring(msg));
			end
		end);
		_localplayer = saved;
		return r;
	end
end
if (not COOP_AIErrors) then COOP_AIErrors = {}; end

-- behaviours load on demand, so this runs once a second for new ones
-- AIBehaviour.DEFAULT.CONVERSATION_REQUEST(_INPLACE) index sender.CurrentConversation, which is nil
-- when the sender's conversation ended before the signal arrived (the original game has the same
-- race; with the wrapper below it showed up as one "attempt to index field `CurrentConversation'")
function CoopGuardConversation(b, fname)
	local old = b[fname];
	if (type(old) ~= "function") then return; end
	b[fname] = function(self, entity, sender)
		if (sender and not sender.CurrentConversation) then return; end
		return %old(self, entity, sender);
	end
end

function CoopWrapBehaviours()
	local d = AIBehaviour.DEFAULT;
	if (type(d) == "table" and not d.COOP_Wrapped) then -- before the loop below wraps every function
		CoopGuardConversation(d, "CONVERSATION_REQUEST");
		CoopGuardConversation(d, "CONVERSATION_REQUEST_INPLACE");
	end
	for bname, b in AIBehaviour do
		if (type(b) == "table" and not b.COOP_Wrapped) then
			b.COOP_Wrapped = 1;
			for fname, f in b do
				if (type(f) == "function") then b[fname] = CoopWrapBehaviour(bname, fname, f); end
			end
		end
	end
end
if (not COOP_OrigAnimKey) then
	COOP_OrigAnimKey = BasicPlayer.Server_EventHandler[ScriptEvent_AnimationKey];
end
BasicPlayer.Server_EventHandler[ScriptEvent_AnimationKey] = function(self, Params)
	if (not COOP_FakeKey and type(Params) == "table" and Params.number) then
		-- the real animation got there: drop the pending fake keyframe
		for i = getn(COOP_KeyDue), 1, -1 do
			local d = COOP_KeyDue[i];
			if (d.id == self.id and d.number == Params.number) then tremove(COOP_KeyDue, i); break; end
		end
	end
	return COOP_OrigAnimKey(self, Params);
end

-- Teammate bots (#CoopBot()): a mercenary spawned with the players' species (0; mercs are 1),
-- so it is a friend of the players and an enemy of the mercs. Once a second: shoot its
-- attention target if that is an enemy, else run to the nearest player.
-- ponytail: merc model and merc behaviours, leader by name (all players may be "Jack
-- Carver"); give it its own character/model if it should look and act like a teammate
COOP_Bots = {} -- this file runs on every map load; old ids would point at other entities
COOP_BOT_CLASSES = {"Grunt", "MercCover", "MercRear", "MercScout"}
COOP_BOT_FOLLOW = 5 -- metres: closer than this to its leader, it stays put
function CoopBotPipes()
	if (COOP_BotPipes) then return; end
	COOP_BotPipes = 1;
	AI:CreateGoalPipe("coop_follow");
	AI:PushGoal("coop_follow", "firecmd", 0, 0);
	AI:PushGoal("coop_follow", "run", 0, 1);
	AI:PushGoal("coop_follow", "acqtarget", 0, ""); -- the leader named in SelectPipe
	AI:PushGoal("coop_follow", "approach", 1, 4);
	AI:PushGoal("coop_follow", "timeout", 1, 0.5);
	AI:CreateGoalPipe("coop_fight");
	AI:PushGoal("coop_fight", "firecmd", 0, 1);
	AI:PushGoal("coop_fight", "timeout", 1, 1);
end

function CoopBot()
	local leader = _localplayer or COOP_AIPlayers[1];
	if (not leader) then System:LogAlways("coop_bot: no player to follow"); return; end
	local class;
	for i = 1, getn(COOP_BOT_CLASSES) do
		local c = getglobal(COOP_BOT_CLASSES[i]);
		if (type(c) == "table" and c.Properties and c.Properties.species) then class = COOP_BOT_CLASSES[i]; break; end
	end
	if (not class) then System:LogAlways("coop_bot: no mercenary class loaded on this map"); return; end
	CoopBotPipes();
	-- the spawned entity copies the class defaults: spawn it as the players' species
	local props = getglobal(class).Properties;
	local species = props.species;
	props.species = 0;
	local bot = Server:SpawnEntity(class);
	props.species = species;
	if (not bot) then System:LogAlways("coop_bot: could not spawn "..class); return; end
	local p = leader:GetPos();
	bot:SetPos({x = p.x + 2, y = p.y + 2, z = p.z + 1});
	bot:EnableSave(0);
	tinsert(COOP_Bots, bot.id);
	CoopMonEvent("S", "bot "..bot:GetName().." ("..class..")");
end
Game:AddCommand("coop_bot", "CoopBot()", "coop_bot: spawn a teammate bot that follows the nearest player");
Game:AddCommand("coop_expect", "COOP_ExpectPlayers = tonumber(%%) or 1", "coop_expect <n>: hold the map intro until n players are in (90 s at most)");

function CoopUpdateBots()
	local keep = {};
	for i = 1, getn(COOP_Bots) do
		local bot = System:GetEntity(COOP_Bots[i]);
		if (bot and bot.cnt and bot.cnt.health > 0) then
			tinsert(keep, bot.id);
			local t = AI:GetAttentionTargetOf(bot.id);
			if (type(t) == "table" and t.Properties and t.Properties.species and t.Properties.species ~= 0
				and t.cnt and t.cnt.health and t.cnt.health > 0) then
				bot:SelectPipe(0, "coop_fight");
			else
				local leader = CoopNearestPlayer(bot);
				if (leader) then
					local p, q = bot:GetPos(), leader:GetPos();
					if ((p.x-q.x)*(p.x-q.x) + (p.y-q.y)*(p.y-q.y) > COOP_BOT_FOLLOW*COOP_BOT_FOLLOW) then
						bot:SelectPipe(0, "coop_follow", leader:GetName());
					end
				end
			end
		end
	end
	COOP_Bots = keep;
end

-- Weapons carry over to the next level, as in the single-player story. At a mission end the
-- server remembers every player's equipment under the player's key (CoopSetKey); on the next
-- level, once that player is alive, the level's own starting weapons are replaced by it. Single
-- player does this for its _localplayer only (SavePlayerElements/LoadPlayerElements), and in
-- co-op the host got the level's defaults. A player who leaves keeps the equipment too and gets
-- it back on joining again, on this map or a later one; saves keep it for every player who ever
-- joined (CoopSave), so a server started from a save a week later still has it.
-- Kept in globals: they survive the map load.
-- What single player keeps (SDK ScriptObjectPlayer.cpp): weapons, ammo, the rounds in every
-- weapon's clips and its fire mode, the selected weapon, armor, binoculars, flashlight and the
-- items table (cryvision goggles); health comes back full.
function CoopCollectLoadout(P)
	if (not (P and P.cnt and P.cnt.GetWeaponsSlots)) then return; end
	-- the selected weapon keeps its ammo in cnt.ammo / cnt.ammo_in_clip, not in P.Ammo
	if (P.Ammo and P.cnt.weapon) then
		call(BasicPlayer.SyncCachedAmmoValues, {P}, "x", function(msg) System:LogAlways("coop: ammo sync error: "..tostring(msg)); end);
	end
	local names, clips = {}, {};
	for k, w in P.cnt:GetWeaponsSlots() do
		if (type(w) == "table" and w.name) then
			names[getn(names) + 1] = w.name;
			local def = WeaponClassesEx[w.name];
			local ws = def and P.WeaponState and P.WeaponState[def.id];
			if (ws and type(ws.AmmoInClip) == "table") then clips[w.name] = {fm = ws.FireMode, clip = new(ws.AmmoInClip)}; end
		end
	end
	local cur = P.cnt.weapon;
	return {weapons = names, ammo = new(P.Ammo or {}), current = (type(cur) == "table" and cur.name) or names[1],
		clips = clips, grenadetype = P.cnt.grenadetype, armor = P.cnt.armor, binoculars = P.cnt.has_binoculars, flashlight = P.cnt.has_flashlight,
		items = new(P.items or {})};
end

-- replace the player's weapons by the loadout L (CoopCollectLoadout; an old save has only
-- weapons, ammo and current), in LoadPlayerElements' order: the weapon is put away first, so
-- that selecting it again reads the carried ammo instead of keeping the level's in cnt.ammo
function CoopGiveLoadout(P, L)
	P.cnt:SetCurrWeapon(); -- no weapon: the selected one writes its cached ammo back now, not later
	local keep = {};
	for k = 1, getn(L.weapons) do keep[L.weapons[k]] = 1; end
	for k, w in P.cnt:GetWeaponsSlots() do -- drop the level's starting weapons we did not carry
		if (type(w) == "table" and w.name and not keep[w.name] and WeaponClassesEx[w.name]) then
			P.cnt:MakeWeaponAvailable(WeaponClassesEx[w.name].id, 0);
		end
	end
	for k = 1, getn(L.weapons) do
		local def = WeaponClassesEx[L.weapons[k]];
		if (def) then
			Game:AddWeapon(L.weapons[k]);
			P.cnt:MakeWeaponAvailable(def.id, 1);
			-- a weapon's state is made when it is first selected, and loads its first clip from
			-- P.Ammo: make it now, before the ammo is set (else a clip of ammo was lost)
			if (P.WeaponState and not P.WeaponState[def.id]) then BasicPlayer.ScriptInitWeapon(P, L.weapons[k]); end
		end
	end
	for ammotype, n in P.Ammo do P.Ammo[ammotype] = 0; end -- as single player: only what was carried
	for ammotype, n in L.ammo do P.Ammo[ammotype] = n; end
	for name, c in (L.clips or {}) do
		local def = WeaponClassesEx[name];
		local ws = def and P.WeaponState and P.WeaponState[def.id];
		if (ws) then ws.FireMode = c.fm; ws.AmmoInClip = new(c.clip); end
	end
	-- the thrown grenade's count is cached in cnt too (the rocks' as a byte: 255 at most)
	local gt = L.grenadetype;
	if (not (gt and GrenadesClasses[gt] and (P.Ammo[GrenadesClasses[gt]] or 0) > 0)) then
		gt = 1; -- the rock
		for id = 2, getn(GrenadesClasses) do
			if ((P.Ammo[GrenadesClasses[id]] or 0) > 0) then gt = id; break; end
		end
	end
	P.cnt.grenadetype = gt;
	P.cnt.numofgrenades = P.Ammo[GrenadesClasses[gt]] or 0;
	if (L.armor) then P.cnt.armor = L.armor; end
	local slot = Server:GetServerSlotByEntityId(P.id);
	if (L.binoculars == 1 and P.cnt.has_binoculars ~= 1) then
		P.cnt:GiveBinoculars(1);
		if (slot) then slot:SendCommand("GI B"); end
	end
	if (L.flashlight == 1 and P.cnt.has_flashlight ~= 1) then
		P.cnt:GiveFlashLight(1);
		if (slot) then slot:SendCommand("GI F"); end
	end
	if (L.items and P.items) then
		for k, v in L.items do P.items[k] = v; end
		if (L.items.heatvisiongoggles and slot) then slot:SendCommand("GI C"); end
	end
	if (L.current and WeaponClassesEx[L.current]) then P.cnt:SetCurrWeapon(WeaponClassesEx[L.current].id);
	else P.cnt:SelectFirstWeapon(); end
	P.COOP_Carried = 1; -- CoopApplyPrefs: keep these, only refill the ammo
end

-- Who the player in a server slot is: the key sent by COOP ClientStuff ("COOPID", the launcher's
-- player key or name). A client without it is known by its slot number for this session only.
if (not COOP_SlotKeys) then COOP_SlotKeys = {}; end -- server slot id -> key
if (not COOP_KeyWait) then COOP_KeyWait = {}; end -- server slot id -> _time its player was first seen without a key
if (not COOP_Progress) then COOP_Progress = {}; end -- key -> loadout (CoopCollectLoadout)
if (not COOP_Owed) then COOP_Owed = {}; end -- key -> 1: give COOP_Progress[key] to that player's next spawn
COOP_KEY_WAIT = 5 -- seconds to wait for COOPID before falling back to the slot number

function CoopSetKey(server_slot, cmd)
	local s, e, key = strfind(cmd, "^COOPID%s+(.-)%s*$");
	if (not key or key == "") then return; end
	local id = server_slot:GetId();
	local base, n = key, 1;
	for sid, k in COOP_SlotKeys do -- two players asked for the same name: the second is someone else
		if (sid ~= id and k == key) then n = n + 1; key = base.."#"..n; end
	end
	if (COOP_SlotKeys[id] ~= key) then CoopMonEvent("S", "key slot "..id.." "..key); end
	COOP_SlotKeys[id] = key;
end

-- the slot's key, or nil while its COOPID may still come
function CoopSlotKey(slot)
	local id = slot:GetId();
	if (COOP_SlotKeys[id]) then return COOP_SlotKeys[id]; end
	COOP_KeyWait[id] = COOP_KeyWait[id] or _time;
	if (_time < COOP_KeyWait[id]) then COOP_KeyWait[id] = _time; end -- _time restarted with a map load
	if (_time - COOP_KeyWait[id] >= COOP_KEY_WAIT) then return "slot"..id; end
end

-- remember the player's equipment and owe it to the next spawn under the same key
function CoopKeepLoadout(slot)
	local key = COOP_SlotKeys[slot:GetId()] or "slot"..slot:GetId();
	local P = System:GetEntity(slot:GetPlayerId());
	if (P and P.cnt and BasicPlayer.IsAlive(P)) then COOP_Progress[key] = CoopCollectLoadout(P); end
	if (COOP_Progress[key]) then COOP_Owed[key] = 1; end -- a dead player gets what was kept last
end

-- the map changes: everybody's equipment comes along
function CoopSaveLoadouts()
	for i, slot in Server:GetServerSlotMap() do CoopKeepLoadout(slot); end -- slots and their keys stay
	CoopWriteProgress("map change");
end

-- Between two saves the equipment lived in memory only: a host who quit or crashed lost what
-- players got since the last checkpoint, also for those who had left already. When a player
-- leaves, the map changes or the server shuts down, the progress part of the last save
-- (COOP_LastSave, written or loaded) is written again; the save point itself (positions,
-- mission state, the players' records) stays as it was. Who is not in the game when that save
-- is loaded gets the newer equipment (CoopApplyLoad: save.progress).
function CoopWriteProgress(why)
	local save = COOP_LastSave;
	if (not (save and save.name and Server)) then return; end
	for i, slot in Server:GetServerSlotMap() do
		local key = COOP_SlotKeys[slot:GetId()];
		local P = System:GetEntity(slot:GetPlayerId());
		if (key and P and P.cnt and BasicPlayer.IsAlive(P)) then COOP_Progress[key] = CoopCollectLoadout(P); end
	end
	save.progress = COOP_Progress;
	save.t0 = nil; -- CoopApplyLoad's wait, not part of the save
	writeto(COOP_SAVE_PATH..save.name..".lua");
	write("COOP_LoadedSave = "..CoopSer(save).."\n");
	writeto();
	System:LogAlways("coop: progress written to "..save.name.." ("..why..")");
end
function CoopWriteProgressError(msg) System:LogAlways("coop: progress write error: "..tostring(msg)); writeto(); end

-- a player leaves: keep the equipment for the next join
COOP_DefaultOnClientDisconnect = GameRules.OnClientDisconnect; -- the single-player rules, loaded above
function GameRules:OnClientDisconnect(server_slot)
	call(CoopKeepLoadout, {server_slot}, "x", function(msg) System:LogAlways("coop: loadout keep error: "..tostring(msg)); end);
	call(CoopWriteProgress, {"player left"}, "x", CoopWriteProgressError);
	COOP_SlotKeys[server_slot:GetId()], COOP_KeyWait[server_slot:GetId()] = nil, nil;
	COOP_JoinedSlots[server_slot:GetId()] = nil;
	return COOP_DefaultOnClientDisconnect(self, server_slot);
end

-- the server goes down (CXServerRules::ShutDown: quit, disconnect, a new map)
COOP_DefaultOnShutdown = GameRules.OnShutdown;
function GameRules:OnShutdown()
	call(CoopWriteProgress, {"shutdown"}, "x", CoopWriteProgressError);
	if (COOP_DefaultOnShutdown) then return COOP_DefaultOnShutdown(self); end
end

-- A player who joins a running map spawned where the single-player rules put him: at the last
-- checkpoint or the level start, maybe far from everybody. The first spawn of a slot on this map
-- goes next to a living teammate (the host's player first) when that one is more than
-- COOP_JOIN_RADIUS away. A respawn after death is not a first spawn and stays at the checkpoint,
-- as in single player; at a map start everybody spawns together anyway; a save load puts the
-- players where it keeps them (CoopApplyLoad marks them).
COOP_JOIN_RADIUS = 30
COOP_JoinedSlots = {} -- slot ids already spawned on this map; this file runs on every map load
function CoopJoinNearTeam()
	if (COOP_PendingLoad) then return; end
	local list = CoopPlayers();
	for i, slot in Server:GetServerSlotMap() do
		local P = System:GetEntity(slot:GetPlayerId());
		if (P and P.cnt and BasicPlayer.IsAlive(P) and not COOP_JoinedSlots[slot:GetId()]) then
			COOP_JoinedSlots[slot:GetId()] = 1;
			local mate = (_localplayer ~= P and _localplayer and BasicPlayer.IsAlive(_localplayer)) and _localplayer;
			for j, Q in list do
				if (not mate and Q ~= P and Q.cnt and BasicPlayer.IsAlive(Q)) then mate = Q; end
			end
			if (mate) then
				local p = P:GetPos();
				local x, y, z = p.x, p.y, p.z; -- GetPos returns a shared table
				local t = mate:GetPos();
				local d2 = (t.x - x) * (t.x - x) + (t.y - y) * (t.y - y) + (t.z - z) * (t.z - z);
				if (d2 > COOP_JOIN_RADIUS * COOP_JOIN_RADIUS) then
					local a = mate:GetAngles();
					local pos, ang = {x = t.x, y = t.y, z = t.z + 0.3}, {x = a.x, y = a.y, z = a.z};
					CoopMovePlayer(P, pos, ang); -- on the mate's spot, as coop_gather
					CoopMonEvent("S", format("joined %s next to %s (was %.0f m away)", P:GetName(), mate:GetName(), sqrt(d2)));
				end
			end
		end
	end
end

-- AI health reaches no client: CPlayer::Write sends health only to the client whose own player
-- it is (SDK XPlayer.cpp, bLocalHostEntity), so clients kept every enemy at full health until it
-- died (harness: mutants sv 198-245 / cl 255 on Treehouse and Cooler). The server sends what
-- changed ("AIHP <id> <hp> ...", COOP ClientStuff): in the frame of a hit (GameRules:OnDamage
-- marks the target), once a second for any other change, and all of it to a joining client
-- (CoopHudSync). Deaths reach the clients by themselves and are not sent.
COOP_HPDirty = {}
function CoopSendHP(list, slot)
	local words = {};
	for i = 1, getn(list) do words[i] = list[i].id.." "..list[i].cnt.health; end
	CoopSendPacked("AIHP", words, slot);
end

-- AI whose health is not what the clients got last; ents: the marked ones (by id), else all.
-- An AI seen the first time by the sweep is where the clients have it too (the level's health).
function CoopSyncAIHealth(ents)
	local list, k = {}, 0;
	for i, e in (ents or System:GetEntities()) do
		if (type(e) == "table" and e.ai and e.cnt and e.cnt.health and e.COOP_HP ~= e.cnt.health) then
			if (e.cnt.health > 0 and (ents or e.COOP_HP)) then k = k + 1; list[k] = e; end
			e.COOP_HP = e.cnt.health;
		end
	end
	if (k > 0) then CoopSendHP(list); end
end

-- a joining client: every AI that is hurt
function CoopSendAllHP(server_slot)
	local list, k = {}, 0;
	for i, e in System:GetEntities() do
		if (e.ai and e.cnt and e.cnt.health and e.cnt.health > 0 and e.COOP_HP) then k = k + 1; list[k] = e; end
	end
	if (k > 0) then CoopSendHP(list, server_slot); end
end

function CoopApplyLoadouts()
	if (COOP_PendingLoad) then return; end -- CoopApplyLoad gives the save's equipment
	for i, slot in Server:GetServerSlotMap() do
		local P = System:GetEntity(slot:GetPlayerId());
		if (P and P.cnt and P.cnt.GetWeaponsSlots and BasicPlayer.IsAlive(P)) then
			local key = CoopSlotKey(slot);
			if (key and COOP_Owed[key] and COOP_Progress[key]) then
				COOP_Owed[key] = nil;
				CoopGiveLoadout(P, COOP_Progress[key]);
				CoopMonEvent("S", "loadout "..P:GetName().." ("..key..") "..getn(COOP_Progress[key].weapons).." weapons");
			end
		end
	end
end

-- Launcher settings (prefs.lua, loaded by COOP ClientStuff): every client sends its shirt color
-- and chosen weapons ("PREF", OnClientCmd). Once per spawned player entity (a respawn is a new
-- entity): everyone paints it ("PCOLOR", COOP ClientStuff). With the host's COOP_LoadoutMode=1
-- it also gets its own 4 weapons instead of the mission's, unless it carried
-- weapons over from the last level (CoopApplyLoadouts), and full ammo every spawn.
COOP_LOADOUT_WEAPONS = {Machete=1, Falcon=1, MP5=1, P90=1, M4=1, AG36=1, OICW=1, Shotgun=1, SniperRifle=1, M249=1, RL=1}
if (not COOP_Prefs) then COOP_Prefs = {}; end -- per server slot id; kept through map loads

function CoopSetPrefs(server_slot, tk)
	local color = tonumber(tk[2]) or 1;
	if (color < 0 or color > 9) then color = 1; end
	local weapons = {};
	for k = 3, 6 do
		if (tk[k] and COOP_LOADOUT_WEAPONS[tk[k]]) then weapons[getn(weapons) + 1] = tk[k]; end
	end
	COOP_Prefs[server_slot:GetId()] = {color = color, weapons = weapons};
	-- a player who just joined has not seen the others' colors
	for i, slot in Server:GetServerSlotMap() do
		local p, P = COOP_Prefs[slot:GetId()], System:GetEntity(slot:GetPlayerId());
		if (p and P and P.COOP_Prefed) then server_slot:SendCommand("PCOLOR "..P.id.." "..p.color); end
	end
	CoopMonEvent("S", "prefs slot "..server_slot:GetId().." color "..color.." weapons "..getn(weapons));
end

function CoopFillAmmo(P)
	for ammotype, amount in MaxAmmo do
		if (P.Ammo and P.Ammo[ammotype] and P.Ammo[ammotype] < amount) then
			BasicPlayer.AddAmmo(P, ammotype, amount - P.Ammo[ammotype]);
		end
	end
end

function CoopApplyPrefs()
	for i, slot in Server:GetServerSlotMap() do
		local p, P = COOP_Prefs[slot:GetId()], System:GetEntity(slot:GetPlayerId());
		local key = CoopSlotKey(slot);
		local waiting = not key or COOP_Owed[key]; -- carried weapons not given yet
		if (p and P and not P.COOP_Prefed and not waiting and P.cnt and BasicPlayer.IsAlive(P)) then
			P.COOP_Prefed = 1;
			Server:BroadcastCommand("PCOLOR "..P.id.." "..p.color);
			if (COOP_LoadoutMode == 1) then
				if (not P.COOP_Carried) then
					for k, w in P.cnt:GetWeaponsSlots() do -- drop the mission's starting weapons
						if (type(w) == "table" and w.name and WeaponClassesEx[w.name]) then
							P.cnt:MakeWeaponAvailable(WeaponClassesEx[w.name].id, 0);
						end
					end
					local give = p.weapons;
					for k = 1, getn(give) do
						Game:AddWeapon(give[k]);
						P.cnt:MakeWeaponAvailable(WeaponClassesEx[give[k]].id, 1);
					end
					if (getn(give) > 0) then P.cnt:SetCurrWeapon(WeaponClassesEx[give[getn(give)]].id); end
				end
				CoopFillAmmo(P);
			end
			CoopMonEvent("S", "prefs "..P:GetName().." color "..p.color.." carried "..tostring(P.COOP_Carried));
		end
	end
end

-- One error in the once-per-second work must not stop the rest of it (the first error per name is logged).
function CoopRun(name, fn)
	call(fn, {}, "x", function(msg)
		COOP_RunErrors = COOP_RunErrors or {};
		if (not COOP_RunErrors[%name]) then
			COOP_RunErrors[%name] = 1;
			System:LogAlways("coop: "..%name.." error: "..tostring(msg));
		end
	end);
end

-- The level intro (Training first_cutscene, Steam val_leaves) is Mission:OnMapChange, which single
-- player's engine calls after a map load and a listen server never does (g_MapChanged stayed 1).
-- Call it once every player is alive: Movie:PlaySequence reaches the clients (SEQ).
-- BasicAI:Drop spawns each dropped item with Server:SpawnEntity(name), i.e. at (0,0,0), and moves
-- it with SetPos afterwards. The spawn reaches the clients, the move does not (pickups have no net
-- presence): clients had every dropped weapon at the map origin (harness diff on Training:
-- PickupM4 sv 708,720,18 / cl 0,0,0). During the original Drop, spawn by class name at the body.
function CoopDrop(self, packname)
	local p = self:GetPos();
	local pos = {x = p.x, y = p.y, z = p.z + 1.2};
	local orig = Server.SpawnEntity;
	Server.SpawnEntity = function(srv, what)
		if (type(what) == "string") then
			local id = Game:GetEntityClassIDByClassName(what);
			if (id) then return %orig(srv, {classid = id, pos = %pos}); end
		end
		return %orig(srv, what);
	end
	call(COOP_OrigDrop, {self, packname}, "x", function(msg) System:LogAlways("coop: drop error: "..tostring(msg)); end);
	Server.SpawnEntity = orig;
end

-- A dropped weapon has no net presence either: each side lets it fall on its own. On River the
-- boat crews' weapons lie on the decks on the server (z 28.4), while a client's boat is 1-3 m
-- off, so its copy missed the deck and sank 5-7 m to the river bed (harness: SetPos on the
-- server did not move the client's copy at all; they are dropped in the first second of the map,
-- before CoopWrapDrop). Physical props (BasicEntity, RigidBody, DestroyableObject: the temple
-- rubble on River) do get net presence once they move (ASI), but the server sends a body only
-- while it is awake: the rubble falls at the map start on both sides, each settles somewhere
-- else (one stone lay at z 34.4 on one side and 37.7 on the other, swapped between runs), and once
-- asleep nothing was sent again (ASI watch: 2 updates, then none, also after a SetPos).
-- So the server tells the clients where each of them has come to rest ("PPOS <id> x y z ax ay az
-- ...", as many as fit, COOP ClientStuff): spawned pickups (id from 65535 down, any BasePickup
-- class: ammo boxes too) and the rigid props of the level, once at rest and again whenever they
-- come to rest somewhere new; a drop that is still moving 5 s after it fell (a deck under way),
-- every second. A BasicEntity that is not a rigid body (Properties.Physics.bRigidBody 0) is left
-- out: the level's sequences move those (Training first_cutscene, BasicEntity182), and a rest
-- place set before the cutscene sent the client's copy 1000 m away.
-- A joining client gets them all again 5 and 15 s after it asked for the HUD (CoopHudSync): sent
-- at once, its copies were set right and then fell again (the client was still setting them up).
COOP_REST_CLASSES = {BasicEntity = 1, RigidBody = 1, DestroyableObject = 1}
COOP_Drops = {} -- id -> {x, y, z (last sample), sx, sy, sz, s (sent), t (sent at), born, drop}; this file runs on every map load
COOP_DropResend = {}
-- Server commands reach the clients cut at 255 characters (harness: a 400-character command
-- arrived as 255): pack the words of one kind into messages under COOP_CMD_MAX.
COOP_CMD_MAX = 240
function CoopSendPacked(head, list, slot)
	local msg = head;
	for i = 1, getn(list) do
		if (msg ~= head and strlen(msg) + 1 + strlen(list[i]) > COOP_CMD_MAX) then
			if (slot) then slot:SendCommand(msg); else Server:BroadcastCommand(msg); end
			msg = head;
		end
		msg = msg.." "..list[i];
	end
	if (msg ~= head) then
		if (slot) then slot:SendCommand(msg); else Server:BroadcastCommand(msg); end
	end
end
function CoopSendRest(list, slot) CoopSendPacked("PPOS", list, slot); end
-- a drop (spawned pickup) or a rigid prop of the level
function CoopRestTracked(e)
	if (e.id >= COOP_STATIC_IDS) then
		return BasePickup and e.Physicalize == BasePickup.Physicalize; -- pickup classes copy BasePickup's functions
	end
	if (not COOP_REST_CLASSES[e.classname]) then return; end
	if (e.classname ~= "BasicEntity") then return 1; end
	local ph = e.Properties and e.Properties.Physics;
	return ph and ph.bRigidBody == 1;
end
function CoopSyncDrops()
	local out, k = {}, 0;
	if (COOP_DropResend[1] and _time >= COOP_DropResend[1]) then
		COOP_DropResend[1], COOP_DropResend[2] = COOP_DropResend[2], nil;
		for id, d in COOP_Drops do if (d.s) then k = k + 1; out[k] = id.." "..d.s; end end
	end
	for i, e in System:GetEntities() do
		if (not COOP_Drops[e.id] and not e.COOP_NoRest) then
			if (CoopRestTracked(e)) then
				COOP_Drops[e.id] = {born = _time, t = _time, drop = (e.id >= COOP_STATIC_IDS)};
			else
				e.COOP_NoRest = 1; -- looked at once
			end
		end
	end
	for id, d in COOP_Drops do
		local e = System:GetEntity(id);
		if (not e or (d.drop and e:GetState() == "Inactive")) then -- gone, or picked up
			COOP_Drops[id] = nil;
		else
			local p = e:GetPos();
			local x, y, z = p.x, p.y, p.z; -- GetPos returns a shared table
			local still = d.x and (x - d.x) * (x - d.x) + (y - d.y) * (y - d.y) + (z - d.z) * (z - d.z) < 0.0025;
			d.x, d.y, d.z = x, y, z;
			local sent = d.sx and (x - d.sx) * (x - d.sx) + (y - d.sy) * (y - d.sy) + (z - d.sz) * (z - d.sz) < 0.0025;
			if ((still and not sent) or (d.drop and not still and _time - d.born >= 5 and _time - d.t >= 1)) then
				local a = e:GetAngles();
				d.sx, d.sy, d.sz, d.t = x, y, z, _time;
				d.s = format("%.2f %.2f %.2f %.1f %.1f %.1f", x, y, z, a.x, a.y, a.z);
				k = k + 1;
				out[k] = id.." "..d.s;
			end
		end
	end
	if (k > 0) then CoopSendRest(out); end
end

-- AI classes copy BasicAI's functions when they are defined: replace Drop in every class table.
function CoopWrapDrop()
	if (not Server or not BasicAI or not BasicAI.Drop) then return; end
	if (not COOP_OrigDrop) then COOP_OrigDrop = BasicAI.Drop; end
	for name, t in globals() do
		if (type(t) == "table" and t.Drop == COOP_OrigDrop) then
			t.Drop = CoopDrop;
		end
	end
end

-- Players who join after the intro started never see it (a sequence is forwarded only when it
-- starts). The launcher / lobby knows how many players come: COOP_ExpectPlayers (coop_expect N)
-- holds the intro until that many are in, for at most COOP_ExpectTimeout seconds of the map.
COOP_ExpectPlayers = COOP_ExpectPlayers or 1;
COOP_ExpectTimeout = COOP_ExpectTimeout or 90;
function CoopMapIntro()
	if (not g_MapChanged or not _localplayer or COOP_PendingLoad or not Mission or not Mission.OnMapChange) then return; end
	local list = CoopPlayers();
	if (getn(list) == 0) then return; end
	if (getn(list) < COOP_ExpectPlayers and _time < COOP_ExpectTimeout) then return; end
	for i, P in list do
		if (not BasicPlayer.IsAlive(P)) then return; end
	end
	Mission:OnMapChange();
	g_MapChanged = nil;
end

function GameRules:OnUpdate(DeltaTime)
	if COOP_PendingMap then -- next level asked for by a mission end (CoopStartLevel)
		local map = COOP_PendingMap
		COOP_PendingMap = nil
		if (not COOP_PendingLoad) then -- else the save has the weapons
			call(CoopSaveLoadouts, {}, "x", function(msg) System:LogAlways("coop: loadout save error: "..tostring(msg)); end)
		end
		CoopMap(map)
		return
	end
	CoopRun("preload weapons", CoopPreloadWeapons)
	if next(COOP_HPDirty) then
		CoopRun("ai health", function() CoopSyncAIHealth(COOP_HPDirty) end)
		COOP_HPDirty = {}
	end
	COOP_AIPlayers = CoopPlayers() -- for CoopAIPlayer; every frame, players respawn as new entities
	CoopRun("monitor", function() CoopMonitor("S") end)
	CoopRun("update keys", CoopUpdateKeys)
	if COOP_God == 1 then -- coop_god: refill every frame
		for i, P in CoopPlayers() do
			if P.cnt.health > 0 then P.cnt.health = P.cnt.max_health; end
		end
	end
	-- _time restarts with every map load, but Lua globals survive coop_restart
	if _time < COOP_NextWake and COOP_NextWake - _time <= 1 then return end
	COOP_NextWake = _time + 1
	COOP_Ticks = (COOP_Ticks or 0) + 1 -- once-per-second block ran (read from the console when debugging)
	-- first, before the unprotected calls below: an error in one of them would end this function and the watch never ran
	call(CoopTeleWatch, {}, "x", function(msg) System:LogAlways("coop: tele watch error: "..tostring(msg)); end)
	-- coop_map turned cutscenes off for a dedicated server; a listen host (it has a
	-- _localplayer) plays the campaign as in single player, cutscenes included
	if _localplayer then setglobal("mov_NoCutscenes", 0) end
	CoopRun("wrap behaviours", CoopWrapBehaviours)
	CoopRun("wrap hud", CoopWrapHud)
	CoopRun("wrap release user", CoopWrapReleaseUser)
	CoopRun("send veh out", CoopSendVehOut)
	CoopRun("vehicle copies", CoopVehicleCopies)
	CoopRun("wrap cutscene moves", CoopWrapCutsceneMoves)
	CoopRun("wrap drop", CoopWrapDrop)
	CoopRun("map intro", CoopMapIntro)
	CoopRun("boat seats", CoopBoatSeats)
	CoopRun("ai health sweep", CoopSyncAIHealth)
	CoopRun("drops", CoopSyncDrops)
	CoopRun("join near team", CoopJoinNearTeam)
	call(CoopApplyLoadouts, {}, "x", function(msg) System:LogAlways("coop: loadout error: "..tostring(msg)); end)
	call(CoopApplyPrefs, {}, "x", function(msg) System:LogAlways("coop: prefs error: "..tostring(msg)); end)
	call(CoopUpdateBots, {}, "x", function(msg) System:LogAlways("coop: bot error: "..tostring(msg)); end)
	if COOP_PendingLoad then call(CoopApplyLoad, {}, "x", function(msg) System:LogAlways("coop: load error: "..tostring(msg)); COOP_PendingLoad = nil; end); end
	local players = {}
	for i, P in CoopPlayers() do
		local t = P:GetPos() -- GetPos returns a shared table: copy the values
		players[i] = {x = t.x, y = t.y, z = t.z}
	end
	if getn(players) == 0 then return end
	local wake2, sleeper2 = COOP_WAKE_RADIUS * COOP_WAKE_RADIUS, COOP_SLEEPER_RADIUS * COOP_SLEEPER_RADIUS
	for i, e in System:GetEntities() do
		if e.ai and not e.COOP_AnimWrapped then CoopWrapAnim(e) end
		if e.classname == "GameEvent" and not e.COOP_Wrapped then CoopWrapGameEvent(e) end
		if (e.Event_Hide or e.Event_UnHide) and not e.COOP_HideWrapped then CoopWrapHide(e) end
		if e.Behaviour and e.cnt and e.Properties and e.Properties.species and not e.COOP_Awake
			and e.Enemy_Hidden ~= 1 then
			local r2 = (e.Properties.bSleepOnSpawn == 1) and sleeper2 or wake2
			local t = e:GetPos()
			for j = 1, getn(players) do
				local q = players[j]
				if (t.x-q.x)*(t.x-q.x) + (t.y-q.y)*(t.y-q.y) + (t.z-q.z)*(t.z-q.z) < r2 then
					-- one bad entity must not stop the wake-up of the rest: catch and log once
					call(CoopWake, {e}, "x", CoopWakeError)
					break
				end
			end
		end
	end
end

-- see CoopMovePlayer: resend a move until the remote player is within 6 m of it (at most 8 times, for
-- 15 s), and move it again if it falls through the ground in the next 8 s; a dead player is waited for. Cleared with every map load (this file runs on each).
COOP_TeleWatch = {};
function CoopTeleWatch()
	for i, slot in Server:GetServerSlotMap() do
		local id = slot:GetId();
		local w = COOP_TeleWatch[id];
		if (w) then
			local P = System:GetEntity(slot:GetPlayerId());
			if (_time < w.t or _time - w.t > 15 or w.tries >= 8) then -- second test: _time restarted
				COOP_TeleWatch[id] = nil;
			elseif (P and P.cnt and P.cnt.health > 0 and BasicPlayer.IsAlive(P)) then
				local t = P:GetPos();
				local dx, dy, dz = t.x - w.pos.x, t.y - w.pos.y, t.z - w.pos.z;
				if (not w.arrived and dx * dx + dy * dy + dz * dz < 36) then w.arrived = _time; end
				if (w.arrived) then
					-- 8 s more: a player put down where the ground has not streamed in on its machine falls
					-- through it (Training: z -100 a few seconds after the move)
					if (_time < w.arrived or _time - w.arrived > 8) then
						COOP_TeleWatch[id] = nil;
					elseif (t.z < w.pos.z - 10) then
						w.tries = w.tries + 1;
						System:LogAlways(format("coop: tele again (%d) for %s: it fell to z %.0f", w.tries, P:GetName(), t.z));
						if (w.tries >= 2 and _localplayer and _localplayer.id ~= P.id) then -- the spot has no ground for it: use the host's
							local h = _localplayer:GetPos();
							w.pos = {x = h.x + 1, y = h.y, z = h.z};
						end
						CoopMovePlayer(P, w.pos, w.ang, 1);
						w.arrived = nil;
						w.t = _time;
					end
				elseif (_time - w.t >= 1.5) then
					w.tries = w.tries + 1;
					CoopMonEvent("S", format("tele again (%d) for %s", w.tries, P:GetName()));
					System:LogAlways(format("coop: tele again (%d) for %s", w.tries, P:GetName()));
					CoopMovePlayer(P, w.pos, w.ang, 1);
				end
			elseif (not w.logged) then -- waiting for the player to be alive: say why, once
				w.logged = 1;
				System:LogAlways(format("coop: tele watch waits for %s: hp %s state %s vehicle %s", tostring(P and P:GetName()),
					tostring(P and P.cnt and P.cnt.health), tostring(P and P.GetState and P:GetState()), tostring(P and P.theVehicle ~= nil)));
			end
		end
	end
end

function CoopWake(e)
	e.COOP_Awake = 1 -- set first, so a failing entity is not retried every second
	e:TriggerEvent(AIEVENT_WAKEUP)
	e:TriggerEvent(AIEVENT_ENABLE)
end

function CoopWakeError(msg)
	if not COOP_WakeErrorLogged then
		COOP_WakeErrorLogged = 1
		System:LogAlways("coop: AI wake-up error: "..tostring(msg))
	end
end

-- Mission objectives and messages: mission scripts run on the server and call its Hud, which
-- nobody sees. Forward every call to the clients ("MHUD <op> <text>", COOP ClientStuff;
-- "HUD" is taken by the pickup icons), and send
-- the current objectives to a client that asks ("HUDSYNC": it joined after they were given).
-- The flag lives in Hud itself, so a reloaded Hud gets wrapped again.
-- ponytail: Hud.DisplayControl (hide radar/ammo) is not forwarded, add when a mission needs it
function CoopWrapHud()
	if (not Hud or Hud.COOP_Wrapped) then return; end
	Hud.COOP_Wrapped = 1;
	local wrap = function(name, op)
		local old = Hud[name];
		Hud[name] = function(self, a, b, c, d)
			local r = %old(self, a, b, c, d);
			local text = (%op == "push") and b or a; -- PushObjective(pos, text)
			Server:BroadcastCommand("MHUD "..%op.." "..tostring(text or ""));
			return r;
		end
	end
	wrap("AddMessage", "msg");
	wrap("PushObjective", "push");
	wrap("CompleteObjective", "done");
	wrap("FlashObjectives", "flash");
	local oldRadar = Hud.SetRadarObjective;
	Hud.SetRadarObjective = function(self, name)
		Hud.COOP_Radar = name;
		%oldRadar(self, name);
		Server:BroadcastCommand("MHUD radar "..tostring(name));
	end
end
CoopWrapHud();

-- Hide/UnHide events (mission triggers showing and hiding things: the freighter of Boat is
-- hidden by ProximityTrigger_HIDE_SHIP and shown again by Trigger_ACTIVATE_FREIGHTER) run only
-- on the machine where the trigger fired, so the freighter stayed hidden for a client. Each
-- entity's Event_Hide/Event_UnHide is wrapped (per entity: class-level wraps do not reach
-- existing entities, see AreaTrigger in NOTES) to tell the clients ("HIDE <id> 1/0", COOP
-- ClientStuff), and a joining client gets the current state (CoopHudSync).
COOP_HideState = {} -- this file runs on every map load
function CoopWrapHide(e)
	e.COOP_HideWrapped = 1;
	local wrap = function(name, v)
		local old = %e[name];
		if (not old) then return; end
		%e[name] = function(self, a, b)
			local r = %old(self, a, b);
			COOP_HideState[self.id] = %v;
			Server:BroadcastCommand("HIDE "..self.id.." "..%v);
			return r;
		end
	end
	wrap("Event_Hide", 1);
	wrap("Event_UnHide", 0);
end

function CoopHudSync(server_slot)
	for id, v in COOP_HideState do server_slot:SendCommand("HIDE "..id.." "..v); end
	CoopSendAllHP(server_slot);
	COOP_DropResend = {_time + 5, _time + 15};
	server_slot:SendCommand("MHUD flash ");
	for i, o in (Hud and Hud.objectives or {}) do
		if (type(o) == "table") then
			server_slot:SendCommand("MHUD push "..tostring(o.text));
			if (o.completed) then server_slot:SendCommand("MHUD done "..tostring(o.text)); end
		end
	end
	if (Hud and Hud.COOP_Radar) then server_slot:SendCommand("MHUD radar "..Hud.COOP_Radar); end
end

-- Client-side hits (see COOP ClientStuff): apply the damage a client reports for its own shot.
function GameRules:OnClientCmd(server_slot, cmd)
	local tk = tokenize(cmd);
	if (tk[1] == "CHIT") then CoopClientHit(server_slot, tk);
	elseif (tk[1] == "HUDSYNC") then CoopHudSync(server_slot);
	elseif (tk[1] == "PREF") then CoopSetPrefs(server_slot, tk);
	elseif (tk[1] == "COOPID") then CoopSetKey(server_slot, cmd); end
end

function CoopClientHit(server_slot, tk)
	local shooter = System:GetEntity(server_slot:GetPlayerId());
	local target = System:GetEntity(tonumber(tk[2]) or 0);
	local damage = tonumber(tk[3]) or 0;
	if (not shooter or not target or target.type ~= "Player" or not BasicPlayer.IsAlive(shooter)
		or not BasicPlayer.IsAlive(target) or damage <= 0 or damage > 1000) then
		return; -- ponytail: trusts the client otherwise (co-op among friends), add checks if cheating matters
	end
	local hit = {
		shooter = shooter, target = target, weapon = shooter.cnt.weapon,
		damage = damage, ipart = tonumber(tk[4]) or -1, damage_type = "normal", landed = 1,
		target_material = Materials["mat_"..tk[5]] or Materials["mat_flesh"],
		pos = {x = tonumber(tk[6]), y = tonumber(tk[7]), z = tonumber(tk[8])},
		dir = {x = tonumber(tk[9]), y = tonumber(tk[10]), z = tonumber(tk[11])},
		normal = {x = -tonumber(tk[9]), y = -tonumber(tk[10]), z = -tonumber(tk[11])},
		impact_force_mul = 0, impact_force_mul_final = 0, impact_force_mul_final_torso = 0,
		COOP_ClientHit = 1,
	};
	target:Damage(hit);
end

-- Server-side bullets of remote players would double the client-reported damage: drop them.
-- The host of a listen server (its _localplayer) keeps server-side hits.
if (not COOP_OldOnDamage) then COOP_OldOnDamage = GameRules.OnDamage; end -- once: this file reloads on coop_restart
function GameRules:OnDamage(hit)
	local s, t = hit.shooter, hit.target;
	if (s and not s.ai and s ~= _localplayer and t and t.ai and not hit.COOP_ClientHit) then return end
	if (t and t.ai and not t.COOP_Awake and t.Enemy_Hidden ~= 1) then
		call(CoopWake, {t}, "x", CoopWakeError); -- a sleeper that gets shot wakes up (COOP_SLEEPER_RADIUS)
	end
	local r = COOP_OldOnDamage(self, hit);
	if (t and t.ai) then COOP_HPDirty[t.id] = t; end -- the clients get the new health this frame (CoopSyncAIHealth)
	return r;
end

-- Campaign saves (host only), as in single player: a checkpoint saves by itself ("auto"), F6 is
-- quicksave ("quick"), F7 quickload; coop_savegame <name> / coop_loadgame <name> by hand.
-- The engine's own CXGame::Save refuses to run in multiplayer, so this is a Lua save kept in
-- Mods\FarCryCoop\save_<name>.lua: map, every player's position, health, armor, weapons and
-- ammo, which AI are dead, and the respawn point. Loading reloads the map with
-- LoadLevelMPServer, so joined players stay connected (a load from a fresh game start needs them
-- to join again), removes the dead AI and puts everybody back. Static entity ids from the level
-- XML stay the same when the same map reloads, so entities are matched by id.
-- Mission state (version 2), what the single-player save keeps too (CXGame::SaveToStream):
-- the level entities that are gone (picked-up items, removed AI and objects) are removed again;
-- living AI get their position and health back; triggers, doors and mission hints keep their
-- state through their own OnSave/OnLoad, called with a stream that writes into the save table
-- (CoopStm); hidden entities (COOP_HideState) and the mission objectives come back. Not saved: the
-- Mission table's own variables and AI behaviour states (the engine save does not have them
-- either, or keeps them in its AI chunk).
COOP_STATIC_IDS = 32768 -- ponytail: level entities have small ids, dynamic ones (players, spawned) are given from 65535 down
-- classes whose OnSave/OnLoad only keep mission flags (read in the game scripts); players, AI and
-- vehicles have their own, heavier ones, and are left out
COOP_SAVE_CLASSES = {AreaTrigger = 1, ProximityTrigger = 1, ProximityKeyTrigger = 1, DelayTrigger = 1, MultipleTrigger = 1,
	AITrigger = 1, VisibilityTrigger = 1, Door = 1, AutomaticDoor = 1, MissionHint = 1}

-- a stand-in for the CStream that OnSave/OnLoad get in single player: values go into t[1..n]
function CoopStm(t)
	local put = function(self, v) self.n = self.n + 1; self.t[self.n] = v; end
	local get = function(self) self.n = self.n + 1; return self.t[self.n]; end
	return {t = t or {}, n = 0, WriteInt = put, WriteFloat = put, WriteString = put, WriteByte = put,
		WriteBool = function(self, v) %put(self, (v and v ~= 0) and 1 or 0); end,
		ReadInt = get, ReadFloat = get, ReadString = get, ReadByte = get,
		ReadBool = function(self) local v = %get(self); if (v and v ~= 0) then return 1; end end};
end

function CoopSer(v)
	local t = type(v);
	if (t == "number") then return format("%.10g", v); end
	if (t == "string") then return format("%q", v); end
	if (t == "table") then
		local s = "{";
		for k, x in v do
			if (type(k) == "number" or type(k) == "string") then s = s.."["..CoopSer(k).."]="..CoopSer(x)..","; end
		end
		return s.."}";
	end
	return "nil";
end

function CoopSave(name)
	name = name or "quick";
	if (not Game:IsServer()) then return; end
	if (not COOP_Map) then System:LogAlways("coop_save: no co-op map running"); return; end
	if (strfind(name, "[^%w_]")) then System:LogAlways("coop_save: the name may have only letters, digits and _"); return; end
	local save = {version = 2, map = COOP_Map, name = name, difficulty = COOP_Difficulty, players = {}, dead = {},
		present = {}, ai = {}, state = {}, hidden = new(COOP_HideState), objectives = {}, radar = Hud and Hud.COOP_Radar};
	if (date) then save.date = date("%Y-%m-%d %H:%M"); end
	for i, P in CoopPlayers() do
		local t, a = P:GetPos(), P:GetAngles();
		local L = CoopCollectLoadout(P) or {weapons = {}, ammo = new(P.Ammo or {})};
		local slot = Server:GetServerSlotByEntityId(P.id);
		L.key = slot and (COOP_SlotKeys[slot:GetId()] or "slot"..slot:GetId());
		if (L.key and P.cnt.health > 0) then COOP_Progress[L.key] = CoopCollectLoadout(P); end
		L.pos = {x = t.x, y = t.y, z = t.z};
		L.ang = {x = a.x, y = a.y, z = a.z};
		L.health = (P.cnt.health > 0) and P.cnt.health or P.cnt.max_health; -- a dead player is saved alive
		L.armor = P.cnt.armor;
		save.players[i] = L;
	end
	save.progress = COOP_Progress; -- also the players who are not here now
	local nd = 0;
	for i, e in System:GetEntities() do
		if (e.ai and e.cnt and e.cnt.health and e.cnt.health <= 0) then nd = nd + 1; save.dead[nd] = e.id; end
		if (e.id < COOP_STATIC_IDS) then
			save.present[e.id] = 1;
			if (e.ai and e.cnt and e.cnt.health and e.cnt.health > 0) then
				local p, a = e:GetPos(), e:GetAngles();
				save.ai[e.id] = {x = p.x, y = p.y, z = p.z, a = a.z, h = e.cnt.health};
			elseif (COOP_SAVE_CLASSES[e.classname] and e.OnSave) then
				local stm = CoopStm();
				e:OnSave(stm);
				save.state[e.id] = {n = stm.n, v = stm.t};
			end
		end
	end
	for i, o in (Hud and Hud.objectives or {}) do
		if (type(o) == "table" and o.text) then save.objectives[getn(save.objectives) + 1] = {text = o.text, done = o.completed}; end
	end
	if (_LastCheckPPos) then
		save.check = {pos = new(_LastCheckPPos), ang = _LastCheckPAngles and new(_LastCheckPAngles) or nil};
	end
	writeto(COOP_SAVE_PATH..name..".lua");
	write("COOP_LoadedSave = "..CoopSer(save).."\n");
	writeto();
	COOP_LastSave = save; -- CoopWriteProgress keeps its progress part up to date
	CoopSaveMessage(format("saved %s: %d players, %d dead AI on %s", name, getn(save.players), nd, save.map));
end

function CoopSaveError(msg) System:LogAlways("coop: save error: "..tostring(msg)); writeto(); end
function CoopQuickSave() call(CoopSave, {"quick"}, "x", CoopSaveError); end

-- the checkpoint (a GameEvent save trigger, after it set _LastCheckPPos) saves by itself
if (not COOP_OldAfterSave) then COOP_OldAfterSave = Game.OnAfterSave or 0; end -- once: this file reloads
function Game:OnAfterSave()
	if (COOP_Map and Game:IsServer()) then call(CoopSave, {"auto"}, "x", CoopSaveError); end
	if (COOP_OldAfterSave ~= 0) then return COOP_OldAfterSave(self); end
end

-- CoopLoad, CoopQuickLoad: Scripts/Multiplayer/AvailableMods.lua (the launcher calls CoopLoad from the menu)

Game:AddCommand("coop_save", "CoopQuickSave()", "coop_save: quicksave (F6)");
Game:AddCommand("coop_load", "CoopQuickLoad()", "coop_load: quickload (F7)");
Game:AddCommand("coop_savegame", "CoopSave(%%)", "coop_savegame <name>: save the co-op game");
Game:AddCommand("coop_loadgame", "CoopLoad(%%)", "coop_loadgame <name>: load a co-op save (quick, auto or a name)");
if (Input) then
	Input:BindCommandToKey("#CoopQuickSave()", "f6", 1);
	Input:BindCommandToKey("#CoopQuickLoad()", "f7", 1);
end

function CoopApplyLoad()
	local save = COOP_PendingLoad;
	local list = CoopPlayers();
	if (getn(list) == 0) then return; end
	for i, P in list do
		if (not BasicPlayer.IsAlive(P)) then return; end -- wait until every player has spawned
	end
	-- a client still respawning after LoadLevelMPServer has a slot but no entity yet: wait for it
	-- (30 s at most), and for every player's key
	local slots, keys = 0, 0;
	for i, slot in Server:GetServerSlotMap() do
		slots = slots + 1;
		if (CoopSlotKey(slot)) then keys = keys + 1; end
	end
	save.t0 = save.t0 or _time;
	if ((getn(list) < slots or keys < slots) and _time - save.t0 < 30) then return; end
	COOP_PendingLoad = nil;
	COOP_LastSave = save;
	for i, slot in Server:GetServerSlotMap() do COOP_JoinedSlots[slot:GetId()] = 1; end -- placed below, not next to the team
	-- everyone the save knows is owed their equipment; who is here gets it below, the rest on joining
	COOP_Progress, COOP_Owed = save.progress or {}, {};
	for key, L in COOP_Progress do COOP_Owed[key] = 1; end
	local keyed = save.players[1] and save.players[1].key; -- older saves give the records by join order
	for i = 1, getn(save.dead) do
		local e = System:GetEntity(save.dead[i]);
		if (e and e.ai) then Server:RemoveEntity(e.id); end
	end
	if (save.present) then CoopApplyMissionState(save); end
	local c = save.check or {pos = save.players[1].pos, ang = save.players[1].ang};
	for i, P in list do
		local s;
		if (keyed) then
			local slot = Server:GetServerSlotByEntityId(P.id);
			local key = slot and CoopSlotKey(slot);
			for j = 1, getn(save.players) do
				if (save.players[j].key == key) then s = save.players[j]; end
			end
			if (key) then COOP_Owed[key] = nil; end
		else
			s = save.players[i] or save.players[1];
		end
		if (s) then
			CoopMovePlayer(P, s.pos, s.ang);
			P.cnt.health = s.health;
			P.cnt.armor = s.armor;
			if (s.weapons and P.cnt.GetWeaponsSlots) then CoopGiveLoadout(P, s); end
		else -- not in this save: to the team's respawn point, with what the save keeps for them
			CoopMovePlayer(P, c.pos, c.ang);
			local slot = Server:GetServerSlotByEntityId(P.id);
			local key = slot and CoopSlotKey(slot);
			if (key and COOP_Progress[key]) then CoopGiveLoadout(P, COOP_Progress[key]); end
		end
	end
	_LastCheckPPos = new(c.pos);
	if (c.ang) then _LastCheckPAngles = new(c.ang); end
	CoopSaveMessage(format("loaded %s: %d players, %d dead AI removed", tostring(save.name), getn(list), getn(save.dead)));
end

-- the mission state of a version 2 save, on the freshly loaded map (see CoopSave)
function CoopApplyMissionState(save)
	local gone, n = {}, 0;
	for i, e in System:GetEntities() do
		if (e.id < COOP_STATIC_IDS and not save.present[e.id] and e.type ~= "Player") then n = n + 1; gone[n] = e.id; end
	end
	for i = 1, n do Server:RemoveEntity(gone[i]); end
	for id, a in save.ai do
		local e = System:GetEntity(id);
		if (e and e.ai and e.cnt) then
			e:SetPos({x = a.x, y = a.y, z = a.z});
			e:SetAngles({x = 0, y = 0, z = a.a});
			e.cnt.health = a.h;
		end
	end
	local ns = 0;
	for id, st in save.state do
		local e = System:GetEntity(id);
		if (e and e.OnLoad and COOP_SAVE_CLASSES[e.classname]) then
			local stm = CoopStm(st.v);
			call(e.OnLoad, {e, stm}, "x", function(msg) System:LogAlways("coop: load state of "..%e:GetName()..": "..tostring(msg)); end);
			ns = ns + 1;
		end
	end
	for id, v in (save.hidden or {}) do
		local e = System:GetEntity(id);
		if (e) then
			if (not e.COOP_HideWrapped) then CoopWrapHide(e); end
			local ev = (v == 1) and e.Event_Hide or e.Event_UnHide; -- wrapped: tells the clients (HIDE)
			if (ev) then ev(e, e); else e:Hide(v); end
		end
	end
	if (Hud and save.objectives) then
		Hud:FlashObjectives(); -- wrapped (CoopWrapHud): the clients get the same list
		for i, o in save.objectives do
			Hud:PushObjective({}, o.text);
			if (o.done) then Hud:CompleteObjective(o.text); end
		end
		if (save.radar) then Hud:SetRadarObjective(save.radar); end
	end
	CoopSaveMessage(format("mission state: %d entities removed, %d states restored, %d objectives", n, ns, getn(save.objectives or {})));
end

-- The crews of the level's vehicles died in the first frame of a co-op map (Training: the Humvee
-- and boat crews, 4 AI, hp 0 at t=0.01; alive and seated in single player). VC:OnResetCommon
-- (VehicleCommon.lua) gives every vehicle JustSpawned=5 in multiplayer, and VC:OnContactServerT
-- kills whoever touches it during those first updates (VC:KillPlayer, 5000 damage from
-- themselves): telefrag protection for vehicles respawning in deathmatch. In co-op nothing
-- respawns into a vehicle's place (CoopVehicleCopies waits for a free spot), so the level's
-- vehicles do not get it. The level's vehicles are reset before this file runs, so their flag
-- is cleared here; later resets (coop_restart, spawned copies) go through the wrapper.
function CoopNoTelefrag()
	if (not VC or not VC.OnResetCommon) then return; end
	if (not COOP_OrigVCReset) then COOP_OrigVCReset = VC.OnResetCommon; end -- once: this file runs on every map load
	VC.OnResetCommon = function(self)
		COOP_OrigVCReset(self);
		self.JustSpawned = nil;
	end
	for i, e in System:GetEntities() do
		if (e.JustSpawned) then e.JustSpawned = nil; end
	end
end
CoopNoTelefrag();

-- Movie sequences (e.g. the heli fly-by on Pier, started by a ProximityTrigger) play only on
-- the machine that calls Movie:PlaySequence, and the entities they animate are not sent over
-- the network. The server forwards every sequence start/stop to the clients ("SEQ"/"SEQSTOP",
-- handled in COOP ClientStuff). Once: this file reloads on coop_restart.
if (not COOP_OrigPlaySequence) then
	COOP_OrigPlaySequence, COOP_OrigStopSequence = Movie.PlaySequence, Movie.StopSequence;
	Movie.PlaySequence = function(self, name)
		CoopMonEvent("S", "sequence "..tostring(name));
		COOP_OrigPlaySequence(self, name);
		Server:BroadcastCommand("SEQ "..tostring(name));
	end
	Movie.StopSequence = function(self, name)
		COOP_OrigStopSequence(self, name);
		Server:BroadcastCommand("SEQSTOP "..tostring(name));
	end
end
