-- @harness native
-- Phase 4: City-State Expeditionary (PLAN 5.4 WP4.1 / WP4.2; spec 9.3, 6, 11)
-- end to end on the fake engine, in the confirmed in-game hook order:
--   P4.1 eligibility (any met city-state), rows, fee = Expeditionary column,
--        duration 10, send -> arrival as a city-state-owned unit with 0 moves;
--   P4.2 CS war rule (1.0.2 designer ruling: no shared enemy needed; only
--        a war between the sender and the city-state -> rejected);
--   P4.3 10-turn timer, EXPIRY_SOON at 3 and 1 (_CS sender text), return
--        at expiry from anywhere (0.7: no grace / mutiny for CS);
--   P4.4 valid return territory = the city-state's or the sender's tiles,
--        NOT an ally's (still used by EXP-style checks; CS expiry ignores it);
--   spec 11 rows for CS (WP5.1 brought forward, INTERFACES note 24):
--        sender-CS war -> revert / return, city-state eliminated -> return
--        (in transit and from the snapshot);
--   suzerain levy -> relink (RelinkLevied).
-- The UI tests for "Send to City-State" moved to test_070_send.lua (0.7).
-- Scenario (H.baseScenario): 0 human (cities (10,10), (14,20)), 1 ally B,
-- 2 friend F, 3 enemy C (at war with 0, 1, 2 and the city-state), 4 city-state
-- at (30,20) (met by 0, at war with C).

local N = function(name) return "EFV_NOTIF_" .. name end
local CS = "CS_EXPEDITIONARY"
local FEE_EXP = { 0, 36, 72, 108 }   -- Swordsman, Standard speed (0.5.2 fee ruling: band 1 free)

local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end

local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end

local function Sent(pid, name, turn)
	local out = {}
	for _, n in ipairs(H.notifs(pid, N(name))) do
		if turn == nil or n.turn == turn then out[#out + 1] = n end
	end
	return out
end
local function Summary(n) return n.data[ParameterTypes.SUMMARY] end

-- A Swordsman of player 0 next to its capital (origin = (10,10)).
local function MyUnit()
	return H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 })
end

-- Sends a CS Expeditionary to the city-state's capital and plays until it
-- arrives. Returns the record and the city-state's unit.
local function SendAndArrive(S)
	H.send(0, MyUnit(), 4, S.c4, CS, 999)
	local r = Only()
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "DEPLOYED")
	return r, Players[4]:GetUnits():FindID(r.onMapUnitID)
end

-- Suzerain levy as the engine does it (Firaxis rule UnitFlagManager.lua:734-758:
-- owner ~= original owner; Session F T28): every unit of `from` whose original
-- owner is `orig` becomes a new unit of `to` on the same tile (new ID), keeping
-- damage, XP, promotions and formation; the old object stays in `from`'s list
-- at -9999,-9999 until the next turn start (FAKE.LevyTransfer). Returns the new
-- units in old-ID order.
local function TransferUnits(from, to, orig)
	return H.levy(from, to, orig)
end
local function Levy(cs, suzerain)
	Players[cs].suzerain = suzerain
	return TransferUnits(cs, suzerain, cs)
end
local function EndLevy(cs, suzerain)
	return TransferUnits(suzerain, cs, cs)
end

-- ===========================================================================
-- P4.1 / P4.2 rules
-- ===========================================================================
test("P4.1 rules: CS rows = met city-states' cities; fee = Expeditionary column; duration 10", function()
	local S = H.baseScenario()
	FAKE.NewPlayer(5, { kind = "CITY_STATE" })
	local c5 = H.city(5, 40, 10, { capital = true, name = "LOC_CITY_CS2" })
	H.war(3, 5)                                       -- shares the war, but not met
	H.loadEFV()
	local u = MyUnit()
	local store = EFV_Records.Load()
	local rows = EFV_DestinationRows(0, u, CS, store)
	H.len(rows, 1, "only the met city-state (4); unmet 5 and all majors excluded")
	local row = rows[1]
	H.eq(row.recipientID, 4); H.eq(row.cityID, S.c4.id); H.ok(row.ok, "enabled")
	local band = EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y)
	H.eq(row.calc.band, band); H.eq(row.calc.transit, band)
	H.eq(row.calc.fee, FEE_EXP[band], "FEE_CS_EXPEDITIONARY 0% + band surcharge")
	H.eq(row.calc.duration, 10, "CS_EXPEDITIONARY_DURATION")
	H.eq(row.calc.basis, "CITY_STATE")
	local _, _, expCalc = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", store)
	H.eq(EFV_Fee("UNIT_SWORDSMAN", CS, expCalc.band), expCalc.fee, "same fee as Expeditionary for the same band")
	-- Expeditionary rows never list city-states.
	for _, r in ipairs(EFV_DestinationRows(0, u, "EXPEDITIONARY", store)) do
		H.ne(EFV_PlayerKind(r.recipientID), "CITY_STATE")
	end
	-- Forged destinations.
	local ok, reasons = EFV_EvaluateSend(0, u, 5, c5, CS, store)
	H.ok(not ok); H.eq(reasons[1], "CS_NOT_MET", "unmet city-state")
	ok, reasons = EFV_EvaluateSend(0, u, 1, S.c1, CS, store)
	H.contains(reasons, "CS_NOT_MET", "a major is not a city-state")
	ok, reasons = EFV_EvaluateSend(0, u, 4, S.c4, "EXPEDITIONARY", store)
	H.contains(reasons, "NOT_PARTNER", "a city-state is not an Expeditionary partner")
	H.meet(0, 5)
	H.len(EFV_DestinationRows(0, u, CS, store), 2, "met -> listed")
	H.clean()
end)

test("P4.2 CS war rule (1.0.2): no shared enemy needed; only a war with the city-state itself blocks", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = MyUnit()
	local store = EFV_Records.Load()
	local function Reasons() local _, r = EFV_EvaluateSend(0, u, 4, S.c4, CS, store); return r end
	H.deq(Reasons(), {})
	H.peace(3, 4)                                     -- the city-state's only war ends
	H.deq(Reasons(), {}, "a city-state at war with nobody is allowed (proxy wars)")
	H.war(63, 4); H.war(63, 0)                        -- both fight the barbarians only
	H.deq(Reasons(), {}, "barbarian wars change nothing")
	H.war(62, 4)                                      -- 0 is always at war with the Free Cities
	H.deq(Reasons(), {}, "Free Cities wars change nothing")
	H.peace(62, 4); H.war(2, 4)                       -- the city-state fights F, 0 does not
	H.deq(Reasons(), {}, "a war of the city-state the sender stays out of is allowed")
	H.len(EFV_DestinationRows(0, u, CS, store), 1, "the met city-state is listed")
	H.ok(EFV_DestinationRows(0, u, CS, store)[1].ok, "and its row is open")
	-- Expeditionary to a major still needs the shared war (unchanged).
	H.peace(3, 1); H.peace(3, 0)
	H.contains(select(2, EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", store)), "NO_COMMON_WAR", "EXP keeps the shared-enemy rule")
	H.war(3, 4)
	H.war(0, 4)
	H.contains(Reasons(), "AT_WAR_WITH_RECIPIENT")
	-- Gameplay rejects the forged send with the first reason and names the city-state.
	H.send(0, u, 4, S.c4, CS, 999)
	H.len(H.records(), 0)
	local f = Sent(0, "REQUEST_FAILED")
	H.len(f, 1)
	H.ok(string.find(Summary(f[1]), EFV_PlayerName(4), 1, true), Summary(f[1]))
	H.clean()
end)

-- ===========================================================================
-- P4.1 send and arrival
-- ===========================================================================
test("P4.1 send: fee charged, OUTBOUND with duration 10; arrives owned by the city-state with 0 moves", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = MyUnit()
	local band = EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y)
	local fee = FEE_EXP[band]
	H.send(0, u, 4, S.c4, CS, fee)
	local r = Only()
	H.eq(r.forceType, CS); H.eq(r.state, "OUTBOUND"); H.eq(r.recipientID, 4)
	H.eq(r.accessBasis, "CITY_STATE"); H.eq(r.durationTurns, 10); H.eq(r.feePaid, fee)
	H.eq(r.arrivalTurn, FAKE.turn + band); H.eq(r.originCityID, S.c0.id)
	H.eq(H.gold(0), 1000 - fee)
	H.ok(not H.unitAlive(u), "unit left the map")
	H.len(Sent(0, "DEPARTED"), 1)
	-- Transit: the sender pays the Swordsman's gold maintenance (2) each turn.
	H.turns(band)
	r = Only()
	H.eq(r.state, "DEPLOYED"); H.eq(r.deployedTurn, FAKE.turn)
	H.eq(r.maintGoldPaid, 2 * band); H.eq(H.gold(0), 1000 - fee - 2 * band)
	H.eq(r.onMapPlayerID, 4, "owner = the city-state (spec 7.4)")
	local cu = Players[4]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(cu)
	H.eq(cu:GetOriginalOwner(), 4)
	H.deq(H.promotionTypes(cu), { "PROMOTION_BATTLECRY" }); H.eq(cu.xp, 14) -- Session F T08 + FLAG_XP_CLAMP: level 1, XP clamped to 14
	H.ok(H.dist(cu, S.c4) >= 1 and H.dist(cu, S.c4) <= 5, "spawned in rings 1-5 of the city-state")
	H.eq(H.plot(cu.x, cu.y):GetOwner(), 4, "ring 1 = the city-state's own tiles")
	H.len(Sent(0, "ARRIVED"), 1, "sender notified"); H.len(Sent(4, "ARRIVED"), 0, "city-state is AI")
	-- 0 moves in the city-state's first turn (S10: exhausted again at its PlayerTurnStartComplete).
	local seenMoves
	H.endTurn{ act = function(p) if p == 4 then seenMoves = cu:GetMovesRemaining() end end }
	H.eq(seenMoves, 0)
	H.clean()
end)

-- ===========================================================================
-- P4.3 / P4.4 timeline and return territory
-- ===========================================================================
test("P4.3 timeline: EXPIRY_SOON at 3 and 1 (names the city-state), expiry on its tiles -> EXPIRED -> RETURNED", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	local D = FAKE.turn
	local unit, csName = EFV_UnitDisplayName("UNIT_SWORDSMAN"), EFV_PlayerName(4)
	local warned = {}
	for t = D + 1, D + 9 do
		H.endTurn()
		H.eq(Only().state, "DEPLOYED", "turn " .. t)
		local w = Sent(0, "EXPIRY_SOON", FAKE.turn)
		if #w > 0 then
			warned[#warned + 1] = FAKE.turn - D
			H.eq(Summary(w[1]), Locale.Lookup("LOC_EFV_NOTIF_EXPIRY_SOON_CS_SUMMARY", unit, 10 - (FAKE.turn - D), csName))
		end
	end
	H.deq(warned, { 7, 9 }, "left 3 and left 1")
	H.endTurn()                                       -- D + 10: expiry on the city-state's tiles
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(cu), "removed from the city-state")
	local back = EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y)
	H.eq(r.arrivalTurn, FAKE.turn + back, "return band = origin city to the city-state's city")
	H.len(Sent(0, "GRACE"), 0)
	H.turns(back)
	H.len(H.records(), 0)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" })
	H.ok(H.dist(home[1], S.c0) <= 5, "around the origin city")
	H.len(Sent(0, "RETURNED"), 1)
	H.clean()
end)

test("P4.4 return territory: an ally's tiles are not valid return land, but a CS unit there is recalled at expiry (0.7)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	H.ok(not EFV_ValidReturnTerritory(r, H.plot(22, 11)), "B's tile")
	H.ok(EFV_ValidReturnTerritory(r, H.plot(31, 20)), "the city-state's tile")
	H.ok(EFV_ValidReturnTerritory(r, H.plot(15, 20)), "the sender's tile")
	H.moveUnit(cu, 22, 11)                            -- inside ally B's borders
	EditRecord(r.id, function(x) x.deployedTurn = FAKE.turn - 9 end)
	H.endTurn()                                       -- E
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(cu), "removed from B's land")
	H.len(Sent(0, "GRACE"), 0); H.len(Sent(1, "GRACE"), 0, "the ally is not involved")
	H.ok(H.hasLine("cs=recall-anywhere"))
	H.clean()
end)

test("P4.3 no mutiny (0.7): a damaged CS unit on neutral land at expiry comes home with its damage", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	local p = H.neutralPlot(30, 5)
	H.moveUnit(cu, p:GetX(), p:GetY())
	cu.damage = 20
	EditRecord(r.id, function(x) x.deployedTurn = FAKE.turn - 9 end)
	H.endTurn()                                       -- E
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED"); H.eq(r.damage, 20)
	H.len(Sent(0, "GRACE"), 0); H.len(Sent(0, "MUTINY"), 0)
	H.turns(r.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.eq(home[1]:GetDamage(), 20, "damage kept")
	H.clean()
end)

-- ===========================================================================
-- Spec 11 rows for CS (WP5.1 brought forward)
-- ===========================================================================
test("CS spec 11: sender-CS war reverts the deployed unit to the sender in place (REVERTED)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	local x, y = cu:GetX(), cu:GetY()
	H.war(0, 4)                                       -- e.g. the city-state joined its suzerain's war
	H.endTurn()                                       -- reverted at the first boundary (DV16)
	H.len(H.records(), 0, "record closed")
	H.ok(not H.unitAlive(cu))
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), x); H.eq(mine[1]:GetY(), y)
	H.deq(H.promotionTypes(mine[1]), { "PROMOTION_BATTLECRY" })
	H.eq(mine[1]:GetOriginalOwner(), 0, "recreated for the sender")
	H.len(Sent(0, "REVERTED"), 1)
	H.ok(H.hasLine("[War] reverted id=" .. r.id))
	H.clean()
end)

test("CS spec 11: revert whose same-tile Create returns nil uses the next candidate (Session D 3)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	local x, y = cu:GetX(), cu:GetY()
	H.war(0, 4)
	FAKE.createNil = function(pid, px, py) return px == x and py == y end
	H.endTurn()
	H.len(H.records(), 0, "record closed")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1, "reverted, not sent on the return trip")
	H.ok(Map.GetPlotDistance(x, y, mine[1]:GetX(), mine[1]:GetY()) >= 1, "spawn search around the old tile (at-war owner plots excluded)")
	H.len(FAKE.createRefused, 1)
	H.len(Sent(0, "REVERTED"), 1)
	H.clean()
end)

test("CS spec 11: sender-CS war while OUTBOUND -> transit cancelled (WAR)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = MyUnit()
	local x, y = u:GetX(), u:GetY()
	H.send(0, u, 4, S.c4, CS, 999)
	H.war(0, 4)
	H.endTurn()
	H.len(H.records(), 0, "cancelled, no return trip")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), x); H.eq(mine[1]:GetY(), y)
	H.ok(H.hasLine("reason=WAR"))
	H.clean()
end)

test("CS spec 11: city-state eliminated -> transit cancelled (RECIPIENT_GONE), unit on its tile at once", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = MyUnit()
	local x, y = u:GetX(), u:GetY()
	H.send(0, u, 4, S.c4, CS, 999)
	H.kill(4)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1, "back at once")
	H.eq(mine[1]:GetX(), x); H.eq(mine[1]:GetY(), y)
	H.ok(H.hasLine("reason=RECIPIENT_GONE"))
	H.clean()
end)

test("CS spec 11: city-state eliminated with the unit deployed -> returned from the snapshot, not DISBANDED", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	cu.xp = 35                                        -- gained while serving; snapshotted at a boundary
	H.endTurn()
	H.eq(Only().experience, 35)
	for _, u in ipairs(H.unitsOf(4)) do H.killUnit(u) end   -- engine: units vanish with the last city
	H.kill(4)
	H.endTurn()
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECIPIENT_GONE")
	H.len(Sent(0, "UNIT_LOST"), 0, "not reported as disbanded")
	H.turns(r.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.eq(home[1].xp, 14); H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" }) -- Session F T08 + FLAG_XP_CLAMP: a restored unit is level 1, XP above the first threshold (15) is lost (clamped to 14)
	H.clean()
end)

test("CS spec 11: sender eliminated -> record deleted, the unit stays with the city-state", function()
	local S = H.baseScenario()
	H.loadEFV()
	local _, cu = SendAndArrive(S)
	H.kill(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.unitAlive(cu)); H.eq(cu:GetOwner(), 4)
	H.clean()
end)

test("CS: alliance/friendship changes do not affect a CS record (spec 11 row 3)", function()
	local S = H.baseScenario()
	H.loadEFV()
	SendAndArrive(S)
	H.ally(0, 1, false); H.friend(0, 2, false)
	H.turns(2)
	H.eq(Only().state, "DEPLOYED")
	H.clean()
end)

-- ===========================================================================
-- Suzerain levy
-- ===========================================================================
test("levy: the suzerain levies the city-state -> record follows the levied unit; levy end -> back", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	local x, y = cu:GetX(), cu:GetY()
	H.unit(4, "UNIT_WARRIOR", 31, 21)                  -- other type: never a candidate
	H.unit(4, "UNIT_SWORDSMAN", 30, 27)                -- same type, 7 hexes away: too far
	local levied = Levy(4, 2)                          -- F is suzerain and levies
	local mine = nil
	for _, u in ipairs(levied) do
		if u.x == x and u.y == y then mine = u end
	end
	H.notnil(mine)
	H.endTurn()
	r = Only()
	H.eq(r.state, "DEPLOYED", "not lost")
	H.eq(r.onMapPlayerID, 2); H.eq(r.onMapUnitID, mine.id)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.ok(H.hasLine("[Levy] relink id=" .. r.id))
	-- A levied tracked unit cannot be sent on by the suzerain (tracked + levy rule).
	H.contains(EFV_UnitSendReasons(mine, 2, EFV_Records.Load()), "ALREADY_TRACKED")
	-- The levy ends: the unit goes back to the city-state (the suzerain's copy
	-- becomes a stale object at -9999,-9999 until the next turn start, T28).
	local mx, my = mine.x, mine.y
	local back = EndLevy(4, 2)
	local home
	for _, u in ipairs(back) do
		if u.x == mx and u.y == my then home = u end
	end
	H.eq(mine.x, -9999, "the old object is off the map")
	H.endTurn()
	r = Only()
	H.eq(r.onMapPlayerID, 4); H.eq(r.onMapUnitID, home.id)
	-- The timer never stopped: expiry on the city-state's tiles returns it.
	EditRecord(r.id, function(x2) x2.deployedTurn = FAKE.turn - 9 end)
	H.endTurn()
	H.eq(Only().returnReason, "EXPIRED")
	H.clean()
end)

test("levy: expiry while levied recalls the unit from the suzerain at once, even on the suzerain's land (0.7)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = SendAndArrive(S)
	local levied = Levy(4, 1)
	H.endTurn()
	r = Only()
	H.eq(r.onMapPlayerID, 1)
	local lu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(lu)
	H.moveUnit(lu, 22, 11)                            -- the suzerain's own land (not valid return land)
	EditRecord(r.id, function(x) x.deployedTurn = FAKE.turn - 9 end)
	H.endTurn()
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(lu), "taken from the suzerain")
	H.len(Sent(0, "GRACE"), 0)
	H.ok(#levied >= 1)
	H.clean()
end)

test("levy: no candidate -> DISBANDED as before; a combat marker wins over a levied twin (KILLED)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = SendAndArrive(S)
	H.killUnit(cu)                                    -- gone, nothing levied
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(string.find(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED"), 1, true))
	-- Second record: it fought last turn, then its twin shows up with the suzerain.
	H.clearNotifs()
	r, cu = SendAndArrive(S)
	EditRecord(r.id, function(x) x.lastCombatTurn = FAKE.turn end)
	Levy(4, 2)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(string.find(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED"), 1, true))
	H.clean()
end)
