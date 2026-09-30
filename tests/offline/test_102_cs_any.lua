-- @harness native
-- 1.0.2 designer ruling (proxy wars): City-State Expeditionary units can go
-- to ANY city-state the sender has met, with no shared-enemy requirement.
-- Still refused while the sender and that city-state are at war with each
-- other (AT_WAR_WITH_RECIPIENT); an unmet city-state never gets a row
-- (CS_NOT_MET). Expeditionary to majors and Volunteers keep the
-- shared-enemy rule (NO_COMMON_WAR). Lifecycle unchanged: a CS unit never
-- lapses for want of a war, and a war between the sender and the city-state
-- still sends it home (spec 11; 1.0.4: the return trip, no switch in place).
--
-- Scenario: 0 Rome (human), 1 England (friend + open borders), 5 Mali
-- (friend, no wars), 3 Gaul (at war with Rome and England), 6 Rapa Nui
-- (city-state at war with Gaul), 7 Kandy (city-state, no wars), 8 Zanzibar
-- (city-state, not met), 62 Free Cities, 63 barbarians.

local EXP, VOL, CS = "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"
local ROME, ENGLAND, GAUL, MALI, RAPA, KANDY, ZANZI, FREE, BARB = 0, 1, 3, 5, 6, 7, 8, 62, 63

local function Scenario()
	H.world({ players = {
		{ id = ROME, human = true, gold = 1000 }, { id = ENGLAND, gold = 1000 },
		{ id = GAUL, gold = 1000 }, { id = MALI, gold = 1000 },
		{ id = RAPA, kind = "CITY_STATE", gold = 0 }, { id = KANDY, kind = "CITY_STATE", gold = 0 },
		{ id = ZANZI, kind = "CITY_STATE", gold = 0 },
		{ id = FREE, kind = "FREE_CITIES" }, { id = BARB, kind = "BARBARIAN" },
	} })
	local S = {}
	S.c0 = H.city(ROME, 10, 10, { capital = true, name = "Roma" })
	S.c1 = H.city(ENGLAND, 22, 10, { capital = true, name = "London" })
	S.c3 = H.city(GAUL, 70, 40, { capital = true, name = "Gergovia" })
	S.c5 = H.city(MALI, 12, 30, { capital = true, name = "Niani" })
	S.c6 = H.city(RAPA, 30, 20, { capital = true, name = "Rapa Nui" })
	S.c7 = H.city(KANDY, 20, 20, { capital = true, name = "Kandy" })
	S.c8 = H.city(ZANZI, 40, 30, { capital = true, name = "Zanzibar" })
	H.friend(ROME, ENGLAND); H.openBorders(ROME, ENGLAND)
	H.friend(ROME, MALI)
	H.war(GAUL, ROME); H.war(GAUL, ENGLAND); H.war(GAUL, RAPA)
	H.meet(ROME, RAPA); H.meet(ROME, KANDY)
	return S
end

local function MyUnit() return H.unit(ROME, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 }) end

local function Reasons(u, rid, city, ft)
	local _, r = EFV_EvaluateSend(ROME, u, rid, city, ft, EFV_Records.Load())
	return r
end

local function RowsOf(u, ft, rid)
	local out = {}
	for _, row in ipairs(EFV_DestinationRows(ROME, u, ft, EFV_Records.Load())) do
		if row.recipientID == rid then out[#out + 1] = row end
	end
	return out
end

-- Runs fn once as gameplay and once as UI (the test stays in the UI context).
local function BothContexts(fn)
	fn("G")
	include("fake_ui")
	FAKE_UI.Enable()
	fn("UI")
end

test("1.0.2: a met city-state at war with nobody -> City-State send allowed, both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	BothContexts(function(ctx)
		H.ok(not EFV_HasCommonWar(ROME, KANDY), ctx .. ": no common enemy with Kandy")
		H.deq(Reasons(u, KANDY, S.c7, CS), {}, ctx .. ": Kandy")
		local rows = RowsOf(u, CS, KANDY)
		H.len(rows, 1, ctx .. ": Kandy listed")
		H.ok(rows[1].ok, ctx .. ": Kandy row open")
		H.eq(rows[1].calc.basis, "CITY_STATE", ctx)
		H.deq(Reasons(u, RAPA, S.c6, CS), {}, ctx .. ": Rapa Nui (shares Gaul) still allowed")
	end)
	H.clean()
end)

test("1.0.2: a sender at war with nobody can still lend to a city-state", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.peace(GAUL, ROME)
	H.war(BARB, ROME); H.war(BARB, KANDY)
	BothContexts(function(ctx)
		H.deq(Reasons(u, KANDY, S.c7, CS), {}, ctx .. ": Kandy")
		H.deq(Reasons(u, RAPA, S.c6, CS), {}, ctx .. ": Rapa Nui (at war with Gaul, Rome is not)")
		for _, row in ipairs(EFV_DestinationRows(ROME, u, CS, EFV_Records.Load())) do
			H.notContains(row.reasons, "NO_COMMON_WAR", ctx .. ": no City-State row shows NO_COMMON_WAR")
		end
	end)
	H.clean()
end)

test("1.0.2 proxy war: a city-state fighting the sender's friend is still allowed", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.war(MALI, KANDY)                                -- Kandy fights Mali, Rome's friend
	BothContexts(function(ctx)
		H.deq(Reasons(u, KANDY, S.c7, CS), {}, ctx .. ": Kandy")
	end)
	H.clean()
end)

test("1.0.2: a city-state at war with the sender -> blocked (AT_WAR_WITH_RECIPIENT), both contexts; gameplay rejects it", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.war(ROME, KANDY)
	H.send(ROME, u, KANDY, S.c7, CS, 999)
	H.len(H.records(), 0, "no record")
	H.len(H.notifs(ROME, "EFV_NOTIF_REQUEST_FAILED"), 1)
	BothContexts(function(ctx)
		H.deq(Reasons(u, KANDY, S.c7, CS), { "AT_WAR_WITH_RECIPIENT" }, ctx .. ": Kandy")
		local rows = RowsOf(u, CS, KANDY)
		H.len(rows, 1, ctx .. ": listed, greyed")
		H.ok(not rows[1].ok, ctx)
		H.deq(Reasons(u, RAPA, S.c6, CS), {}, ctx .. ": Rapa Nui unaffected")
	end)
	H.clean()
end)

test("1.0.2: an unmet city-state has no row and a forged send is refused (CS_NOT_MET)", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.send(ROME, u, ZANZI, S.c8, CS, 999)
	H.len(H.records(), 0, "no record for the unmet city-state")
	BothContexts(function(ctx)
		H.len(RowsOf(u, CS, ZANZI), 0, ctx .. ": Zanzibar absent")
		H.contains(Reasons(u, ZANZI, S.c8, CS), "CS_NOT_MET", ctx)
		H.notContains(Reasons(u, ZANZI, S.c8, CS), "NO_COMMON_WAR", ctx)
	end)
	H.clean()
end)

test("1.0.2: Expeditionary to majors and Volunteers keep the shared-enemy rule", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	BothContexts(function(ctx)
		H.deq(Reasons(u, MALI, S.c5, EXP), { "NO_COMMON_WAR" }, ctx .. ": Expeditionary to Mali (no shared war)")
		H.deq(Reasons(u, MALI, S.c5, VOL), { "VOL_NEEDS_ACCESS", "NO_COMMON_WAR" }, ctx .. ": Volunteers to Mali")
		H.deq(Reasons(u, ENGLAND, S.c1, EXP), {}, ctx .. ": Expeditionary to England (shares Gaul)")
		H.deq(Reasons(u, ENGLAND, S.c1, VOL), {}, ctx .. ": Volunteers to England")
	end)
	FAKE_UI.AsGameplay(function()
		H.peace(GAUL, ENGLAND)
		H.contains(Reasons(u, ENGLAND, S.c1, EXP), "NO_COMMON_WAR", "G: England without the shared war")
		H.contains(Reasons(u, ENGLAND, S.c1, VOL), "NO_COMMON_WAR", "G: Volunteers too")
	end)
	H.clean()
end)

test("1.0.2 lifecycle: a CS unit sent without a shared war serves on; a sender-CS war sends it home (1.0.4)", function()
	local S = Scenario()
	H.loadEFV()
	H.send(ROME, MyUnit(), KANDY, S.c7, CS, 999)
	local recs = H.records()
	H.len(recs, 1, "send to Kandy accepted without a shared enemy")
	H.len(H.notifs(ROME, "EFV_NOTIF_REQUEST_FAILED"), 0)
	local r = recs[1]
	H.eq(r.forceType, CS)
	H.eq(r.recipientID, KANDY)
	H.turns(r.arrivalTurn - FAKE.turn)
	r = H.record()
	H.eq(r.state, "DEPLOYED")
	H.turns(3)
	r = H.record()
	H.eq(r.state, "DEPLOYED", "no lapse, grace or recall for want of a war")
	H.eq(tonumber(r.lapsed) or 0, 0)
	H.notnil(Players[KANDY]:GetUnits():FindID(r.onMapUnitID), "Kandy commands the unit")
	H.war(ROME, KANDY)
	H.endTurn()
	r = H.record()
	H.eq(r.state, "RETURNING", "sent home at the next boundary (spec 11, 1.0.4)")
	H.eq(r.returnReason, "WAR")
	H.len(H.unitsOf(KANDY, "UNIT_SWORDSMAN"), 0, "taken from Kandy")
	H.len(H.notifs(ROME, "EFV_NOTIF_RETURNING"), 1)
	H.len(H.notifs(ROME, "EFV_NOTIF_REVERTED"), 0)
	H.turns(r.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	H.len(H.unitsOf(ROME, "UNIT_SWORDSMAN"), 1, "the unit is back home with Rome")
	H.clean()
end)
