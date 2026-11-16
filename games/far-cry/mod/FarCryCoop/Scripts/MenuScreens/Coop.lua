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
	-- the Steam lobby's type (steam.c "coop_steam host <max> <type>": k_ELobbyType)
	Access = {"Everyone", "Friends only", "Invite only"},
	AccessType = {"public", "friends", "private"},
	MaxPlayers = 16, -- steam.c: a lobby holds up to 16

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
			width = 580, height = 302,
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

		MaxText =
		{
			skin = UI.skins.Label,
			left = 500, top = 240,
			width = 130,
			text = "Max players",
		},

		MaxCombo =
		{
			skin = UI.skins.ComboBox,
			left = 640, top = 236,
			width = 80, height = 25,
			tabstop = 4,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},

		AccessText =
		{
			skin = UI.skins.Label,
			left = 210, top = 320,
			width = 180,
			text = "Who can join (Steam)",
		},

		AccessCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 316,
			width = 200, height = 25,
			tabstop = 6,
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
			tabstop = 5,
		},

		PasswordText =
		{
			skin = UI.skins.Label,
			left = 210, top = 360,
			width = 180,
			text = "Password (optional)",
		},

		Password =
		{
			skin = UI.skins.EditBox,
			left = 400, top = 356,
			width = 200,
			tabstop = 7,
		},

		-- the game's name in Find game (Steam lobby, LAN sv_name); empty: "<player> - <map>"
		ServerNameText =
		{
			skin = UI.skins.Label,
			left = 210, top = 400,
			width = 180,
			text = "Server name (optional)",
		},

		ServerName =
		{
			skin = UI.skins.EditBox,
			left = 400, top = 396,
			width = 200,
			tabstop = 8,
		},

		JoinIP =
		{
			skin = UI.skins.BottomMenuButton,
			left = 200,
			tabstop = 9,
			text = "Join by IP",
			OnCommand = function(Sender)
				UI.JoinIPBox("Join by IP", "Enter the host's IP and port (49001)", UI.PageCoop.ConnectIP);
			end,
		},

		PlayerSettings =
		{
			skin = UI.skins.BottomMenuButton,
			left = 400,
			tabstop = 11,
			text = "Player settings",
			OnCommand = function(Sender)
				GotoPage("CoopPlayer");
			end,
		},

		Launch =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 10,
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
		GUI.ServerName:SetMaxLength(COOP_SERVER_NAME_MAX);
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

		GUI.MaxCombo:Clear();
		for i = 1, UI.PageCoop.MaxPlayers do
			GUI.MaxCombo:AddItem(tostring(i));
		end
		GUI.MaxCombo:Select(tostring(UI.PageCoop.nLastMax or 4));

		GUI.AccessCombo:Clear();
		for i, a in UI.PageCoop.Access do
			GUI.AccessCombo:AddItem(a);
		end
		GUI.AccessCombo:SelectIndex(UI.PageCoop.nLastAccess or 2);

		GUI.Password:SetPassword(1); -- stars, as the game's own password boxes
		GUI.Password:SetText(tostring(getglobal("sv_password") or ""));

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
		-- loads the level at once (CXGame::LoadLevelCS resets the script timers): run it from a
		-- click or a console line, never from a Game:SetTimer callback (docs/findings.md 2026-11-15)
		-- the launcher's settings first (shirt color, weapons; COOP ClientStuff would load them at the
		-- map start, over the choices below, while COOP_Color is unset)
		if (not COOP_Color) then Script:LoadScript("Mods/FarCryCoop/prefs.lua"); end
		CoopApplySteamName(); -- the Steam name over prefs.lua's p_name (the lobby name uses it)
		-- joined to somebody else's game: leave it first (a host keeps its players: a map change)
		if (not Game:IsServer()) then Game:Disconnect(); end
		-- by index: the combo shows Localize's text ("@Veteran" comes back as "Veteran", or the
		-- game's language)
		local diff = tonumber(GUI.DifficultyCombo:GetSelectionIndex());
		if (diff and diff >= 1 and diff <= 5) then COOP_Difficulty = diff - 1; else COOP_Difficulty = 1; end
		COOP_ExpectPlayers = tonumber(GUI.WaitCombo:GetSelection()) or 1;
		if (GUI.Loadout:GetChecked()) then COOP_LoadoutMode = 1; else COOP_LoadoutMode = 0; end
		UI.PageCoop.szLastMap = sel;
		local max = tonumber(GUI.MaxCombo:GetSelection()) or 4;
		if (max < COOP_ExpectPlayers) then max = COOP_ExpectPlayers; end -- the waited-for players must fit
		local access = tonumber(GUI.AccessCombo:GetSelectionIndex()) or 1;
		if (not UI.PageCoop.AccessType[access]) then access = 1; end
		UI.PageCoop.nLastMax, UI.PageCoop.nLastAccess = max, access;
		local n = strlen(UI.PageCoop.SavePrefix);
		local map = sel;
		if (strsub(sel, 1, n) == UI.PageCoop.SavePrefix) then map = strsub(sel, n + 1); end
		-- The engine's own server settings: sv_maxplayers turns away a player over the limit (the
		-- host counts: "@ServerFull", SDK CXServer), sv_password one without the password; the
		-- game asks a joining player for it itself (Multiplayer/Connecting.lua, InvalidServerPassword).
		-- They apply to the next players who connect, on a map change too.
		local pw = UI.PageCoop.CleanPassword(GUI.Password:GetText());
		setglobal("sv_maxplayers", max);
		setglobal("sv_password", pw);
		COOP_MenuLaunch = 1; -- CoopMap: a new game with this screen's settings, not a console one
		-- the player's own name for the game, or nil: "<player> - <map>" (CoopServerName)
		COOP_ServerName = CoopServerName(GUI.ServerName:GetText());
		if (COOP_ServerName == "") then COOP_ServerName = nil; end
		local lobby = {max = max, access = UI.PageCoop.AccessType[access], pw = (pw ~= "" and 1) or 0, map = map, name = COOP_ServerName};
		if (Game:IsServer() and COOP_Lobby) then
			COOP_Lobby = lobby; -- a map change: the lobby follows (CoopLobbyUpdate, once a second)
		elseif (not Game:IsServer()) then
			-- a new game: its Steam lobby, so friends and the world list find it. Without Steam the
			-- ASI says so in the console (CoopSteam_OnLobby(0)).
			-- (without Steam the ASI answers CoopSteam_OnLobby(0) inside this call: COOP_Lobby is
			-- nil after it)
			COOP_Lobby = lobby;
			COOP_LobbySent = CoopLobbyArgs();
			System:ExecuteCommand("coop_steam host "..COOP_LobbySent);
		end
		if (strsub(sel, 1, n) == UI.PageCoop.SavePrefix) then
			System:ExecuteCommand("coop_loadgame "..strsub(sel, n + 1));
		else
			System:ExecuteCommand("coop_map "..sel);
		end
	end,

	-- a password the engine and a joining player can take: printable ASCII, 32 at most (the game's
	-- own password box takes 32, Multiplayer/Connecting.lua)
	CleanPassword = function(s)
		return strsub(gsub(tostring(s or ""), "[^ -~]", ""), 1, 32);
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

-- the ASI, once Steam has answered "coop_steam host" (steam.c)
function CoopSteam_OnLobby(ok)
	if (ok == 1) then
		-- an update sent before Steam had created it was refused ("no lobby of ours"): send the
		-- game as it is now (CoopLobbyUpdate)
		COOP_LobbySent = nil;
		System:LogAlways("coop: Steam lobby created");
	else
		COOP_Lobby = nil; -- nothing to update
		System:LogAlways("coop: no Steam lobby (Steam is off or offline): friends join by IP");
	end
end

AddUISideMenu(UI.PageCoop.GUI,
{
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0},
	{ "CoopFind", "Find game", "CoopFind", },
	{ "Options", Localize("Options"), "Options", },
});

UI:CreateScreenFromTable("Coop", UI.PageCoop.GUI);
