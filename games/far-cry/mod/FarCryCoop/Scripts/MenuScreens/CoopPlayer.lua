-- FarCryCoop "Player settings" screen (docs/specs/in-game-menu.md, step 3d): the name (with Steam:
-- the Steam name, not editable; AvailableMods.lua CoopCleanName either way), the shirt
-- color and the 4 weapons of the loadout, as the launcher sets them. Saved to
-- Mods/FarCryCoop/prefs.lua, the file the launcher writes (COOP ClientStuff loads it at the map
-- start, MenuScreens/Coop.lua before a launch); the player model is not offered yet.

UI.PageCoopPlayer =
{
	-- MultiplayerUtils.ModelColor, 0..9
	Colors = {"Black", "White", "Blue", "Green", "Red", "Cyan", "Yellow", "Magenta", "Orange", "Grey"},
	-- COOP gamerules COOP_LOADOUT_WEAPONS, in the launcher's order
	Weapons = {"Machete", "Falcon", "MP5", "P90", "M4", "AG36", "OICW", "Shotgun", "SniperRifle", "M249", "RL"},
	DefaultWeapons = {"Falcon", "MP5", "M4", "Shotgun"},
	NONE = "-",

	GUI =
	{
		TitleText =
		{
			skin = UI.skins.Label,
			left = 200, top = 110,
			width = 300,
			halign = UIALIGN_LEFT,
			text = "Player settings",
		},

		Border =
		{
			skin = UI.skins.MenuBorder,
			left = 200, top = 141,
			width = 580, height = 262,
			zorder = -50,
		},

		NameText = { skin = UI.skins.Label, left = 210, top = 160, width = 180, text = "Name", },
		Name =
		{
			skin = UI.skins.EditBox,
			left = 400, top = 156,
			width = 200,
			tabstop = 1,
		},

		ColorText = { skin = UI.skins.Label, left = 210, top = 200, width = 180, text = "Shirt color", },
		ColorCombo =
		{
			skin = UI.skins.ComboBox,
			left = 400, top = 196,
			width = 200, height = 25,
			tabstop = 2,
			vscrollbar = { skin = UI.skins.VScrollBar, },
		},

		WeaponsText = { skin = UI.skins.Label, left = 210, top = 240, width = 180, text = "Loadout weapons", },
		Weapon1 = { skin = UI.skins.ComboBox, left = 400, top = 236, width = 180, height = 25, tabstop = 3, vscrollbar = { skin = UI.skins.VScrollBar, }, },
		Weapon2 = { skin = UI.skins.ComboBox, left = 590, top = 236, width = 180, height = 25, tabstop = 4, vscrollbar = { skin = UI.skins.VScrollBar, }, },
		Weapon3 = { skin = UI.skins.ComboBox, left = 400, top = 276, width = 180, height = 25, tabstop = 5, vscrollbar = { skin = UI.skins.VScrollBar, }, },
		Weapon4 = { skin = UI.skins.ComboBox, left = 590, top = 276, width = 180, height = 25, tabstop = 6, vscrollbar = { skin = UI.skins.VScrollBar, }, },

		HintText =
		{
			skin = UI.skins.Label,
			left = 210, top = 320,
			width = 560,
			halign = UIALIGN_LEFT,
			text = "Weapons: given when the host turns the loadout on. In a game: from the next map.",
		},

		Back =
		{
			skin = UI.skins.BottomMenuButton,
			left = 200,
			tabstop = 7,
			text = "Back",
			OnCommand = function(Sender)
				GotoPage("Coop");
			end,
		},

		Save =
		{
			skin = UI.skins.BottomMenuButton,
			left = 780 - 180,
			tabstop = 8,
			text = "Save",
			OnCommand = function(Sender)
				UI.PageCoopPlayer.Save();
				GotoPage("Coop");
			end,
		},

		OnActivate = function(Sender)
			UI.PageCoopPlayer.Fill();
		end,
	},

	Fill = function()
		local P, GUI = UI.PageCoopPlayer, UI.PageCoopPlayer.GUI;
		if (not COOP_Color) then Script:LoadScript("Mods/FarCryCoop/prefs.lua"); end
		CoopApplySteamName();
		GUI.Name:SetText(tostring(getglobal("p_name") or ""));
		-- with Steam the name is the Steam name (AvailableMods.lua CoopApplySteamName)
		if (COOP_SteamName) then UI:DisableWidget(GUI.Name); else UI:EnableWidget(GUI.Name); end
		GUI.ColorCombo:Clear();
		for i, c in P.Colors do GUI.ColorCombo:AddItem(c); end
		GUI.ColorCombo:SelectIndex((tonumber(COOP_Color) or 1) + 1);
		local have, s, i = {}, tostring(COOP_Weapons or ""), 1;
		while (1) do
			local a, b, w = strfind(s, "(%S+)", i);
			if (not a) then break; end
			tinsert(have, w);
			i = b + 1;
		end
		if (getn(have) == 0 and not COOP_Weapons) then have = P.DefaultWeapons; end
		for k = 1, 4 do
			local combo = GUI["Weapon"..k];
			combo:Clear();
			combo:AddItem(P.NONE);
			for i, w in P.Weapons do combo:AddItem(w); end
			combo:Select(have[k] or P.NONE);
		end
	end,

	Save = function()
		local P, GUI = UI.PageCoopPlayer, UI.PageCoopPlayer.GUI;
		-- with Steam the field cannot be typed in; without it: what the field says, cleaned
		local name = COOP_SteamName or CoopCleanName(GUI.Name:GetText());
		local color = (tonumber(GUI.ColorCombo:GetSelectionIndex()) or 2) - 1;
		if (color < 0 or color > 9) then color = 1; end
		local list, seen = {}, {};
		for k = 1, 4 do
			local w = GUI["Weapon"..k]:GetSelection();
			if (w and w ~= P.NONE and not seen[w]) then seen[w] = 1; tinsert(list, w); end
		end
		local weapons = "";
		for i = 1, getn(list) do
			if (i > 1) then weapons = weapons.." "; end
			weapons = weapons..list[i];
		end
		COOP_Color, COOP_Weapons = color, weapons;
		setglobal("p_name", name);
		if (Client) then Client:SetName(name); end -- as Options/Game.lua does
		local f = openfile("Mods/FarCryCoop/prefs.lua", "w");
		if (not f) then
			System:LogAlways("coop: player settings: cannot write Mods/FarCryCoop/prefs.lua");
			return;
		end
		write(f, format("COOP_Color=%d COOP_Weapons=\"%s\" setglobal(\"p_name\",\"%s\")\n", color, weapons, name));
		-- what the launcher wrote besides: the player key (its Steam ID: the saves keep each
		-- player's weapons under it) and the host's settings
		if (COOP_PlayerKey and strfind(tostring(COOP_PlayerKey), "^[%w_%.%-]+$")) then
			write(f, format("COOP_PlayerKey=\"%s\"\n", tostring(COOP_PlayerKey)));
		end
		if (tonumber(COOP_LoadoutMode)) then write(f, format("COOP_LoadoutMode=%d\n", tonumber(COOP_LoadoutMode))); end
		if (tonumber(COOP_Difficulty)) then write(f, format("COOP_Difficulty=%d\n", tonumber(COOP_Difficulty))); end
		if (tonumber(COOP_ExitTime)) then write(f, format("COOP_ExitTime=%d\n", tonumber(COOP_ExitTime))); end
		closefile(f);
		System:LogAlways("coop: player settings saved: "..name.." color "..color.." weapons "..weapons);
	end,
}

UI:CreateScreenFromTable("CoopPlayer", UI.PageCoopPlayer.GUI);
