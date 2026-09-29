-- @harness native
-- EFV_Rules: spawn candidate ordering and validity (spec 8), EFV_Spawn.Pick,
-- partner / war rules (spec 6.1, D2, designer answers), unit send reasons
-- (spec 6.2), destination evaluation (spec 6.3) and recall reasons (spec 9.2).

local function idx(plots)
	local out = {}
	for i, p in ipairs(plots or {}) do out[i] = p:GetIndex() end
	return out
end

local function Setup()
	H.world{ w = 40, h = 30, wrapX = false }
	H.loadEFV()
end

-- ---------------------------------------------------------------------------
-- Spawn search
-- ---------------------------------------------------------------------------
test("spawn: open land -> ring 1, six plots sorted by index", function()
	Setup()
	local ring, plots = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	H.eq(ring, 1)
	H.len(plots, 6)
	local ids = idx(plots)
	for i = 2, #ids do H.ok(ids[i - 1] < ids[i], "ascending index") end
	for _, p in ipairs(plots) do H.eq(Map.GetPlotDistance(20, 15, p:GetX(), p:GetY()), 1) end
end)

test("spawn: ring 1 fully occupied -> ring 2 (12 plots, exact distance 2)", function()
	Setup()
	for dir = 0, 5 do
		local p = Map.GetAdjacentPlot(20, 15, dir)
		H.unit(3, "UNIT_WARRIOR", p:GetX(), p:GetY())
	end
	local ring, plots = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	H.eq(ring, 2)
	H.len(plots, 12)
	for _, p in ipairs(plots) do H.eq(Map.GetPlotDistance(20, 15, p:GetX(), p:GetY()), 2) end
end)

test("spawn: centre (city) plot is never a candidate", function()
	Setup()
	local _, plots = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	for _, p in ipairs(plots) do H.ne(p:GetIndex(), H.plot(20, 15):GetIndex()) end
end)

test("spawn: water, mountains and natural wonders are rejected for land", function()
	Setup()
	H.terrain(21, 15, "OCEAN")
	H.terrain(19, 15, "MOUNTAIN")
	Map.GetAdjacentPlot(20, 15, 0).wonder = true
	local ring, plots = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	H.eq(ring, 1)
	H.len(plots, 3)
	H.ok(not EFV_SpawnValid(H.plot(21, 15), "LAND", 1, nil), "water")
	H.ok(not EFV_SpawnValid(H.plot(19, 15), "LAND", 1, nil), "mountain")
	H.ok(not EFV_SpawnValid(Map.GetAdjacentPlot(20, 15, 0), "LAND", 1, nil), "natural wonder")
end)

test("spawn: natural wonders allowed when the flag is off", function()
	H.world{ w = 40, h = 30, wrapX = false }
	H.loadEFV{ flags = { FLAG_SPAWN_EXCLUDE_NATURAL_WONDER = false } }
	local p = Map.GetAdjacentPlot(20, 15, 0)
	p.wonder = true
	H.ok(EFV_SpawnValid(p, "LAND", 1, nil))
end)

test("spawn: plots owned by an enemy of the new owner are rejected (ignoreWarOwner overrides)", function()
	Setup()
	H.war(1, 3)
	local p = H.plot(21, 15)
	p.owner = 3
	H.ok(not EFV_SpawnValid(p, "LAND", 1, nil), "enemy-owned")
	H.ok(EFV_SpawnValid(p, "LAND", 1, { ignoreWarOwner = true }), "ignoreWarOwner")
	p.owner = 2
	local ok, why = EFV_SpawnValid(p, "LAND", 1, nil)
	H.eq(ok, false, "owned by a non-enemy with closed borders"); H.eq(why, "ACCESS")
	H.ally(1, 2)
	H.ok(EFV_SpawnValid(p, "LAND", 1, nil), "allied owner: access")
end)

test("spawn ACCESS (Session D 3): owner -1 / self / team / CS / ally / open borders; friend alone is not enough", function()
	Setup()
	local p = H.plot(21, 15)
	local function V() local ok, why = EFV_SpawnValid(p, "LAND", 1, nil); return ok, why end
	p.owner = -1; H.ok((V()), "unowned")
	p.owner = 1; H.ok((V()), "own")
	p.owner = 2
	H.friend(1, 2)
	local ok, why = V()
	H.eq(ok, false, "declared friend without open borders"); H.eq(why, "ACCESS")
	H.openBorders(2, 1)                               -- 1 grants 2: the wrong direction
	H.eq((V()), false, "open borders granted BY the new owner do not count")
	H.openBorders(1, 2)                               -- 2 grants 1
	H.ok((V()), "open borders from the plot owner")
	H.openBorders(1, 2, false)
	Players[2].team = Players[1].team
	H.ok((V()), "teammate")
	Players[2].team = 2
	p.owner = 4
	H.ok((V()), "city-state land (open at peace)")
	H.eq(EFV_Spawn.Valid(p, "LAND", 1), true, "EFV_Spawn delegates the same rule")
	-- UI context (naval dry run): same rule through the UI readers.
	p.owner = 2
	H.openBorders(1, 2)
	FAKE.context = "UI"; UI = {}
	H.eq(EFV_IsGameplay(), false)
	H.ok((V()), "UI: HasOpenBordersFrom")
	H.openBorders(1, 2, false)
	H.eq((V()), false, "UI: closed")
	UI = nil; FAKE.context = "G"
end)

test("EFV_Spawn.PickOrdered: [1] = Pick's plot (one RNG call), then the ring in index order after it, then ring 2; bounded", function()
	Setup()
	FAKE.rngSeed = 5
	local pick = EFV_Spawn.Pick(20, 15, "LAND", 1, "arr9")
	local calls = #FAKE.rngCalls
	FAKE.rngSeed = 5
	local list = EFV_Spawn.PickOrdered(20, 15, "LAND", 1, "arr9", nil, 10)
	H.eq(#FAKE.rngCalls, calls + 1, "exactly one RNG call")
	H.len(list, 10)
	H.eq(list[1]:GetIndex(), pick:GetIndex(), "first = Pick")
	local _, ring1 = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	local k = FAKE.rngCalls[#FAKE.rngCalls].result
	for i = 1, 6 do
		H.eq(list[i]:GetIndex(), ring1[((k + i - 1) % 6) + 1]:GetIndex(), "ring 1 wraps after the pick")
	end
	local ring2 = EFV_SpawnRing(20, 15, 2, "LAND", 1, nil)
	for i = 7, 10 do
		H.eq(list[i]:GetIndex(), ring2[i - 6]:GetIndex(), "then ring 2 in index order")
		H.eq(Map.GetPlotDistance(20, 15, list[i]:GetX(), list[i]:GetY()), 2)
	end
	H.len(EFV_Spawn.PickOrdered(20, 15, "LAND", 1, "arr9"), EFV_Config.SPAWN_CREATE_TRIES, "default bound")
	H.len(FAKE.forbidden, 0)
end)

test("spawn: dead ends (fewer than SPAWN_MIN_EXITS passable neighbours) are rejected", function()
	Setup()
	-- (10,10) with 5 of its 6 neighbours mountains -> 1 exit
	for dir = 1, 5 do
		local q = Map.GetAdjacentPlot(10, 10, dir)
		H.terrain(q:GetX(), q:GetY(), "MOUNTAIN")
	end
	H.ok(not EFV_SpawnValid(H.plot(10, 10), "LAND", 1, nil))
	local q = Map.GetAdjacentPlot(10, 10, 1)
	H.terrain(q:GetX(), q:GetY(), "LAND")
	H.ok(EFV_SpawnValid(H.plot(10, 10), "LAND", 1, nil), "two exits is enough")
end)

test("spawn: sea domain needs water with exits; 1-tile lake never valid", function()
	Setup()
	H.fill(0, 0, 39, 8, "OCEAN")                -- sea in the south
	local c = H.city(1, 20, 9, { radius = 1 })  -- coastal city
	local ring, plots = EFV_SpawnCandidates(20, 9, "SEA", 1, nil)
	H.eq(ring, 1)
	for _, p in ipairs(plots) do H.ok(p:IsWater()) end
	H.terrain(30, 20, "LAKE")
	H.ok(not EFV_SpawnValid(H.plot(30, 20), "SEA", 1, nil), "1-tile lake (G)")
	H.ok(not EFV_SpawnValid(H.plot(30, 20), "SEA", 1, { skipLake = true }), "no exits anyway")
	H.isnil((EFV_SpawnCandidates(30, 25, "SEA", 1, nil)), "no sea near an inland city")
end)

test("spawn: nothing within 5 rings -> nil", function()
	Setup()
	for _, p in ipairs(Map.GetNeighborPlots(20, 15, 5)) do
		if p:GetIndex() ~= H.plot(20, 15):GetIndex() then H.unit(3, "UNIT_WARRIOR", p:GetX(), p:GetY()) end
	end
	H.isnil((EFV_SpawnCandidates(20, 15, "LAND", 1, nil)))
	H.isnil(EFV_Spawn.Pick(20, 15, "LAND", 1, "t"))
end)

test("spawn: foreign city plots are not candidates", function()
	Setup()
	H.city(2, 21, 15, { radius = 0 })
	H.ok(not EFV_SpawnValid(H.plot(21, 15), "LAND", 1, nil))
end)

test("EFV_Spawn.Pick: deterministic, uses Game.GetRandNum over the sorted list", function()
	Setup()
	FAKE.rngSeed = 99
	local p1 = EFV_Spawn.Pick(20, 15, "LAND", 1, "arr1")
	FAKE.rngSeed = 99
	local p2 = EFV_Spawn.Pick(20, 15, "LAND", 1, "arr1")
	H.notnil(p1)
	H.eq(p1:GetIndex(), p2:GetIndex(), "same seed, same plot")
	local call = FAKE.rngCalls[#FAKE.rngCalls]
	H.eq(call.n, 6, "GetRandNum(#plots)")
	H.ok(string.find(tostring(call.label), "arr1", 1, true) ~= nil, "label passed through")
	local _, plots = EFV_SpawnCandidates(20, 15, "LAND", 1, nil)
	H.eq(p1:GetIndex(), plots[call.result + 1]:GetIndex(), "plots[r + 1]")
	H.len(FAKE.forbidden, 0)
end)

test("EFV_Spawn.DomainOf", function()
	Setup()
	H.eq(EFV_Spawn.DomainOf("UNIT_SWORDSMAN"), "LAND")
	H.eq(EFV_Spawn.DomainOf("UNIT_GALLEY"), "SEA")
	H.isnil(EFV_Spawn.DomainOf("UNIT_NOPE"))
end)

-- ---------------------------------------------------------------------------
-- Partner / war rules
-- ---------------------------------------------------------------------------
test("EFV_PartnerBasis: TEAM > ALLIANCE > FRIEND > nil", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(EFV_PartnerBasis(0, 1), "ALLIANCE")
	H.eq(EFV_PartnerBasis(0, 2), "FRIEND")
	H.isnil(EFV_PartnerBasis(0, 3))
	H.team(2, 0)
	H.eq(EFV_PartnerBasis(0, 2), "TEAM")
end)

test("war wins over an alliance flag (Session E 6: SetHasAllied does not end a war)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.war(0, 1)                                       -- the fake war also clears the alliance ...
	Players[0]:GetDiplomacy():SetHasAllied(1, true)   -- ... so re-flag it like EFV_Dev "ally"
	Players[1]:GetDiplomacy():SetHasAllied(0, true)
	H.ok(Players[0]:GetDiplomacy():HasAllied(1) and Players[0]:GetDiplomacy():IsAtWarWith(1), "allied AND at war")
	H.isnil(EFV_PartnerBasis(0, 1), "not a partner while at war")
	H.isnil(EFV_VolunteerBasis(0, 1))
	local ok, reasons = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", EFV_Records.Load())
	H.eq(ok, false)
	H.contains(reasons, "AT_WAR_WITH_RECIPIENT"); H.contains(reasons, "NOT_PARTNER")
	for _, row in ipairs(EFV_DestinationRows(0, u, "EXPEDITIONARY", EFV_Records.Load())) do
		H.ne(row.recipientID, 1, "no picker rows for a flag ally at war")
	end
	H.peace(0, 1)
	H.eq(EFV_PartnerBasis(0, 1), "ALLIANCE", "peace: the flag alliance counts again")
end)

test("EFV_HasCommonWar: shared enemy, barbarians do not count", function()
	H.baseScenario()
	H.loadEFV()
	H.ok(EFV_HasCommonWar(0, 1), "both at war with 3")
	H.peace(3, 1)
	H.ok(not EFV_HasCommonWar(0, 1))
	H.war(0, 63); H.war(1, 63)
	H.ok(not EFV_HasCommonWar(0, 1), "barbarians excluded")
	H.war(4, 3)
	H.ok(EFV_HasCommonWar(0, 4), "city-state recipient")
end)

test("EFV_VolunteerBasis: friend needs open borders FROM the recipient (D2)", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(EFV_VolunteerBasis(0, 1), "ALLIANCE")
	H.isnil(EFV_VolunteerBasis(0, 2), "friend without OB")
	H.openBorders(2, 0)
	H.isnil(EFV_VolunteerBasis(0, 2), "wrong direction")
	H.openBorders(0, 2)
	H.eq(EFV_VolunteerBasis(0, 2), "FRIEND_OB")
	H.ok(EFV_HasOpenBordersFrom(0, 2))
end)

test("EFV_VolunteerLapseReason: WAR first, then PARTNER, nil when fine", function()
	H.baseScenario()
	H.loadEFV()
	H.isnil(EFV_VolunteerLapseReason(0, 1))
	H.ally(0, 1, false)
	H.eq(EFV_VolunteerLapseReason(0, 1), "PARTNER")
	H.peace(3, 1)
	H.eq(EFV_VolunteerLapseReason(0, 1), "WAR")
	H.war(3, 1); H.friend(0, 1); H.openBorders(0, 1)
	H.isnil(EFV_VolunteerLapseReason(0, 1), "friend + OB keeps eligibility (Q3)")
end)

-- ---------------------------------------------------------------------------
-- Unit class and send reasons
-- ---------------------------------------------------------------------------
test("EFV_UnitClass: combat OK; civilian, support, hero, CanTrain=false, levied NEVER", function()
	H.baseScenario()
	H.loadEFV()
	H.eq((EFV_UnitClass(H.unit(0, "UNIT_SWORDSMAN", 10, 11))), "OK")
	H.eq((EFV_UnitClass(H.unit(0, "UNIT_GALLEY", 10, 11))), "OK")
	local s, code = EFV_UnitClass(H.unit(0, "UNIT_SETTLER", 10, 11))
	H.eq(s, "NEVER"); H.eq(code, "CLASS_NEVER")
	H.eq((EFV_UnitClass(H.unit(0, "UNIT_BATTERING_RAM", 10, 11))), "NEVER", "support")
	for row in GameInfo.Units() do
		if string.find(row.UnitType, "UNIT_HERO_", 1, true) == 1 and row.FormationClass == "FORMATION_CLASS_LAND_COMBAT" then
			H.eq((EFV_UnitClass(H.unit(0, row.UnitType, 10, 11))), "NEVER", row.UnitType)
			break
		end
	end
	for row in GameInfo.Units() do
		if row.CanTrain == false and row.FormationClass == "FORMATION_CLASS_LAND_COMBAT" then
			H.eq((EFV_UnitClass(H.unit(0, row.UnitType, 10, 11))), "NEVER", row.UnitType .. " CanTrain=false")
			break
		end
	end
	local levy = H.unit(0, "UNIT_SWORDSMAN", 10, 11)
	levy.originalOwner = 4
	H.eq((EFV_UnitClass(levy)), "NEVER", "levied")
	if GameInfo.Units["UNIT_WARRIOR_MONK"] then
		H.eq((EFV_UnitClass(H.unit(0, "UNIT_WARRIOR_MONK", 10, 11))), "OK", "D4 warrior monk allowed")
	end
end)

test("EFV_UnitSendReasons: eligible unit has no reasons", function()
	H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.deq(EFV_UnitSendReasons(u, 0, EFV_Records.Load()), {})
end)

test("EFV_UnitSendReasons: each failing condition is reported", function()
	H.baseScenario()
	H.loadEFV()
	local store = EFV_Records.Load()
	H.contains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { damage = 10 }), 0, store), "DAMAGED")
	-- 0.7 "Send from the recipient's land": ally land is no unit-level reason
	-- (rows of other recipients get WRONG_TERRITORY); unowned land still is.
	H.notContains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 21, 10), 0, store), "NOT_OWN_TERRITORY", "in ally land")
	local np = H.neutralPlot(11, 10)
	H.contains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", np:GetX(), np:GetY()), 0, store), "NOT_OWN_TERRITORY", "on neutral land")
	H.contains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { moves = 0 }), 0, store), "NOT_FULL_MOVES")
	H.contains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { formation = 1 }), 0, store), "FORMATION")
	H.contains(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { embarked = true }), 0, store), "EMBARKED")
	H.contains(EFV_UnitSendReasons(H.unit(1, "UNIT_SWORDSMAN", 11, 10), 0, store), "NOT_OWNER")
	H.contains(EFV_UnitSendReasons(H.unit(1, "UNIT_SWORDSMAN", 21, 10), 1, store), "NOT_HUMAN_MAJOR")
	H.deq(EFV_UnitSendReasons(nil, 0, store), { "REQ_STALE" })
end)

test("EFV_UnitSendReasons: full movement points required (designer decision, replaces spec 6.2.6)", function()
	H.baseScenario()
	H.loadEFV()
	local store = EFV_Records.Load()
	local fresh = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.eq(fresh:GetMovesRemaining(), fresh:GetMaxMoves(), "a fresh unit has full moves")
	H.deq(EFV_UnitSendReasons(fresh, 0, store), {}, "a fresh unit passes")
	local moved = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { moves = 1 })
	H.ok(moved:GetMovesRemaining() > 0 and moved:GetMovesRemaining() < moved:GetMaxMoves())
	H.deq(EFV_UnitSendReasons(moved, 0, store), { "NOT_FULL_MOVES" }, "partial moves are blocked")
	H.deq(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { moves = 0 }), 0, store), { "NOT_FULL_MOVES" },
		"no moves: one reason, no separate NO_MOVES")
	-- Attacking spends moves in game; the separate ATTACKED check is gone.
	H.deq(EFV_UnitSendReasons(H.unit(0, "UNIT_SWORDSMAN", 11, 10, { attacks = 0 }), 0, store), {},
		"no ATTACKED reason; only the moves count")
	H.notContains(EFV_Rules.ALL_REASON_CODES, "NO_MOVES", "retired")
	H.notContains(EFV_Rules.ALL_REASON_CODES, "ATTACKED", "retired")
	H.contains(EFV_Rules.ALL_REASON_CODES, "NOT_FULL_MOVES")
	H.isnil(FAKE_TEXT["LOC_EFV_REASON_NO_MOVES"], "retired text removed")
	H.isnil(FAKE_TEXT["LOC_EFV_REASON_ATTACKED"], "retired text removed")
	H.ok(FAKE_TEXT["LOC_EFV_REASON_NOT_FULL_MOVES"] ~= nil, "NOT_FULL_MOVES has text")
end)

test("EFV_UnitSendReasons: a tracked unit is ALREADY_TRACKED (DV8)", function()
	H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local store = { ids = { 7 }, recs = { r7 = { id = 7, onMapPlayerID = 0, onMapUnitID = u.id } } }
	H.contains(EFV_UnitSendReasons(u, 0, store), "ALREADY_TRACKED")
end)

-- ---------------------------------------------------------------------------
-- Destination evaluation
-- ---------------------------------------------------------------------------
test("EFV_EvaluateSend: ally city, band 2, fee 36 (0.5.2 ruling), origin = nearest own city", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, reasons, calc = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", EFV_Records.Load())
	H.deq(reasons, {}); H.ok(ok)
	H.eq(calc.origin, S.c0, "origin city")
	H.eq(calc.distance, 12); H.eq(calc.band, 2); H.eq(calc.transit, 2)
	H.eq(calc.fee, 36); H.eq(calc.duration, 20); H.eq(calc.basis, "ALLIANCE")
end)

test("EFV_EvaluateSend: destination failures", function()
	local S = H.baseScenario()
	H.loadEFV()
	local store = EFV_Records.Load()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, r = EFV_EvaluateSend(0, u, 3, S.c3, "EXPEDITIONARY", store)
	H.ok(not ok); H.contains(r, "NOT_PARTNER"); H.contains(r, "AT_WAR_WITH_RECIPIENT")
	ok, r = EFV_EvaluateSend(0, u, 1, S.c2, "EXPEDITIONARY", store)
	H.contains(r, "CITY_NOT_OWNED")
	FAKE.unrevealed[0] = { [H.plot(S.c1.x, S.c1.y):GetIndex()] = true }
	ok, r = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", store)
	H.contains(r, "NOT_REVEALED")
	FAKE.unrevealed[0] = nil
	H.setGold(0, 35)
	local calc
	ok, r, calc = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", store)
	H.deq(r, { "GOLD" }); H.eq(calc.fee, 36, "calc filled for disabled rows")
	H.setGold(0, 1000)
	H.peace(3, 1)
	ok, r = EFV_EvaluateSend(0, u, 1, S.c1, "EXPEDITIONARY", store)
	H.deq(r, { "NO_COMMON_WAR" })
end)

test("EFV_EvaluateSend: Volunteer to a friend without open borders -> VOL_NEEDS_ACCESS", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, r, calc = EFV_EvaluateSend(0, u, 2, S.c2, "VOLUNTEER", EFV_Records.Load())
	H.ok(not ok); H.contains(r, "VOL_NEEDS_ACCESS")
	H.openBorders(0, 2)
	ok, r, calc = EFV_EvaluateSend(0, u, 2, S.c2, "VOLUNTEER", EFV_Records.Load())
	H.deq(r, {}); H.eq(calc.basis, "FRIEND_OB"); H.isnil(calc.duration)
end)

test("EFV_EvaluateSend: CS Expeditionary to a met city-state", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, r, calc = EFV_EvaluateSend(0, u, 4, S.c4, "CS_EXPEDITIONARY", EFV_Records.Load())
	H.deq(r, {}); H.eq(calc.basis, "CITY_STATE"); H.eq(calc.duration, 10)
end)

test("EFV_EvaluateSend: naval unit to an inland city -> NAVAL_NO_SPAWN", function()
	local S = H.baseScenario()
	H.fill(0, 0, 83, 7, "OCEAN")
	H.loadEFV()
	local g = H.unit(0, "UNIT_GALLEY", 10, 8)   -- own land tile next to the sea (odd ownership irrelevant)
	H.own(10, 8, 0)
	local _, r = EFV_EvaluateSend(0, g, 2, S.c2, "EXPEDITIONARY", EFV_Records.Load())
	H.contains(r, "NAVAL_NO_SPAWN", "friend's inland city")
	_, r = EFV_EvaluateSend(0, g, 1, S.c1, "EXPEDITIONARY", EFV_Records.Load())
	H.notContains(r, "NAVAL_NO_SPAWN", "ally city 3 hexes from the sea")
end)

test("EFV_DestinationRows: EXP rows = partner majors' cities, ascending", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local rows = EFV_DestinationRows(0, u, "EXPEDITIONARY", EFV_Records.Load())
	local keys = {}
	for _, row in ipairs(rows) do keys[#keys + 1] = row.recipientID .. ":" .. row.cityID end
	H.deq(keys, { "1:" .. S.c1.id, "1:" .. S.c1b.id, "2:" .. S.c2.id }, "ally cities then friend city; enemy excluded")
	for _, row in ipairs(rows) do
		if row.recipientID == 1 then H.ok(row.ok, "ally rows enabled") end
		H.notnil(row.calc); H.eq(row.destX, CityManager.GetCity(row.recipientID, row.cityID):GetX())
	end
end)

-- ---------------------------------------------------------------------------
-- Return territory and recall
-- ---------------------------------------------------------------------------
test("EFV_ValidReturnTerritory: sender or recipient tiles only", function()
	H.baseScenario()
	H.loadEFV()
	local rec = { senderID = 0, recipientID = 1 }
	H.ok(EFV_ValidReturnTerritory(rec, H.plot(10, 11)), "sender")
	H.ok(EFV_ValidReturnTerritory(rec, H.plot(22, 11)), "recipient")
	H.ok(not EFV_ValidReturnTerritory(rec, H.plot(40, 31)), "third party")
	H.ok(not EFV_ValidReturnTerritory(rec, H.neutralPlot(30, 5)), "neutral")
end)

test("EFV_RecallReasons: minimum turns, lapse waiver, territory, no HP rule", function()
	H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 22, 11, { damage = 50 })
	local rec = { forceType = "VOLUNTEER", senderID = 0, recipientID = 1, deployedTurn = 5, lapsed = 0 }
	H.deq(EFV_RecallReasons(rec, u, 14), { "RECALL_MIN_TURNS" })
	H.deq(EFV_RecallReasons(rec, u, 15), {}, "10 turns elapsed, damage does not matter")
	rec.lapsed = 1
	H.deq(EFV_RecallReasons(rec, u, 6), {}, "lapse waives the minimum")
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	H.deq(EFV_RecallReasons(rec, u, 20), { "RECALL_TERRITORY" })
	H.deq(EFV_RecallReasons({ forceType = "EXPEDITIONARY" }, u, 20), { "RECALL_NOT_VOLUNTEER" })
end)

test("ALL_REASON_CODES: retired RECALL_DAMAGED absent, every code has text", function()
	H.world{}
	H.loadEFV()
	H.notContains(EFV_Rules.ALL_REASON_CODES, "RECALL_DAMAGED")
	local missing = {}
	for _, code in ipairs(EFV_Rules.ALL_REASON_CODES) do
		if FAKE_TEXT["LOC_EFV_REASON_" .. code] == nil then missing[#missing + 1] = code end
	end
	H.deq(missing, {}, "codes without LOC_EFV_REASON_<CODE>")
end)
