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
-- The player who set off the mission end: the one in a trigger that is Occupied now (Training:
-- ProximityTrigger39 -> DelayTrigger3 -> Mission:Event_MissionFinished -> StartLevelFade). An
-- inactive trigger keeps its last Who, so only Occupied ones count; one the player has left
-- (Occupied until its leave timer runs out) only if none holds him now.
function CoopExitOpener()
	local P1, e1;
	for i, e in System:GetEntities() do
		local P = e.Who;
		if (type(P) == "table" and P.classname == "Player" and not P.ai and BasicPlayer.IsAlive(P) and e:GetState() == "Occupied") then
			if (e.Properties and e.Properties.DimX and CoopUseNear(e, P, 0.2)) then return P, e; end
			if (not P1) then P1, e1 = P, e; end
		end
	end
	return P1, e1;
end

-- From CoopStartLevel (the mission end, on the server): 1 when the exit takes over the level
-- change, nil to change it now (nobody in a trigger: an end after a cutscene or a timer).
function CoopExitOpen(map)
	if (COOP_Exit) then COOP_Exit.map = map; return 1; end
	local P, e = CoopExitOpener();
	if (not P) then return; end
	local p = new(P:GetPos()); -- a copy: e:GetPos() below returns the same shared table
	local x = {map = map, x = p.x, y = p.y, z = p.z, hx = COOP_EXIT_MIN / 2, hy = COOP_EXIT_MIN / 2, ends = _time + COOP_ExitTime, hold = {}, sendAt = 0};
	local d = e.Properties;
	if (d and d.DimX and d.DimY) then -- a box trigger (the engine lets players in by it along the world axes)
		local t = e:GetPos();
		x.x = t.x;
		x.y = t.y;
		x.hx = max(d.DimX / 2, x.hx); -- one by one (Lua 4, see CoopAimedPlayer)
		x.hy = max(d.DimY / 2, x.hy);
	end
	-- the opener is in, even from the edge of a wide trigger (counted by his body, the zone by his feet)
	x.hold[P.id] = {x = p.x, y = p.y, z = p.z, P = P};
	COOP_Exit = x;
	CoopMonEvent("S", format("exit open by %s (%s) at %.1f,%.1f,%.1f, %.0f x %.0f m, %d s", P:GetName(), e:GetName(), x.x, x.y, x.z, x.hx * 2, x.hy * 2, COOP_ExitTime));
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
				if (P == _localplayer and not P.theVehicle and (px - h.x) * (px - h.x) + (py - h.y) * (py - h.y) > COOP_EXIT_HOLD * COOP_EXIT_HOLD) then
					P:SetPos({x = h.x, y = h.y, z = h.z}); -- a remote player holds himself (EXIT command, CoopExitClientTick)
				end
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

function CoopExitClose(x, why)
	CoopMonEvent("S", format("exit: %s, %d s left: %s", why, max(0, floor(x.ends - _time)), x.map));
	COOP_Exit = nil;
	COOP_ExitView = nil;
	Server:BroadcastCommand("EXIT -");
	COOP_PendingMap = x.map; -- GameRules:OnUpdate loads it next frame
	return 1;
end

Game:AddCommand("coop_exittime", "COOP_ExitTime = tonumber(%%) or 120", "coop_exittime <s>: how long the exit waits for the players at a level end (120)");

-- client (and a listen host) -----------------------------------------------------------------

-- "EXIT <x> <y> <z> <half width x> <half width y> <seconds left> <players needed> [<hold x> <hold y>
-- <hold z>]", once a second while the exit is open; "EXIT -" when it closes.
if (ClientStuff and ClientStuff.ServerCommandTable) then ClientStuff.ServerCommandTable["EXIT"] = function(String, tk)
	if (Game:IsServer()) then return; end
	if (tk[2] == "-") then COOP_ExitView = nil; return; end
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
	if (_time > v.at + 3 or _time < v.at) then COOP_ExitView = nil; return; end -- the server stopped (a map change)
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
