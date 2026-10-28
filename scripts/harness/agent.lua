-- FC1 Co-op test harness agent.
-- Runs inside the game (Lua 4.1). Loaded from the command line by tools/harness:
--   "#HARNESS_DIR='D:/.../server' HARNESS_NAME='server'" "#Script:LoadScript('D:/.../agent.lua')"
--
-- Protocol (files in HARNESS_DIR):
--   cmd.txt    harness -> agent, lines "<seq>\t<command>". "lua <code>" runs Lua, anything else is a console command.
--   ack.txt    agent -> harness, appended "<seq>\t<ok|err>\t<info>" per executed command.
--   state.txt  agent -> harness, rewritten every tick (key=value lines), via state.tmp + rename.
--
-- Script timers are wiped by CXGame::LoadLevelCS, so the agent re-arms itself from
-- OnAfterLoadGameRules (called by CXServerRules on every level load) and from Hud:OnUpdate.

if (not Harness) then
	Harness = {
		lastSeq = 0,
		gen = 0,
		ticks = 0,
		lastTick = 0,
		period = 200,
		hooked = nil,
	};
end

Harness.dir = HARNESS_DIR;
Harness.name = HARNESS_NAME or "game";

function Harness:Log(msg)
	System:LogAlways("[HARNESS] "..tostring(msg));
end

function Harness:Path(file)
	return self.dir.."/"..file;
end

-- (Re)arm the tick timer. Older timers carry a stale gen and are ignored.
function Harness:Arm(reason)
	self.gen = self.gen + 1;
	self.lastTick = System:GetCurrAsyncTime();
	Game:SetTimer(self, self.period, {gen = self.gen});
	self:Log("armed gen="..self.gen.." reason="..tostring(reason));
end

function Harness:EnsureArmed(reason)
	if (System:GetCurrAsyncTime() - self.lastTick > 2) then
		self:Arm(reason);
	end
end

function Harness:OnEvent(event, param)
	if (type(param) ~= "table" or param.gen ~= self.gen) then
		return;
	end
	self.lastTick = System:GetCurrAsyncTime();
	self.ticks = self.ticks + 1;
	local ok = call(self.Tick, {self}, "x", Harness.OnError);
	Game:SetTimer(self, self.period, param);
end

function Harness.OnError(msg)
	System:LogAlways("[HARNESS] tick error: "..tostring(msg));
end

function Harness:Tick()
	self:WrapHud();
	self:ReadCommands();
	if (mod(self.ticks, 5) == 1) then
		self:WriteState();
	end
	if (self.trace) then
		self:TraceTick();
	end
end

-- Trace(pattern, file): every tick, append "time id class name x y z" for each entity
-- whose class or name matches the Lua pattern (e.g. "^Ammo"; "@pickup" = every BasePickup).
-- Trace() stops.
function Harness:Trace(pattern, file)
	if (not pattern) then
		self.trace = nil;
		return "trace off";
	end
	self.trace = {pattern = pattern, file = file or "trace.txt"};
	return "trace "..pattern;
end

function Harness:TraceTick()
	local t = self.trace;
	local f = openfile(self:Path(t.file), "a");
	if (not f) then
		return;
	end
	local now = format("%.2f", _time);
	for i, e in System:GetEntities() do
		local cls, name = tostring(e.classname), tostring(e:GetName());
		local hit;
		if (t.pattern == "@pickup") then
			hit = e.AttemptPick;
		else
			hit = strfind(cls, t.pattern) or strfind(name, t.pattern);
		end
		if (hit) then
			local p = e:GetPos();
			write(f, format("%s\t%d\t%s\t%s\t%.2f\t%.2f\t%.2f\n", now, e.id, cls, name, p.x, p.y, p.z));
		end
	end
	closefile(f);
end

-- Commands -------------------------------------------------------------------

function Harness:ReadCommands()
	local f = openfile(self:Path("cmd.txt"), "r");
	if (not f) then
		return;
	end
	local lines = {};
	local line = read(f, "*l");
	while (line) do
		tinsert(lines, line);
		line = read(f, "*l");
	end
	closefile(f);

	for i = 1, getn(lines) do
		local _, _, seq, cmd = strfind(lines[i], "^(%d+)\t(.*)$");
		seq = tonumber(seq);
		if (seq and seq > self.lastSeq) then
			self.lastSeq = seq;
			self:Exec(seq, cmd);
		end
	end
end

-- Commands that reach CXGame::LoadLevelCS. It calls CScriptTimerMgr::Reset, which
-- frees the timer map while CScriptTimerMgr::Update is iterating it, so these must not
-- run from our timer: they are queued and run from Hud:OnUpdate instead.
Harness.loadPatterns = {"^map ", "^load_level", "^start_server", "^load_game", "^load_lastcheckpoint",
	"^connect", "^disconnect", "^reconnect", "Game:Load", "Game:Connect", "Game:Disconnect"};

function Harness:IsLoadCommand(cmd)
	local body = cmd;
	if (strsub(body, 1, 4) == "lua ") then
		body = strsub(body, 5);
	end
	for i = 1, getn(self.loadPatterns) do
		if (strfind(body, self.loadPatterns[i])) then
			return 1;
		end
	end
end

function Harness:Exec(seq, cmd)
	if (not self.inHud and self:IsLoadCommand(cmd)) then
		self.deferred = self.deferred or {};
		tinsert(self.deferred, {seq = seq, cmd = cmd});
		self:Log("deferred #"..seq..": "..cmd);
		return;
	end
	self:Log("exec #"..seq..": "..cmd);
	local status, info = "ok", "";
	if (strsub(cmd, 1, 4) == "lua ") then
		local res = dostring(strsub(cmd, 5));
		if (res == nil) then
			status = "err";
		elseif (type(res) == "string" or type(res) == "number") then
			info = ""..res;
		end
	else
		System:ExecuteCommand(cmd);
	end
	local f = openfile(self:Path("ack.txt"), "a");
	if (f) then
		-- write() garbles numbers in this Lua build; concatenate into one string.
		write(f, seq.."\t"..status.."\t"..info.."\n");
		closefile(f);
	end
end

-- State ----------------------------------------------------------------------

function Harness:Num(v)
	if (not v) then
		return "nil";
	end
	return format("%.2f", v);
end

function Harness:Vec(v)
	if (not v) then
		return "nil";
	end
	return format("%.2f,%.2f,%.2f", v.x, v.y, v.z);
end

function Harness:WriteState()
	local out = {};
	tinsert(out, "name="..self.name);
	tinsert(out, "ticks="..self.ticks);
	tinsert(out, "gen="..self.gen);
	tinsert(out, "time="..self:Num(System:GetCurrAsyncTime()));
	tinsert(out, "level="..tostring(Game:GetLevelName()));
	tinsert(out, "server="..tostring(Game:IsServer()));
	tinsert(out, "client="..tostring(Game:IsClient()));
	tinsert(out, "mp="..tostring(Game:IsMultiplayer()));
	tinsert(out, "lastseq="..self.lastSeq);

	local me = _localplayer;
	if (me) then
		tinsert(out, "me.id="..tostring(me.id));
		tinsert(out, "me.pos="..self:Vec(me:GetPos()));
		if (me.cnt) then
			tinsert(out, "me.health="..tostring(me.cnt.health));
		end
	end

	local ents = System:GetEntities();
	local total, players, ai, aiAlive = 0, 0, 0, 0;
	if (ents) then
		for i, e in ents do
			total = total + 1;
			if (e.type == "Player") then
				if (e.ai) then
					ai = ai + 1;
					if (e.cnt and e.cnt.health and e.cnt.health > 0) then
						aiAlive = aiAlive + 1;
					end
				else
					players = players + 1;
					tinsert(out, "player."..tostring(e.id).."="..tostring(e:GetName()).."|"..self:Vec(e:GetPos()).."|"..tostring(e.cnt and e.cnt.health));
				end
			end
		end
	end
	tinsert(out, "ents="..total);
	tinsert(out, "players="..players);
	tinsert(out, "ai="..ai);
	tinsert(out, "ai.alive="..aiAlive);

	local tmp = self:Path("state.tmp");
	local f = openfile(tmp, "w");
	if (not f) then
		return;
	end
	for i = 1, getn(out) do
		write(f, out[i], "\n");
	end
	closefile(f);
	remove(self:Path("state.txt"));
	rename(tmp, self:Path("state.txt"));
end

-- First player entity that is not this machine's own player (for scenario steps).
function Harness:RemotePlayer()
	for i, e in System:GetEntities() do
		if (e.type == "Player" and not e.ai and e ~= _localplayer) then
			return e;
		end
	end
end

-- Snapshot of every scripted entity for desync comparison (harness diff).
-- Line: id \t class \t name \t x \t y \t z \t health
function Harness:Snapshot(file)
	local f = openfile(self:Path(file or "snap.txt"), "w");
	if (not f) then
		return "cannot open snap file";
	end
	local n = 0;
	for i, e in System:GetEntities() do
		local p = e:GetPos();
		local hp = "-";
		if (e.cnt and e.cnt.health) then
			hp = format("%d", e.cnt.health);
		end
		write(f, format("%d\t%s\t%s\t%.2f\t%.2f\t%.2f\t%s\n", e.id, tostring(e.classname), tostring(e:GetName()), p.x, p.y, p.z, hp));
		n = n + 1;
	end
	closefile(f);
	return "snap "..n;
end

-- Hooks ----------------------------------------------------------------------

-- Level loads (CXGame::LoadLevelCS) wipe script timers. They are synchronous and
-- reached from Lua (console "map"/"start_server", menus, missions), so re-arm right
-- after them. (OnAfterLoadGameRules is commented out in CXServerRules.)
Harness.loadFuncs = {"LoadLevel", "LoadLevelListen", "LoadLevelMPServer", "Load", "LoadLatestCheckPoint"};

function Harness:WrapGame()
	for i = 1, getn(self.loadFuncs) do
		local fname = self.loadFuncs[i];
		local orig = Game[fname];
		if (orig and not Harness["orig"..fname]) then
			Harness["orig"..fname] = orig;
			-- Forward the exact arguments: the C++ side checks GetParamCount().
			Game[fname] = dostring("return function(...) "..
				"local r = call(Harness.orig"..fname..", arg); "..
				"Harness:Arm('"..fname.."'); return r; end");
		end
	end
end

-- Loads started from C++ (e.g. a remote client following the server via
-- CXSystemBase::LoadLevelCommon -> CXGame::Reset) bypass the wrappers above.
-- CXGame::Reset nils _localplayer and the engine assigns it again once the local
-- player exists, so a "setglobal" tag method on nil catches every level load.
function Harness.OnSetGlobal(name, old, new)
	if (Harness.prevSetGlobalTM) then
		Harness.prevSetGlobalTM(name, old, new);
	else
		rawset(globals(), name, new);
	end
	if (name == "_localplayer" and new) then
		Harness:Arm("localplayer");
	end
end

if (not Harness.hooked) then
	Harness.hooked = 1;
	Harness:WrapGame();
	Harness.prevSetGlobalTM = gettagmethod(tag(nil), "setglobal");
	settagmethod(tag(nil), "setglobal", Harness.OnSetGlobal);
end

-- Hud is reloaded with the level, so (re)wrap it on every tick if needed.
function Harness:WrapHud()
	if (Hud and Hud.OnUpdate and not Hud.harnessWrapped) then
		Hud.harnessWrapped = 1;
		Hud.harnessPrevOnUpdate = Hud.OnUpdate;
		Hud.OnUpdate = function(self)
			Harness:EnsureArmed("hud");
			Harness:RunDeferred();
			return self.harnessPrevOnUpdate(self);
		end
	end
end

function Harness:RunDeferred()
	if (not self.deferred or getn(self.deferred) == 0) then
		return;
	end
	local q = self.deferred;
	self.deferred = {};
	self.inHud = 1;
	for i = 1, getn(q) do
		self:Exec(q[i].seq, q[i].cmd);
	end
	self.inHud = nil;
end

Harness:Log("agent loaded, dir="..tostring(Harness.dir).." name="..Harness.name);
Harness:Arm("load");
