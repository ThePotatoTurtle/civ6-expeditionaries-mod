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
-- ReligionIconBacking, always empty on military units) for an EXP / VOL / CS
-- badge with the EFV_UI_StatusTooltip tooltip. No XML, no other overrides.
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

-- Badge per force type. ReligionIcon has IconSize 22, so only atlases with a
-- 22 px size work (Icons_DiploActions, Icons_CityStates, Icons_Stats). The
-- text label (LOC_EFV_BADGE_*) heads the tooltip.
local BADGES = {
	EXPEDITIONARY    = { icon = "ICON_DIPLOACTION_JOINT_WAR",          label = "LOC_EFV_BADGE_EXP" },
	VOLUNTEER        = { icon = "ICON_DIPLOACTION_DECLARE_FRIENDSHIP", label = "LOC_EFV_BADGE_VOL" },
	CS_EXPEDITIONARY = { icon = "ICON_CITYSTATE_MILITARISTIC",         label = "LOC_EFV_BADGE_CS" },
}
local FALLBACK_ICON = "ICON_STRENGTH"   -- used if SetIcon reports a missing icon
local BADGE_COLOR = 0xFFFFFFFF          -- undo a religion colour on a reused instance
local BADGE_STATES = { DEPLOYED = true, GRACE = true, MUTINY = true }
local POLL_EVENTS = { "PlayerTurnActivated", "UnitAddedToMap", "UnitRemovedFromMap",
	"UnitSelectionChanged", "UnitMoveComplete", "LocalPlayerChanged" }

local BASE_UpdateReligion = nil  -- set when the wrapper is installed
local m_Off = false              -- true after the first EFV error: base behaviour
local m_Badged = {}              -- "pid:uid" -> { pid, uid } of flags showing a badge
local m_Sig = nil                -- "rev:turn" of the last full refresh

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
-- / GRACE / MUTINY, put the force-type icon into the religion tag with the
-- tooltip "[EXP] " .. EFV_UI_StatusTooltip(rec) (LOC_EFV_FLAG_TT: force,
-- unit, sender, recipient, state with remaining turns) and show it. Otherwise
-- the base result stands (the base hid or set the tag).
-- PLAN 3.5; spec 14.4; UnitFlagManager.lua:216, :796. APIs: U14, U07.
-- ---------------------------------------------------------------------------
local function EFV_ApplyBadge(flag)
	local pUnit = flag:GetUnit()
	local inst = flag.m_Instance
	if pUnit == nil or inst == nil then
		return
	end
	local pid, uid = pUnit:GetOwner(), pUnit:GetID()
	local rec = EFV_UI_RecordForUnit(pid, uid)
	local badge = (rec ~= nil and BADGE_STATES[rec.state]) and BADGES[rec.forceType] or nil
	if badge == nil or inst.ReligionIcon == nil or inst.ReligionIconBacking == nil then
		m_Badged[Key(pid, uid)] = nil
		return
	end
	if inst.ReligionIcon:SetIcon(badge.icon) == false then
		inst.ReligionIcon:SetIcon(FALLBACK_ICON)
	end
	inst.ReligionIcon:SetColor(BADGE_COLOR)
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
		end)
	end

	EFV_Log(2, LOG_TAG, "wrapper installed over %s", tostring(m_BaseFile))
else
	EFV_Log(2, LOG_TAG, "badges disabled; base %s runs unwrapped", tostring(m_BaseFile))
end
