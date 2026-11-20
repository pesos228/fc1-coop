-- The co-op Esc menu (owner, 2026-11-20), in place of the single-player one (InGameSingle: its
-- checkpoint list loads single-player saves and drops everyone). COOP ClientStuff
-- GetInGameMenuName picks "CoopInGameHost" on the host and "CoopInGame" on a joined player.
-- Left: Return to game, Call a vote, (host) Save game, Load game, Co-op, Options, Leave or End
-- game, Quit. Right: who is in, with the Steam avatar, the name, the health and the host's mark
-- (the server's "PLIST", COOP ClientStuff COOP_PList). The host's rows of the others have a kick
-- and a ban icon; the server takes them from the host's own slot only (COOP gamerules
-- CoopAdminCmd).

COOP_MENU_ROWS = 8
COOP_MENU_ROW_H = 36
COOP_MENU_TOP = 147
COOP_MenuAvatarAsked = COOP_MenuAvatarAsked or {} -- SteamID -> when asked (the ASI writes the file)
-- one request per refresh: the ASI's queue to its Steam thread holds a few lines only (steam.c)
COOP_MENU_AVATAR_RETRY = 10

function CoopMenuIcon(name) return System:LoadImage("Scripts/COOP/Icons/"..name..".dds"); end

-- the rows of one screen: built for each, the widgets belong to one screen
function CoopMenuRows(GUI, host)
	for i = 1, COOP_MENU_ROWS do
		local top = COOP_MENU_TOP + (i - 1) * COOP_MENU_ROW_H;
		GUI["Avatar"..i] = {
			skin = UI.skins.MenuBorder,
			left = 210, top = top, width = 32, height = 32,
			color = "0 0 0 64",
		};
		GUI["Name"..i] = {
			skin = UI.skins.Label,
			left = 250, top = top + 2, width = 300,
			halign = UIALIGN_LEFT,
			text = "",
		};
		GUI["Host"..i] = {
			skin = UI.skins.Label,
			left = 550, top = top + 2, width = 70,
			halign = UIALIGN_LEFT,
			fontcolor = "158 204 128 255",
			text = "",
		};
		GUI["Health"..i] = {
			skin = UI.skins.Label,
			left = 620, top = top + 2, width = 60,
			halign = UIALIGN_RIGHT,
			text = "",
		};
		if (host) then
			GUI["Kick"..i] = {
				classname = "button",
				left = 700, top = top + 2, width = 28, height = 28,
				texture = CoopMenuIcon("kick"), overtexture = CoopMenuIcon("kick_over"), downtexture = CoopMenuIcon("kick_over"),
				texrect = "0 0 32 32",
				color = "255 255 255 255",
				bordersize = 0,
				tooltip = "Kick",
				user = {row = i},
				OnCommand = function(Sender) CoopMenuAsk("kick", Sender.user.row); end,
			};
			GUI["Ban"..i] = {
				classname = "button",
				left = 738, top = top + 2, width = 28, height = 28,
				texture = CoopMenuIcon("ban"), overtexture = CoopMenuIcon("ban_over"), downtexture = CoopMenuIcon("ban_over"),
				texrect = "0 0 32 32",
				color = "255 255 255 255",
				bordersize = 0,
				tooltip = "Ban",
				user = {row = i},
				OnCommand = function(Sender) CoopMenuAsk("ban", Sender.user.row); end,
			};
		end
	end
	GUI.PlayersText = {
		skin = UI.skins.Label,
		left = 200, top = 110, width = 300,
		halign = UIALIGN_LEFT,
		text = "Players",
	};
	GUI.PlayersBorder = {
		skin = UI.skins.MenuBorder,
		left = 200, top = 141,
		width = 580, height = COOP_MENU_ROWS * COOP_MENU_ROW_H + 10,
		zorder = -50,
	};
	GUI.OnActivate = function(self)
		self.fActivateTime = System:GetCurrAsyncTime();
		CoopMenuFill(self);
	end;
	GUI.OnUpdate = function(self)
		if ((self.fActivateTime) and (System:GetCurrAsyncTime() - self.fActivateTime > 0.125)) then
			self.fActivateTime = nil;
			UI:EnableSwitch(1); -- as the game's in-game menu: not the Esc that opened it
		end
		local t = System:GetCurrAsyncTime();
		if (not self.fFillTime or t - self.fFillTime > 0.5 or t < self.fFillTime) then CoopMenuFill(self); end
	end;
end

-- the players in the list's order: the host first, then by entity id
function CoopMenuPlayers()
	local t, k = {}, 0;
	for i, e in System:GetEntities() do
		if (e.classname == "Player" and not e.ai) then k = k + 1; t[k] = e; end
	end
	sort(t, function(a, b)
		local ha, hb = (COOP_PList[a.id] and COOP_PList[a.id].host) and 1 or 0, (COOP_PList[b.id] and COOP_PList[b.id].host) and 1 or 0;
		if (ha ~= hb) then return ha > hb; end
		return a.id < b.id;
	end);
	return t;
end

-- a joined player's own entity has no name in its game: the name it joined with
function CoopMenuName(e)
	local n = tostring(e:GetName() or "");
	if (n == "" and e == _localplayer) then n = tostring(getglobal("p_name") or ""); end
	return n;
end

function CoopMenuHealth(e)
	if (not e.cnt or not e.cnt.health) then return ""; end
	if (e.cnt.health <= 0) then return "dead"; end
	return max(1, floor(e.cnt.health * 100 / max(e.cnt.max_health or 255, 1) + 0.5)).."%"; -- alive: never 0%
end

-- the avatar's texture, or nil; asks the ASI for a missing one (it answers CoopVoice_Avatar)
function CoopMenuAvatar(e)
	local P = COOP_PList[e.id];
	local key = P and P.key;
	local av;
	if (e == _localplayer) then av = COOP_VoiceAvatar and COOP_VoiceAvatar[""]; end
	if (not av and key) then av = COOP_VoiceAvatar and COOP_VoiceAvatar[CoopDecHex(key)]; end
	if (av and av ~= "" and CoopVoiceTexture) then
		local tex = CoopVoiceTexture(av);
		if (tex) then return tex; end
	end
	local t = System:GetCurrAsyncTime();
	local at = COOP_MenuAvatarAsked[key or ""];
	if (key and not COOP_MenuAvatarSent and (not at or t - at > COOP_MENU_AVATAR_RETRY or t < at)) then
		COOP_MenuAvatarAsked[key], COOP_MenuAvatarSent = t, 1;
		System:ExecuteCommand("coop_voice avatar "..key);
	end
end

function CoopMenuFill(GUI)
	GUI.fFillTime = System:GetCurrAsyncTime();
	local host = Game:IsServer();
	local list = CoopMenuPlayers();
	COOP_MenuAvatarSent = nil;
	COOP_MenuRowIds = {}; -- the screen is the engine's object, not this table: kept here
	for i = 1, COOP_MENU_ROWS do
		local e = list[i];
		local avatar, name = GUI["Avatar"..i], GUI["Name"..i];
		if (e) then
			COOP_MenuRowIds[i] = e.id;
			local tex = CoopMenuAvatar(e);
			if (tex) then avatar:SetColor("255 255 255 255"); avatar:SetTexture(tex);
			else avatar:SetColor("0 0 0 64"); avatar:SetTexture(nil); end
			UI:ShowWidget(avatar);
			name:SetText(CoopMenuName(e));
			GUI["Host"..i]:SetText((COOP_PList[e.id] and COOP_PList[e.id].host) and "Host" or "");
			GUI["Health"..i]:SetText(CoopMenuHealth(e));
		else
			UI:HideWidget(avatar);
			name:SetText("");
			GUI["Host"..i]:SetText("");
			GUI["Health"..i]:SetText("");
		end
		if (GUI["Kick"..i]) then
			if (host and e and e ~= _localplayer) then UI:ShowWidget(GUI["Kick"..i]); UI:ShowWidget(GUI["Ban"..i]);
			else UI:HideWidget(GUI["Kick"..i]); UI:HideWidget(GUI["Ban"..i]); end
		end
	end
end

-- a kick or ban icon: asks first, then "ADMIN kick|ban <entity id>" to the server
function CoopMenuAsk(kind, row)
	local id = COOP_MenuRowIds and COOP_MenuRowIds[row];
	local e = id and System:GetEntity(id);
	if (not e) then return; end
	local name = CoopMenuName(e);
	COOP_MenuAdmin = {kind = kind, id = id, name = name};
	if (kind == "ban") then
		UI.YesNoBox("Ban", "Ban "..name.." from this game?\nThey will not be able to join again.", CoopMenuAdminYes);
	else
		UI.YesNoBox("Kick", "Kick "..name.." from this game?", CoopMenuAdminYes);
	end
end
function CoopMenuAdminYes()
	local a = COOP_MenuAdmin;
	COOP_MenuAdmin = nil;
	if (not a or not Client) then return; end
	-- the box was open a while: still the same player?
	local e = System:GetEntity(a.id);
	if (not e or CoopMenuName(e) ~= a.name) then
		if (Hud and Hud.AddMessage) then Hud:AddMessage(a.name.." is no longer here."); end
		return;
	end
	Client:SendCommand("ADMIN "..a.kind.." "..a.id);
end

function CoopMenuSave()
	if (CoopQuickSave) then CoopQuickSave(); end -- as F6
	GotoPage("$Return$");
end
function CoopMenuEndGame()
	UI.YesNoBox("End game", "End the game?\nEveryone will be disconnected.", DisconnectOnYes);
end
function CoopMenuLeave()
	UI.YesNoBox("Leave game", "Leave this game?", DisconnectOnYes);
end

UI.PageCoopInGameHost = { GUI = {} }
CoopMenuRows(UI.PageCoopInGameHost.GUI, 1);
AddUISideMenu(UI.PageCoopInGameHost.GUI,
{
	{ "Return", Localize("ReturnToGame"), "$Return$", },
	{ "-", "-", "-", },
	{ "CoopVote", "Call a vote", "CoopVote", },
	{ "CoopSave", "Save game", CoopMenuSave, },
	{ "CoopLoad", "Load game", "CoopLoadGame", },
	{ "Coop", "Co-op", "Coop", },
	{ "Options", Localize("Options"), "Options", },
	{ "-", "-", "-", },
	{ "EndGame", "End game", CoopMenuEndGame, },
	{ "Quit", Localize("Quit"), UI.PageMainScreen.ShowConfirmation, },
});
UI:CreateScreenFromTable("CoopInGameHost", UI.PageCoopInGameHost.GUI);

UI.PageCoopInGame = { GUI = {} }
CoopMenuRows(UI.PageCoopInGame.GUI);
AddUISideMenu(UI.PageCoopInGame.GUI,
{
	{ "Return", Localize("ReturnToGame"), "$Return$", },
	{ "-", "-", "-", },
	{ "CoopVote", "Call a vote", "CoopVote", },
	{ "Options", Localize("Options"), "Options", },
	{ "-", "-", "-", },
	{ "Leave", "Leave game", CoopMenuLeave, },
	{ "Quit", Localize("Quit"), UI.PageMainScreen.ShowConfirmation, },
});
UI:CreateScreenFromTable("CoopInGame", UI.PageCoopInGame.GUI);

-- Load game (the host): the last checkpoint (save_auto) and the quick save (F6, save_quick);
-- the chosen one, after a yes, for everyone (CoopLoad: the map loads again with every player).
COOP_MENU_SAVES = {{"auto", "Last checkpoint"}, {"quick", "Quick save"}}
UI.PageCoopLoadGame =
{
	Names = {}, -- list index -> save name
	GUI =
	{
		TitleText =
		{
			skin = UI.skins.Label,
			left = 200, top = 110, width = 300,
			halign = UIALIGN_LEFT,
			text = "Load game",
		},
		List =
		{
			skin = UI.skins.ListView,
			left = 200, top = 141,
			width = 580, height = 200,
			fontsize = 14,
			tabstop = 1,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			hscrollbar = { skin = UI.skins.HScrollBar, },
		},
		HelpText =
		{
			skin = UI.skins.Label,
			left = 210, top = 350, width = 560, height = 60,
			halign = UIALIGN_LEFT,
			text = "",
		},
		Load =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 2,
			text = "Load",
			OnCommand = function(Sender) UI.PageCoopLoadGame.Ask(); end,
		},
		OnActivate = function(Sender)
			Sender.List.OnCommand = Sender.Load.OnCommand; -- a double click loads too
			UI.PageCoopLoadGame.Fill();
		end,
	},

	-- what a save file holds about itself (COOP gamerules CoopSave: map, date)
	Info = function(name)
		local f = openfile(COOP_SAVE_PATH..name..".lua", "r");
		if (not f) then return; end
		closefile(f);
		COOP_LoadedSave = nil;
		call(dofile, {COOP_SAVE_PATH..name..".lua"}, "x", function(msg) System:LogAlways("coop: save "..tostring(msg)); end);
		local save = COOP_LoadedSave;
		COOP_LoadedSave = nil;
		if (type(save) ~= "table" or not save.map) then return; end
		return save;
	end,

	Fill = function()
		local P = UI.PageCoopLoadGame;
		local GUI = P.GUI;
		GUI.List:Clear();
		P.Names = {};
		local first;
		for i, s in COOP_MENU_SAVES do
			local save = P.Info(s[1]);
			if (save) then
				local text = s[2].." - "..CoopMapTitle(save.map);
				if (save.date) then text = text..", "..save.date; end
				local idx = GUI.List:AddItem(text);
				if (idx) then P.Names[idx] = s[1]; first = first or idx; end
			end
		end
		GUI.List:ClearSelection();
		if (first) then
			GUI.List:SelectIndex(first);
			GUI.HelpText:SetText("Everyone goes back to that point.");
		else
			GUI.HelpText:SetText("No saves yet: the game saves at checkpoints, F6 saves at once.");
		end
	end,

	Ask = function()
		local P = UI.PageCoopLoadGame;
		local idx = P.GUI.List:GetSelection(0);
		local name = idx and P.Names[idx];
		if (not name) then return; end
		COOP_MenuLoad = name;
		UI.YesNoBox("Load game", "Load this save?\nEveryone goes back to that point.", UI.PageCoopLoadGame.Yes);
	end,
	Yes = function()
		local name = COOP_MenuLoad;
		COOP_MenuLoad = nil;
		if (name) then
			CoopLoad(name);
			GotoPage("$Return$");
		end
	end,
}
AddUISideMenu(UI.PageCoopLoadGame.GUI,
{
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0 },
});
UI:CreateScreenFromTable("CoopLoadGame", UI.PageCoopLoadGame.GUI);
