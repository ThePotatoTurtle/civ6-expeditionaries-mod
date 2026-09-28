-- @harness native
-- EFV_Lifecycle.ProcessTimers state machine through the real turn pipeline
-- (spec 9.1, 9.3, 14.3; PLAN 2.9 timeline; D9; designer answers Q2-Q4):
--   DEPLOYED -(EXPIRY_SOON at 3 and 1)-> expiry E
--     on valid territory -> RETURNING "EXPIRED"
--     else GRACE 5 at E, 4..1 at E+1..E+4, MUTINY 20/40/60/80 at E+5..E+8,
--     death at E+9; valid territory during grace/mutiny -> return.
--   Volunteers: no timer; lapse (WAR / PARTNER) -> GRACE, reversible.
-- Grace / mutiny landed in WP2.1 (Phase 2); more Phase 2 cases (heal at
-- every hook point, identity, turn boundaries, D9 UI) are in test_phase2.lua.

local N = function(name) return "EFV_NOTIF_" .. name end

-- Creates a deployed record for a unit already on the map.
-- opts: forceType, sender, recipient, owner (on-map owner), x, y, elapsed
-- (turns since deployment), duration, basis, dest (city), origin (city).
local function Deploy(S, opts)
	opts = opts or {}
	local ft = opts.forceType or "EXPEDITIONARY"
	local sender = opts.sender or 0
	local recipient = opts.recipient or 1
	local owner = opts.owner or ((ft == "VOLUNTEER") and sender or recipient)
	local dest = opts.dest or S.c1
	local origin = opts.origin or S.c0
	local x, y = opts.x or (dest.x + 1), opts.y or dest.y
	local u = H.unit(owner, opts.unitType or "UNIT_SWORDSMAN", x, y,
		{ promotions = { "PROMOTION_BATTLECRY" }, xp = 20, damage = opts.damage })
	local store = EFV_Records.Load()
	local turn = Game.GetCurrentGameTurn()
	local band, d = EFV_Band(origin.x, origin.y, dest.x, dest.y)
	local duration = opts.duration
	if duration == nil and ft ~= "VOLUNTEER" then duration = (ft == "CS_EXPEDITIONARY") and 10 or 20 end
	local rec = EFV_Records.New(store, {
		forceType = ft, state = "DEPLOYED", senderID = sender, recipientID = recipient,
		accessBasis = opts.basis or "ALLIANCE",
		originCityID = origin.id, originX = origin.x, originY = origin.y,
		destCityID = dest.id, destX = dest.x, destY = dest.y, rerouted = 0,
		onMapPlayerID = owner, onMapUnitID = u.id,
		sentTurn = turn - (opts.elapsed or 0) - band, arrivalTurn = turn - (opts.elapsed or 0),
		transitTurns = band, band = band, distance = d,
		deployedTurn = turn - (opts.elapsed or 0), durationTurns = duration,
		spawnFailCount = 0, feePaid = 100, maintGoldPaid = 0, lapsed = 0,
	})
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(u), turn)
	EFV_Records.Commit(store)
	H.clearNotifs()
	return rec.id, u
end

local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function Count(pid, name, turn)
	local n = 0
	for _, x in ipairs(H.notifs(pid, N(name))) do
		if turn == nil or x.turn == turn then n = n + 1 end
	end
	return n
end

-- ---------------------------------------------------------------------------
test("EXPIRY_SOON at 3 and 1 turns left, to recipient and sender", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local id = Deploy(S, { elapsed = 16 })          -- next turn: elapsed 17, left 3
	H.endTurn()
	H.eq(Count(0, "EXPIRY_SOON", FAKE.turn), 1, "sender, left 3")
	H.eq(Count(1, "EXPIRY_SOON", FAKE.turn), 1, "recipient, left 3")
	H.endTurn()
	H.eq(Count(0, "EXPIRY_SOON", FAKE.turn), 0, "left 2: silent")
	H.endTurn()
	H.eq(Count(0, "EXPIRY_SOON", FAKE.turn), 1, "left 1")
	H.eq(Rec(id).state, "DEPLOYED")
	H.clean()
end)

test("expiry on recipient territory -> RETURNING (EXPIRED), unit removed", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 19 })
	H.endTurn()                                      -- elapsed 20: expiry turn E
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(u), "unit taken off the map")
	H.eq(r.arrivalTurn, FAKE.turn + 2, "band(origin c0, dest c1) = 2")
	H.eq(r.returnCityID, S.c0.id)
	H.isnil(r.onMapUnitID); H.isnil(r.graceTurnsLeft)
	H.eq(Count(0, "RETURNING", FAKE.turn), 1)
	H.ok(H.hasLine("[Return]"))
	H.clean()
end)

test("expiry on sender territory also returns", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { elapsed = 19, x = 11, y = 11 })  -- inside player 0's borders
	H.endTurn()
	H.eq(Rec(id).state, "RETURNING")
end)

test("CS Expeditionary expires after 10 turns", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, basis = "CITY_STATE", elapsed = 8 })
	H.endTurn()
	H.eq(Rec(id).state, "DEPLOYED", "elapsed 9")
	H.endTurn()
	H.eq(Rec(id).state, "RETURNING", "elapsed 10")
end)

test("P2.1 timeline: GRACE 5..1, MUTINY 20/40/60/80, death at E+9", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.endTurn()                                       -- E
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, 5)
	H.eq(Count(0, "GRACE", FAKE.turn), 1, "GRACE notice at E")
	for left = 4, 1, -1 do
		H.endTurn()
		r = Rec(id)
		H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, left, "grace countdown")
		H.eq(Count(0, "GRACE", FAKE.turn), 1, "re-sent every turn (D9)")
	end
	for _, dmg in ipairs({ 20, 40, 60, 80 }) do
		H.endTurn()
		r = Rec(id)
		H.eq(r.state, "MUTINY")
		H.eq(u:GetDamage(), dmg, "mutiny damage")
		H.eq(r.lastDamage, dmg)
		H.eq(Count(0, "MUTINY", FAKE.turn), 1)
	end
	H.endTurn()                                       -- E+9
	H.isnil(Rec(id), "record deleted")
	H.ok(not H.unitAlive(u), "unit destroyed")
	H.eq(Count(0, "MUTINY_DEATH", FAKE.turn), 1)
	H.clean()
end)

test("GRACE: moving into recipient territory returns next turn (GRACE_RETURN)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.endTurn(); H.endTurn()                          -- E, E+1
	H.moveUnit(u, S.c1.x, S.c1.y + 1)
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "GRACE_RETURN")
end)

test("MUTINY: moving home returns; the returned unit keeps its damage", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.turns(7)                                        -- E..E+6: damage 40
	H.eq(u:GetDamage(), 40)
	H.moveUnit(u, S.c0.x + 1, S.c0.y)                 -- sender territory
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "MUTINY_RETURN")
	H.eq(r.damage, 40, "snapshot keeps damage")
	H.turns(r.arrivalTurn - FAKE.turn)
	H.isnil(Rec(id), "returned and closed")
	local back = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(back, 1)
	H.eq(back[1]:GetDamage(), 40)
	H.deq(H.promotionTypes(back[1]), { "PROMOTION_BATTLECRY" })
	H.clean()
end)

test("MUTINY: engine healing between turns is suppressed (S8)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.turns(5)                                        -- E..E+4 (grace)
	local seen = {}
	for _ = 1, 4 do
		H.endTurn{ heal = 10 }                        -- engine heals 10 before OnGameTurnStarted
		seen[#seen + 1] = u:GetDamage()
	end
	H.deq(seen, { 20, 40, 60, 80 }, "damage never decreases")
end)

test("MUTINY: mid-turn heal is floored at the next turn boundary ([Floor]), not OnPlayerTurnEnded", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.turns(7)                                        -- damage 40
	H.eq(u:GetDamage(), 40)
	local seen = nil
	H.endTurn{ act = function(pid)
		if pid == 1 then u.damage = 25                -- e.g. a medic heals during the recipient's turn
		elseif pid == 2 then seen = u:GetDamage() end
	end }
	H.eq(seen, 40, "restored to lastDamage at PlayerTurnStarted(2)")
	H.ok(H.hasLine("[Floor] restore"))
	H.ok(not H.hasLine("OnPlayerTurnEnded"), "without the legacy event")
end)

test("Volunteers: no expiry and never EXPIRY_SOON (Q4)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "VOLUNTEER", elapsed = 16 })
	H.turns(10)
	H.eq(Rec(id).state, "DEPLOYED")
	H.eq(#H.notifs(0, N("EXPIRY_SOON")), 0)
end)

test("Volunteer WAR lapse: GRACE, lapsed=1, VOLUNTEER_LAPSE; cancels when war resumes (Q2)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.peace(3, 1)                                     -- recipient no longer at war with 3
	H.endTurn()
	local L = FAKE.turn
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapsed, 1); H.eq(r.lapseReason, "WAR")
	H.eq(r.lapseTurn, L); H.eq(r.preLapseState, "DEPLOYED"); H.eq(r.graceTurnsLeft, 5)
	H.eq(Count(0, "VOLUNTEER_LAPSE", L), 1)
	local deployed = r.deployedTurn
	H.endTurn()
	H.eq(Rec(id).graceTurnsLeft, 4, "grace runs from L+1")
	H.war(3, 1)
	H.endTurn()
	r = Rec(id)
	H.eq(r.state, "DEPLOYED", "lapse cancelled")
	H.eq(r.lapsed, 0); H.isnil(r.lapseReason); H.isnil(r.preLapseState); H.isnil(r.graceTurnsLeft)
	H.eq(r.deployedTurn, deployed, "deployedTurn never resets")
	H.clean()
end)

test("Volunteer PARTNER lapse: alliance lost without friend+OB -> ACCESS_LAPSE", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3 })
	H.ally(0, 1, false)
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapseReason, "PARTNER")
	H.eq(Count(0, "ACCESS_LAPSE", FAKE.turn), 1)
end)

test("Volunteer: alliance lost but friend with open borders -> no lapse (Q3)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3 })
	H.ally(0, 1, false); H.friend(0, 1); H.openBorders(0, 1)
	H.turns(2)
	H.eq(Rec(id).state, "DEPLOYED")
end)

test("Volunteer lapse runs the grace/mutiny sequence like Expeditionary", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.peace(3, 1)
	H.turns(6)                                        -- L, L+1..L+5
	local r = Rec(id)
	H.eq(r.state, "MUTINY"); H.eq(u:GetDamage(), 20)
end)

test("Expeditionary is unaffected by losing the common war or the alliance", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { elapsed = 3 })
	H.peace(3, 1); H.ally(0, 1, false)
	H.turns(3)
	H.eq(Rec(id).state, "DEPLOYED")
end)

test("lapsed Volunteer on valid territory never auto-returns: the grace is paused (designer ruling, note 29)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3 })   -- inside the recipient's borders
	H.peace(3, 1)
	H.endTurn()
	H.eq(Rec(id).state, "GRACE"); H.eq(Rec(id).lapsePaused, 1, "starts paused on valid land")
	H.turns(3)
	local r = Rec(id)
	H.eq(r.state, "GRACE", "no GRACE_RETURN"); H.eq(r.graceTurnsLeft, 5, "no tick while paused")
	H.eq(#H.notifs(0, N("GRACE")), 0, "no GRACE spam while paused")
	H.clean()
end)
