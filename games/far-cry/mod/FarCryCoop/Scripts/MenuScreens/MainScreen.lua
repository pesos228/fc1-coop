-- FarCryCoop main menu: the game's own, with "Co-op" in place of "Campaign" and "Multiplayer"
-- (owner, docs/specs/in-game-menu.md: no single player in the mod's menu; one player is a co-op
-- game for one). The co-op screens live in MenuScreens/Coop.lua, loaded from here because
-- UISystem.lua loads this file before the other screens.

UI.PageMainScreen =
{
	GUI=
	{
		OnActivate = function(self)
			self.fActivateTime = System:GetCurrAsyncTime();
		end,

		-- as in the game: credits and demo loops quit with escape into the game otherwise
		OnUpdate = function(self)
			if ((self.fActivateTime) and (System:GetCurrAsyncTime() - self.fActivateTime > 0.125)) then
				self.fActivateTime = nil;
				UI:EnableSwitch(1);
			end
		end
	},

	QuitYes = function()
		Game:SendMessage("Quit-Yes");
	end,

	ShowConfirmation = function()
		UI.YesNoBox(Localize("Quit"), Localize("QuitConfirmation"), UI.PageMainScreen.QuitYes);
	end,
}

AddUISideMenu(UI.PageMainScreen.GUI,
{
	{ "Coop", "Co-op", "Coop", },
	{ "Options", Localize("Options"), "Options", },
	{ "Profiles", Localize("Profiles"), "Profiles", },
	{ "Mods", Localize("Mods"), "Mods", },
	{ "DemoLoop", Localize("DemoLoop"), "DemoLoop", 0},
	{ "Credits", Localize("Credits"), "Credits", 0},
	{ "Quit", Localize("Quit"), UI.PageMainScreen.ShowConfirmation, },
});

UI:CreateScreenFromTable("MainScreen", UI.PageMainScreen.GUI);

UI.PageMainScreenInGame =
{
	GUI=
	{
		OnActivate = function(self)
			self.fActivateTime = System:GetCurrAsyncTime();
		end,

		OnUpdate = function(self)
			if ((self.fActivateTime) and (System:GetCurrAsyncTime() - self.fActivateTime > 0.125)) then
				self.fActivateTime = nil;
				UI:EnableSwitch(1);
			end
		end
	},
}

AddUISideMenu(UI.PageMainScreenInGame.GUI,
{
	{ "Return", Localize("ReturnToGame"), "$Return$", },
	{ "-", "-", "-", },
	{ "Coop", "Co-op", "Coop", },
	{ "Options", Localize("Options"), "Options", },
	{ "Profiles", Localize("Profiles"), "Profiles", },
	{ "Mods", Localize("Mods"), "Mods", },
	{ "Quit", Localize("Quit"), UI.PageMainScreen.ShowConfirmation, },
});

UI:CreateScreenFromTable("MainScreenInGame", UI.PageMainScreenInGame.GUI);

Script:LoadScript("Scripts/MenuScreens/Coop.lua", 1);
