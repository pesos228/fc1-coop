-- FarCryCoop "Find game" screen (docs/specs/in-game-menu.md, step 3c), a server browser in the
-- manner of Source games: tabs on top, the list, filters under it. Laid out with the game's own
-- widgets (MultiPlayer/LANServerList.lua, Multiplayer.lua).
--   Internet: public games of this mod from Steam: "coop_steam find" (steam.c).
--   Friends: games of Steam friends, friends-only ones too: "coop_steam friends".
--     The ASI answers both with CoopFind_List(<count>, <kind>) and a CoopFind_Row(...) per game
--     (steam.c emitRows); Join enters the game's lobby (coop_steam joinlobby <n>), the ASI connects
--     once its server is up, and the game asks for the password itself (Multiplayer/Connecting.lua).
--   LAN: the engine's own LAN search (Game:RefreshServerList), games of this mod only; Join
--     connects by address (coop_connect, as Join by IP).
-- Filters (map, difficulty, not full, no password) only hide rows: no new search.

UI.PageCoopFind =
{
	Tab = "internet",
	Rows = {},      -- the tab's games, as found
	Games = {},     -- list item index -> its row
	Timeout = 15,   -- s: Steam's answer usually takes one or two
	LANWait = 1.7,  -- s: LAN answers come in this long (LANServerList.lua)

	GUI =
	{
		Internet =
		{
			skin = UI.skins.TopMenuButton,
			left = 200, width = 150,
			tabstop = 1,
			text = "Internet",
			greyedcolor = UI.szTabAdditiveColor,
			greyedblend = UIBLEND_ADDITIVE,
			OnCommand = function(Sender)
				UI.PageCoopFind.SetTab("internet");
			end,
		},

		Friends =
		{
			skin = UI.skins.TopMenuButton,
			left = 350, width = 150,
			tabstop = 2,
			text = "Friends",
			greyedcolor = UI.szTabAdditiveColor,
			greyedblend = UIBLEND_ADDITIVE,
			OnCommand = function(Sender)
				UI.PageCoopFind.SetTab("friends");
			end,
		},

		LAN =
		{
			skin = UI.skins.TopMenuButton,
			left = 500, width = 150,
			tabstop = 3,
			text = Localize("LAN"),
			greyedcolor = UI.szTabAdditiveColor,
			greyedblend = UIBLEND_ADDITIVE,
			OnCommand = function(Sender)
				UI.PageCoopFind.SetTab("lan");
			end,
		},

		GameList =
		{
			skin = UI.skins.ListView,
			fontsize = 12,
			left = 200, top = 140.5,
			width = 580, height = 205,
			tabstop = 4,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			hscrollbar = { skin = UI.skins.HScrollBar, },

			OnInit = function(Sender)
				Sender:ClearColumns();
				Sender:AddColumn("@Name", 220, UIALIGN_LEFT, UI.szListViewOddColor, "0 0 0 0");
				Sender:AddColumn("@PWD", 20, UIALIGN_CENTER, UI.szListViewEvenColor, "0 0 0 0", nil, nil, 0, 0, 1);
				Sender:AddColumn("@Players", 55, UIALIGN_CENTER, UI.szListViewOddColor, "0 0 0 0", nil, nil, 1);
				Sender:AddColumn("@Map", 95, UIALIGN_CENTER, UI.szListViewEvenColor, "0 0 0 64");
				Sender:AddColumn("Difficulty", 100, UIALIGN_CENTER, UI.szListViewOddColor, "0 0 0 0");
				Sender:AddColumn("@Ping", 50, UIALIGN_CENTER, UI.szListViewEvenColor, "0 0 0 64", nil, nil, 1);
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
			width = 578, height = 203,
			flags = UIFLAG_ENABLED,
			zorder = 150,
			color = "0 0 0 196",
			halign = UIALIGN_CENTER,
			valign = UIALIGN_MIDDLE,
			text = "",
		},

		FilterBorder =
		{
			skin = UI.skins.MenuBorder,
			left = 200, top = 352,
			width = 580, height = 98,
			zorder = -50,
		},

		FilterText =
		{
			skin = UI.skins.Label,
			left = 210, top = 357,
			width = 200,
			halign = UIALIGN_LEFT,
			text = "Filters",
		},

		MapText =
		{
			skin = UI.skins.Label,
			left = 200, top = 384,
			width = 80,
			text = "Map",
		},

		MapFilter =
		{
			skin = UI.skins.ComboBox,
			left = 290, top = 380,
			width = 170, height = 25,
			tabstop = 5,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			OnChanged = function(Sender)
				UI.PageCoopFind.Show();
			end,
		},

		DifficultyText =
		{
			skin = UI.skins.Label,
			left = 470, top = 384,
			width = 110,
			text = "Difficulty",
		},

		DifficultyFilter =
		{
			skin = UI.skins.ComboBox,
			left = 590, top = 380,
			width = 170, height = 25,
			tabstop = 6,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			OnChanged = function(Sender)
				UI.PageCoopFind.Show();
			end,
		},

		NotFullText =
		{
			skin = UI.skins.Label,
			left = 200, top = 418,
			width = 80,
			text = "Not full",
		},

		NotFull =
		{
			skin = UI.skins.CheckBox,
			left = 290, top = 418,
			tabstop = 7,
			OnChanged = function(Sender)
				UI.PageCoopFind.Show();
			end,
		},

		NoPasswordText =
		{
			skin = UI.skins.Label,
			left = 470, top = 418,
			width = 110,
			text = "No password",
		},

		NoPassword =
		{
			skin = UI.skins.CheckBox,
			left = 590, top = 418,
			tabstop = 8,
			OnChanged = function(Sender)
				UI.PageCoopFind.Show();
			end,
		},

		Refresh =
		{
			skin = UI.skins.BottomMenuButton,
			left = 200,
			tabstop = 9,
			text = Localize("Refresh"),
			OnCommand = function(Sender)
				UI.PageCoopFind.Refresh();
			end,
		},

		Join =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 10,
			text = Localize("Join"),
			OnCommand = function(Sender)
				UI.PageCoopFind.Join();
			end,
		},

		-- also back from a join that failed (Connecting.lua): SetTab → Refresh → CancelJoin clears it
		OnActivate = function(Sender)
			UI.PageCoopFind.Filters();
			UI.PageCoopFind.SetTab(UI.PageCoopFind.Tab);
		end,

		-- a join goes on: Game:Disconnect in Join takes this screen down itself; the ASI gives
		-- up on a server that does not come up (steam.c lobbyWait)
		OnDeactivate = function(Sender)
			UI.PageCoopFind.Waiting = nil;
			UI.PageCoopFind.LANSince = nil;
		end,

		OnUpdate = function(Sender)
			local Page = UI.PageCoopFind;
			if (Page.LANSince and Page.LANSince + Page.LANWait < _time) then
				Page.LANSince = nil;
				Page.Waiting = nil;
				Page.LANRows();
			end
			if (Page.Waiting and Page.Waiting + Page.Timeout < _time) then
				Page.Waiting = nil;
				Page.Say("Steam did not answer. Try Refresh.");
			end
		end,
	},

	-- the filter combos, once: "Any", then the maps and difficulties of the Co-op screen
	Filters = function()
		local GUI = UI.PageCoopFind.GUI;
		if (UI.PageCoopFind.FiltersMade) then
			return;
		end
		UI.PageCoopFind.FiltersMade = 1;
		GUI.MapFilter:Clear();
		GUI.MapFilter:AddItem("Any");
		for i, m in UI.PageCoop.Maps do
			GUI.MapFilter:AddItem(m);
		end
		GUI.MapFilter:SelectIndex(1);
		GUI.DifficultyFilter:Clear();
		GUI.DifficultyFilter:AddItem("Any");
		for i, d in UI.PageCoop.Difficulty do
			GUI.DifficultyFilter:AddItem(d);
		end
		GUI.DifficultyFilter:SelectIndex(1);
	end,

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

	-- the chosen tab greyed, as the game's LAN / Internet tabs (Multiplayer.lua)
	SetTab = function(tab)
		local Page = UI.PageCoopFind;
		local GUI = Page.GUI;
		Page.Tab = tab;
		for t, w in {internet = GUI.Internet, friends = GUI.Friends, lan = GUI.LAN} do
			if (t == tab) then UI:DisableWidget(w); else UI:EnableWidget(w); end
			w.skin.OnLostFocus(w);
		end
		Page.Refresh();
	end,

	-- the ASI waits in the game's lobby for its server (steam.c lobbyWait): Refresh stops it, so it
	-- does not connect later to the game the player gave up on
	CancelJoin = function()
		local Page = UI.PageCoopFind;
		if (Page.Joining and not Page.JoiningIP) then
			System:LogAlways("coop: find game: join called off");
			System:ExecuteCommand("coop_steam leave");
		end
		Page.Joining = nil;
		Page.JoiningIP = nil;
	end,

	Refresh = function()
		local Page = UI.PageCoopFind;
		Page.CancelJoin();
		Page.Rows = {};
		Page.Accept = nil;
		Page.LANSince = nil; -- a LAN search still on: its rows are not for this tab
		Page.Waiting = _time;
		Page.Show(Localize("RefreshingServerList"));
		if (Page.Tab == "lan") then
			Page.LANSince = _time;
			Game:RefreshServerList();
		elseif (Page.Tab == "friends") then
			System:ExecuteCommand("coop_steam friends");
		else
			System:ExecuteCommand("coop_steam find");
		end
	end,

	-- the engine's LAN list: this mod's games only (the game type COOP, or this mod)
	LANRows = function()
		local Page = UI.PageCoopFind;
		local n = 0;
		if (Page.Tab ~= "lan") then
			return;
		end
		for i, s in (Game:GetServerList() or {}) do
			if (s.InternetServer == 0 and (strupper(tostring(s.GameType or "")) == "COOP" or strlower(tostring(s.Mod or "")) == "farcrycoop")) then
				local map = tostring(s.Map or "");
				n = n + 1;
				local name = tostring(s.Name or "");
				if (name == "") then name = "Co-op game"; end
				Page.Rows[n] = {Name = name, Map = strupper(strsub(map, 1, 1))..strlower(strsub(map, 2)),
					Password = (s.Password and s.Password ~= 0) and 1 or 0, Players = tonumber(s.Players) or 0,
					Limit = tonumber(s.MaxPlayers) or 0, Up = 1, Ping = tonumber(s.Ping), IP = s.IP};
				System:LogAlways(format("coop: find game: %s | %s | %d/%d | %s | pw %d", Page.Rows[n].Name, Page.Rows[n].Map,
					Page.Rows[n].Players, Page.Rows[n].Limit, tostring(s.IP), Page.Rows[n].Password));
			end
		end
		System:LogAlways("coop: find game: "..n.." game(s) (lan)");
		Page.Show(n == 0 and "No co-op games on the local network.\nThe host can give you the address for Join by IP." or nil);
	end,

	-- what passes the filters, into the list; text: the box to show over it (nil: none, or "no game
	-- matches" when the filters hide everything)
	Show = function(text)
		local Page = UI.PageCoopFind;
		local GUI = Page.GUI;
		local map = GUI.MapFilter:GetSelectionIndex();
		local diff = GUI.DifficultyFilter:GetSelectionIndex();
		map = map and map > 1 and UI.PageCoop.Maps[map - 1];
		diff = diff and diff > 1 and diff - 2;
		local notFull = GUI.NotFull:GetChecked();
		local noPassword = GUI.NoPassword:GetChecked();
		GUI.GameList:Clear();
		Page.Games = {};
		local shown, total = 0, 0;
		for i = 1, getn(Page.Rows) do -- by index: tinsert keeps a count in Rows.n
			local r = Page.Rows[i];
			total = total + 1;
			if ((not map or r.Map == map) and (not diff or r.Diff == diff) and
			    (not notFull or r.Limit == 0 or r.Players < r.Limit) and (not noPassword or r.Password ~= 1)) then
				local item = GUI.GameList:AddItem(r.Name, "", r.Players.."/"..r.Limit, (r.Up == 1) and r.Map or r.Map.." (starting)",
					r.Diff and UI.PageCoop.Difficulty[r.Diff + 1] or "", r.Ping and tostring(r.Ping) or "");
				if (r.Password == 1) then
					GUI.GameList:SetItemImage(9, item, 1); -- ServerTypeIcon 9: the lock (column 1)
				end
				Page.Games[item] = r;
				shown = shown + 1;
			end
		end
		Page.Shown = shown;
		if (text) then
			Page.Say(text);
		elseif (total > 0 and shown == 0) then
			Page.Say("No game matches the filters.");
		else
			Page.Say(nil);
		end
		Page.Buttons();
	end,

	Join = function()
		local Page = UI.PageCoopFind;
		local item = Page.GUI.GameList:GetSelection(0);
		local game = item and Page.Games[item];
		if (not game or Page.Joining) then
			return;
		end
		System:LogAlways("coop: find game: joining "..game.Name);
		Page.Say("Joining "..game.Name.."...");
		Game:Disconnect(); -- as the game's own server lists do before they join
		Page.Joining = 1; -- no second Join (a double click) until this one is over or called off
		Page.Buttons();
		if (game.IP) then
			Page.JoiningIP = 1; -- the game's own Connecting screen takes it from here
			System:ExecuteCommand("coop_connect "..game.IP);
		else
			System:ExecuteCommand("coop_steam joinlobby "..game.N);
		end
	end,
}

-- the ASI's answer to "coop_steam find" / "friends": count games follow (-1: no Steam, or it
-- failed); kind "internet" or "friends" (nil when Steam is off), so an answer meant for another
-- tab is not shown in this one
function CoopFind_List(count, kind)
	local Page = UI.PageCoopFind;
	if (Page.Tab == "lan" or (kind and kind ~= Page.Tab)) then
		Page.Accept = nil;
		return;
	end
	Page.Accept = 1;
	Page.Waiting = nil;
	Page.Rows = {};
	System:LogAlways("coop: find game: "..count.." game(s) ("..tostring(kind or Page.Tab)..")");
	if (count < 0) then
		Page.Show("Steam is off: Internet and Friends games are found through Steam.\nStart Far Cry from Steam, or use LAN or Join by IP.");
	elseif (count == 0) then
		Page.Show(Page.Tab == "friends" and "None of your Steam friends hosts a co-op game now." or
			"No co-op games found. Try Refresh, or create one in Co-op.");
	else
		Page.Show();
	end
end

-- one game of the list: n for joinlobby, the lobby's data (steam.c luaRow) and its player limit
function CoopFind_Row(n, name, map, diff, pw, players, limit, up)
	local Page = UI.PageCoopFind;
	if (not Page.Accept) then
		return;
	end
	if (name == "") then name = "Co-op game"; end
	map = strupper(strsub(map, 1, 1))..strlower(strsub(map, 2)); -- as the filter's names: a host may send "carrier"
	tinsert(Page.Rows, {N = n, Name = name, Map = map, Diff = UI.PageCoop.Difficulty[diff + 1] and diff, Password = pw,
		Players = players, Limit = limit, Up = up});
	Page.Show();
	System:LogAlways(format("coop: find game: %s | %s | %d/%d | %s | pw %d", name, map, players, limit,
		UI.PageCoop.Difficulty[diff + 1] or "", pw));
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
