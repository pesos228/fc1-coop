-- Field of view and view distance in Options > Video > Advanced Options > More Options (owner,
-- 2026-11-19/20). Each player's own, kept in Mods/FarCryCoop/view.lua; nothing goes to the server.
--
-- The game's view is 90 degrees everywhere: a new player entity starts with it (SDK CPlayer), and
-- ZoomView (scripts/Default/Hud/ZoomView.lua) zooms from NoZoom = 90 degrees to NoZoom / step for
-- the weapon sights, scopes and binoculars, and back. Ground vehicles narrow it to 70. So the angle
-- the scripts ask Game:SetCameraFov for is mapped to the player's:
--   not zoomed: scaled, 90 -> the player's angle (any other angle by the same ratio);
--   zoomed: a zoom step stays the game's own (the scopes and binoculars look as they always did),
--   or the player's angle / step when that is narrower (a narrow view must still zoom in), and
--   the fade between 90 and the step goes from the player's angle instead.
-- A camera the scripts did not set (a new entity after a respawn or a map start) is put right
-- every frame by CoopViewTick.
-- The game turns the view by the mouse times the angle / 90 degrees (SDK CXClient::TriggerTurnLR):
-- a wider view would turn faster, so out of zoom the mouse is scaled by 90 / angle. ZoomView sets
-- the scale itself while zoomed (0.3) and back to 1 after: it gets 1 to start from. In a menu
-- (the game runs on under it in a network game, UISystem.lua puts the scale to 1 for the cursor)
-- and out of a game the scale is 1.

COOP_FOV_MIN, COOP_FOV_MAX = 60, 120
COOP_FOV_GAME = 90 * 3.1415962 / 180 -- ZoomView.NoZoom, with the game's own digits
function CoopFovClamp(d)
	d = floor(tonumber(d) or 90);
	if (d < COOP_FOV_MIN) then return COOP_FOV_MIN; elseif (d > COOP_FOV_MAX) then return COOP_FOV_MAX; end
	return d;
end

COOP_Fov = COOP_Fov or 90
do -- COOP_Fov=... once the player chose one (no file: no "unable to open" error)
	local f = openfile("Mods/FarCryCoop/view.lua", "r");
	if (f) then
		closefile(f);
		Script:LoadScript("Mods/FarCryCoop/view.lua");
	end
	COOP_Fov = CoopFovClamp(COOP_Fov); -- a hand-edited file
end

-- View distance in Options > Game (owner, 2026-11-19: bushes and trees pop up right in front of
-- the player). The engine's own distances, scaled from the player's video settings:
--   e_obj_view_dist_ratio: how far objects and vegetation are drawn at all;
--   e_vegetation_sprites_distance_ratio: where vegetation turns from a model into a flat sprite;
--   e_obj_lod_ratio: how far the detailed models are kept.
-- Pier, Medium, 800x600 (docs/findings.md): 1x 114 fps, 3x 107. A map change keeps them.
-- The game writes two of them to system.cfg on quit: a scaled value would come back as the
-- player's own and be scaled again. So the player's values and ours are kept in view.lua too: a
-- value still at ours keeps the kept base; any other (the Video options, a preset) is the
-- player's new base.
COOP_VIEW_VARS = {"e_obj_view_dist_ratio", "e_vegetation_sprites_distance_ratio", "e_obj_lod_ratio"}
COOP_VIEW_MIN, COOP_VIEW_MAX = 100, 300 -- percent
COOP_ViewDist = COOP_ViewDist or 100
COOP_ViewBase = COOP_ViewBase or {} -- var -> the player's own value
COOP_ViewSet = COOP_ViewSet or {}   -- var -> the value set here
function CoopViewDistClamp(p)
	p = floor(tonumber(p) or 100);
	if (p < COOP_VIEW_MIN) then return COOP_VIEW_MIN; elseif (p > COOP_VIEW_MAX) then return COOP_VIEW_MAX; end
	return p;
end
COOP_ViewDist = CoopViewDistClamp(COOP_ViewDist);
if (type(COOP_ViewBase) ~= "table") then COOP_ViewBase = {}; end
if (type(COOP_ViewSet) ~= "table") then COOP_ViewSet = {}; end

-- puts the scaled values in; a value that is not ours is the player's new base
function CoopViewApply()
	local m = COOP_ViewDist / 100;
	local changed;
	for i, v in COOP_VIEW_VARS do
		local cur = tonumber(getglobal(v));
		if (cur) then
			local set = tonumber(COOP_ViewSet[v]);
			if (not set or not tonumber(COOP_ViewBase[v]) or abs(cur - set) > 0.001 * max(1, abs(set))) then
				COOP_ViewBase[v] = cur;
				changed = 1;
			end
			local want = COOP_ViewBase[v] * m;
			if (abs(want - cur) > 0.0001 * max(1, abs(want))) then setglobal(v, want); end
			if (set ~= want) then COOP_ViewSet[v] = want; changed = 1; end
		end
	end
	-- kept only while scaled: at 100 the game's own value is the player's (CoopViewDistSet saves 100)
	if (changed and m ~= 1) then CoopViewSave(); end
end

function CoopViewDistSet(p)
	COOP_ViewDist = CoopViewDistClamp(p);
	CoopViewApply();
	CoopViewSave();
end

function CoopViewSave()
	local f = openfile("Mods/FarCryCoop/view.lua", "w");
	if (not f) then
		System:LogAlways("coop: view: cannot write Mods/FarCryCoop/view.lua");
		return;
	end
	write(f, format("COOP_Fov=%d\nCOOP_ViewDist=%d\n", COOP_Fov, COOP_ViewDist));
	for i, t in {"COOP_ViewBase", "COOP_ViewSet"} do
		write(f, t.."={");
		for k, v in getglobal(t) do
			if (tonumber(v)) then write(f, format("%s=%.6g,", k, v)); end
		end
		write(f, "}\n");
	end
	closefile(f);
end

function CoopFovRad()
	return CoopFovClamp(COOP_Fov) * 3.1415962 / 180;
end

-- the angle a script asked for -> the one to set
function CoopFovMap(f)
	local u, g = CoopFovRad(), COOP_FOV_GAME;
	if (abs(u - g) < 0.0001 or type(f) ~= "number") then return f; end
	local Z = ZoomView;
	if (Z and (Z.active or Z.COOP_Activating)) then -- Activate sets the angle before it marks itself active
		local step = Z.ZoomSteps and Z.CurrZoomStep and tonumber(Z.ZoomSteps[Z.CurrZoomStep]);
		if (f >= g - 0.0001) then return u; end
		if (step and step > 1) then
			local tv = (Z.NoZoom or g) / step; -- the step the scripts ask for
			local tu = min(g, u) / step;      -- the one we give
			if (f > tv) then return tu + (f - tv) * (u - tu) / (g - tv); end -- fading in or out
			return f * tu / tv;
		end
		return f;
	end
	return f * u / g;
end

function CoopFovWrap()
	if (not Game or not Game.SetCameraFov or Game.COOP_StockSetFov) then return; end
	local stock = Game.SetCameraFov;
	Game.COOP_StockSetFov = stock;
	Game.SetCameraFov = function(self, f) return %stock(self, CoopFovMap(f)); end
end
CoopFovWrap();

-- ZoomView keeps the mouse scale it finds on the first zoom and sets 0.3 times it: give it 1
function CoopViewWrapZoom()
	local Z = ZoomView;
	if (not Z or not Z.Activate or Z.COOP_Act == Z.Activate) then return; end
	local act = Z.Activate;
	Z.Activate = function(self, a, b, c, d)
		if ((ZoomView.NumActive or 0) == 0 and not self.active) then Input:SetMouseSensitivityScale(1); end
		self.COOP_Activating = 1;
		local ok = call(%act, {self, a, b, c, d}, "x", function(msg) System:LogAlways("coop: zoom error: "..tostring(msg)); end);
		self.COOP_Activating = nil;
		return ok;
	end
	Z.COOP_Act = Z.Activate;
end

-- every frame on a client (ClientStuff:OnUpdate)
function CoopViewTick()
	CoopFovWrap();
	CoopViewWrapZoom();
	if (not COOP_ViewAt or _time > COOP_ViewAt + 1 or _time < COOP_ViewAt) then -- _time restarts with a map
		COOP_ViewAt = _time;
		CoopViewApply(); -- the Video options may have changed a value
	end
	local me = _localplayer;
	if (not me or not me.cnt or Game:IsInMenu()) then
		if (COOP_ViewMouse and abs((Input:GetMouseSensitivityScale() or 1) - COOP_ViewMouse) < 0.0005) then Input:SetMouseSensitivityScale(1); end
		COOP_ViewMouse = nil;
		return;
	end
	local zoomed = ZoomView and ZoomView.active;
	local u = CoopFovRad();
	if (not zoomed) then
		local f = Game:GetCameraFov();
		if (f and abs(f - u) > 0.0005 and abs(f - COOP_FOV_GAME) < 0.0005) then Game:COOP_StockSetFov(u); end
		local s = COOP_FOV_GAME / u;
		local cur = Input:GetMouseSensitivityScale();
		-- 1 is what ZoomView and the menu put back; a scale of ours from another angle too
		if (cur and abs(cur - s) > 0.0005 and (abs(cur - 1) < 0.0005 or abs(cur - (COOP_ViewMouse or 1)) < 0.0005)) then
			Input:SetMouseSensitivityScale(s);
		end
		COOP_ViewMouse = s;
	end
end

-- the player chose an angle (the slider): now, if in a game and not zoomed
function CoopFovSet(d)
	COOP_Fov = CoopFovClamp(d);
	if (_localplayer and _localplayer.cnt and not (ZoomView and ZoomView.active)) then
		Game:COOP_StockSetFov(CoopFovRad());
	end
end

-- Options > Video > Advanced Options > "More Options" (owner, 2026-11-20: a second page of the
-- advanced video options, "next page" at the bottom right; its "Back" at the bottom left where the
-- first page has "Basic Options"). Applied at once, as the sliders of Options > Video are.
COOP_VIEW_STEPS = {{100, "Normal"}, {150, "Far"}, {200, "Very Far"}, {300, "Extreme"}}
UI.PageCoopVideoMore =
{
	GUI =
	{
		widget_title =
		{
			skin = UI.skins.TopMenuButton,
			left = 200, width = 580,
			text = "More Options",
		},
		widget_Fov_Text = { skin = UI.skins.Label, left = 200, top = 175, width = 160, text = "Field of View", },
		widget_Fov =
		{
			skin = UI.skins.HScrollBar,
			left = 370, top = 178, width = 120, height = 24,
			tabstop = 1,
			OnChanged = function(Sender)
				local v = tonumber(Sender:GetValue()) or 0;
				CoopFovSet(COOP_FOV_MIN + floor(v * (COOP_FOV_MAX - COOP_FOV_MIN) + 0.5));
				UI.PageCoopVideoMore.GUI.widget_FovValue:SetText(tostring(COOP_Fov));
				CoopViewSave();
			end,
		},
		widget_FovValue = { skin = UI.skins.Label, left = 495, top = 175, width = 40, halign = UIALIGN_LEFT, text = "90", },
		widget_ViewDist_Text = { skin = UI.skins.Label, left = 200, top = 225, width = 160, text = "View Distance", },
		widget_ViewDist =
		{
			skin = UI.skins.ComboBox,
			left = 370, top = 225, width = 120,
			tabstop = 2,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			OnChanged = function(Sender)
				local s = COOP_VIEW_STEPS[tonumber(Sender:GetSelectionIndex()) or 1];
				if (s) then CoopViewDistSet(s[1]); end
			end,
		},
		widget_back =
		{
			left = 208, top = 142 + 318 - 34,
			width = 160,
			skin = UI.skins.BottomMenuButton,
			bordersides = "lrtb",
			text = "Back",
			tabstop = 3,
			OnCommand = function(Sender)
				GotoPage("VideoAdvOptions");
			end,
		},
		OnActivate = function(Sender)
			CoopViewMenuShow();
		end,
	},
}
AddUISideMenu(UI.PageCoopVideoMore.GUI,
{
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0 },
});
UI:CreateScreenFromTable("CoopVideoMore", UI.PageCoopVideoMore.GUI);

-- the advanced page is made after this file: its "More Options" button is added once the main
-- menu shows (MenuScreens/MainScreen.lua) or a map starts (COOP ClientStuff OnSetPlayer)
function CoopViewPatchMenus()
	local P = UI and UI.PageOptionsVideoAdv;
	if (not P or not P.GUI or P.GUI.coop_more) then return; end
	P.GUI.coop_more = UI:CreateObjectFromTable("coop_more", {
		skin = UI.skins.BottomMenuButton,
		left = 780 - 180 - 178.5,
		tabstop = 27,
		text = "More Options",
		OnCommand = function(Sender)
			GotoPage("CoopVideoMore");
		end,
	}, "VideoAdvOptions");
end
-- the page shows the settings as they are now (they may change in the console or a harness)
function CoopViewMenuShow()
	local G = UI.PageCoopVideoMore.GUI;
	G.widget_Fov:SetValue((COOP_Fov - COOP_FOV_MIN) / (COOP_FOV_MAX - COOP_FOV_MIN));
	G.widget_FovValue:SetText(tostring(COOP_Fov));
	G.widget_ViewDist:Clear();
	local sel, best = 1, nil;
	for i, s in COOP_VIEW_STEPS do
		G.widget_ViewDist:AddItem(s[2]);
		local d = abs(s[1] - COOP_ViewDist);
		if (not best or d < best) then sel, best = i, d; end -- the nearest (an older file may have another value)
	end
	G.widget_ViewDist:SelectIndex(sel);
end
CoopViewApply();
