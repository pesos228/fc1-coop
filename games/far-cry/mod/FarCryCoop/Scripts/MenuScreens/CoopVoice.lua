-- Voice chat key in Options > Controls (asi/voice.c: push-to-talk, K by default). The game's own
-- actions come from CryGame.dll, which has no voice action, so the list gets one more row of its
-- own ("Co-op" / "Voice chat (push to talk)") and its own "press a key" screen. The key is kept in
-- Mods/FarCryCoop/voice.lua and given to the ASI as a VK code (coop_voice key vk<n>): the ASI reads
-- the key itself (GetAsyncKeyState), as it runs outside the game's input.

-- the game's key names (Input:GetXKeyPressedName) the ASI can watch, and their VK codes
COOP_VOICE_KEYS = {
	mouse3 = 4, mouse4 = 5, mouse5 = 6,
	lalt = 164, ralt = 165, rctrl = 163, rshift = 161, capslock = 20, caps = 20,
	backspace = 8, insert = 45, delete = 46, home = 36, ["end"] = 35,
	numpad0 = 96, numpad1 = 97, numpad2 = 98, numpad3 = 99, numpad4 = 100,
	numpad5 = 101, numpad6 = 102, numpad7 = 103, numpad8 = 104, numpad9 = 105,
}
for i = 1, 12 do COOP_VOICE_KEYS["f"..i] = 111 + i; end
for i = 0, 9 do COOP_VOICE_KEYS[tostring(i)] = 48 + i; end
for i = 97, 122 do COOP_VOICE_KEYS[strchar(i)] = i - 32; end

COOP_VoiceKey = COOP_VoiceKey or "k"
do -- COOP_VoiceKey="..." once the player chose one (no file: no "unable to open" error)
	local f = openfile("Mods/FarCryCoop/voice.lua", "r");
	if (f) then
		closefile(f);
		Script:LoadScript("Mods/FarCryCoop/voice.lua");
	end
end

function CoopVoiceApply()
	local vk = COOP_VOICE_KEYS[strlower(tostring(COOP_VoiceKey))];
	if (vk) then System:ExecuteCommand("coop_voice key vk"..vk); end
end
function CoopVoiceSave()
	local f = openfile("Mods/FarCryCoop/voice.lua", "w");
	if (not f) then
		System:LogAlways("coop: voice chat: cannot write Mods/FarCryCoop/voice.lua");
		return;
	end
	write(f, format("COOP_VoiceKey=\"%s\"\n", tostring(COOP_VoiceKey)));
	closefile(f);
end
CoopVoiceApply();

COOP_VOICE_ACTION = {desc = "Voice chat (push to talk)", configurable = 1, coop_voice = 1}

-- Options > Controls (Options/Control.lua) and the chat line (MessageMode.lua) are loaded after
-- this file: patched once the main menu shows (MenuScreens/MainScreen.lua) or a map starts
-- (COOP ClientStuff OnSetPlayer)
function CoopVoicePatchMenus()
	CoopVoicePatchChat();
	CoopVoicePatchControls();
end
-- while the chat line is open, a K typed there does not talk (the ASI reads the key itself)
function CoopVoicePatchChat()
	local M = MessageModeScreen;
	if (not M or M.COOP_Voice or not M.OnActivate or not M.OnDeactivate) then return; end
	M.COOP_Voice = 1;
	local on, off = M.OnActivate, M.OnDeactivate;
	M.OnActivate = function(self) System:ExecuteCommand("coop_voice hold 1"); %on(self); end
	M.OnDeactivate = function(self) System:ExecuteCommand("coop_voice hold 0"); %off(self); end
end
function CoopVoicePatchControls()
	local P = UI.PageOptionsControl;
	if (not P or P.COOP_Voice or not P.FillBindList or not P.GUI or not P.GUI.change) then return; end
	P.COOP_Voice = 1;
	local fill = P.FillBindList;
	P.FillBindList = function(self)
		%fill(self);
		local list = UI.PageOptionsControl.GUI.controllist;
		list:AddItem("$8CO-OP"); -- a section title, as the game's ($8: its orange)
		local i = list:AddItem(COOP_VOICE_ACTION.desc, strupper(tostring(COOP_VoiceKey)), "");
		if (i) then UI.PageOptionsControl.Actions[i] = COOP_VOICE_ACTION; end
		if (COOP_VOTE_ACTIONS) then -- the vote keys (MenuScreens/CoopVote.lua)
			i = list:AddItem(COOP_VOTE_ACTIONS[1].desc, strupper(tostring(COOP_VoteYesKey)), "");
			if (i) then UI.PageOptionsControl.Actions[i] = COOP_VOTE_ACTIONS[1]; end
			i = list:AddItem(COOP_VOTE_ACTIONS[2].desc, strupper(tostring(COOP_VoteNoKey)), "");
			if (i) then UI.PageOptionsControl.Actions[i] = COOP_VOTE_ACTIONS[2]; end
		end
	end
	local change = P.GUI.change.OnCommand;
	P.GUI.change.OnCommand = function(Sender)
		local list = UI.PageOptionsControl.GUI.controllist;
		if (list:GetSelectionCount() == 1) then
			local Action = UI.PageOptionsControl.Actions[list:GetSelection(0)];
			if (Action and Action.coop_voice) then
				UI:ActivateScreen("CoopBindVoice");
				return;
			end
			if (Action and Action.coop_vote) then
				UI.PageCoopBindVote.Action = Action;
				UI:ActivateScreen("CoopBindVote");
				return;
			end
		end
		%change(Sender);
	end
end

-- the game's "press a key" screen (Options/BindWaitForKey.lua), for the voice key
UI.PageCoopBindVoice =
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
			UI.PageCoopBindVoice.GUI.commandtext:SetText(Localize("PressAKeyToBind").." "..COOP_VOICE_ACTION.desc..
				"\n(a letter, a digit, F1-F12, mouse 3-5, Alt, right Ctrl or Shift, Caps Lock, numpad)");
		end,
		OnUpdate = function(self)
			local key = Input:GetXKeyPressedName();
			if (not key) then return; end
			key = strlower(tostring(key));
			if (key == "esc" or key == "pause" or key == strlower(tostring(System:GetConsoleKeyName()))) then return; end
			if (not COOP_VOICE_KEYS[key]) then return; end -- a key the ASI cannot watch: wait for another
			COOP_VoiceKey = key;
			CoopVoiceSave();
			CoopVoiceApply();
			UI.PageOptionsControl:FillBindList();
			UI:DeactivateScreen(self);
		end,
	},
}
UI:CreateScreenFromTable("CoopBindVoice", UI.PageCoopBindVoice.GUI);
