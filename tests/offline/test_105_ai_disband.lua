-- @harness native
-- 1.0.5 AI disband fix (FIXPLAN_proxy_war.md "AI disband fix (1.0.5)",
-- AD3 / AD5 step 6; DECISIONS "AI disband fix: the DQ answers",
-- 2026-10-25). An Expeditionary or City-State unit that its AI or
-- city-state holder disbands (step 0c class DISBANDED) comes home by the
-- normal trip from its last snapshot (RETURNING "DISBANDED"), with half the
-- fee back when it was disbanded in the round it arrived. A human holder's
-- disband, a combat death, an absorption and a possible upgraded or levied
-- copy near the last position keep the 1.0.4 loss. Volunteers unchanged.
-- Kill switch FLAG_DISBAND_RETURN.
-- Scenario (H.baseScenario): 0 human (cities (10,10) capital, (14,20)),
-- 1 = B ally AI (capital (22,10): band 2, Swordsman fee 18, half = 9;
-- (18,13)), 2 friend F, 3 enemy C, 4 city-state (30,20).

local N = function(name) return "EFV_NOTIF_" .. name end
local VOL, CS = "VOLUNTEER", "CS_EXPEDITIONARY"
local EM, EN = "\226\128\148", "\226\128\147"

local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end
local function Sent(pid, name) return H.notifs(pid, N(name)) end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] or "" end
local function Has(text, s) return text ~= nil and s ~= nil and string.find(text, s, 1, true) ~= nil end

local function MyUnit(x, y)
	return H.unit(0, "UNIT_SWORDSMAN", x or 11, y or 10, { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 })
end

-- Sends a unit of player 0 and plays until it arrives (the human's turn of
-- the arrival round). Returns the record and the on-map unit.
local function Deploy(S, forceType, recipient, city, unit)
	recipient = recipient or 1
	local u = unit or MyUnit()
	H.send(0, u, recipient, city or S.c1, forceType or "EXPEDITIONARY", 999)
	local r = H.records()[#H.records()]
	H.notnil(r, "send accepted")
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Rec(r.id)
	H.eq(r.state, "DEPLOYED")
	H.eq(r.deployedTurn, FAKE.turn)
	return r, FAKE.units[r.onMapUnitID]
end

-- The AI deletes the unit (no combat, no merge).
local function Disband(u) FAKE.RemoveUnit(u, "DISBAND") end

-- A free land plot at exactly distance d from (x, y) with no units.
local function FreeAt(x, y, d, skip)
	for _, p in ipairs(Map.GetNeighborPlots(x, y, d)) do
		if Map.GetPlotDistance(x, y, p.x, p.y) == d and not p:IsWater() and not p:IsImpassable()
			and p:GetUnitCount() == 0 and not p:IsCity() and not (skip and skip(p)) then
			return p
		end
	end
	error("no free plot at distance " .. d)
end

local function DisbandedText(rec, holder, refundText)
	local band = rec.transitTurns
	local pCity = CityManager.GetCityAt(rec.returnX, rec.returnY)
	return Locale.Lookup("LOC_EFV_NOTIF_RETURNING_DISBANDED_SUMMARY",
		EFV_UnitDisplayName(rec.unitType, rec.veteranName), EFV_CityName(pCity), band,
		EFV_PlayerName(holder), refundText or "")
end

-- ===========================================================================
-- d1-d3: the arrival-round refund, later disbands, free sends
-- ===========================================================================
test("d1: disbanded by the AI host in its arrival round -> home by the normal trip, half the fee back once", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	H.eq(r.feePaid, 18)
	Disband(u)
	H.clearNotifs()
	local g0, m0 = H.gold(0), r.maintGoldPaid or 0
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.eq(rr.disbandTurn, FAKE.turn); H.eq(rr.disbandBy, 1); H.eq(rr.disbandRefund, 9)
	H.eq(H.gold(0), g0 + 9 - ((rr.maintGoldPaid or 0) - m0), "refund 9, minus any upkeep paid this turn")
	H.len(Sent(0, "UNIT_LOST"), 0)
	local ret = Sent(0, "RETURNING")
	H.len(ret, 1)
	H.eq(Summary(ret[1]), DisbandedText(rr, 1, Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9)))
	H.ok(Has(Summary(ret[1]), EFV_PlayerName(1)), "names B")
	H.eq(ret[1].data[ParameterTypes.MESSAGE], Locale.Lookup("LOC_EFV_NOTIF_RETURNING_DISBANDED_MESSAGE"))
	H.ok(H.hasLine("class=DISBANDED"))
	H.ok(H.hasLine("[Disband] home id=" .. r.id .. " force=EXPEDITIONARY holder=1"))
	H.ok(H.hasLine("refund=9"))
	H.ok(H.hasLine("[Return] start id=" .. r.id .. " reason=DISBANDED"))
	local snapXP = rr.experience
	local m1 = rr.maintGoldPaid or 0
	-- The trip home: upkeep is charged on the way, no second refund.
	local g1 = H.gold(0)
	H.turns(rr.arrivalTurn - FAKE.turn - 1)
	if rr.transitTurns > 1 then
		H.ok((Rec(rr.id).maintGoldPaid or 0) > m1, "upkeep charged while RETURNING")
	end
	H.endTurn()
	H.len(H.records(), 0, "RETURNED")
	H.ok(H.hasLine("[Return] arrived id=" .. r.id .. " reason=DISBANDED"))
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" })
	H.eq(home[1].xp, snapXP)
	H.len(Sent(0, "RETURNED"), 1)
	H.ok(Has(Summary(Sent(0, "RETURNED")[1]), EFV_UnitDisplayName(rr.unitType, rr.veteranName)))
	H.ok(H.gold(0) <= g1, "no second refund")
	H.len(H.lines("[Disband] home"), 1)
	H.clean()
end)

test("d2: disbanded a turn after its arrival round -> home, no refund, no refund sentence", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	H.endTurn()
	Disband(u)
	H.clearNotifs()
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.isnil(rr.disbandRefund)
	H.ok(H.hasLine("refund=nil"))
	local s = Summary(Sent(0, "RETURNING")[1])
	H.eq(s, DisbandedText(rr, 1, ""))
	H.ok(not Has(s, Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9)))
	H.ok(not Has(s, Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")))
	H.clean()
end)

test("d3: a free (band 1) send disbanded on arrival -> home, the free-send sentence, gold unchanged by a refund", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S, nil, 1, S.c1b)
	H.eq(r.feePaid, 0, "band 1 is free")
	Disband(u)
	H.clearNotifs()
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.disbandRefund, 0)
	H.eq(Summary(Sent(0, "RETURNING")[1]), DisbandedText(rr, 1, Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")))
	H.clean()
end)

-- ===========================================================================
-- d4-d9: what keeps the 1.0.4 result
-- ===========================================================================
test("d4: a human host's disband -> UNIT_LOST 'It was disbanded.', no record, no refund (1.0.4)", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S)
	Disband(u)
	H.clearNotifs()
	local g0 = H.gold(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED")))
	H.eq(Locale.Lookup("LOC_EFV_LOSS_DISBANDED"), "It was disbanded.")
	H.len(Sent(0, "RETURNING"), 0)
	H.eq(H.gold(0), g0)
	H.ok(not H.hasLine("[Disband]"))
	H.clean()
end)

test("d5: a city-state host disbands a City-State unit in its arrival round -> home, half the fee back", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S, CS, 4, S.c4)
	local fee = r.feePaid
	Disband(u)
	H.clearNotifs()
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED"); H.eq(rr.disbandBy, 4)
	H.eq(rr.disbandRefund, math.floor(fee * 50 / 100))
	local refundText = (fee > 0) and Locale.Lookup("LOC_EFV_CANCEL_REFUND", rr.disbandRefund)
		or Locale.Lookup("LOC_EFV_CANCEL_REFUND_FREE")
	H.eq(Summary(Sent(0, "RETURNING")[1]), DisbandedText(rr, 4, refundText))
	H.ok(H.hasLine("force=CS_EXPEDITIONARY holder=4"))
	H.clean()
end)

test("d6: the sender's own Volunteer disbanded -> record closed silently (unchanged)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S, VOL)
	Disband(u)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "RETURNING"), 0); H.len(Sent(0, "UNIT_LOST"), 0)
	H.ok(not H.hasLine("[Disband]"))
	H.clean()
end)

test("d7: FLAG_DISBAND_RETURN = false -> 1.0.4 exactly (lost, no refund, no new text)", function()
	local S = H.baseScenario()
	H.loadEFV({ flags = { FLAG_DISBAND_RETURN = false } })
	local r, u = Deploy(S)
	Disband(u)
	H.clearNotifs()
	local g0 = H.gold(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED")))
	H.len(Sent(0, "RETURNING"), 0)
	H.eq(H.gold(0), g0)
	H.ok(not H.hasLine("[Disband]")); H.ok(not H.hasLine("-> home"))
	H.clean()
end)

test("d8: a combat marker wins -> KILLED, lost", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	GameEvents.OnCombatOccurred(3, 999, 1, u.id, 0, 0)
	H.killUnit(u)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	H.ok(not H.hasLine("[Disband]"))
	H.clean()
end)

test("d9: absorbed into the host's Corps within the radius -> MERGED _ABSORBED, not home", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = FreeAt(u:GetX(), u:GetY(), 2)
	H.unit(1, "UNIT_SWORDSMAN", p.x, p.y, { formation = MilitaryFormationTypes.CORPS_FORMATION })
	FAKE.RemoveUnit(u, "MERGE")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "MERGED"), 1); H.len(Sent(0, "RETURNING"), 0)
	H.ok(H.hasLine("[Merge] absorbed id=" .. r.id))
	H.clean()
end)

-- ===========================================================================
-- d10-d12: the fail-safe guard (possible successors) and levied units
-- ===========================================================================
test("d10a: guard: the host's untracked Man-at-Arms with BATTLECRY 1 tile away -> lost (fail safe)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = FreeAt(u.x, u.y, 1)
	Disband(u)
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", p.x, p.y, { promotions = { "PROMOTION_BATTLECRY" } })
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED")))
	H.ok(H.hasLine("[Disband] possible successor id=" .. r.id .. " n=1 -> lost (fail safe)"))
	H.ok(H.unitAlive(other)); H.eq(other:GetOwner(), 1)
	H.clean()
end)

test("d10b: guard: the same Man-at-Arms without BATTLECRY is no successor -> home", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = FreeAt(u.x, u.y, 1)
	Disband(u)
	H.unit(1, "UNIT_MAN_AT_ARMS", p.x, p.y)
	H.endTurn()
	H.eq(Only().returnReason, "DISBANDED")
	H.ok(not H.hasLine("possible successor"))
	H.clean()
end)

test("d10c: guard: two upgrade-type units on the snapshot plot -> [Upgrade] ambiguous, lost", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local x, y = u.x, u.y
	FAKE.RemoveUnit(u, "UPGRADE")
	H.unit(1, "UNIT_MAN_AT_ARMS", x, y, { promotions = { "PROMOTION_BATTLECRY" } })
	H.unit(1, "UNIT_MAN_AT_ARMS", x, y, { promotions = { "PROMOTION_BATTLECRY" } })
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("[Upgrade] ambiguous id=" .. r.id .. " candidates=2"))
	H.ok(H.hasLine("[Disband] possible successor id=" .. r.id .. " n=2"))
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.clean()
end)

-- A CS record whose unit and a native twin (same XP, damage and promotions)
-- are both levied next to its last position: two exact candidates, no relink.
local function AmbiguousLevy(S, suzerain)
	local r, cu = Deploy(S, CS, 4, S.c4)
	local x, y = cu.x, cu.y
	local a = FreeAt(x, y, 1)
	local b = FreeAt(x, y, 1, function(p) return p == a end)
	H.unit(4, "UNIT_SWORDSMAN", b.x, b.y, { xp = cu.xp, damage = cu.damage, promotions = { "PROMOTION_BATTLECRY" } })
	Players[4].suzerain = suzerain
	local copies = H.levy(4, suzerain, 4, function(u)
		if u == cu then return a.x, a.y end
		return u.x, u.y
	end)
	H.len(copies, 2)
	return r, copies
end

test("d11a: guard: an ambiguous levy to AI suzerain 2 -> lost (fail safe)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = AmbiguousLevy(S, 2)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1); H.len(Sent(0, "RETURNING"), 0)
	H.ok(H.hasLine("[Levy] ambiguous id=" .. r.id))
	H.ok(H.hasLine("[Disband] possible successor id=" .. r.id))
	H.clean()
end)

test("d11b: guard: the same levy to the human sender as suzerain -> lost, so no duplicate", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, copies = AmbiguousLevy(S, 0)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1); H.len(Sent(0, "RETURNING"), 0)
	H.ok(H.hasLine("[Disband] possible successor id=" .. r.id))
	for _, c in ipairs(copies) do H.eq(c:GetOwner(), 0, "the levied copies stay where the levy put them") end
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 2, "no third Swordsman")
	H.clean()
end)

test("d12: a levied City-State unit held by AI suzerain 2 and disbanded -> home, the text names player 2", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, cu = Deploy(S, CS, 4, S.c4)
	Players[4].suzerain = 2
	H.levy(4, 2, 4)
	H.endTurn()
	local rr = Only()
	H.eq(rr.onMapPlayerID, 2, "relinked to the levied copy")
	Disband(Players[2]:GetUnits():FindID(rr.onMapUnitID))
	H.clearNotifs()
	H.endTurn()
	rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED"); H.eq(rr.disbandBy, 2)
	H.isnil(rr.disbandRefund, "not the arrival round")
	H.eq(Summary(Sent(0, "RETURNING")[1]), DisbandedText(rr, 2, ""))
	H.clean()
end)

-- ===========================================================================
-- d13-d19: other states, ordering, resume, save and load
-- ===========================================================================
test("d13: an expired GRACE record disbanded -> home with its damage, no refund", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	u.damage = 30
	EditRecord(r.id, function(x) x.deployedTurn = FAKE.turn - 20 end)
	H.endTurn()
	H.eq(Rec(r.id).state, "GRACE")
	H.endTurn()                                        -- a boundary snapshot of the damage
	H.eq(Rec(r.id).damage, 30)
	Disband(u)
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.isnil(rr.disbandRefund)
	H.eq(rr.damage, 30)
	H.turns(rr.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1); H.eq(home[1]:GetDamage(), 30)
	H.clean()
end)

test("d14: sender-host war with the unit already gone -> left for step 0c -> home with the _DISBANDED text", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	Disband(u)
	H.war(0, 1)
	H.clearNotifs()
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.ok(H.hasLine("left for step 0c"))
	H.eq(Summary(Sent(0, "RETURNING")[1]), DisbandedText(rr, 1, Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9)))
	H.clean()
end)

test("d15: the slot reused by a new unit of B -> the snapshot comes home; B's new unit is untouched", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	H.killUnit(u)
	local nu = H.unitInSlot(u, 1, "UNIT_SWORDSMAN", u.x, u.y)
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.ok(H.unitAlive(nu)); H.eq(nu:GetOwner(), 1); H.eq(nu:GetDamage(), 0)
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, nu.id))
	H.turns(rr.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	H.ok(H.unitAlive(nu)); H.eq(nu:GetOwner(), 1)
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1)
	H.clean()
end)

test("d16: StartReturn fails once after the refund -> the next turn goes home with no second refund", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	Disband(u)
	local real = EFV_Transit.StartReturn
	local calls = 0
	EFV_Transit.StartReturn = function(...)
		calls = calls + 1
		if calls == 1 then error("injected") end
		return real(...)
	end
	local g0 = H.gold(0)
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "DEPLOYED", "the failed turn leaves the record")
	H.eq(rr.disbandRefund, 9)
	H.eq(H.gold(0), g0 + 9 - ((rr.maintGoldPaid or 0) - (r.maintGoldPaid or 0)))
	H.len(H.errorLines(), 1, "the injected error only")
	H.markBody()
	H.clearNotifs()
	local g1, m1 = H.gold(0), rr.maintGoldPaid or 0
	H.endTurn()
	rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.eq(H.gold(0), g1 - ((rr.maintGoldPaid or 0) - m1), "no second refund")
	H.eq(Summary(Sent(0, "RETURNING")[1]), DisbandedText(rr, 1, Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9)))
	EFV_Transit.StartReturn = real
	H.clean()
end)

test("d17: save and load between the disband and the arrival home -> it still arrives", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	Disband(u)
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "RETURNING")
	H.reloadEFV()
	H.markBody()
	H.turns(rr.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	H.ok(H.hasLine("[Return] arrived id=" .. r.id .. " reason=DISBANDED"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1)
	H.clean()
end)

test("d18: no return city -> UNIT_LOST NO_CITY, the refund paid once", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	Disband(u)
	H.raze(S.c0); H.raze(S.c0b)
	H.clearNotifs()
	local g0 = H.gold(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_NO_CITY")))
	H.eq(H.gold(0), g0 + 9)
	H.endTurn()
	H.eq(H.gold(0), g0 + 9, "paid once")
	H.clean()
end)

test("d19: two records disbanded in one turn -> both home, in ID order", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r1, u1 = Deploy(S)
	local r2, u2 = Deploy(S, nil, 1, S.c1, MyUnit(12, 10))
	Disband(u1); Disband(u2)
	H.endTurn()
	local recs = H.records()
	H.len(recs, 2)
	for _, x in ipairs(recs) do
		H.eq(x.state, "RETURNING"); H.eq(x.returnReason, "DISBANDED")
	end
	local lines = H.lines("[Disband] home")
	H.len(lines, 2)
	H.ok(Has(lines[1], "id=" .. r1.id .. " ")); H.ok(Has(lines[2], "id=" .. r2.id .. " "))
	H.ok(r1.id < r2.id)
	H.clean()
end)

-- ===========================================================================
-- d20: text
-- ===========================================================================
test("d20: the _DISBANDED text renders plainly: no keys, no braces, no dashes, plural turns, VEF never EFV", function()
	local S = H.baseScenario()
	H.loadEFV()
	for _, key in ipairs({ "LOC_EFV_NOTIF_RETURNING_DISBANDED_MESSAGE", "LOC_EFV_NOTIF_RETURNING_DISBANDED_SUMMARY" }) do
		local t = FAKE_TEXT[key]
		H.notnil(t, key)
		H.ok(not Has(t, EM) and not Has(t, EN), "no em or en dash: " .. key)
		H.ok(not Has(t, "EFV"), "no EFV: " .. key)
	end
	local one = Locale.Lookup("LOC_EFV_NOTIF_RETURNING_DISBANDED_SUMMARY", "Swordsman", "London", 1, "Rome",
		Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9))
	local two = Locale.Lookup("LOC_EFV_NOTIF_RETURNING_DISBANDED_SUMMARY", "Swordsman", "London", 2, "Rome", "")
	for _, s in ipairs({ one, two }) do
		H.ok(not Has(s, "LOC_EFV") and not Has(s, "{"), s)
	end
	H.ok(Has(one, "arrives in 1 turn."), one)
	H.ok(Has(two, "arrives in 2 turns."), two)
	H.ok(Has(one, "Rome disbanded Swordsman"), one)
	H.ok(Has(one, "9"), one)
	H.clean()
end)
