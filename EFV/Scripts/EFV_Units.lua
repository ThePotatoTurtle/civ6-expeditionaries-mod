-- ===========================================================================
-- EFV_Units.lua
-- Module:   EFV_Units (global table)
-- Context:  gameplay only, include("EFV_Units").
-- Owner:    WP1.3.
--
-- Responsibility (PLAN 2.5; SPIKES S10): look up units, snapshot a unit into
-- record fields, remove a unit silently, recreate a unit from a record
-- (type, promotions, XP, damage, name, 0 moves) and exhaust the moves of
-- newly created units at PlayerTurnStartComplete (pending list).
-- 0.7 (FIXPLAN_0.7 items 7, 9; INTERFACES note 33): Recreate names the unit
-- right after Create and, for a human owner (EFV_Veteran.UseRouteB), leaves
-- the promotions to veteran route B (an EFV_Veteran job completed by the
-- owner's own PROMOTE commands); RestoreXPClamped is the shared XP restore
-- with the FLAG_XP_CLAMP clamp (also used by EFV_Veteran.Fallback).
--
-- Snapshot shape (INTERFACES "Snapshot"):
--   { unitType, veteranName, damage, experience, xpNext, promotions = {..},
--     level, formation, lastX, lastY }
--
-- Error policy: every engine call that changes state is pcall-guarded and
-- logged. Recreate always returns the new unit once it exists, even if a
-- later restore step failed, so the caller can link the record to it (a
-- unit on the map that no record points to would be duplicated by a retry).
-- ===========================================================================

if EFV_Units ~= nil and EFV_Units.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Records")
-- 0.7 (INTERFACES note 33): veteran route B. EFV_Veteran never includes
-- EFV_Units (it reads the EFV_Units global at call time), so no cycle.
include("EFV_Veteran")

EFV_Units = {}

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

-- Short error text for pcall failures (single line in Lua.log).
local function ErrText(e)
	local s = string.gsub(tostring(e), "[\r\n]+", " ")
	return s
end

-- Unit type string of a unit, or nil.
local function UnitTypeOf(pUnit)
	local row = GameInfo.Units[pUnit:GetType()]
	if row == nil then
		return nil
	end
	return row.UnitType
end

-- Comma-joined promotion list for log lines ("-" when empty).
local function PromoText(list)
	if list == nil or #list == 0 then
		return "-"
	end
	return table.concat(list, ",")
end

-- Session-local "log once" memo for identity mismatches (logging only; not
-- game state, so it cannot desync anything).
local m_MismatchLogged = {}

-- ---------------------------------------------------------------------------
-- EFV_Units.Get(pid, uid, expectedType) -> pUnit
-- Players[pid]:GetUnits():FindID(uid), nil-safe (missing player -> nil),
-- with the Session C identity check (INTERFACES note 23): FindID resolves
-- only the slot, so a unit whose GetID() ~= uid (slot reused after the
-- original died), whose owner differs, or (when expectedType is given) whose
-- type is neither expectedType nor an upgrade of it, is treated as MISSING.
-- Session F (0.5.2, INTERFACES note 30): so is a stale object that FindID
-- still returns although the unit is dead (damage >= max), off the map
-- (a levied unit's old object at -9999,-9999) or no longer in its plot's
-- unit list ("GONE_*", EFV_UnitGoneReason).
-- A mismatch is logged once per (pid, uid, why) under [Snapshot].
-- Params:  pid player ID, uid unit ID, expectedType unit type string or nil
--          (optional; nil = ID, owner and liveness check only).
-- Returns: unit object, or nil plus the EFV_UnitMatches reason ("ID",
--          "OWNER", "TYPE", "GONE_DEAD", "GONE_OFFMAP", "GONE_PLOT", ...;
--          nil when FindID found nothing).
-- PLAN 2.5; Session C item 2; Session F item 1. APIs: A17, A04.
-- ---------------------------------------------------------------------------
function EFV_Units.Get(pid, uid, expectedType)
	if type(pid) ~= "number" or type(uid) ~= "number" or pid < 0 or uid < 0 then
		return nil
	end
	local pPlayer = Players[pid]
	if pPlayer == nil then
		return nil
	end
	local ok, pUnit = pcall(function()
		local pUnits = pPlayer:GetUnits()
		if pUnits == nil then
			return nil
		end
		return pUnits:FindID(uid)
	end)
	if not ok then
		EFV_Log(1, "Snapshot", "Get failed pid=%s uid=%s err=%s", tostring(pid), tostring(uid), ErrText(pUnit))
		return nil
	end
	if pUnit == nil then
		return nil
	end
	local same, why, typeName = EFV_UnitMatches(pUnit, pid, uid, expectedType)
	if not same then
		local key = tostring(pid) .. ":" .. tostring(uid) .. ":" .. tostring(why)
		if m_MismatchLogged[key] == nil then
			m_MismatchLogged[key] = 1
			local foundID, x, y, dmg = nil, nil, nil, nil
			pcall(function()
				foundID = pUnit:GetID()
				x, y, dmg = pUnit:GetX(), pUnit:GetY(), pUnit:GetDamage()
			end)
			EFV_Log(2, "Snapshot", "stale ID pid=%s uid=%s why=%s found=%s type=%s expected=%s at=%s,%s dmg=%s -> treated as missing",
				tostring(pid), tostring(uid), tostring(why), tostring(foundID), tostring(typeName), tostring(expectedType),
				tostring(x), tostring(y), tostring(dmg))
		end
		return nil, why
	end
	return pUnit
end

-- ---------------------------------------------------------------------------
-- EFV_Units.ValidPosition(x, y) -> bool   (added 0.5.2, Session F item 1)
-- true when (x, y) are numbers >= 0 and Map.GetPlot(x, y) exists. Guards
-- every write of rec.lastX / lastY (a levied unit's old object reports
-- -9999,-9999, T28).
-- ---------------------------------------------------------------------------
function EFV_Units.ValidPosition(x, y)
	if type(x) ~= "number" or type(y) ~= "number" or x < 0 or y < 0 then
		return false
	end
	local ok, plot = pcall(function() return Map.GetPlot(x, y) end)
	return ok and plot ~= nil
end

-- ---------------------------------------------------------------------------
-- EFV_Units.GetForRecord(rec) -> pUnit   (added Phase 2, Session C item 2)
-- The on-map unit of a record: Get(rec.onMapPlayerID, rec.onMapUnitID,
-- rec.unitType). rec.unitType follows upgrades through the turn-boundary
-- snapshots; EFV_UnitMatches also accepts an upgrade of the recorded type.
-- Returns Get's second value (the reason) too.
-- Params:  rec record (DEPLOYED / GRACE / MUTINY).
-- Returns: unit object or nil (missing, or a different unit in the slot).
-- ---------------------------------------------------------------------------
function EFV_Units.GetForRecord(rec)
	if rec == nil then
		return nil
	end
	return EFV_Units.Get(rec.onMapPlayerID, rec.onMapUnitID, rec.unitType)
end

-- ---------------------------------------------------------------------------
-- EFV_Units.Snapshot(pUnit) -> snap
-- unitType = GameInfo.Units[pUnit:GetType()].UnitType; veteranName =
-- exp:GetVeteranName() (nil if empty); damage = GetDamage(); experience =
-- exp:GetExperiencePoints(); xpNext = exp:GetExperienceForNextLevel();
-- promotions: for row in GameInfo.UnitPromotions() if exp:HasPromotion(
-- row.Index) append row.UnitPromotionType (no class filter, S10); level =
-- #promotions + 1; formation = GetMilitaryFormation(); lastX/lastY = unit
-- position. Logs "[Snapshot] ..." at level 2.
-- GameInfo.UnitPromotions() iterates in DB order, which is identical on all
-- clients (deterministic promotion order).
-- Params:  pUnit unit object; quiet boolean (optional): log the snapshot at
--          level 3 instead of 2 (the turn-boundary passes snapshot every
--          tracked unit at every per-player hook).
-- Returns: snap table (INTERFACES "Snapshot") or nil if pUnit is nil or a
--          read failed (logged as ERROR).
-- PLAN 2.5; SPIKES S10, S9. APIs: A31, A51, A30, A25, A26, A27, A29, A33.
-- ---------------------------------------------------------------------------
function EFV_Units.Snapshot(pUnit, quiet)
	if pUnit == nil then
		return nil
	end
	local ok, snap = pcall(function()
		local s = {}
		s.unitType = UnitTypeOf(pUnit)
		if s.unitType == nil then
			error("unknown unit type index " .. tostring(pUnit:GetType()))
		end
		local exp = pUnit:GetExperience()
		local name = exp:GetVeteranName()
		if type(name) == "string" and name ~= "" then
			s.veteranName = name
		else
			s.veteranName = nil
		end
		s.damage = pUnit:GetDamage() or 0
		s.experience = exp:GetExperiencePoints() or 0
		s.xpNext = exp:GetExperienceForNextLevel() or 0
		local promos = {}
		for row in GameInfo.UnitPromotions() do
			if exp:HasPromotion(row.Index) then
				promos[#promos + 1] = row.UnitPromotionType
			end
		end
		s.promotions = promos
		s.level = #promos + 1
		s.formation = pUnit:GetMilitaryFormation()
		s.lastX = pUnit:GetX()
		s.lastY = pUnit:GetY()
		return s
	end)
	if not ok then
		EFV_Log(1, "Snapshot", "failed err=%s", ErrText(snap))
		return nil
	end
	EFV_Log(quiet and 3 or 2, "Snapshot", "pid=%s uid=%s type=%s xp=%s next=%s dmg=%s level=%s promotions=%s name=%s formation=%s x=%s y=%s",
		tostring(pUnit:GetOwner()), tostring(pUnit:GetID()), tostring(snap.unitType), tostring(snap.experience),
		tostring(snap.xpNext), tostring(snap.damage), tostring(snap.level), PromoText(snap.promotions),
		tostring(snap.veteranName or "-"), tostring(snap.formation), tostring(snap.lastX), tostring(snap.lastY))
	return snap
end

-- ---------------------------------------------------------------------------
-- EFV_Units.ApplySnapshot(rec, snap, turn)
-- Copies every snapshot field into rec and sets rec.snapTurn = turn. The
-- promotions array is copied (no aliasing between snap and rec). A nil
-- veteranName clears the record field. The caller marks the store dirty
-- (EFV_Records.Touch).
-- Params:  rec record, snap snapshot table, turn number.
-- Returns: nil.
-- PLAN 2.5; SPIKES S9. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Units.ApplySnapshot(rec, snap, turn)
	if rec == nil or snap == nil then
		EFV_Log(1, "Snapshot", "ApplySnapshot called with rec=%s snap=%s", tostring(rec), tostring(snap))
		return nil
	end
	rec.unitType = snap.unitType
	rec.veteranName = snap.veteranName
	rec.damage = snap.damage
	rec.experience = snap.experience
	rec.xpNext = snap.xpNext
	local promos = {}
	if snap.promotions ~= nil then
		for i, p in ipairs(snap.promotions) do
			promos[i] = p
		end
	end
	rec.promotions = promos
	rec.level = snap.level
	rec.formation = snap.formation
	-- Session F item 1: never store an off-map position (a levied unit's old
	-- object sits at -9999,-9999); the relinks search around lastX / lastY.
	if EFV_Units.ValidPosition(snap.lastX, snap.lastY) then
		rec.lastX = snap.lastX
		rec.lastY = snap.lastY
	else
		EFV_Log(1, "Snapshot", "ApplySnapshot id=%s: off-map position %s,%s not stored (kept %s,%s)",
			tostring(rec.id), tostring(snap.lastX), tostring(snap.lastY), tostring(rec.lastX), tostring(rec.lastY))
	end
	rec.snapTurn = turn
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Units.Remove(pUnit) -> ok
-- Silent removal per EFV_Config.FLAG_REMOVE_API: "DESTROY" ->
-- Players[owner]:GetUnits():Destroy(pUnit) (A20); "KILL" ->
-- UnitManager.Kill(pUnit) (A21, single argument only). No XP, war score or
-- death notification (Session B T07: both are silent). Logs "[Remove] ...".
-- Params:  pUnit unit object.
-- Returns: true if removed, false otherwise.
-- PLAN 2.5; SPIKES S10, 3 row 7. APIs: A20, A21.
-- ---------------------------------------------------------------------------
function EFV_Units.Remove(pUnit)
	if pUnit == nil then
		return false
	end
	local owner, uid = -1, -1
	local okId = pcall(function()
		owner = pUnit:GetOwner()
		uid = pUnit:GetID()
	end)
	if not okId then
		EFV_Log(1, "Remove", "failed: unit object unreadable")
		return false
	end
	local api = EFV_Config.FLAG_REMOVE_API
	local ok, err = pcall(function()
		if api == "KILL" then
			UnitManager.Kill(pUnit)
		else
			local pPlayer = Players[owner]
			if pPlayer == nil then
				error("no player " .. tostring(owner))
			end
			pPlayer:GetUnits():Destroy(pUnit)
		end
	end)
	if not ok then
		EFV_Log(1, "Remove", "failed pid=%s uid=%s api=%s err=%s", tostring(owner), tostring(uid), tostring(api), ErrText(err))
		return false
	end
	-- T07 aid: report whether the unit is still findable right after removal.
	local still = (EFV_Units.Get(owner, uid) ~= nil)
	EFV_Log(2, "Remove", "pid=%s uid=%s api=%s stillFound=%s", tostring(owner), tostring(uid), tostring(api), still and "1" or "0")
	return true
end

-- ---------------------------------------------------------------------------
-- EFV_Units.RestoreXPClamped(pUnit, target) -> xpNow, xpNext, clamped
-- (0.7, INTERFACES note 33; extracted from Recreate step 3.) Sets the XP to
-- target (ChangeExperience(target - current); the engine caps it at the
-- next-level threshold while a promotion is pending, Session B / F T08),
-- then, when FLAG_XP_CLAMP, clamps it to threshold - 1 so the unit gets no
-- free promotion. Errors propagate (callers pcall).
-- Params:  pUnit unit object, target XP number (nil -> 0).
-- Returns: XP after the restore, the next-level threshold, the XP removed
--          by the clamp (0 when none).
-- APIs: A26, A25, A30.
-- ---------------------------------------------------------------------------
function EFV_Units.RestoreXPClamped(pUnit, target)
	local exp = pUnit:GetExperience()
	local want = tonumber(target) or 0
	local cur = exp:GetExperiencePoints() or 0
	if want ~= cur then
		exp:ChangeExperience(want - cur)
	end
	local xpNext = exp:GetExperienceForNextLevel()
	local xpNow = exp:GetExperiencePoints()
	local clamped = 0
	if EFV_Config.FLAG_XP_CLAMP and type(xpNext) == "number" and xpNext > 0 and xpNow >= xpNext then
		local limit = xpNext - 1
		if limit < 0 then
			limit = 0
		end
		exp:ChangeExperience(limit - xpNow)
		clamped = xpNow - limit
		xpNow = exp:GetExperiencePoints()
	end
	return xpNow, xpNext, clamped
end

-- Classic restore (Recreate steps 3a / 3b): SetPromotion for every stored
-- type, then the XP with the clamp. Returns restored, wanted, xpNow, xpNext,
-- xpClamped for the log line.
local function RestoreClassic(pUnit, exp, rec, rid)
	local wanted, restored = 0, 0
	if exp ~= nil and rec.promotions ~= nil then
		for _, pType in ipairs(rec.promotions) do
			wanted = wanted + 1
			local pRow = GameInfo.UnitPromotions[pType]
			if pRow == nil then
				EFV_Log(1, "Restore", "id=%s unknown promotion=%s skipped", rid, tostring(pType))
			else
				local okP, errP = pcall(function()
					if not exp:HasPromotion(pRow.Index) then
						exp:SetPromotion(pRow.Index)
					end
					return exp:HasPromotion(pRow.Index)
				end)
				if not okP then
					EFV_Log(1, "Restore", "id=%s SetPromotion %s failed err=%s", rid, tostring(pType), ErrText(errP))
				elseif errP then
					restored = restored + 1
				else
					EFV_Log(1, "Restore", "id=%s SetPromotion %s had no effect", rid, tostring(pType))
				end
			end
		end
	end

	local xpNow, xpNext, xpClamped = nil, nil, 0
	if exp ~= nil then
		local okX, a, b, c = pcall(EFV_Units.RestoreXPClamped, pUnit, rec.experience)
		if okX then
			xpNow, xpNext, xpClamped = a, b, c
		else
			EFV_Log(1, "Restore", "id=%s experience restore failed err=%s", rid, ErrText(a))
		end
		if xpNext ~= nil and rec.xpNext ~= nil and xpNext ~= rec.xpNext then
			EFV_Log(2, "Restore", "id=%s xpNext mismatch new=%s snap=%s (T08)", rid, tostring(xpNext), tostring(rec.xpNext))
		end
		-- Session B: ChangeExperience is capped at the next-level threshold while
		-- a promotion is pending, so the restored XP can be lower than stored.
		local want = tonumber(rec.experience) or 0
		if type(xpNow) == "number" and xpClamped == 0 and xpNow < want then
			EFV_Log(2, "Restore", "id=%s xp capped by the engine got=%s want=%s next=%s (T08)",
				rid, tostring(xpNow), tostring(want), tostring(xpNext))
		end
	end
	return restored, wanted, xpNow, xpNext, xpClamped
end

-- ---------------------------------------------------------------------------
-- EFV_Units.Recreate(store, ownerID, rec, plot, turn) -> pUnit
-- Order (S10; 0.7 INTERFACES note 33):
--   1. create rec.unitType for ownerID at plot (FLAG_CREATE_API: "CREATE" ->
--      Players[ownerID]:GetUnits():Create(GameInfo.Units[t].Index, x, y),
--      A18; "INITUNIT" -> UnitManager.InitUnit(ownerID, t, x, y), A19; nil
--      check);
--   2. SetVeteranName if non-empty (0.7, FIXPLAN item 9 hardening: right
--      after Create, so every later change carries the name to the UI);
--   3. the level, by route (EFV_Veteran.UseRouteB(ownerID, rec)):
--      classic (AI owner, FLAG_VET_ROUTE_B off, no known promotion):
--        3a SetPromotion(GameInfo.UnitPromotions[type].Index) for each
--           stored type (unknown types logged and skipped);
--        3b EFV_Units.RestoreXPClamped(pUnit, rec.experience) (threshold
--           logged against rec.xpNext, T08; clamp when FLAG_XP_CLAMP);
--      route B (human owner): nothing here, see 4b;
--   4. SetDamage(rec.damage) (below max HP);
--   4b route B: EFV_Veteran.Begin(store, ownerID, pUnit, rec, turn) (XP to
--      the first threshold and a job for the owner's own PROMOTE commands;
--      the damage of step 4 is the job's floor against the promotion heal).
--      Begin false or failing -> 3a / 3b run now, then step 4 again;
--   5. UnitManager.FinishMoves -> EFV_Records.AddPending(store, ownerID,
--      newID, turn).
-- Formation is NOT restored (D3). Logs "[Restore] ... route=B|classic".
-- Each restore step runs in its own pcall; a failed step is logged as ERROR
-- and the remaining steps still run. Once the unit exists it is returned.
-- Params:  store, ownerID player ID (new owner), rec record (snapshot
--          fields), plot plot object (spawn tile), turn number.
-- Returns: the new unit object, or nil if creation failed.
-- PLAN 2.5; SPIKES S10; D3; FIXPLAN_0.7 items 7, 9. APIs: A18, A19, A28,
-- A26, A25, A30, A22.
-- ---------------------------------------------------------------------------
function EFV_Units.Recreate(store, ownerID, rec, plot, turn)
	if rec == nil or plot == nil or type(ownerID) ~= "number" then
		EFV_Log(1, "Restore", "Recreate bad args owner=%s rec=%s plot=%s", tostring(ownerID), tostring(rec), tostring(plot))
		return nil
	end
	local rid = tostring(rec.id)
	local unitType = rec.unitType
	local typeRow = nil
	if type(unitType) == "string" then
		typeRow = GameInfo.Units[unitType]
	end
	if typeRow == nil then
		EFV_Log(1, "Restore", "id=%s unknown unitType=%s", rid, tostring(unitType))
		return nil
	end
	local pPlayer = Players[ownerID]
	if pPlayer == nil then
		EFV_Log(1, "Restore", "id=%s no player owner=%s", rid, tostring(ownerID))
		return nil
	end
	local x, y = plot:GetX(), plot:GetY()

	-- 1. Create.
	local api = EFV_Config.FLAG_CREATE_API
	local okC, pUnit = pcall(function()
		if api == "INITUNIT" then
			return UnitManager.InitUnit(ownerID, unitType, x, y)
		end
		return pPlayer:GetUnits():Create(typeRow.Index, x, y)
	end)
	if not okC then
		EFV_Log(1, "Restore", "id=%s create failed owner=%s type=%s x=%s y=%s api=%s err=%s",
			rid, tostring(ownerID), unitType, tostring(x), tostring(y), tostring(api), ErrText(pUnit))
		return nil
	end
	if pUnit == nil then
		-- Not an error by itself: the engine refuses a plot the owner may not
		-- enter (Session D 3); the caller tries the next plot and logs ERROR
		-- only when every try failed.
		EFV_Log(2, "Restore", "id=%s create returned nil owner=%s type=%s x=%s y=%s api=%s",
			rid, tostring(ownerID), unitType, tostring(x), tostring(y), tostring(api))
		return nil
	end
	local newID = pUnit:GetID()

	local okE, exp = pcall(function() return pUnit:GetExperience() end)
	if not okE then
		EFV_Log(1, "Restore", "id=%s GetExperience failed err=%s", rid, ErrText(exp))
		exp = nil
	end

	-- 2. Custom name (only when non-empty), right after Create (item 9).
	if exp ~= nil and type(rec.veteranName) == "string" and rec.veteranName ~= "" then
		local okN, errN = pcall(function() exp:SetVeteranName(rec.veteranName) end)
		if not okN then
			EFV_Log(1, "Restore", "id=%s SetVeteranName failed err=%s", rid, ErrText(errN))
		end
	end

	-- 3. Level: route B (human owner) or classic (promotions + clamped XP).
	local okR, routeB = pcall(EFV_Veteran.UseRouteB, ownerID, rec)
	if not okR then
		EFV_Log(1, "Restore", "id=%s route check failed err=%s; classic restore", rid, ErrText(routeB))
		routeB = false
	end
	if exp == nil then
		routeB = false
	end
	local restored, wanted, xpNow, xpNext, xpClamped = 0, 0, nil, nil, 0
	if not routeB then
		restored, wanted, xpNow, xpNext, xpClamped = RestoreClassic(pUnit, exp, rec, rid)
	end

	-- 4. Damage (clamped below max HP so the restore can never kill).
	local function RestoreDamage()
		local okD, errD = pcall(function()
			local dmg = tonumber(rec.damage) or 0
			if dmg < 0 then
				dmg = 0
			end
			local maxD = pUnit:GetMaxDamage()
			if type(maxD) == "number" and maxD > 0 and dmg >= maxD then
				dmg = maxD - 1
			end
			if dmg ~= pUnit:GetDamage() then
				pUnit:SetDamage(dmg)
			end
		end)
		if not okD then
			EFV_Log(1, "Restore", "id=%s SetDamage failed err=%s", rid, ErrText(errD))
		end
	end
	RestoreDamage()

	-- 4b. Route B: the job (XP to the first threshold); failure -> classic.
	local route = "classic"
	if routeB then
		local okB, began = pcall(EFV_Veteran.Begin, store, ownerID, pUnit, rec, turn)
		if okB and began then
			route = "B"
			pcall(function()
				xpNow = exp:GetExperiencePoints()
				xpNext = exp:GetExperienceForNextLevel()
			end)
		else
			if not okB then
				EFV_Log(1, "Restore", "id=%s route B failed err=%s; classic restore", rid, ErrText(began))
			else
				EFV_Log(2, "Restore", "id=%s route B not started; classic restore", rid)
			end
			restored, wanted, xpNow, xpNext, xpClamped = RestoreClassic(pUnit, exp, rec, rid)
			RestoreDamage()
		end
	end

	-- 5. Zero the moves now, and again at the owner's PlayerTurnStartComplete
	--    (moves are restored between PlayerTurnStarted and
	--    PlayerTurnStartComplete, S10 gotcha).
	local okM, errM = pcall(function() UnitManager.FinishMoves(pUnit) end)
	if not okM then
		EFV_Log(1, "Restore", "id=%s FinishMoves failed err=%s", rid, ErrText(errM))
	end
	if store ~= nil then
		EFV_Records.AddPending(store, ownerID, newID, turn)
	else
		EFV_Log(1, "Restore", "id=%s no store: pending exhaust not queued", rid)
	end

	EFV_Log(2, "Restore", "id=%s owner=%s uid=%s type=%s x=%s y=%s api=%s route=%s promotions=%d/%d xp=%s/%s next=%s/%s clamped=%s dmg=%s name=%s",
		rid, tostring(ownerID), tostring(newID), unitType, tostring(x), tostring(y), tostring(api), route,
		restored, wanted, tostring(xpNow), tostring(rec.experience), tostring(xpNext), tostring(rec.xpNext),
		tostring(xpClamped), tostring(rec.damage), tostring(rec.veteranName or "-"))
	return pUnit
end

-- ---------------------------------------------------------------------------
-- EFV_Units.ExhaustPending(store, pid)
-- For each entry of EFV_Records.TakePending(store, pid) whose unit still
-- exists: UnitManager.FinishMoves(unit). Logs "[Exhaust] ...". Called from
-- the GameEvents.PlayerTurnStartComplete(pid) hook (S10, T06).
-- Only entries created on the current turn (e.t >= current turn) are
-- exhausted: the unit must have 0 moves on its arrival turn only. An older
-- entry (the owner had no turn start since, e.g. created after the owner's
-- PlayerTurnStartComplete, or a skipped player) is dropped and logged, so a
-- unit never loses the moves of a later turn.
-- Params:  store, pid player ID.
-- Returns: nil.
-- PLAN 1.8, 2.5; SPIKES S10. APIs: A17, A22, A04.
-- ---------------------------------------------------------------------------
function EFV_Units.ExhaustPending(store, pid)
	if store == nil or type(pid) ~= "number" then
		return nil
	end
	local entries = EFV_Records.TakePending(store, pid)
	if entries == nil or #entries == 0 then
		return nil
	end
	local turn = Game.GetCurrentGameTurn()
	for _, e in ipairs(entries) do
		local t = tonumber(e.t) or -1
		if t < turn then
			EFV_Log(2, "Exhaust", "skip stale pid=%s uid=%s created=%s", tostring(e.p), tostring(e.u), tostring(e.t))
		else
			local pUnit = EFV_Units.Get(e.p, e.u)
			if pUnit == nil then
				EFV_Log(2, "Exhaust", "skip gone pid=%s uid=%s", tostring(e.p), tostring(e.u))
			else
				local ok, err = pcall(function() UnitManager.FinishMoves(pUnit) end)
				if ok then
					local moves = nil
					pcall(function() moves = pUnit:GetMovesRemaining() end)
					EFV_Log(2, "Exhaust", "pid=%s uid=%s moves=%s", tostring(e.p), tostring(e.u), tostring(moves))
				else
					EFV_Log(1, "Exhaust", "FinishMoves failed pid=%s uid=%s err=%s", tostring(e.p), tostring(e.u), ErrText(err))
				end
			end
		end
	end
	return nil
end

EFV_Units.LOADED = 1
