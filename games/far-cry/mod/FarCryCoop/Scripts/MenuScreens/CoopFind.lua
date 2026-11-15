-- FarCryCoop "Find game" screen (docs/specs/in-game-menu.md, step 3c): the co-op games Steam lists
-- (lobbies of this mod: lobby data fc1coop), laid out like the game's own server lists
-- (MultiPlayer/LANServerList.lua). "Refresh" asks the ASI (coop_steam find); it answers with
-- CoopFind_List(<count>) and a CoopFind_Row(...) per game (steam.c luaRow). "Join" enters the
-- game's lobby (coop_steam joinlobby <n>); the ASI connects once its server is up, and the game
-- asks for the password itself (Multiplayer/Connecting.lua).

UI.PageCoopFind =
{
	Games = {},     -- list item index -> the game's row
	Timeout = 15,   -- s: Steam's answer usually takes one or two

	GUI =
	{
		TitleText =
		{
			skin = UI.skins.Label,
			left = 200, top = 110,
			width = 300,
			halign = UIALIGN_LEFT,
			text = "Find a co-op game",
		},

		GameList =
		{
			skin = UI.skins.ListView,
			fontsize = 12,
			left = 200, top = 140.5,
			width = 580, height = 280,
			tabstop = 1,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			hscrollbar = { skin = UI.skins.HScrollBar, },

			OnInit = function(Sender)
				Sender:ClearColumns();
				Sender:AddColumn("@Name", 250, UIALIGN_LEFT, UI.szListViewOddColor, "0 0 0 0");
				Sender:AddColumn("@PWD", 20, UIALIGN_CENTER, UI.szListViewEvenColor, "0 0 0 0", nil, nil, 0, 0, 1);
				Sender:AddColumn("@Players", 60, UIALIGN_CENTER, UI.szListViewOddColor, "0 0 0 0", nil, nil, 1);
				Sender:AddColumn("@Map", 110, UIALIGN_CENTER, UI.szListViewEvenColor, "0 0 0 64");
				Sender:AddColumn("Difficulty", 110, UIALIGN_CENTER, UI.szListViewOddColor, "0 0 0 0");
				Sender:AddImageList(UI.skins.ServerTypeIcon);
			end,

			OnChanged = function(Sender)
				UI.PageCoopFind.Buttons();
			end,

			OnCommand = function(Sender) -- a double click
				UI.PageCoopFind.Join();
			end,
		},

		Status =
		{
			classname = "static",
			left = 201, top = 141,
			width = 578, height = 278,
			flags = UIFLAG_ENABLED,
			zorder = 150,
			color = "0 0 0 196",
			halign = UIALIGN_CENTER,
			valign = UIALIGN_MIDDLE,
			text = "",
		},

		Refresh =
		{
			skin = UI.skins.BottomMenuButton,
			left = 200,
			tabstop = 2,
			text = Localize("Refresh"),
			OnCommand = function(Sender)
				UI.PageCoopFind.Refresh();
			end,
		},

		Join =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 3,
			text = Localize("Join"),
			OnCommand = function(Sender)
				UI.PageCoopFind.Join();
			end,
		},

		OnActivate = function(Sender)
			UI.PageCoopFind.Refresh();
		end,

		OnDeactivate = function(Sender)
			-- a join goes on: Game:Disconnect in Join takes this screen down itself; the ASI gives
			-- up on a server that does not come up (steam.c lobbyWait)
			UI.PageCoopFind.Waiting = nil;
		end,

		OnUpdate = function(Sender)
			local Page = UI.PageCoopFind;
			if (Page.Waiting and Page.Waiting + Page.Timeout < _time) then
				Page.Waiting = nil;
				Page.Say("Steam did not answer. Try Refresh.");
			end
		end,
	},

	Say = function(text) -- the box over the list; nil hides it
		local GUI = UI.PageCoopFind.GUI;
		if (text) then
			GUI.Status:SetText(text);
			UI:ShowWidget(GUI.Status);
		else
			UI:HideWidget(GUI.Status);
		end
	end,

	Buttons = function()
		local GUI = UI.PageCoopFind.GUI;
		if (GUI.GameList:GetSelectionCount() > 0 and not UI.PageCoopFind.Joining) then
			UI:EnableWidget(GUI.Join);
		else
			UI:DisableWidget(GUI.Join);
		end
	end,

	-- the ASI waits in the game's lobby for its server (steam.c lobbyWait): Refresh stops it, so it
	-- does not connect later to the game the player gave up on
	CancelJoin = function()
		if (UI.PageCoopFind.Joining) then
			UI.PageCoopFind.Joining = nil;
			System:LogAlways("coop: find game: join called off");
			System:ExecuteCommand("coop_steam leave");
		end
	end,

	Clear = function()
		local Page = UI.PageCoopFind;
		Page.GUI.GameList:Clear();
		Page.Games = {};
		Page.Buttons();
	end,

	Refresh = function()
		local Page = UI.PageCoopFind;
		Page.CancelJoin();
		Page.Clear();
		Page.Expected = 0;
		Page.Waiting = _time;
		Page.Buttons();
		Page.Say(Localize("RefreshingServerList"));
		System:ExecuteCommand("coop_steam find");
	end,

	Join = function()
		local Page = UI.PageCoopFind;
		local item = Page.GUI.GameList:GetSelection(0);
		local game = item and Page.Games[item];
		if (not game or Page.Joining) then
			return;
		end
		Page.Joining = 1;
		Page.Buttons();
		Page.Say("Joining "..game.Name.."...");
		System:LogAlways("coop: find game: joining "..game.Name);
		Game:Disconnect(); -- as the game's own server lists do before they join
		System:ExecuteCommand("coop_steam joinlobby "..game.N);
	end,
}

-- the ASI's answer to "coop_steam find": count games follow (-1: no Steam, or it failed)
function CoopFind_List(count)
	local Page = UI.PageCoopFind;
	Page.Waiting = nil;
	Page.Expected = count;
	Page.Clear(); -- the rows' numbers are of this list now (coop_steam joinlobby <n>)
	if (count < 0) then
		Page.Say("Steam is off: games are found through Steam.\nStart Far Cry from Steam, or use Join by IP in Co-op.");
	elseif (count == 0) then
		Page.Say("No co-op games found. Try Refresh, or create one in Co-op.");
	else
		Page.Say(nil);
	end
	System:LogAlways("coop: find game: "..count.." game(s)");
end

-- one game of the list: n for joinlobby, the lobby's data (steam.c luaRow) and its player limit
function CoopFind_Row(n, name, map, diff, pw, players, limit, up)
	local Page = UI.PageCoopFind;
	local difficulty = UI.PageCoop.Difficulty[diff + 1] or "";
	if (name == "") then name = "Co-op game"; end
	if (up ~= 1) then map = map.." (starting)"; end
	local item = Page.GUI.GameList:AddItem(name, "", players.."/"..limit, map, difficulty);
	if (pw == 1) then
		Page.GUI.GameList:SetItemImage(9, item, 1); -- ServerTypeIcon 9: the lock (column 1)
	end
	Page.Games[item] = {N = n, Name = name, Map = map, Password = pw, Players = players, Limit = limit, Up = up};
	Page.Buttons();
	System:LogAlways(format("coop: find game: %s | %s | %d/%d | %s | pw %d", name, map, players, limit, difficulty, pw));
end

-- the lobby could not be entered (gone, full, or this game still runs a server). Also for a Steam
-- invite refused while hosting: no box then, the player did not ask from this screen.
function CoopFind_JoinFailed()
	local Page = UI.PageCoopFind;
	System:LogAlways("coop: find game: could not join");
	if (Page.Joining) then
		Page.Joining = nil;
		Page.Say(nil);
		Page.Buttons();
		UI.MessageBox("Find game", "Could not join this game: it is over, or full. Try Refresh.");
	end
end

-- the ASI connects to the game's server now (steam.c join): the join from this screen is done
function CoopFind_Connecting()
	UI.PageCoopFind.Joining = nil;
end

AddUISideMenu(UI.PageCoopFind.GUI,
{
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0},
	{ "Coop", "Co-op", "Coop", },
});

UI:CreateScreenFromTable("CoopFind", UI.PageCoopFind.GUI);
