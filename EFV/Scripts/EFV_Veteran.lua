-- ===========================================================================
-- EFV_Veteran.lua
-- Module:   EFV_Veteran (global table)
-- Context:  gameplay only, include("EFV_Veteran") (included by EFV_Units).
-- Owner:    WP0 (0.7 stub, final API); WP3 (implementation, FIXPLAN_0.7
--           item 7).
--
-- Responsibility (designer ruling "Veteran level restore", final session S6;
-- INTERFACES note 33): restore a returned unit's level for a HUMAN owner by
-- "route B": gameplay raises XP to the next threshold, the owner's UI
-- (EFV_VetRestore) issues the engine's own PROMOTE command, gameplay syncs
-- and raises XP again, until every snapshot promotion is back. AI owners
-- keep the FLAG_XP_CLAMP path. Gated by EFV_Config.FLAG_VET_ROUTE_B.
--
-- Job shape (store.vet, property EFV_Config.PROP.VET "EFV_VetJobs", dense
-- array sorted by (t, p, u)):
--   { p = ownerID, u = unitID, ut = unitType, t = turnCreated,
--     rid = recordID (log only), want = { promotion type names still to
--     take, snapshot order }, got = promotions held when last synced,
--     xp = target XP (snapshot), dmg = damage floor against the promotion
--     heal, n = steps synced, ex = 1 while the arrival-turn exhaust is
--     owed (0.7.2), rt = turn of an open moves refill (1.0.4, see below) }
-- Jobs are independent of records (a returned record is deleted at arrival).
--
-- One-turn restore (1.0.4, designer ruling 2026-10-05, EFV_Dev 1.0.3.2
-- veteran spike V2): a landed promotion ends the unit's turn (moves 0) and
-- the engine offers no further PROMOTE that turn, which made route B one
-- promotion per turn. So when the EFV_VetStep request syncs a landed
-- promotion and wanted promotions remain, Refill gives the unit its moves
-- back (pUnit:ChangeMovesRemaining(max - remaining), the V2 call) and the
-- owner's UI chains the next PROMOTE at once: every promotion lands in the
-- turn the unit comes home. The refill is a loan (job.rt = its turn):
--   * the next promotion uses it up (the step clears rt);
--   * the last promotion gets no refill, so the job ends at the moves the
--     engine leaves after a promotion (0), and PayExhaust zeroes them in the
--     arrival turn as before;
--   * a refill happens only from 0 moves (a unit whose promotion kept its
--     moves needs none), so the moves before it were always 0: Unloan takes
--     the loan back with UnitManager.FinishMoves when the job is
--     interrupted in the refill's turn (Fallback NOT_HUMAN, or the owner's
--     UI reports that no wanted promotion is offered: EFV_VetStep stall = 1);
--   * a loan from an earlier turn is dropped without touching the unit (the
--     engine has given it the moves of the new turn since).
-- So the unit never keeps more moves than the engine would leave it after
-- the promotions, in the arrival turn or in a later one (a job resumed
-- after a load, or one whose promotions were not offered in the arrival
-- turn). The refill runs only in the EFV_VetStep handler (synced on every
-- client); turn boundaries never refill.
--
-- Arrival-turn moves (0.7.2, re-test 0.7 step 5): the engine offers PROMOTE
-- only to a unit with movement points (arrival turn at 0 moves: nothing
-- offered; next turn at full moves: both promotions taken at once). So a
-- route B unit is NOT queued for the arrival exhaust at the owner's
-- PlayerTurnStartComplete (EFV_Units.Recreate); the job owes it (ex = 1)
-- and PayExhaust zeroes the moves when the job ends in the arrival turn
-- (Sync DONE or a Fallback other than SNAPSHOT, whose unit leaves the map
-- at once), plus a pending entry for the case the owner's
-- PTSC is still to come. A job that ends later owes nothing any more (the
-- arrival turn is over). Known edge: when no promotion can be taken in the
-- arrival turn at all, the unit keeps its moves for that turn (never more
-- than the engine gave it: a refill needs a landed promotion first).
--
-- Flow (FIXPLAN_0.7 item 7):
--   1. EFV_Units.Recreate -> UseRouteB -> Begin (XP to the first threshold,
--      job created, damage floor = the restored damage).
--   2. The owner's UI (EFV_VetRestore) sends PROMOTE for the first wanted
--      promotion the engine offers, and EFV_VetStep once one landed.
--   3. Sync (EFV_VetStep handler, every boundary, pipeline step 0e): state
--      derived and idempotent. New promotions -> undo the promotion heal,
--      strike them from want (a promotion picked by hand replaces one, never
--      adds one), raise XP to the next threshold, refill the moves (1.0.4,
--      EFV_VetStep only, see "One-turn restore"); want empty -> XP target,
--      job removed.
--   4. No time limit (designer ruling, 0.7.4): before 1.0.4 the engine
--      allowed one promotion per turn, so a veteran with N promotions
--      needed about N turns, and the 0.7.0 deadline (turn >= t + 2 ->
--      Fallback("TIMEOUT")) cost 3+ promotion veterans their level. With the
--      refill the job normally ends in the arrival turn; it still stays
--      open until it is done. Fallback (SetPromotion for the rest, XP target with the
--      clamp, damage floor) only on concrete causes: the owner is no longer
--      human (Sync, "NOT_HUMAN") or the unit is about to leave the map
--      (step 5, "SNAPSHOT"). A job that cannot progress leaves the unit
--      with a pending promotion the player can pick by hand (accepted);
--      such a pick replaces a wanted one (step 3).
--   5. Settle before any removal snapshot (EFV_Transit / EFV_Lifecycle):
--      Sync, then Fallback("SNAPSHOT") when still open.
-- A job whose unit is gone (killed, upgraded to a new ID, ...) is dropped.
--
-- MP (INTERFACES note 33): gameplay owns all state; the UI only issues the
-- engine's own PROMOTE for the local player's jobs. EFV_VetStep only makes
-- gameplay Sync the requester's own job (key = requester, unitID), so a
-- forged or early request changes nothing Sync would not (the 1.0.4 refill
-- needs a promotion the unit really holds; stall = 1 only takes back moves
-- VEF lent the requester's own unit this turn). No
-- Game.GetLocalPlayer here; jobs are walked in array order (deterministic).
--
-- Include rule: this file must NOT include EFV_Units, EFV_Transit or
-- EFV_Lifecycle (EFV_Units includes this file; the EFV_Units global is read
-- at call time), so there is no include cycle.
-- Log tag "[Vet]".
-- ===========================================================================

if EFV_Veteran ~= nil and EFV_Veteran.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Records")

EFV_Veteran = {}

local TAG = "Vet"

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

local function ErrText(e)
	local s = string.gsub(tostring(e), "[\r\n]+", " ")
	return s
end

local function List(t)
	if t == nil or #t == 0 then
		return "-"
	end
	return table.concat(t, ",")
end

local function CurrentTurn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

local function IsHuman(pid)
	if type(pid) ~= "number" then
		return false
	end
	local pPlayer = Players[pid]
	if pPlayer == nil then
		return false
	end
	local ok, human = pcall(function() return pPlayer:IsHuman() end)
	return ok and human == true
end

local function Touch(store)
	EFV_Records.MarkDirty(store, EFV_Config.PROP.VET)
end

-- Unit type string of a unit, or nil.
local function UnitTypeOf(pUnit)
	local row = GameInfo.Units[pUnit:GetType()]
	if row == nil then
		return nil
	end
	return row.UnitType
end

-- Promotion type names the unit holds, in GameInfo.UnitPromotions() (DB)
-- order: identical on every client. HasPromotion works in gameplay;
-- GetPromotions is UI-only (Session A T09).
local function Held(pUnit)
	local exp = pUnit:GetExperience()
	local out = {}
	for row in GameInfo.UnitPromotions() do
		if exp:HasPromotion(row.Index) then
			out[#out + 1] = row.UnitPromotionType
		end
	end
	return out
end

-- The snapshot promotions that resolve in GameInfo.UnitPromotions, in
-- snapshot order, without duplicates.
local function KnownPromotions(rec)
	local out, seen = {}, {}
	if rec == nil or type(rec.promotions) ~= "table" then
		return out
	end
	for _, name in ipairs(rec.promotions) do
		if type(name) == "string" and seen[name] == nil and GameInfo.UnitPromotions[name] ~= nil then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	return out
end

-- Raises XP to the next-level threshold when below it (the engine caps
-- ChangeExperience there, Session B / F T08). Returns xp, next after.
local function XPToThreshold(pUnit)
	local exp = pUnit:GetExperience()
	local xp = exp:GetExperiencePoints() or 0
	local nxt = exp:GetExperienceForNextLevel() or 0
	if nxt > 0 and xp < nxt then
		exp:ChangeExperience(nxt - xp)
		xp = exp:GetExperiencePoints() or 0
	end
	return xp, nxt
end

-- Puts the damage back up to the floor (the promotion heal,
-- EXPERIENCE_PROMOTE_HEALED). Returns true when it wrote.
local function RestoreFloor(job, pUnit)
	local dmg = pUnit:GetDamage() or 0
	local floor = tonumber(job.dmg) or 0
	if dmg < floor then
		local maxD = pUnit:GetMaxDamage()
		if type(maxD) == "number" and maxD > 0 and floor >= maxD then
			floor = maxD - 1
		end
		pUnit:SetDamage(floor)
		EFV_Log(2, TAG, "heal undone id=%s uid=%s dmg=%s -> %s", tostring(job.rid), tostring(job.u),
			tostring(dmg), tostring(floor))
		return true
	end
	return false
end

-- The arrival-turn exhaust the job owes (ex = 1, see the header): paid
-- only in the job's creation turn. Logs "[Vet] exhaust ...".
local function PayExhaust(store, job, pUnit)
	if tonumber(job.ex) ~= 1 then
		return
	end
	job.ex = nil
	Touch(store)
	local turn = CurrentTurn()
	if turn ~= tonumber(job.t) then
		return
	end
	local ok, err = pcall(function() UnitManager.FinishMoves(pUnit) end)
	EFV_Records.AddPending(store, job.p, job.u, job.t)
	local moves = nil
	pcall(function() moves = pUnit:GetMovesRemaining() end)
	EFV_Log(2, TAG, "exhaust id=%s uid=%s moves=%s (arrival turn, level back)%s", tostring(job.rid), tostring(job.u),
		tostring(moves), ok and "" or (" FinishMoves failed err=" .. ErrText(err)))
end

local function MovesOf(pUnit)
	local ok, m = pcall(function() return pUnit:GetMovesRemaining() end)
	if ok and type(m) == "number" then
		return m
	end
	return nil
end

-- One-turn restore (1.0.4, see the header): after a landed promotion with
-- wanted promotions left, gives the unit its moves back so the owner's UI
-- can send the next PROMOTE this turn (EFV_Dev 1.0.3.2 spike V2,
-- PiratesScenario_UnitCommands.lua:665-666). Only from 0 moves; records
-- the loan (job.rt = this turn). Logs "[Vet] refill ...".
local function Refill(store, job, pUnit)
	local before = MovesOf(pUnit)
	if before == nil or before > 0 then
		return false
	end
	local maxM = nil
	pcall(function() maxM = pUnit:GetMaxMoves() end)
	if type(maxM) ~= "number" or maxM <= 0 then
		return false
	end
	local ok, err = pcall(function() pUnit:ChangeMovesRemaining(maxM - before) end)
	if not ok then
		EFV_Log(1, TAG, "refill id=%s uid=%s failed err=%s", tostring(job.rid), tostring(job.u), ErrText(err))
		return false
	end
	job.rt = CurrentTurn()
	Touch(store)
	EFV_Log(2, TAG, "refill id=%s uid=%s moves=%s -> %s/%s left=%s", tostring(job.rid), tostring(job.u), tostring(before),
		tostring(MovesOf(pUnit)), tostring(maxM), List(job.want))
	return true
end

-- Takes back an open refill (job.rt): in the refill's turn the moves go back
-- to what the promotion left, 0 (UnitManager.FinishMoves, as PayExhaust);
-- a loan from an earlier turn is only dropped (the engine has given the
-- unit the moves of the new turn since). Logs "[Vet] refill undone ...".
local function Unloan(store, job, pUnit, why)
	if job.rt == nil then
		return false
	end
	local rt = tonumber(job.rt)
	job.rt = nil
	Touch(store)
	if pUnit == nil or rt ~= CurrentTurn() then
		EFV_Log(3, TAG, "refill dropped id=%s uid=%s turn=%s why=%s (earlier turn)", tostring(job.rid), tostring(job.u),
			tostring(rt), tostring(why))
		return false
	end
	local ok, err = pcall(function() UnitManager.FinishMoves(pUnit) end)
	EFV_Log(2, TAG, "refill undone id=%s uid=%s why=%s moves=%s%s", tostring(job.rid), tostring(job.u), tostring(why),
		tostring(MovesOf(pUnit)), ok and "" or (" FinishMoves failed err=" .. ErrText(err)))
	return ok
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.UseRouteB(ownerID, rec) -> bool
-- true when FLAG_VET_ROUTE_B is on, the owner is human and the snapshot has
-- at least one promotion that resolves in GameInfo.UnitPromotions.
-- ---------------------------------------------------------------------------
function EFV_Veteran.UseRouteB(ownerID, rec)
	if not EFV_Config.FLAG_VET_ROUTE_B then
		return false
	end
	if not IsHuman(ownerID) then
		return false
	end
	return #KnownPromotions(rec) > 0
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.Begin(store, ownerID, pUnit, rec, turn) -> bool
-- Raises XP to the first threshold and adds the job (damage floor = the
-- unit's damage now, so Recreate sets the damage first). false -> the
-- caller runs the classic promotions + clamped XP steps. Errors propagate
-- (Recreate pcalls). Logs "[Vet] begin ...".
-- ---------------------------------------------------------------------------
function EFV_Veteran.Begin(store, ownerID, pUnit, rec, turn)
	if type(store) ~= "table" or pUnit == nil or rec == nil or type(ownerID) ~= "number" then
		return false
	end
	local want = KnownPromotions(rec)
	local held = Held(pUnit)
	local heldSet = {}
	for _, name in ipairs(held) do
		heldSet[name] = true
	end
	local rest = {}
	for _, name in ipairs(want) do
		if not heldSet[name] then
			rest[#rest + 1] = name
		end
	end
	if #rest == 0 then
		return false
	end
	local xp, nxt = XPToThreshold(pUnit)
	local job = {
		p = ownerID, u = pUnit:GetID(), ut = UnitTypeOf(pUnit), t = tonumber(turn) or CurrentTurn(),
		rid = rec.id, want = rest, got = #held, xp = tonumber(rec.experience) or 0,
		dmg = pUnit:GetDamage() or 0, n = 0, ex = 1,
	}
	if EFV_Records.AddVetJob(store, job) == nil then
		return false
	end
	EFV_Log(2, TAG, "begin id=%s owner=%s uid=%s type=%s promotions=%s xp=%s/%s target=%s dmg=%s",
		tostring(job.rid), tostring(ownerID), tostring(job.u), tostring(job.ut), List(rest), tostring(xp),
		tostring(nxt), tostring(job.xp), tostring(job.dmg))
	return true
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.Fallback(store, job, pUnit, why)
-- SetPromotion for the rest of want, XP target then the clamp
-- (EFV_Units.RestoreXPClamped), damage floor, an open refill of this turn
-- taken back (not for SNAPSHOT), the arrival exhaust, job removed. pUnit
-- nil -> the job is only removed. Logs "[Vet] fallback id= why=".
-- why: "NOT_HUMAN" | "SNAPSHOT" (no "TIMEOUT" since 0.7.4)
-- ---------------------------------------------------------------------------
function EFV_Veteran.Fallback(store, job, pUnit, why)
	if type(store) ~= "table" or job == nil then
		return nil
	end
	local set, xpNow, xpNext, clamped = {}, nil, nil, 0
	if pUnit ~= nil then
		local ok, err = pcall(function()
			local exp = pUnit:GetExperience()
			for _, name in ipairs(job.want or {}) do
				local row = GameInfo.UnitPromotions[name]
				if row ~= nil and not exp:HasPromotion(row.Index) then
					exp:SetPromotion(row.Index)
					set[#set + 1] = name
				end
			end
			xpNow, xpNext, clamped = EFV_Units.RestoreXPClamped(pUnit, job.xp)
			RestoreFloor(job, pUnit)
		end)
		if not ok then
			EFV_Log(1, TAG, "fallback id=%s uid=%s failed err=%s", tostring(job.rid), tostring(job.u), ErrText(err))
		end
		if why == "SNAPSHOT" then
			-- A removal snapshot follows (send, return): the unit
			-- leaves the map, and exhausting it here would make the send
			-- that asked for the snapshot fail NOT_FULL_MOVES. An open
			-- refill is dropped the same way (the moves do not travel).
			job.ex = nil
			job.rt = nil
		else
			Unloan(store, job, pUnit, why)
			PayExhaust(store, job, pUnit)
		end
	end
	EFV_Records.RemoveVetJob(store, job.p, job.u)
	EFV_Log(2, TAG, "fallback id=%s owner=%s uid=%s why=%s set=%s xp=%s/%s next=%s clamped=%s steps=%s",
		tostring(job.rid), tostring(job.p), tostring(job.u), tostring(why), List(set), tostring(xpNow),
		tostring(job.xp), tostring(xpNext), tostring(clamped), tostring(job.n))
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.Sync(store, job, pUnit, hook) -> "OPEN" | "DONE" | "FALLBACK"
-- Idempotent, state-derived sync of one job with its unit (FIXPLAN_0.7
-- item 7 step 3):
--   * owner no longer human -> Fallback("NOT_HUMAN");
--   * more promotions held than job.got: damage floor restored (promotion
--     heal), held names struck from want, promotions not in want (picked by
--     hand) drop as many entries from the end of want, got / n updated;
--     else job.dmg follows the unit's damage (round heal, combat);
--   * want empty -> XP raised to job.xp (never lowered), job removed, DONE;
--     else XP raised to the next threshold (promotion available), OPEN;
--   * 1.0.4 one-turn restore: a refill from an earlier turn is dropped; a
--     new promotion uses up the open refill; hook "EFV_VetStep" with a new
--     promotion and want not empty -> Refill (moves back for the next
--     PROMOTE this turn). Boundaries and SETTLE never refill.
-- ---------------------------------------------------------------------------
function EFV_Veteran.Sync(store, job, pUnit, hook)
	if type(store) ~= "table" or job == nil or pUnit == nil then
		return "OPEN"
	end
	if not IsHuman(job.p) then
		EFV_Veteran.Fallback(store, job, pUnit, "NOT_HUMAN")
		return "FALLBACK"
	end
	if type(job.want) ~= "table" then
		job.want = {}
	end
	if job.rt ~= nil and tonumber(job.rt) ~= CurrentTurn() then
		Unloan(store, job, pUnit, "STALE")
	end
	local held = Held(pUnit)
	local got = tonumber(job.got) or 0
	local stepped = false
	if #held > got then
		stepped = true
		-- The promotion used up an open refill (it ended the turn again).
		job.rt = nil
		RestoreFloor(job, pUnit)
		local heldSet = {}
		for _, name in ipairs(held) do
			heldSet[name] = true
		end
		local rest, removed = {}, 0
		for _, name in ipairs(job.want) do
			if heldSet[name] then
				removed = removed + 1
			else
				rest[#rest + 1] = name
			end
		end
		local foreign = (#held - got) - removed
		if foreign > 0 then
			local dropped = {}
			for _ = 1, foreign do
				if #rest > 0 then
					dropped[#dropped + 1] = table.remove(rest)
				end
			end
			EFV_Log(2, TAG, "foreign promotion id=%s uid=%s count=%d dropped=%s", tostring(job.rid),
				tostring(job.u), foreign, List(dropped))
		end
		job.want = rest
		job.got = #held
		job.n = (tonumber(job.n) or 0) + 1
		Touch(store)
		EFV_Log(2, TAG, "step id=%s uid=%s hook=%s held=%s left=%s", tostring(job.rid), tostring(job.u),
			tostring(hook), List(held), List(rest))
	else
		local dmg = pUnit:GetDamage() or 0
		if dmg ~= job.dmg then
			job.dmg = dmg
			Touch(store)
		end
	end

	local exp = pUnit:GetExperience()
	if #job.want == 0 then
		local xp = exp:GetExperiencePoints() or 0
		local target = tonumber(job.xp) or 0
		if target > xp then
			exp:ChangeExperience(target - xp)
		elseif target < xp then
			EFV_Log(2, TAG, "xp kept id=%s uid=%s xp=%s target=%s (never lowered)", tostring(job.rid),
				tostring(job.u), tostring(xp), tostring(target))
		end
		if job.rt ~= nil then
			Unloan(store, job, pUnit, "DONE")
		end
		PayExhaust(store, job, pUnit)
		EFV_Records.RemoveVetJob(store, job.p, job.u)
		EFV_Log(2, TAG, "done id=%s owner=%s uid=%s promotions=%s xp=%s/%s next=%s steps=%s",
			tostring(job.rid), tostring(job.p), tostring(job.u), List(held), tostring(exp:GetExperiencePoints()),
			tostring(target), tostring(exp:GetExperienceForNextLevel()), tostring(job.n))
		return "DONE"
	end
	XPToThreshold(pUnit)
	if stepped and hook == "EFV_VetStep" then
		Refill(store, job, pUnit)
	end
	return "OPEN"
end

-- The job's unit, or nil plus the reason (EFV_Units.Get identity rules).
local function JobUnit(job)
	if EFV_Units == nil then
		return nil, "NO_UNITS_MODULE"
	end
	local pUnit, why = EFV_Units.Get(job.p, job.u, job.ut)
	return pUnit, why
end

local function DropGone(store, job, why)
	EFV_Records.RemoveVetJob(store, job.p, job.u)
	EFV_Log(2, TAG, "dropped id=%s owner=%s uid=%s why=GONE (%s) left=%s", tostring(job.rid), tostring(job.p),
		tostring(job.u), tostring(why or "NONE"), List(job.want))
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.ProcessJobs(store, turn, hook)
-- Syncs every job in array order (dropping jobs whose unit is gone), one
-- pcall per job. No deadline (0.7.4): an open job stays open. turn is only
-- logged.
-- ---------------------------------------------------------------------------
function EFV_Veteran.ProcessJobs(store, turn, hook)
	if type(store) ~= "table" or type(store.vet) ~= "table" or #store.vet == 0 then
		return nil
	end
	local jobs = {}
	for i, job in ipairs(store.vet) do
		jobs[i] = job
	end
	for _, job in ipairs(jobs) do
		local ok, err = pcall(function()
			local pUnit, why = JobUnit(job)
			if pUnit == nil then
				DropGone(store, job, why)
				return
			end
			EFV_Veteran.Sync(store, job, pUnit, hook)
		end)
		if not ok then
			EFV_Log(1, TAG, "job owner=%s uid=%s hook=%s turn=%s failed err=%s", tostring(job.p), tostring(job.u),
				tostring(hook), tostring(turn), ErrText(err))
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.OnRequestStep(playerID, params)
-- Handler of the EFV_VetStep request (EFV_Config.REQ_VETSTEP; params
-- unitID n, have n, stall n optional). Contract: INTERFACES section 6
-- (pcall, human requester, load, validate, commit); the requester only
-- reaches its own job (FindVetJob(store, playerID, unitID)); "have" is
-- logged only (gameplay reads the promotions itself). Sync runs with hook
-- "EFV_VetStep", so a landed promotion gets the 1.0.4 refill.
-- stall = 1 (1.0.4): the owner's UI found no wanted promotion offered after
-- a refill; when this Sync took no step, the open refill of this turn is
-- taken back (Unloan "STALL"). It can only take moves from the requester's
-- own unit, and only moves VEF lent this turn.
-- ---------------------------------------------------------------------------
function EFV_Veteran.OnRequestStep(playerID, params)
	local store = nil
	local ok, err = pcall(function()
		if not IsHuman(playerID) then
			EFV_Log(2, TAG, "step request rejected player=%s reasons=NOT_HUMAN_MAJOR", tostring(playerID))
			return
		end
		if type(params) ~= "table" then
			EFV_Log(1, TAG, "step request rejected player=%s: params missing", tostring(playerID))
			return
		end
		local uid = tonumber(params.unitID)
		store = EFV_Records.Load()
		local job = EFV_Records.FindVetJob(store, playerID, uid)
		if job == nil then
			EFV_Log(2, TAG, "step request player=%s uid=%s have=%s: no job (done or not theirs)",
				tostring(playerID), tostring(uid), tostring(params.have))
			return
		end
		local pUnit, why = JobUnit(job)
		if pUnit == nil then
			DropGone(store, job, why)
			return
		end
		local n0 = tonumber(job.n) or 0
		local result = EFV_Veteran.Sync(store, job, pUnit, "EFV_VetStep")
		if tonumber(params.stall) == 1 and result == "OPEN" and (tonumber(job.n) or 0) == n0 then
			Unloan(store, job, pUnit, "STALL")
		end
		EFV_Log(2, TAG, "step request player=%s uid=%s have=%s%s -> %s", tostring(playerID), tostring(uid),
			tostring(params.have), tonumber(params.stall) == 1 and " stall=1" or "", tostring(result))
	end)
	if not ok then
		EFV_Log(1, TAG, "step handler failed player=%s: %s", tostring(playerID), ErrText(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", ErrText(errC))
		end
	end
	if EFV_Notify ~= nil then
		pcall(EFV_Notify.Flush)
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.OnBoundary(hook, pid)
-- Turn-boundary entry (PlayerTurnStarted, PlayerTurnStartComplete,
-- OnGameTurnEnded), called by EFV_Gameplay after the existing boundary
-- pass; own load and commit (same sync as step 0e). Nothing to do
-- (no commit) while there is no job.
-- ---------------------------------------------------------------------------
function EFV_Veteran.OnBoundary(hook, pid)
	local store = nil
	local ok, err = pcall(function()
		store = EFV_Records.Load()
		if type(store.vet) ~= "table" or #store.vet == 0 then
			store = nil
			return
		end
		EFV_Veteran.ProcessJobs(store, CurrentTurn(), hook)
	end)
	if not ok then
		EFV_Log(1, TAG, "boundary %s(%s) failed: %s", tostring(hook), tostring(pid), ErrText(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", ErrText(errC))
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Veteran.Settle(store, pUnit)
-- Completes the unit's open job before any removal snapshot: Sync, then
-- Fallback("SNAPSHOT") if still open. Safe to call for any unit (no job ->
-- nothing happens); never raises. Callers: EFV_Transit SendBody /
-- StartReturn (WP1; also the war send-home since 1.0.4).
-- ---------------------------------------------------------------------------
function EFV_Veteran.Settle(store, pUnit)
	if type(store) ~= "table" or pUnit == nil or type(store.vet) ~= "table" or #store.vet == 0 then
		return nil
	end
	local ok, err = pcall(function()
		local job = EFV_Records.FindVetJob(store, pUnit:GetOwner(), pUnit:GetID())
		if job == nil then
			return
		end
		if EFV_Veteran.Sync(store, job, pUnit, "SETTLE") == "OPEN" then
			EFV_Veteran.Fallback(store, job, pUnit, "SNAPSHOT")
		end
	end)
	if not ok then
		EFV_Log(1, TAG, "settle failed err=%s", ErrText(err))
	end
	return nil
end

EFV_Veteran.LOADED = 1
