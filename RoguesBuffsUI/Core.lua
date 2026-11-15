-- Rogue's Buffs UI: shows self-applied buffs (Slice and Dice, weapon poisons,
-- own additions) as movable icons and alerts when they run out.
--
-- WoW Forever runs on the Midnight client: aura data can be "secret" while
-- addon restrictions are active (combat). Secret values must never be compared
-- or tested, so every value from the game goes through Safe*() first.
-- If auras can't be read in combat we fall back to (1) the expiry time that
-- was readable before and (2) an estimate from our own Slice and Dice cast.

local ADDON_NAME, ns = ...
local L = ns.L

local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
	or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "?"

local DB
local trackers = {}      -- ordered list of tracker definitions
local states = {}        -- [key] = runtime state
local icons = {}         -- [key] = icon frame
local container, alertFrame
local playerClass
local inCombat = false

---------------------------------------------------------------------------
-- Helpers: secret-safe access
---------------------------------------------------------------------------

local function IsSecret(v)
	if issecretvalue then
		local ok, r = pcall(issecretvalue, v)
		if ok and r then
			return true
		end
	end
	return false
end

local function CanUseTable(t)
	if type(t) ~= "table" or IsSecret(t) then
		return false
	end
	if canaccesstable then
		local ok, r = pcall(canaccesstable, t)
		if ok and r == false then
			return false
		end
	end
	return true
end

local function SafeNumber(v)
	if type(v) == "number" and not IsSecret(v) then
		return v
	end
end

local function SafeString(v)
	if type(v) == "string" and not IsSecret(v) then
		return v
	end
end

-- Returns true/false, or nil if unknown/secret. Old APIs return 1/nil.
local function SafeBool(v)
	if IsSecret(v) then
		return nil
	end
	if type(v) == "boolean" then
		return v
	end
	if type(v) == "number" then
		return v ~= 0
	end
	return false
end

local function Call(fn, ...)
	if not fn then
		return false
	end
	return pcall(fn, ...)
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RBU|r: " .. tostring(msg))
end
ns.Print = Print

---------------------------------------------------------------------------
-- Spell helpers
---------------------------------------------------------------------------

local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = Call(C_Spell.GetSpellName, id)
		if ok and SafeString(n) then
			return n
		end
	end
	if GetSpellInfo then
		local ok, n = Call(GetSpellInfo, id)
		if ok and SafeString(n) then
			return n
		end
	end
end

local function SpellIcon(id)
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, t = Call(C_Spell.GetSpellTexture, id)
		if ok and not IsSecret(t) and t then
			return t
		end
	end
	if GetSpellInfo then
		local ok, _, _, t = Call(GetSpellInfo, id)
		if ok and not IsSecret(t) and t then
			return t
		end
	end
end

-- Spell ID from a name (only works for spells in your spellbook).
local function SpellIDFromName(name)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = Call(C_Spell.GetSpellInfo, name)
		if ok and CanUseTable(info) then
			return SafeNumber(info.spellID)
		end
	end
	if GetSpellInfo then
		local ok, _, _, _, _, _, _, id = Call(GetSpellInfo, name)
		if ok then
			return SafeNumber(id)
		end
	end
end

local function KnowsSpell(id)
	if IsPlayerSpell then
		local ok, r = Call(IsPlayerSpell, id)
		if ok and SafeBool(r) then
			return true
		end
	end
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		local ok, r = Call(C_SpellBook.IsSpellKnown, id)
		if ok and SafeBool(r) then
			return true
		end
	end
	return false
end

local function PlayerLevel()
	return SafeNumber(UnitLevel("player")) or 0
end

local function ComboPoints()
	local n
	if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
		local ok, v = Call(UnitPower, "player", Enum.PowerType.ComboPoints)
		if ok then
			n = SafeNumber(v)
		end
	end
	if (not n or n == 0) and GetComboPoints then
		local ok, v = Call(GetComboPoints, "player", "target")
		if ok and SafeNumber(v) then
			n = math.max(n or 0, v)
		end
	end
	return n or 0
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local DEFAULTS = {
	locked = true,
	pos = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
	alertPos = { point = "CENTER", relPoint = "CENTER", x = 0, y = 200 },
	iconSize = 40,
	spacing = 6,
	scale = 100,
	onlyMissing = false,
	sound = true,
	textAlert = true,
	poisonWarnMinutes = 5,
	poisonWarnCharges = 10,
	enabled = { snd = true, mh = true, oh = true },
	custom = {},      -- { id = number|nil, name = string, combatOnly = bool }
	learnedIDs = {},  -- [trackerKey] = { [spellID] = true }
	learnedDur = {},  -- [trackerKey] = { [comboPoints] = seconds }
}

local function CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then
				dst[k] = {}
			end
			CopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

---------------------------------------------------------------------------
-- Trackers
---------------------------------------------------------------------------

-- Slice and Dice: vanilla ranks 5171/6774, retail 315496. Name matching
-- (localized name from those IDs) catches other IDs out of combat; IDs found
-- that way are remembered for combat.
local SND_IDS = { 5171, 6774, 315496 }

local function MakeAuraTracker(key, ids, names, opts)
	local tr = {
		key = key,
		kind = "aura",
		ids = {},
		idSet = {},
		nameSet = {},
		names = {},
		combatOnly = opts.combatOnly,
		warnSeconds = opts.warnSeconds or 0,
		estimate = opts.estimate,
		label = opts.label,
		isAvailable = opts.isAvailable,
		builtin = opts.builtin,
	}
	local function addID(id)
		if id and not tr.idSet[id] then
			tr.idSet[id] = true
			tr.ids[#tr.ids + 1] = id
		end
	end
	for _, id in ipairs(ids) do
		addID(id)
		local n = SpellName(id)
		if n and not tr.nameSet[n] then
			tr.nameSet[n] = true
			tr.names[#tr.names + 1] = n
		end
		if not tr.icon then
			tr.icon = SpellIcon(id)
		end
	end
	for _, n in ipairs(names or {}) do
		if not tr.nameSet[n] then
			tr.nameSet[n] = true
			tr.names[#tr.names + 1] = n
		end
	end
	local learned = DB.learnedIDs[key]
	if learned then
		for id in pairs(learned) do
			addID(id)
		end
	end
	tr.AddID = addID
	tr.displayName = tr.label or tr.names[1] or tostring(ids[1] or "?")
	return tr
end

local function BuildTrackers()
	wipe(trackers)

	if playerClass == "ROGUE" then
		trackers[#trackers + 1] = MakeAuraTracker("snd", SND_IDS, nil, {
			builtin = true,
			combatOnly = true,
			warnSeconds = 3,
			estimate = { base = 6, perCP = 3 },
			isAvailable = function()
				for _, id in ipairs(SND_IDS) do
					if KnowsSpell(id) then
						return true
					end
				end
				return PlayerLevel() >= 10
			end,
		})
		trackers[#trackers].icon = trackers[#trackers].icon or "Interface\\Icons\\Ability_Rogue_SliceDice"
		if trackers[#trackers].displayName == "5171" then
			trackers[#trackers].displayName = L.SND
		end

		local function poisonAvailable()
			return KnowsSpell(2842) or PlayerLevel() >= 20
		end
		trackers[#trackers + 1] = { key = "mh", kind = "weapon", slot = 16, builtin = true,
			short = L.MH, long = L.MAINHAND, isAvailable = poisonAvailable }
		trackers[#trackers + 1] = { key = "oh", kind = "weapon", slot = 17, builtin = true,
			short = L.OH, long = L.OFFHAND, isAvailable = poisonAvailable }
	end

	for i, c in ipairs(DB.custom) do
		local ids = c.id and { c.id } or {}
		local names = c.name and { c.name } or nil
		local tr = MakeAuraTracker("c" .. i, ids, names, { combatOnly = c.combatOnly, label = c.name })
		tr.icon = tr.icon or c.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
		trackers[#trackers + 1] = tr
	end

	for _, tr in ipairs(trackers) do
		states[tr.key] = states[tr.key] or {}
	end
end

local function TrackerEnabled(tr)
	if tr.builtin then
		return DB.enabled[tr.key] ~= false
	end
	return true
end

---------------------------------------------------------------------------
-- Reading auras
---------------------------------------------------------------------------

-- Returns "found", expires, duration, icon  |  "secret"  |  nil
local function ReadAuraTable(aura)
	if not CanUseTable(aura) then
		return "secret"
	end
	local exp = SafeNumber(aura.expirationTime)
	local dur = SafeNumber(aura.duration)
	if exp == nil or dur == nil then
		return "secret"
	end
	local icon = aura.icon
	if IsSecret(icon) then
		icon = nil
	end
	return "found", exp, dur, icon
end

local function LearnID(tr, id)
	if tr.idSet[id] then
		return
	end
	tr.AddID(id)
	DB.learnedIDs[tr.key] = DB.learnedIDs[tr.key] or {}
	DB.learnedIDs[tr.key][id] = true
end

local function FindAura(tr)
	local api = C_UnitAuras

	-- 1) direct lookup by spell ID (cheap, may work in combat)
	if api and api.GetPlayerAuraBySpellID then
		for _, id in ipairs(tr.ids) do
			local ok, aura = Call(api.GetPlayerAuraBySpellID, id)
			if ok and type(aura) == "table" then
				return ReadAuraTable(aura)
			end
		end
	end

	-- 2) scan all buffs, match by ID or name
	if api and api.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, aura = Call(api.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not ok or type(aura) ~= "table" then
				break
			end
			if CanUseTable(aura) then
				local name = SafeString(aura.name)
				local sid = SafeNumber(aura.spellId)
				if (sid and tr.idSet[sid]) or (name and tr.nameSet[name]) then
					if sid then
						LearnID(tr, sid)
					end
					return ReadAuraTable(aura)
				end
			end
		end
	elseif UnitAura then
		for i = 1, 40 do
			local ok, name, icon, _, _, dur, exp, _, _, _, sid = Call(UnitAura, "player", i, "HELPFUL")
			if not ok or type(name) == "nil" then
				break
			end
			name, sid = SafeString(name), SafeNumber(sid)
			if (sid and tr.idSet[sid]) or (name and tr.nameSet[name]) then
				if sid then
					LearnID(tr, sid)
				end
				dur, exp = SafeNumber(dur), SafeNumber(exp)
				if dur and exp then
					return "found", exp, dur, (not IsSecret(icon)) and icon or nil
				end
				return "secret"
			end
		end
	end
end

local function EvaluateAura(tr, st, now)
	local res, exp, dur, icon = FindAura(tr)

	if res == "found" then
		st.status = "active"
		st.source = "aura"
		if inCombat then
			st.readableInCombat = true
		end
		if exp and exp > 0 and dur and dur > 0 then
			-- learn real duration of our own cast for later estimates
			if tr.estimate and st.pendingCP and st.castTime and now - st.castTime < 2 then
				DB.learnedDur[tr.key] = DB.learnedDur[tr.key] or {}
				DB.learnedDur[tr.key][st.pendingCP] = math.floor(dur + 0.5)
				st.pendingCP = nil
			end
			st.expires, st.duration = exp, dur
		else
			st.expires, st.duration = nil, nil -- no timer (permanent buff)
		end
		if icon then
			st.icon = icon
		end
	elseif res == "secret" then
		-- there, but the game hides the details: keep a cached timer if any
		st.status = "active"
		st.source = "secret"
		if st.expires and st.expires <= now then
			st.expires, st.duration = nil, nil
		end
	elseif inCombat and not st.readableInCombat then
		-- nil in combat can mean "missing" OR "hidden by the game"
		if st.expires and st.expires > now then
			st.status = "active"
			if st.source ~= "estimate" then
				st.source = "cache"
			end
		elseif st.status == "active" and st.expires == nil and st.source ~= "estimate" then
			st.status = "active" -- permanent buff we saw before combat
			st.source = "cache"
		else
			st.status = "missing"
			st.expires, st.duration = nil, nil
		end
	else
		st.status = "missing"
		st.expires, st.duration = nil, nil
		st.source = nil
	end

	st.low = st.status == "active" and tr.warnSeconds > 0 and st.expires ~= nil
		and (st.expires - now) <= tr.warnSeconds
end

---------------------------------------------------------------------------
-- Weapon poisons (temporary weapon enchants)
---------------------------------------------------------------------------

local function ItemClassID(itemID)
	local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if fn then
		local ok, _, _, _, _, _, classID = Call(fn, itemID)
		if ok then
			return SafeNumber(classID)
		end
	end
end

local function HasWeapon(slot)
	local itemID = SafeNumber(GetInventoryItemID("player", slot))
	if not itemID then
		return false
	end
	local classID = ItemClassID(itemID)
	return classID == nil or classID == 2 -- 2 = weapon
end

-- has, remainingSeconds|nil, charges|nil, enchantID|nil
local function WeaponEnchant(slot)
	if not GetWeaponEnchantInfo then
		return nil
	end
	local ok, hasMH, mhExp, mhCh, mhID, hasOH, ohExp, ohCh, ohID = pcall(GetWeaponEnchantInfo)
	if not ok then
		return nil
	end
	local has, exp, ch, id
	if slot == 16 then
		has, exp, ch, id = hasMH, mhExp, mhCh, mhID
	else
		has, exp, ch, id = hasOH, ohExp, ohCh, ohID
	end
	exp = SafeNumber(exp)
	return SafeBool(has), exp and exp / 1000 or nil, SafeNumber(ch), SafeNumber(id)
end

local function EvaluateWeapon(tr, st, now)
	if not HasWeapon(tr.slot) then
		st.status = "hidden"
		return
	end
	local tex = GetInventoryItemTexture("player", tr.slot)
	st.icon = (not IsSecret(tex)) and tex or nil
	local has, remaining, charges = WeaponEnchant(tr.slot)
	if has == nil then
		st.status = "unknown"
		st.expires, st.charges = nil, nil
		return
	end
	if not has then
		st.status = "missing"
		st.expires, st.duration, st.charges = nil, nil, nil
		st.low = false
		return
	end
	st.status = "active"
	st.source = "weapon"
	if remaining and remaining > 0 then
		local exp = now + remaining
		-- keep a stable duration for the swipe: max remaining seen this application
		if not st.duration or not st.expires or exp > st.expires + 2 then
			st.duration = remaining
		end
		st.expires = exp
	else
		st.expires, st.duration = nil, nil
	end
	st.charges = (charges and charges > 0) and charges or nil

	local lowTime = DB.poisonWarnMinutes > 0 and remaining and remaining > 0
		and remaining < DB.poisonWarnMinutes * 60
	local lowCharges = DB.poisonWarnCharges > 0 and st.charges and st.charges < DB.poisonWarnCharges
	st.low = (lowTime or lowCharges) and true or false
	st.lowCharges = lowCharges and true or false
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------

local function PlayAlertSound()
	if not DB.sound then
		return
	end
	local id = SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959
	pcall(PlaySound, id, "Master")
end

local function ShowAlert(text, noSound)
	if DB.textAlert and alertFrame then
		alertFrame.text:SetText(text)
		alertFrame.text:SetTextColor(1, 0.25, 0.2)
		alertFrame.shownAt = GetTime()
		alertFrame:SetAlpha(1)
		alertFrame:Show()
	end
	if not noSound then
		PlayAlertSound()
	end
end
ns.ShowAlert = ShowAlert

local function AlertMissing(tr)
	if tr.kind == "weapon" then
		ShowAlert(L.ALERT_NO_POISON:format(tr.long))
	else
		ShowAlert(L.ALERT_EXPIRED:format(tr.displayName))
	end
end

local function CheckAlerts(tr, st, prevStatus, prevLow)
	if not TrackerEnabled(tr) or UnitIsDeadOrGhost("player") then
		return
	end
	if tr.kind == "weapon" then
		if prevStatus == "active" and st.status == "missing" then
			AlertMissing(tr)
		elseif st.status == "active" and st.low and not prevLow and prevStatus ~= nil then
			if st.lowCharges then
				ShowAlert(L.ALERT_POISON_LOW_CHARGES:format(tr.long, st.charges))
			else
				ShowAlert(L.ALERT_POISON_LOW_TIME:format(tr.long,
					math.ceil(((st.expires or GetTime()) - GetTime()) / 60)))
			end
		end
	else
		if prevStatus == "active" and st.status == "missing" and (not tr.combatOnly or inCombat) then
			AlertMissing(tr)
		end
	end
end

-- Remind about missing poisons (entering combat, after login).
local function RemindMissingPoisons()
	for _, tr in ipairs(trackers) do
		local st = states[tr.key]
		if tr.kind == "weapon" and TrackerEnabled(tr) and st.status == "missing"
			and tr.isAvailable() and not UnitIsDeadOrGhost("player") then
			AlertMissing(tr)
			return
		end
	end
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local function FormatTime(sec)
	if sec >= 3600 then
		return ("%dh"):format(math.floor(sec / 3600 + 0.5))
	elseif sec >= 60 then
		return ("%dm"):format(math.ceil(sec / 60))
	elseif sec >= 10 then
		return ("%d"):format(math.floor(sec))
	end
	return ("%.1f"):format(sec)
end

local function CreateIcon(key)
	local f = CreateFrame("Frame", nil, container)
	f:EnableMouse(false)

	f.border = f:CreateTexture(nil, "BACKGROUND")
	f.border:SetPoint("TOPLEFT", -2, 2)
	f.border:SetPoint("BOTTOMRIGHT", 2, -2)
	f.border:SetColorTexture(0, 0, 0, 0.9)

	f.tex = f:CreateTexture(nil, "ARTWORK")
	f.tex:SetAllPoints()
	f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
	f.cd:SetAllPoints()
	f.cd:SetReverse(true)
	f.cd:SetDrawEdge(false)
	if f.cd.SetHideCountdownNumbers then
		f.cd:SetHideCountdownNumbers(true)
	end

	local overlay = CreateFrame("Frame", nil, f)
	overlay:SetAllPoints()
	overlay:SetFrameLevel(f.cd:GetFrameLevel() + 2)

	f.timer = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.timer:SetPoint("TOP", f, "BOTTOM", 0, -3)

	f.label = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.label:SetPoint("TOP", f, "TOP", 0, -2)

	f.charges = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	f.charges:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 2)

	f.bang = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	f.bang:SetPoint("CENTER")
	f.bang:SetText("!")
	f.bang:SetTextColor(1, 0.15, 0.1)

	f.pulse = f.border:CreateAnimationGroup()
	f.pulse:SetLooping("BOUNCE")
	local a = f.pulse:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.25)
	a:SetDuration(0.5)

	icons[key] = f
	return f
end

local function ApplyIconLook(f, tr, st, now, unlocked)
	local size = DB.iconSize
	f:SetSize(size, size)
	f.tex:SetTexture(st.icon or tr.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	f.label:SetText(tr.short or "")

	local idle = tr.combatOnly and st.status == "missing" and not inCombat
	local missing = (st.status == "missing" and not idle) or (st.status == "unknown")

	f.tex:SetDesaturated(st.status ~= "active")
	f:SetAlpha(idle and 0.45 or 1)
	f.bang:SetShown(missing and st.status == "missing")

	if missing then
		f.border:SetColorTexture(1, 0.1, 0.05, 1)
	elseif st.low then
		f.border:SetColorTexture(1, 0.8, 0, 1)
	else
		f.border:SetColorTexture(0, 0, 0, 0.9)
	end
	local shouldPulse = (missing and st.status == "missing") or st.low
	if shouldPulse and not f.pulse:IsPlaying() then
		f.pulse:Play()
	elseif not shouldPulse and f.pulse:IsPlaying() then
		f.pulse:Stop()
		f.border:SetAlpha(1)
	end

	-- swipe
	if st.status == "active" and st.expires and st.duration and st.duration > 0 then
		local start = st.expires - st.duration
		if f.cdStart ~= start or f.cdDur ~= st.duration then
			f.cd:SetCooldown(start, st.duration)
			f.cdStart, f.cdDur = start, st.duration
		end
		f.cd:Show()
	else
		f.cd:Clear()
		f.cdStart, f.cdDur = nil, nil
	end

	f.charges:SetText(st.charges and tostring(st.charges) or "")
end

local function UpdateTimerText(f, st, now)
	if st.status == "active" then
		if st.expires then
			local left = math.max(0, st.expires - now)
			local prefix = (st.source == "estimate") and "~" or ""
			f.timer:SetText(prefix .. FormatTime(left))
			if st.low then
				f.timer:SetTextColor(1, 0.8, 0)
			else
				f.timer:SetTextColor(1, 1, 1)
			end
		elseif st.source == "secret" or st.source == "cache" then
			f.timer:SetText("?")
			f.timer:SetTextColor(0.7, 0.7, 0.7)
		else
			f.timer:SetText("")
		end
	elseif st.status == "unknown" then
		f.timer:SetText("?")
		f.timer:SetTextColor(0.7, 0.7, 0.7)
	else
		f.timer:SetText("")
	end
end

local function IconVisible(tr, st, unlocked)
	if not TrackerEnabled(tr) or st.status == "hidden" or st.status == nil then
		return false
	end
	if tr.isAvailable and not tr.isAvailable() then
		return false
	end
	if unlocked then
		return true
	end
	if UnitIsDeadOrGhost("player") then
		return false
	end
	if DB.onlyMissing then
		if st.status == "active" and not st.low then
			return false
		end
		if tr.combatOnly and st.status == "missing" and not inCombat then
			return false
		end
	end
	return true
end

local function Layout()
	if not container then
		return
	end
	local now = GetTime()
	local unlocked = not DB.locked
	local visible = {}
	for _, tr in ipairs(trackers) do
		local st = states[tr.key]
		local f = icons[tr.key] or CreateIcon(tr.key)
		if IconVisible(tr, st, unlocked) then
			ApplyIconLook(f, tr, st, now, unlocked)
			UpdateTimerText(f, st, now)
			visible[#visible + 1] = f
			f:Show()
		else
			f:Hide()
		end
	end
	local active = {}
	for _, tr in ipairs(trackers) do
		active[tr.key] = true
	end
	for key, f in pairs(icons) do
		if not active[key] then
			f:Hide()
		end
	end

	local size, gap = DB.iconSize, DB.spacing
	local n = #visible
	local width = math.max(n * size + math.max(n - 1, 0) * gap, size * 3 + gap * 2)
	container:SetSize(width, size + 18)
	local x = (width - (n * size + math.max(n - 1, 0) * gap)) / 2
	for _, f in ipairs(visible) do
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", container, "TOPLEFT", x, 0)
		x = x + size + gap
	end
end

local function RefreshTimers()
	local now = GetTime()
	for _, tr in ipairs(trackers) do
		local f = icons[tr.key]
		if f and f:IsShown() then
			UpdateTimerText(f, states[tr.key], now)
		end
	end
end

---------------------------------------------------------------------------
-- Evaluate everything
---------------------------------------------------------------------------

local function EvaluateAll(silent)
	if not DB then
		return
	end
	local now = GetTime()
	local changed = false
	for _, tr in ipairs(trackers) do
		local st = states[tr.key]
		local prevStatus, prevLow = st.status, st.low
		local prevExp = st.expires
		if tr.kind == "weapon" then
			EvaluateWeapon(tr, st, now)
		else
			EvaluateAura(tr, st, now)
		end
		if not silent then
			CheckAlerts(tr, st, prevStatus, prevLow)
		end
		if prevStatus ~= st.status or prevLow ~= st.low or prevExp ~= st.expires then
			changed = true
		end
	end
	if changed then
		Layout()
	end
end
ns.EvaluateAll = EvaluateAll

-- Slice and Dice cast: estimate the duration in case the aura is secret.
local cpNow, cpSpent, cpSpentAt = 0, 0, 0

local function OnComboPoints()
	local cp = ComboPoints()
	if cp < cpNow then
		cpSpent, cpSpentAt = cpNow, GetTime()
	end
	cpNow = cp
end

local function OnPlayerCast(spellID)
	local sid = SafeNumber(spellID)
	if not sid then
		return
	end
	local now = GetTime()
	for _, tr in ipairs(trackers) do
		if tr.estimate and (tr.idSet[sid] or (SpellName(sid) and tr.nameSet[SpellName(sid)])) then
			local cp = ComboPoints()
			if now - cpSpentAt < 0.7 and cpSpent > cp then
				cp = cpSpent
			end
			if cp > 0 then
				local st = states[tr.key]
				local learned = DB.learnedDur[tr.key] and DB.learnedDur[tr.key][cp]
				local dur = learned or (tr.estimate.base + tr.estimate.perCP * cp)
				st.pendingCP, st.castTime = cp, now
				local res = FindAura(tr)
				if res ~= "found" then
					st.status = "active"
					st.source = "estimate"
					st.expires, st.duration = now + dur, dur
				end
				LearnID(tr, sid)
				Layout()
			end
		end
	end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function SavePos(frame, pos)
	local point, _, relPoint, x, y = frame:GetPoint(1)
	pos.point, pos.relPoint = point or "CENTER", relPoint or "CENTER"
	pos.x, pos.y = math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5)
end

local function PlaceFrame(frame, pos)
	frame:ClearAllPoints()
	frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
end

local function MakeMovable(frame, pos)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if not DB.locked then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePos(self, pos)
		PlaceFrame(self, pos)
	end)
end

local function CreateFrames()
	container = CreateFrame("Frame", "RoguesBuffsUIFrame", UIParent)
	container:SetFrameStrata("MEDIUM")
	container:SetSize(150, 60)
	MakeMovable(container, DB.pos)

	container.bg = container:CreateTexture(nil, "BACKGROUND", nil, -8)
	container.bg:SetPoint("TOPLEFT", -6, 18)
	container.bg:SetPoint("BOTTOMRIGHT", 6, -4)
	container.bg:SetColorTexture(0.1, 0.6, 1, 0.25)
	container.title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	container.title:SetPoint("BOTTOM", container, "TOP", 0, 3)
	container.title:SetText(L.FRAME_PLACEHOLDER)

	alertFrame = CreateFrame("Frame", "RoguesBuffsUIAlert", UIParent)
	alertFrame:SetFrameStrata("HIGH")
	alertFrame:SetSize(500, 40)
	MakeMovable(alertFrame, DB.alertPos)
	alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	alertFrame.text:SetPoint("CENTER")
	local font, size = alertFrame.text:GetFont()
	if font then
		alertFrame.text:SetFont(font, (size or 20) + 6, "OUTLINE")
	end
	alertFrame.bg = alertFrame:CreateTexture(nil, "BACKGROUND")
	alertFrame.bg:SetAllPoints()
	alertFrame.bg:SetColorTexture(0.1, 0.6, 1, 0.25)
	alertFrame:SetScript("OnUpdate", function(self)
		if not DB.locked or not self.shownAt then
			return
		end
		local t = GetTime() - self.shownAt
		if t > 3 then
			self:Hide()
			self.shownAt = nil
		elseif t > 2 then
			self:SetAlpha(3 - t)
		end
	end)
	alertFrame:Hide()

	local elapsed, evalElapsed = 0, 0
	container:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		evalElapsed = evalElapsed + dt
		if evalElapsed >= 0.25 then
			evalElapsed = 0
			EvaluateAll()
		end
		if elapsed >= 0.1 then
			elapsed = 0
			RefreshTimers()
		end
	end)
end

function ns.ApplyLayoutSettings()
	if not container then
		return
	end
	local unlocked = not DB.locked
	container:SetScale(DB.scale / 100)
	alertFrame:SetScale(DB.scale / 100)
	PlaceFrame(container, DB.pos)
	PlaceFrame(alertFrame, DB.alertPos)
	container:EnableMouse(unlocked)
	container.bg:SetShown(unlocked)
	container.title:SetShown(unlocked)
	alertFrame:EnableMouse(unlocked)
	alertFrame.bg:SetShown(unlocked)
	if unlocked then
		alertFrame.text:SetText(L.ALERT_PLACEHOLDER)
		alertFrame.text:SetTextColor(1, 0.82, 0)
		alertFrame.shownAt = nil
		alertFrame:SetAlpha(1)
		alertFrame:Show()
	elseif not alertFrame.shownAt then
		alertFrame:Hide()
	end
	Layout()
end

function ns.SetLocked(locked)
	DB.locked = locked
	ns.ApplyLayoutSettings()
	Print(locked and L.LOCKED or L.UNLOCKED)
end

function ns.Rebuild()
	BuildTrackers()
	EvaluateAll(true)
	Layout()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Scan()
	local api = C_UnitAuras
	local found, hidden = 0, false
	Print(L.SCAN_HEADER)
	for i = 1, 40 do
		local name, sid
		if api and api.GetAuraDataByIndex then
			local ok, aura = Call(api.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not ok or type(aura) ~= "table" then
				break
			end
			if CanUseTable(aura) then
				name, sid = SafeString(aura.name), SafeNumber(aura.spellId)
			end
		elseif UnitAura then
			local ok, n, _, _, _, _, _, _, _, _, s = Call(UnitAura, "player", i, "HELPFUL")
			if not ok or type(n) == "nil" then
				break
			end
			name, sid = SafeString(n), SafeNumber(s)
		end
		if name or sid then
			found = found + 1
			Print(("  %s - %s"):format(tostring(sid or "?"), name or "?"))
		else
			hidden = true
		end
	end
	if found == 0 and not hidden then
		Print(L.SCAN_NONE)
	end
	if hidden then
		Print(L.SCAN_SECRET)
	end
end

local function AddCustom(arg)
	local combatOnly = false
	local lower = arg:lower()
	for _, word in ipairs({ "kampf", "combat" }) do
		local s = lower:find("%s+" .. word .. "$")
		if s then
			combatOnly = true
			arg = arg:sub(1, s - 1)
			break
		end
	end
	arg = arg:gsub("^%s+", ""):gsub("%s+$", "")
	if arg == "" then
		Print(L.ADD_USAGE)
		return
	end
	local id = tonumber(arg:match("^%d+$") or arg:match("spell:(%d+)") or "")
	local name
	if id then
		name = SpellName(id)
		if not name then
			Print(L.ADD_UNKNOWN:format(arg))
			return
		end
	else
		name = arg:match("%[(.-)%]") or arg -- accepts a shift-clicked spell link
		id = SpellIDFromName(name)
	end
	DB.custom[#DB.custom + 1] = { id = id, name = name, combatOnly = combatOnly,
		icon = id and SpellIcon(id) or nil }
	ns.Rebuild()
	Print(L.ADDED:format(name))
end

local function ListCustom()
	if #DB.custom == 0 then
		Print(L.LIST_EMPTY)
		return
	end
	Print(L.LIST_HEADER)
	for i, c in ipairs(DB.custom) do
		Print(("  %d. %s%s%s"):format(i, c.name or "?", c.id and (" (" .. c.id .. ")") or "",
			c.combatOnly and (" - " .. L.COMBAT_ONLY) or ""))
	end
end

local function RemoveCustom(arg)
	local i = tonumber(arg)
	if not i or not DB.custom[i] then
		Print(L.REMOVE_USAGE)
		return
	end
	local c = table.remove(DB.custom, i)
	DB.learnedIDs["c" .. i] = nil
	-- keys shift after removal; drop learned IDs of the following entries
	for j = i, #DB.custom + 1 do
		DB.learnedIDs["c" .. j] = nil
	end
	wipe(states)
	ns.Rebuild()
	Print(L.REMOVED:format(c.name or "?"))
end

local function Debug()
	local now = GetTime()
	Print(("v%s  class=%s  level=%d  combat=%s  secrets-api=%s"):format(VERSION, tostring(playerClass),
		PlayerLevel(), tostring(inCombat), issecretvalue and "yes" or "no"))
	for _, tr in ipairs(trackers) do
		local st = states[tr.key]
		local left = st.expires and ("%.1fs"):format(st.expires - now) or "-"
		Print(("  %s: %s  src=%s  left=%s  low=%s  enabled=%s  avail=%s  ids=%s"):format(
			tr.key, tostring(st.status), tostring(st.source), left, tostring(st.low),
			tostring(TrackerEnabled(tr)), tostring(tr.isAvailable == nil or tr.isAvailable()),
			table.concat(tr.ids or {}, ",")))
	end
	if GetWeaponEnchantInfo then
		local r = { pcall(GetWeaponEnchantInfo) }
		local parts = {}
		for i = 2, math.min(#r, 9) do
			local v = r[i]
			parts[#parts + 1] = IsSecret(v) and "secret" or tostring(v)
		end
		Print("  weaponEnchant: " .. table.concat(parts, ", "))
	else
		Print("  weaponEnchant: API missing")
	end
	Print(("  combo points: %d"):format(ComboPoints()))
end

SLASH_ROGUESBUFFSUI1 = "/rbu"
SLASH_ROGUESBUFFSUI2 = "/roguesbuffs"
SlashCmdList.ROGUESBUFFSUI = function(msg)
	if not DB then
		return
	end
	msg = msg or ""
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" or cmd == "options" or cmd == "config" then
		if ns.OpenOptions then
			ns.OpenOptions()
		end
	elseif cmd == "lock" then
		ns.SetLocked(true)
	elseif cmd == "unlock" or cmd == "move" then
		ns.SetLocked(false)
	elseif cmd == "reset" then
		DB.pos = CopyDefaults({}, DEFAULTS.pos)
		DB.alertPos = CopyDefaults({}, DEFAULTS.alertPos)
		-- MakeMovable captured the old tables: re-hook
		MakeMovable(container, DB.pos)
		MakeMovable(alertFrame, DB.alertPos)
		ns.ApplyLayoutSettings()
		Print(L.POS_RESET)
	elseif cmd == "test" then
		ShowAlert(L.ALERT_TEST)
	elseif cmd == "scan" then
		Scan()
	elseif cmd == "add" then
		AddCustom(rest)
	elseif cmd == "list" then
		ListCustom()
	elseif cmd == "remove" or cmd == "del" then
		RemoveCustom(rest)
	elseif cmd == "debug" then
		Debug()
	else
		for _, line in ipairs(L.HELP) do
			DEFAULT_CHAT_FRAME:AddMessage(line)
		end
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			RoguesBuffsUICharDB = CopyDefaults(type(RoguesBuffsUICharDB) == "table" and RoguesBuffsUICharDB or {}, DEFAULTS)
			DB = RoguesBuffsUICharDB
			ns.DB = DB
			self:UnregisterEvent("ADDON_LOADED")
		end
		return
	end

	if event == "PLAYER_LOGIN" then
		local _, class = UnitClass("player")
		playerClass = class
		inCombat = InCombatLockdown() and true or false
		CreateFrames()
		BuildTrackers()
		EvaluateAll(true)
		ns.ApplyLayoutSettings()
		local ok, err = pcall(function()
			if ns.CreateOptions then
				ns.CreateOptions()
			end
		end)
		if not ok then
			Print("options: " .. tostring(err))
		end
		if C_Timer then
			C_Timer.After(5, function()
				EvaluateAll(true)
				RemindMissingPoisons()
			end)
		end

		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
		self:RegisterEvent("PLAYER_LEVEL_UP")
		self:RegisterEvent("SPELLS_CHANGED")
		self:RegisterEvent("PLAYER_TARGET_CHANGED")
		self:RegisterUnitEvent("UNIT_AURA", "player")
		self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
		self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
		self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
		self:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
		return
	end

	if event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
		EvaluateAll(true)
		Layout()
		RemindMissingPoisons()
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
		for _, st in pairs(states) do
			st.readableInCombat = nil
		end
		EvaluateAll(true)
		Layout()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		OnPlayerCast(arg3)
		EvaluateAll()
	elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" or event == "PLAYER_TARGET_CHANGED" then
		OnComboPoints()
	elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD" then
		EvaluateAll(true)
		Layout()
	else
		EvaluateAll()
	end
end)
