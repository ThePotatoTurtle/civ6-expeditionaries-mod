-- ===========================================================================
-- EFV_Util.lua
-- Module:   EFV_Util (load marker table) + global EFV_* helper functions
-- Context:  shared (gameplay + UI), include("EFV_Util").
-- Owner:    WP1.1 (complete). EFV_Log and EFV_IsGameplay date from WP1.0.
--
-- Responsibility (PLAN 2.2): logging, context test, capability probe,
-- deterministic iteration helpers (the ONLY sanctioned pairs() lives in
-- EFV_SortedKeys), player classification, plot keys, nearest city (own loop,
-- DV3), distance bands and fee math (integer, spec 4-5), display helpers.
--
-- Functions are globals named exactly as in PLAN 2.2 (EFV_Log, EFV_Band, ...).
-- PLAN 1.6 also writes "EFV_Util.SortedAlivePlayers()"; the canonical name is
-- the global EFV_SortedAlivePlayers() (see INTERFACES.md, Scaffold notes).
--
-- Every function here returns the same value in gameplay and UI for the same
-- game state (fee shown == fee charged, PLAN 7.2). The only context branch is
-- the Free Cities test in EFV_PlayerKind (G: PlayerManager, UI: player method).
-- WP1.7 moved the display helpers EFV_PlayerName / EFV_CityName here (they
-- were duplicated in EFV_Transit and EFV_Lifecycle).
-- ===========================================================================

if EFV_Util ~= nil and EFV_Util.LOADED == 1 then
	return
end

include("EFV_Config")

EFV_Util = {}

-- Capability memo for EFV_Has: [method] = true/false (per context, because
-- each context is its own Lua state).
local m_HasMemo = {}

-- One-time log keys (fallback notices must not spam Lua.log every refresh).
local m_LoggedOnce = {}

local function LogOnce(key, level, tag, fmt, ...)
	if m_LoggedOnce[key] then
		return
	end
	m_LoggedOnce[key] = true
	EFV_Log(level, tag, fmt, ...)
end

-- ---------------------------------------------------------------------------
-- EFV_Log(level, tag, fmt, ...)
-- Prints "[EFV][T<turn>][<tag>] <message>" when level <= EFV_Config.LOG_LEVEL.
-- Level 1 messages are prefixed "ERROR ". fmt is a string.format pattern when
-- extra args are given (format errors are caught and logged raw); without
-- extra args fmt is printed as is. Never throws.
-- Params:  level number (1 error, 2 event, 3 verbose), tag string (INTERFACES
--          "Log tags"), fmt string, ... format args.
-- Returns: nil.
-- PLAN 2.2, 5.0 (log conventions). APIs: A04, A56.
-- ---------------------------------------------------------------------------
function EFV_Log(level, tag, fmt, ...)
	local maxLevel = 2
	if EFV_Config ~= nil and EFV_Config.LOG_LEVEL ~= nil then
		maxLevel = EFV_Config.LOG_LEVEL
	end
	if level == nil or maxLevel <= 0 or level > maxLevel then
		return
	end
	local msg
	if select("#", ...) > 0 then
		local ok, s = pcall(string.format, tostring(fmt), ...)
		if ok then
			msg = s
		else
			msg = tostring(fmt) .. " [format error: " .. tostring(s) .. "]"
		end
	else
		msg = tostring(fmt)
	end
	if level == 1 then
		msg = "ERROR " .. msg
	end
	local turn = -1
	local okT, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if okT and type(t) == "number" then
		turn = t
	end
	print("[EFV][T" .. tostring(turn) .. "][" .. tostring(tag) .. "] " .. msg)
end

-- ---------------------------------------------------------------------------
-- EFV_IsGameplay() -> bool
-- true in the gameplay context (the UI global is nil there), false in UI.
-- Params:  none.
-- Returns: boolean.
-- PLAN 2.2, 2.3 (context adapters). APIs: A58.
-- ---------------------------------------------------------------------------
function EFV_IsGameplay()
	return UI == nil
end

-- ---------------------------------------------------------------------------
-- EFV_Has(obj, method) -> bool
-- Capability probe: pcall(function() return type(obj[method]) == "function" end),
-- memoised per method name (and context: each context is its own Lua state).
-- Used for calls whose availability in this context is still pending a test
-- (e.g. GetAttacksRemaining in G, T09). A nil obj returns false and is not
-- memoised. The first probe of each method logs its result at level 3.
-- Params:  obj userdata/table (engine object), method string.
-- Returns: boolean.
-- PLAN 2.2. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Has(obj, method)
	if obj == nil or method == nil then
		return false
	end
	-- Memo key includes the context: in the real game each context is its own
	-- Lua state, but a shared state (offline harness) must not leak G results
	-- into UI calls.
	local key = (EFV_IsGameplay() and "G:" or "UI:") .. tostring(method)
	local memo = m_HasMemo[key]
	if memo ~= nil then
		return memo
	end
	local ok, isFn = pcall(function() return type(obj[method]) == "function" end)
	local has = (ok and isFn == true)
	m_HasMemo[key] = has
	EFV_Log(3, "Config", "capability %s=%s (%s)", tostring(method), tostring(has),
		EFV_IsGameplay() and "G" or "UI")
	return has
end

-- ---------------------------------------------------------------------------
-- EFV_SortedKeys(t) -> keys
-- The only sanctioned pairs() in EFV: collects the keys of t and sorts them.
-- Keys of one table are normally all strings or all numbers; mixed tables are
-- still ordered deterministically (numbers before strings, then by value).
-- Params:  t table (nil allowed -> empty result).
-- Returns: dense array of keys, ascending.
-- PLAN 1.6, 2.2. APIs: none.
-- ---------------------------------------------------------------------------
local function KeyLess(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		if ta == "number" then
			return true
		end
		if tb == "number" then
			return false
		end
		return ta < tb
	end
	if ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

function EFV_SortedKeys(t)
	local keys = {}
	if type(t) ~= "table" then
		return keys
	end
	for k, _ in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, KeyLess)
	return keys
end

-- ---------------------------------------------------------------------------
-- EFV_SortedAlivePlayers() -> playerIDs
-- Copy of PlayerManager.GetAliveIDs() sorted ascending (MP-deterministic).
-- Includes every alive player (majors, city-states, Free Cities, barbarians);
-- callers filter with EFV_PlayerKind.
-- Params:  none.
-- Returns: dense array of player IDs ({} if the engine call fails).
-- PLAN 1.6, 2.2. APIs: A43.
-- ---------------------------------------------------------------------------
function EFV_SortedAlivePlayers()
	local ids = {}
	local ok, alive = pcall(function() return PlayerManager.GetAliveIDs() end)
	if not ok or type(alive) ~= "table" then
		EFV_Log(1, "Config", "PlayerManager.GetAliveIDs failed: %s", tostring(alive))
		return ids
	end
	for _, pid in ipairs(alive) do
		ids[#ids + 1] = pid
	end
	table.sort(ids)
	return ids
end

-- ---------------------------------------------------------------------------
-- EFV_PlayerKind(pid) -> kind
-- Classifies a player: "BARBARIAN" (IsBarbarian), "FREE_CITIES", "MAJOR"
-- (IsMajor), else "CITY_STATE" (R3 2.3). Free Cities is tested before IsMajor.
-- Context adapter for Free Cities: G compares with
-- PlayerManager.GetFreeCitiesPlayerID() (A43, G only); UI uses
-- pPlayer:IsFreeCities() (SPIKES 4.2 "Capture decision", RazeCity_Expansion2.lua:67;
-- UI CONFIRMED but not in Appendix A: pcall-guarded, NEW-VERIFY allowlist).
-- Params:  pid number.
-- Returns: string, or nil if the player does not exist.
-- PLAN 2.2. APIs: A42, A43; UI IsFreeCities (SPIKES 4.2).
-- ---------------------------------------------------------------------------
function EFV_PlayerKind(pid)
	if type(pid) ~= "number" or pid < 0 then
		return nil
	end
	local pPlayer = Players[pid]
	if pPlayer == nil then
		return nil
	end
	local okB, isBarb = pcall(function() return pPlayer:IsBarbarian() end)
	if okB and isBarb then
		return "BARBARIAN"
	end
	local isFree = false
	if EFV_IsGameplay() then
		-- EFV:G-ONLY begin
		local okF, freeID = pcall(function() return PlayerManager.GetFreeCitiesPlayerID() end)
		isFree = (okF and freeID ~= nil and freeID == pid)
		-- EFV:G-ONLY end
	else
		-- EFV:UI-ONLY begin
		-- NEW-VERIFY (allowlist): Player:IsFreeCities is UI-confirmed in GS
		-- (SPIKES 4.2) but missing from PLAN Appendix A; probe + pcall.
		if EFV_Has(pPlayer, "IsFreeCities") then
			local okF, v = pcall(function() return pPlayer:IsFreeCities() end)
			isFree = (okF and v == true)
		end
		-- EFV:UI-ONLY end
	end
	if isFree then
		return "FREE_CITIES"
	end
	local okM, isMajor = pcall(function() return pPlayer:IsMajor() end)
	if okM and isMajor then
		return "MAJOR"
	end
	return "CITY_STATE"
end

-- ---------------------------------------------------------------------------
-- EFV_PlotKey(x, y) -> key
-- Map key for plot-keyed tables: "p" .. Map.GetPlot(x, y):GetIndex().
-- Params:  x, y numbers.
-- Returns: string, or nil if the plot does not exist.
-- PLAN 1.3 (EFV_Entrust keys), 2.2. APIs: A10.
-- ---------------------------------------------------------------------------
function EFV_PlotKey(x, y)
	if x == nil or y == nil then
		return nil
	end
	local plot = Map.GetPlot(x, y)
	if plot == nil then
		return nil
	end
	return "p" .. tostring(plot:GetIndex())
end

-- ---------------------------------------------------------------------------
-- EFV_NearestCity(playerID, x, y) -> city, dist
-- Own loop over Players[playerID]:GetCities():Members(): minimum
-- Map.GetPlotDistance(x, y, city), tie-break lowest city:GetID() (DV3; same
-- result in UI and gameplay; FindClosest is NOT used). The result does not
-- depend on the engine's iteration order.
-- Params:  playerID number, x, y numbers.
-- Returns: city object and distance number, or nil if the player has no
--          cities (or does not exist).
-- PLAN 2.2 (DV3). APIs: A45, A46, A08.
-- ---------------------------------------------------------------------------
function EFV_NearestCity(playerID, x, y)
	if playerID == nil or x == nil or y == nil then
		return nil
	end
	local pPlayer = Players[playerID]
	if pPlayer == nil then
		return nil
	end
	local pCities = pPlayer:GetCities()
	if pCities == nil then
		return nil
	end
	local best, bestDist, bestID = nil, nil, nil
	for _, pCity in pCities:Members() do
		if pCity ~= nil then
			local d = Map.GetPlotDistance(x, y, pCity:GetX(), pCity:GetY())
			local cid = pCity:GetID()
			if d ~= nil and d >= 0 then
				if best == nil or d < bestDist or (d == bestDist and cid < bestID) then
					best, bestDist, bestID = pCity, d, cid
				end
			end
		end
	end
	if best == nil then
		return nil
	end
	return best, bestDist
end

-- ---------------------------------------------------------------------------
-- EFV_BandThresholds() -> thresholds
-- Band upper bounds for this map: EFV_Config.Derive().BAND_THRESHOLDS
-- (t_k = max(1, floor(thr_k * W / 84 + 0.5)), spec 4.2). Derive() owns the
-- computation; this function is the accessor used by EFV_Band.
-- Params:  none.
-- Returns: array { t1, t2, t3 } (Derive never returns nil; Standard values
--          are used if the map width cannot be read).
-- PLAN 2.2. APIs: A09 (via Derive).
-- ---------------------------------------------------------------------------
function EFV_BandThresholds()
	local D = EFV_Config.Derive()
	if D ~= nil and D.BAND_THRESHOLDS ~= nil then
		return D.BAND_THRESHOLDS
	end
	return EFV_Config.BAND_THRESHOLDS_STANDARD
end

-- ---------------------------------------------------------------------------
-- EFV_Band(x1, y1, x2, y2) -> band, d
-- d = Map.GetPlotDistance(x1, y1, x2, y2); band = 1 if d <= t1, 2 if d <= t2,
-- 3 if d <= t3, else 4. Always city to city (spec 4.1). transitTurns = band.
-- Params:  x1, y1, x2, y2 numbers.
-- Returns: band number 1..4 and hex distance d number; nil if a coordinate
--          is missing or the distance cannot be computed.
-- PLAN 2.2; spec 4.1-4.3. APIs: A08.
-- ---------------------------------------------------------------------------
function EFV_Band(x1, y1, x2, y2)
	if x1 == nil or y1 == nil or x2 == nil or y2 == nil then
		return nil
	end
	local d = Map.GetPlotDistance(x1, y1, x2, y2)
	if type(d) ~= "number" or d < 0 then
		return nil
	end
	local t = EFV_BandThresholds()
	local band = #t + 1
	for k = 1, #t do
		if d <= t[k] then
			band = k
			break
		end
	end
	return band, d
end

-- Unit row lookup by type string ("UNIT_SWORDSMAN") or index.
local function UnitRow(unitType)
	if unitType == nil then
		return nil
	end
	local ok, row = pcall(function() return GameInfo.Units[unitType] end)
	if ok then
		return row
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_BaseGoldCost(unitType) -> gold
-- GameInfo.Units[unitType].Cost * SPEED_PCT / 100 * PURCHASE_MULTIPLIER
-- (unmodified base, spec 5.1). Display/test helper; may be fractional on
-- non-Standard speeds. The fee uses EFV_Fee (integer math).
-- Params:  unitType string ("UNIT_SWORDSMAN") or unit index.
-- Returns: number, or nil for an unknown type.
-- PLAN 2.2; spec 5.1. APIs: A51.
-- ---------------------------------------------------------------------------
function EFV_BaseGoldCost(unitType)
	local row = UnitRow(unitType)
	if row == nil or row.Cost == nil then
		return nil
	end
	local D = EFV_Config.Derive()
	return row.Cost * D.SPEED_PCT * D.PURCHASE_MULTIPLIER / 100
end

-- ---------------------------------------------------------------------------
-- EFV_HealResourceType(unitType) -> resourceType   (0.6.0, heal-gate warning)
-- The strategic resource the engine's heal gate checks for a unit type
-- (designer ruling "Strategic-resource heal gate"; Session F F4:
-- STRATEGIC_RESOURCE_MINIMUM_FOR_UNIT_HEALING = 1, a unit whose type needs a
-- strategic resource does not heal while its OWNER has none):
-- GameInfo.Units[t].StrategicResource (Swordsman -> RESOURCE_IRON), else
-- Units_XP2[t].ResourceMaintenanceType when ResourceMaintenanceAmount > 0.
-- Params:  unitType string ("UNIT_SWORDSMAN") or unit index.
-- Returns: resource type string, or nil when the type needs none.
-- APIs: A51.
-- ---------------------------------------------------------------------------
function EFV_HealResourceType(unitType)
	local row = UnitRow(unitType)
	if row == nil then
		return nil
	end
	local res = row.StrategicResource
	if type(res) == "string" and res ~= "" then
		return res
	end
	local ok, xp2 = pcall(function() return GameInfo.Units_XP2[row.UnitType] end)
	if ok and xp2 ~= nil and (tonumber(xp2.ResourceMaintenanceAmount) or 0) > 0 then
		local m = xp2.ResourceMaintenanceType
		if type(m) == "string" and m ~= "" then
			return m
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_HealGateBlocked(unitType, ownerID) -> blocked, resourceType
-- true when the unit type needs a strategic resource (EFV_HealResourceType)
-- and ownerID's stock of it is below the engine minimum
-- (EFV_Config.Derive().HEAL_RESOURCE_MIN = GlobalParameters
-- STRATEGIC_RESOURCE_MINIMUM_FOR_UNIT_HEALING, default 1):
-- such a unit does not heal (game rule; VEF adds no scripted healing). Any
-- unreadable value (missing player, resource API unavailable) -> false, so
-- the warning is skipped rather than guessed. pcall-guarded, read-only.
-- Params:  unitType string or index; ownerID player who owns the unit on the
--          map (the recipient for Expeditionary / City-State, the sender for
--          Volunteers).
-- Returns: boolean, resource type string or nil.
-- APIs: A50 (GetResources / GetResourceAmount), A51.
-- ---------------------------------------------------------------------------
function EFV_HealGateBlocked(unitType, ownerID)
	local resType = EFV_HealResourceType(unitType)
	if resType == nil or type(ownerID) ~= "number" or ownerID < 0 or Players[ownerID] == nil then
		return false, resType
	end
	local okS, stock = pcall(function()
		local resRow = GameInfo.Resources[resType]
		if resRow == nil then
			return nil
		end
		return Players[ownerID]:GetResources():GetResourceAmount(resRow.Index)
	end)
	if not okS or type(stock) ~= "number" then
		return false, resType
	end
	local minimum = EFV_Config.Derive().HEAL_RESOURCE_MIN or EFV_Config.DEFAULT_HEAL_RESOURCE_MIN
	return stock < minimum, resType
end

-- ---------------------------------------------------------------------------
-- EFV_Fee(unitType, forceType, band) -> fee
-- Integer math: n = Cost * SPEED_PCT * PURCHASE_MULTIPLIER
-- * (FEE_PCT[forceType] + SURCHARGE_PCT[band]); fee = floor((n + 9999) / 10000)
-- (= ceil(n / 10000), spec 5.2; no float artefacts). Swordsman at Standard
-- (base 360 gold), fees of the 2026-10-04 ruling: EXP/CS 0/18/36/54 (band
-- 1 free: 0 is a valid fee), VOL 36/54/72/90.
-- Params:  unitType string (or index), forceType EFV_Config.FT_*, band 1..4.
-- Returns: integer gold, or nil for an unknown type / force type / band.
-- PLAN 2.2; spec 5.2. APIs: A51.
-- ---------------------------------------------------------------------------
function EFV_Fee(unitType, forceType, band)
	local row = UnitRow(unitType)
	if row == nil or row.Cost == nil then
		return nil
	end
	local D = EFV_Config.Derive()
	local feePct = D.FEE_PCT[forceType]
	local surPct = (band ~= nil) and D.SURCHARGE_PCT[band] or nil
	if feePct == nil or surPct == nil then
		return nil
	end
	local n = row.Cost * D.SPEED_PCT * D.PURCHASE_MULTIPLIER * (feePct + surPct)
	return math.floor((n + 9999) / 10000)
end

-- ---------------------------------------------------------------------------
-- EFV_Duration(forceType) -> turns
-- EXPEDITIONARY -> EXPEDITIONARY_DURATION (20), CS_EXPEDITIONARY ->
-- CS_EXPEDITIONARY_DURATION (10), VOLUNTEER -> nil (no fixed duration).
-- Frozen into record.durationTurns at send.
-- Params:  forceType string.
-- Returns: number or nil.
-- PLAN 1.4 (durationTurns), 2.2. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Duration(forceType)
	if forceType == EFV_Config.FT_EXP then
		return EFV_Config.EXPEDITIONARY_DURATION
	elseif forceType == EFV_Config.FT_CS then
		return EFV_Config.CS_EXPEDITIONARY_DURATION
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_UnitDisplayName(unitType, veteranName) -> name
-- veteranName if non-empty, else Locale.Lookup(GameInfo.Units[unitType].Name);
-- the raw unitType string if the row is unknown.
-- Params:  unitType string, veteranName string or nil.
-- Returns: localized string ("" if both are missing).
-- PLAN 2.2, 2.7 (notification args). APIs: A51, A54.
-- ---------------------------------------------------------------------------
function EFV_UnitDisplayName(unitType, veteranName)
	if type(veteranName) == "string" and veteranName ~= "" then
		return veteranName
	end
	local row = UnitRow(unitType)
	if row ~= nil and row.Name ~= nil then
		local ok, s = pcall(function() return Locale.Lookup(row.Name) end)
		if ok and type(s) == "string" then
			return s
		end
		return tostring(row.Name)
	end
	if unitType == nil then
		return ""
	end
	LogOnce("name:" .. tostring(unitType), 2, "Config", "unknown unit type %s in display name", tostring(unitType))
	return tostring(unitType)
end

-- ---------------------------------------------------------------------------
-- EFV_PlayerName(pid) -> name   (added in WP1.7; shared)
-- Localized civilization short name:
-- Locale.Lookup(PlayerConfigurations[pid]:GetCivilizationShortDescription())
-- (A62: UI CONFIRMED, G NEW-VERIFY [T09+], pcall-guarded). Falls back to
-- Locale.Lookup("LOC_EFV_PLAYER_GENERIC") (no arguments). Callers in the UI
-- that must hide unmet civs use EFV_UI_PlayerName.
-- Params:  pid player ID.
-- Returns: string (never nil or "").
-- PLAN 2.7 (text arguments). APIs: A62, A54.
-- ---------------------------------------------------------------------------
function EFV_PlayerName(pid)
	local ok, s = pcall(function()
		local cfg = PlayerConfigurations[pid]
		return Locale.Lookup(cfg:GetCivilizationShortDescription())
	end)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
	local okG, g = pcall(function() return Locale.Lookup("LOC_EFV_PLAYER_GENERIC") end)
	if okG and type(g) == "string" and g ~= "" then
		return g
	end
	return "Player " .. tostring(pid)
end

-- ---------------------------------------------------------------------------
-- EFV_CityName(pCity) -> name   (added in WP1.7; shared)
-- Locale.Lookup(pCity:GetName()), pcall-guarded.
-- Params:  pCity city object or nil.
-- Returns: string ("" for nil or on error).
-- PLAN 2.7. APIs: A46, A54.
-- ---------------------------------------------------------------------------
function EFV_CityName(pCity)
	if pCity == nil then
		return ""
	end
	local ok, s = pcall(function() return Locale.Lookup(pCity:GetName()) end)
	if ok and type(s) == "string" then
		return s
	end
	return ""
end

-- ---------------------------------------------------------------------------
-- EFV_ForceLabelKey(forceType) -> key
-- "LOC_EFV_FORCE_EXPEDITIONARY" | "LOC_EFV_FORCE_VOLUNTEER" |
-- "LOC_EFV_FORCE_CS_EXPEDITIONARY".
-- Params:  forceType string.
-- Returns: text key string, or nil for an unknown force type.
-- PLAN 2.2, 4.2. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_ForceLabelKey(forceType)
	if forceType == EFV_Config.FT_EXP or forceType == EFV_Config.FT_VOL or forceType == EFV_Config.FT_CS then
		return "LOC_EFV_FORCE_" .. forceType
	end
	return nil
end

-- ===========================================================================
-- Unit identity (Session C item 2; INTERFACES note 23). Added in Phase 2,
-- hardened in 0.5.2 (Session F MUST-FIX 1 and 3, INTERFACES note 30).
-- Session C (SESSION_C_REPORT 6): PlayerUnits:FindID(id) resolves only the
-- slot (low 16 bits of the ID) and returns a DIFFERENT, newer unit of the
-- same owner once the original is gone and its slot is reused. The upper
-- bits are a serial, so the full ID of the new unit differs. Every lookup by
-- a stored ID therefore checks GetID() == storedID (primary check). A record
-- also knows its unit type; the type check is a second, independent guard,
-- but a recipient may upgrade the unit (spec 9.1), so a type reached from the
-- recorded type through GameInfo.UnitUpgrades (a civilization's unique unit
-- counting as the unit it replaces, GameInfo.UnitReplaces) is accepted.
-- Session F (SESSION_F_REPORT 1.3): FindID + GetID() also still return a
-- unit object that is no longer a live unit on the map: a unit killed in
-- combat in the same frame (its damage has reached the maximum), an
-- upgraded unit's old object (rest of the owner's turn) and a levied unit
-- handed to another owner (in the old owner's list at -9999,-9999 until the
-- next turn start). EFV_UnitMatches rejects these as "GONE_*" (see
-- EFV_UnitGoneReason), so every lookup treats them as missing.
-- ===========================================================================

-- [Unit] = UpgradeUnit, built once per context from GameInfo.UnitUpgrades().
local m_UpgradeMap = nil
-- [CivUniqueUnitType] = ReplacesUnitType and [ReplacesUnitType] = { UU, ... }
-- (sorted), built once per context from GameInfo.UnitReplaces() (T30:
-- Warrior -> UNIT_MACEDONIAN_HYPASPIST, which replaces the Swordsman).
local m_BaseOf = nil
local m_Replacers = nil

local function UpgradeMap()
	if m_UpgradeMap ~= nil then
		return m_UpgradeMap
	end
	local map = {}
	local ok, err = pcall(function()
		for row in GameInfo.UnitUpgrades() do
			if type(row.Unit) == "string" and type(row.UpgradeUnit) == "string" then
				map[row.Unit] = row.UpgradeUnit
			end
		end
	end)
	if not ok then
		LogOnce("upgrades", 1, "Config", "GameInfo.UnitUpgrades unreadable: %s (type check accepts only equal types)", tostring(err))
	end
	m_UpgradeMap = map
	return map
end

local function ReplaceMaps()
	if m_BaseOf ~= nil then
		return m_BaseOf, m_Replacers
	end
	local baseOf, replacers = {}, {}
	local ok, err = pcall(function()
		for row in GameInfo.UnitReplaces() do
			local uu, base = row.CivUniqueUnitType, row.ReplacesUnitType
			if type(uu) == "string" and type(base) == "string" then
				baseOf[uu] = base
				replacers[base] = replacers[base] or {}
				table.insert(replacers[base], uu)
			end
		end
	end)
	if not ok then
		LogOnce("replaces", 1, "Config", "GameInfo.UnitReplaces unreadable: %s (unique units are not matched to the units they replace)", tostring(err))
	end
	for _, base in ipairs(EFV_SortedKeys(replacers)) do
		table.sort(replacers[base])
	end
	m_BaseOf, m_Replacers = baseOf, replacers
	return baseOf, replacers
end

-- ---------------------------------------------------------------------------
-- EFV_BaseUnitType(unitType) -> unitType   (added 0.5.2, Session F item 3)
-- The unit a civilization's unique unit replaces (GameInfo.UnitReplaces
-- CivUniqueUnitType -> ReplacesUnitType), or unitType itself.
-- Params:  unitType string.
-- Returns: string (or the argument unchanged when it is not a string).
-- APIs: GameInfo.UnitReplaces (DB table, both contexts).
-- ---------------------------------------------------------------------------
function EFV_BaseUnitType(unitType)
	if type(unitType) ~= "string" then
		return unitType
	end
	local baseOf = ReplaceMaps()
	return baseOf[unitType] or unitType
end

-- The upgrade chain from oldType: every type reached through UnitUpgrades
-- from oldType itself and from the unit it replaces (a unique unit may have
-- its own UnitUpgrades row), at most 16 steps each. Returns an array (step
-- order) of distinct types, oldType and its base excluded.
local function UpgradeChain(oldType)
	local map = UpgradeMap()
	local out, seen = {}, { [oldType] = true }
	local starts = { oldType }
	local base = EFV_BaseUnitType(oldType)
	if base ~= oldType then
		starts[#starts + 1] = base
		seen[base] = true
	end
	for _, t in ipairs(starts) do
		for _ = 1, 16 do
			t = map[t]
			if t == nil or seen[t] then
				break
			end
			seen[t] = true
			out[#out + 1] = t
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_IsUpgradeOf(newType, oldType) -> bool
-- true if newType == oldType, or both are the same unit up to a unique-unit
-- replacement (GameInfo.UnitReplaces: a unique unit counts as the unit it
-- replaces), or newType (or the unit it replaces) is reached from oldType
-- (or the unit it replaces) along GameInfo.UnitUpgrades in at most 16 steps.
-- Civilization-agnostic (identity type check); the upgrade relink uses the
-- stricter, owner-aware EFV_UpgradeTargets.
-- Examples (T30): ("UNIT_MACEDONIAN_HYPASPIST", "UNIT_WARRIOR") -> true;
-- ("UNIT_SWORDSMAN", "UNIT_MACEDONIAN_HYPASPIST") -> true.
-- Params:  newType, oldType unit type strings.
-- Returns: boolean (false if either is not a string).
-- APIs: A51 (GameInfo.UnitUpgrades, CivilopediaPage_Unit.lua:177),
-- GameInfo.UnitReplaces.
-- ---------------------------------------------------------------------------
function EFV_IsUpgradeOf(newType, oldType)
	if type(newType) ~= "string" or type(oldType) ~= "string" then
		return false
	end
	if newType == oldType then
		return true
	end
	local newBase = EFV_BaseUnitType(newType)
	if newBase == EFV_BaseUnitType(oldType) then
		return true
	end
	for _, t in ipairs(UpgradeChain(oldType)) do
		if t == newType or t == newBase then
			return true
		end
	end
	return false
end

-- Trait types of a player's civilization and leader (GameInfo.
-- CivilizationTraits / LeaderTraits). Returns a set, or nil when the
-- player's configuration or the tables are unreadable.
local function OwnerTraits(ownerID)
	local ok, set = pcall(function()
		local cfg = PlayerConfigurations[ownerID]
		if cfg == nil then
			return nil
		end
		local civ, leader = cfg:GetCivilizationTypeName(), cfg:GetLeaderTypeName()
		local s = {}
		for row in GameInfo.CivilizationTraits() do
			if row.CivilizationType == civ then
				s[row.TraitType] = true
			end
		end
		for row in GameInfo.LeaderTraits() do
			if row.LeaderType == leader then
				s[row.TraitType] = true
			end
		end
		return s
	end)
	if ok then
		return set
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_UpgradeTargets(oldType, ownerID) -> { [unitType] = true }
-- (added 0.5.2, Session F item 3; used by the upgrade relink)
-- Every type a unit of oldType can become by upgrading while ownerID owns it:
-- each type on its UnitUpgrades chain (see EFV_IsUpgradeOf), plus every
-- unique unit replacing one of them (GameInfo.UnitReplaces) whose TraitType
-- belongs to ownerID's civilization or leader (CivilizationTraits /
-- LeaderTraits via PlayerConfigurations[ownerID]:GetCivilizationTypeName /
-- GetLeaderTypeName; T30: a Macedonian Warrior upgrades to the Hypaspist).
-- When the owner's traits cannot be read, a replacing unique unit of any
-- civilization is accepted (logged once): the relink also requires the same
-- owner, the same plot and a single candidate. Never contains oldType or
-- the unit oldType replaces (strict upgrade).
-- Params:  oldType unit type string; ownerID player ID (nil: any civ).
-- Returns: set table (empty when oldType is not a string).
-- APIs: A51, GameInfo.UnitReplaces / CivilizationTraits / LeaderTraits,
-- PlayerConfigurations (GameInfo.Units[..].TraitType).
-- ---------------------------------------------------------------------------
function EFV_UpgradeTargets(oldType, ownerID)
	local set = {}
	if type(oldType) ~= "string" then
		return set
	end
	local _, replacers = ReplaceMaps()
	local traits = nil
	if ownerID ~= nil then
		traits = OwnerTraits(ownerID)
		if traits == nil then
			LogOnce("traits:" .. tostring(ownerID), 2, "Config",
				"traits of player %s unreadable: any civilization's unique unit is accepted as an upgrade", tostring(ownerID))
		end
	end
	local oldBase = EFV_BaseUnitType(oldType)
	for _, t in ipairs(UpgradeChain(oldType)) do
		if t ~= oldBase then
			set[t] = true
		end
		for _, uu in ipairs(replacers[t] or {}) do
			if uu ~= oldType then
				local allowed = (traits == nil)
				if not allowed then
					local okR, row = pcall(function() return GameInfo.Units[uu] end)
					allowed = okR and row ~= nil and row.TraitType ~= nil and traits[row.TraitType] == true
				end
				if allowed then
					set[uu] = true
				end
			end
		end
	end
	return set
end

-- ---------------------------------------------------------------------------
-- EFV_UnitGoneReason(pUnit, pid, uid) -> why or nil   (added 0.5.2)
-- Session F 1.3: signals that a unit object returned by FindID is no longer
-- a live unit on the map. Checked in this order:
--   "GONE_OFFMAP" GetX() / GetY() negative or Map.GetPlot(x, y) == nil
--                 (levied unit handed to another owner: -9999,-9999, T28);
--   "GONE_DEAD"   GetDamage() >= GetMaxDamage() (killed in combat in this
--                 frame: 72 -> 100, yet "EXISTS" inside CityConquered, T20);
--   "GONE_PLOT"   the unit is not in its plot's unit list
--                 (Units.GetUnitsInPlot(plot), G and UI confirmed): a removed
--                 or replaced (upgraded) object, if the engine already took
--                 it off the plot (unmeasured; skipped when unreadable).
-- Unit:IsDead / IsDelayedDeath are NOT used: their availability and meaning
-- in G are unproven (no Phase 0 test).
-- Params:  pUnit unit object; pid, uid the IDs it must have.
-- Returns: reason string, or nil when the unit looks alive; "GONE_ERROR" if
--          it is unreadable.
-- APIs: A04 (GetX/GetY/GetDamage/GetMaxDamage), A09, A15.
-- ---------------------------------------------------------------------------
function EFV_UnitGoneReason(pUnit, pid, uid)
	local ok, why = pcall(function()
		local x, y = pUnit:GetX(), pUnit:GetY()
		if type(x) ~= "number" or type(y) ~= "number" or x < 0 or y < 0 then
			return "GONE_OFFMAP"
		end
		local plot = Map.GetPlot(x, y)
		if plot == nil then
			return "GONE_OFFMAP"
		end
		local d, maxD = pUnit:GetDamage(), pUnit:GetMaxDamage()
		if type(d) == "number" and type(maxD) == "number" and maxD > 0 and d >= maxD then
			return "GONE_DEAD"
		end
		local okL, list = pcall(function() return Units.GetUnitsInPlot(plot) end)
		if okL and type(list) == "table" then
			for _, u in ipairs(list) do
				if u ~= nil and u:GetID() == uid and u:GetOwner() == pid then
					return nil
				end
			end
			return "GONE_PLOT"
		end
		return nil
	end)
	if not ok then
		return "GONE_ERROR"
	end
	return why
end

-- ---------------------------------------------------------------------------
-- EFV_UnitMatches(pUnit, pid, uid, expectedType) -> ok, why, typeName
-- Identity check for a unit found by a stored (pid, uid): GetID() == uid
-- ("ID": slot reused by another unit), GetOwner() == pid ("OWNER"), a live
-- unit on the map (EFV_UnitGoneReason: "GONE_OFFMAP" / "GONE_DEAD" /
-- "GONE_PLOT" / "GONE_ERROR", Session F), and, when expectedType is a string,
-- the unit's type equals it or is an upgrade of it ("TYPE", EFV_IsUpgradeOf).
-- "NONE" for a nil unit, "ERROR" if the unit is unreadable.
-- Params:  pUnit unit object or nil; pid, uid stored IDs; expectedType unit
--          type string or nil (no type check).
-- Returns: true, nil, typeName | false, why, typeName-or-nil.
-- Session C item 2; Session F item 1; INTERFACES notes 23, 30. APIs: A04
-- (GetID/GetOwner/GetType), A51 (+ EFV_UnitGoneReason).
-- ---------------------------------------------------------------------------
function EFV_UnitMatches(pUnit, pid, uid, expectedType)
	if pUnit == nil then
		return false, "NONE", nil
	end
	local ok, id, owner, typeName = pcall(function()
		local row = GameInfo.Units[pUnit:GetType()]
		return pUnit:GetID(), pUnit:GetOwner(), row and row.UnitType or nil
	end)
	if not ok then
		return false, "ERROR", nil
	end
	if id ~= uid then
		return false, "ID", typeName
	end
	if owner ~= pid then
		return false, "OWNER", typeName
	end
	local gone = EFV_UnitGoneReason(pUnit, pid, uid)
	if gone ~= nil then
		return false, gone, typeName
	end
	if type(expectedType) == "string" and typeName ~= expectedType
		and not EFV_IsUpgradeOf(typeName, expectedType) then
		return false, "TYPE", typeName
	end
	return true, nil, typeName
end

EFV_Util.LOADED = 1
