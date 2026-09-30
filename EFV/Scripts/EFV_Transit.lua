-- ===========================================================================
-- EFV_Transit.lua
-- Module:   EFV_Transit (global table)
-- Context:  gameplay only, include("EFV_Transit").
-- Owner:    WP1.4 (CS branches WP4.2).
--
-- Responsibility (PLAN 2.8; spec 7, 10): the EFV_Send request handler,
-- transit maintenance (pipeline step 1), arrivals of outbound and returning
-- records incl. spawn retries (step 2), the transit check (cancel of an
-- outbound record, see below), return-city resolution, and StartReturn (an
-- on-map record enters RETURNING).
--
-- Return reasons (record.returnReason): "EXPIRED", "GRACE_RETURN",
-- "MUTINY_RETURN", "RECALL", "RECIPIENT_GONE" (on-map EXP / CS of an
-- eliminated recipient), "WAR" (on-map EXP / CS whose sender and host went
-- to war; the sender gets the RETURNING _WAR text, 1.0.4), "CANCELLED"
-- (a cancelled transit with no free tile near its origin or home city,
-- fallback B). "DEST_LOST" and outbound "RECIPIENT_GONE" / "WAR" only appear
-- on RETURNING records from older saves (still handled by ArriveReturning).
-- GRACE_RETURN / MUTINY_RETURN are EXP / CS only: a lapsed Volunteer never
-- returns by itself; on valid land its lapse is paused and Recall is its way
-- home (designer ruling "Lapsed Volunteers on valid land", INTERFACES note 29).
--
-- Transit check (DECISIONS "Transit cancelled", "Sender eliminated with
-- units in transit", "Recipient eliminated with units in transit",
-- 2026-09-30; INTERFACES note 34): an OUTBOUND record is checked in step 0b,
-- at its sender's GameEvents.PlayerTurnStarted and once more at arrival.
-- Destination city gone, owned by someone else or conquered since the last
-- check (rec.destLost, set in GameEvents.CityConquered), recipient
-- eliminated, or the recipient-level send conditions no longer holding
-- (EFV_SendRecipientReasons) -> the transit is cancelled: half the fee back
-- (TRANSIT_CANCEL_REFUND_PCT), the unit is recreated for the sender on the
-- tile it left from (rec.sentX / sentY, legacy lastX / lastY) or the
-- nearest valid free tile within SPAWN_SEARCH_MAX_RING, else near the
-- return city, else it travels there (RETURNING "CANCELLED"). There is no
-- reroute any more. Sender eliminated: Expeditionary and City-State units
-- in transit still arrive and become the recipient's own units (the record
-- is deleted at the spawn); outbound Volunteers are lost.
--
-- Notification text arguments (EFV_Notify.Queue args, in placeholder order;
-- all strings already localized in gameplay, PLAN 2.7):
--   DEPARTED       {1 unit, 2 destination city, 3 N transit turns}
--   ARRIVED        {1 unit, 2 sender civ, 3 city}
--     _CANCELLED   {1 unit, 2 sender civ, 3 destination, 4 reason text} (recipient)
--     _KEPT        {1 unit, 2 sender civ, 3 city} (recipient of an orphan)
--   SPAWN_BLOCKED  {1 unit, 2 city}
--   RETURNING      {1 unit, 2 return city, 3 N transit turns}
--     _WAR         {1 unit, 2 return city, 3 N transit turns, 4 recipient
--                   civ} (sender; reason "WAR", 1.0.4)
--     _CANCELLED   {1 unit, 2 destination, 3 reason text, 4 home city,
--                   5 N transit turns, 6 refund text} (sender, fallback B)
--   RETURNED       {1 unit, 2 city}
--     _CANCELLED   {1 unit, 2 destination, 3 reason text, 4 refund text} (sender)
--   UNIT_LOST      {1 unit, 2 loss text (LOC_EFV_LOSS_*)}
--   REQUEST_FAILED {1 reason text (LOC_EFV_REASON_<CODE>)}
-- REROUTED is retired (never sent; the type stays for older saves).
-- Reason text: LOC_EFV_CANCEL_REASON_<status> {1 civ} (sender: the
-- recipient civ; recipient: the sender civ, _HOST variant where the wording
-- differs). Refund text: LOC_EFV_CANCEL_REFUND {1 gold} or
-- LOC_EFV_CANCEL_REFUND_FREE.
-- extra = { recordID = rec.id, kind = <EFV_Config.NOTIF key> } (kind
-- "CANCELLED" / "KEPT" for the variants).
--
-- 0.7 (INTERFACES note 33): a unit may be sent from the recipient's land
-- (WRONG_TERRITORY names the land owner in REQUEST_FAILED), and a unit is
-- settled (EFV_Veteran.Settle: an open veteran-restore job is finished)
-- before it is validated and snapshotted for a send, and before StartReturn
-- snapshots it, so no unit leaves the map half-restored.
--
-- MP rules (PLAN 1.6): records iterated by EFV_Records.IDs (sorted copy), no
-- pairs(), no math.random (spawn RNG via EFV_Spawn.Pick), every request is
-- re-validated in gameplay; playerID is the only authority on who asked.
-- ===========================================================================

if EFV_Transit ~= nil and EFV_Transit.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")
include("EFV_Notify")
include("EFV_Units")
include("EFV_Spawn")

EFV_Transit = {}

-- ===========================================================================
-- File-local helpers
-- ===========================================================================

local function CurrentTurn()
	return Game.GetCurrentGameTurn()
end

-- Localized unit name for notification text (veteran name first).
local function UnitName(rec)
	local ok, s = pcall(EFV_UnitDisplayName, rec.unitType, rec.veteranName)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
	return tostring(rec.unitType)
end

-- Localized city / civ names: shared helpers in EFV_Util (WP1.7).
local CityName = EFV_CityName
local PlayerName = EFV_PlayerName

-- The destination's name for the transit-cancel texts: the city standing at
-- destX / destY (a captured city keeps its name), else the name key stored
-- at the send (rec.destNameKey), else LOC_EFV_CANCEL_DEST_GENERIC.
local function DestName(rec)
	local pCity = nil
	if rec.destX ~= nil and rec.destY ~= nil then
		local ok, c = pcall(CityManager.GetCityAt, rec.destX, rec.destY)
		if ok then
			pCity = c
		end
	end
	if pCity ~= nil then
		local s = CityName(pCity)
		if s ~= "" then
			return s
		end
	end
	if type(rec.destNameKey) == "string" and rec.destNameKey ~= "" then
		local ok, s = pcall(Locale.Lookup, rec.destNameKey)
		if ok and type(s) == "string" and s ~= "" then
			return s
		end
	end
	return Locale.Lookup("LOC_EFV_CANCEL_DEST_GENERIC")
end

-- The name key of a city (pCity:GetName(): the engine's text key or a
-- custom name, the same on every client), stored at the send so a razed
-- destination can still be named. Never a localized string (Game
-- properties must be identical on every MP client).
local function DestNameKey(pCity)
	local ok, s = pcall(function() return pCity:GetName() end)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
	return nil
end

-- Reason codes whose text names the recipient ({1_Name}): the shared list
-- EFV_Rules.NAME_REASON_CODES (also used by EFV_UIShared).
local NAME_REASONS = {}
for _, code in ipairs(EFV_Rules.NAME_REASON_CODES) do
	NAME_REASONS[code] = true
end

-- Localized reason text for EFV_NOTIF_REQUEST_FAILED (LOC_EFV_REASON_<CODE>).
-- Argument contract (EFV_Text.xml): GOLD / FEE_CHANGED {1_Num} = fee;
-- NAME_REASONS {1_Name} = recipient civ name; WRONG_TERRITORY {1_Name} = the
-- land owner's civ name (0.7); all others none.
local function ReasonText(code, fee, recipientID, landOwnerID)
	local key = "LOC_EFV_REASON_" .. tostring(code)
	local arg = nil
	if code == "GOLD" or code == "FEE_CHANGED" then
		arg = fee or 0
	elseif code == "WRONG_TERRITORY" then
		arg = PlayerName(landOwnerID)
	elseif NAME_REASONS[code] then
		arg = PlayerName(recipientID)
	end
	local ok, s
	if arg ~= nil then
		ok, s = pcall(Locale.Lookup, key, arg)
	else
		ok, s = pcall(Locale.Lookup, key)
	end
	if ok and type(s) == "string" then
		return s
	end
	return tostring(code)
end

local function IsAlive(pid)
	if pid == nil then
		return false
	end
	local pPlayer = Players[pid]
	return pPlayer ~= nil and pPlayer:IsAlive()
end

local function Extra(rec, kind)
	return { recordID = rec.id, kind = kind }
end

local function Touch(store)
	EFV_Records.Touch(store)
end

-- Per-record pcall so one broken record does not stop a pipeline step
-- (PLAN 1.6). The error is deterministic, so all clients skip the same record.
local function ForRecord(tag, rec, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		EFV_Log(1, tag, "record id=%s failed: %s", tostring(rec and rec.id), tostring(err))
	end
	return ok
end

-- Queue EFV_NOTIF_UNIT_LOST to the sender (and to the recipient when
-- alsoRecipient) with loss text LOC_EFV_LOSS_<lossKey>.
local function NotifyUnitLost(rec, lossKey, alsoRecipient)
	local args = { UnitName(rec), Locale.Lookup("LOC_EFV_LOSS_" .. lossKey) }
	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.UNIT_LOST, "LOC_" .. EFV_Config.NOTIF.UNIT_LOST,
		args, rec.lastX, rec.lastY, Extra(rec, "UNIT_LOST"))
	-- Phase 5: an eliminated recipient (spec 11 row 4) gets nothing.
	local recipientAlive = false
	if rec.recipientID ~= nil and Players[rec.recipientID] ~= nil then
		local okA, alive = pcall(function() return Players[rec.recipientID]:IsAlive() end)
		recipientAlive = okA and alive == true
	end
	if alsoRecipient and recipientAlive and rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, EFV_Config.NOTIF.UNIT_LOST, "LOC_" .. EFV_Config.NOTIF.UNIT_LOST,
			args, rec.lastX, rec.lastY, Extra(rec, "UNIT_LOST"))
	end
end

-- Moves a record into RETURNING towards pCity (spec 10.2 step 3). The band is
-- measured from (fromX, fromY) = the associated recipient city (spec 10.2) or
-- the origin tile of a cancelled transit (fallback B). Clears on-map, grace,
-- mutiny and lapse fields (incl. lapsePaused). Queues EFV_NOTIF_RETURNING
-- (sender; the _WAR text for reason "WAR", 1.0.4) unless quiet (the transit
-- cancel sends its own _CANCELLED text).
local function EnterReturning(store, rec, pCity, reason, fromX, fromY, turn, quiet)
	local cx, cy = pCity:GetX(), pCity:GetY()
	local band, d = nil, nil
	if fromX ~= nil and fromY ~= nil then
		band, d = EFV_Band(cx, cy, fromX, fromY)
	end
	if band == nil then
		EFV_Log(1, "Return", "band unavailable id=%s from=%s,%s; using 1", tostring(rec.id), tostring(fromX), tostring(fromY))
		band = 1
	end

	rec.state          = EFV_Config.ST_RETURNING
	rec.arrivalTurn    = turn + band
	rec.transitTurns   = band
	rec.band           = band
	rec.distance       = d
	rec.returnCityID   = pCity:GetID()
	rec.returnX        = cx
	rec.returnY        = cy
	rec.returnReason   = reason
	rec.spawnFailCount = 0
	rec.onMapPlayerID  = nil
	rec.onMapUnitID    = nil
	rec.graceTurnsLeft = nil
	rec.lastDamage     = nil
	rec.lapsed         = 0
	rec.lapseReason    = nil
	rec.lapseTurn      = nil
	rec.preLapseState  = nil
	rec.lapsePaused    = nil
	Touch(store)

	if not quiet then
		local key = "LOC_" .. EFV_Config.NOTIF.RETURNING
		local args = { UnitName(rec), CityName(pCity), band }
		if reason == "WAR" then
			-- 1.0.4: sent home because the sender and the host went to war.
			key = key .. "_WAR"
			args[4] = PlayerName(rec.recipientID)
		end
		EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.RETURNING, key,
			args, cx, cy, Extra(rec, "RETURNING"))
	end
	EFV_Log(2, "Return", "start id=%d reason=%s city=%s at=%d,%d band=%d arrival=%d",
		rec.id, tostring(reason), tostring(rec.returnCityID), cx, cy, band, rec.arrivalTurn)
end

-- ===========================================================================
-- Send handler
-- ===========================================================================

local VALID_FORCE = {}
VALID_FORCE[EFV_Config.FT_EXP] = true
VALID_FORCE[EFV_Config.FT_VOL] = true
VALID_FORCE[EFV_Config.FT_CS]  = true

-- Rejects a send: logs every reason, notifies the requester with the first
-- (fee = argument of GOLD / FEE_CHANGED; recipientID names the civ for the
-- recipient-level reasons; landOwnerID names the land owner for
-- WRONG_TERRITORY).
local function RejectSend(playerID, reasons, fee, recipientID, landOwnerID)
	EFV_Log(2, "Send", "rejected player=%s reasons=%s", tostring(playerID), table.concat(reasons, ","))
	local first = reasons[1] or "REQ_STALE"
	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.REQUEST_FAILED, "LOC_" .. EFV_Config.NOTIF.REQUEST_FAILED,
		{ ReasonText(first, fee, recipientID, landOwnerID) }, nil, nil, { kind = "REQUEST_FAILED" })
end

-- Finishes an open veteran-restore job of the unit (route B, item 7 step 5)
-- before a removal snapshot. A failure is logged; the send / return goes on
-- with the unit as it is.
local function Settle(store, pUnit, tag)
	if pUnit == nil or EFV_Veteran == nil or EFV_Veteran.Settle == nil then
		return
	end
	local ok, err = pcall(EFV_Veteran.Settle, store, pUnit)
	if not ok then
		EFV_Log(1, tag, "veteran settle failed unit=%s: %s", tostring(pUnit:GetID()), tostring(err))
	end
end

-- Body of OnRequestSend (spec 7.1). Mutations happen only after every check
-- passed; order: snapshot -> record -> remove unit -> gold, so that a failed
-- removal leaves no record and costs no gold.
local function SendBody(playerID, params, store)
	local turn = CurrentTurn()

	-- Flat params (PLAN 1.5); never trust types.
	local unitID      = tonumber(params.unitID)
	local recipientID = tonumber(params.recipientID)
	local destX       = tonumber(params.destX)
	local destY       = tonumber(params.destY)
	local expectedFee = tonumber(params.expectedFee)
	local forceType   = params.forceType
	if type(forceType) ~= "string" or not VALID_FORCE[forceType]
		or unitID == nil or recipientID == nil or destX == nil or destY == nil then
		RejectSend(playerID, { "REQ_STALE" })
		return
	end

	-- 1. Resolve unit (owned by the requester by construction; identity-checked,
	--    Session C item 2) and city by plot (DV1).
	local pUnit = EFV_Units.Get(playerID, unitID)
	local pCity = CityManager.GetCityAt(destX, destY)
	if pUnit == nil or pCity == nil then
		RejectSend(playerID, { "REQ_STALE" })
		return
	end

	-- 1b. Settle a pending veteran restore first (route B, 0.7), so the checks
	--     and the snapshot below see the finished unit.
	Settle(store, pUnit, "Send")

	-- 2. Full re-validation with the shared rules (G adapters).
	local ok, reasons, calc = EFV_EvaluateSend(playerID, pUnit, recipientID, pCity, forceType, store)
	if not ok then
		if reasons == nil or #reasons == 0 then
			reasons = { "REQ_STALE" }
		end
		local landOwnerID = EFV_SendLandOwner(pUnit, playerID)
		if landOwnerID == -1 then
			landOwnerID = nil
		end
		RejectSend(playerID, reasons, calc and calc.fee, recipientID, landOwnerID)
		return
	end
	if calc == nil or calc.origin == nil or calc.fee == nil or calc.transit == nil then
		EFV_Log(1, "Send", "EvaluateSend ok without complete calc player=%s unit=%s", tostring(playerID), tostring(unitID))
		RejectSend(playerID, { "REQ_STALE" })
		return
	end
	local fee = calc.fee
	-- DV5: expectedFee is the upper bound the player consented to.
	if expectedFee == nil or fee > expectedFee then
		EFV_Log(2, "Send", "fee changed expected=%s fee=%s", tostring(expectedFee), tostring(fee))
		RejectSend(playerID, { "FEE_CHANGED" }, fee)
		return
	end
	local pTreasury = Players[playerID]:GetTreasury()
	if math.floor(pTreasury:GetGoldBalance()) < fee then
		RejectSend(playerID, { "GOLD" }, fee)
		return
	end

	-- 3. Snapshot before anything changes.
	local snap = EFV_Units.Snapshot(pUnit)
	if snap == nil then
		EFV_Log(1, "Send", "snapshot failed player=%s unit=%s", tostring(playerID), tostring(unitID))
		RejectSend(playerID, { "REQ_STALE" })
		return
	end

	-- 4. Record (OUTBOUND). Snapshot fields are applied after New.
	local origin = calc.origin
	local fields = {
		forceType      = forceType,
		state          = EFV_Config.ST_OUTBOUND,
		senderID       = playerID,
		recipientID    = recipientID,
		accessBasis    = calc.basis,
		originCityID   = origin:GetID(),
		originX        = origin:GetX(),
		originY        = origin:GetY(),
		destCityID     = pCity:GetID(),
		destX          = pCity:GetX(),
		destY          = pCity:GetY(),
		destNameKey    = DestNameKey(pCity),   -- names a razed destination in the cancel texts
		sentX          = snap.lastX,           -- designer ruling 2026-09-30: a cancelled transit returns the unit here
		sentY          = snap.lastY,
		rerouted       = 0,                    -- schema stability; never set to 1 since the transit cancel
		sentTurn       = turn,
		arrivalTurn    = turn + calc.transit,
		transitTurns   = calc.transit,
		band           = calc.band,
		distance       = calc.distance,
		durationTurns  = calc.duration,  -- nil for VOLUNTEER
		lapsed         = 0,
		spawnFailCount = 0,
		feePaid        = fee,
		maintGoldPaid  = 0,
	}
	local rec = EFV_Records.New(store, fields)
	if rec == nil then
		EFV_Log(1, "Send", "record creation failed player=%s unit=%s", tostring(playerID), tostring(unitID))
		RejectSend(playerID, { "REQ_STALE" })
		return
	end
	EFV_Units.ApplySnapshot(rec, snap, turn)
	Touch(store)

	-- 5. Remove the unit; on failure drop the record, no gold is taken.
	if not EFV_Units.Remove(pUnit) then
		EFV_Log(1, "Send", "unit removal failed id=%d player=%s unit=%s", rec.id, tostring(playerID), tostring(unitID))
		EFV_Records.Delete(store, rec.id)
		RejectSend(playerID, { "REQ_STALE" })
		return
	end

	-- 6. Fee.
	if fee > 0 then
		pTreasury:ChangeGoldBalance(-fee)
	end

	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.DEPARTED, "LOC_" .. EFV_Config.NOTIF.DEPARTED,
		{ UnitName(rec), CityName(pCity), calc.transit }, rec.destX, rec.destY, Extra(rec, "DEPARTED"))
	EFV_Log(2, "Send", "ok id=%d force=%s sender=%d recipient=%d unit=%s type=%s fee=%d band=%s dist=%s transit=%d arrival=%d origin=%s dest=%d,%d basis=%s from=%s,%s",
		rec.id, forceType, playerID, recipientID, tostring(unitID), tostring(rec.unitType), fee,
		tostring(calc.band), tostring(calc.distance), calc.transit, rec.arrivalTurn,
		tostring(rec.originCityID), rec.destX, rec.destY, tostring(calc.basis),
		tostring(rec.sentX), tostring(rec.sentY))
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.OnRequestSend(playerID, params)
-- Handler of GameEvents.EFV_Send (spec 7.1; PLAN 1.5 handler contract):
-- pcall body; reject non-human requesters; load store; pUnit =
-- EFV_Units.Get(playerID, params.unitID), pCity = CityManager.GetCityAt(
-- params.destX, params.destY) (missing -> REQ_STALE); ok, reasons, calc =
-- EFV_EvaluateSend(playerID, pUnit, params.recipientID, pCity,
-- params.forceType, store); also reject if calc.fee > params.expectedFee
-- (FEE_CHANGED, DV5); on failure queue EFV_NOTIF_REQUEST_FAILED to playerID
-- with the first reason and log "[Send] rejected reasons=..."; else
-- EFV_Veteran.Settle(store, pUnit) runs before the re-validation (0.7).
-- WRONG_TERRITORY names the land owner (EFV_SendLandOwner). Then
-- snapshot, EFV_Records.New (state OUTBOUND, sentTurn, arrivalTurn = turn +
-- calc.transit, origin from calc.origin, dest, accessBasis = calc.basis,
-- durationTurns, feePaid, snapshot fields), EFV_Units.Remove,
-- ChangeGoldBalance(-calc.fee), queue EFV_NOTIF_DEPARTED (sender).
-- Commit, flush (both also after an error, so engine-side changes that
-- already happened are never left without their record).
-- Params:  playerID requesting player (authoritative), params table:
--          { unitID, recipientID, destX, destY, forceType, expectedFee }.
-- Returns: nil.
-- PLAN 1.5, 2.8; spec 7.1; DV1, DV5. APIs: A42, A44, A49 (+ helpers).
-- ---------------------------------------------------------------------------
function EFV_Transit.OnRequestSend(playerID, params)
	local store = nil
	local ok, err = pcall(function()
		local pPlayer = Players[playerID]
		if pPlayer == nil or not pPlayer:IsHuman() then
			EFV_Log(2, "Send", "rejected player=%s reasons=NOT_HUMAN_MAJOR", tostring(playerID))
			return
		end
		if type(params) ~= "table" then
			EFV_Log(1, "Send", "rejected player=%s: params missing", tostring(playerID))
			return
		end
		store = EFV_Records.Load()
		SendBody(playerID, params, store)
	end)
	if not ok then
		EFV_Log(1, "Send", "handler failed player=%s: %s", tostring(playerID), tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Send", "commit failed: %s", tostring(errC))
		end
	end
	local okF, errF = pcall(EFV_Notify.Flush)
	if not okF then
		EFV_Log(1, "Send", "flush failed: %s", tostring(errF))
	end
	return nil
end

-- ===========================================================================
-- Transit maintenance (step 1)
-- ===========================================================================

-- GameInfo.Units_XP2 row for a unit type. Primary: index by UnitType (the
-- table's primary key). Fallback: ordered iteration (deterministic).
local function UnitsXP2Row(unitType)
	local ok, row = pcall(function()
		return GameInfo.Units_XP2[unitType]
	end)
	if ok and row ~= nil then
		return row
	end
	local found = nil
	pcall(function()
		for r in GameInfo.Units_XP2() do
			if r.UnitType == unitType then
				found = r
				break
			end
		end
	end)
	return found
end

-- Strategic resource part of transit maintenance (spec 7.2, SPIKES S7, T14).
-- Never pushes the stockpile below 0. Separate pcall so a failing resource
-- API (A50 is LIKELY in G) does not block the gold part.
local function ChargeResource(rec, pPlayer)
	local row = UnitsXP2Row(rec.unitType)
	if row == nil then
		return
	end
	local amount = tonumber(row.ResourceMaintenanceAmount) or 0
	local resType = row.ResourceMaintenanceType
	if amount <= 0 or resType == nil or resType == "" then
		return
	end
	local resRow = GameInfo.Resources[resType]
	if resRow == nil then
		EFV_Log(1, "Maint", "unknown resource %s id=%d", tostring(resType), rec.id)
		return
	end
	local pRes = pPlayer:GetResources()
	local have = math.floor(tonumber(pRes:GetResourceAmount(resRow.Index)) or 0)
	local res = math.min(amount, math.max(0, have))
	if res > 0 then
		pRes:ChangeResourceAmount(resRow.Index, -res)
	end
	EFV_Log(2, "Maint", "rec=%d res=%d type=%s due=%d stock=%d", rec.id, res, tostring(resType), amount, have)
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.ChargeTransitMaintenance(store, turn)
-- Pipeline step 1 (spec 7.2). For each OUTBOUND / RETURNING record (id
-- order): gold amt = min(GameInfo.Units[t].Maintenance, max(0,
-- floor(balance))), ChangeGoldBalance(-amt), rec.maintGoldPaid += amt; if
-- FLAG_RESOURCE_MAINTENANCE and Units_XP2[t].ResourceMaintenanceAmount > 0:
-- res = min(amount, floor(GetResourceAmount(idx))), ChangeResourceAmount(
-- idx, -res) (S7). Never pushes a balance below 0. Records of a sender that
-- is no longer alive are skipped (ReconcilePlayers, step 0b, deletes them;
-- R2 orphans, EXP / CS in transit of an eliminated sender, pay nothing).
-- Logs "[Maint] rec=.. gold=..".
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 1, 2.8; spec 7.2; SPIKES S7, 3 rows 8, 9. APIs: A49, A50, A51.
-- ---------------------------------------------------------------------------
function EFV_Transit.ChargeTransitMaintenance(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and (rec.state == EFV_Config.ST_OUTBOUND or rec.state == EFV_Config.ST_RETURNING) then
			ForRecord("Maint", rec, function()
				if not IsAlive(rec.senderID) then
					EFV_Log(2, "Maint", "skip rec=%d sender=%s not alive", rec.id, tostring(rec.senderID))
					return
				end
				local pPlayer = Players[rec.senderID]
				local unitRow = GameInfo.Units[rec.unitType]
				local maint = 0
				if unitRow ~= nil then
					maint = tonumber(unitRow.Maintenance) or 0
				else
					EFV_Log(1, "Maint", "unknown unit type %s rec=%d", tostring(rec.unitType), rec.id)
				end
				local pTreasury = pPlayer:GetTreasury()
				local balance = math.floor(pTreasury:GetGoldBalance())
				local amt = math.min(maint, math.max(0, balance))
				if amt > 0 then
					pTreasury:ChangeGoldBalance(-amt)
				end
				rec.maintGoldPaid = (rec.maintGoldPaid or 0) + amt
				Touch(store)
				EFV_Log(2, "Maint", "rec=%d gold=%d due=%d balance=%d state=%s", rec.id, amt, maint, balance, rec.state)

				if EFV_Config.FLAG_RESOURCE_MAINTENANCE then
					local okR, errR = pcall(ChargeResource, rec, pPlayer)
					if not okR then
						EFV_Log(1, "Maint", "resource maintenance failed rec=%d: %s", rec.id, tostring(errR))
					end
				end
			end)
		end
	end
	return nil
end

-- ===========================================================================
-- Arrivals (step 2)
-- ===========================================================================

-- Spawn failed (no tile or creation failed): retry next turn, notify the
-- sender each turn, maintenance continues (spec 7.4 step 2). An eliminated
-- sender (R2 orphan arrival) is not notified; the retry goes on silently.
local function SpawnBlocked(store, rec, pCity, why)
	rec.spawnFailCount = (rec.spawnFailCount or 0) + 1
	Touch(store)
	if IsAlive(rec.senderID) then
		EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.SPAWN_BLOCKED, "LOC_" .. EFV_Config.NOTIF.SPAWN_BLOCKED,
			{ UnitName(rec), CityName(pCity) }, pCity:GetX(), pCity:GetY(), Extra(rec, "SPAWN_BLOCKED"))
	end
	EFV_Log(2, "Arrival", "blocked id=%d state=%s city=%d,%d why=%s fails=%d",
		rec.id, rec.state, pCity:GetX(), pCity:GetY(), tostring(why), rec.spawnFailCount)
end

-- Spawns rec around pCity for ownerID. Returns the new unit and plot, or nil
-- after SpawnBlocked. When Create returns nil on a plot (e.g. the plot
-- owner's borders are closed to ownerID, Session D 3), the next plots of
-- EFV_Spawn.PickOrdered are tried in the same call (bounded by
-- EFV_Config.SPAWN_CREATE_TRIES, no extra RNG calls).
local function SpawnAround(store, rec, pCity, ownerID, labelPrefix, turn)
	local domain = EFV_Spawn.DomainOf(rec.unitType)
	if domain == nil then
		EFV_Log(1, "Arrival", "unknown domain for %s id=%d", tostring(rec.unitType), rec.id)
		SpawnBlocked(store, rec, pCity, "DOMAIN")
		return nil
	end
	local plots = EFV_Spawn.PickOrdered(pCity:GetX(), pCity:GetY(), domain, ownerID, labelPrefix .. rec.id)
	if #plots == 0 then
		SpawnBlocked(store, rec, pCity, "NO_TILE")
		return nil
	end
	for i, plot in ipairs(plots) do
		local pNew = EFV_Units.Recreate(store, ownerID, rec, plot, turn)
		if pNew ~= nil then
			if i > 1 then
				EFV_Log(2, "Arrival", "recreate id=%d succeeded on try %d at %d,%d", rec.id, i, plot:GetX(), plot:GetY())
			end
			return pNew, plot
		end
		EFV_Log(2, "Arrival", "recreate returned nil id=%d type=%s owner=%d plot=%d,%d plotOwner=%s try=%d/%d",
			rec.id, tostring(rec.unitType), ownerID, plot:GetX(), plot:GetY(), tostring(plot:GetOwner()), i, #plots)
	end
	EFV_Log(1, "Arrival", "recreate failed id=%d type=%s owner=%d tries=%d",
		rec.id, tostring(rec.unitType), ownerID, #plots)
	SpawnBlocked(store, rec, pCity, "CREATE_FAILED")
	return nil
end

-- Designer ruling 2026-09-30 (sender eliminated, R2): an Expeditionary or
-- City-State unit in transit of an eliminated sender still arrives, as the
-- recipient's own permanent unit (no service timer, no return, no mutiny, no
-- tracker row: the record is deleted once the unit has spawned). Outbound
-- Volunteers, or a recipient that is gone too, -> lost. Destination no longer
-- the recipient's -> the recipient's city nearest to it (designer answer Q4);
-- no city -> lost. Blocked -> stays OUTBOUND and retries silently.
local function ArriveOrphan(store, rec, turn)
	if rec.forceType == EFV_Config.FT_VOL or not IsAlive(rec.recipientID) then
		EFV_Log(2, "Arrival", "orphan id=%d force=%s recipient=%s alive=%s -> lost, record deleted",
			rec.id, tostring(rec.forceType), tostring(rec.recipientID), tostring(IsAlive(rec.recipientID)))
		EFV_Records.Delete(store, rec.id)
		return
	end
	local pCity = CityManager.GetCityAt(rec.destX, rec.destY)
	if pCity == nil or pCity:GetOwner() ~= rec.recipientID then
		pCity = EFV_NearestCity(rec.recipientID, rec.destX, rec.destY)
		if pCity == nil then
			EFV_Log(2, "Arrival", "orphan id=%d: recipient %d has no city -> lost, record deleted", rec.id, rec.recipientID)
			EFV_Records.Delete(store, rec.id)
			return
		end
		EFV_Log(2, "Arrival", "orphan id=%d: destination lost -> the recipient's nearest city %d at %d,%d",
			rec.id, pCity:GetID(), pCity:GetX(), pCity:GetY())
	end
	local pNew, plot = SpawnAround(store, rec, pCity, rec.recipientID, "arr", turn)
	if pNew == nil then
		return
	end
	local typeName = EFV_Config.NOTIF.ARRIVED
	EFV_Notify.Queue(rec.recipientID, typeName, "LOC_" .. typeName .. "_KEPT",
		{ UnitName(rec), PlayerName(rec.senderID), CityName(pCity) }, plot:GetX(), plot:GetY(), Extra(rec, "KEPT"))
	EFV_Log(2, "Arrival", "orphan id=%d force=%s sender=%d (gone) -> owner=%d unit=%d at %d,%d: the recipient's own unit, record closed",
		rec.id, tostring(rec.forceType), rec.senderID, rec.recipientID, pNew:GetID(), plot:GetX(), plot:GetY())
	EFV_Records.Delete(store, rec.id)
end

local function ArriveOutbound(store, rec, turn)
	-- Designer ruling 2026-09-30 (sender eliminated): EXP / CS units still
	-- arrive, as the recipient's own units; outbound Volunteers are lost.
	if not IsAlive(rec.senderID) then
		ArriveOrphan(store, rec, turn)
		return
	end
	-- Designer ruling 2026-09-30 (transit cancel): the last check before the
	-- unit lands (step 0b normally ran it moments ago). Any failed condition
	-- cancels the transit; there is no reroute any more.
	if EFV_Transit.CheckOutbound(store, rec, turn, "Arrival") ~= "OK" then
		return
	end
	local pCity = CityManager.GetCityAt(rec.destX, rec.destY)
	if pCity == nil then
		EFV_Log(1, "Arrival", "destination missing after a passing check id=%d at=%d,%d", rec.id, rec.destX, rec.destY)
		return
	end

	-- New owner: recipient (EXP, CS), sender (VOL); spec 7.4 step 3.
	local ownerID = rec.recipientID
	if rec.forceType == EFV_Config.FT_VOL then
		ownerID = rec.senderID
	end

	local pNew, plot = SpawnAround(store, rec, pCity, ownerID, "arr", turn)
	if pNew == nil then
		return
	end

	rec.state         = EFV_Config.ST_DEPLOYED
	rec.deployedTurn  = turn
	rec.onMapPlayerID = ownerID
	rec.onMapUnitID   = pNew:GetID()
	rec.lastX         = plot:GetX()
	rec.lastY         = plot:GetY()
	Touch(store)

	local args = { UnitName(rec), PlayerName(rec.senderID), CityName(pCity) }
	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.ARRIVED, "LOC_" .. EFV_Config.NOTIF.ARRIVED,
		args, rec.lastX, rec.lastY, Extra(rec, "ARRIVED"))
	if rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, EFV_Config.NOTIF.ARRIVED, "LOC_" .. EFV_Config.NOTIF.ARRIVED,
			args, rec.lastX, rec.lastY, Extra(rec, "ARRIVED"))
	end
	EFV_Log(2, "Arrival", "id=%d plot=%d,%d owner=%d unit=%d force=%s city=%d,%d rerouted=%s fails=%s",
		rec.id, rec.lastX, rec.lastY, ownerID, rec.onMapUnitID, tostring(rec.forceType),
		pCity:GetX(), pCity:GetY(), tostring(rec.rerouted), tostring(rec.spawnFailCount))
end

local function ArriveReturning(store, rec, turn)
	if not IsAlive(rec.senderID) then
		-- Backup: ReconcilePlayers (step 0b) deletes records of a dead sender.
		EFV_Log(2, "Return", "skip id=%d sender=%s not alive", rec.id, tostring(rec.senderID))
		return
	end

	-- Spec 10.2 step 4: return city lost in transit -> re-resolve (10.1)
	-- without recalculating transit time.
	local pCity = nil
	if rec.returnX ~= nil and rec.returnY ~= nil then
		pCity = CityManager.GetCityAt(rec.returnX, rec.returnY)
	end
	if pCity == nil or pCity:GetOwner() ~= rec.senderID then
		pCity = EFV_Transit.ResolveReturnCity(rec)
		if pCity == nil then
			EFV_Log(2, "Return", "lost id=%d reason=NO_CITY sender=%d", rec.id, rec.senderID)
			NotifyUnitLost(rec, "NO_CITY", false)
			EFV_Records.Delete(store, rec.id)
			return
		end
		EFV_Log(2, "Return", "re-resolved id=%d city=%d at=%d,%d", rec.id, pCity:GetID(), pCity:GetX(), pCity:GetY())
		rec.returnCityID = pCity:GetID()
		rec.returnX      = pCity:GetX()
		rec.returnY      = pCity:GetY()
		Touch(store)
	end

	local pNew, plot = SpawnAround(store, rec, pCity, rec.senderID, "ret", turn)
	if pNew == nil then
		return
	end

	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.RETURNED, "LOC_" .. EFV_Config.NOTIF.RETURNED,
		{ UnitName(rec), CityName(pCity) }, plot:GetX(), plot:GetY(), Extra(rec, "RETURNED"))
	EFV_Log(2, "Return", "arrived id=%d reason=%s plot=%d,%d unit=%d city=%d",
		rec.id, tostring(rec.returnReason), plot:GetX(), plot:GetY(), pNew:GetID(), pCity:GetID())
	EFV_Records.Delete(store, rec.id)
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.ProcessArrivals(store, turn)
-- Pipeline step 2 (spec 7.4, 10.2), for records with arrivalTurn <= turn:
-- OUTBOUND: sender eliminated -> ArriveOrphan (R2: EXP / CS arrive as the
-- recipient's own units, record deleted; VOL lost); else the transit check
-- once more (CheckOutbound hook "Arrival": any failed condition cancels the
-- transit, no reroute, DECISIONS "Transit cancelled"); else spawn. New owner
-- = recipient (EXP, CS) or sender (VOL). plot = EFV_Spawn.Pick(city, domain, owner, "arr" ..
-- id); nil (or Recreate failed) -> spawnFailCount + 1, queue
-- EFV_NOTIF_SPAWN_BLOCKED (sender), keep record; else EFV_Units.Recreate,
-- state DEPLOYED, deployedTurn = turn, onMap*, lastX/Y, queue
-- EFV_NOTIF_ARRIVED (sender and recipient).
-- RETURNING: re-resolve the return city if lost (ResolveReturnCity, no
-- transit recalculation, spec 10.2.4); none -> delete, EFV_NOTIF_UNIT_LOST
-- (NO_CITY) to sender; spawn around it as sender; blocked -> retry next
-- turn; success -> delete record, EFV_NOTIF_RETURNED. Logs "[Arrival] ...",
-- "[Return] ...".
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 2, 2.8. APIs: A42, A44, A46 (+ helpers).
-- ---------------------------------------------------------------------------
function EFV_Transit.ProcessArrivals(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.arrivalTurn ~= nil and rec.arrivalTurn <= turn then
			if rec.state == EFV_Config.ST_OUTBOUND then
				ForRecord("Arrival", rec, ArriveOutbound, store, rec, turn)
			elseif rec.state == EFV_Config.ST_RETURNING then
				ForRecord("Return", rec, ArriveReturning, store, rec, turn)
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.ResolveReturnCity(rec) -> city
-- Spec 10.1: the origin city if CityManager.GetCityAt(originX, originY) is
-- owned by the sender; else EFV_NearestCity(senderID, originX, originY);
-- else Players[senderID]:GetCities():GetCapitalCity(); else nil.
-- Params:  rec record.
-- Returns: city object or nil.
-- PLAN 2.8; spec 10.1. APIs: A44, A45.
-- ---------------------------------------------------------------------------
function EFV_Transit.ResolveReturnCity(rec)
	local senderID = rec.senderID
	local pSender = Players[senderID]
	if pSender == nil then
		return nil
	end
	if rec.originX ~= nil and rec.originY ~= nil then
		local pCity = CityManager.GetCityAt(rec.originX, rec.originY)
		if pCity ~= nil and pCity:GetOwner() == senderID then
			return pCity
		end
		local pNear = EFV_NearestCity(senderID, rec.originX, rec.originY)
		if pNear ~= nil then
			return pNear
		end
	end
	local ok, pCap = pcall(function()
		return pSender:GetCities():GetCapitalCity()
	end)
	if ok and pCap ~= nil then
		return pCap
	end
	return nil
end

-- ===========================================================================
-- Transit check (designer ruling 2026-09-30; DECISIONS "Transit cancelled",
-- "Recipient eliminated with units in transit"; INTERFACES note 34)
-- ===========================================================================

-- Rule code (EFV_SendRecipientReasons) -> cancel status, after the war check.
local CANCEL_STATUS_OF = {
	NOT_PARTNER      = "NOT_PARTNER",
	VOL_NEEDS_ACCESS = "NO_ACCESS",
	NO_COMMON_WAR    = "NO_COMMON_WAR",
}

-- Recipient texts whose sender wording does not fit the recipient
-- (LOC_EFV_CANCEL_REASON_<status>_HOST, {1_Civ} = the sender civ). The
-- other reason texts read the same from both sides (designer answer Q8:
-- the recipient's notice gives the reason too).
local HOST_REASON_SUFFIX = {
	NO_ACCESS    = "_HOST",
	NOT_ELIGIBLE = "_HOST",
}

-- Session-local log throttle for evaluation errors (log only; it cannot
-- make clients diverge). Key "id:turn".
local m_EvalErrLogged = {}

local function EvalError(rec, what)
	local key = tostring(rec.id) .. ":" .. tostring(CurrentTurn())
	if not m_EvalErrLogged[key] then
		m_EvalErrLogged[key] = true
		EFV_Log(1, "Cancel", "id=%s: %s; not cancelled", tostring(rec.id), tostring(what))
	end
	return "OK", "EVAL_ERROR"
end

-- The tile the unit left from: rec.sentX / sentY (sends since the transit
-- cancel), else rec.lastX / lastY (every older OUTBOUND record: nothing
-- writes lastX / lastY while a record is OUTBOUND, so it is the send tile).
-- Returns x, y, source ("sent" / "legacy") or nil, nil, "none".
local function OriginTile(rec)
	if rec.sentX ~= nil and rec.sentY ~= nil and EFV_Units.ValidPosition(rec.sentX, rec.sentY) then
		return rec.sentX, rec.sentY, "sent"
	end
	if rec.lastX ~= nil and rec.lastY ~= nil and EFV_Units.ValidPosition(rec.lastX, rec.lastY) then
		return rec.lastX, rec.lastY, "legacy"
	end
	return nil, nil, "none"
end

-- Recreates rec for ownerID on (cx, cy) itself (tryCentre, when
-- EFV_SpawnValid passes: free, not enemy land, enterable) or else on the
-- plots of EFV_Spawn.PickOrdered around it (nearest ring first, one synced
-- RNG pick inside that ring, at most SPAWN_CREATE_TRIES plots). A nil Create
-- tries the next plot.
-- Returns pNew, plot, ring, tries (pNew nil when nothing worked).
local function PlaceNear(store, rec, cx, cy, domain, ownerID, label, turn, tryCentre)
	local tries = 0
	if tryCentre then
		local here = Map.GetPlot(cx, cy)
		if here ~= nil and EFV_SpawnValid(here, domain, ownerID, nil) then
			tries = 1
			local pNew = EFV_Units.Recreate(store, ownerID, rec, here, turn)
			if pNew ~= nil then
				return pNew, here, 0, tries
			end
			EFV_Log(2, "Cancel", "recreate returned nil id=%d at=%d,%d (the tile itself)", rec.id, cx, cy)
		end
	end
	for _, plot in ipairs(EFV_Spawn.PickOrdered(cx, cy, domain, ownerID, label .. rec.id)) do
		tries = tries + 1
		local pNew = EFV_Units.Recreate(store, ownerID, rec, plot, turn)
		if pNew ~= nil then
			return pNew, plot, Map.GetPlotDistance(cx, cy, plot:GetX(), plot:GetY()), tries
		end
		EFV_Log(2, "Cancel", "recreate returned nil id=%d at=%d,%d plotOwner=%s try=%d",
			rec.id, plot:GetX(), plot:GetY(), tostring(plot:GetOwner()), tries)
	end
	return nil, nil, nil, tries
end

-- Localized reason text LOC_EFV_CANCEL_REASON_<status> {1_Civ = civID};
-- host = the recipient's copy (_HOST variant where the wording differs).
local function ReasonTextFor(status, civID, host)
	local key = "LOC_EFV_CANCEL_REASON_" .. tostring(status)
	if host and HOST_REASON_SUFFIX[status] ~= nil then
		key = key .. HOST_REASON_SUFFIX[status]
	end
	local ok, s = pcall(Locale.Lookup, key, PlayerName(civID))
	if ok and type(s) == "string" then
		return s
	end
	return tostring(status)
end

local function RefundText(fee, refund)
	if fee <= 0 then
		return Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")
	end
	return Locale.Lookup("LOC_EFV_CANCEL_REFUND", refund)
end

-- Cancel notices (one-off, created at the start of the sender's turn):
-- sender RETURNED _CANCELLED (placed, at the unit) or RETURNING _CANCELLED
-- (fallback B, at the home city); a living recipient other than the sender
-- ARRIVED _CANCELLED at the destination (EFV_Notify.Queue skips AI players
-- and city-states).
local function NotifyCancelled(rec, status, fee, refund, plot, pHome)
	local unit = UnitName(rec)
	local dest = DestName(rec)
	local reason = ReasonTextFor(status, rec.recipientID, false)
	local refundText = RefundText(fee, refund)
	if plot ~= nil then
		local typeName = EFV_Config.NOTIF.RETURNED
		EFV_Notify.Queue(rec.senderID, typeName, "LOC_" .. typeName .. "_CANCELLED",
			{ unit, dest, reason, refundText }, plot:GetX(), plot:GetY(), Extra(rec, "CANCELLED"))
	elseif pHome ~= nil then
		local typeName = EFV_Config.NOTIF.RETURNING
		EFV_Notify.Queue(rec.senderID, typeName, "LOC_" .. typeName .. "_CANCELLED",
			{ unit, dest, reason, CityName(pHome), rec.transitTurns or 1, refundText },
			pHome:GetX(), pHome:GetY(), Extra(rec, "CANCELLED"))
	end
	if rec.recipientID ~= nil and rec.recipientID ~= rec.senderID and IsAlive(rec.recipientID) then
		local typeName = EFV_Config.NOTIF.ARRIVED
		EFV_Notify.Queue(rec.recipientID, typeName, "LOC_" .. typeName .. "_CANCELLED",
			{ unit, PlayerName(rec.senderID), dest, ReasonTextFor(status, rec.senderID, true) },
			rec.destX, rec.destY, Extra(rec, "CANCELLED"))
	end
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.OutboundStatus(rec) -> status, code
-- Pure read (no store writes). In this order: "NONE" (no OUTBOUND record),
-- "ORPHAN" (sender not alive: never cancelled, R2), "RECIPIENT_GONE"
-- (recipient not alive, R3), "DEST_LOST" (code "NO_CITY": no city at
-- destX / destY; "OWNER": the city belongs to someone else; "CONQUERED":
-- rec.destLost == 1, captured since the send even if taken back), "WAR"
-- (AT_WAR_WITH_RECIPIENT among the recipient reasons), then by the first
-- recipient reason: "NOT_PARTNER", "NO_ACCESS" (VOL_NEEDS_ACCESS),
-- "NO_COMMON_WAR", "NOT_ELIGIBLE" (any other code), else "OK". An engine
-- or rule error -> "OK", "EVAL_ERROR" (fail safe: never cancel on an
-- internal error; ERROR logged once per record and turn). Unit-level send
-- checks are not rechecked; band and fee are not recomputed.
-- Params:  rec record.
-- Returns: status string, code string or nil (logs only).
-- ---------------------------------------------------------------------------
function EFV_Transit.OutboundStatus(rec)
	if rec == nil or rec.state ~= EFV_Config.ST_OUTBOUND then
		return "NONE", nil
	end
	if not IsAlive(rec.senderID) then
		return "ORPHAN", nil
	end
	if not IsAlive(rec.recipientID) then
		return "RECIPIENT_GONE", nil
	end
	local okC, pCity = pcall(CityManager.GetCityAt, rec.destX, rec.destY)
	if not okC then
		return EvalError(rec, "destination lookup failed: " .. tostring(pCity))
	end
	if pCity == nil then
		return "DEST_LOST", "NO_CITY"
	end
	local okO, owner = pcall(function() return pCity:GetOwner() end)
	if not okO then
		return EvalError(rec, "destination owner failed: " .. tostring(owner))
	end
	if owner ~= rec.recipientID then
		return "DEST_LOST", "OWNER"
	end
	if rec.destLost == 1 then
		return "DEST_LOST", "CONQUERED"
	end
	local reasons = EFV_SendRecipientReasons(rec.senderID, rec.recipientID, rec.forceType)
	if type(reasons) ~= "table" then
		return EvalError(rec, "rules could not be evaluated")
	end
	for _, code in ipairs(reasons) do
		if code == "REQ_STALE" then
			return EvalError(rec, "rules could not be evaluated")
		end
	end
	for _, code in ipairs(reasons) do
		if code == "AT_WAR_WITH_RECIPIENT" then
			return "WAR", code
		end
	end
	local first = reasons[1]
	if first == nil then
		return "OK", nil
	end
	return CANCEL_STATUS_OF[first] or "NOT_ELIGIBLE", first
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.CheckOutbound(store, rec, turn, hook) -> status
-- The transit check of one record: OutboundStatus; "OK" / "ORPHAN" /
-- "NONE" -> nothing; any other status -> CancelOutbound. A record whose
-- cancel already started (rec.refundPaid set, e.g. an error during the
-- placement) is cancelled again with its stored reason, whatever the
-- conditions are now (no second refund).
-- Params:  store, rec record, turn number, hook string (log:
--          "OnGameTurnStarted", "PlayerTurnStarted", "Arrival", "War").
-- Returns: the status.
-- ---------------------------------------------------------------------------
function EFV_Transit.CheckOutbound(store, rec, turn, hook)
	if rec == nil or rec.state ~= EFV_Config.ST_OUTBOUND then
		return "NONE"
	end
	if rec.refundPaid ~= nil and type(rec.cancelReason) == "string" and IsAlive(rec.senderID) then
		local reason = rec.cancelReason
		EFV_Transit.CancelOutbound(store, rec, reason, turn, hook, "RESUMED")
		return reason
	end
	local status, code = EFV_Transit.OutboundStatus(rec)
	if status == "OK" or status == "ORPHAN" or status == "NONE" then
		return status
	end
	EFV_Transit.CancelOutbound(store, rec, status, turn, hook, code)
	return status
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.CancelOutbound(store, rec, status, turn, hook, code) -> result
-- Cancels an OUTBOUND transit (sender alive). 1. Refund once: floor(fee *
-- TRANSIT_CANCEL_REFUND_PCT / 100) of rec.feePaid (nil -> 0) to the sender
-- (ChangeGoldBalance, A49); rec.refundPaid / cancelReason / cancelTurn are
-- set before anything is placed. 2. The unit is recreated for the sender
-- (all three force types) on its origin tile (OriginTile) or the nearest
-- valid free tile within SPAWN_SEARCH_MAX_RING ("cxl" .. id), else around
-- the return city (ResolveReturnCity, "cxc" .. id). 3. Placed -> record
-- deleted, RETURNED _CANCELLED (sender), ARRIVED _CANCELLED (recipient).
-- Nothing free but a return city -> RETURNING "CANCELLED" to it (quiet
-- EnterReturning, band from the origin tile), RETURNING _CANCELLED. No city
-- at all -> lost (UNIT_LOST NO_CITY, record deleted; the refund stays paid).
-- Logs "[Cancel] ...".
-- Params:  store, rec record (OUTBOUND), status (OutboundStatus), turn
--          number (nil -> current), hook string, code string (logs).
-- Returns: "PLACED" | "RETURNING" | "LOST".
-- ---------------------------------------------------------------------------
function EFV_Transit.CancelOutbound(store, rec, status, turn, hook, code)
	if turn == nil then
		turn = CurrentTurn()
	end
	local fee = math.max(0, math.floor(tonumber(rec.feePaid) or 0))
	local refund = 0
	if rec.refundPaid == nil then
		refund = math.floor(fee * (EFV_Config.TRANSIT_CANCEL_REFUND_PCT or 50) / 100)
		rec.refundPaid   = refund
		rec.cancelReason = status
		rec.cancelTurn   = turn
		Touch(store)
		if refund > 0 then
			local okG, errG = pcall(function()
				Players[rec.senderID]:GetTreasury():ChangeGoldBalance(refund)
			end)
			if not okG then
				EFV_Log(1, "Cancel", "refund failed id=%d gold=%d: %s", rec.id, refund, tostring(errG))
			end
		end
	else
		refund = tonumber(rec.refundPaid) or 0
	end

	local ox, oy, src = OriginTile(rec)
	EFV_Log(2, "Cancel", "id=%d force=%s sender=%s recipient=%s reason=%s code=%s hook=%s dest=%s,%s fee=%d refund=%d origin=%s,%s (%s)",
		rec.id, tostring(rec.forceType), tostring(rec.senderID), tostring(rec.recipientID), tostring(status),
		tostring(code), tostring(hook), tostring(rec.destX), tostring(rec.destY), fee, refund,
		tostring(ox), tostring(oy), src)

	local domain = EFV_Spawn.DomainOf(rec.unitType)
	local pHome = EFV_Transit.ResolveReturnCity(rec)
	local pNew, plot, ring, tries, where = nil, nil, nil, 0, nil
	if domain ~= nil and ox ~= nil then
		pNew, plot, ring, tries = PlaceNear(store, rec, ox, oy, domain, rec.senderID, "cxl", turn, true)
		where = "origin"
	end
	if pNew == nil and domain ~= nil and pHome ~= nil then
		local more = 0
		pNew, plot, ring, more = PlaceNear(store, rec, pHome:GetX(), pHome:GetY(), domain, rec.senderID, "cxc", turn, false)
		tries = tries + more
		where = "home"
	end

	if pNew ~= nil then
		NotifyCancelled(rec, status, fee, refund, plot, nil)
		EFV_Log(2, "Cancel", "placed id=%d unit=%d at=%d,%d ring=%s where=%s tries=%d",
			rec.id, pNew:GetID(), plot:GetX(), plot:GetY(), tostring(ring), where, tries)
		EFV_Records.Delete(store, rec.id)
		return "PLACED"
	end
	if pHome == nil then
		EFV_Log(2, "Cancel", "lost id=%d reason=NO_CITY sender=%s", rec.id, tostring(rec.senderID))
		NotifyUnitLost(rec, "NO_CITY", false)
		EFV_Records.Delete(store, rec.id)
		return "LOST"
	end
	EnterReturning(store, rec, pHome, "CANCELLED", ox or rec.destX, oy or rec.destY, turn, true)
	NotifyCancelled(rec, status, fee, refund, nil, pHome)
	EFV_Log(2, "Cancel", "no free tile id=%d near=%s,%s tries=%d -> returning to city=%s at=%d,%d arrival=%s",
		rec.id, tostring(ox), tostring(oy), tries, tostring(rec.returnCityID), pHome:GetX(), pHome:GetY(),
		tostring(rec.arrivalTurn))
	return "RETURNING"
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.CheckTransits(store, turn, hook, senderID) -> n
-- The transit check for every OUTBOUND record (id order) of senderID (nil:
-- all senders); per-record pcall. Called by EFV_Lifecycle.TurnBoundaryPass
-- at GameEvents.PlayerTurnStarted(senderID): in sequential turns and
-- hotseat, changes other players made earlier in the round are seen before
-- the sender acts.
-- Params:  store, turn number, hook string (log), senderID or nil.
-- Returns: number of cancelled transits.
-- ---------------------------------------------------------------------------
function EFV_Transit.CheckTransits(store, turn, hook, senderID)
	local n, seen = 0, 0
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.state == EFV_Config.ST_OUTBOUND and (senderID == nil or rec.senderID == senderID) then
			seen = seen + 1
			local status = "OK"
			ForRecord("Cancel", rec, function()
				status = EFV_Transit.CheckOutbound(store, rec, turn, hook)
			end)
			if status ~= "OK" and status ~= "ORPHAN" and status ~= "NONE" then
				n = n + 1
			end
		end
	end
	EFV_Log(3, "Cancel", "check hook=%s sender=%s outbound=%d cancelled=%d", tostring(hook), tostring(senderID), seen, n)
	return n
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.MarkDestinationConquered(store, x, y, capturerID, oldOwnerID,
--   turn) -> n
-- Called from GameEvents.CityConquered (EFV_Lifecycle.OnCityConquered,
-- synchronous): every OUTBOUND record whose destination is the plot (x, y)
-- gets rec.destLost = 1 (write-once), so a capture and recapture between
-- two check points still cancels (designer answer Q5). The cancel itself
-- happens at the next check point, never inside the combat resolution.
-- Params:  store, x, y (event plot), capturerID, oldOwnerID, turn (logs).
-- Returns: number of records marked.
-- ---------------------------------------------------------------------------
function EFV_Transit.MarkDestinationConquered(store, x, y, capturerID, oldOwnerID, turn)
	local n = 0
	if x == nil or y == nil then
		return n
	end
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.state == EFV_Config.ST_OUTBOUND and rec.destX == x and rec.destY == y and rec.destLost ~= 1 then
			rec.destLost = 1
			Touch(store)
			n = n + 1
			EFV_Log(2, "Cancel", "mark id=%d dest=%d,%d capturer=%s oldOwner=%s turn=%s (checked at the next check point)",
				rec.id, x, y, tostring(capturerID), tostring(oldOwnerID), tostring(turn))
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- EFV_Transit.StartReturn(store, rec, pUnit, reason, turn) -> returning
-- Spec 10.2, for an on-map record (DEPLOYED / GRACE / MUTINY). city =
-- ResolveReturnCity(rec); nil -> remove the unit if any, delete the record,
-- queue EFV_NOTIF_UNIT_LOST (NO_CITY) to the sender and, if the unit was on
-- the recipient's side (onMapUnitID set), to the recipient. Else: snapshot
-- (if pUnit), remove, state = "RETURNING", arrivalTurn = turn + band(city,
-- destX, destY), returnCityID/X/Y, returnReason = reason, clear
-- onMapPlayerID/onMapUnitID, graceTurnsLeft, lastDamage, lapse fields; queue
-- EFV_NOTIF_RETURNING (sender). A given pUnit is settled first
-- (EFV_Veteran.Settle, 0.7). If the unit cannot be removed the record is
-- left unchanged (logged; retried by the caller next turn) and false is
-- returned. Logs "[Return] start reason=...".
-- Params:  store; rec record; pUnit unit object or nil (then the stored
--          snapshot is used, S9); reason string (return reasons above);
--          turn number (nil -> current turn).
-- Returns: true if the record is now RETURNING, false otherwise.
-- PLAN 2.8; spec 10.2. APIs: via helpers.
-- ---------------------------------------------------------------------------
function EFV_Transit.StartReturn(store, rec, pUnit, reason, turn)
	if turn == nil then
		turn = CurrentTurn()
	end
	-- Route B (0.7): finish an open veteran-restore job before any snapshot.
	Settle(store, pUnit, "Return")
	local pCity = EFV_Transit.ResolveReturnCity(rec)
	if pCity == nil then
		if pUnit ~= nil then
			local okS, snap = pcall(EFV_Units.Snapshot, pUnit)
			if okS and snap ~= nil then
				rec.lastX, rec.lastY = snap.lastX, snap.lastY
			end
			EFV_Units.Remove(pUnit)
		end
		local wasOnMap = rec.onMapUnitID ~= nil
		EFV_Log(2, "Return", "lost id=%d reason=NO_CITY trigger=%s sender=%d", rec.id, tostring(reason), rec.senderID)
		NotifyUnitLost(rec, "NO_CITY", wasOnMap)
		EFV_Records.Delete(store, rec.id)
		return false
	end

	if pUnit ~= nil then
		local snap = EFV_Units.Snapshot(pUnit)
		if snap ~= nil then
			EFV_Units.ApplySnapshot(rec, snap, turn)
			Touch(store)
		else
			EFV_Log(1, "Return", "snapshot failed id=%d; using stored snapshot (snapTurn=%s)", rec.id, tostring(rec.snapTurn))
		end
		if not EFV_Units.Remove(pUnit) then
			EFV_Log(1, "Return", "unit removal failed id=%d reason=%s; record unchanged", rec.id, tostring(reason))
			return false
		end
	end

	EnterReturning(store, rec, pCity, reason, rec.destX, rec.destY, turn)
	return true
end

EFV_Transit.LOADED = 1
