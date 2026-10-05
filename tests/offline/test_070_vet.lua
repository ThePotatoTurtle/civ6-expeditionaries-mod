-- @harness native
-- 0.7 veteran route B (FIXPLAN_0.7 item 7, WP3; INTERFACES note 33):
--   a unit restored to a HUMAN owner gets its promotions back through the
--   owner's own PROMOTE command (EFV_VetRestore UI context), so it keeps its
--   level; gameplay (EFV_Veteran) owns the job, raises XP step by step,
--   undoes the promotion heal and falls back to SetPromotion + the XP clamp
--   before a removal snapshot or when the owner is no longer human (no time
--   limit since 0.7.4). AI owners keep the clamp path.
-- Route B is enabled explicitly (H.loadEFV{ routeB = true }): the harness
-- default is off for the legacy suites.
-- Fake engine: a script-created unit is level 1 (T08); thresholds 15 / 45 /
-- 90 for levels 1 / 2 / 3; the fake PROMOTE (fake_ui) is applied on the
-- next FAKE_UI.Update tick, raises the level and heals 50.

local BATTLECRY, TORTOISE, COMMANDO = "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE", "PROMOTION_COMMANDO"

-- A returned veteran's record (S12 shape): level 3, two promotions, 50/90
-- XP, 30 damage. The level-2 promotion comes first so the UI must follow the
-- engine's offer, not the snapshot order.
local function VetRec(fields)
	local rec = { id = 7, unitType = "UNIT_WARRIOR", promotions = { COMMANDO, BATTLECRY },
		experience = 50, xpNext = 90, level = 3, damage = 30, veteranName = "VEF-VET", formation = 0 }
	for k, v in pairs(fields or {}) do rec[k] = v end
	return rec
end

-- Recreates the veteran for owner at (11,10) and commits. Returns the unit.
local function Restore(owner, rec, turn)
	local store = EFV_Records.Load()
	local u = EFV_Units.Recreate(store, owner or 0, rec or VetRec(), H.plot(11, 10), turn or FAKE.turn)
	EFV_Records.Commit(store)
	return u
end

-- The owner's turn start gives the restored unit its moves back (the engine
-- restores moves between PlayerTurnStarted and PlayerTurnStartComplete). The
-- fake PROMOTE, like the engine (re-test 0.7 step 5), needs movement points.
local function OwnerTurnStart(u) u.moves = u.maxMoves end

local function Jobs() return EFV_Records.Load().vet end
local function Xp(u) return u:GetExperience():GetExperiencePoints() end
local function Next(u) return u:GetExperience():GetExperienceForNextLevel() end

-- Owner's UI: loads EFV_VetRestore in its own context (FAKE_UI).
local function BootUI()
	include("fake_ui")
	FAKE_UI.Enable()
	return FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")
end

-- n UI frames of 0.3 s; the requests the UI sent are delivered to gameplay
-- like EXECUTE_SCRIPT (GameEvents[OnStart](pid, params)).
local function Pump(env, n)
	for _ = 1, n do
		FAKE_UI.Update(env, 0.3)
		local reqs = FAKE_UI.requests
		FAKE_UI.requests = {}
		for _, r in ipairs(reqs) do
			FAKE_UI.AsGameplay(function() H.request(r.pid, r.params) end)
		end
	end
end

local function Promotes()
	local out = {}
	for _, c in ipairs(FAKE_UI.unitCommands or {}) do
		if c.cmd == UnitCommandTypes.PROMOTE then out[#out + 1] = c end
	end
	return out
end

-- ---------------------------------------------------------------------------
test("shipped default: FLAG_VET_ROUTE_B = true, no VET_JOB_TURNS (0.7.4); the harness turns it off unless opts.routeB", function()
	local src = __py_read("EFV/Scripts/EFV_Config.lua")
	H.ok(string.find(src, "EFV_Config.FLAG_VET_ROUTE_B%s*=%s*true") ~= nil, "shipped default on")
	H.ok(string.find(src, "VET_JOB_TURNS", 1, true) == nil, "the job deadline is gone (0.7.4)")
	H.world{}
	H.loadEFV()
	H.eq(EFV_Config.FLAG_VET_ROUTE_B, false, "harness default for legacy suites")
	H.ok(GameEvents.EFV_VetStep.Count() >= 1, "EFV_VetStep handler registered")
end)

test("human return: no promotions yet, XP 15/15 (one promotion available), one job, damage and name kept", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	H.notnil(u)
	H.len(H.promotionTypes(u), 0, "no SetPromotion on route B")
	H.eq(Xp(u), 15); H.eq(Next(u), 15)
	H.eq(u:GetDamage(), 30); H.eq(u:GetExperience():GetVeteranName(), "VEF-VET")
	H.eq(u:GetMovesRemaining(), 0)
	local jobs = Jobs()
	H.len(jobs, 1)
	local j = jobs[1]
	H.eq(j.p, 0); H.eq(j.u, u.id); H.eq(j.ut, "UNIT_WARRIOR"); H.eq(j.rid, 7); H.eq(j.t, FAKE.turn)
	H.deq(j.want, { COMMANDO, BATTLECRY }); H.eq(j.got, 0); H.eq(j.xp, 50); H.eq(j.dmg, 30); H.eq(j.n, 0)
	H.ok(H.hasLine("route=B")); H.ok(H.hasLine("[Vet] begin id=7"))
	H.clean()
end)

test("owner's UI + engine PROMOTE: level 3 with both promotions, XP 50/90, damage back at 30, job gone", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	OwnerTurnStart(u)
	local env = BootUI()
	H.ok(not env.ContextPtr:IsHidden(), "context shown (note 19)")
	Pump(env, 8)
	local p = Promotes()
	H.len(p, 2, "one PROMOTE per step")
	H.eq(GameInfo.UnitPromotions[p[1].promotion].UnitPromotionType, BATTLECRY, "the engine offers the tier-1 one first")
	H.eq(GameInfo.UnitPromotions[p[2].promotion].UnitPromotionType, COMMANDO)
	H.deq(H.promotionTypes(u), { BATTLECRY, COMMANDO })
	H.eq(u:GetExperience():GetLevel(), 3, "level kept (route B)")
	H.eq(Xp(u), 50); H.eq(Next(u), 90)
	H.eq(u:GetDamage(), 30, "promotion heal undone")
	H.len(Jobs(), 0, "job done")
	H.ok(H.hasLine("[Vet] heal undone")); H.ok(H.hasLine("[Vet] done id=7"))
	H.ok(H.hasLine("[UIRequest] EFV_VetStep"))
	-- Nothing more happens once the job is gone.
	Pump(env, 20)
	H.len(Promotes(), 2)
	H.clean()
end)

test("only the owner's client promotes (hot seat / MP: another human's UI sends nothing)", function()
	H.baseScenario()
	Players[1].human = true
	H.loadEFV{ routeB = true }
	OwnerTurnStart(Restore(0))
	include("fake_ui")
	FAKE_UI.Enable()
	FAKE.localPlayer = 1
	local other = FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")
	Pump(other, 20)
	H.len(Promotes(), 0, "player 1's UI never touches player 0's unit")
	H.len(FAKE_UI.requests, 0)
	FAKE.localPlayer = 0
	local owner = FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")
	Pump(owner, 1)
	H.len(Promotes(), 1, "the owner's client sends PROMOTE")
	H.eq(Promotes()[1].pid, 0)
	H.clean()
end)

test("PROMOTE sent once per step, one resend after 3 s; nothing offered -> the UI waits and logs once", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	OwnerTurnStart(Restore(0))
	local env = BootUI()
	FAKE_UI.canPromote = false
	for _ = 1, 30 do FAKE_UI.Update(env, 0.3) end
	H.len(Promotes(), 0)
	H.len(H.lines("[UIVet] waiting"), 1, "logged once")
	FAKE_UI.canPromote = true
	FAKE_UI.ApplyUnitCommands = function() end   -- the command never lands
	for _ = 1, 30 do FAKE_UI.Update(env, 0.3) end
	H.len(Promotes(), 2, "first send + one resend")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- 0.7.2, re-test 0.7 step 5: the level came back one turn late (arrival turn:
-- 0 moves, "no wanted promotion offered now"; next turn: both promotions at
-- full moves, and the round heal of 15 in own land left damage 15). Now a
-- route B unit gets no pending exhaust; the job owes it and pays it when the
-- level is back in the arrival turn.
-- The owner's turn start as the engine runs it after the turn-start
-- pipeline (Session E order): PTS -> moves restored -> PTSC.
local function HumanTurnStart(pid)
	GameEvents.PlayerTurnStarted(pid)
	for _, u in ipairs(FAKE.UnitsOf(pid)) do u.moves = u.maxMoves end
	GameEvents.PlayerTurnStartComplete(pid)
end

test("0.7.2 step 5: the 0.7.0 order (arrival exhaust at the owner's PTSC) leaves nothing to promote in the arrival turn", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	local store = EFV_Records.Load()
	EFV_Records.AddPending(store, 0, u.id, FAKE.turn)   -- what 0.7.0 queued
	EFV_Records.Commit(store)
	HumanTurnStart(0)
	H.eq(u:GetMovesRemaining(), 0, "exhausted at PTSC")
	local env = BootUI()
	Pump(env, 8)
	H.len(Promotes(), 0, "no PROMOTE at 0 moves")
	H.ok(H.hasLine("[UIVet] waiting"), "the 0.7.0 log line")
	H.len(Jobs(), 1)
	H.clean()
end)

test("0.7.2 step 5: route B unit keeps its moves until the level is back, all in the arrival turn; then 0 moves", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, nil, t0)
	H.ok(H.hasLine("arrival exhaust left to the veteran job"))
	H.len(EFV_Records.Load().pending, 0, "no pending exhaust for a route B unit")
	H.eq(Jobs()[1].ex, 1, "the job owes the arrival exhaust")
	HumanTurnStart(0)
	H.ok(u:GetMovesRemaining() > 0, "moves kept at PTSC, so PROMOTE is offered")
	local env = BootUI()
	Pump(env, 8)
	H.eq(FAKE.turn, t0, "still the arrival turn")
	H.len(Promotes(), 2)
	H.eq(u:GetExperience():GetLevel(), 3)
	H.eq(Xp(u), 50); H.eq(Next(u), 90)
	H.eq(u:GetDamage(), 30, "no round heal yet, promotion heal undone")
	H.len(Jobs(), 0)
	H.eq(u:GetMovesRemaining(), 0, "exhausted once the level is back (arrived units do not act)")
	H.ok(H.hasLine("[Vet] exhaust id=7"))
	H.endTurn()
	H.eq(u:GetMovesRemaining(), u.maxMoves, "next turn: full moves (the pending entry is stale)")
	H.ok(H.hasLine("[Exhaust] skip stale"))
	H.clean()
end)

test("0.7.2 step 5: a job that ends after the arrival turn owes no exhaust (moves of a later turn are never taken)", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	HumanTurnStart(0)
	local env = BootUI()
	FAKE_UI.canPromote = false
	Pump(env, 4)
	H.len(Jobs(), 1, "nothing taken in the arrival turn")
	H.endTurn()
	FAKE_UI.canPromote = true
	Pump(env, 8)
	H.len(Jobs(), 0, "done the next turn")
	H.eq(u:GetMovesRemaining(), u.maxMoves, "moves of the later turn kept")
	H.ok(not H.hasLine("[Vet] exhaust id="))
	H.clean()
end)

test("0.7.2 step 5: a fallback in the arrival turn pays the exhaust (owner turned AI); a SNAPSHOT fallback does not (the unit leaves)", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	HumanTurnStart(0)
	local store = EFV_Records.Load()
	EFV_Veteran.Settle(store, u)
	EFV_Records.Commit(store)
	H.len(Jobs(), 0)
	H.ok(H.hasLine("why=SNAPSHOT"))
	H.eq(u:GetMovesRemaining(), u.maxMoves, "SNAPSHOT: a removal follows, the send must not fail NOT_FULL_MOVES")
	H.ok(not H.hasLine("[Vet] exhaust id=7"))
	local v = Restore(0, VetRec({ id = 8 }))
	v.moves = v.maxMoves
	Players[0].human = false
	GameEvents.OnGameTurnEnded(FAKE.turn)   -- a boundary in the arrival turn
	H.ok(H.hasLine("why=NOT_HUMAN"))
	H.eq(v:GetMovesRemaining(), 0, "the arrival exhaust is paid")
	H.ok(H.hasLine("[Vet] exhaust id=8"))
	H.clean()
end)

test("AI owner: clamp path (promotions set, level 1, XP 14), no job; 1.0.4: no refill, the usual pending exhaust", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(1)
	H.deq(H.promotionTypes(u), { BATTLECRY, COMMANDO })
	H.eq(Xp(u), 14); H.eq(Next(u), 15)
	H.len(Jobs(), 0)
	H.ok(H.hasLine("route=classic"))
	H.eq(u:GetMovesRemaining(), 0)
	local pend = EFV_Records.Load().pending
	H.len(pend, 1); H.eq(pend[1].u, u.id)
	H.request(1, { OnStart = "EFV_VetStep", unitID = u.id, have = 2 })   -- no job, AI requester
	H.eq(u:GetMovesRemaining(), 0)
	H.ok(not H.hasLine("[Vet] refill"))
	H.clean()
end)

test("FLAG_VET_ROUTE_B = false: clamp for human owners too", function()
	H.baseScenario()
	H.loadEFV{ routeB = false }
	local u = Restore(0)
	H.len(H.promotionTypes(u), 2); H.eq(Xp(u), 14)
	H.len(Jobs(), 0)
	H.clean()
end)

test("a snapshot without known promotions uses the classic path (nothing to promote)", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, VetRec({ promotions = { "PROMOTION_DOES_NOT_EXIST" } }))
	H.len(Jobs(), 0)
	H.eq(Xp(u), 14)
end, { allowErrors = true })

-- 0.7.4 (designer decision): no time limit. Before 1.0.4 the engine's one
-- promotion per turn (a promotion ends the unit's turn) made a veteran with
-- N promotions need about N turns, and the 0.7.0 deadline (t + 2 ->
-- SetPromotion + clamp) reset every 3+ promotion veteran. 1.0.4 restores
-- them in one turn (below); a job still never times out.
test("0.7.4: a job nobody advances stays open for many turns (no fallback), XP kept at the next threshold", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, nil, t0)
	H.turns(8)
	H.eq(FAKE.turn, t0 + 8)
	H.len(Jobs(), 1, "still open")
	H.len(H.promotionTypes(u), 0, "no SetPromotion")
	H.eq(Xp(u), 15, "one promotion available: the player may pick it by hand")
	H.ok(not H.hasLine("[Vet] fallback"))
	H.ok(not H.hasLine("TIMEOUT"))
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- 1.0.4 one-turn restore (designer ruling 2026-10-05, EFV_Dev 1.0.3.2 spike
-- V2). In game a landed promotion ends the unit's turn
-- (FAKE_UI.promoteEndsTurn) and PROMOTE needs moves
-- (FAKE_UI.promoteNeedsMoves), which made route B one promotion per turn.
-- Gameplay now refills the moves after each promotion the EFV_VetStep
-- request syncs (ChangeMovesRemaining, job.rt = the loan's turn) and the UI
-- chains the next PROMOTE in the same turn.
local FOUR = { BATTLECRY, COMMANDO, "PROMOTION_ZWEIHANDER", "PROMOTION_ELITE_GUARD" }
local FOUR_HELD = { BATTLECRY, COMMANDO, "PROMOTION_ELITE_GUARD", "PROMOTION_ZWEIHANDER" }   -- DB order

local function FourRec(fields)
	local rec = VetRec({ promotions = FOUR, experience = 160, xpNext = 225, level = 5 })
	for k, v in pairs(fields or {}) do rec[k] = v end
	return rec
end

-- The owner's UI, with the engine rule that a promotion ends the unit's turn.
local function BootUIEndsTurn()
	local env = BootUI()
	FAKE_UI.promoteEndsTurn = true
	return env
end

-- Counts the unit's ChangeMovesRemaining calls and the highest moves value
-- they left.
local function WatchMoves(u)
	local w = { calls = 0, peak = u.moves }
	local orig = u.ChangeMovesRemaining
	u.ChangeMovesRemaining = function(self, d)
		w.calls = w.calls + 1
		orig(self, d)
		if self.moves > w.peak then w.peak = self.moves end
	end
	return w
end

test("1.0.4: a 4-promotion veteran gets every promotion back in the arrival turn: level 5, XP 160/225, damage 30, then 0 moves", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, FourRec(), t0)
	HumanTurnStart(0)
	local env = BootUIEndsTurn()
	local w = WatchMoves(u)
	Pump(env, 16)
	H.eq(FAKE.turn, t0, "still the arrival turn")
	H.len(Promotes(), 4, "four PROMOTEs, all in the arrival turn")
	H.deq(H.promotionTypes(u), FOUR_HELD)
	H.eq(u:GetExperience():GetLevel(), 5, "level kept")
	H.eq(Xp(u), 160); H.eq(Next(u), 225)
	H.eq(u:GetDamage(), 30, "every promotion heal undone")
	H.len(Jobs(), 0, "done")
	H.len(H.lines("[Vet] refill id=7"), 3, "a refill after each promotion but the last")
	H.eq(w.calls, 3)
	H.ok(w.peak <= u.maxMoves, "never above the unit's max moves")
	H.eq(u:GetMovesRemaining(), 0, "0 moves on the arrival turn once the level is back")
	H.ok(H.hasLine("[Vet] exhaust id=7"))
	H.ok(not H.hasLine("[Vet] fallback"))
	H.endTurn()
	H.eq(u:GetMovesRemaining(), u.maxMoves, "next turn: full moves")
	H.clean()
end)

test("1.0.4: a job the arrival turn could not start (0 moves) restores everything in one later turn; no free moves, no exhaust", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, FourRec(), t0)
	local env = BootUIEndsTurn()
	Pump(env, 8)
	H.len(H.promotionTypes(u), 0, "arrival turn: 0 moves, nothing offered")
	H.endTurn()
	H.eq(FAKE.turn, t0 + 1)
	local before = u:GetMovesRemaining()
	H.eq(before, u.maxMoves)
	local w = WatchMoves(u)
	Pump(env, 16)
	H.eq(FAKE.turn, t0 + 1, "all in one later turn")
	H.len(Jobs(), 0)
	H.deq(H.promotionTypes(u), FOUR_HELD)
	H.eq(u:GetExperience():GetLevel(), 5)
	H.eq(Xp(u), 160); H.eq(Next(u), 225)
	H.eq(u:GetDamage(), 30, "damage floor kept")
	H.eq(w.calls, 3)
	H.ok(w.peak <= before, "a refill never lifts the moves above what the unit had before the step")
	H.eq(u:GetMovesRemaining(), 0, "the last promotion ends the turn as in the base game; nothing lent is kept")
	H.ok(not H.hasLine("[Vet] exhaust id=7"), "no arrival exhaust in a later turn")
	H.clean()
end)

test("1.0.4: the owner turned AI mid-chain: the lent moves are taken back and the fallback sets the rest (arrival turn, later turn)", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, FourRec())
	HumanTurnStart(0)
	local env = BootUIEndsTurn()
	Pump(env, 2)
	H.len(H.promotionTypes(u), 1, "one promotion landed")
	H.eq(Jobs()[1].rt, FAKE.turn, "the refill is an open loan of this turn")
	H.eq(u:GetMovesRemaining(), u.maxMoves, "moves lent for the next PROMOTE")
	Players[0].human = false
	GameEvents.OnGameTurnEnded(FAKE.turn)
	H.len(Jobs(), 0)
	H.ok(H.hasLine("why=NOT_HUMAN"))
	H.ok(H.hasLine("[Vet] refill undone id=7"))
	H.ok(H.hasLine("[Vet] exhaust id=7"))
	H.eq(u:GetMovesRemaining(), 0, "no lent moves kept in the arrival turn")
	H.deq(H.promotionTypes(u), FOUR_HELD, "the rest set by the fallback")
	H.eq(u:GetDamage(), 30, "damage floor kept")
	-- A later turn: the loan is taken back the same way, no arrival exhaust.
	Players[0].human = true
	local v = Restore(0, FourRec({ id = 8 }))
	H.endTurn()
	Pump(env, 2)
	H.len(H.promotionTypes(v), 1)
	H.eq(Jobs()[1].rt, FAKE.turn)
	H.eq(v:GetMovesRemaining(), v.maxMoves)
	Players[0].human = false
	GameEvents.OnGameTurnEnded(FAKE.turn)
	H.ok(H.hasLine("[Vet] refill undone id=8"))
	H.eq(v:GetMovesRemaining(), 0, "back to what the promotion left")
	H.ok(not H.hasLine("[Vet] exhaust id=8"), "no arrival exhaust in a later turn")
	H.clean()
end)

test("1.0.4: nothing wanted offered after a refill -> the UI reports the stall once, gameplay takes the lent moves back; the rest comes next turn", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, FourRec(), t0)
	HumanTurnStart(0)
	local env = BootUIEndsTurn()
	Pump(env, 2)
	H.len(H.promotionTypes(u), 1)
	H.eq(u:GetMovesRemaining(), u.maxMoves)
	FAKE_UI.canPromote = false     -- the engine offers nothing now
	Pump(env, 10)
	H.len(H.lines("[UIVet] stalled"), 1, "reported once")
	H.ok(H.hasLine("why=STALL"))
	H.eq(u:GetMovesRemaining(), 0, "lent moves given back")
	local j = Jobs()[1]
	H.notnil(j, "job still open"); H.isnil(j.rt); H.eq(j.got, 1)
	Pump(env, 10)
	H.len(H.lines("[UIVet] stalled"), 1, "not again for the same step")
	FAKE_UI.canPromote = true
	H.endTurn()
	Pump(env, 16)
	H.eq(FAKE.turn, t0 + 1)
	H.len(Jobs(), 0)
	H.deq(H.promotionTypes(u), FOUR_HELD)
	H.eq(u:GetExperience():GetLevel(), 5)
	H.eq(u:GetMovesRemaining(), 0)
	H.clean()
end)

test("1.0.4: stall = 1 without a loan of this turn, or right after a new promotion, takes no moves", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, FourRec())
	HumanTurnStart(0)
	H.request(0, { OnStart = "EFV_VetStep", unitID = u.id, have = 0, stall = 1 })
	H.eq(u:GetMovesRemaining(), u.maxMoves, "no loan: nothing taken")
	-- A promotion landed (moves 0, as in game); the request syncs it and
	-- lends the moves, the stall flag does not undo that step.
	u.promotions[GameInfo.UnitPromotions[BATTLECRY].Index] = true; u.level = 2; u.moves = 0
	H.request(0, { OnStart = "EFV_VetStep", unitID = u.id, have = 1, stall = 1 })
	H.eq(Jobs()[1].got, 1)
	H.eq(Jobs()[1].rt, FAKE.turn)
	H.eq(u:GetMovesRemaining(), u.maxMoves, "the step's refill stays")
	H.request(2, { OnStart = "EFV_VetStep", unitID = u.id, have = 1, stall = 1 })   -- not the owner
	H.eq(u:GetMovesRemaining(), u.maxMoves)
	H.clean()
end)

test("1.0.4: a boundary that finds a new promotion syncs it without a refill (only EFV_VetStep lends moves)", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, FourRec())
	u.promotions[GameInfo.UnitPromotions[BATTLECRY].Index] = true; u.level = 2; u.moves = 0
	GameEvents.OnGameTurnEnded(FAKE.turn)
	H.eq(Jobs()[1].got, 1, "synced")
	H.isnil(Jobs()[1].rt)
	H.eq(u:GetMovesRemaining(), 0)
	H.ok(not H.hasLine("[Vet] refill id="))
	H.clean()
end)

test("1.0.4: a loan still open when its turn ends is dropped next turn without taking the new turn's moves", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, FourRec())
	HumanTurnStart(0)
	local env = BootUIEndsTurn()
	Pump(env, 2)
	H.eq(Jobs()[1].rt, FAKE.turn)
	H.endTurn()   -- the UI does not run in between (no stall report)
	H.eq(u:GetMovesRemaining(), u.maxMoves, "the new turn's moves")
	H.isnil(Jobs()[1].rt, "loan dropped at the turn start")
	H.ok(H.hasLine("[Vet] refill dropped id=7"))
	H.ok(not H.hasLine("[Vet] refill undone"))
	H.clean()
end)

test("1.0.4: save and load mid-chain: the job and its loan survive, a fresh UI finishes the restore in the same turn", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local t0 = FAKE.turn
	local u = Restore(0, FourRec(), t0)
	HumanTurnStart(0)
	local env = BootUIEndsTurn()
	Pump(env, 2)
	H.len(H.promotionTypes(u), 1)
	FAKE_UI.AsGameplay(H.reloadEFV)
	local j = Jobs()[1]
	H.notnil(j)
	H.eq(j.rt, t0, "the loan is in the saved job"); H.eq(j.ex, 1, "the arrival exhaust is still owed"); H.eq(j.got, 1)
	local env2 = FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")   -- the UI comes back with empty memory
	Pump(env2, 16)
	H.eq(FAKE.turn, t0)
	H.len(Jobs(), 0)
	H.deq(H.promotionTypes(u), FOUR_HELD)
	H.eq(u:GetExperience():GetLevel(), 5)
	H.eq(Xp(u), 160); H.eq(Next(u), 225)
	H.eq(u:GetDamage(), 30)
	H.eq(u:GetMovesRemaining(), 0, "arrival turn: 0 moves")
	H.ok(H.hasLine("[Vet] exhaust id=7"))
	H.clean()
end)

test("0.7.4: after turns of progress, the owner turning AI still falls back (NOT_HUMAN) at the next boundary", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0, VetRec({ promotions = { BATTLECRY, COMMANDO, "PROMOTION_ZWEIHANDER" }, experience = 100,
		xpNext = 150, level = 4 }))
	H.turns(3)
	u.promotions[GameInfo.UnitPromotions[BATTLECRY].Index] = true; u.level = 2
	H.request(0, { OnStart = "EFV_VetStep", unitID = u.id, have = 1 })
	H.len(Jobs(), 1)
	H.turns(2)
	H.len(Jobs(), 1, "still open, no deadline")
	Players[0].human = false
	H.endTurn()
	H.len(Jobs(), 0)
	H.ok(H.hasLine("why=NOT_HUMAN"))
	H.deq(H.promotionTypes(u), { BATTLECRY, COMMANDO, "PROMOTION_ZWEIHANDER" }, "the rest set")
	H.eq(Xp(u), 44, "XP target then the clamp (level 2 threshold 45 - 1)")
	H.clean()
end)

test("a promotion picked by hand replaces one: promotion count equals the snapshot's", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	local idx = function(name) return GameInfo.UnitPromotions[name].Index end
	-- The player picks Tortoise (not in the snapshot) in the unit panel.
	u.promotions[idx(TORTOISE)] = true; u.level = 2; u.damage = 0
	H.request(0, { OnStart = "EFV_VetStep", unitID = u.id, have = 1 })
	local j = Jobs()[1]
	H.deq(j.want, { COMMANDO }, "the last wanted entry is dropped, Battlecry-free list kept in order")
	H.eq(j.got, 1); H.eq(u:GetDamage(), 30, "heal undone")
	H.eq(Xp(u), 45, "next promotion available")
	H.ok(H.hasLine("[Vet] foreign promotion"))
	u.promotions[idx(COMMANDO)] = true; u.level = 3
	H.request(0, { OnStart = "EFV_VetStep", unitID = u.id, have = 2 })
	H.len(Jobs(), 0)
	H.len(H.promotionTypes(u), 2, "as many promotions as the snapshot")
	H.eq(Xp(u), 50)
	H.clean()
end)

test("EFV_VetStep from another player or a non-human changes nothing", function()
	H.baseScenario()
	Players[2].human = true
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	u.promotions[GameInfo.UnitPromotions[BATTLECRY].Index] = true; u.level = 2
	H.request(1, { OnStart = "EFV_VetStep", unitID = u.id, have = 1 })   -- AI
	H.request(2, { OnStart = "EFV_VetStep", unitID = u.id, have = 1 })   -- another human
	local j = Jobs()[1]
	H.eq(j.got, 0, "not synced"); H.deq(j.want, { COMMANDO, BATTLECRY })
	H.ok(H.hasLine("reasons=NOT_HUMAN_MAJOR")); H.ok(H.hasLine("no job"))
	H.clean()
end)

test("jobs survive the property round trip and a reload; want = {} comes back as {}", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	H.reloadEFV()
	local j = Jobs()[1]
	H.notnil(j); H.eq(j.u, u.id); H.deq(j.want, { COMMANDO, BATTLECRY })
	local s = EFV_Records.Load()
	s.vet[1].want = {}
	EFV_Records.MarkDirty(s, EFV_Config.PROP.VET)
	EFV_Records.Commit(s)
	H.deq(Jobs()[1].want, {}, "normalised on load")
	H.clean()
end)

test("Settle completes an open job by fallback (why=SNAPSHOT); no job -> nothing", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	local s = EFV_Records.Load()
	EFV_Veteran.Settle(s, u)
	H.len(s.vet, 0)
	H.len(H.promotionTypes(u), 2); H.eq(Xp(u), 14); H.eq(u:GetDamage(), 30)
	H.ok(H.hasLine("why=SNAPSHOT"))
	EFV_Veteran.Settle(s, H.unit(0, "UNIT_WARRIOR", 12, 10))
	EFV_Veteran.Settle(s, nil)
	H.clean()
end)

test("owner turned AI (MP drop) -> fallback at the next boundary; a gone unit drops its job", function()
	H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = Restore(0)
	Players[0].human = false
	GameEvents.PlayerTurnStarted(0)
	H.len(Jobs(), 0)
	H.len(H.promotionTypes(u), 2)
	H.ok(H.hasLine("why=NOT_HUMAN"))
	Players[0].human = true
	local v = Restore(0, VetRec({ id = 8 }))
	H.len(Jobs(), 1)
	H.killUnit(v)
	GameEvents.OnGameTurnEnded(FAKE.turn)
	H.len(Jobs(), 0)
	H.ok(H.hasLine("[Vet] dropped id=8"))
	H.clean()
end)

-- Sends u and ends turns until the record is DEPLOYED (the arrival turn).
local function SendAndArrive(u, recipient, city, forceType)
	H.send(0, u, recipient, city, forceType)
	local r = H.record()
	H.notnil(r, "sent")
	for _ = 1, r.transitTurns do H.endTurn() end
	r = H.record()
	H.eq(r.state, "DEPLOYED")
	return r
end

test("arrival: Volunteers (kept by the human sender) use route B", function()
	local S = H.baseScenario()
	H.loadEFV{ routeB = true }
	H.openBorders(0, 2, true)
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { BATTLECRY }, xp = 20 })
	local r = SendAndArrive(u, 2, S.c2, "VOLUNTEER")
	H.eq(r.onMapPlayerID, 0)
	local jobs = Jobs()
	H.len(jobs, 1); H.eq(jobs[1].p, 0); H.eq(jobs[1].u, r.onMapUnitID); H.deq(jobs[1].want, { BATTLECRY })
	H.clean()
end)

test("arrival: Expeditionary to an AI recipient keeps the clamp path (no job)", function()
	local S = H.baseScenario()
	H.loadEFV{ routeB = true }
	local u = H.unit(0, "UNIT_SWORDSMAN", 9, 10, { promotions = { BATTLECRY }, xp = 20 })
	local r = SendAndArrive(u, 1, S.c1, "EXPEDITIONARY")
	H.eq(r.onMapPlayerID, 1)
	H.len(Jobs(), 0)
	local nu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.deq(H.promotionTypes(nu), { BATTLECRY }); H.eq(Xp(nu), 14)
	H.ok(H.hasLine("route=classic"))
	H.clean()
end)

test("arrival: Expeditionary to a HUMAN recipient uses route B for that recipient", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV{ routeB = true }
	local u = H.unit(0, "UNIT_SWORDSMAN", 9, 10, { promotions = { BATTLECRY }, xp = 20 })
	local r = SendAndArrive(u, 1, S.c1, "EXPEDITIONARY")
	H.eq(r.onMapPlayerID, 1)
	local jobs = Jobs()
	H.len(jobs, 1); H.eq(jobs[1].p, 1); H.eq(jobs[1].u, r.onMapUnitID)
	H.deq(jobs[1].want, { BATTLECRY })
	H.clean()
	H.len(FAKE.forbidden, 0, "no Game.GetLocalPlayer in gameplay")
end)

test("EFV_Records vet jobs: sorted add, replace, find, remove, malformed dropped on load, dump", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	EFV_Records.AddVetJob(s, { p = 1, u = 5, t = 3, want = { BATTLECRY } })
	EFV_Records.AddVetJob(s, { p = 0, u = 9, t = 3, want = { BATTLECRY } })
	EFV_Records.AddVetJob(s, { p = 0, u = 2, t = 2, want = { BATTLECRY } })
	EFV_Records.AddVetJob(s, { p = 1, u = 5, t = 3, want = { TORTOISE } })   -- replaces
	H.len(s.vet, 3)
	H.deq({ s.vet[1].u, s.vet[2].u, s.vet[3].u }, { 2, 9, 5 }, "(t, p, u) order")
	local j, i = EFV_Records.FindVetJob(s, 1, 5)
	H.eq(i, 3); H.deq(j.want, { TORTOISE })
	H.isnil(EFV_Records.FindVetJob(s, 1, 9))
	H.ok(EFV_Records.RemoveVetJob(s, 0, 9)); H.ok(not EFV_Records.RemoveVetJob(s, 0, 9))
	s.vet[#s.vet + 1] = { p = "x" }
	EFV_Records.MarkDirty(s, EFV_Config.PROP.VET)
	EFV_Records.Commit(s)
	local l = EFV_Records.Load()
	H.len(l.vet, 2, "malformed job dropped")
	H.eq(l.vet[1].got, 0); H.eq(l.vet[1].n, 0)
	EFV_Records.Dump(l)
	H.len(H.lines("[Dump] vet "), 2)
end, { allowErrors = true })
