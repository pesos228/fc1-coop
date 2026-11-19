-- "Call a vote" in the in-game menu (owner, 2026-11-19: kick, ban, map change by vote as in TF2;
-- COOP gamerules CoopCallVote counts them, COOP ClientStuff CoopDrawVote shows them). The kind,
-- then the player or the map, then "Call vote": the server gets "CALLVOTE kick|ban <entity id>"
-- or "CALLVOTE map <map>". The keys that answer a vote (F3 yes, F4 no; F1 is the game's view
-- change) are set in Options > Controls, in the Co-op rows (MenuScreens/CoopVoice.lua adds the
-- section), and kept in Mods/FarCryCoop/votekeys.lua.

COOP_VoteYesKey = COOP_VoteYesKey or "f3"
COOP_VoteNoKey = COOP_VoteNoKey or "f4"
function CoopVoteKeysLoad()
	local f = openfile("Mods/FarCryCoop/votekeys.lua", "r");
	if (f) then closefile(f); dofile("Mods/FarCryCoop/votekeys.lua"); end
end
CoopVoteKeysLoad();
function CoopVoteKeysSave()
	local f = openfile("Mods/FarCryCoop/votekeys.lua", "w");
	if (not f) then System:LogAlways("coop: cannot write Mods/FarCryCoop/votekeys.lua"); return; end
	write(f, format("COOP_VoteYesKey=%q\nCOOP_VoteNoKey=%q\n", tostring(COOP_VoteYesKey), tostring(COOP_VoteNoKey)));
	closefile(f);
end
-- a key chosen for "yes" or "no": the old one is free again
function CoopVoteSetKey(which, key)
	key = strlower(tostring(key));
	local old;
	if (which == "yes") then
		old = COOP_VoteYesKey;
		if (key == strlower(tostring(COOP_VoteNoKey))) then COOP_VoteNoKey = old; end -- swapped
		COOP_VoteYesKey = key;
	else
		old = COOP_VoteNoKey;
		if (key == strlower(tostring(COOP_VoteYesKey))) then COOP_VoteYesKey = old; end
		COOP_VoteNoKey = key;
	end
	if (Input) then
		if (old and old ~= key) then Input:BindCommandToKey("", strlower(tostring(old)), 1); end
		Input:BindCommandToKey("#CoopVoteYes()", strlower(tostring(COOP_VoteYesKey)), 1);
		Input:BindCommandToKey("#CoopVoteNo()", strlower(tostring(COOP_VoteNoKey)), 1);
	end
	CoopVoteKeysSave();
end

COOP_VOTE_ACTIONS = {
	{desc = "Vote yes", configurable = 1, coop_vote = "yes"},
	{desc = "Vote no", configurable = 1, coop_vote = "no"},
}

UI.PageCoopVote =
{
	Kinds = {"Kick a player", "Ban a player", "Change the map"},
	KindCmd = {"kick", "ban", "map"},
	Targets = {}, -- combo index -> entity id or map name

	GUI =
	{
		TitleText =
		{
			skin = UI.skins.Label,
			left = 200, top = 110,
			width = 300,
			halign = UIALIGN_LEFT,
			text = "Call a vote",
		},
		Border =
		{
			skin = UI.skins.MenuBorder,
			left = 200, top = 141,
			width = 580, height = 182,
			zorder = -50,
		},
		KindText = { skin = UI.skins.Label, left = 210, top = 160, width = 180, text = "Vote", },
		KindCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 156,
			width = 200, height = 25,
			tabstop = 1,
			vscrollbar = { skin = UI.skins.VScrollBar, },
			OnChanged = function(Sender)
				UI.PageCoopVote.FillTargets();
			end,
		},
		TargetText = { skin = UI.skins.Label, left = 210, top = 200, width = 180, text = "Player or map", },
		TargetCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 196,
			width = 200, height = 25,
			tabstop = 2,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},
		HelpText =
		{
			skin = UI.skins.Label,
			left = 210, top = 240,
			width = 560, height = 60,
			halign = UIALIGN_LEFT,
			text = "",
		},
		Call =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 3,
			text = "Call vote",
			OnCommand = function(Sender)
				if (UI.PageCoopVote.Call()) then GotoPage("$Return$"); end
			end,
		},
		OnActivate = function(Sender)
			UI.PageCoopVote.Fill();
		end,
	},

	Fill = function()
		local GUI = UI.PageCoopVote.GUI;
		GUI.KindCombo:Clear();
		for i, k in UI.PageCoopVote.Kinds do GUI.KindCombo:AddItem(k); end
		GUI.KindCombo:SelectIndex(1);
		GUI.HelpText:SetText(format("Everyone answers with %s (yes) or %s (no); the keys are in Options > Controls.",
			strupper(tostring(COOP_VoteYesKey)), strupper(tostring(COOP_VoteNoKey))));
		UI.PageCoopVote.FillTargets();
	end,

	FillTargets = function()
		local P = UI.PageCoopVote;
		local GUI = P.GUI;
		GUI.TargetCombo:Clear();
		P.Targets = {};
		local kind = P.KindCmd[tonumber(GUI.KindCombo:GetSelectionIndex()) or 1] or "kick";
		if (kind == "map") then
			for i, m in UI.PageCoop.Maps do
				local n = GUI.TargetCombo:AddItem(m);
				if (n) then P.Targets[n] = m; end
			end
		elseif (CoopMonPlayers) then
			for i, e in CoopMonPlayers() do
				if (e ~= _localplayer and not e.ai and e:GetName() and e:GetName() ~= "") then
					local n = GUI.TargetCombo:AddItem(e:GetName());
					if (n) then P.Targets[n] = e.id; end
				end
			end
		end
		GUI.TargetCombo:SelectIndex(1);
	end,

	-- 1: sent
	Call = function()
		local P = UI.PageCoopVote;
		local kind = P.KindCmd[tonumber(P.GUI.KindCombo:GetSelectionIndex()) or 0];
		local target = P.Targets[tonumber(P.GUI.TargetCombo:GetSelectionIndex()) or 0];
		if (not kind or not target or not Client) then return; end
		Client:SendCommand(format("CALLVOTE %s %s", kind, tostring(target)));
		return 1;
	end,
}

AddUISideMenu(UI.PageCoopVote.GUI,
{
	{ "Return", Localize("ReturnToGame"), "$Return$", },
	{ "MainMenu", Localize("MainMenu"), "$MainScreen$", 0},
});

UI:CreateScreenFromTable("CoopVote", UI.PageCoopVote.GUI);

-- the game's "press a key" screen for a vote key (as CoopBindVoice for the voice key)
UI.PageCoopBindVote =
{
	GUI =
	{
		darkeningpane = { classname = "static", rect = "0 0 800 600", color = "0 0 0 128", zorder = 50, },
		commandtext =
		{
			classname = "static",
			left = 200, top = 140,
			width = 580, height = 259,
			color = "0 0 0 128",
			zorder = 55,
			halign = UIALIGN_CENTER,
			fontsize = 16,
		},
		OnActivate = function(Sender)
			local a = UI.PageCoopBindVote.Action or COOP_VOTE_ACTIONS[1];
			UI.PageCoopBindVote.GUI.commandtext:SetText(Localize("PressAKeyToBind").." "..a.desc);
		end,
		OnUpdate = function(self)
			local key = Input:GetXKeyPressedName();
			if (not key) then return; end
			key = strlower(tostring(key));
			if (key == "esc" or key == "pause" or key == strlower(tostring(System:GetConsoleKeyName()))) then return; end
			local a = UI.PageCoopBindVote.Action or COOP_VOTE_ACTIONS[1];
			CoopVoteSetKey(a.coop_vote, key);
			UI.PageOptionsControl:FillBindList();
			UI:DeactivateScreen(self);
		end,
	},
}
UI:CreateScreenFromTable("CoopBindVote", UI.PageCoopBindVote.GUI);
