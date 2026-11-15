-- FarCryCoop "Co-op" screen (docs/specs/in-game-menu.md, step 3b): create a co-op game, or join one
-- by address. Laid out like the game's own Create Server screen (MultiPlayer/CreateServer.lua).
-- "Launch" sets what the launcher used to put in the console line (COOP_ExpectPlayers,
-- COOP_Difficulty, COOP_LoadoutMode) and starts the map or save with the console commands
-- coop_map / coop_loadgame: the ASI marks the game as a co-op one from those lines (steam.c hExec),
-- and they run without -DEVMODE, unlike "#" Lua lines.

UI.PageCoop =
{
	-- the campaign in story order (defiant.lua DEFIANT)
	Maps = {"Training", "Carrier", "Fort", "Pier", "Research", "Treehouse", "Bunker", "Steam",
		"Regulator", "Control", "Rebellion", "Archive", "Cooler", "Boat", "Catacombs", "River",
		"Swamp", "Factory", "Dam", "Volcano"},
	SavePrefix = "Save: ",
	Difficulty = {"Easy", "Medium", "Challenging", "Veteran", "Realistic"}, -- 0..4, Campaign.lua

	GUI =
	{
		TitleText =
		{
			skin = UI.skins.Label,
			left = 200, top = 110,
			width = 300,
			halign = UIALIGN_LEFT,
			text = "Create a co-op game",
		},

		Border =
		{
			skin = UI.skins.MenuBorder,
			left = 200, top = 141,
			width = 580, height = 222,
			zorder = -50,
		},

		MapText =
		{
			skin = UI.skins.Label,
			left = 210, top = 160,
			width = 180,
			text = "Map or save",
		},

		MapCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 156,
			width = 200, height = 25,
			tabstop = 1,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},

		DifficultyText =
		{
			skin = UI.skins.Label,
			left = 210, top = 200,
			width = 180,
			text = "Difficulty",
		},

		DifficultyCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 196,
			width = 200, height = 25,
			tabstop = 2,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},

		WaitText =
		{
			skin = UI.skins.Label,
			left = 210, top = 240,
			width = 180,
			text = "Players to wait for",
		},

		WaitCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 236,
			width = 80, height = 25,
			tabstop = 3,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},

		LoadoutText =
		{
			skin = UI.skins.Label,
			left = 210, top = 280,
			width = 180,
			text = "Weapon loadout",
		},

		Loadout =
		{
			skin = UI.skins.CheckBox,
			left = 400, top = 280,
			tabstop = 4,
		},

		JoinIP =
		{
			skin = UI.skins.BottomMenuButton,
			left = 200,
			tabstop = 5,
			text = "Join by IP",
			OnCommand = function(Sender)
				UI.JoinIPBox("Join by IP", "Enter the host's IP and port (49001)", UI.PageCoop.ConnectIP);
			end,
		},

		Launch =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 6,
			text = Localize("Launch"),
			OnCommand = function(Sender)
				UI.PageCoop.Launch();
			end,
		},

		OnActivate = function(Sender)
			UI.PageCoop.Fill();
		end,
	},

	Fill = function()
		local GUI = UI.PageCoop.GUI;
		GUI.MapCombo:Clear();
		for i, m in UI.PageCoop.Maps do
			GUI.MapCombo:AddItem(m);
		end
		for i, s in UI.PageCoop.Saves() do
			GUI.MapCombo:AddItem(UI.PageCoop.SavePrefix..s);
		end
		GUI.MapCombo:Select(UI.PageCoop.szLastMap or UI.PageCoop.Maps[1]);

		GUI.DifficultyCombo:Clear();
		for i, d in UI.PageCoop.Difficulty do
			GUI.DifficultyCombo:AddItem(Localize(d));
		end
		GUI.DifficultyCombo:SelectIndex((tonumber(COOP_Difficulty) or 1) + 1);

		GUI.WaitCombo:Clear();
		for i = 1, 8 do
			GUI.WaitCombo:AddItem(tostring(i));
		end
		GUI.WaitCombo:Select(tostring(tonumber(COOP_ExpectPlayers) or 2));

		if (tonumber(COOP_LoadoutMode) == 1) then GUI.Loadout:SetChecked(1); else GUI.Loadout:SetChecked(0); end
	end,

	-- co-op saves: Mods/FarCryCoop/save_<name>.lua (COOP gamerules CoopSave)
	Saves = function()
		local out = {};
		local files = System:ScanDirectory("Mods/FarCryCoop", SCANDIR_FILES) or {};
		for i, f in files do
			local s, e, name = strfind(f, "^save_([%w_]+)%.lua$");
			if (name) then tinsert(out, name); end
		end
		sort(out);
		return out;
	end,

	Launch = function()
		local GUI = UI.PageCoop.GUI;
		local sel = GUI.MapCombo:GetSelection();
		if (not sel) then return; end
		-- the launcher's settings first (shirt color, weapons; COOP ClientStuff would load them at the
		-- map start, over the choices below, while COOP_Color is unset)
		if (not COOP_Color) then Script:LoadScript("Mods/FarCryCoop/prefs.lua"); end
		-- joined to somebody else's game: leave it first (a host keeps its players: a map change)
		if (not Game:IsServer()) then Game:Disconnect(); end
		-- by index: the combo shows Localize's text ("@Veteran" comes back as "Veteran", or the
		-- game's language)
		local diff = tonumber(GUI.DifficultyCombo:GetSelectionIndex());
		if (diff and diff >= 1 and diff <= 5) then COOP_Difficulty = diff - 1; else COOP_Difficulty = 1; end
		COOP_ExpectPlayers = tonumber(GUI.WaitCombo:GetSelection()) or 1;
		if (GUI.Loadout:GetChecked()) then COOP_LoadoutMode = 1; else COOP_LoadoutMode = 0; end
		UI.PageCoop.szLastMap = sel;
		local n = strlen(UI.PageCoop.SavePrefix);
		if (strsub(sel, 1, n) == UI.PageCoop.SavePrefix) then
			System:ExecuteCommand("coop_loadgame "..strsub(sel, n + 1));
		else
			System:ExecuteCommand("coop_map "..sel);
		end
	end,

	ConnectIP = function(IP1, IP2, IP3, IP4, Port)
		UI:DeactivateScreen("JoinIPDialog");
		-- the dialog hands back its fields as typed ("" when empty)
		local ip = {IP1, IP2, IP3, IP4};
		for i = 1, 4 do
			local n = tonumber(ip[i] or "");
			if (not n or n < 0 or n > 255 or strfind(tostring(ip[i]), "[^%d]")) then
				System:LogAlways("coop: join by IP: not an address");
				return;
			end
		end
		local addr = ip[1].."."..ip[2].."."..ip[3].."."..ip[4];
		if (Port and Port ~= "") then
			if (not tonumber(Port) or strfind(tostring(Port), "[^%d]")) then
				System:LogAlways("coop: join by IP: not a port");
				return;
			end
			addr = addr..":"..Port;
		end
		Game:Disconnect(); -- as the game's own server lists do before they join
		System:ExecuteCommand("coop_connect "..addr);
	end,
}

AddUISideMenu(UI.PageCoop.GUI,
{
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0},
	{ "Options", Localize("Options"), "Options", },
});

UI:CreateScreenFromTable("Coop", UI.PageCoop.GUI);
