-- @harness native
-- End-to-end scenarios through the real hooks (GameEvents.EFV_Send, the
-- OnGameTurnStarted pipeline, PlayerTurnStartComplete, OnPlayerTurnEnded):
-- P1.1 send -> transit -> arrival, P1.3 expiry -> return, P1.2 forged
-- requests, P1.4 save/load + idempotency guard, P1.5 maintenance, P1.6 spawn
-- blocked, P1.7 destination lost (since 2026-09-30 a transit cancel, no
-- reroute; the full suite is test_transit_cancel.lua), return city lost,
-- unit killed.

local N = function(name) return "EFV_NOTIF_" .. name end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end

local function Veteran(x, y)
	return H.unit(0, "UNIT_SWORDSMAN", x or 11, y or 10,
		{ xp = 25, vet = "Brutus", promotions = { "PROMOTION_BATTLECRY" } })
end

-- ---------------------------------------------------------------------------
test("P1.1 + P1.3: send, transit, arrival, expiry, return (full lifecycle)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = Veteran()
	local uid = u.id
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 36)

	-- Send (turn 1)
	H.eq(H.gold(0), 964, "fee 36 (Swordsman, band 2: 10%, 0.5.2 ruling)")
	H.ok(not H.unitAlive(u), "unit removed")
	local r = Only()
	H.eq(r.state, "OUTBOUND"); H.eq(r.forceType, "EXPEDITIONARY")
	H.eq(r.senderID, 0); H.eq(r.recipientID, 1); H.eq(r.accessBasis, "ALLIANCE")
	H.eq(r.originCityID, S.c0.id); H.eq(r.destCityID, S.c1.id)
	H.eq(r.sentTurn, 1); H.eq(r.arrivalTurn, 3); H.eq(r.transitTurns, 2); H.eq(r.band, 2); H.eq(r.distance, 12)
	H.eq(r.feePaid, 36); H.eq(r.durationTurns, 20); H.eq(r.unitType, "UNIT_SWORDSMAN")
	H.eq(r.experience, 25); H.eq(r.veteranName, "Brutus"); H.deq(r.promotions, { "PROMOTION_BATTLECRY" })
	H.eq(#H.notifs(0, N("DEPARTED")), 1)
	H.ok(H.hasLine("[Send]"))

	-- Transit (turn 2): maintenance 2
	H.endTurn()
	H.eq(H.gold(0), 962, "maintenance 2")
	H.eq(Only().state, "OUTBOUND")
	H.ok(H.hasLine("[Maint]"))

	-- Arrival (turn 3): maintenance for the second transit turn, then spawn
	H.endTurn()
	r = Only()
	H.eq(r.state, "DEPLOYED"); H.eq(r.deployedTurn, 3); H.eq(r.maintGoldPaid, 4)
	H.eq(H.gold(0), 960)
	H.eq(r.onMapPlayerID, 1)
	local nu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(nu, "unit exists for the recipient")
	H.ne(nu:GetID(), uid)
	local d = Map.GetPlotDistance(S.c1.x, S.c1.y, nu:GetX(), nu:GetY())
	H.ok(d >= 1 and d <= 5, "spawned in ring 1-5 of the destination")
	H.deq(H.promotionTypes(nu), { "PROMOTION_BATTLECRY" })
	H.eq(nu:GetExperience():GetExperiencePoints(), 14) -- Session F T08 + FLAG_XP_CLAMP: level 1, XP clamped to 14
	H.eq(nu:GetExperience():GetVeteranName(), "Brutus")
	H.eq(nu:GetMovesRemaining(), 0, "exhausted at PlayerTurnStartComplete(1)")
	H.eq(#H.notifs(0, N("ARRIVED")), 1)
	H.ok(H.hasLine("[Arrival]"))

	-- Deployed: EXPIRY_SOON at turns 20 and 22, expiry at 23 (inside B's borders)
	H.turns(17)                                       -- turn 20
	H.eq(#H.notifs(0, N("EXPIRY_SOON")), 1)
	H.turns(2)                                        -- turn 22
	H.eq(#H.notifs(0, N("EXPIRY_SOON")), 2)
	H.endTurn()                                       -- turn 23
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED"); H.eq(r.arrivalTurn, 25)
	H.ok(not H.unitAlive(nu))
	H.eq(#H.notifs(0, N("RETURNING")), 1)
	local g = H.gold(0)

	-- Return transit (turns 24, 25), arrival home
	H.turns(2)
	H.eq(H.gold(0), g - 4, "maintenance also while returning")
	H.len(H.records(), 0, "record closed")
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	local hd = Map.GetPlotDistance(S.c0.x, S.c0.y, home[1]:GetX(), home[1]:GetY())
	H.ok(hd >= 1 and hd <= 5, "spawned around the origin city")
	H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" })
	H.eq(home[1]:GetExperience():GetVeteranName(), "Brutus")
	H.eq(home[1]:GetMovesRemaining(), 0)
	H.eq(#H.notifs(0, N("RETURNED")), 1)
	H.clean()
end)

-- ---------------------------------------------------------------------------
test("P1.2(g): forged send of a damaged unit is rejected", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { damage = 10 })
	H.send(0, u, 1, S.c1)
	H.ok(H.unitAlive(u)); H.eq(H.gold(0), 1000); H.len(H.records(), 0)
	H.ok(H.hasLine("reasons=DAMAGED"), "[Send] rejected reasons=DAMAGED")
	H.eq(#H.notifs(0, N("REQUEST_FAILED")), 1)
	H.clean()
end)

test("send rejected when the fee rose above expectedFee (FEE_CHANGED, DV5)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 35)
	H.len(H.records(), 0); H.eq(H.gold(0), 1000)
	H.ok(H.hasLine("FEE_CHANGED"))
end)

test("send rejected: not enough gold, no common war, enemy destination", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.setGold(0, 20)                                  -- fee 36
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.ok(H.hasLine("GOLD"))
	H.setGold(0, 1000)
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 11), 3, S.c3)
	H.ok(H.hasLine("NOT_PARTNER"))
	H.len(H.records(), 0)
	H.eq(#H.notifs(0, N("REQUEST_FAILED")), 2)
end)

test("send: requester must own the unit; AI requests are ignored", function()
	local S = H.baseScenario()
	H.loadEFV()
	local theirs = H.unit(1, "UNIT_SWORDSMAN", 22, 11)
	H.send(0, theirs, 1, S.c1)
	H.ok(H.unitAlive(theirs)); H.len(H.records(), 0)
	H.send(1, theirs, 0, S.c0)                       -- AI player 1 "asks"
	H.ok(H.unitAlive(theirs)); H.len(H.records(), 0)
	H.eq(#H.notifs(1), 0)
end)

test("send: destination given by plot must be a city (REQ_STALE)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.request(0, { OnStart = "EFV_Send", unitID = u.id, recipientID = 1, destX = 23, destY = 10,
		forceType = "EXPEDITIONARY", expectedFee = 500 })
	H.ok(H.unitAlive(u)); H.len(H.records(), 0)
	H.ok(H.hasLine("REQ_STALE"))
end)

-- ---------------------------------------------------------------------------
test("P1.4(c): pipeline runs once per turn (DV9 idempotency guard)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.endTurn()
	local g = H.gold(0)
	GameEvents.OnGameTurnStarted(FAKE.turn)           -- event re-fires for the same turn
	H.eq(H.gold(0), g, "no second maintenance charge")
	H.ok(H.hasLine("[Pipeline] skip"))
end)

test("P1.4(a): save/load while OUTBOUND keeps the arrival turn", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	EFV_Records.Dump(EFV_Records.Load())
	local before = H.lines("[Dump]")
	H.reloadEFV()
	H.markBody()
	EFV_Records.Dump(EFV_Records.Load())
	H.deq(H.lines("[Dump]"), before, "dump identical")
	H.turns(2)
	H.eq(Only().state, "DEPLOYED")
	H.eq(Only().deployedTurn, 3)
	H.clean()
end)

-- ---------------------------------------------------------------------------
test("P1.5: resource maintenance in transit, floored at 0", function()
	local S = H.baseScenario()
	H.loadEFV()
	local xp2 = GameInfo.Units_XP2["UNIT_TANK"]
	H.notnil(xp2); H.ok((xp2.ResourceMaintenanceAmount or 0) > 0, "tank needs oil")
	local res = xp2.ResourceMaintenanceType
	H.setRes(0, res, 3)
	H.setGold(0, 5000)
	H.send(0, H.unit(0, "UNIT_TANK", 11, 10), 2, S.c2)   -- band 4 to the friend (d = 40)
	local r = Only()
	H.eq(r.state, "OUTBOUND")
	local amt = xp2.ResourceMaintenanceAmount
	H.endTurn()
	H.eq(H.res(0, res), math.max(0, 3 - amt))
	H.endTurn()
	H.ok(H.res(0, res) >= 0, "never below 0")
	H.eq(H.res(0, res), math.max(0, 3 - 2 * amt))
end)

test("P1.5: gold maintenance never pushes the treasury negative", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.setGold(0, 1)
	H.endTurn()
	H.eq(H.gold(0), 0)
	H.endTurn()
	H.eq(H.gold(0), 0)
end)

-- ---------------------------------------------------------------------------
test("P1.6: spawn blocked -> SPAWN_BLOCKED each turn, arrival when a tile frees", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1b)   -- band 1 (d = 9)
	local r = Only()
	H.eq(r.band, 1)
	local blockers = {}
	for _, p in ipairs(Map.GetNeighborPlots(S.c1b.x, S.c1b.y, 5)) do
		if not (p:GetX() == S.c1b.x and p:GetY() == S.c1b.y) then
			blockers[#blockers + 1] = H.unit(1, "UNIT_WARRIOR", p:GetX(), p:GetY())
		end
	end
	H.endTurn()
	r = Only()
	H.eq(r.state, "OUTBOUND"); H.eq(r.spawnFailCount, 1)
	H.eq(#H.notifs(0, N("SPAWN_BLOCKED")), 1)
	local g = H.gold(0)
	H.endTurn()
	H.eq(#H.notifs(0, N("SPAWN_BLOCKED")), 2, "notified every turn")
	H.eq(H.gold(0), g - 2, "maintenance continues")
	H.killUnit(blockers[1])
	H.endTurn()
	H.eq(Only().state, "DEPLOYED")
	H.clean()
end)

test("P1.7: destination captured in transit -> transit cancelled, unit back on its tile, half the fee back, no REROUTED", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0, "cancelled at the next turn start")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), 11); H.eq(mine[1]:GetY(), 10)
	H.eq(H.gold(0), 1000 - 36 + 18, "refund 18, no upkeep on the cancel turn")
	H.eq(#H.notifs(0, N("REROUTED")), 0)
	H.eq(#H.notifs(0, N("RETURNED")), 1, "RETURNED _CANCELLED")
	H.ok(H.hasLine("reason=DEST_LOST code=OWNER"))
	H.clean()
end)

test("destination lost and recipient has no city left -> cancelled (DEST_LOST), unit on its tile", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	CityManager.TransferCity(S.c1b, 3, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1, "unit back at once")
	H.eq(mine[1]:GetX(), 11); H.eq(mine[1]:GetY(), 10)
	H.ok(H.hasLine("reason=DEST_LOST"))
	H.clean()
end)

test("return city lost while RETURNING -> nearest own city to the origin (10.1)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	FAKE.createNil = function() return true end      -- no tile anywhere: the cancel travels home (fallback B)
	H.endTurn()                                       -- now RETURNING to c0
	H.eq(Only().state, "RETURNING"); H.eq(Only().returnReason, "CANCELLED")
	FAKE.createNil = nil
	CityManager.TransferCity(S.c0, 3, CityTransferTypes.BY_COMBAT)
	H.turns(Only().arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.ok(Map.GetPlotDistance(S.c0b.x, S.c0b.y, home[1]:GetX(), home[1]:GetY()) <= 5, "around the other own city")
end)

-- ---------------------------------------------------------------------------
test("deployed unit killed in combat -> record deleted, UNIT_LOST to sender", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.turns(2)
	local r = Only()
	local nu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	local enemy = H.unit(3, "UNIT_SWORDSMAN", nu:GetX() + 1, nu:GetY())
	GameEvents.OnCombatOccurred(3, enemy.id, 1, nu.id, -1, -1)
	H.killUnit(nu)
	H.endTurn()
	H.len(H.records(), 0)
	H.eq(#H.notifs(0, N("UNIT_LOST")), 1)
end)

test("multi-record determinism: two sends, same seed -> same spawn plots", function()
	local first = true
	local function Run()
		for k in pairs(FAKE.props) do FAKE.props[k] = nil end
		FAKE.units, FAKE.cityList, FAKE.notifications = {}, {}, {}
		local S = H.baseScenario()
		if first then H.loadEFV() else H.reloadEFV() end
		first = false
		FAKE.rngSeed = 4242
		H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
		H.send(0, H.unit(0, "UNIT_WARRIOR", 11, 11), 1, S.c1)
		H.turns(2)
		local out = {}
		for _, r in ipairs(H.records()) do
			local u = Players[1]:GetUnits():FindID(r.onMapUnitID)
			out[#out + 1] = u:GetX() .. "," .. u:GetY()
		end
		return out
	end
	local a = Run()
	local b = Run()
	H.len(a, 2)
	H.deq(b, a)
end)
