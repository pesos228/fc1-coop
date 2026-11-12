-- FarCryCoop level end, as in Synergy (docs/specs/level-end.md): a mission end does not change
-- the level at once. The mission's last trigger becomes the exit zone: its box (at least
-- COOP_EXIT_MIN across), drawn with glowing edges and smoke at the corners. Who walks in stays on
-- his spot, takes no damage and deals none, and everybody sees the countdown; in the zone also how
-- many more players it waits for. The next level loads when more than half of the living players
-- are in the zone, or when the countdown (COOP_ExitTime, the host sets it: launcher or
-- coop_exittime) runs out. Loaded by COOP gamerules (server) and COOP ClientStuff (client).
COOP_ExitTime = COOP_ExitTime or 120
COOP_EXIT_MIN = 6 -- the zone is at least this wide and long
COOP_EXIT_HEIGHT = 5 -- above or below the opener's feet, still in the zone
COOP_EXIT_HOLD = 0.3 -- a held player who got farther than this from his spot is put back

-- server ------------------------------------------------------------------------------------

COOP_Exit = nil -- this file runs on every map load
-- Who set off the mission end, carried along the chain of trigger events (Training:
-- ProximityTrigger111 -> DelayTrigger4, 3 s -> ProximityTrigger39 -> DelayTrigger3, 2 s ->
-- Mission:Event_MissionFinished; half the maps end with an AreaTrigger right away). Every trigger
-- fires with BroadcastEvent(self, event), which calls its targets' Event_ functions at once:
-- - a trigger a player walked into has him in Who: he is the cause, with where he stood and the
--   trigger's box, taken now (he may have walked off by the end of the chain);
-- - an event fired from inside another one's (COOP_CurrentCause) keeps that one's cause: a
--   trigger set off by an event keeps an old Who, or none;
-- - its targets get the cause (COOP_Cause), for when they fire later (a DelayTrigger).
-- So a mission end set off by nobody (after a cutscene, a timer) opens no exit, and another player
-- crossing some other trigger meanwhile is not taken for the opener. A cause older than
-- COOP_EXIT_CAUSE_AGE s does not count (Boat: the end comes 25 s after a gunship dies, whenever
-- that is).
COOP_EXIT_CAUSE_AGE = 60
if (BroadcastEvent and BroadcastEvent ~= COOP_BroadcastEvent) then COOP_OrigBroadcastEvent = BroadcastEvent; end -- common.lua's (this file runs on every map load)
function CoopExitCause(sender, event)
	if (COOP_CurrentCause) then return COOP_CurrentCause; end
	local P = sender.Who;
	-- an area enter calls the trigger's OnEnterArea with the trigger itself as the player (SDK
	-- XArea.cpp CXArea::EnterArea), and AreaTrigger goes on to broadcast Enter in that call, inside
	-- one player's area update: the ASI names that player in COOP_AreaUser just before. Only then:
	-- the global stays at whoever was updated last (OnLoad clears Who, Entered stops a second Enter)
	if (P == sender and event == "Enter" and COOP_AreaUser) then P = System:GetEntity(COOP_AreaUser); end
	if (type(P) == "table" and P.classname == "Player" and not P.ai) then
		local p = P:GetPos();
		local c = {P = P, x = p.x, y = p.y, z = p.z, t = _time, name = sender:GetName()};
		local d = sender.Properties;
		if (d and d.DimX and d.DimY) then -- a box trigger (the engine lets players in by it along the world axes)
			local q = sender:GetPos();
			c.bx = q.x;
			c.by = q.y;
			c.hx = d.DimX / 2;
			c.hy = d.DimY / 2;
		end
		return c;
	end
	return sender.COOP_Cause;
end
function COOP_BroadcastEvent(sender, event)
	local cause = type(sender) == "table" and CoopExitCause(sender, event);
	local list = cause and sender.Events and sender.Events[event];
	if (list) then
		for i, target in list do
			local e = target[1] ~= 0 and System:GetEntity(target[1]);
			if (e) then e.COOP_Cause = cause; end
		end
	end
	local prev = COOP_CurrentCause;
	COOP_CurrentCause = cause or prev;
	-- call: an error in a target's script must not leave its cause behind for every later event
	local r = call(COOP_OrigBroadcastEvent, {sender, event}, "x", function(msg) System:LogAlways("coop: event error: "..tostring(msg)); end);
	COOP_CurrentCause = prev;
	return r;
end
BroadcastEvent = COOP_BroadcastEvent
COOP_CurrentCause = nil

-- the cause of this mission end, if it is a living player and recent enough (nil: change at once)
function CoopExitOpener()
	local c = COOP_CurrentCause;
	local why = nil;
	if (not c) then why = "no player set it off";
	elseif (_time < c.t or _time > c.t + COOP_EXIT_CAUSE_AGE) then why = format("set off %.0f s ago", _time - c.t); -- (_time restarts on a map load)
	elseif (System:GetEntity(c.P.id) ~= c.P or not BasicPlayer.IsAlive(c.P)) then why = "the opener is gone or dead"; end
	if (why) then CoopMonEvent("S", "exit skipped: "..why); return; end
	return c;
end

-- From CoopStartLevel (the mission end, on the server): 1 when the exit takes over the level
-- change, nil to change it now.
function CoopExitOpen(map)
	if (COOP_Exit) then COOP_Exit.map = map; return 1; end
	local c = CoopExitOpener();
	if (not c) then return; end
	local x = {map = map, x = c.x, y = c.y, z = c.z, hx = COOP_EXIT_MIN / 2, hy = COOP_EXIT_MIN / 2, ends = _time + COOP_ExitTime, hold = {}, sendAt = 0};
	if (c.bx) then
		x.x = c.bx;
		x.y = c.by;
		x.hx = max(c.hx, x.hx); -- one by one (Lua 4, see CoopAimedPlayer)
		x.hy = max(c.hy, x.hy);
	end
	-- the opener is in, on the spot he set it off from (counted by his body there, the zone by feet)
	x.hold[c.P.id] = {x = c.x, y = c.y, z = c.z, P = c.P};
	COOP_Exit = x;
	CoopMonEvent("S", format("exit open by %s (%s) at %.1f,%.1f,%.1f, %.0f x %.0f m, %d s", c.P:GetName(), c.name, x.x, x.y, x.z, x.hx * 2, x.hy * 2, COOP_ExitTime));
	CoopExitTick(); -- more than half there already (alone): the level changes at once
	return 1;
end

function CoopExitIn(x, p)
	return abs(p.x - x.x) <= x.hx and abs(p.y - x.y) <= x.hy and abs(p.z - x.z) <= COOP_EXIT_HEIGHT;
end

-- held: not hurt and hurts nobody (COOP gamerules GameRules:OnDamage)
function CoopExitHeld(e)
	local h = COOP_Exit and e and COOP_Exit.hold[e.id];
	return h and h.P == e;
end

-- Every frame from GameRules:OnUpdate. 1 when it changed the level.
function CoopExitTick()
	local x = COOP_Exit;
	if (not x) then return; end
	if (_time >= x.ends) then return CoopExitClose(x, "time is up"); end -- first: an error below must not keep the level
	local alive, n, list = 0, 0, CoopPlayers();
	for i, P in list do
		if (BasicPlayer.IsAlive(P)) then
			alive = alive + 1;
			local p = P:GetPos();
			local px, py, pz = p.x, p.y, p.z; -- GetPos returns a shared table
			local h = x.hold[P.id];
			if (h and h.P ~= P) then h = nil; end -- the id of a player who left, taken by a new one
			if (not h and CoopExitIn(x, p)) then
				h = {x = px, y = py, z = pz, P = P};
				x.hold[P.id] = h;
				x.sendAt = 0; -- tell him now
				CoopMonEvent("S", "exit in "..P:GetName());
			end
			if (h) then
				n = n + 1;
				-- the whole spot: x,y with the height of where he was moved to put him inside the
				-- carrier's hull (tests/level-end.txt). A spot taken mid-jump only drops him once: falling
				-- does not move him off it sideways. Never a seated player: SetPos in a seat killed him
				-- (CoopLeaveSeat)
				-- A remote player holds himself (EXIT command, CoopExitClientTick), but his SetPos does
				-- not reach the server's copy of him: on a slope it slid off for the server (and so
				-- for the others) while he stood on his spot (runs/20261112-001707). Put that copy
				-- back too; a server SetPos does not move the client himself.
				if (not P.theVehicle and (px - h.x) * (px - h.x) + (py - h.y) * (py - h.y) > COOP_EXIT_HOLD * COOP_EXIT_HOLD) then
					P:SetPos({x = h.x, y = h.y, z = h.z});
				end
				CoopExitFreeze(P);
			end
		end
	end
	if (alive > 0 and n * 2 > alive) then return CoopExitClose(x, n.." of "..alive.." in"); end
	if (_time < x.sendAt) then return; end
	x.sendAt = _time + 1;
	local left, need = max(0, floor(x.ends - _time)), floor(alive / 2) + 1 - n;
	local head = format("EXIT %.2f %.2f %.2f %.1f %.1f %d %d", x.x, x.y, x.z, x.hx, x.hy, left, need);
	for i, slot in Server:GetServerSlotMap() do
		local P = System:GetEntity(slot:GetPlayerId());
		local h = P and x.hold[P.id];
		if (P ~= _localplayer) then
			slot:SendCommand(h and format("%s %.2f %.2f %.2f", head, h.x, h.y, h.z) or head);
		end
	end
	if (_localplayer) then -- a listen host: its own view, as a client gets it
		local h = x.hold[_localplayer.id];
		COOP_ExitView = {x = x.x, y = x.y, z = x.z, hx = x.hx, hy = x.hy, ends = _time + left, need = need, hold = h, at = _time};
	end
end

-- A held player can neither walk (speedscale: CPlayer scales the input speed by it) nor fire
-- (weapon_busy > 0: no shot, grenade or melee, the weapon stays in his hands), on the machine
-- that moves him (his own: CoopExitClientTick) and on the server's copy. Every frame: the
-- weapon_busy counts down by itself.
function CoopExitFreeze(P)
	local c = P and P.cnt;
	if (not c) then return; end
	if (c.speedscale and c.speedscale ~= 0) then P.COOP_ExitSpeed = c.speedscale; c.speedscale = 0; end
	if (c.weapon_busy and c.weapon_busy < 0.5) then c.weapon_busy = 0.5; end
end
function CoopExitUnfreeze(P)
	if (P and P.cnt and P.COOP_ExitSpeed) then P.cnt.speedscale = P.COOP_ExitSpeed; P.COOP_ExitSpeed = nil; end
end

function CoopExitClose(x, why)
	COOP_Exit = nil;
	COOP_ExitView = nil;
	COOP_PendingMap = x.map; -- GameRules:OnUpdate loads it next frame; first: an error below must not keep the level
	CoopMonEvent("S", format("exit: %s, %d s left: %s", why, max(0, floor(x.ends - _time)), x.map));
	Server:BroadcastCommand("EXIT -");
	CoopExitUnfreezeAll(x);
	return 1;
end
function CoopExitUnfreezeAll(x)
	for id, h in x.hold do
		if (System:GetEntity(id) == h.P) then CoopExitUnfreeze(h.P); end
	end
end

Game:AddCommand("coop_exittime", "COOP_ExitTime = tonumber(%%) or 120", "coop_exittime <s>: how long the exit waits for the players at a level end (120)");

-- client (and a listen host) -----------------------------------------------------------------

-- "EXIT <x> <y> <z> <half width x> <half width y> <seconds left> <players needed> [<hold x> <hold y>
-- <hold z>]", once a second while the exit is open; "EXIT -" when it closes.
if (ClientStuff and ClientStuff.ServerCommandTable) then ClientStuff.ServerCommandTable["EXIT"] = function(String, tk)
	if (Game:IsServer()) then return; end
	if (tk[2] == "-") then COOP_ExitView = nil; CoopExitUnfreeze(_localplayer); return; end
	local v = {x = tonumber(tk[2]) or 0, y = tonumber(tk[3]) or 0, z = tonumber(tk[4]) or 0, hx = tonumber(tk[5]) or 3, hy = tonumber(tk[6]) or 3};
	v.ends = _time + (tonumber(tk[7]) or 0);
	v.need = tonumber(tk[8]) or 0;
	v.at = _time;
	if (tk[11]) then v.hold = {x = tonumber(tk[9]) or 0, y = tonumber(tk[10]) or 0, z = tonumber(tk[11]) or 0}; end
	COOP_ExitView = v;
end end

COOP_ExitView = nil -- this file runs on every map load
-- the corners: a flare's smoke (FlareGrenade.SmokeTrail), green; the edges: short glows
COOP_ExitSmoke = {
	focus = 1,
	start_color = {0.3, 1.0, 0.3},
	end_color = {1.0, 1.0, 0.6},
	gravity = {x = 0.0, y = 0.0, z = 1.75},
	rotation = {x = 0.0, y = 0.0, z = 1.5},
	speed = 0.75,
	count = 1,
	size = 0.15, size_speed = 0.6,
	LinearSizeSpeed = 1,
	lifetime = 2.5,
	frames = 1,
	tid = System:LoadTexture("textures/clouda.dds"),
}
COOP_ExitGlow = {
	focus = 0,
	start_color = {0.4, 1.0, 0.4},
	end_color = {0.2, 0.6, 0.2},
	gravity = {x = 0.0, y = 0.0, z = 0.3},
	rotation = {x = 0.0, y = 0.0, z = 0.0},
	speed = 0,
	count = 1,
	size = 0.25, size_speed = 0,
	lifetime = 0.6,
	frames = 1,
	tid = COOP_ExitSmoke.tid,
}
COOP_EXIT_STEP = 1 -- metres between glows on the edges
COOP_EXIT_GLOWS = 24 -- at most on one edge (a big trigger: farther apart)

function CoopExitDraw(v)
	local z = v.z + 0.15;
	local x0, x1, y0, y1 = v.x - v.hx, v.x + v.hx, v.y - v.hy, v.y + v.hy;
	local up = {x = 0, y = 0, z = 1};
	local n = min(COOP_EXIT_GLOWS, max(1, floor(v.hx * 2 / COOP_EXIT_STEP)));
	for i = 0, n do
		local x = x0 + (x1 - x0) * i / n;
		Particle:CreateParticle({x = x, y = y0, z = z}, up, COOP_ExitGlow);
		Particle:CreateParticle({x = x, y = y1, z = z}, up, COOP_ExitGlow);
	end
	n = min(COOP_EXIT_GLOWS, max(1, floor(v.hy * 2 / COOP_EXIT_STEP)));
	for i = 1, n - 1 do
		local y = y0 + (y1 - y0) * i / n;
		Particle:CreateParticle({x = x0, y = y, z = z}, up, COOP_ExitGlow);
		Particle:CreateParticle({x = x1, y = y, z = z}, up, COOP_ExitGlow);
	end
	Particle:CreateParticle({x = x0, y = y0, z = z}, up, COOP_ExitSmoke);
	Particle:CreateParticle({x = x1, y = y0, z = z}, up, COOP_ExitSmoke);
	Particle:CreateParticle({x = x0, y = y1, z = z}, up, COOP_ExitSmoke);
	Particle:CreateParticle({x = x1, y = y1, z = z}, up, COOP_ExitSmoke);
	if (_localplayer) then _localplayer:AddDynamicLight({x = v.x, y = v.y, z = v.z + 1.5}, min(max(v.hx, v.hy) + 2, 15), 0.4, 1, 0.4, 1, 0, 0, 0, 0, 0.4); end
end

-- Every frame from ClientStuff:OnUpdate: the zone, and our own player kept on his spot.
function CoopExitClientTick()
	local v = COOP_ExitView;
	if (not v) then return; end
	if (_time > v.at + 3 or _time < v.at) then COOP_ExitView = nil; CoopExitUnfreeze(_localplayer); return; end -- the server stopped (a map change)
	if (_time >= (COOP_ExitDrawAt or 0) or _time + 1 < COOP_ExitDrawAt) then
		COOP_ExitDrawAt = _time + 0.3;
		CoopExitDraw(v);
	end
	local P = _localplayer;
	if (v.hold and P and not P.theVehicle and not Game:IsServer()) then -- as CoopExitTick for the host
		local p = P:GetPos();
		if ((p.x - v.hold.x) * (p.x - v.hold.x) + (p.y - v.hold.y) * (p.y - v.hold.y) > COOP_EXIT_HOLD * COOP_EXIT_HOLD) then
			P:SetPos(v.hold);
		end
	end
	if (v.hold and P and not Game:IsServer()) then CoopExitFreeze(P); end
end

-- From the COOP Hud hook every frame: the countdown at the top, in the zone also who is missing.
-- COOP_ExitText is what was drawn (tests/level-end.txt).
function CoopDrawExit()
	COOP_ExitText = nil;
	local v = COOP_ExitView;
	if (not v or tonumber(cl_display_hud) == 0) then return; end
	local left = max(0, floor(v.ends - _time + 0.5));
	local text = format("Next level in %d s", left);
	if (v.hold and v.need > 0) then
		text = text..format(" - waiting for %d more player%s", v.need, v.need == 1 and "" or "s");
	end
	Game:SetHUDFont("default", "default");
	local w = Game:GetHudStringSize(text, 18, 18);
	Game:WriteHudString(400 - w * 0.5, 90, text, 1, 1, 1, 1, 18, 18);
	COOP_ExitText = text;
end
