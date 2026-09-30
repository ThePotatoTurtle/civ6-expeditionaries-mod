-- ===========================================================================
-- EFV_Entrust.lua
-- Module:   EFV_Entrust (global table)
-- Context:  gameplay only, include("EFV_Entrust").
-- Owner:    WP6.1 (Phase 6, implemented; INTERFACES note 31).
--
-- Responsibility (PLAN 2.10; spec 12; SPIKES S1, UI-S3; D1, D5; Session F
-- T15 / T16 / T20): take a capture-time eligibility snapshot keyed by plot,
-- handle the EFV_Entrust request (re-validate against the snapshot, transfer
-- with CityManager.TransferCity, verify by re-fetching the city at the plot
-- because the transfer gives the city a NEW ID), and drop stale snapshots at
-- turn start. No grievance change for the recipient (D1 ruling; BY_GIFT kept,
-- DECISIONS "Entrust transfer type resolved"). No loyalty help (spec 12.4,
-- design note: intended).
--
-- Snapshot shape (store.entrust["p"..plotIndex], INTERFACES "Entrust
-- snapshot"): { capturerID, oldOwnerID, turn, recipients = { pid... },
-- partners = { pid... } }. recipients = partners at war with the old owner
-- at the moment of capture, or every partner when the old owner is the Free
-- Cities, a city-state or no longer alive (EFV_EntrustSkipsWarCheck; ruling
-- 2026-09-30) (EFV_EntrustCandidates, shared with the UI);
-- partners = every eligible partner then (only for the disabled-button
-- tooltip). Empty arrays come back nil from a property round trip;
-- EFV_Records.Load normalises both to {}.
--
-- Flow (D5, Session F): the capture popup (UI, EFV_EntrustPopup) sends
-- CityManager.RequestCommand(DESTROY, KEEP) first (resolves the capture
-- decision and its end-turn blocker), then EFV_Entrust {x, y, recipientID}.
-- Both orders were proven in game (T15 KEEP first, T16 without KEEP); the
-- city is the capturer's from the moment of capture either way. After the
-- transfer the capturer has no further relationship with the city: the
-- snapshot is deleted and nothing else is tracked.
--
-- Only human major capturers get a snapshot, and only human requesters are
-- served (the AI never entrusts, spec 1.1). Notification text arguments:
--   ENTRUSTED      {1 capturer civ, 2 city, 3 recipient civ} (to both; AI
--                  recipients are skipped by EFV_Notify)
--   REQUEST_FAILED {1 reason text (LOC_EFV_REASON_ENTRUST_*)}
-- ===========================================================================

if EFV_Entrust ~= nil and EFV_Entrust.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")
include("EFV_Notify")

EFV_Entrust = {}

local LOG_TAG = "Entrust"

-- ===========================================================================
-- File-local helpers
-- ===========================================================================

local function CurrentTurn()
	return Game.GetCurrentGameTurn()
end

local function IsHumanMajor(pid)
	if type(pid) ~= "number" or Players[pid] == nil then
		return false
	end
	local ok, human = pcall(function() return Players[pid]:IsHuman() end)
	return ok and human == true and EFV_PlayerKind(pid) == "MAJOR"
end

local function ListText(list)
	local parts = {}
	for _, v in ipairs(list or {}) do
		parts[#parts + 1] = tostring(v)
	end
	return table.concat(parts, ",")
end

-- Localized reason text for EFV_NOTIF_REQUEST_FAILED. ENTRUST_NO_PARTNER
-- {1_Name} = the former owner's civ name; the other Entrust codes take none.
local function ReasonText(code, snap)
	local key = "LOC_EFV_REASON_" .. tostring(code)
	local ok, s
	if code == "ENTRUST_NO_PARTNER" then
		ok, s = pcall(Locale.Lookup, key, EFV_PlayerName(type(snap) == "table" and snap.oldOwnerID or -1))
	else
		ok, s = pcall(Locale.Lookup, key)
	end
	if ok and type(s) == "string" then
		return s
	end
	return tostring(code)
end

local function Reject(playerID, codes, snap, x, y, recipientID)
	EFV_Log(2, LOG_TAG, "rejected player=%s at=%s,%s recipient=%s reasons=%s", tostring(playerID),
		tostring(x), tostring(y), tostring(recipientID), table.concat(codes, ","))
	local first = codes[1] or "ENTRUST_STALE"
	local lx, ly = nil, nil
	if type(x) == "number" and type(y) == "number" then
		lx, ly = x, y
	end
	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.REQUEST_FAILED, "LOC_" .. EFV_Config.NOTIF.REQUEST_FAILED,
		{ ReasonText(first, snap) }, lx, ly, { kind = "REQUEST_FAILED" })
end

-- CityTransferTypes value of FLAG_ENTRUST_TRANSFER_TYPE (default BY_GIFT).
local function TransferType()
	local name = EFV_Config.FLAG_ENTRUST_TRANSFER_TYPE or "BY_GIFT"
	local v = CityTransferTypes[name]
	if v == nil then
		EFV_Log(1, LOG_TAG, "unknown FLAG_ENTRUST_TRANSFER_TYPE %s; using BY_GIFT", tostring(name))
		name = "BY_GIFT"
		v = CityTransferTypes.BY_GIFT
	end
	return v, name
end

-- ===========================================================================
-- Public API
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- EFV_Entrust.EligibleRecipients(capturerID, oldOwnerID) -> recipients
-- Sorted alive majors P ~= capturer with EFV_PartnerBasis(capturer, P) ~=
-- nil (friends included; D2 applies only to Volunteers) and (P at war with
-- oldOwnerID, or EFV_EntrustSkipsWarCheck(oldOwnerID): Free Cities, a
-- city-state, or an old owner no longer alive). Thin wrapper of the shared
-- EFV_EntrustCandidates (EFV_Rules).
-- Params:  capturerID, oldOwnerID player IDs.
-- Returns: dense ascending array of player IDs.
-- PLAN 2.10; spec 12.2. APIs: A43, A42, A36.
-- ---------------------------------------------------------------------------
function EFV_Entrust.EligibleRecipients(capturerID, oldOwnerID)
	local recipients = EFV_EntrustCandidates(capturerID, oldOwnerID)
	return recipients
end

-- ---------------------------------------------------------------------------
-- EFV_Entrust.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
-- Hook body of GameEvents.CityConquered (owns load / commit, pcall). Any
-- older snapshot at the plot is dropped first (the city changed hands
-- again). Only for a human major capturer: recipients, partners =
-- EFV_EntrustCandidates(capturerID, oldOwnerID); store.entrust[
-- EFV_PlotKey(x, y)] = { capturerID, oldOwnerID, turn, recipients,
-- partners }; commit. Logs "[Entrust] snapshot ...".
-- Params:  capturerID, oldOwnerID player IDs; cityID number (logged only:
--          city IDs change on transfer, key by plot); x, y city plot.
-- Returns: nil.
-- PLAN 1.8, 2.10; spec 12.1-12.2; SPIKES S1. APIs: A47, A42.
-- ---------------------------------------------------------------------------
function EFV_Entrust.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
	local store = nil
	local ok, err = pcall(function()
		local key = EFV_PlotKey(x, y)
		if key == nil then
			EFV_Log(1, LOG_TAG, "CityConquered at=%s,%s: no plot; no snapshot", tostring(x), tostring(y))
			return
		end
		store = EFV_Records.Load()
		if store.entrust[key] ~= nil then
			store.entrust[key] = nil
			EFV_Records.MarkDirty(store, EFV_Config.PROP.ENTRUST)
			EFV_Log(2, LOG_TAG, "snapshot %s replaced (city changed hands again)", key)
		end
		if not IsHumanMajor(capturerID) then
			EFV_Log(3, LOG_TAG, "CityConquered capturer=%s is not a human major: no Entrust offer", tostring(capturerID))
			return
		end
		local turn = CurrentTurn()
		local recipients, partners = EFV_EntrustCandidates(capturerID, oldOwnerID)
		local _, skipWhy = EFV_EntrustSkipsWarCheck(oldOwnerID)
		store.entrust[key] = {
			capturerID = capturerID,
			oldOwnerID = oldOwnerID,
			turn = turn,
			recipients = recipients,
			partners = partners,
		}
		EFV_Records.MarkDirty(store, EFV_Config.PROP.ENTRUST)
		EFV_Log(2, LOG_TAG, "snapshot %s at=%s,%s city=%s capturer=%d oldOwner=%s oldKind=%s noWarCheck=%s turn=%d recipients=[%s] partners=[%s]",
			key, tostring(x), tostring(y), tostring(cityID), capturerID, tostring(oldOwnerID),
			tostring(EFV_PlayerKind(oldOwnerID)), tostring(skipWhy or "no"), turn, ListText(recipients), ListText(partners))
	end)
	if not ok then
		EFV_Log(1, LOG_TAG, "OnCityConquered failed: %s", tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", tostring(errC))
		end
	end
	return nil
end

-- Body of OnRequestEntrust. Mutation (TransferCity) only after every check.
local function EntrustBody(playerID, params, store)
	local turn = CurrentTurn()
	local x, y = tonumber(params.x), tonumber(params.y)
	local recipientID = tonumber(params.recipientID)
	local key = (x ~= nil and y ~= nil) and EFV_PlotKey(x, y) or nil
	if key == nil or recipientID == nil then
		Reject(playerID, { "ENTRUST_STALE" }, nil, x, y, params.recipientID)
		return
	end

	-- 1. Capture-time snapshot: same capturer, this turn, recipient listed.
	local snap = store.entrust[key]
	local codes = EFV_EntrustSnapshotReasons(snap, playerID, turn)
	if #codes > 0 then
		Reject(playerID, codes, snap, x, y, recipientID)
		return
	end
	codes = EFV_EntrustRecipientReasons(snap, playerID, recipientID)
	if #codes > 0 then
		Reject(playerID, codes, snap, x, y, recipientID)
		return
	end

	-- 2. The city must still stand there and belong to the capturer (it is
	--    the capturer's from the moment of capture; liberated or razed away
	--    -> stale).
	local pCity = CityManager.GetCityAt(x, y)
	if pCity == nil or pCity:GetOwner() ~= playerID then
		EFV_Log(2, LOG_TAG, "city at=%d,%d owner=%s (expected %d)", x, y,
			tostring(pCity and pCity:GetOwner()), playerID)
		Reject(playerID, { "ENTRUST_STALE" }, snap, x, y, recipientID)
		return
	end

	-- 3. Transfer (D5, Session F T15: KEEP was sent first by the UI; T16:
	--    works without it too).
	local oldCityID = pCity:GetID()
	local cityName = EFV_CityName(pCity)
	local how, howName = TransferType()
	local okT, errT = pcall(function() CityManager.TransferCity(pCity, recipientID, how) end)
	if not okT then
		EFV_Log(1, LOG_TAG, "TransferCity threw at=%d,%d recipient=%d: %s", x, y, recipientID, tostring(errT))
	end

	-- 4. The city gets a NEW ID: re-fetch by plot and verify the owner.
	local pNew = CityManager.GetCityAt(x, y)
	if pNew == nil or pNew:GetOwner() ~= recipientID then
		EFV_Log(1, LOG_TAG, "transfer failed at=%d,%d recipient=%d owner after=%s", x, y, recipientID,
			tostring(pNew and pNew:GetOwner()))
		Reject(playerID, { "ENTRUST_FAILED" }, snap, x, y, recipientID)
		return
	end
	local newName = EFV_CityName(pNew)
	if newName ~= "" then
		cityName = newName
	end

	-- 5. The capturer has no further relationship with the city.
	store.entrust[key] = nil
	EFV_Records.MarkDirty(store, EFV_Config.PROP.ENTRUST)
	EFV_Log(2, LOG_TAG, "ok at=%d,%d capturer=%d recipient=%d oldOwner=%s type=%s cityID %s -> %s",
		x, y, playerID, recipientID, tostring(snap.oldOwnerID), howName, tostring(oldCityID), tostring(pNew:GetID()))

	local args = { EFV_PlayerName(playerID), cityName, EFV_PlayerName(recipientID) }
	local extra = { kind = "ENTRUSTED" }
	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.ENTRUSTED, nil, args, x, y, extra)
	EFV_Notify.Queue(recipientID, EFV_Config.NOTIF.ENTRUSTED, nil, args, x, y, extra)
end

-- ---------------------------------------------------------------------------
-- EFV_Entrust.OnRequestEntrust(playerID, params)
-- Handler of GameEvents.EFV_Entrust (spec 12.3; D5; PLAN 1.5 contract):
-- pcall; reject non-human requesters (log only; the AI never entrusts);
-- load; snap = store.entrust[EFV_PlotKey(params.x, params.y)];
-- EFV_EntrustSnapshotReasons (same capturer, this turn, a recipient existed:
-- ENTRUST_STALE / ENTRUST_NO_PARTNER); EFV_EntrustRecipientReasons (listed
-- in the snapshot, alive major, not at war with the capturer now:
-- ENTRUST_RECIPIENT_INVALID); city = CityManager.GetCityAt(x, y) owned by
-- playerID (else ENTRUST_STALE); CityManager.TransferCity(city,
-- recipientID, CityTransferTypes[FLAG_ENTRUST_TRANSFER_TYPE]); re-fetch
-- with GetCityAt and verify the owner (else ENTRUST_FAILED, snapshot kept);
-- delete the snapshot; queue EFV_NOTIF_ENTRUSTED to both. Commit, flush.
-- Params:  playerID requesting player (authoritative), params { x, y,
--          recipientID }.
-- Returns: nil.
-- PLAN 1.5, 2.10; spec 12.3; D1, D5. APIs: A44, A48, A42, A36.
-- ---------------------------------------------------------------------------
function EFV_Entrust.OnRequestEntrust(playerID, params)
	local store = nil
	local ok, err = pcall(function()
		local pPlayer = Players[playerID]
		if pPlayer == nil or not pPlayer:IsHuman() then
			EFV_Log(2, LOG_TAG, "rejected player=%s reasons=NOT_HUMAN_MAJOR", tostring(playerID))
			return
		end
		if type(params) ~= "table" then
			EFV_Log(1, LOG_TAG, "rejected player=%s: params missing", tostring(playerID))
			return
		end
		store = EFV_Records.Load()
		EntrustBody(playerID, params, store)
	end)
	if not ok then
		EFV_Log(1, LOG_TAG, "handler failed player=%s: %s", tostring(playerID), tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", tostring(errC))
		end
	end
	local okF, errF = pcall(EFV_Notify.Flush)
	if not okF then
		EFV_Log(1, "Notify", "flush failed: %s", tostring(errF))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Entrust.CleanupSnapshots(store, turn)
-- Pipeline step 0a: delete store.entrust entries with snap.turn < turn (or
-- malformed ones); keys via EFV_SortedKeys (deterministic); marks
-- EFV_Entrust dirty when anything changed. The capture decision must be
-- made in the capture turn (end-turn blocker), so nothing valid is lost.
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 0a, 2.10. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Entrust.CleanupSnapshots(store, turn)
	if type(store) ~= "table" or type(store.entrust) ~= "table" then
		return nil
	end
	local removed = 0
	for _, key in ipairs(EFV_SortedKeys(store.entrust)) do
		local snap = store.entrust[key]
		if type(snap) ~= "table" or type(snap.turn) ~= "number" or snap.turn < turn then
			store.entrust[key] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		EFV_Records.MarkDirty(store, EFV_Config.PROP.ENTRUST)
		EFV_Log(2, LOG_TAG, "cleanup turn=%d removed=%d stale snapshot(s)", turn, removed)
	end
	return nil
end

EFV_Entrust.LOADED = 1
