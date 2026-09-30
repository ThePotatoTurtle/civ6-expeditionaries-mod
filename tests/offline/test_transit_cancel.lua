-- @harness native
-- Transit cancel, sender and recipient eliminated in transit (designer
-- rulings 2026-09-30; FIXPLAN_transit_cancel.md section 5.1; DECISIONS
-- "Transit cancelled", "Sender eliminated with units in transit",
-- "Recipient eliminated with units in transit"; INTERFACES note 34).
-- Scenario (H.baseScenario): 0 human (capital (10,10), (14,20)), 1 ally B
-- ((22,10) capital, (18,13)), 2 friend F (40,30), 3 enemy C at war with 0, 1,
-- 2 and 4, 4 city-state (30,20). Default unit: a veteran Swordsman at (11,10);
-- an Expeditionary send to B's capital costs 36 (band 2), half = 18.

local N = function(name) return "EFV_NOTIF_" .. name end
local EXP, VOL, CS = "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"

local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end
local function Sent(pid, name) return H.notifs(pid, N(name)) end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] or "" end
local function Message(n) return n and n.data[ParameterTypes.MESSAGE] or "" end
local function Has(text, s) return string.find(text or "", s, 1, true) ~= nil end
local function Reason(status, civ) return Locale.Lookup("LOC_EFV_CANCEL_REASON_" .. status, EFV_PlayerName(civ)) end

local function Vet(x, y)
	return H.unit(0, "UNIT_SWORDSMAN", x or 11, y or 10,
		{ xp = 25, vet = "Brutus", promotions = { "PROMOTION_BATTLECRY" } })
end

-- Player pid's units of typeName standing on (x, y).
local function UnitsOn(pid, typeName, x, y)
	local out = {}
	for _, u in ipairs(H.unitsOf(pid, typeName)) do
		if u.x == x and u.y == y then out[#out + 1] = u end
	end
	return out
end

-- Engine elimination (Session D 4): the units vanish, then the player is dead.
local function Eliminate(pid)
	for _, u in ipairs(H.unitsOf(pid)) do H.killUnit(u) end
	H.kill(pid)
end

local function IDsOf(pid, typeName)
	local ids = {}
	for _, u in ipairs(H.unitsOf(pid, typeName)) do ids[u.id] = true end
	return ids
end

local function NewUnits(pid, typeName, before)
	local out = {}
	for _, u in ipairs(H.unitsOf(pid, typeName)) do
		if not before[u.id] then out[#out + 1] = u end
	end
	return out
end

-- Units of blockerID on every free plot within radius of (x, y): the spawn
-- search finds no valid tile there (UNITS rule), so no Create is tried.
local function Crowd(x, y, radius, blockerID)
	local out = {}
	for _, p in ipairs(Map.GetNeighborPlots(x, y, radius)) do
		if p:GetUnitCount() == 0 then out[#out + 1] = H.unit(blockerID, "UNIT_WARRIOR", p.x, p.y) end
	end
	return out
end

local function NoReroute()
	H.len(H.notifs(nil, N("REROUTED")), 0, "REROUTED is never sent")
end

-- ===========================================================================
-- (a) destination
-- ===========================================================================
test("a1 EXP: destination transferred -> cancelled at the next turn start, unit on its tile with promotions and name, refund 18", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.eq(H.gold(0), 964)
	local r = Only()
	H.eq(r.sentX, 11); H.eq(r.sentY, 10); H.eq(r.destNameKey, "LOC_CITY_B")
	H.ok(H.hasLine("from=11,10"), "[Send] ok names the origin tile")
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0, "record closed")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	local b = mine[1]
	H.eq(b:GetX(), 11); H.eq(b:GetY(), 10)
	H.deq(H.promotionTypes(b), { "PROMOTION_BATTLECRY" })
	H.eq(b:GetExperience():GetVeteranName(), "Brutus")
	H.eq(b:GetMovesRemaining(), 0, "0 moves after PlayerTurnStartComplete")
	H.eq(H.gold(0), 1000 - 36 + 18, "half the fee back; no upkeep on the cancel turn")
	local n = Sent(0, "RETURNED")
	H.len(n, 1)
	H.eq(Message(n[1]), "Transit Cancelled")
	H.ok(Has(Summary(n[1]), Reason("DEST_LOST", 1)), "reason text")
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REFUND", 18)), "refund text")
	H.ok(Has(Summary(n[1]), "LOC_CITY_B"), "names the destination")
	H.len(Sent(0, "RETURNING"), 0)
	H.len(H.notifs(1), 0, "an AI recipient gets nothing")
	NoReroute()
	H.ok(H.hasLine("[Cancel] id=1 force=EXPEDITIONARY"))
	H.ok(H.hasLine("reason=DEST_LOST code=OWNER hook=OnGameTurnStarted"))
	H.ok(H.hasLine("origin=11,10 (sent)"))
	H.ok(H.hasLine("ring=0 where=origin"))
	H.clean()
end)

test("a2: destination razed -> DEST_LOST NO_CITY; the text names the city from destNameKey", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.raze(S.c1)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=DEST_LOST code=NO_CITY"))
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), "LOC_CITY_B"), "razed city named from the stored key")
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

test("a3: captured and retaken between two checks -> destLost marker set at the event, cancelled CONQUERED", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	local c = CityManager.GetCityAt(22, 10)
	GameEvents.CityConquered(3, 1, c:GetID(), 22, 10)
	H.eq(Only().destLost, 1, "marker right after the event")
	H.eq(Only().state, "OUTBOUND", "no cancel inside the event")
	CityManager.TransferCity(c, 1, CityTransferTypes.BY_COMBAT)
	local c2 = CityManager.GetCityAt(22, 10)
	GameEvents.CityConquered(1, 3, c2:GetID(), 22, 10)
	H.eq(c2:GetOwner(), 1, "back with B")
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=DEST_LOST code=CONQUERED"))
	H.ok(H.hasLine("[Cancel] mark id=1 dest=22,10"))
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

test("a4: a human recipient gets ARRIVED _CANCELLED once, with the reason", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	CityManager.TransferCity(S.c1b, 3, CityTransferTypes.BY_COMBAT)   -- B keeps its capital
	H.endTurn()
	H.len(H.records(), 1, "other city lost: not the destination")
	H.ally(0, 1, false)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	local n = Sent(1, "ARRIVED")
	H.len(n, 1)
	H.eq(Message(n[1]), "Transit Cancelled")
	H.ok(Has(Summary(n[1]), EFV_PlayerName(0)), "names the sender")
	H.ok(Has(Summary(n[1]), Reason("NOT_PARTNER", 0)), "Q8: the recipient's notice gives the reason")
	H.len(Sent(0, "ARRIVED"), 0)
	H.len(Sent(0, "RETURNED"), 1)
	H.clean()
end)

test("a5 CS: the city-state's only city handed to C while it stays alive -> DEST_LOST", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 4, S.c4, CS, 999)
	local fee = Only().feePaid
	local g = H.gold(0)
	CityManager.TransferCity(S.c4, 3, CityTransferTypes.BY_GIFT)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=DEST_LOST code=OWNER"))
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.eq(H.gold(0), g + math.floor(fee / 2))
	H.clean()
end)

-- ===========================================================================
-- R3: recipient eliminated
-- ===========================================================================
test("b1 EXP: recipient eliminated -> RECIPIENT_GONE, origin tile, refund 18, no return trip, no recipient notice", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.kill(1)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.eq(H.gold(0), 982)
	H.ok(H.hasLine("reason=RECIPIENT_GONE"))
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), Reason("RECIPIENT_GONE", 1)))
	H.len(H.notifs(1), 0)
	H.ok(not H.hasLine("[Return] start"), "never RETURNING")
	H.ok(not H.hasLine("outbound -> return"))
	H.clean()
end)

test("b2: Volunteer to B and City-State unit to the city-state, both recipients eliminated -> both cancelled, each on its tile, two refunds", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, VOL, 999)
	H.send(0, Vet(10, 11), 4, S.c4, CS, 999)
	local fees = 0
	for _, r in ipairs(H.records()) do fees = fees + math.floor(r.feePaid / 2) end
	local g = H.gold(0)
	H.kill(1); H.kill(4)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 10, 11), 1)
	H.eq(#H.lines("reason=RECIPIENT_GONE"), 2)
	H.eq(H.gold(0), g + fees, "two refunds")
	H.clean()
end)

test("b3: the city-state's last city conquered (IsAlive already false inside the event) -> marker, cancelled RECIPIENT_GONE", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 4, S.c4, CS, 999)
	CityManager.TransferCity(S.c4, 3, CityTransferTypes.BY_COMBAT)
	H.kill(4)                                           -- T20: dead before CityConquered fires
	GameEvents.CityConquered(3, 4, CityManager.GetCityAt(30, 20):GetID(), 30, 20)
	H.eq(Only().destLost, 1)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=RECIPIENT_GONE"), "RECIPIENT_GONE precedes DEST_LOST")
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

-- ===========================================================================
-- (b) send conditions
-- ===========================================================================
test("c1 EXP: alliance ended -> NOT_PARTNER", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NOT_PARTNER code=NOT_PARTNER"))
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), Reason("NOT_PARTNER", 1)))
	H.clean()
end)

test("c2 EXP: the partner makes peace with the shared enemy -> NO_COMMON_WAR", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.peace(3, 1)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	H.clean()
end)

test("c3: EXP and VOL, war with the recipient -> WAR at the next turn start, never at an AI's boundary", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, EXP, 36)
	H.send(0, Vet(10, 11), 1, S.c1, VOL, 999)
	H.war(0, 1)
	local seen = {}
	H.endTurn({ act = function(p)
		for _, r in ipairs(H.records()) do seen[#seen + 1] = r.state end
	end })
	H.ok(#seen >= 2)
	for _, st in ipairs(seen) do H.eq(st, "OUTBOUND", "still in transit during the AI turns") end
	H.len(H.records(), 0)
	H.eq(#H.lines("reason=WAR code=AT_WAR_WITH_RECIPIENT hook=OnGameTurnStarted"), 2)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 10, 11), 1)
	H.clean()
end)

test("c4 VOL to a friend: open borders withdrawn -> NO_ACCESS", function()
	local S = H.baseScenario()
	H.openBorders(0, 2)
	H.loadEFV()
	H.send(0, Vet(), 2, S.c2, VOL, 999)
	H.eq(Only().state, "OUTBOUND")
	H.openBorders(0, 2, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NO_ACCESS code=VOL_NEEDS_ACCESS"))
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), Reason("NO_ACCESS", 2)))
	H.clean()
end)

test("c5 VOL to a friend: open borders reach their predicted expiry during the transit -> cancelled that turn (no grace)", function()
	local S = H.baseScenario({ turn = 40 })
	H.openBorders(0, 2, true, { enacted = 11, duration = 30 })   -- ends on turn 41
	H.loadEFV()
	H.send(0, Vet(), 2, S.c2, VOL, 999)
	local r = Only()
	H.ok(r.arrivalTurn > 41, "arrives after the expiry")
	H.endTurn()                                          -- turn 41
	H.len(H.records(), 0, "cancelled at the pipeline of the expiry turn")
	H.ok(H.hasLine("reason=NO_ACCESS"))
	H.clean()
end)

test("c6 (1.0.2 regression): peace with the enemy cancels the EXP to B (NO_COMMON_WAR) but not the City-State send", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, EXP, 36)
	H.send(0, Vet(10, 11), 4, S.c4, CS, 999)
	local csID = H.records()[2].id
	local arrival = Rec(csID).arrivalTurn
	H.peace(3, 0)
	H.endTurn()
	H.eq(#H.lines("[Cancel] id="), 1, "only the EXP")
	H.ok(H.hasLine("[Cancel] id=1 "))
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	H.eq(Rec(csID).state, "OUTBOUND")
	H.turns(arrival - FAKE.turn)
	H.eq(Rec(csID).state, "DEPLOYED", "the City-State unit arrives")
	H.clean()
end)

test("c7 CS: war with the city-state -> WAR", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 4, S.c4, CS, 999)
	H.war(0, 4)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=WAR"))
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

test("c8: unit-level conditions are not rechecked (origin tile now neutral, no gold) -> the unit arrives", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.own(11, 10, -1)
	H.setGold(0, 0)
	H.turns(2)
	H.eq(Only().state, "DEPLOYED")
	H.ok(not H.hasLine("[Cancel] id="))
	H.clean()
end)

-- ===========================================================================
-- Timing
-- ===========================================================================
test("d1: a lapse that is restored between two checks changes nothing", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local arrival = Only().arrivalTurn
	H.endTurn({ act = function(p)
		if p == 1 then H.ally(0, 1, false) end
		if p == 2 then H.ally(0, 1, true) end
	end })
	H.eq(Only().state, "OUTBOUND")
	H.turns(arrival - FAKE.turn)
	H.eq(Only().state, "DEPLOYED"); H.eq(Only().deployedTurn, arrival, "on schedule")
	H.ok(not H.hasLine("[Cancel] id="))
	H.clean()
end)

test("d2: the sender's own PlayerTurnStarted checks its transits; another player's does not", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.war(0, 1)
	GameEvents.PlayerTurnStarted(2)
	H.eq(Only().state, "OUTBOUND", "not at player 2's turn start")
	GameEvents.PlayerTurnStarted(0)
	H.len(H.records(), 0)
	H.ok(H.hasLine("hook=PlayerTurnStarted"))
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

test("d3: the arrival step checks once more before spawning (hook Arrival), never DEPLOYED", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local id = Only().id
	EditRecord(id, function(rec) rec.arrivalTurn = FAKE.turn end)
	H.war(0, 1)
	local s = EFV_Records.Load()
	EFV_Transit.ProcessArrivals(s, FAKE.turn)
	EFV_Records.Commit(s)
	EFV_Notify.Flush()
	H.isnil(Rec(id))
	H.ok(H.hasLine("hook=Arrival"))
	H.ok(not H.hasLine("[Arrival] id="), "never spawned for B")
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.clean()
end)

test("d4: an arrival that is blocked stays in transit and is still cancelled when the city is lost", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1b, EXP, 999)                -- band 1
	for _, p in ipairs(Map.GetNeighborPlots(S.c1b.x, S.c1b.y, 5)) do
		if not (p.x == S.c1b.x and p.y == S.c1b.y) and p:GetUnitCount() == 0 then H.unit(1, "UNIT_WARRIOR", p.x, p.y) end
	end
	H.endTurn()
	H.eq(Only().state, "OUTBOUND"); H.eq(Only().spawnFailCount, 1)
	H.len(Sent(0, "SPAWN_BLOCKED"), 1)
	CityManager.TransferCity(S.c1b, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0, "cancelled while waiting")
	H.ok(not H.hasLine("[Arrival] id="), "never DEPLOYED")
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.len(Sent(0, "SPAWN_BLOCKED"), 1, "the SPAWN_BLOCKED copy is left for the tracker sweep")
	H.clean()
end)

test("d5: a destination razed after the arrival does not touch the deployed unit", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.turns(2)
	H.eq(Only().state, "DEPLOYED")
	H.raze(S.c1)
	H.endTurn()
	H.eq(Only().state, "DEPLOYED")
	H.ok(not H.hasLine("[Cancel] id="))
	H.clean()
end)

-- ===========================================================================
-- Refund
-- ===========================================================================
test("e1: odd fee 37 -> refund 18 (rounded down)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	EditRecord(Only().id, function(rec) rec.feePaid = 37 end)
	H.kill(1)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("fee=37 refund=18"))
	H.eq(H.gold(0), 1000 - 36 + 18)
	H.clean()
end)

test("e2: a free send (band 1) refunds nothing and says so", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1b, EXP, 0)
	H.eq(Only().feePaid, 0)
	CityManager.TransferCity(S.c1b, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0)
	H.eq(H.gold(0), 1000)
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")))
	H.clean()
end)

test("e3: a legacy record without feePaid refunds 0 without an error", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	EditRecord(Only().id, function(rec) rec.feePaid = nil end)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.eq(H.gold(0), 964)
	H.ok(H.hasLine("fee=0 refund=0"))
	H.clean()
end)

test("e4: no free tile near the origin or home -> travels home (RETURNING CANCELLED), refundPaid set, one refund only, arrives once a tile frees", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local crowd = Crowd(10, 10, 6, 2)                    -- covers 5 rings around the origin and the capital
	H.war(0, 1)
	H.endTurn()
	local r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "CANCELLED"); H.eq(r.returnCityID, S.c0.id)
	H.eq(r.refundPaid, 18); H.eq(r.cancelReason, "WAR"); H.eq(r.cancelTurn, FAKE.turn)
	H.eq(H.gold(0), 1000 - 36 + 18 - 2, "refund, then upkeep as on any return trip")
	local n = Sent(0, "RETURNING")
	H.len(n, 1, "RETURNING _CANCELLED instead of the plain RETURNING")
	H.eq(Message(n[1]), "Transit Cancelled")
	H.ok(Has(Summary(n[1]), "no free tile"))
	H.ok(Has(Summary(n[1]), Reason("WAR", 1)))
	H.ok(H.hasLine("[Cancel] no free tile id=1"))
	H.endTurn()                                          -- blocked at the return arrival
	H.eq(Only().state, "RETURNING")
	H.len(Sent(0, "SPAWN_BLOCKED"), 1)
	for _, w in ipairs(crowd) do
		if Map.GetPlotDistance(10, 10, w.x, w.y) == 1 then H.killUnit(w); break end
	end
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "RETURNED"), 1, "an ordinary return arrival")
	H.eq(#H.lines("[Cancel] id=1 force="), 1, "cancelled once")
	H.eq(H.gold(0), 1000 - 36 + 18 - 2 - 2 - 2, "one refund; upkeep while travelling home")
	H.clean()
end)

test("e5: upkeep already paid is not refunded", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = Vet()
	H.send(0, u, 1, S.c1, EXP, 36)
	H.endTurn()                                          -- turn 2: upkeep 2
	H.eq(H.gold(0), 962)
	H.eq(Only().maintGoldPaid, 2)
	H.ally(0, 1, false)
	H.endTurn()                                          -- turn 3: cancelled before upkeep and arrival
	H.len(H.records(), 0)
	H.eq(H.gold(0), 1000 - 36 - 2 + 18)
	H.clean()
end)

-- ===========================================================================
-- Placement
-- ===========================================================================
test("f1: origin occupied -> ring 1, never the occupied tile; one synced RNG pick", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.unit(1, "UNIT_WARRIOR", 11, 10)
	FAKE.rngCalls = {}
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(Map.GetPlotDistance(11, 10, mine[1].x, mine[1].y), 1)
	local n = 0
	for _, c in ipairs(FAKE.rngCalls) do
		if c.label == "EFV spawn cxl1" then n = n + 1 end
	end
	H.eq(n, 1, "one GetRandNum call for the ring pick")
	H.ok(H.hasLine("ring=1 where=origin"))
	H.clean()
end)

test("f2: origin and all of ring 1 occupied -> ring 2", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.unit(0, "UNIT_WARRIOR", 11, 10)
	for _, p in ipairs(Map.GetNeighborPlots(11, 10, 1)) do
		if Map.GetPlotDistance(11, 10, p.x, p.y) == 1 and p:GetUnitCount() == 0 then
			H.unit(0, "UNIT_WARRIOR", p.x, p.y)
		end
	end
	H.ally(0, 1, false)
	H.endTurn()
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(Map.GetPlotDistance(11, 10, mine[1].x, mine[1].y), 2)
	H.clean()
end)

test("f3: sent from B's land, then war with B -> lands on the nearest tile that is not B's", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.eq(Map.GetPlot(20, 10):GetOwner(), 1)
	H.send(0, Vet(20, 10), 1, S.c1, EXP, 999)
	H.eq(Only().sentX, 20)
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.ne(Map.GetPlot(mine[1].x, mine[1].y):GetOwner(), 1, "never in enemy land")
	H.ok(Map.GetPlotDistance(20, 10, mine[1].x, mine[1].y) <= 5)
	H.clean()
end)

test("f4: sent from B's land, alliance ended, borders closed -> not on B's land, no refused Create", function()
	local S = H.baseScenario()
	H.loadEFV()
	FAKE.closedBorders = true
	H.send(0, Vet(20, 10), 1, S.c1, EXP, 999)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.ne(Map.GetPlot(mine[1].x, mine[1].y):GetOwner(), 1)
	H.ok(Map.GetPlotDistance(20, 10, mine[1].x, mine[1].y) <= 5)
	H.len(FAKE.createRefused, 0, "the ACCESS rule excluded B's land beforehand")
	H.clean()
end)

test("f5: nothing valid within 5 of the origin -> placed near the return city (where=home)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(20, 10), 1, S.c1, EXP, 999)
	FAKE.createNil = function(pid, x, y) return pid == 0 and Map.GetPlotDistance(x, y, 20, 10) <= 5 end
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.ok(Map.GetPlotDistance(S.c0.x, S.c0.y, mine[1].x, mine[1].y) <= 5, "around the return city")
	H.ok(H.hasLine("where=home"))
	H.clean()
end)

test("f6: sender alive without any city and the origin blocked -> UNIT_LOST (NO_CITY), refund still paid", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.raze(S.c0); H.raze(S.c0b)
	FAKE.createNil = function(pid) return pid == 0 end
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_NO_CITY")))
	H.eq(H.gold(0), 982)
	H.ok(H.hasLine("[Cancel] lost id=1 reason=NO_CITY"))
	H.clean()
end)

test("f7 naval: Galleys sent from coast tiles come back to them; an occupied one -> the next water tile, never land", function()
	local S = H.baseScenario()
	H.fill(0, 0, 83, 7, "OCEAN")
	H.own(10, 7, 0); H.own(14, 7, 0)
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_GALLEY", 10, 7), 1, S.c1, EXP, 999)
	H.send(0, H.unit(0, "UNIT_GALLEY", 14, 7), 1, S.c1, EXP, 999)
	H.len(H.records(), 2, "both sends accepted")
	local blocker = H.unit(0, "UNIT_GALLEY", 14, 7)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_GALLEY", 10, 7), 1, "back on its water tile")
	local others = {}
	for _, g in ipairs(H.unitsOf(0, "UNIT_GALLEY")) do
		if g.id ~= blocker.id and not (g.x == 10 and g.y == 7) then others[#others + 1] = g end
	end
	H.len(others, 1)
	H.eq(Map.GetPlotDistance(14, 7, others[1].x, others[1].y), 1)
	H.ok(Map.GetPlot(others[1].x, others[1].y):IsWater(), "never on land")
	H.clean()
end)

test("f8 naval: a Galley sent from inside the capital lands on the nearest valid water tile", function()
	local S = H.baseScenario()
	H.fill(0, 0, 83, 8, "OCEAN")
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_GALLEY", 10, 10), 1, S.c1, EXP, 999)
	H.len(H.records(), 1, "send accepted")
	H.eq(Only().sentX, 10); H.eq(Only().sentY, 10)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	local g = H.unitsOf(0, "UNIT_GALLEY")
	H.len(g, 1)
	H.ok(Map.GetPlot(g[1].x, g[1].y):IsWater())
	H.eq(Map.GetPlotDistance(10, 10, g[1].x, g[1].y), 2, "nearest water ring")
	H.clean()
end)

test("f9: two units to the same city from different tiles -> each on its own tile, ascending id order, two refunds", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, EXP, 36)
	H.send(0, Vet(10, 11), 1, S.c1, EXP, 999)
	local refunds = 0
	for _, r in ipairs(H.records()) do refunds = refunds + math.floor(r.feePaid / 2) end
	H.eq(refunds, 36, "fees are city to city: 36 each")
	local g = H.gold(0)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 10, 11), 1)
	local lines = H.lines("[Cancel] id=")
	H.len(lines, 2)
	H.ok(Has(lines[1], "[Cancel] id=1 ")); H.ok(Has(lines[2], "[Cancel] id=2 "))
	H.eq(H.gold(0), g + refunds, "two refunds")
	H.clean()
end)

test("f10: two units sent from the same tile in one turn -> the first gets the tile, the second ring 1", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, EXP, 36)
	H.send(0, Vet(11, 10), 1, S.c1, EXP, 36)
	H.len(H.records(), 2)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 2)
	H.ok(H.hasLine("placed id=1 ") and H.hasLine("ring=0 where=origin"))
	H.ok(H.hasLine("ring=1 where=origin"))
	H.clean()
end)

test("f11: veteran restore as on any return: route B job for a human sender; classic path sets promotions, XP clamped", function()
	local S = H.baseScenario()
	H.loadEFV({ routeB = true })
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.ally(0, 1, false)
	H.endTurn()
	local u = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	H.notnil(u)
	local found = false
	for _, j in ipairs(EFV_Records.Load().vet or {}) do
		if j.p == 0 and j.u == u.id then found = true end
	end
	H.ok(found, "a route B job for (0, new unit)")
	H.clean()
end)

test("f11b: classic restore (route B off): promotions set, XP clamped", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.ally(0, 1, false)
	H.endTurn()
	local u = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	H.deq(H.promotionTypes(u), { "PROMOTION_BATTLECRY" })
	H.eq(u:GetExperience():GetExperiencePoints(), 14, "XP clamped (Session F T08)")
	H.clean()
end)

-- ===========================================================================
-- Save compatibility and persistence
-- ===========================================================================
test("g1: a legacy OUTBOUND record (no sentX / sentY) uses lastX / lastY, the send tile", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	EditRecord(Only().id, function(rec) rec.sentX = nil; rec.sentY = nil; rec.destNameKey = nil end)
	H.eq(Only().lastX, 11); H.eq(Only().lastY, 10)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.ok(H.hasLine("origin=11,10 (legacy)"))
	H.clean()
end)

test("g2: a legacy record without any tile -> placed near the return city", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	EditRecord(Only().id, function(rec) rec.sentX = nil; rec.sentY = nil; rec.lastX = nil; rec.lastY = nil end)
	H.ally(0, 1, false)
	H.endTurn()
	H.len(H.records(), 0)
	local u = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	H.ok(Map.GetPlotDistance(S.c0.x, S.c0.y, u.x, u.y) <= 5)
	H.ok(H.hasLine("(none)")); H.ok(H.hasLine("where=home"))
	H.clean()
end)

test("g3: save and load in transit, then the break -> cancelled; sentX / sentY / destNameKey survive the property round trip", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	H.reloadEFV()
	H.markBody()
	local r = Only()
	H.eq(r.sentX, 11); H.eq(r.sentY, 10); H.eq(r.destNameKey, "LOC_CITY_B")
	H.raze(S.c1)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(UnitsOn(0, "UNIT_SWORDSMAN", 11, 10), 1)
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), "LOC_CITY_B"))
	H.clean()
end)

test("g4: a legacy RETURNING record (returnReason DEST_LOST) still arrives home normally", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	EditRecord(Only().id, function(rec)
		rec.state = "RETURNING"; rec.returnReason = "DEST_LOST"; rec.arrivalTurn = FAKE.turn + 1
		rec.returnCityID = S.c0.id; rec.returnX = S.c0.x; rec.returnY = S.c0.y
	end)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "RETURNED"), 1)
	H.ok(not H.hasLine("[Cancel] id="))
	H.clean()
end)

-- ===========================================================================
-- R2: sender eliminated
-- ===========================================================================
test("h1 EXP: sender eliminated in transit -> kept, no upkeep, arrives as B's own unit with its promotions, record closed, _KEPT to B", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local id = Only().id
	local before = IDsOf(1, "UNIT_SWORDSMAN")
	H.clearNotifs()
	Eliminate(0)
	H.endTurn()
	H.eq(Rec(id).state, "OUTBOUND"); H.eq(Rec(id).senderGoneTurn, FAKE.turn)
	H.eq(H.gold(0), 964, "no upkeep for a dead sender")
	H.ok(H.hasLine("arrives as the recipient's own unit"))
	H.endTurn()                                          -- turn 3: arrival
	H.isnil(Rec(id), "record deleted once the unit spawned")
	local got = NewUnits(1, "UNIT_SWORDSMAN", before)
	H.len(got, 1)
	H.ok(Map.GetPlotDistance(S.c1.x, S.c1.y, got[1].x, got[1].y) <= 5)
	H.deq(H.promotionTypes(got[1]), { "PROMOTION_BATTLECRY" })
	local n = Sent(1, "ARRIVED")
	H.len(n, 1)
	H.eq(Message(n[1]), "Unit Joined Your Forces")
	H.ok(Has(Summary(n[1]), "now yours to keep"))
	H.len(H.notifs(0), 0, "nothing to the dead sender")
	H.ok(not H.hasLine("[Cancel] id="))
	H.eq(H.gold(0), 964, "no refund")
	H.clean()
end)

test("h2 CS: sender eliminated -> the City-State unit arrives for the city-state, record deleted", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 4, S.c4, CS, 999)
	local r = Only()
	Eliminate(0)
	H.turns(r.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	local got = H.unitsOf(4, "UNIT_SWORDSMAN")
	H.len(got, 1)
	H.ok(Map.GetPlotDistance(S.c4.x, S.c4.y, got[1].x, got[1].y) <= 5)
	H.clean()
end)

test("h3: sender eliminated -> an outbound Volunteer and a returning EXP are deleted, nothing spawns", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(11, 10), 1, S.c1, VOL, 999)
	H.send(0, Vet(10, 11), 1, S.c1, EXP, 999)
	local ids = {}
	for _, r in ipairs(H.records()) do ids[#ids + 1] = r.id end
	EditRecord(ids[2], function(rec)
		rec.state = "RETURNING"; rec.returnReason = "EXPIRED"; rec.arrivalTurn = FAKE.turn + 1
		rec.returnCityID = S.c0.id; rec.returnX = S.c0.x; rec.returnY = S.c0.y
	end)
	local b = #H.unitsOf(1)
	Eliminate(0)
	H.turns(3)
	H.len(H.records(), 0)
	H.len(H.unitsOf(0), 0)
	H.eq(#H.unitsOf(1), b)
	H.clean()
end)

test("h4: orphan whose recipient is eliminated too -> deleted, nothing spawned", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	Eliminate(0)
	H.endTurn()
	H.len(H.records(), 1)
	Eliminate(1)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(H.unitsOf(1), 0)
	H.clean()
end)

test("h5: orphan whose destination changed hands -> delivered to the host's nearest other city (Q4)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local before = IDsOf(1, "UNIT_SWORDSMAN")
	Eliminate(0)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.turns(2)
	H.len(H.records(), 0)
	local got = NewUnits(1, "UNIT_SWORDSMAN", before)
	H.len(got, 1)
	H.ok(Map.GetPlotDistance(S.c1b.x, S.c1b.y, got[1].x, got[1].y) <= 5, "around B's other city")
	H.ok(H.hasLine("the recipient's nearest city"))
	H.clean()
end)

test("h5b: orphan whose host has no city left -> lost", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	Eliminate(0)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	CityManager.TransferCity(S.c1b, 3, CityTransferTypes.BY_COMBAT)
	H.turns(2)
	H.len(H.records(), 0)
	H.len(H.unitsOf(1, "UNIT_SWORDSMAN"), 0)
	H.ok(H.hasLine("has no city -> lost"))
	H.clean()
end)

test("h6: orphan arrival blocked -> no SPAWN_BLOCKED, retried, arrives when a tile frees", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	Eliminate(0)
	local crowd = Crowd(S.c1.x, S.c1.y, 5, 2)
	H.turns(2)
	H.eq(Only().state, "OUTBOUND"); H.eq(Only().spawnFailCount, 1)
	H.len(H.notifs(nil, N("SPAWN_BLOCKED")), 0)
	for _, w in ipairs(crowd) do
		if Map.GetPlotDistance(S.c1.x, S.c1.y, w.x, w.y) == 1 then H.killUnit(w); break end
	end
	H.endTurn()
	H.len(H.records(), 0)
	H.len(H.unitsOf(1, "UNIT_SWORDSMAN"), 1)
	H.clean()
end)

test("h7: orphan veteran to a human host with route B -> the job belongs to the host", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV({ routeB = true })
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	Eliminate(0)
	H.turns(2)
	H.len(H.records(), 0)
	local u = H.unitsOf(1, "UNIT_SWORDSMAN")[1]
	H.notnil(u)
	local owner = nil
	for _, j in ipairs(EFV_Records.Load().vet or {}) do
		if j.u == u.id then owner = j.p end
	end
	H.eq(owner, 1)
	H.clean()
end)

-- ===========================================================================
-- Texts and MP rules
-- ===========================================================================
test("i1: every cancel text renders with its arguments; no 'EFV', no en or em dash", function()
	H.baseScenario()
	H.loadEFV()
	local texts = {}
	for _, st in ipairs({ "RECIPIENT_GONE", "DEST_LOST", "WAR", "NOT_PARTNER", "NO_ACCESS", "NO_ACCESS_HOST",
			"NO_COMMON_WAR", "NOT_ELIGIBLE", "NOT_ELIGIBLE_HOST" }) do
		texts[#texts + 1] = Locale.Lookup("LOC_EFV_CANCEL_REASON_" .. st, "Rome")
	end
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_CANCEL_REFUND", 18)
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_CANCEL_DEST_GENERIC")
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_CONFIRM_SEND_CANCEL", "Rome")
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_CONFIRM_SEND_CANCEL_FREE", "Rome")
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_NOTIF_RETURNED_CANCELLED_SUMMARY", "u", "c", "r", "f")
	local returning = Locale.Lookup("LOC_EFV_NOTIF_RETURNING_CANCELLED_SUMMARY", "u", "c", "r", "h", 2, "f")
	texts[#texts + 1] = returning
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_NOTIF_ARRIVED_CANCELLED_SUMMARY", "u", "s", "c", "r")
	texts[#texts + 1] = Locale.Lookup("LOC_EFV_NOTIF_ARRIVED_KEPT_SUMMARY", "u", "s", "c")
	for _, k in ipairs({ "RETURNED_CANCELLED", "RETURNING_CANCELLED", "ARRIVED_CANCELLED", "ARRIVED_KEPT" }) do
		texts[#texts + 1] = Locale.Lookup("LOC_EFV_NOTIF_" .. k .. "_MESSAGE")
	end
	H.len(FAKE.textArgErrors, 0)
	for _, t in ipairs(texts) do
		H.ok(not Has(t, "LOC_EFV"), "defined: " .. t)
		H.ok(not Has(t, "{"), "all placeholders filled: " .. t)
		H.ok(string.find(t, "%f[%w]EFV%f[%W]") == nil, "says VEF, never EFV: " .. t)
		H.ok(not Has(t, "\226\128\147") and not Has(t, "\226\128\148"), "no en or em dash: " .. t)
	end
	H.ok(Has(returning, "2 turns"), "plural form")
end)

test("i2: Reroute and ConvertToReturn are gone; REROUTED is never queued", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.isnil(EFV_Transit.Reroute)
	H.isnil(EFV_Transit.ConvertToReturn)
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.turns(3)
	NoReroute()
	H.clean()
end)

test("j1: no async Events subscription for the transit cancel; the marker is written inside GameEvents.CityConquered", function()
	local S = H.baseScenario()
	H.loadEFV()
	for _, name in ipairs({ "CityTransferred", "CityOccupationChanged", "CityRemovedFromMap", "CityAddedToMap",
			"DiplomacyDeclareWar", "DiplomacyMakePeace", "DiplomacyRelationshipChanged", "PlayerDestroyed" }) do
		local ev = rawget(Events, name)
		H.ok(ev == nil or #ev.handlers == 0, "no handler on Events." .. name)
	end
	H.send(0, Vet(), 1, S.c1, EXP, 36)
	local rev = H.prop(EFV_Config.PROP.REV)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.eq(H.prop(EFV_Config.PROP.REV), rev, "a transfer alone writes nothing")
	GameEvents.CityConquered(3, 1, CityManager.GetCityAt(22, 10):GetID(), 22, 10)
	H.ok(H.prop(EFV_Config.PROP.REV) > rev, "store written inside the synchronous event")
	H.eq(Only().destLost, 1)
	H.clean()
end)
