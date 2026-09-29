-- ===========================================================================
-- EFV_UIShared.lua
-- Module:   EFV_UIShared (load marker table) + global EFV_UI_* functions
-- Context:  UI only, include("EFV_UIShared") from every EFV UI context and
--           from the UnitFlagManager wrapper (modinfo ImportFiles EFV_Imports).
-- Owner:    WP1.5 (Phase 2/7 extend).
--
-- Responsibility (PLAN 3.1): read-only access to the gameplay store through
-- Game:GetProperty (decoding when FLAG_PERSIST_AS_STRING), record queries for
-- the local player, text builders (state text, reason text, status tooltip)
-- and the single request sender (UI.RequestPlayerOperation EXECUTE_SCRIPT).
-- The UI never mutates game state and never uses ExposedMembers (PLAN 1.2).
--
-- UI store shape (INTERFACES "UI store"): { ids, recs, entrust, rev }.
-- EFV_Records is included only for the pure Decode function (string
-- persistence fallback); the UI calls no other EFV_Records function.
--
-- Added helpers (INTERFACES 3.12, WP1.5 additions accepted in WP1.7):
-- EFV_UI_PlayerName, EFV_UI_CityName, EFV_UI_DurationText,
-- EFV_UI_RowReasonCtx, EFV_UIShared.NAME_REASONS. The name helpers wrap the
-- shared EFV_PlayerName / EFV_CityName (EFV_Util).
-- WP7.2 (tracker panel): EFV_UI_TrackerRows, EFV_UI_TrackerState,
-- EFV_UI_TrackerTurns, EFV_UI_TrackerPlace, EFV_UI_TrackerCounts (pure
-- functions over the UI store; the panel only renders their rows).
-- 0.7.1 (tracker column sort): EFV_UI_TRACKER_SORT_COLS,
-- EFV_UI_TrackerSortClick, EFV_UI_TrackerSortRows, EFV_UI_TrackerSortMark.
-- 0.7.3: EFV_UI_TrackerSortHint (the "sortable" mark on unsorted headers).
-- 0.5.2 (fee ruling, band 1 free): EFV_UI_FeeText.
-- 0.7 (INTERFACES note 33): EFV_UI_PickerRowText, EFV_UI_PickerHeaderText
-- (one formatted line per picker row; EFV_UI_FeeCell removed);
-- EFV_UI_RowReasonCtx names the land owner for WRONG_TERRITORY.
-- Phase 6 (Entrust, WP6.2): EFV_UI_EntrustState, EFV_UI_EntrustReasonsText
-- (the capture popup's buttons, from the gameplay snapshot and the shared
-- Entrust rules).
--
-- Text-key argument contract used here (for WP1.6):
--   LOC_EFV_STATE_OUTBOUND / _DEPLOYED / _DEPLOYED_VOLUNTEER / _GRACE /
--     _MUTINY / _RETURNING               {1_Num} turns
--   LOC_EFV_STATE_DEPLOYED_EXPIRED, _DEPLOYED_VOLUNTEER_READY, _BLOCKED  none
--   LOC_EFV_LAPSE_WAR / _PARTNER         none (appended to lapsed VOL state)
--   LOC_EFV_STATE_GRACE_PAUSED / _MUTINY_PAUSED {1_Num} (paused lapse, 0.5.1)
--   LOC_EFV_DURATION_TURNS {1_Num}; LOC_EFV_DURATION_UNLIMITED none
--   LOC_EFV_FLAG_TT {1_Force} {2_Unit} {3_Sender} {4_Recipient} {5_State}
--   LOC_EFV_REASON_GOLD / _FEE_CHANGED {1_Num} = fee; LOC_EFV_REASON_NOT_PARTNER /
--     _VOL_NEEDS_ACCESS / _CS_NOT_MET / _AT_WAR_WITH_RECIPIENT /
--     _NO_COMMON_WAR {1_Name} (one civ name or a comma list);
--     LOC_EFV_REASON_WRONG_TERRITORY {1_Name} = land owner (row.landOwnerID);
--     LOC_EFV_REASON_RECALL_MIN_TURNS {1_Num}; LOC_EFV_REASON_ENTRUST_NO_PARTNER
--     {1_Name} = former owner; all other reasons: none.
--   LOC_EFV_PICKER_HEADER / _HEADER_CS none; LOC_EFV_PICKER_TILES {1_Num};
--     LOC_EFV_PICKER_FEE {1_Num} (fee > 0; 0 -> LOC_EFV_FEE_FREE).
--   LOC_EFV_ENTRUST_NOT_AT_WAR {1_List} partners {2_Name} former owner;
--     LOC_EFV_ENTRUST_NO_PARTNERS none.
--   LOC_EFV_TRACKER_ST_* none; LOC_EFV_TRACKER_ST_LAPSE {1_State};
--     LOC_EFV_TRACKER_ST_LAPSE_PAUSED {1_State} {2_Num} (0.5.1);
--     LOC_EFV_TRACKER_TO / _FROM {1_Civ}; LOC_EFV_TRACKER_TT_TRANSIT {1_City};
--     LOC_EFV_TRACKER_TT_SELECT / _LOOK none;
--     LOC_EFV_TRACKER_SUMMARY {1_Num} sent {2_Num} received {3_Num} alerts.
-- ===========================================================================

if EFV_UIShared ~= nil and EFV_UIShared.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")

EFV_UIShared = {}

local LOG_TAG_REQ = "UIRequest"

-- Reason codes whose text names the recipient ({1_Name}).
local NAME_REASON_LIST = EFV_Rules.NAME_REASON_CODES
local NAME_REASONS = {}
for _, code in ipairs(NAME_REASON_LIST) do
	NAME_REASONS[code] = true
end
EFV_UIShared.NAME_REASONS = NAME_REASONS

-- Store cache: Game:GetProperty returns fresh tables on every call, and the
-- flag wrapper asks once per unit flag. Gameplay bumps EFV_Rev on every
-- commit that wrote something (INTERFACES note 16), so (rev, turn) identify
-- the content. Callers must treat the returned store as read-only.
local m_Cache = nil      -- { rev, turn, store, byUnit }

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------
local function ReadProp(key)
	local ok, v = pcall(function()
		return Game:GetProperty(key)
	end)
	if not ok then
		EFV_Log(1, "UIShared", "GetProperty(%s) failed: %s", tostring(key), tostring(v))
		return nil
	end
	if type(v) == "string" then
		-- FLAG_PERSIST_AS_STRING (PLAN 1.3); decode even if the flag is off so
		-- a save written with the flag on still reads.
		local okD, dv = pcall(EFV_Records.Decode, v)
		if okD then
			return dv
		end
		EFV_Log(1, "UIShared", "Decode(%s) failed: %s", tostring(key), tostring(dv))
		return nil
	end
	return v
end

local function CurrentTurn()
	local ok, t = pcall(function()
		return Game.GetCurrentGameTurn()
	end)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

local function SafeLookup(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function()
		return Locale.Lookup(key, unpack(args, 1, n))
	end)
	if ok and type(s) == "string" then
		return s
	end
	return tostring(key)
end

local function LocalPlayer()
	local ok, pid = pcall(function()
		return Game.GetLocalPlayer()
	end)
	if ok and type(pid) == "number" then
		return pid
	end
	return -1
end

-- ---------------------------------------------------------------------------
-- EFV_UI_ReadStore() -> uiStore
-- Reads EFV_RecordIDs, EFV_Records, EFV_Entrust, EFV_VetJobs (0.7), EFV_Rev with
-- Game:GetProperty (A06 UI), decoding with EFV_Records.Decode when the value
-- is a string (FLAG_PERSIST_AS_STRING). Missing keys -> empty tables / 0.
-- Cached per (EFV_Rev, turn); the result is shared and read-only.
-- Params:  none.
-- Returns: { ids = {..}, recs = { ["r"..id] = rec }, entrust = { ["p"..idx] =
--          snap }, vet = { job.. } (0.7, INTERFACES note 33; missing -> {}),
--          rev = n } (never nil).
-- PLAN 3.1, 1.3. APIs: A06, A04.
-- ---------------------------------------------------------------------------
function EFV_UI_ReadStore()
	local rev = ReadProp(EFV_Config.PROP.REV)
	if type(rev) ~= "number" then
		rev = 0
	end
	local turn = CurrentTurn()
	if m_Cache ~= nil and m_Cache.rev == rev and m_Cache.turn == turn then
		return m_Cache.store
	end

	local ids = ReadProp(EFV_Config.PROP.RECORD_IDS)
	local recs = ReadProp(EFV_Config.PROP.RECORDS)
	local entrust = ReadProp(EFV_Config.PROP.ENTRUST)
	local vet = ReadProp(EFV_Config.PROP.VET)
	if type(ids) ~= "table" then ids = {} end
	if type(recs) ~= "table" then recs = {} end
	if type(entrust) ~= "table" then entrust = {} end
	if type(vet) ~= "table" then vet = {} end

	local store = { ids = ids, recs = recs, entrust = entrust, vet = vet, rev = rev }
	m_Cache = { rev = rev, turn = turn, store = store, byUnit = nil }
	EFV_Log(3, "UIShared", "store read rev=%d ids=%d", rev, #ids)
	return store
end

-- Records of the store in id order (skips ids without a record).
local function StoreRecords(store)
	local out = {}
	for _, id in ipairs(store.ids) do
		local rec = store.recs["r" .. tostring(id)]
		if type(rec) == "table" then
			out[#out + 1] = rec
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_UI_RecordForUnit(pid, uid) -> rec
-- The record whose onMapPlayerID == pid and onMapUnitID == uid.
-- Params:  pid player ID, uid unit ID.
-- Returns: rec or nil.
-- PLAN 3.1. APIs: A06 (via EFV_UI_ReadStore).
-- ---------------------------------------------------------------------------
function EFV_UI_RecordForUnit(pid, uid)
	if pid == nil or uid == nil then
		return nil
	end
	EFV_UI_ReadStore()
	if m_Cache.byUnit == nil then
		local idx = {}
		for _, rec in ipairs(StoreRecords(m_Cache.store)) do
			if rec.onMapPlayerID ~= nil and rec.onMapUnitID ~= nil then
				idx[tostring(rec.onMapPlayerID) .. ":" .. tostring(rec.onMapUnitID)] = rec
			end
		end
		m_Cache.byUnit = idx
	end
	return m_Cache.byUnit[tostring(pid) .. ":" .. tostring(uid)]
end

-- ---------------------------------------------------------------------------
-- EFV_UI_RecordsFor(localID) -> recs
-- Records where senderID == localID or recipientID == localID, ascending id.
-- Params:  localID player ID (Game.GetLocalPlayer()).
-- Returns: dense array of records.
-- PLAN 3.1, 3.6. APIs: A06.
-- ---------------------------------------------------------------------------
function EFV_UI_RecordsFor(localID)
	local out = {}
	if localID == nil or localID < 0 then
		return out
	end
	for _, rec in ipairs(StoreRecords(EFV_UI_ReadStore())) do
		if rec.senderID == localID or rec.recipientID == localID then
			out[#out + 1] = rec
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_UI_AlertRecords(localID) -> recs
-- Subset of EFV_UI_RecordsFor(localID) in state GRACE or MUTINY (D9 alert
-- state), ascending id.
-- Params:  localID player ID.
-- Returns: dense array of records.
-- PLAN 3.1, 3.6; D9. APIs: A06.
-- ---------------------------------------------------------------------------
function EFV_UI_AlertRecords(localID)
	local out = {}
	for _, rec in ipairs(EFV_UI_RecordsFor(localID)) do
		if rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY then
			out[#out + 1] = rec
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackedUnit(rec) -> pUnit   (added Phase 2, Session C item 2)
-- The record's on-map unit, UnitManager.GetUnit(onMapPlayerID, onMapUnitID),
-- identity-checked with EFV_UnitMatches (GetID / owner / type or an upgrade
-- of rec.unitType): a unit found in a reused slot counts as missing.
-- Params:  rec record (UI store; fields may be nil).
-- Returns: unit object or nil.
-- APIs: A17 (UI), A04.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackedUnit(rec)
	if type(rec) ~= "table" or type(rec.onMapPlayerID) ~= "number" or type(rec.onMapUnitID) ~= "number" then
		return nil
	end
	local ok, pUnit = pcall(function()
		return UnitManager.GetUnit(rec.onMapPlayerID, rec.onMapUnitID)
	end)
	if not ok or pUnit == nil then
		return nil
	end
	if not EFV_UnitMatches(pUnit, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType) then
		return nil
	end
	return pUnit
end

-- ---------------------------------------------------------------------------
-- EFV_UI_PlayerName(pid) -> text   (added helper)
-- Localized civilization short name; LOC_EFV_PLAYER_GENERIC when unknown or
-- not met by the local player.
-- APIs: A62 (UI C), A41, U02, U17.
-- ---------------------------------------------------------------------------
function EFV_UI_PlayerName(pid)
	if type(pid) ~= "number" or pid < 0 then
		return SafeLookup("LOC_EFV_PLAYER_GENERIC")
	end
	local localID = LocalPlayer()
	local okMet, met = pcall(function()
		if localID >= 0 and localID ~= pid then
			local pLocal = Players[localID]
			if pLocal ~= nil and not pLocal:GetDiplomacy():HasMet(pid) then
				return false
			end
		end
		return true
	end)
	if okMet and met == false then
		return SafeLookup("LOC_EFV_PLAYER_GENERIC")
	end
	return EFV_PlayerName(pid)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_CityName(pid, cityID, x, y) -> text   (added helper)
-- Localized name of city cityID of pid, else of the city at (x, y), else
-- "(x,y)".
-- APIs: A45, A44, A46, U17.
-- ---------------------------------------------------------------------------
function EFV_UI_CityName(pid, cityID, x, y)
	local ok, name = pcall(function()
		local pCity = nil
		if type(pid) == "number" and pid >= 0 and type(cityID) == "number" and Players[pid] ~= nil then
			pCity = Players[pid]:GetCities():FindID(cityID)
		end
		if pCity == nil and type(x) == "number" and type(y) == "number" then
			pCity = CityManager.GetCityAt(x, y)
		end
		if pCity == nil then
			return nil
		end
		return EFV_CityName(pCity)
	end)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	return "(" .. tostring(x) .. "," .. tostring(y) .. ")"
end

-- ---------------------------------------------------------------------------
-- EFV_UI_DurationText(turns) -> text   (added helper)
-- nil -> LOC_EFV_DURATION_UNLIMITED (Volunteers); n -> LOC_EFV_DURATION_TURNS.
-- ---------------------------------------------------------------------------
function EFV_UI_DurationText(turns)
	if type(turns) ~= "number" then
		return SafeLookup("LOC_EFV_DURATION_UNLIMITED")
	end
	return SafeLookup("LOC_EFV_DURATION_TURNS", turns)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_FeeText(fee) -> text   (added 0.5.2, fee ruling: band 1 is free for
-- Expeditionary and City-State Expeditionary)
-- 0 -> LOC_EFV_FEE_FREE ("Free"); n > 0 -> LOC_EFV_FEE_GOLD {1_Num}
-- ("n [ICON_Gold] Gold"); nil -> "-". Used by the confirm dialog.
-- ---------------------------------------------------------------------------
function EFV_UI_FeeText(fee)
	if type(fee) ~= "number" then
		return "-"
	end
	if fee <= 0 then
		return SafeLookup("LOC_EFV_FEE_FREE")
	end
	return SafeLookup("LOC_EFV_FEE_GOLD", fee)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_PickerRowText(row, forceType) -> text   (added 0.7, note 33)
-- One destination row as a single line, parts joined with " - ":
-- recipient name; the city name unless it equals the recipient name (a
-- city-state's city usually does); then, with row.calc: distance
-- (LOC_EFV_PICKER_TILES), travel time (EFV_UI_DurationText(transit)), fee
-- (0 -> LOC_EFV_FEE_FREE, else LOC_EFV_PICKER_FEE) and service
-- (EFV_UI_DurationText(duration)); without calc only the service of the
-- force type (EFV_Duration). E.g. "Rome - Roma - 34 tiles - 4 turns -
-- 108 [ICON_Gold] - 20 turns".
-- Params:  row destination row, forceType EFV_Config.FT_*.
-- Returns: string.
-- APIs: U17 (+ name helpers).
-- ---------------------------------------------------------------------------
function EFV_UI_PickerRowText(row, forceType)
	if type(row) ~= "table" then
		return ""
	end
	local name = EFV_UI_PlayerName(row.recipientID)
	local parts = { name }
	local city = EFV_UI_CityName(row.recipientID, row.cityID, row.destX, row.destY)
	if city ~= name then
		parts[#parts + 1] = city
	end
	local calc = row.calc
	if type(calc) == "table" then
		parts[#parts + 1] = SafeLookup("LOC_EFV_PICKER_TILES", calc.distance or 0)
		parts[#parts + 1] = EFV_UI_DurationText(calc.transit or 0)
		if type(calc.fee) ~= "number" then
			parts[#parts + 1] = "-"
		elseif calc.fee <= 0 then
			parts[#parts + 1] = SafeLookup("LOC_EFV_FEE_FREE")
		else
			parts[#parts + 1] = SafeLookup("LOC_EFV_PICKER_FEE", calc.fee)
		end
		parts[#parts + 1] = EFV_UI_DurationText(calc.duration)
	else
		local okD, d = pcall(EFV_Duration, forceType)
		parts[#parts + 1] = EFV_UI_DurationText(okD and d or nil)
	end
	return table.concat(parts, " - ")
end

-- ---------------------------------------------------------------------------
-- EFV_UI_PickerHeaderText(forceType) -> text   (added 0.7, note 33)
-- The picker's header line: LOC_EFV_PICKER_HEADER_CS for City-State sends
-- (no separate city part), else LOC_EFV_PICKER_HEADER.
-- ---------------------------------------------------------------------------
function EFV_UI_PickerHeaderText(forceType)
	if forceType == EFV_Config.FT_CS then
		return SafeLookup("LOC_EFV_PICKER_HEADER_CS")
	end
	return SafeLookup("LOC_EFV_PICKER_HEADER")
end

-- ---------------------------------------------------------------------------
-- EFV_UI_RowReasonCtx(row, senderID) -> ctx   (added helper)
-- Lookup arguments for the reason codes of one destination row:
-- GOLD / FEE_CHANGED = { fee }, recipient-named codes = { civ name },
-- WRONG_TERRITORY = { land owner's name } (row.landOwnerID, 0.7).
-- APIs: none (senderID kept for signature compatibility).
-- ---------------------------------------------------------------------------
function EFV_UI_RowReasonCtx(row, senderID)
	local ctx = {}
	if row == nil then
		return ctx
	end
	local name = EFV_UI_PlayerName(row.recipientID)
	for _, code in ipairs(NAME_REASON_LIST) do
		ctx[code] = { name }
	end
	local fee = (row.calc ~= nil) and row.calc.fee or nil
	ctx.GOLD = { fee or 0 }
	ctx.FEE_CHANGED = { fee or 0 }
	ctx.WRONG_TERRITORY = { EFV_UI_PlayerName(row.landOwnerID) }
	return ctx
end

-- Turns until a MUTINY unit is destroyed: the higher of the recorded floor
-- (lastDamage) and the live unit's damage (identity-checked, Session C),
-- MUTINY_DAMAGE_PER_TURN per turn, at least 1 (PLAN 2.9 formula). Shared by
-- EFV_UI_StateText and the tracker's turns column.
local function MutinyTurnsLeft(rec)
	local damage = rec.lastDamage or rec.damage or 0
	local maxDamage = 100
	pcall(function()
		local pUnit = EFV_UI_TrackedUnit(rec)
		if pUnit ~= nil then
			damage = math.max(damage, pUnit:GetDamage())
			maxDamage = pUnit:GetMaxDamage()
		end
	end)
	local n = math.ceil((maxDamage - damage) / EFV_Config.MUTINY_DAMAGE_PER_TURN)
	return math.max(1, n)
end

-- A lapsed Volunteer whose countdown is paused on valid land (gameplay sets
-- rec.lapsePaused at every turn boundary; note 29).
local function IsPausedLapse(rec)
	return rec.lapsed == 1 and rec.lapsePaused == 1
		and (rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_StateText(rec, turn) -> text
-- Localized one-line state: "In transit, arrives in N" / "Deployed, N turns
-- left" / "Deployed (volunteer, recall in N)" / "Grace N" / "Mutiny,
-- destroyed in N" / "Returning, arrives in N"; blocked arrivals and served
-- EXP/CS terms have their own keys. Lapsed Volunteers get the lapse reason
-- (LOC_EFV_LAPSE_WAR / _PARTNER) appended. A paused lapse (rec.lapsePaused
-- == 1: the Volunteer stands on the sender's or the recipient's land,
-- INTERFACES note 29) reads "Grace N (paused): recall it now ..." /
-- "Mutiny N (paused): ..." (LOC_EFV_STATE_GRACE_PAUSED / _MUTINY_PAUSED).
-- Params:  rec record, turn number (current turn; nil = now).
-- Returns: string.
-- PLAN 3.1, 2.9 (mutiny N formula); spec 14.4, 14.5. APIs: A17, A25, U17.
-- ---------------------------------------------------------------------------
function EFV_UI_StateText(rec, turn)
	if type(rec) ~= "table" then
		return ""
	end
	turn = turn or CurrentTurn()
	local st = rec.state
	local text = ""
	if st == EFV_Config.ST_OUTBOUND or st == EFV_Config.ST_RETURNING then
		local n = (rec.arrivalTurn or turn) - turn
		if n <= 0 and (rec.spawnFailCount or 0) > 0 then
			text = SafeLookup("LOC_EFV_STATE_BLOCKED")
		else
			local key = (st == EFV_Config.ST_OUTBOUND) and "LOC_EFV_STATE_OUTBOUND" or "LOC_EFV_STATE_RETURNING"
			text = SafeLookup(key, math.max(0, n))
		end
	elseif st == EFV_Config.ST_DEPLOYED then
		local elapsed = turn - (rec.deployedTurn or turn)
		if rec.forceType == EFV_Config.FT_VOL then
			local n = EFV_Config.VOLUNTEER_MIN_DEPLOYMENT - elapsed
			if n > 0 then
				text = SafeLookup("LOC_EFV_STATE_DEPLOYED_VOLUNTEER", n)
			else
				text = SafeLookup("LOC_EFV_STATE_DEPLOYED_VOLUNTEER_READY")
			end
		else
			local n = (rec.durationTurns or 0) - elapsed
			if n > 0 then
				text = SafeLookup("LOC_EFV_STATE_DEPLOYED", n)
			else
				text = SafeLookup("LOC_EFV_STATE_DEPLOYED_EXPIRED")
			end
		end
	elseif st == EFV_Config.ST_GRACE then
		local key = IsPausedLapse(rec) and "LOC_EFV_STATE_GRACE_PAUSED" or "LOC_EFV_STATE_GRACE"
		text = SafeLookup(key, rec.graceTurnsLeft or 0)
	elseif st == EFV_Config.ST_MUTINY then
		local key = IsPausedLapse(rec) and "LOC_EFV_STATE_MUTINY_PAUSED" or "LOC_EFV_STATE_MUTINY"
		text = SafeLookup(key, MutinyTurnsLeft(rec))
	else
		text = tostring(st)
	end
	if rec.lapsed == 1 and (rec.lapseReason == "WAR" or rec.lapseReason == "PARTNER") then
		text = text .. " " .. SafeLookup("LOC_EFV_LAPSE_" .. rec.lapseReason)
	end
	return text
end

-- ---------------------------------------------------------------------------
-- EFV_UI_ReasonsText(codes, ctx) -> text
-- Concatenates, per code, "[NEWLINE][COLOR:Red]" .. Locale.Lookup(
-- "LOC_EFV_REASON_" .. code, unpack(ctx[code] or {})) .. "[ENDCOLOR]"
-- (UnitPanel style, R4 1.4). Duplicate codes are shown once.
-- Params:  codes dense array of reason codes; ctx table or nil mapping a code
--          to its Lookup argument array, e.g. { RECALL_MIN_TURNS = { 3 },
--          GOLD = { 108 } }.
-- Returns: string ("" for no codes).
-- PLAN 3.1, 3.7. APIs: U17, A61.
-- ---------------------------------------------------------------------------
function EFV_UI_ReasonsText(codes, ctx)
	if type(codes) ~= "table" then
		return ""
	end
	ctx = ctx or {}
	local seen = {}
	local parts = {}
	for _, code in ipairs(codes) do
		if not seen[code] then
			seen[code] = true
			local args = ctx[code] or {}
			parts[#parts + 1] = "[NEWLINE][COLOR:Red]" .. SafeLookup("LOC_EFV_REASON_" .. tostring(code), unpack(args)) .. "[ENDCOLOR]"
		end
	end
	return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_Request(onStart, params)
-- Sets params.OnStart = onStart, flattens values (booleans -> 0/1; tables,
-- functions and nil-keys dropped with an error log), logs
-- "[UIRequest] <onStart> k=v ...", calls UI.RequestPlayerOperation(
-- Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, params) (SPIKES S2).
-- Params:  onStart EFV_Config.REQ_*, params flat table.
-- Returns: nil.
-- PLAN 3.1, 1.5; SPIKES S2. APIs: U01, U02.
-- ---------------------------------------------------------------------------
function EFV_UI_Request(onStart, params)
	local localID = LocalPlayer()
	if localID < 0 then
		EFV_Log(1, LOG_TAG_REQ, "%s not sent: no local player", tostring(onStart))
		return nil
	end
	local flat = {}
	local logParts = {}
	for _, k in ipairs(EFV_SortedKeys(params or {})) do
		local v = params[k]
		local tv = type(v)
		if tv == "boolean" then
			v = v and 1 or 0
			tv = "number"
		end
		if type(k) == "string" and (tv == "number" or tv == "string") then
			flat[k] = v
			logParts[#logParts + 1] = k .. "=" .. tostring(v)
		else
			EFV_Log(1, LOG_TAG_REQ, "%s dropped non-flat param %s (%s)", tostring(onStart), tostring(k), tv)
		end
	end
	flat.OnStart = onStart
	EFV_Log(2, LOG_TAG_REQ, "%s %s", tostring(onStart), table.concat(logParts, " "))
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(localID, PlayerOperations.EXECUTE_SCRIPT, flat)
	end)
	if not ok then
		EFV_Log(1, LOG_TAG_REQ, "%s RequestPlayerOperation failed: %s", tostring(onStart), tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_UI_StatusTooltip(rec) -> text
-- LOC_EFV_FLAG_TT with {1_Force} {2_Unit} {3_Sender} {4_Recipient}
-- {5_State} (state text includes the remaining turns; spec 14.4). Reused by
-- the flag badge, the unit-panel status button and the tracker.
-- Params:  rec record.
-- Returns: string.
-- PLAN 3.1; spec 14.4. APIs: U17, A62.
-- ---------------------------------------------------------------------------
function EFV_UI_StatusTooltip(rec)
	if type(rec) ~= "table" then
		return ""
	end
	local forceKey = EFV_ForceLabelKey(rec.forceType)
	local force = forceKey and SafeLookup(forceKey) or tostring(rec.forceType)
	local unitName = ""
	pcall(function()
		unitName = EFV_UnitDisplayName(rec.unitType, rec.veteranName) or ""
	end)
	local text = SafeLookup("LOC_EFV_FLAG_TT", force, unitName,
		EFV_UI_PlayerName(rec.senderID), EFV_UI_PlayerName(rec.recipientID),
		EFV_UI_StateText(rec, CurrentTurn()))
	-- Heal-gate warning (designer ruling "Strategic-resource heal gate",
	-- 0.6.0): a unit on the map whose owner has none of its resource.
	if rec.state == EFV_Config.ST_DEPLOYED or rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY then
		local owner = rec.onMapPlayerID
		if type(owner) ~= "number" then
			owner = (rec.forceType == EFV_Config.FT_VOL) and rec.senderID or rec.recipientID
		end
		local warn = EFV_UI_HealWarning(rec.unitType, owner)
		if warn ~= "" then
			text = text .. "[NEWLINE][NEWLINE]" .. warn
		end
	end
	return text
end

-- ---------------------------------------------------------------------------
-- EFV_UI_HealWarning(unitType, ownerID) -> text   (added 0.6.0)
-- Designer ruling "Strategic-resource heal gate" (warning only, no scripted
-- healing): when EFV_HealGateBlocked(unitType, ownerID) (the type needs a
-- strategic resource and the owner has none), a red LOC_EFV_WARN_NO_HEAL
-- {1_Civ} {2_Resource} line; else "". Used by the destination picker (row
-- tooltip and confirm dialog; owner = the recipient for Expeditionary and
-- City-State, the sender for Volunteers) and by EFV_UI_StatusTooltip (flag
-- badge, tracker row, unit panel). Unreadable stock -> "" (no guess).
-- APIs: A50, A51 (via EFV_HealGateBlocked), U17.
-- ---------------------------------------------------------------------------
function EFV_UI_HealWarning(unitType, ownerID)
	local ok, blocked, resType = pcall(EFV_HealGateBlocked, unitType, ownerID)
	if not ok or not blocked or resType == nil then
		return ""
	end
	local resName = resType
	pcall(function()
		local row = GameInfo.Resources[resType]
		if row ~= nil and row.Name ~= nil then
			resName = "[ICON_" .. resType .. "] " .. Locale.Lookup(row.Name)
		end
	end)
	return "[COLOR:Red]" .. SafeLookup("LOC_EFV_WARN_NO_HEAL", EFV_UI_PlayerName(ownerID), resName) .. "[ENDCOLOR]"
end

-- ===========================================================================
-- Tracker rows (WP7.2; spec 14.5; D9). Pure functions over the UI store, so
-- the offline tests check them without the panel.
-- ===========================================================================

-- Sort group of a row: alerts first (MUTINY, then GRACE: the D9 banner cycle
-- order), then units on the map, then units in transit.
local STATE_GROUP = { MUTINY = 1, GRACE = 2, DEPLOYED = 3, OUTBOUND = 4, RETURNING = 5 }

-- Short state label keys of the State column.
local TRACKER_STATE_KEYS = {
	OUTBOUND  = "LOC_EFV_TRACKER_ST_OUTBOUND",
	DEPLOYED  = "LOC_EFV_TRACKER_ST_DEPLOYED",
	GRACE     = "LOC_EFV_TRACKER_ST_GRACE",
	MUTINY    = "LOC_EFV_TRACKER_ST_MUTINY",
	RETURNING = "LOC_EFV_TRACKER_ST_RETURNING",
}

local function InTransit(rec)
	return rec.state == EFV_Config.ST_OUTBOUND or rec.state == EFV_Config.ST_RETURNING
end

local function Blocked(rec, turn)
	return InTransit(rec) and (rec.arrivalTurn or turn) - turn <= 0 and (rec.spawnFailCount or 0) > 0
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerTurns(rec, turn) -> n or nil   (added WP7.2)
-- The Turns column: OUTBOUND / RETURNING turns until arrival; DEPLOYED EXP /
-- CS turns of service left (0 once served); GRACE turns left before mutiny;
-- MUTINY turns until destroyed (same formula as EFV_UI_StateText). nil for a
-- deployed Volunteer (unlimited service) and unknown states. Never negative.
-- Params:  rec record (UI store, nil-safe fields), turn current turn.
-- Returns: number or nil.
-- PLAN 3.6; spec 14.5. APIs: via EFV_UI_TrackedUnit (mutiny).
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerTurns(rec, turn)
	if type(rec) ~= "table" then
		return nil
	end
	turn = turn or CurrentTurn()
	local st = rec.state
	if InTransit(rec) then
		return math.max(0, (rec.arrivalTurn or turn) - turn)
	elseif st == EFV_Config.ST_DEPLOYED then
		if rec.forceType == EFV_Config.FT_VOL or type(rec.durationTurns) ~= "number" then
			return nil
		end
		return math.max(0, rec.durationTurns - (turn - (rec.deployedTurn or turn)))
	elseif st == EFV_Config.ST_GRACE then
		return math.max(0, rec.graceTurnsLeft or 0)
	elseif st == EFV_Config.ST_MUTINY then
		return MutinyTurnsLeft(rec)
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerState(rec, turn) -> text   (added WP7.2)
-- The short State column: Outbound / Deployed / Service ended / Grace /
-- Mutiny / Returning / Blocked (arrival due, no free tile); a lapsed
-- Volunteer (GRACE / MUTINY after a lapse) shows "Lapse: <state>", and
-- "Lapse: <state> N (paused)" while it stands on valid land (note 29).
-- Params:  rec record, turn current turn.
-- Returns: string ("" for no record).
-- PLAN 3.6; spec 14.5. APIs: U17.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerState(rec, turn)
	if type(rec) ~= "table" then
		return ""
	end
	turn = turn or CurrentTurn()
	local st = rec.state
	local text
	if Blocked(rec, turn) then
		text = SafeLookup("LOC_EFV_TRACKER_ST_BLOCKED")
	elseif st == EFV_Config.ST_DEPLOYED and rec.forceType ~= EFV_Config.FT_VOL
			and EFV_UI_TrackerTurns(rec, turn) == 0 then
		text = SafeLookup("LOC_EFV_TRACKER_ST_EXPIRED")
	elseif TRACKER_STATE_KEYS[st] ~= nil then
		text = SafeLookup(TRACKER_STATE_KEYS[st])
	else
		text = tostring(st)
	end
	if IsPausedLapse(rec) then
		text = SafeLookup("LOC_EFV_TRACKER_ST_LAPSE_PAUSED", text, EFV_UI_TrackerTurns(rec, turn) or 0)
	elseif rec.lapsed == 1 and (st == EFV_Config.ST_GRACE or st == EFV_Config.ST_MUTINY) then
		text = SafeLookup("LOC_EFV_TRACKER_ST_LAPSE", text)
	end
	return text
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerPlace(rec) -> text   (added WP7.2)
-- The Destination column: OUTBOUND -> the destination city (recipient's),
-- RETURNING -> the return city (sender's); "" for units on the map.
-- Params:  rec record.
-- Returns: string.
-- PLAN 3.6. APIs: via EFV_UI_CityName.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerPlace(rec)
	if type(rec) ~= "table" then
		return ""
	end
	if rec.state == EFV_Config.ST_OUTBOUND then
		return EFV_UI_CityName(rec.recipientID, rec.destCityID, rec.destX, rec.destY)
	elseif rec.state == EFV_Config.ST_RETURNING then
		return EFV_UI_CityName(rec.senderID, rec.returnCityID, rec.returnX, rec.returnY)
	end
	return ""
end

-- Row order (see STATE_GROUP): alerts by id (the banner cycle order), the
-- other rows by group, then fewest turns first (unlimited last), then id.
local function RowLess(a, b)
	if a.group ~= b.group then
		return a.group < b.group
	end
	if a.alert == nil then
		local ta, tb = a.turns or math.huge, b.turns or math.huge
		if ta ~= tb then
			return ta < tb
		end
	end
	return (a.id or 0) < (b.id or 0)
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerRows(localID, turn) -> rows   (added WP7.2)
-- One row per record of EFV_UI_RecordsFor(localID) (sent and received):
--   { rec, id, alert = "MUTINY" / "GRACE" / nil, sent = bool (local is the
--     sender), own = bool (local controls the unit on the map), transit =
--     bool, group, turns = n or nil, unit, partner ("To X" / "From X"),
--     force, state (EFV_UI_TrackerState), turnsText ("-" when nil), place
--     (EFV_UI_TrackerPlace), tooltip (EFV_UI_StatusTooltip + click hint) }
-- sorted MUTINY, GRACE (ascending id), then DEPLOYED, OUTBOUND, RETURNING
-- (fewest turns first, unlimited last, then id). Deterministic.
-- Params:  localID player ID; turn current turn (nil = now).
-- Returns: dense array (empty for no local player).
-- PLAN 3.6; spec 14.5; D9. APIs: U17, A62.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerRows(localID, turn)
	turn = turn or CurrentTurn()
	local rows = {}
	for _, rec in ipairs(EFV_UI_RecordsFor(localID)) do
		local sent = (rec.senderID == localID)
		local partnerID = sent and rec.recipientID or rec.senderID
		local forceKey = EFV_ForceLabelKey(rec.forceType)
		local unitName = ""
		pcall(function()
			unitName = EFV_UnitDisplayName(rec.unitType, rec.veteranName) or ""
		end)
		local alert = nil
		if rec.state == EFV_Config.ST_MUTINY or rec.state == EFV_Config.ST_GRACE then
			alert = rec.state
		end
		local transit = InTransit(rec)
		local own = (not transit) and rec.onMapPlayerID == localID
		local turns = EFV_UI_TrackerTurns(rec, turn)
		local place = EFV_UI_TrackerPlace(rec)
		local hint
		if transit then
			hint = SafeLookup("LOC_EFV_TRACKER_TT_TRANSIT", place)
		elseif own then
			hint = SafeLookup("LOC_EFV_TRACKER_TT_SELECT")
		else
			hint = SafeLookup("LOC_EFV_TRACKER_TT_LOOK")
		end
		rows[#rows + 1] = {
			rec = rec,
			id = rec.id,
			alert = alert,
			sent = sent,
			own = own,
			transit = transit,
			group = STATE_GROUP[rec.state] or 9,
			turns = turns,
			unit = unitName,
			partner = SafeLookup(sent and "LOC_EFV_TRACKER_TO" or "LOC_EFV_TRACKER_FROM", EFV_UI_PlayerName(partnerID)),
			force = forceKey and SafeLookup(forceKey) or tostring(rec.forceType),
			state = EFV_UI_TrackerState(rec, turn),
			turnsText = (turns ~= nil) and tostring(turns) or "-",
			place = place,
			tooltip = EFV_UI_StatusTooltip(rec) .. "[NEWLINE][NEWLINE]" .. hint,
		}
	end
	table.sort(rows, RowLess)
	return rows
end

-- ---------------------------------------------------------------------------
-- Tracker column sorting (added 0.7.1). The panel's six header labels are
-- click targets; the sort state is { col = 1..6 or nil, dir = 1 (A-Z /
-- ascending), -1 (Z-A / descending) or 0 (default order) }. It lives in a
-- Lua variable of the tracker context only (never saved to the game).
-- EFV_UI_TRACKER_SORT_COLS: column i -> row field and kind, in header order
--   (Unit, Partner, Force, State, Turns, Destination). Text columns compare
--   the displayed text case-insensitively; the Turns column compares
--   row.turns, where nil (a Volunteer's unlimited service, shown "-") counts
--   as larger than any number.
-- ---------------------------------------------------------------------------
EFV_UI_TRACKER_SORT_COLS = {
	{ field = "unit",    numeric = false },
	{ field = "partner", numeric = false },
	{ field = "force",   numeric = false },
	{ field = "state",   numeric = false },
	{ field = "turns",   numeric = true },
	{ field = "place",   numeric = false },
}

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerSortClick(sort, col) -> new sort state   (added 0.7.1)
-- A click on header column col: a different (or no) sorted column -> col
-- ascending; the sorted column cycles ascending -> descending -> default
-- (col nil, dir 0). Only one column is sorted at a time. Pure.
-- Params:  sort current state ({ col, dir } or nil); col 1..6.
-- Returns: a new table { col = n or nil, dir = 1 / -1 / 0 }.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerSortClick(sort, col)
	sort = sort or {}
	if EFV_UI_TRACKER_SORT_COLS[col] == nil then
		return { col = sort.col, dir = sort.dir or 0 }
	end
	if sort.col ~= col or (sort.dir or 0) == 0 then
		return { col = col, dir = 1 }
	elseif sort.dir == 1 then
		return { col = col, dir = -1 }
	end
	return { col = nil, dir = 0 }
end

-- -1 / 0 / 1 comparison of two cell values of one column.
local function SortCellCompare(a, b, numeric)
	if numeric then
		local na = (type(a) == "number") and a or math.huge
		local nb = (type(b) == "number") and b or math.huge
		if na < nb then return -1 elseif na > nb then return 1 end
		return 0
	end
	local la, lb = string.lower(tostring(a or "")), string.lower(tostring(b or ""))
	if la < lb then return -1 elseif la > lb then return 1 end
	return 0
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerSortRows(rows, sort) -> rows   (added 0.7.1)
-- The rows of EFV_UI_TrackerRows in the order of the sort state: default
-- (no column or dir 0) -> the same array, untouched (GRACE / MUTINY pinned
-- on top); otherwise a new array of ALL rows (alerts not pinned) ordered by
-- the column, ascending (dir 1) or descending (dir -1); equal cells keep
-- ascending record id in both directions (a total order, deterministic).
-- Params:  rows array; sort { col, dir } or nil.
-- Returns: array.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerSortRows(rows, sort)
	local spec = sort and EFV_UI_TRACKER_SORT_COLS[sort.col or 0] or nil
	local dir = sort and sort.dir or 0
	if spec == nil or (dir ~= 1 and dir ~= -1) or type(rows) ~= "table" then
		return rows
	end
	local out = {}
	for i, row in ipairs(rows) do
		out[i] = row
	end
	table.sort(out, function(a, b)
		local c = SortCellCompare(a[spec.field], b[spec.field], spec.numeric) * dir
		if c ~= 0 then
			return c < 0
		end
		return (a.id or 0) < (b.id or 0)
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerSortMark(sort, col) -> text key or nil   (added 0.7.1)
-- The arrow appended to the label of header column col: LOC_EFV_TRACKER_SORT_ASC
-- / _DESC (arrow font icons, 0.7.2) for the sorted column; nil for every
-- other column (those show the faded "sortable" pair instead, see
-- EFV_UI_TrackerSortHint).
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerSortMark(sort, col)
	if sort ~= nil and sort.col == col then
		if sort.dir == 1 then
			return "LOC_EFV_TRACKER_SORT_ASC"
		elseif sort.dir == -1 then
			return "LOC_EFV_TRACKER_SORT_DESC"
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerSortHint(sort, col) -> boolean   (added 0.7.3)
-- True when header column col shows the "sortable" mark (SortXHint in
-- EFV_Tracker.xml: PressureUp / PressureDown textures at 40% alpha,
-- designer's candidate B): every column except the sorted one, which carries
-- its single arrow (EFV_UI_TrackerSortMark) instead. Exactly one of the two
-- marks shows on each column. Pure.
-- Params:  sort { col, dir } or nil; col 1..6.
-- Returns: boolean.
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerSortHint(sort, col)
	return EFV_UI_TrackerSortMark(sort, col) == nil
end

-- ---------------------------------------------------------------------------
-- EFV_UI_TrackerCounts(localID) -> sent, received, alerts   (added WP7.2)
-- Record counts of the local player for the panel summary and the launch-bar
-- tooltip; alerts = records in GRACE / MUTINY (D9).
-- ---------------------------------------------------------------------------
function EFV_UI_TrackerCounts(localID)
	local sent, received, alerts = 0, 0, 0
	for _, rec in ipairs(EFV_UI_RecordsFor(localID)) do
		if rec.senderID == localID then
			sent = sent + 1
		else
			received = received + 1
		end
		if rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY then
			alerts = alerts + 1
		end
	end
	return sent, received, alerts
end

-- ---------------------------------------------------------------------------
-- EFV_UI_EntrustState(localID, x, y) -> state   (added Phase 6, WP6.2)
-- What the capture popup offers for the captured city at (x, y), from the
-- gameplay snapshot (EFV_UI_ReadStore().entrust[EFV_PlotKey(x, y)]) and the
-- shared rules (EFV_EntrustSnapshotReasons / EFV_EntrustRecipientReasons),
-- so the buttons agree with the gameplay re-validation.
-- Returns: { key, snap, oldOwnerID, codes = option-level reason codes
--   (empty = Entrust offered), rows = { { recipientID, name, codes } } in
--   snapshot order (ascending ID), enabled = number of rows without codes }.
--   When every listed recipient became invalid, codes =
--   { "ENTRUST_RECIPIENT_INVALID" }.
-- APIs: A06 (via EFV_UI_ReadStore), A10, A42, A36.
-- ---------------------------------------------------------------------------
function EFV_UI_EntrustState(localID, x, y)
	local st = { codes = {}, rows = {}, enabled = 0 }
	st.key = EFV_PlotKey(x, y)
	local snap = nil
	if st.key ~= nil then
		snap = EFV_UI_ReadStore().entrust[st.key]
	end
	if type(snap) ~= "table" then
		snap = nil
	end
	st.snap = snap
	st.codes = EFV_EntrustSnapshotReasons(snap, localID, CurrentTurn())
	if snap ~= nil then
		st.oldOwnerID = snap.oldOwnerID
	end
	if #st.codes == 0 then
		for _, rid in ipairs(snap.recipients) do
			local codes = EFV_EntrustRecipientReasons(snap, localID, rid)
			st.rows[#st.rows + 1] = { recipientID = rid, name = EFV_UI_PlayerName(rid), codes = codes }
			if #codes == 0 then
				st.enabled = st.enabled + 1
			end
		end
		if st.enabled == 0 then
			st.codes = { "ENTRUST_RECIPIENT_INVALID" }
		end
	end
	return st
end

-- ---------------------------------------------------------------------------
-- EFV_UI_EntrustReasonsText(state) -> text   (added Phase 6, WP6.2)
-- Red reason lines for a disabled Entrust button (spec 12.2 "a tooltip
-- explaining why"): EFV_UI_ReasonsText of state.codes, where
-- ENTRUST_NO_PARTNER names the former owner; for ENTRUST_NO_PARTNER a second
-- line names the partners that were not at war with it
-- (LOC_EFV_ENTRUST_NOT_AT_WAR {1_List} {2_Name}) or says there were none
-- (LOC_EFV_ENTRUST_NO_PARTNERS).
-- ---------------------------------------------------------------------------
function EFV_UI_EntrustReasonsText(state)
	if type(state) ~= "table" or type(state.codes) ~= "table" then
		return ""
	end
	local oldName = EFV_UI_PlayerName(state.oldOwnerID)
	local text = EFV_UI_ReasonsText(state.codes, { ENTRUST_NO_PARTNER = { oldName } })
	for _, code in ipairs(state.codes) do
		if code == "ENTRUST_NO_PARTNER" then
			local names = {}
			local partners = (state.snap ~= nil and type(state.snap.partners) == "table") and state.snap.partners or {}
			for _, pid in ipairs(partners) do
				names[#names + 1] = EFV_UI_PlayerName(pid)
			end
			if #names > 0 then
				text = text .. "[NEWLINE]" .. SafeLookup("LOC_EFV_ENTRUST_NOT_AT_WAR", table.concat(names, ", "), oldName)
			else
				text = text .. "[NEWLINE]" .. SafeLookup("LOC_EFV_ENTRUST_NO_PARTNERS")
			end
		end
	end
	return text
end

EFV_UIShared.LOADED = 1
