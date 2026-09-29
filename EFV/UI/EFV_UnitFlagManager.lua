-- ===========================================================================
-- EFV_UnitFlagManager.lua
-- Context:  UI, ReplaceUIScript LuaContext "UnitFlagManager", LoadOrder 1000
--           (modinfo action EFV_UnitFlags; above CQUI 50 and Better Builder
--           Charges 666, below Gift It To Me 13066). Also ImportFiles'd so
--           the include name resolves like other replacement wrappers.
-- Owner:    WP7.1 (badges). WP1.0 wired the base include chain and the
--           wrappers (without the base include the game has no unit flags).
--           Under Gathering Storm the live base is Base/Assets/UI/
--           UnitFlagManager.lua (Expansion1/2 do not replace it); the
--           BarbarianClansMode file is imported only when that mode is on.
--
-- Responsibility (PLAN 3.5; D8; R4 4.3): thin wrapper around the active
-- UnitFlagManager. Re-uses the religion-tag slot (ReligionIcon /
-- ReligionIconBacking, always empty on military units) for a badge: the
-- sender's civ emblem tinted gold (EXP) / green (VOL) / light blue (CS),
-- with the EFV_UI_StatusTooltip tooltip (0.7, FIXPLAN_0.7 item 4). No XML,
-- no other overrides. 0.7.2: a badge only on the flag's own live unit that a
-- record names (BadgeRecord); dev audit hook LuaEvents.EFV_BadgeAuditRequest.
-- Base code always runs first and outside EFV's pcalls; the first EFV error
-- restores the base look of every badged flag and turns badges off for the
-- session. EFV_Config.FLAG_FLAG_BADGES = false (and dropping the
-- ReplaceUIScript action) is the D8 fallback: the unit-panel status button
-- and the tracker. Known conflict: Gift It To Me wins by LoadOrder (badges
-- disappear, nothing else breaks).
-- ===========================================================================

include("EFV_Config")
-- Initialize, UnitFlag, Subscribe, Unsubscribe come from the included base
-- UnitFlagManager file (CQUI / Builder Charges variants have no export list).
-- EFV:GLOBALS Initialize

-- ---------------------------------------------------------------------------
-- Base include chain (PLAN 3.5): CQUI -> Better Builder Charges ->
-- UnitFlagManager_BarbarianClansMode -> UnitFlagManager, stopping when the
-- base Initialize exists (Builder-Charges technique). Returns the file name
-- used, or nil if none defined Initialize.
-- ---------------------------------------------------------------------------
local function IncludeBase()
	-- EFV_Config nil-checks: a failed EFV include must never cost the base flags.
	if EFV_Config ~= nil and Modding.IsModActive(EFV_Config.CQUI_MOD_ID) then
		include("unitflagmanager_CQUI")
		if Initialize ~= nil then
			return "unitflagmanager_CQUI"
		end
	end
	if EFV_Config ~= nil and Modding.IsModActive(EFV_Config.BUILDER_CHARGES_MOD_ID) then
		include("UnitFlagManager_BuilderCharges")
		if Initialize ~= nil then
			return "UnitFlagManager_BuilderCharges"
		end
	end
	local files = { "UnitFlagManager_BarbarianClansMode", "UnitFlagManager" }
	for _, fileName in ipairs(files) do
		include(fileName)
		if Initialize ~= nil then
			return fileName
		end
	end
	return nil
end

local m_BaseFile = IncludeBase()

include("EFV_UIShared")

local LOG_TAG = "UIFlags"

-- Badge per force type (0.7, FIXPLAN_0.7 item 4). The icon is the LENDING
-- civ's emblem ("ICON_" .. its civilization type, the base pattern of
-- Instances/CivilizationIcon.lua:56): the 22 px civ emblems are white glyphs
-- tinted in code (Icons_Civilizations.xml:4; EspionageOverview.lua:784-787),
-- like the base religion icons in this slot (UnitFlagManager.lua:806-807).
-- 0.6 used ICON_ATLAS_DIPLOACTIONS, a baked-colour set drawn untinted
-- (DiplomacyActionView.xml:56): a dark glyph on the near-black religion tag
-- (UnitFlagReligionTag), so the tester saw only a black bar. The tint (ABGR,
-- format of Colors.lua:6-8) tells the force type: EXP gold, VOL green, CS
-- light blue. A sender the local player has not met shows
-- ICON_CIVILIZATION_UNKNOWN (CivilizationIcon.lua:47-57). SetIcon returning
-- false (a modded civ without a 22 px emblem) walks FALLBACK_ICONS
-- (Icons_Civilizations.xml:28; Icons_CityStates.xml:4,19). ReligionIcon has
-- IconSize 22, so only atlases with a 22 px size work. The text label
-- (LOC_EFV_BADGE_*) heads the tooltip.
-- 0.7.2 (re-test 0.7 step 3: the emblem was dark and the same for all three
-- types): the hex literal was passed to SetColor as is. The engine wants the
-- value from UI.GetColorValueFromHexLiteral (every tint in Colors.lua:6-17 is
-- built that way; METER_HP_GOOD there is our green 0xFF4BE810); a raw
-- 0xFFxxxxxx literal is above the int32 range and draws dark. TintOf
-- converts once per badge and falls back to the literal only when the
-- converter is missing.
local BADGES = {
	EXPEDITIONARY    = { hex = 0xFF3CC8FF, label = "LOC_EFV_BADGE_EXP" },   -- gold
	VOLUNTEER        = { hex = 0xFF4BE810, label = "LOC_EFV_BADGE_VOL" },   -- green
	CS_EXPEDITIONARY = { hex = 0xFFFFC878, label = "LOC_EFV_BADGE_CS" },    -- light blue
}
local UNKNOWN_ICON = "ICON_CIVILIZATION_UNKNOWN"
local FALLBACK_ICONS = { UNKNOWN_ICON, "ICON_CITYSTATE_MILITARISTIC" }
local BADGE_STATES = { DEPLOYED = true, GRACE = true, MUTINY = true }
local POLL_EVENTS = { "PlayerTurnActivated", "UnitAddedToMap", "UnitRemovedFromMap",
	"UnitSelectionChanged", "UnitMoveComplete", "LocalPlayerChanged" }

local BASE_UpdateReligion = nil  -- set when the wrapper is installed
local m_Off = false              -- true after the first EFV error: base behaviour
local m_Badged = {}              -- "pid:uid" -> { pid, uid } of flags showing a badge
local m_Sig = nil                -- "rev:turn" of the last full refresh

-- Engine colour value of a badge's tint (cached in badge.color).
local function TintOf(badge)
	if badge.color == nil then
		local conv = UI.GetColorValueFromHexLiteral
		badge.color = (conv ~= nil) and conv(badge.hex) or badge.hex
	end
	return badge.color
end

local function Key(pid, uid)
	return tostring(pid) .. ":" .. tostring(uid)
end

-- First error: log once, give every badged flag its base look back, stop.
local function EFV_Fail(where, err)
	if m_Off then
		return
	end
	m_Off = true
	EFV_Log(1, LOG_TAG, "%s failed; badges off for this session: %s", where, tostring(err))
	for _, k in ipairs(EFV_SortedKeys(m_Badged)) do
		local e = m_Badged[k]
		pcall(function()
			local f = GetUnitFlag(e[1], e[2])
			if f ~= nil then
				BASE_UpdateReligion(f)
			end
		end)
	end
	m_Badged = {}
end

-- ---------------------------------------------------------------------------
-- EFV_ApplyBadge(flag)
-- After the base UpdateReligion: if the flag's unit has a record in DEPLOYED
-- / GRACE / MUTINY, put the sender's emblem (EmblemIcon) into the religion
-- tag, tinted by force type, with the tooltip "[EXP] " ..
-- EFV_UI_StatusTooltip(rec) (LOC_EFV_FLAG_TT: force, unit, sender,
-- recipient, state with remaining turns) and show it. Otherwise the base
-- result stands (the base hid or set the tag).
-- PLAN 3.5; spec 14.4; FIXPLAN_0.7 item 4; UnitFlagManager.lua:216, :796.
-- APIs: U14, U07, A62.
-- ---------------------------------------------------------------------------

-- Emblem of the sender as the local player may see it: "ICON_<civ type>",
-- or ICON_CIVILIZATION_UNKNOWN when the local player (not the sender) has
-- not met the sender or the civ type is unreadable.
local function EmblemIcon(senderID)
	local localID = Game.GetLocalPlayer()
	if type(senderID) ~= "number" or senderID < 0 then
		return UNKNOWN_ICON
	end
	if localID ~= nil and localID >= 0 and localID ~= senderID then
		local pLocal = Players[localID]
		if pLocal ~= nil and not pLocal:GetDiplomacy():HasMet(senderID) then
			return UNKNOWN_ICON
		end
	end
	local cfg = PlayerConfigurations[senderID]
	local civType = (cfg ~= nil) and cfg:GetCivilizationTypeName() or nil
	if type(civType) ~= "string" or civType == "" then
		return UNKNOWN_ICON
	end
	return "ICON_" .. civType
end

-- The flag's own key (base UnitFlag.Initialize: m_Player = Players[pid],
-- m_UnitID = uid). nil parts when the flag object lacks them.
local function FlagKey(flag)
	local pid, uid = nil, flag.m_UnitID
	pcall(function()
		if flag.m_Player ~= nil then
			pid = flag.m_Player:GetID()
		end
	end)
	return pid, uid
end

-- 0.7.2 identity rule (0.7.1 report: "the Volunteer Swordsman turned into a
-- Warrior"): the base UnitFlag.GetUnit resolves the flag's stored ID with
-- FindID, which matches only the slot (Session C) and still returns a dead
-- unit's object (Session F). A badge therefore needs all of: the unit found
-- is the flag's own (same owner and full ID), it is the live unit of the
-- record (EFV_UnitMatches: owner, ID, type or an upgrade, not GONE_*), and
-- the record is on the map. Returns the record or nil.
local function BadgeRecord(flag, pUnit)
	local pid, uid = pUnit:GetOwner(), pUnit:GetID()
	local fPid, fUid = FlagKey(flag)
	if (fPid ~= nil and fPid ~= pid) or (fUid ~= nil and fUid ~= uid) then
		return nil, "FLAG_KEY"
	end
	local rec = EFV_UI_RecordForUnit(pid, uid)
	if rec == nil or not BADGE_STATES[rec.state] or BADGES[rec.forceType] == nil then
		return nil, "NO_RECORD"
	end
	local same, why = EFV_UnitMatches(pUnit, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType)
	if not same then
		return nil, why
	end
	return rec
end

local function EFV_ApplyBadge(flag)
	local pUnit = flag:GetUnit()
	local inst = flag.m_Instance
	if inst == nil then
		return
	end
	if pUnit == nil then
		-- The flag's unit is gone (the base leaves the tag as it was): take
		-- a VEF badge off.
		local fPid, fUid = FlagKey(flag)
		if fPid ~= nil and m_Badged[Key(fPid, fUid)] ~= nil and inst.ReligionIconBacking ~= nil then
			inst.ReligionIconBacking:SetHide(true)
			m_Badged[Key(fPid, fUid)] = nil
		end
		return
	end
	local pid, uid = pUnit:GetOwner(), pUnit:GetID()
	local rec = BadgeRecord(flag, pUnit)
	local badge = rec ~= nil and BADGES[rec.forceType] or nil
	if badge == nil or inst.ReligionIcon == nil or inst.ReligionIconBacking == nil then
		local fPid, fUid = FlagKey(flag)
		if m_Badged[Key(pid, uid)] ~= nil or (fPid ~= nil and m_Badged[Key(fPid, fUid)] ~= nil) then
			-- It carried a badge: the base result (called just before) stands.
			m_Badged[Key(pid, uid)] = nil
			if fPid ~= nil then
				m_Badged[Key(fPid, fUid)] = nil
			end
		end
		return
	end
	local icon = EmblemIcon(rec.senderID)
	if inst.ReligionIcon:SetIcon(icon) == false then
		for _, fb in ipairs(FALLBACK_ICONS) do
			if fb ~= icon and inst.ReligionIcon:SetIcon(fb) ~= false then
				break
			end
		end
	end
	inst.ReligionIcon:SetColor(TintOf(badge))
	inst.ReligionIconBacking:SetToolTipString("[" .. Locale.Lookup(badge.label) .. "] " .. EFV_UI_StatusTooltip(rec))
	inst.ReligionIconBacking:SetHide(false)
	m_Badged[Key(pid, uid)] = { pid, uid }
end

-- ---------------------------------------------------------------------------
-- EFV_RefreshAllBadges(force)
-- If EFV_Rev or the turn changed since the last pass (or force): re-run
-- UpdateReligion on the flag of every on-map record and of every flag that
-- showed a badge (ended records lose it). Otherwise one GetProperty only.
-- PLAN 3.5; UnitFlagManager.lua:166. APIs: U14, A06.
-- ---------------------------------------------------------------------------
local function EFV_RefreshAllBadges(force)
	local store = EFV_UI_ReadStore()
	local sig = tostring(store.rev) .. ":" .. tostring(Game.GetCurrentGameTurn())
	if sig == m_Sig and not force then
		return
	end
	m_Sig = sig
	local targets = {}
	for k, e in pairs(m_Badged) do
		targets[k] = e
	end
	for _, id in ipairs(store.ids) do
		local rec = store.recs["r" .. tostring(id)]
		if type(rec) == "table" and rec.onMapPlayerID ~= nil and rec.onMapUnitID ~= nil then
			targets[Key(rec.onMapPlayerID, rec.onMapUnitID)] = { rec.onMapPlayerID, rec.onMapUnitID }
		end
	end
	for _, k in ipairs(EFV_SortedKeys(targets)) do
		local f = GetUnitFlag(targets[k][1], targets[k][2])
		if f ~= nil then
			UnitFlag.UpdateReligion(f)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Dev audit hook (0.7.2; EFV_Dev "Badge audit"; nothing fires it in normal
-- play): LuaEvents.EFV_BadgeAuditRequest() answers
-- LuaEvents.EFV_BadgeAuditReport(rows), one row per flag that shows a VEF
-- tag: every flag this wrapper decorated (m_Badged) and every live unit's
-- flag whose religion tag is visible although the unit carries no religion
-- (only VEF uses that slot then). Row: { fp, fu = the flag's key; up, uu,
-- ut = its unit (owner, ID, type); rid, rt, rs = the record found for the
-- flag's key; bad = nil or why the tag is on the wrong unit }.
-- ---------------------------------------------------------------------------
local function AuditRow(fp, fu)
	local f = GetUnitFlag(fp, fu)
	local inst = f and f.m_Instance or nil
	if inst == nil or inst.ReligionIconBacking == nil or inst.ReligionIconBacking:IsHidden() then
		return nil
	end
	local row = { fp = fp, fu = fu }
	local pUnit = f:GetUnit()
	if pUnit ~= nil then
		row.up, row.uu = pUnit:GetOwner(), pUnit:GetID()
		local r = GameInfo.Units[pUnit:GetType()]
		row.ut = r and r.UnitType or nil
		local okR, religious = pcall(function() return pUnit:GetReligionType() > 0 and pUnit:GetReligiousStrength() > 0 end)
		if okR and religious then
			return nil   -- the base religion tag
		end
	end
	local rec = EFV_UI_RecordForUnit(fp, fu)
	if rec ~= nil then
		row.rid, row.rt, row.rs = rec.id, rec.unitType, rec.state
	end
	if pUnit == nil then
		row.bad = "the flag has no unit"
	elseif row.up ~= fp or row.uu ~= fu then
		row.bad = "the flag's unit is another unit"
	elseif rec == nil or not BADGE_STATES[rec.state] then
		row.bad = "no on-map record for this unit"
	else
		local same, why = EFV_UnitMatches(pUnit, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType)
		if not same then
			row.bad = "not the record's live unit (" .. tostring(why) .. ")"
		end
	end
	return row
end

local function OnAuditRequest()
	local rows, seen = {}, {}
	local function Add(fp, fu)
		local k = Key(fp, fu)
		if seen[k] then
			return
		end
		seen[k] = true
		local ok, row = pcall(AuditRow, fp, fu)
		if ok and row ~= nil then
			rows[#rows + 1] = row
		elseif not ok then
			rows[#rows + 1] = { fp = fp, fu = fu, bad = "audit error: " .. tostring(row) }
		end
	end
	for _, k in ipairs(EFV_SortedKeys(m_Badged)) do
		Add(m_Badged[k][1], m_Badged[k][2])
	end
	for pid = 0, 63 do
		pcall(function()
			local pPlayer = Players[pid]
			if pPlayer ~= nil then
				for _, pU in pPlayer:GetUnits():Members() do
					if pU ~= nil then
						Add(pid, pU:GetID())
					end
				end
			end
		end)
	end
	LuaEvents.EFV_BadgeAuditReport(rows)
end

-- Any listed event: poll EFV_Rev / turn. UnitDamageChanged also re-applies a
-- badged flag (the Mutiny N count uses the live damage).
local function OnPoll()
	if m_Off then
		return
	end
	local ok, err = pcall(EFV_RefreshAllBadges, false)
	if not ok then
		EFV_Fail("refresh", err)
	end
end

local function OnUnitDamage(pid, uid)
	if m_Off then
		return
	end
	local ok, err = pcall(function()
		local f = (m_Badged[Key(pid, uid)] ~= nil) and GetUnitFlag(pid, uid) or nil
		if f ~= nil then
			UnitFlag.UpdateReligion(f)
		end
		EFV_RefreshAllBadges(false)
	end)
	if not ok then
		EFV_Fail("damage refresh", err)
	end
end

-- ---------------------------------------------------------------------------
-- Wrappers (installed only when the base loaded and badges are enabled).
-- Subscribe / Unsubscribe are called by the base OnInit / OnShutdown
-- (UnitFlagManager.lua:2077-2110), so overriding the globals here is enough.
-- ---------------------------------------------------------------------------
if m_BaseFile == nil then
	print("[EFV][" .. LOG_TAG .. "] ERROR no base UnitFlagManager could be included")
elseif EFV_UIShared == nil or EFV_Log == nil then
	-- Never let a missing EFV include break the flags: run the base unwrapped.
	print("[EFV][" .. LOG_TAG .. "] ERROR EFV_UIShared not loaded; badges disabled")
elseif EFV_Config.FLAG_FLAG_BADGES and UnitFlag ~= nil and UnitFlag.UpdateReligion ~= nil then
	BASE_UpdateReligion = UnitFlag.UpdateReligion
	local BASE_Subscribe = Subscribe
	local BASE_Unsubscribe = Unsubscribe

	function UnitFlag.UpdateReligion(self)
		BASE_UpdateReligion(self)
		if not m_Off then
			local ok, err = pcall(EFV_ApplyBadge, self)
			if not ok then
				BASE_UpdateReligion(self)
				EFV_Fail("ApplyBadge", err)
			end
		end
	end

	function Subscribe()
		if BASE_Subscribe ~= nil then
			BASE_Subscribe()
		end
		local ok, err = pcall(function()
			for _, name in ipairs(POLL_EVENTS) do
				Events[name].Add(OnPoll)
			end
			Events.UnitDamageChanged.Add(OnUnitDamage)
		end)
		if not ok then
			EFV_Fail("Subscribe", err)
		end
		pcall(function() LuaEvents.EFV_BadgeAuditRequest.Add(OnAuditRequest) end)
	end

	function Unsubscribe()
		if BASE_Unsubscribe ~= nil then
			BASE_Unsubscribe()
		end
		pcall(function()
			for _, name in ipairs(POLL_EVENTS) do
				Events[name].Remove(OnPoll)
			end
			Events.UnitDamageChanged.Remove(OnUnitDamage)
			LuaEvents.EFV_BadgeAuditRequest.Remove(OnAuditRequest)
		end)
	end

	EFV_Log(2, LOG_TAG, "wrapper installed over %s", tostring(m_BaseFile))
else
	EFV_Log(2, LOG_TAG, "badges disabled; base %s runs unwrapped", tostring(m_BaseFile))
end
