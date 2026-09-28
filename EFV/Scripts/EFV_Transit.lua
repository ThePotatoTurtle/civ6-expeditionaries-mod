-- ===========================================================================
-- EFV_Transit.lua
-- Module:   EFV_Transit (global table)
-- Context:  gameplay only, include("EFV_Transit").
-- Owner:    WP1.4 (CS branches WP4.2).
--
-- Responsibility (PLAN 2.8; spec 7, 10): the EFV_Send request handler,
-- transit maintenance (pipeline step 1), arrivals of outbound and returning
-- records incl. spawn retries (step 2), reroute when the destination city is
-- lost, return-city resolution, and the two ways a record enters RETURNING
-- (StartReturn from the map, ConvertToReturn from OUTBOUND).
--
-- Return reasons (record.returnReason): "EXPIRED", "GRACE_RETURN",
-- "MUTINY_RETURN", "RECALL", "DEST_LOST", "RECIPIENT_GONE", "WAR".
-- GRACE_RETURN / MUTINY_RETURN are EXP / CS only: a lapsed Volunteer never
-- returns by itself; on valid land its lapse is paused and Recall is its way
-- home (designer ruling "Lapsed Volunteers on valid land", INTERFACES note 29).
--
-- Notification text arguments (EFV_Notify.Queue args, in placeholder order;
-- all strings already localized in gameplay, PLAN 2.7):
--   DEPARTED       {1 unit, 2 destination city, 3 N transit turns}
--   ARRIVED        {1 unit, 2 sender civ, 3 city}
--   SPAWN_BLOCKED  {1 unit, 2 city}
--   RETURNING      {1 unit, 2 return city, 3 N transit turns}
--   RETURNED       {1 unit, 2 city}
--   REROUTED       {1 lost city, 2 unit, 3 new city}
--   UNIT_LOST      {1 unit, 2 loss text (LOC_EFV_LOSS_*)}
--   REQUEST_FAILED {1 reason text (LOC_EFV_REASON_<CODE>)}
-- extra = { recordID = rec.id, kind = <EFV_Config.NOTIF key> }.
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

-- Name of the city at (x, y), or "(x,y)" when no city stands there any more.
local function CityNameAt(x, y)
	local pCity = nil
	if x ~= nil and y ~= nil then
		pCity = CityManager.GetCityAt(x, y)
	end
	if pCity ~= nil then
		return CityName(pCity)
	end
	return "(" .. tostring(x) .. "," .. tostring(y) .. ")"
end

-- Reason codes whose text names the recipient ({1_Name}): the shared list
-- EFV_Rules.NAME_REASON_CODES (also used by EFV_UIShared).
local NAME_REASONS = {}
for _, code in ipairs(EFV_Rules.NAME_REASON_CODES) do
	NAME_REASONS[code] = true
end

-- Localized reason text for EFV_NOTIF_REQUEST_FAILED (LOC_EFV_REASON_<CODE>).
-- Argument contract (EFV_Text.xml): GOLD / FEE_CHANGED {1_Num} = fee;
-- NAME_REASONS {1_Name} = recipient civ name; all others none.
local function ReasonText(code, fee, recipientID)
	local key = "LOC_EFV_REASON_" .. tostring(code)
	local arg = nil
	if code == "GOLD" or code == "FEE_CHANGED" then
		arg = fee or 0
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
-- the lost destination (spec 7.3, DV14). Clears on-map, grace, mutiny and
-- lapse fields (incl. lapsePaused). Queues EFV_NOTIF_RETURNING (sender).
local function EnterReturning(store, rec, pCity, reason, fromX, fromY, turn)
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

	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.RETURNING, "LOC_" .. EFV_Config.NOTIF.RETURNING,
		{ UnitName(rec), CityName(pCity), band }, cx, cy, Extra(rec, "RETURNING"))
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
-- recipient-level reasons).
local function RejectSend(playerID, reasons, fee, recipientID)
	EFV_Log(2, "Send", "rejected player=%s reasons=%s", tostring(playerID), table.concat(reasons, ","))
	local first = reasons[1] or "REQ_STALE"
	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.REQUEST_FAILED, "LOC_" .. EFV_Config.NOTIF.REQUEST_FAILED,
		{ ReasonText(first, fee, recipientID) }, nil, nil, { kind = "REQUEST_FAILED" })
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

	-- 2. Full re-validation with the shared rules (G adapters).
	local ok, reasons, calc = EFV_EvaluateSend(playerID, pUnit, recipientID, pCity, forceType, store)
	if not ok then
		if reasons == nil or #reasons == 0 then
			reasons = { "REQ_STALE" }
		end
		RejectSend(playerID, reasons, calc and calc.fee, recipientID)
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
		rerouted       = 0,
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
	EFV_Log(2, "Send", "ok id=%d force=%s sender=%d recipient=%d unit=%s type=%s fee=%d band=%s dist=%s transit=%d arrival=%d origin=%s dest=%d,%d basis=%s",
		rec.id, forceType, playerID, recipientID, tostring(unitID), tostring(rec.unitType), fee,
		tostring(calc.band), tostring(calc.distance), calc.transit, rec.arrivalTurn,
		tostring(rec.originCityID), rec.destX, rec.destY, tostring(calc.basis))
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
-- is no longer alive are skipped (ReconcilePlayers, step 0b, deletes them).
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
-- sender each turn, maintenance continues (spec 7.4 step 2).
local function SpawnBlocked(store, rec, pCity, why)
	rec.spawnFailCount = (rec.spawnFailCount or 0) + 1
	Touch(store)
	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.SPAWN_BLOCKED, "LOC_" .. EFV_Config.NOTIF.SPAWN_BLOCKED,
		{ UnitName(rec), CityName(pCity) }, pCity:GetX(), pCity:GetY(), Extra(rec, "SPAWN_BLOCKED"))
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

local function ArriveOutbound(store, rec, turn)
	-- Sender eliminated / sender-recipient war are handled by ReconcilePlayers
	-- in step 0b (Phase 4, WP5.1 brought forward); this guard is a backup.
	if not IsAlive(rec.senderID) then
		EFV_Log(2, "Arrival", "skip id=%d sender=%s not alive", rec.id, tostring(rec.senderID))
		return
	end

	local pCity = CityManager.GetCityAt(rec.destX, rec.destY)
	if pCity == nil or pCity:GetOwner() ~= rec.recipientID or not IsAlive(rec.recipientID) then
		-- Spec 7.3: reroute to the recipient's nearest city, no transit
		-- recalculation; no city / recipient gone -> return from the lost
		-- destination coordinates. (A dead recipient is normally converted by
		-- ReconcilePlayers in step 0b; backup here: Reroute -> "RETURN".)
		local lostX, lostY = rec.destX, rec.destY
		if EFV_Transit.Reroute(store, rec) == "RETURN" then
			local reason = "DEST_LOST"
			if not IsAlive(rec.recipientID) then
				reason = "RECIPIENT_GONE"
			end
			EFV_Transit.ConvertToReturn(store, rec, reason, lostX, lostY, turn)
			return
		end
		pCity = CityManager.GetCityAt(rec.destX, rec.destY)
		if pCity == nil then
			EFV_Log(1, "Arrival", "rerouted city missing id=%d at=%d,%d", rec.id, rec.destX, rec.destY)
			return
		end
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
-- Pipeline step 2 (spec 7.3, 7.4, 10.2), for records with arrivalTurn <= turn:
-- OUTBOUND: destination city missing or not owned by the recipient ->
-- Reroute; "RETURN" -> ConvertToReturn(store, rec, "DEST_LOST" (or
-- "RECIPIENT_GONE"), lost destX, destY, turn). New owner = recipient (EXP,
-- CS) or sender (VOL). plot = EFV_Spawn.Pick(city, domain, owner, "arr" ..
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
-- EFV_Transit.Reroute(store, rec) -> result
-- Recipient not alive or without cities -> "RETURN". Else city =
-- EFV_NearestCity(recipientID, destX, destY): update destCityID/destX/destY,
-- rerouted = 1, queue EFV_NOTIF_REROUTED (sender). No transit
-- recalculation (spec 7.3). Logs "[Reroute] ...".
-- Params:  store, rec record (OUTBOUND).
-- Returns: "OK" | "RETURN".
-- PLAN 2.8; spec 7.3. APIs: A42, A45 (+ EFV_NearestCity).
-- ---------------------------------------------------------------------------
function EFV_Transit.Reroute(store, rec)
	if not IsAlive(rec.recipientID) then
		EFV_Log(2, "Reroute", "id=%d recipient=%s not alive -> RETURN", rec.id, tostring(rec.recipientID))
		return "RETURN"
	end
	local pCity = EFV_NearestCity(rec.recipientID, rec.destX, rec.destY)
	if pCity == nil then
		EFV_Log(2, "Reroute", "id=%d recipient=%d has no cities -> RETURN", rec.id, rec.recipientID)
		return "RETURN"
	end
	local lostName = CityNameAt(rec.destX, rec.destY)
	local fromX, fromY = rec.destX, rec.destY
	rec.destCityID = pCity:GetID()
	rec.destX      = pCity:GetX()
	rec.destY      = pCity:GetY()
	rec.rerouted   = 1
	Touch(store)
	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.REROUTED, "LOC_" .. EFV_Config.NOTIF.REROUTED,
		{ lostName, UnitName(rec), CityName(pCity) }, rec.destX, rec.destY, Extra(rec, "REROUTED"))
	EFV_Log(2, "Reroute", "id=%d from=%s,%s to=%d,%d city=%d arrival=%s",
		rec.id, tostring(fromX), tostring(fromY), rec.destX, rec.destY, rec.destCityID, tostring(rec.arrivalTurn))
	return "OK"
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

-- ---------------------------------------------------------------------------
-- EFV_Transit.StartReturn(store, rec, pUnit, reason, turn) -> returning
-- Spec 10.2, for an on-map record (DEPLOYED / GRACE / MUTINY). city =
-- ResolveReturnCity(rec); nil -> remove the unit if any, delete the record,
-- queue EFV_NOTIF_UNIT_LOST (NO_CITY) to the sender and, if the unit was on
-- the recipient's side (onMapUnitID set), to the recipient. Else: snapshot
-- (if pUnit), remove, state = "RETURNING", arrivalTurn = turn + band(city,
-- destX, destY), returnCityID/X/Y, returnReason = reason, clear
-- onMapPlayerID/onMapUnitID, graceTurnsLeft, lastDamage, lapse fields; queue
-- EFV_NOTIF_RETURNING (sender). If the unit cannot be removed the record is
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

-- ---------------------------------------------------------------------------
-- EFV_Transit.ConvertToReturn(store, rec, reason, fromX, fromY, turn)
--   -> returning
-- For OUTBOUND records (war, elimination, destination lost): as StartReturn
-- without a unit; the return band uses (fromX, fromY) = the (lost)
-- destination coordinates (spec 7.3 last bullet; DV14). No return city ->
-- delete the record and queue EFV_NOTIF_UNIT_LOST (NO_CITY) to the sender.
-- Refuses (logs, returns false, record unchanged) for a record that still
-- has a unit on the map.
-- Params:  store; rec record (OUTBOUND); reason string; fromX, fromY
--          numbers (nil -> rec.destX/destY); turn number (optional trailing
--          parameter added by WP1.0; defaults to Game.GetCurrentGameTurn()).
-- Returns: true if the record is now RETURNING, false otherwise.
-- PLAN 2.8; DV14. APIs: A04 (+ helpers).
-- ---------------------------------------------------------------------------
function EFV_Transit.ConvertToReturn(store, rec, reason, fromX, fromY, turn)
	if turn == nil then
		turn = CurrentTurn()
	end
	if rec.onMapUnitID ~= nil then
		EFV_Log(1, "Return", "ConvertToReturn on an on-map record id=%d state=%s; use StartReturn", rec.id, tostring(rec.state))
		return false
	end
	if fromX == nil or fromY == nil then
		fromX, fromY = rec.destX, rec.destY
	end
	local pCity = EFV_Transit.ResolveReturnCity(rec)
	if pCity == nil then
		EFV_Log(2, "Return", "lost id=%d reason=NO_CITY trigger=%s sender=%d", rec.id, tostring(reason), rec.senderID)
		NotifyUnitLost(rec, "NO_CITY", false)
		EFV_Records.Delete(store, rec.id)
		return false
	end
	EnterReturning(store, rec, pCity, reason, fromX, fromY, turn)
	return true
end

EFV_Transit.LOADED = 1
