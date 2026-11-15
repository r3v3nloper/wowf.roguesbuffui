-- Settings panel: Esc > Options > AddOns > Rogue's Buffs UI
-- Built with Blizzard's Settings API. Created from Core.lua inside a pcall,
-- so a problem here never breaks the icons themselves.

local ADDON_NAME, ns = ...
local L = ns.L

local mainCategory

local function Checkbox(category, key, label, tooltip, get, set, default)
	local setting = Settings.RegisterProxySetting(category, "RBU_" .. key, Settings.VarType.Boolean,
		label, default, get, set)
	Settings.CreateCheckbox(category, setting, tooltip)
end

local function Slider(category, key, label, tooltip, min, max, step, get, set, default)
	local setting = Settings.RegisterProxySetting(category, "RBU_" .. key, Settings.VarType.Number,
		label, default, get, set)
	local options = Settings.CreateSliderOptions(min, max, step)
	if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	Settings.CreateSlider(category, setting, options, tooltip)
end

function ns.CreateOptions()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then
		return
	end
	local DB = ns.DB

	local category, layout = Settings.RegisterVerticalLayoutCategory(L.TITLE)
	mainCategory = category
	if not layout and SettingsPanel and SettingsPanel.GetLayout then
		layout = SettingsPanel:GetLayout(category)
	end

	if layout and CreateSettingsButtonInitializer then
		layout:AddInitializer(CreateSettingsButtonInitializer(L.OPT_TEST, L.OPT_TEST_BUTTON,
			function() ns.ShowAlert(L.ALERT_TEST) end, nil, true))
	end

	local function relayout()
		ns.ApplyLayoutSettings()
	end

	Checkbox(category, "Locked", L.OPT_LOCK, L.OPT_LOCK_TT,
		function() return DB.locked end,
		function(v) DB.locked = v; relayout() end, true)

	Checkbox(category, "SnD", L.OPT_SND, L.OPT_SND_TT,
		function() return DB.enabled.snd ~= false end,
		function(v) DB.enabled.snd = v; relayout() end, true)
	Checkbox(category, "MH", L.OPT_MH, L.OPT_MH_TT,
		function() return DB.enabled.mh ~= false end,
		function(v) DB.enabled.mh = v; relayout() end, true)
	Checkbox(category, "OH", L.OPT_OH, L.OPT_OH_TT,
		function() return DB.enabled.oh ~= false end,
		function(v) DB.enabled.oh = v; relayout() end, true)

	Checkbox(category, "OnlyMissing", L.OPT_ONLY_MISSING, L.OPT_ONLY_MISSING_TT,
		function() return DB.onlyMissing end,
		function(v) DB.onlyMissing = v; relayout() end, false)
	Checkbox(category, "Sound", L.OPT_SOUND, L.OPT_SOUND_TT,
		function() return DB.sound end,
		function(v) DB.sound = v end, true)
	Checkbox(category, "Text", L.OPT_TEXT, L.OPT_TEXT_TT,
		function() return DB.textAlert end,
		function(v) DB.textAlert = v end, true)

	Slider(category, "Size", L.OPT_SIZE, L.OPT_SIZE_TT, 20, 80, 2,
		function() return DB.iconSize end,
		function(v) DB.iconSize = v; relayout() end, 40)
	Slider(category, "Scale", L.OPT_SCALE, L.OPT_SCALE_TT, 50, 200, 5,
		function() return DB.scale end,
		function(v) DB.scale = v; relayout() end, 100)
	Slider(category, "PoisonMin", L.OPT_POISON_MIN, L.OPT_POISON_MIN_TT, 0, 30, 1,
		function() return DB.poisonWarnMinutes end,
		function(v) DB.poisonWarnMinutes = v end, 5)
	Slider(category, "PoisonCharges", L.OPT_POISON_CHARGES, L.OPT_POISON_CHARGES_TT, 0, 50, 1,
		function() return DB.poisonWarnCharges end,
		function(v) DB.poisonWarnCharges = v end, 10)

	if layout and CreateSettingsListSectionHeaderInitializer then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPT_CUSTOM_INFO))
	end

	Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
	if mainCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(mainCategory:GetID())
	else
		for _, line in ipairs(L.HELP) do
			DEFAULT_CHAT_FRAME:AddMessage(line)
		end
	end
end
