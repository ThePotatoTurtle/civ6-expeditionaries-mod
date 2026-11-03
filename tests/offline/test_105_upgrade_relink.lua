-- @harness native
-- 1.0.5 MP upgrade fixes (FIXPLAN_upgrade_relink.md U5 F1-F7, U7; DECISIONS
-- "MP upgrade bugs: the U11 answers", 2026-10-25). A lent unit that its
-- holder moved and then upgraded was not found on its last snapshot tile:
-- in multiplayer no boundary runs while the humans play. The fixes: F1
-- follows moves (GameEvents.OnUnitMoved), F2 pairs the upgrade when the new
-- unit is created (GameEvents.UnitCreated / UnitInitialized), F3 boundary
-- relink order, F4 strict merge guess (a Corps or Army of the same type),
-- F5 kill evidence, F6 the disband guard, F7 the [Classify] line.
-- Scenario (H.baseScenario): 0 human sender (cities (10,10), (14,20)),
-- 1 = B ally (capital (22,10)), 2 friend F, 3 enemy C (at war with 0, 1, 2,
-- 4), 4 city-state (30,20). "MP" cases make B human: the test body then
-- plays B's turn after H.endTurn(), as the multiplayer log shows (U1).
-- Fake engine models used (all off by default, fake_engine.lua header):
-- FAKE.upgradeEvents, upgradeGhostOffMap, upgradeKeepsMoves, createEvents,
-- supportFormation, corpseOffMap, propReads; H.move fires OnUnitMoved.

local N = function(name) return "EFV_NOTIF_" .. name end
local OFF = { FLAG_MOVE_TRACK = false, FLAG_UPGRADE_CREATE_HOOK = false, FLAG_MERGE_STRICT = false, FLAG_KILL_EVIDENCE = false }
local NO_F2 = { FLAG_UPGRADE_CREATE_HOOK = false }
-- F2 ships off (spike U6, 2026-11-03); its tests turn it on. Boot without flags = F2 on.
local F2_ON = { FLAG_UPGRADE_CREATE_HOOK = true }
local ENEMY = { owner = 3, id = 99999 }
local PROMO = { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 }

local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function Sent(pid, name) return H.notifs(pid, N(name)) end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] or "" end
local function Has(text, s) return text ~= nil and s ~= nil and string.find(text, s, 1, true) ~= nil end
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end

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

-- World, model switches and EFV with flags. opts: mp (B human), ghost
-- ("ghost" | "live" | nil), offmap (the upgrade ghost goes off the map:
-- final session L479; default true when ghost is set), support (-1).
local function Boot(opts)
	opts = opts or {}
	local S = H.baseScenario()
	if opts.mp then Players[1].human = true end
	FAKE.upgradeEvents = opts.ghost
	if opts.offmap == nil then opts.offmap = (opts.ghost ~= nil) end
	FAKE.upgradeGhostOffMap = opts.offmap
	FAKE.supportFormation = opts.support
	H.loadEFV({ flags = opts.flags or F2_ON })
	return S
end

-- Sends units of player 0 to B (or recipient / city) in one turn and plays
-- until they arrive. Returns the records and their on-map units (ID order).
local function LendMany(S, n, typeName, unitOpts, force, recipient, city)
	local ids = {}
	for _ = 1, n do
		local u = H.unit(0, typeName or "UNIT_SWORDSMAN", 11, 10, unitOpts or PROMO)
		H.send(0, u, recipient or 1, city or S.c1, force or "EXPEDITIONARY", 999)
		local r = H.records()[#H.records()]
		H.notnil(r, "send accepted")
		ids[#ids + 1] = r.id
	end
	local arrival = Rec(ids[1]).arrivalTurn
	H.turns(arrival - FAKE.turn)
	local recs, units = {}, {}
	for i, id in ipairs(ids) do
		recs[i] = Rec(id)
		H.eq(recs[i].state, "DEPLOYED", "arrived")
		units[i] = FAKE.units[recs[i].onMapUnitID]
	end
	return recs, units
end

local function Lend(S, typeName, unitOpts, force, recipient, city)
	local recs, units = LendMany(S, 1, typeName, unitOpts, force, recipient, city)
	return recs[1], units[1]
end

local function RelinkLine(id, hook)
	for _, l in ipairs(H.lines("[Upgrade] relink id=" .. id .. " ")) do
		if hook == nil or Has(l, "hook=" .. hook) then return l end
	end
	return nil
end

-- ===========================================================================
-- u1-u3: the three records of the report (rec 6, rec 8, rec 12)
-- ===========================================================================
-- Rec 6: a lent Berserker, a host Battering Ram 2 tiles away (formation -1,
-- like the Medic), MP host: moved one tile, then upgraded to a Musketman.
local function Rec6(flags)
	local S = Boot({ mp = true, ghost = "ghost", support = -1, flags = flags })
	local r, u = Lend(S, "UNIT_NORWEGIAN_BERSERKER")
	local to = FreeAt(u.x, u.y, 1)
	local ram = H.unit(1, "UNIT_BATTERING_RAM", FreeAt(u.x, u.y, 2).x, FreeAt(u.x, u.y, 2).y)
	H.eq(ram.formation, -1)
	H.endTurn()                                  -- B's turn (human): no boundary until H.endTurn
	H.clearNotifs()
	H.move(u, to.x, to.y)
	local nu = H.upgrade(u, "UNIT_MUSKETMAN")
	return r, u, nu, to
end

test("u1a (rec 6) all flags off: the 1.0.4 bug, MERGED into the Battering Ram next turn", function()
	local r = Rec6(OFF)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "MERGED"), 1)
	H.ok(H.hasLine("[Merge] absorbed id=" .. r.id), "the misread")
	H.ok(H.hasLine("[Classify] id=" .. r.id .. " class=DISBANDED"), "F7 logs even with the flags off")
	H.clean()
end)

test("u1b (rec 6) F1 + F2: relinked at once (hook=UnitCreated), Musketman, no MERGED or UNIT_LOST", function()
	local r, u, nu, to = Rec6(nil)
	local rr = Rec(r.id)
	H.eq(rr.onMapUnitID, nu.id); H.eq(rr.unitType, "UNIT_MUSKETMAN")
	H.eq(rr.lastX, to.x); H.eq(rr.lastY, to.y); H.eq(rr.posTurn, FAKE.turn)
	H.ok(Has(RelinkLine(r.id, "UnitCreated"), "type=UNIT_NORWEGIAN_BERSERKER->UNIT_MUSKETMAN"))
	H.ok(Has(RelinkLine(r.id, "UnitCreated"), "old=ghost"))
	H.ok(H.hasLine("[Move] id=" .. r.id), "F1 followed the move")
	H.turns(2)
	H.eq(Rec(r.id).state, "DEPLOYED"); H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.len(Sent(0, "MERGED"), 0); H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

test("u1c (rec 6) F1 only (F2 off): relinked at the next boundary from the move's tile", function()
	local r, u, nu, to = Rec6(NO_F2)
	H.eq(Rec(r.id).onMapUnitID, u.id, "not yet")
	H.eq(Rec(r.id).lastX, to.x, "F1: the tile of the move")
	H.endTurn()
	local rr = Rec(r.id)
	H.eq(rr.onMapUnitID, nu.id); H.eq(rr.unitType, "UNIT_MUSKETMAN")
	H.isnil(RelinkLine(r.id, "UnitCreated"))
	H.notnil(RelinkLine(r.id, nil), "relinked at a boundary")
	H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

test("u2 (rec 8) two lent Longships moved and upgraded to Caravels near a host Swordsman Corps and a Ram: both relinked, never MERGED", function()
	local S = Boot({ mp = true, ghost = "ghost", support = -1 })
	H.fill(23, 6, 30, 14, "COAST")
	H.terrain(9, 10, "COAST")
	local ids = {}
	for _ = 1, 2 do
		local ship = H.unit(0, "UNIT_NORWEGIAN_LONGSHIP", 9, 10, PROMO)
		H.send(0, ship, 1, S.c1, "EXPEDITIONARY", 999)
		ids[#ids + 1] = H.records()[#H.records()].id
	end
	H.turns(Rec(ids[1]).arrivalTurn - FAKE.turn)
	local land1 = FreeAt(22, 10, 1)
	H.unit(1, "UNIT_SWORDSMAN", land1.x, land1.y, { formation = MilitaryFormationTypes.CORPS_FORMATION })
	local land2 = FreeAt(22, 10, 1)
	H.unit(1, "UNIT_BATTERING_RAM", land2.x, land2.y)
	H.endTurn()
	H.clearNotifs()
	local news = {}
	for i, id in ipairs(ids) do
		local r = Rec(id)
		H.eq(r.state, "DEPLOYED")
		local u = FAKE.units[r.onMapUnitID]
		local to = nil
		for _, p in ipairs(Map.GetNeighborPlots(u.x, u.y, 1)) do
			if to == nil and H.dist(p, u) == 1 and p:IsWater() and p:GetUnitCount() == 0 then to = p end
		end
		H.move(u, to.x, to.y)
		news[i] = H.upgrade(u, "UNIT_CARAVEL")
	end
	H.turns(2)
	for i, id in ipairs(ids) do
		local r = Rec(id)
		H.eq(r.state, "DEPLOYED"); H.eq(r.onMapUnitID, news[i].id); H.eq(r.unitType, "UNIT_CARAVEL")
	end
	H.len(Sent(0, "MERGED"), 0); H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

for _, c in ipairs({ { "defaults", nil }, { "all flags off", OFF }, { "F2 off", NO_F2 } }) do
	test("u3 (rec 12 control) upgrade in place, " .. c[1] .. ": relinked", function()
		local S = Boot({ mp = true, ghost = "ghost", flags = c[2] })
		local r, u = Lend(S)
		H.endTurn()
		local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
		H.endTurn()
		local rr = Rec(r.id)
		H.eq(rr.onMapUnitID, nu.id); H.eq(rr.unitType, "UNIT_MAN_AT_ARMS")
		H.len(Sent(0, "UNIT_LOST"), 0); H.len(Sent(0, "MERGED"), 0)
		H.clean()
	end)
end

-- ===========================================================================
-- u4-u9: crowds, the order of upgrade and move, AI hosts, hints, new units
-- ===========================================================================
test("u4 crowded: 3 of 4 lent Swordsmen moved and upgraded next to the host's own; each record follows its own unit", function()
	local S = Boot({ mp = true, ghost = "ghost" })
	local recs, units = LendMany(S, 4)
	local own = H.unit(1, "UNIT_SWORDSMAN", FreeAt(units[1].x, units[1].y, 1).x, FreeAt(units[1].x, units[1].y, 1).y, PROMO)
	H.unit(1, "UNIT_MAN_AT_ARMS", FreeAt(units[2].x, units[2].y, 1).x, FreeAt(units[2].x, units[2].y, 1).y, PROMO)
	H.unit(1, "UNIT_MUSKETMAN", FreeAt(units[3].x, units[3].y, 1).x, FreeAt(units[3].x, units[3].y, 1).y, PROMO)
	H.endTurn()
	local news = {}
	for i = 1, 3 do
		local to = FreeAt(units[i].x, units[i].y, 1)
		H.move(units[i], to.x, to.y)
		news[i] = H.upgrade(units[i], "UNIT_MAN_AT_ARMS")
	end
	local ownNew = H.upgrade(own, "UNIT_MAN_AT_ARMS")
	H.turns(2)
	for i = 1, 3 do
		H.eq(Rec(recs[i].id).onMapUnitID, news[i].id, "record " .. i .. " follows its own Man-at-Arms")
	end
	H.eq(Rec(recs[4].id).onMapUnitID, units[4].id, "the fourth is untouched")
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, ownNew.id), "the host's own upgrade stays untracked")
	H.len(Sent(0, "UNIT_LOST"), 0); H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

test("u5a upgrade, then move (moves kept), F2 on: relinked at creation, the later move is followed", function()
	local S = Boot({ mp = true, ghost = "ghost" })
	FAKE.upgradeKeepsMoves = true
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	local to = FreeAt(nu.x, nu.y, 1)
	H.move(nu, to.x, to.y)
	H.eq(Rec(r.id).lastX, to.x); H.eq(Rec(r.id).lastY, to.y)
	H.endTurn()
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

test("u5b upgrade, then move, F2 off: lost, with the [Classify] line (the documented residual)", function()
	local S = Boot({ mp = true, ghost = "ghost", flags = NO_F2 })
	FAKE.upgradeKeepsMoves = true
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	local to = FreeAt(nu.x, nu.y, 1)
	H.move(nu, to.x, to.y)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED")))
	local cl = H.lines("[Classify] id=" .. r.id .. " class=DISBANDED")
	H.len(cl, 1)
	H.ok(Has(cl[1], ":UNIT_MAN_AT_ARMS:f0:d1"), "the new unit is listed near: " .. cl[1])
	H.clean()
end)

test("u6a AI host moves and upgrades in its turn, F2 on: relinked at creation", function()
	local S = Boot({ ghost = "ghost" })
	local r, u = Lend(S)
	local nu
	H.endTurn({ act = function(p)
		if p == 1 then
			local to = FreeAt(u.x, u.y, 1)
			H.move(u, to.x, to.y)
			nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
		end
	end })
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.notnil(RelinkLine(r.id, "UnitCreated"))
	H.clean()
end)

test("u6b AI host moves and upgrades in its turn, F2 off: relinked at the next player's PlayerTurnStarted", function()
	local S = Boot({ ghost = "ghost", flags = NO_F2 })
	local r, u = Lend(S)
	local nu
	H.endTurn({ act = function(p)
		if p == 1 then
			local to = FreeAt(u.x, u.y, 1)
			H.move(u, to.x, to.y)
			nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
		end
	end })
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.notnil(RelinkLine(r.id, "PlayerTurnStarted"))
	H.clean()
end)

test("u7a hint path (old unit still live in the event): [Upgrade] hint, then relinked when the new unit moves", function()
	local S = Boot({ mp = true, ghost = "live" })
	FAKE.upgradeKeepsMoves = true
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.ok(H.hasLine("[Upgrade] hint id=" .. r.id .. " unit=" .. nu.id), "hint")
	H.ok(H.hasLine("old=live"))
	H.eq(Rec(r.id).onMapUnitID, u.id, "not relinked yet")
	H.eq(Rec(r.id).upgradeHintID, nu.id)
	local to = FreeAt(nu.x, nu.y, 1)
	H.move(nu, to.x, to.y)
	local rr = Rec(r.id)
	H.eq(rr.onMapUnitID, nu.id); H.eq(rr.lastX, to.x); H.isnil(rr.upgradeHintID)
	H.ok(Has(RelinkLine(r.id, "OnUnitMoved"), "dist=1"))
	H.clean()
end)

test("u7b hint path without a move: relinked at the next boundary (old=ghost)", function()
	local S = Boot({ mp = true, ghost = "live" })
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.endTurn()
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.ok(Has(RelinkLine(r.id, "PlayerTurnStarted"), "old=ghost"))
	H.clean()
end)

test("u8 a unit appearing on the tile of a live lent unit: a hint, never confirmed, it expires; the lent unit stays tracked", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	H.endTurn()
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", u.x, u.y, PROMO)
	GameEvents.UnitCreated(1, other.id)
	H.ok(H.hasLine("[Upgrade] hint id=" .. r.id .. " unit=" .. other.id))
	H.turns(2)
	local to = FreeAt(other.x, other.y, 1)
	H.move(other, to.x, to.y)
	local rr = Rec(r.id)
	H.eq(rr.onMapUnitID, u.id, "still the lent unit"); H.isnil(rr.upgradeHintID, "the expired hint was dropped")
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, other.id))
	H.isnil(RelinkLine(r.id, nil))
	H.clean()
end)

test("u9a a unit appearing on the tile right after the lent unit died there (corpse): no relink, KILLED", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	H.endTurn()
	H.combat(ENEMY, u, 100)
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", u.x, u.y, PROMO)
	GameEvents.UnitCreated(1, other.id)
	H.ok(not H.hasLine("[Upgrade] hint"), "a corpse is no upgrade")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, other.id))
	H.clean()
end)

test("u9b corpse already gone and a fight since the last sighting: a hint, never confirmed, KILLED", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	H.endTurn()
	H.combat(ENEMY, u, 100)
	FAKE.ExpireGhosts("frame")
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", u.x, u.y, PROMO)
	GameEvents.UnitCreated(1, other.id)
	H.ok(H.hasLine("[Upgrade] hint id=" .. r.id .. " unit=" .. other.id .. " at=" .. u.x .. "," .. u.y .. " hook=UnitCreated old=none"))
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	H.isnil(RelinkLine(r.id, nil))
	H.clean()
end)

-- ===========================================================================
-- u10-u12: F4 strict merge guess
-- ===========================================================================
test("u10a F4: a lent Swordsman disbanded next to a Ram (formation -1), human host: UNIT_LOST 'disbanded', never MERGED", function()
	local S = Boot({ mp = true, support = -1 })
	local r, u = Lend(S)
	local p = FreeAt(u.x, u.y, 2)
	H.unit(1, "UNIT_BATTERING_RAM", p.x, p.y)
	FAKE.RemoveUnit(u, "DISBAND")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "MERGED"), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_DISBANDED")))
	H.clean()
end)

test("u10b F4: the same with an AI host: comes home (the 1.0.5 disband return)", function()
	local S = Boot({ support = -1 })
	local r, u = Lend(S)
	local p = FreeAt(u.x, u.y, 2)
	H.unit(1, "UNIT_BATTERING_RAM", p.x, p.y)
	FAKE.RemoveUnit(u, "DISBAND")
	H.clearNotifs()
	H.endTurn()
	local rr = Rec(r.id)
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DISBANDED")
	H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

for _, c in ipairs({
	{ "an Archer Corps (another type)", "UNIT_ARCHER", false, false },
	{ "a Swordsman Corps (the same type)", "UNIT_SWORDSMAN", true, false },
	{ "a Galley Fleet (another domain)", "UNIT_GALLEY", false, true },
}) do
	test("u11 F4: next to " .. c[1] .. ": " .. (c[3] and "MERGED" or "not MERGED"), function()
		local S = Boot({})
		local r, u = Lend(S)
		local p = FreeAt(u.x, u.y, 2)
		if c[4] then H.terrain(p.x, p.y, "COAST") end
		H.unit(1, c[2], p.x, p.y, { formation = MilitaryFormationTypes.CORPS_FORMATION })
		FAKE.RemoveUnit(u, "MERGE")
		H.clearNotifs()
		H.endTurn()
		if c[3] then
			H.len(H.records(), 0)
			H.len(Sent(0, "MERGED"), 1)
			H.ok(H.hasLine("record closed (D3) type=" .. c[2] .. " formation=1 dist=2"))
		else
			H.len(Sent(0, "MERGED"), 0)
			H.eq(Rec(r.id).returnReason, "DISBANDED", "an AI host's disband: home")
		end
		H.clean()
	end)
end

test("u12a F4: upgraded and absorbed into the host's Man-at-Arms Corps in one turn (no create event): MERGED _ABSORBED", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	local p = FreeAt(u.x, u.y, 1)
	H.unit(1, "UNIT_MAN_AT_ARMS", p.x, p.y, { formation = MilitaryFormationTypes.CORPS_FORMATION })
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	FAKE.RemoveUnit(nu, "MERGE")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	local m = Sent(0, "MERGED")
	H.len(m, 1)
	H.eq(m[1].data[ParameterTypes.MESSAGE], Locale.Lookup("LOC_EFV_NOTIF_MERGED_ABSORBED_MESSAGE"))
	H.ok(H.hasLine("record closed (D3) type=UNIT_MAN_AT_ARMS formation=1"))
	H.clean()
end)

test("u12b F4: upgraded, then the lent unit leads the Corps: relinked, then the merge survivor (_SURVIVOR)", function()
	local S = Boot({ mp = true, ghost = "ghost" })
	local r, u = Lend(S)
	local p = FreeAt(u.x, u.y, 1)
	local partner = H.unit(1, "UNIT_MAN_AT_ARMS", p.x, p.y)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	nu.formation = MilitaryFormationTypes.CORPS_FORMATION
	FAKE.RemoveUnit(partner, "MERGE")
	H.clearNotifs()
	H.endTurn()
	local rr = Rec(r.id)
	H.eq(rr.state, "DEPLOYED"); H.eq(rr.formation, MilitaryFormationTypes.CORPS_FORMATION)
	H.ok(H.hasLine("[Merge] survivor id=" .. r.id))
	H.eq(Sent(0, "MERGED")[1].data[ParameterTypes.MESSAGE], Locale.Lookup("LOC_EFV_NOTIF_MERGED_SURVIVOR_MESSAGE"))
	H.clean()
end)

-- ===========================================================================
-- u13-u15: F5 kill evidence
-- ===========================================================================
local function CorpseCase(flags)
	local S = Boot({ mp = true, flags = flags })
	FAKE.corpseOffMap = true
	local r, u = Lend(S)
	H.endTurn()
	H.combat(ENEMY, u, 100)
	H.eq(u.x, -9999, "the corpse lies off the map with 100 damage")
	u.ghost = "turnStart"   -- as in the 12 logged corpses, the next boundary still finds it
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	return r
end

test("u13 F5: a corpse at -9999 with 100 damage after a combat: dead unit object, killedTurn, KILLED", function()
	local r = CorpseCase(nil)
	H.ok(H.hasLine("[Combat] dead unit object id=" .. r.id), "MarkKilled now runs")
	H.clean()
end)

-- The multiplayer order of U1: the AI attacks the lent unit at the start of
-- the round (it survives), the human host's turn-start boundary sees it
-- alive, then the host moves and upgrades it in the same round.
local function FoughtThenUpgraded(flags)
	local S = Boot({ mp = true, ghost = "ghost", flags = flags })
	local r, u = Lend(S)
	H.endTurn()
	H.combat(ENEMY, u, 30)
	GameEvents.PlayerTurnStarted(1)   -- a boundary after the AI phase (the host's PTS / PTSC in MP)
	H.eq(Rec(r.id).lastCombatTurn, FAKE.turn)
	local to = FreeAt(u.x, u.y, 1)
	H.move(u, to.x, to.y)
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.clearNotifs()
	H.endTurn()
	return r, nu
end

test("u14a F5: attacked in the AI phase, survived and seen alive, then moved and upgraded: relinked, not KILLED", function()
	local r, nu = FoughtThenUpgraded(nil)
	local rr = Rec(r.id)
	H.eq(rr.onMapUnitID, nu.id); H.eq(rr.combatSeq, 1); H.eq(rr.aliveSeq, 1)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

test("u14b F5 with F2 off: the tile rule relinks after the fight", function()
	local r, nu = FoughtThenUpgraded(NO_F2)
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.notnil(RelinkLine(r.id, "PlayerTurnStarted"))
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

test("u15 (rec 9) a fight it survives at T, a killing fight at T+1: KILLED; a host unit made on its tile is never taken", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	H.endTurn({ act = function(p) if p == 3 then H.combat(ENEMY, u, 30) end end })
	local x, y = u.x, u.y
	local bought
	H.endTurn({ act = function(p)
		if p == 3 then
			H.combat(ENEMY, u, 100)
			bought = H.unit(1, "UNIT_MAN_AT_ARMS", x, y, PROMO)
			GameEvents.UnitCreated(1, bought.id)
		end
	end })
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	H.isnil(RelinkLine(r.id, nil))
	H.ok(H.unitAlive(bought)); H.eq(bought:GetOwner(), 1)
	H.clean()
end)

-- ===========================================================================
-- u16-u21: the guard, re-entrancy, cost, save and load, flags off, repeats
-- ===========================================================================
test("u16a F6: AI host, the old object still listed (hint), then a long move: relinked at OnGameTurnEnded, never sent home", function()
	local S = Boot({ ghost = "live", offmap = false })
	FAKE.upgradeKeepsMoves = true
	local r, u = Lend(S)
	local nu
	H.endTurn({ act = function(p)
		if p == 1 then
			nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
			local to = FreeAt(nu.x, nu.y, 4)
			H.move(nu, to.x, to.y)
		end
	end })
	H.ok(H.hasLine("[Upgrade] hint id=" .. r.id))
	local rr = Rec(r.id)
	H.eq(rr.state, "DEPLOYED"); H.eq(rr.onMapUnitID, nu.id)
	H.ok(Has(RelinkLine(r.id, "OnGameTurnEnded"), "dist=4"))
	H.len(Sent(0, "RETURNING"), 0)
	H.clean()
end)

test("u16b F6: an upgrade found ambiguous this turn is a possible successor: an AI host's disband is lost, not sent home", function()
	local S = Boot({})
	local r, u = Lend(S)
	EditRecord(r.id, function(rec) rec.upgradeAmbiguousTurn = FAKE.turn end)
	FAKE.RemoveUnit(u, "DISBAND")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("[Disband] possible successor id=" .. r.id .. " n=1"))
	H.len(Sent(0, "RETURNING"), 0)
	H.clean()
end)

test("u16c F6: a plain AI disband with no upgrade still comes home", function()
	local S = Boot({})
	local r, u = Lend(S)
	FAKE.RemoveUnit(u, "DISBAND")
	H.endTurn()
	H.eq(Rec(r.id).returnReason, "DISBANDED")
	H.clean()
end)

test("u17 re-entrancy: an arrival's Create fires UnitCreated inside the pipeline: skipped, no hint, no extra commit", function()
	local S = Boot({})
	FAKE.createEvents = true
	local fired, handled = 0, 0
	GameEvents.UnitCreated.Add(function() fired = fired + 1 end)
	local orig = EFV_Lifecycle.OnUnitCreated
	EFV_Lifecycle.OnUnitCreated = function(...) handled = handled + 1; return orig(...) end
	local r = Lend(S)
	H.ok(fired >= 1, "the engine event fired for EFV's own Create")
	H.eq(handled, 0, "EFV's handler skipped it (Busy)")
	H.ok(not H.hasLine("[Upgrade]"))
	H.eq(Rec(r.id).state, "DEPLOYED")
	H.clean()
end)

test("u18 cost: 50 moves of untracked units read EFV_Rev only, never EFV_Records", function()
	local S = Boot({ mp = true })
	local r, u = Lend(S)
	local own = H.unit(1, "UNIT_WARRIOR", 40, 40)
	H.move(own, 40, 41)                          -- builds the index once
	FAKE.propReads = {}
	for i = 1, 50 do H.move(own, 40, 40 + (i % 2)) end
	H.isnil(FAKE.propReads["EFV_Records"], "no store load")
	H.eq(FAKE.propReads["EFV_Rev"], 50)
	H.clean()
end)

test("u19 save and load between the hint and the boundary: relinked", function()
	local S = Boot({ mp = true, ghost = "live" })
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.eq(Rec(r.id).upgradeHintID, nu.id)
	H.reloadEFV()
	H.endTurn()
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.clean()
end)

test("u20a all flags off: a disband next to a Ram is MERGED (1.0.4)", function()
	local S = Boot({ mp = true, support = -1, flags = OFF })
	local r, u = Lend(S)
	local p = FreeAt(u.x, u.y, 2)
	H.unit(1, "UNIT_BATTERING_RAM", p.x, p.y)
	FAKE.RemoveUnit(u, "DISBAND")
	H.clearNotifs()
	H.endTurn()
	H.len(Sent(0, "MERGED"), 1)
	H.clean()
end)

test("u20b all flags off: survived a fight, then moved and upgraded: KILLED (1.0.4)", function()
	local r = FoughtThenUpgraded(OFF)
	H.len(H.records(), 0)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), Locale.Lookup("LOC_EFV_LOSS_KILLED")))
	H.isnil(RelinkLine(r.id, nil))
	H.clean()
end)

test("u20c all flags off: an off-map corpse is KILLED by the marker only, no dead-object line (1.0.4)", function()
	local r = CorpseCase(OFF)
	H.ok(not H.hasLine("[Combat] dead unit object"))
	H.clean()
end)

test("u21 repeated UnitCreated / UnitInitialized events about the same unit change nothing (idempotent, same store)", function()
	local S = Boot({ mp = true, ghost = "ghost" })
	local r, u = Lend(S)
	H.endTurn()
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	local before = EFV_Records.Encode(EFV_Records.Load().recs)
	local rev = EFV_Records.Rev()
	for _ = 1, 3 do
		GameEvents.UnitCreated(1, nu.id)
		GameEvents.UnitInitialized(1, nu.id)
	end
	H.eq(EFV_Records.Encode(EFV_Records.Load().recs), before)
	H.eq(EFV_Records.Rev(), rev, "nothing committed")
	H.len(H.lines("[Upgrade] relink id=" .. r.id), 1)
	H.clean()
end)

-- ===========================================================================
-- u22-u24: UI, Volunteers, levies
-- ===========================================================================
test("u22 UI: the tracker's fallback tile is the move's tile (F1); after F2 the flag tag and the row follow the new unit at once", function()
	local S = Boot({ mp = true, ghost = "ghost" })
	include("fake_ui")
	FAKE_UI.Enable()
	include("EFV_UIShared")
	local r, u, nu, to
	FAKE_UI.AsGameplay(function()
		r, u = Lend(S)
		H.endTurn()
		to = FreeAt(u.x, u.y, 1)
		H.move(u, to.x, to.y)
	end)
	local rec = EFV_UI_RecordForUnit(1, u.id)
	H.notnil(rec); H.eq(rec.lastX, to.x); H.eq(rec.lastY, to.y)
	FAKE_UI.AsGameplay(function() nu = H.upgrade(u, "UNIT_MAN_AT_ARMS") end)
	local tag = EFV_UI_RecordForUnit(1, nu.id)
	H.notnil(tag, "the new unit's flag finds the record in the same turn")
	H.eq(tag.unitType, "UNIT_MAN_AT_ARMS")
	H.eq(EFV_UI_TrackedUnit(tag):GetID(), nu.id)
	H.isnil(EFV_UI_RecordForUnit(1, u.id))
	H.clean()
end)

test("u23 Volunteer (the sender's own unit): moved, then upgraded: relinked", function()
	local S = Boot({ ghost = "ghost" })
	local r, u = Lend(S, "UNIT_SWORDSMAN", PROMO, "VOLUNTEER")
	H.eq(u:GetOwner(), 0)
	local to = FreeAt(u.x, u.y, 1)
	H.move(u, to.x, to.y)
	local nu = H.upgrade(u, "UNIT_MAN_AT_ARMS")
	H.eq(Rec(r.id).onMapUnitID, nu.id); H.eq(Rec(r.id).forceType, "VOLUNTEER")
	H.endTurn()
	H.eq(Rec(r.id).onMapUnitID, nu.id)
	H.clean()
end)

test("u24 a levied City-State unit held by AI suzerain 2, upgraded in its turn: relinked with holder 2", function()
	local S = Boot({ ghost = "ghost" })
	local r = Lend(S, "UNIT_SWORDSMAN", PROMO, "CS_EXPEDITIONARY", 4, S.c4)
	Players[4].suzerain = 2
	H.levy(4, 2, 4)
	H.endTurn()
	local rr = Rec(r.id)
	H.eq(rr.onMapPlayerID, 2, "relinked to the levied copy")
	local lv = FAKE.units[rr.onMapUnitID]
	local nu
	H.endTurn({ act = function(p) if p == 2 then nu = H.upgrade(lv, "UNIT_MAN_AT_ARMS") end end })
	rr = Rec(r.id)
	H.eq(rr.onMapPlayerID, 2); H.eq(rr.onMapUnitID, nu.id); H.eq(rr.unitType, "UNIT_MAN_AT_ARMS")
	H.notnil(RelinkLine(r.id, "UnitCreated"))
	H.clean()
end)
