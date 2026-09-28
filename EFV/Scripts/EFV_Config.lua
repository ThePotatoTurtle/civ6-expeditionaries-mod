-- ===========================================================================
-- EFV_Config.lua
-- Module:   EFV_Config (global table)
-- Context:  shared (gameplay + UI), loaded with include("EFV_Config")
--           (modinfo ImportFiles EFV_Imports).
-- Owner:    WP1.0 (complete). Later packages only tune values or flip flags.
--
-- Responsibility (PLAN 2.1):
--   * every tunable constant of the spec (EFV_mod_spec.md section 3),
--   * values verified in SPIKES.md section 3 (used as fallbacks when the
--     engine cannot be read),
--   * the feature flags of PLAN 1.9 (switch fallbacks without code changes),
--   * shared names: force types, record states, property keys (PLAN 1.3),
--     request names (PLAN 1.5), notification type names (PLAN 4.1),
--   * EFV_Config.Derive(): game-dependent constants computed once per session
--     from GameInfo / GameConfiguration / Map (deterministic on all clients).
--
-- No dependencies. Loading this file has no side effects besides defining
-- EFV_Config; engine calls happen only inside Derive().
-- Lua 5.1 only (PLAN 0): no type annotations, no goto, no bit operators.
-- ===========================================================================

-- Load-once guard: include() re-runs a file each time it is called.
if EFV_Config ~= nil and EFV_Config.LOADED == 1 then
	return
end

EFV_Config = {}

-- Mod version (keep equal to the version in EFV.modinfo LOC_EFV_MOD_TITLE /
-- LOC_EFV_MOD_DESCRIPTION and EFV_Dev.modinfo; logged at load by
-- EFV_Gameplay and EFV_Dev so a Lua.log names the installed build).
EFV_Config.VERSION = "0.6.1-dev"

-- ---------------------------------------------------------------------------
-- Spec section 3 constants (verbatim)
-- ---------------------------------------------------------------------------
EFV_Config.EXPEDITIONARY_DURATION    = 20    -- turns on the map before expiry
EFV_Config.CS_EXPEDITIONARY_DURATION = 10
EFV_Config.VOLUNTEER_MIN_DEPLOYMENT  = 10    -- turns before recall is allowed
EFV_Config.GRACE_TURNS               = 5
EFV_Config.MUTINY_DAMAGE_PER_TURN    = 20    -- HP; 20% of COMBAT_MAX_HIT_POINTS 100 (SPIKES 3)
-- Fees (designer ruling 0.5.2, replaces spec 3's 0.10 / 0.20 / 0.10 and
-- { 0.10, 0.20, 0.30, 0.40 }): total = FEE + SURCHARGE[band] of the base
-- gold cost. Expeditionary and City-State Expeditionary: 0% / 10% / 20% /
-- 30% for bands 1-4 (band 1 is free); Volunteer: 20% / 30% / 40% / 50%.
-- A fee of 0 is valid end to end (EFV_Fee returns 0, no gold check fails,
-- no gold is deducted, the UI shows "Free").
EFV_Config.FEE_EXPEDITIONARY         = 0.00  -- fraction of base gold cost
EFV_Config.FEE_VOLUNTEER             = 0.20
EFV_Config.FEE_CS_EXPEDITIONARY      = 0.00
EFV_Config.SURCHARGE_BY_BAND         = { 0.00, 0.10, 0.20, 0.30 }  -- index = band = transit turns 1..4
EFV_Config.BAND_THRESHOLDS_STANDARD  = { 10, 20, 35 }              -- hex distance upper bounds, bands 1..3, Standard map
EFV_Config.STANDARD_MAP_WIDTH        = 84    -- SPIKES 3 row 1: DB Maps.GridWidth (Standard 84x54)
EFV_Config.SPAWN_SEARCH_MAX_RING     = 5
EFV_Config.SPAWN_MIN_EXITS           = 2     -- minimum passable same-domain neighbours
EFV_Config.SPAWN_CREATE_TRIES        = 8     -- EFV addition (Session D item 3): plots tried per spawn when Create returns nil (RNG pick first, then the rest of its ring and the next rings in index order)

-- Plan additions (PLAN 2.1)
EFV_Config.EXPIRY_WARN_AT            = { 3, 1 }  -- EFV_NOTIF_EXPIRY_SOON when turns left is one of these (spec 14.3)
-- Phase 4 addition: a CS Expeditionary unit taken by a suzerain's levy (or
-- handed back when the levy ends) is re-linked to the unit of the new owner
-- whose original owner is the city-state, of the recorded type (or an
-- upgrade), untracked, agreeing with the snapshot, and at most this many
-- hexes from the last known position, only when that unit is unique
-- (EFV_Lifecycle RelinkLevied; INTERFACES notes 24, 30). 0.5.2: 5 -> 2, the
-- largest shift seen in game (Session F T28).
EFV_Config.LEVY_RELINK_MAX_DIST      = 2
-- Phase 5 addition (WP5.2, D3): a tracked unit that vanished without a combat
-- marker counts as absorbed into a Corps / Army when a non-STANDARD unit of
-- its on-map owner (untracked, or a tracked merge survivor of this or the last
-- turn) stands within (the unit type's BaseMoves + this) hexes of its last
-- snapshot position: it may have moved before merging, and a merge survivor
-- has 0 moves left (Session D T11). Misclassification only changes the
-- message. (Until 0.5.1 the same radius bounded the upgrade relink; since
-- 0.5.2 that relink requires the snapshot's own plot, Session F T30.)
EFV_Config.MERGE_SEARCH_EXTRA        = 1

-- ---------------------------------------------------------------------------
-- Force types (PLAN 2.1) and record states (PLAN 1.4)
-- ---------------------------------------------------------------------------
EFV_Config.FT_EXP = "EXPEDITIONARY"
EFV_Config.FT_VOL = "VOLUNTEER"
EFV_Config.FT_CS  = "CS_EXPEDITIONARY"

-- record.state values. Records are deleted when closed (no CLOSED state).
EFV_Config.ST_OUTBOUND  = "OUTBOUND"
EFV_Config.ST_DEPLOYED  = "DEPLOYED"
EFV_Config.ST_GRACE     = "GRACE"
EFV_Config.ST_MUTINY    = "MUTINY"
EFV_Config.ST_RETURNING = "RETURNING"

-- ---------------------------------------------------------------------------
-- Verified values (SPIKES.md section 3). Used by Derive() only when the
-- engine value cannot be read; Derive() logs an error when it falls back.
-- ---------------------------------------------------------------------------
EFV_Config.DEFAULT_GOLD_PURCHASE_MULTIPLIER     = 2    -- GlobalParameters (SPIKES 3 row 5)
EFV_Config.DEFAULT_GOLD_EQUIVALENT_OTHER_YIELDS = 2    -- GlobalParameters (SPIKES 3 row 5); product = 4
EFV_Config.DEFAULT_SPEED_PCT                    = 100  -- GameSpeeds.CostMultiplier, Standard (SPIKES 3 row 4)
EFV_Config.DEFAULT_HEAL_RESOURCE_MIN            = 1    -- GlobalParameters STRATEGIC_RESOURCE_MINIMUM_FOR_UNIT_HEALING (Session F F4)
-- Reference only (SPIKES 3 row 1): map widths Duel 44, Tiny 60, Small 74,
-- Standard 84, Large 96, Huge 106.

-- ---------------------------------------------------------------------------
-- Store schema and property keys (PLAN 1.3). Only gameplay writes them.
-- ---------------------------------------------------------------------------
EFV_Config.SCHEMA_VERSION = 1  -- current EFV_Schema; migrations in EFV_Records.Init

EFV_Config.PROP = {
	INIT       = "EFV_Init",            -- number 1, first-init guard
	SCHEMA     = "EFV_Schema",          -- number, store schema version
	NEXT_ID    = "EFV_NextID",          -- number, monotonic record ID counter
	RECORD_IDS = "EFV_RecordIDs",       -- dense ascending array of record IDs (the only iteration order)
	RECORDS    = "EFV_Records",         -- map "r"..id -> record
	PENDING    = "EFV_PendingExhaust",  -- dense array of {p=, u=, t=}
	ENTRUST    = "EFV_Entrust",         -- map "p"..plotIndex -> Entrust snapshot
	LAST_TURN  = "EFV_LastTurn",        -- number, last turn the pipeline completed (DV9)
	REV        = "EFV_Rev",             -- number, incremented on every commit that wrote something
}

-- ---------------------------------------------------------------------------
-- Request names (PLAN 1.5): params.OnStart values and GameEvents.<name>.
-- ---------------------------------------------------------------------------
EFV_Config.REQ_SEND    = "EFV_Send"
EFV_Config.REQ_RECALL  = "EFV_Recall"
EFV_Config.REQ_ENTRUST = "EFV_Entrust"

-- ---------------------------------------------------------------------------
-- Notification type names (PLAN 4.1). Must match Data/EFV_Notifications.sql.
-- Text keys are "LOC_" .. name .. "_MESSAGE" / "_SUMMARY" (PLAN 4.2).
-- ---------------------------------------------------------------------------
EFV_Config.NOTIF = {
	DEPARTED        = "EFV_NOTIF_DEPARTED",
	ARRIVED         = "EFV_NOTIF_ARRIVED",
	SPAWN_BLOCKED   = "EFV_NOTIF_SPAWN_BLOCKED",
	EXPIRY_SOON     = "EFV_NOTIF_EXPIRY_SOON",
	GRACE           = "EFV_NOTIF_GRACE",
	MUTINY          = "EFV_NOTIF_MUTINY",
	MUTINY_DEATH    = "EFV_NOTIF_MUTINY_DEATH",
	RETURNING       = "EFV_NOTIF_RETURNING",
	RETURNED        = "EFV_NOTIF_RETURNED",
	REROUTED        = "EFV_NOTIF_REROUTED",
	VOLUNTEER_LAPSE = "EFV_NOTIF_VOLUNTEER_LAPSE",
	ENTRUSTED       = "EFV_NOTIF_ENTRUSTED",
	ACCESS_LAPSE    = "EFV_NOTIF_ACCESS_LAPSE",
	UNIT_LOST       = "EFV_NOTIF_UNIT_LOST",
	MERGED          = "EFV_NOTIF_MERGED",
	REVERTED        = "EFV_NOTIF_REVERTED",
	REQUEST_FAILED  = "EFV_NOTIF_REQUEST_FAILED",
	-- Added by the orchestrator call (DECISIONS "Designer answers", 2026-09-28):
	-- a reversible Volunteer lapse was cancelled (sender, and recipient if human).
	LAPSE_CANCELLED = "EFV_NOTIF_LAPSE_CANCELLED",
	-- Designer ruling "Lapsed Volunteers on valid land" (0.5.1, INTERFACES
	-- note 29): a lapsed Volunteer on the sender's or the recipient's land is
	-- paused; sent once to the sender when a pause begins ("recall it now").
	LAPSE_PAUSED    = "EFV_NOTIF_LAPSE_PAUSED",
}

-- ---------------------------------------------------------------------------
-- Feature flags (PLAN 1.9). Default values; the comment names the Phase 0
-- test whose result flips the flag.
-- ---------------------------------------------------------------------------
EFV_Config.FLAG_PERSIST_AS_STRING            = false                  -- T03 fails -> true (EFV_Records.Encode/Decode)
EFV_Config.FLAG_CREATE_API                   = "CREATE"               -- "CREATE" (A18) | "INITUNIT" (A19); T05
EFV_Config.FLAG_REMOVE_API                   = "DESTROY"              -- "DESTROY" (A20) | "KILL" (A21); T07
EFV_Config.FLAG_XP_CLAMP                     = true                   -- ON since 0.5.2 (Session F T08: the level cannot be restored, XP caps at the level-1 threshold and the AI re-promoted at once; restore promotions first, then XP clamped to next - 1)
EFV_Config.FLAG_RESOURCE_MAINTENANCE         = true                   -- T14 fails -> false (gold-only, documented)
EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB         = "DEALS"                -- "DEALS" (G deal scan, A40; UI HasOpenBordersFrom, A39) | "OFF" (allies/teammates only). Session A T09: HasOpenBordersFrom is nil in G; T19 proves the deal scan
EFV_Config.FLAG_ENTRUST_KEEP_FIRST           = true                   -- D5; T16 may allow false
EFV_Config.FLAG_ENTRUST_TRANSFER_TYPE        = "BY_GIFT"              -- key into CityTransferTypes; D1/D5; T17 optional
EFV_Config.FLAG_ENTRUST_UI                   = "INJECT"               -- "INJECT" (E1) | "REPLACE" (E2, also swaps modinfo actions); T24
EFV_Config.FLAG_UNIT_ACTIONS_STACK           = "StandardActionsStack" -- T23 fails -> "SecondaryActionsStack"
EFV_Config.FLAG_FLAG_BADGES                  = true                   -- D8: wrapper conflicts -> false (and drop the ReplaceUIScript action)
EFV_Config.FLAG_DEFEAT_HINT                  = true                   -- DV13; Phase 8 review
EFV_Config.FLAG_SPAWN_EXCLUDE_NATURAL_WONDER = true                   -- design choice (SPIKES 3 row 11)
EFV_Config.FLAG_UPGRADE_RELINK               = true                   -- ON since 0.5.2 (Session F T30: an upgrade creates a new unit ID on the same plot; relink only a provable match, unique units included)
EFV_Config.LOG_LEVEL                         = 2                      -- 0 off, 1 errors, 2 events, 3 verbose (stubs log at 3)

-- Phase gates (PLAN 5.1-5.4): which features are released. The single switch
-- for both contexts: EFV_Rules prepends NOT_IMPLEMENTED to every send of an
-- unreleased force type (so gameplay rejects forged requests too) and
-- EFV_UnitActions shows only released buttons. Phase 3 released VOLUNTEER
-- and RECALL, WP4.1 released CS_EXPEDITIONARY. Setting a type back to false
-- is the kill switch for it (button hidden, forged sends rejected).
EFV_Config.FLAG_RELEASED = {
	EXPEDITIONARY    = true,   -- Phase 1
	VOLUNTEER        = true,   -- Phase 3 (WP3.1 / WP3.3, released 2026-09-28; in-game P3.x pending)
	CS_EXPEDITIONARY = true,   -- Phase 4 (WP4.1, released 2026-09-28; in-game P4.x pending)
	RECALL           = true,   -- Phase 3 (WP3.2 / WP3.3, released 2026-09-28)
}

-- ---------------------------------------------------------------------------
-- Compatibility (PLAN 3.5, R4 4.3). Mod IDs for Modding.IsModActive (U14).
-- ---------------------------------------------------------------------------
EFV_Config.CQUI_MOD_ID            = "1d44b5e7-753e-405b-af24-5ee634ec8a01"  -- CQUI.modinfo:2
EFV_Config.BUILDER_CHARGES_MOD_ID = "c6477d9f-6bad-4d24-9e76-49cda4f0a966"  -- WS\2409116842\BetterBuilderChargesTracking.modinfo

-- ===========================================================================
-- Derived constants
-- ===========================================================================
local m_Derived = nil

-- Log through EFV_Log when EFV_Util is loaded (always the case at runtime,
-- because Derive is called lazily); plain print otherwise.
local function ConfigLog(level, msg)
	if EFV_Log ~= nil then
		EFV_Log(level, "Config", "%s", msg)
	elseif level <= EFV_Config.LOG_LEVEL then
		print("[EFV][Config] " .. msg)
	end
end

local function ToPct(v)
	return math.floor(v * 100 + 0.5)
end

-- GameInfo.GlobalParameters[name].Value is TEXT in the DB (A60).
local function ReadGlobalParameter(name, default)
	local ok, v = pcall(function()
		local row = GameInfo.GlobalParameters[name]
		if row == nil then
			return nil
		end
		return tonumber(row.Value)
	end)
	if ok and v ~= nil then
		return v
	end
	ConfigLog(1, "GlobalParameters." .. name .. " unavailable; using verified default " .. tostring(default))
	return default
end

-- Game speed cost multiplier as an integer percent (A52, A51; PLAN 2.1).
-- Primary: GameConfiguration.GetGameSpeedType() (G LIKELY, T09).
-- Fallback: GameConfiguration.GetValue("GAMESPEED_TYPE") (NEW-VERIFY, T09+).
-- Last resort: 100 (Standard), logged as an error (known limitation).
local function ReadSpeedPct()
	local ok, pct = pcall(function()
		local row = GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()]
		if row == nil then
			return nil
		end
		return tonumber(row.CostMultiplier)
	end)
	if ok and pct ~= nil then
		return pct, "GetGameSpeedType"
	end
	ok, pct = pcall(function()
		local row = GameInfo.GameSpeeds[GameConfiguration.GetValue("GAMESPEED_TYPE")]
		if row == nil then
			return nil
		end
		return tonumber(row.CostMultiplier)
	end)
	if ok and pct ~= nil then
		return pct, "GetValue"
	end
	ConfigLog(1, "game speed unavailable; fee assumes Standard speed (" .. tostring(EFV_Config.DEFAULT_SPEED_PCT) .. ")")
	return EFV_Config.DEFAULT_SPEED_PCT, "DEFAULT"
end

-- Band thresholds for this map (spec 4.2, PLAN 2.2):
-- t_k = max(1, floor(thr_k * W / STANDARD_MAP_WIDTH + 0.5)).
local function ComputeBandThresholds()
	local ok, w = pcall(function()
		return (Map.GetGridSize())  -- first return value = width (SPIKES 3 row 3)
	end)
	local width = EFV_Config.STANDARD_MAP_WIDTH
	local fromMap = false
	if ok and type(w) == "number" and w > 0 then
		width = w
		fromMap = true
	else
		ConfigLog(1, "Map.GetGridSize unavailable; band thresholds assume a Standard map")
	end
	local t = {}
	for k = 1, #EFV_Config.BAND_THRESHOLDS_STANDARD do
		local thr = EFV_Config.BAND_THRESHOLDS_STANDARD[k]
		t[k] = math.max(1, math.floor(thr * width / EFV_Config.STANDARD_MAP_WIDTH + 0.5))
	end
	return t, width, fromMap
end

-- ---------------------------------------------------------------------------
-- EFV_Config.Derive() -> D
-- Computes the game-dependent constants on first use and memoises them for
-- the session (scripts re-run on every load, so the memo never outlives a
-- game). Uses GameInfo / GameConfiguration / Map only, so the result is
-- identical on every client and in both contexts (UI fee == charged fee).
-- The result is not memoised while the map width could not be read.
-- Params:  none.
-- Returns: D (table, never nil):
--   D.GOLD_PURCHASE_MULTIPLIER     number (GlobalParameters, default 2)
--   D.GOLD_EQUIVALENT_OTHER_YIELDS number (GlobalParameters, default 2)
--   D.PURCHASE_MULTIPLIER          number = product of the two (4; SPIKES 3 row 5)
--   D.SPEED_PCT                    integer percent (GameSpeeds.CostMultiplier; 100 = Standard)
--   D.SPEED_SOURCE                 "GetGameSpeedType" | "GetValue" | "DEFAULT"
--   D.FEE_PCT                      { EXPEDITIONARY = 0, VOLUNTEER = 20, CS_EXPEDITIONARY = 0 }
--   D.SURCHARGE_PCT                { 0, 10, 20, 30 } (index = band)
--   D.MAP_WIDTH                    number (Map.GetGridSize width; 84 if unreadable)
--   D.BAND_THRESHOLDS              { t1, t2, t3 } for this map (spec 4.2)
--   D.HEAL_RESOURCE_MIN            number (GlobalParameters STRATEGIC_RESOURCE_
--                                  MINIMUM_FOR_UNIT_HEALING, default 1; 0.6.0
--                                  heal-gate warning, EFV_HealGateBlocked)
-- PLAN 2.1, 2.2; SPIKES 3 rows 1, 3, 4, 5. APIs: A09, A51, A52, A60.
-- ---------------------------------------------------------------------------
function EFV_Config.Derive()
	if m_Derived ~= nil then
		return m_Derived
	end
	local D = {}

	local gpm = ReadGlobalParameter("GOLD_PURCHASE_MULTIPLIER", EFV_Config.DEFAULT_GOLD_PURCHASE_MULTIPLIER)
	local geo = ReadGlobalParameter("GOLD_EQUIVALENT_OTHER_YIELDS", EFV_Config.DEFAULT_GOLD_EQUIVALENT_OTHER_YIELDS)
	D.GOLD_PURCHASE_MULTIPLIER     = gpm
	D.GOLD_EQUIVALENT_OTHER_YIELDS = geo
	D.PURCHASE_MULTIPLIER          = gpm * geo
	D.HEAL_RESOURCE_MIN            = ReadGlobalParameter("STRATEGIC_RESOURCE_MINIMUM_FOR_UNIT_HEALING",
		EFV_Config.DEFAULT_HEAL_RESOURCE_MIN)

	local speedPct, speedSource = ReadSpeedPct()
	D.SPEED_PCT    = speedPct
	D.SPEED_SOURCE = speedSource

	D.FEE_PCT = {}
	D.FEE_PCT[EFV_Config.FT_EXP] = ToPct(EFV_Config.FEE_EXPEDITIONARY)
	D.FEE_PCT[EFV_Config.FT_VOL] = ToPct(EFV_Config.FEE_VOLUNTEER)
	D.FEE_PCT[EFV_Config.FT_CS]  = ToPct(EFV_Config.FEE_CS_EXPEDITIONARY)

	D.SURCHARGE_PCT = {}
	for band = 1, #EFV_Config.SURCHARGE_BY_BAND do
		D.SURCHARGE_PCT[band] = ToPct(EFV_Config.SURCHARGE_BY_BAND[band])
	end

	local thresholds, width, fromMap = ComputeBandThresholds()
	D.MAP_WIDTH       = width
	D.BAND_THRESHOLDS = thresholds

	ConfigLog(2, "derived PM=" .. tostring(D.PURCHASE_MULTIPLIER)
		.. " speedPct=" .. tostring(D.SPEED_PCT) .. " (" .. tostring(D.SPEED_SOURCE) .. ")"
		.. " mapWidth=" .. tostring(D.MAP_WIDTH)
		.. " bands=" .. tostring(thresholds[1]) .. "/" .. tostring(thresholds[2]) .. "/" .. tostring(thresholds[3]))

	if fromMap then
		m_Derived = D
	end
	return D
end

EFV_Config.LOADED = 1
