-- @harness native
-- Self-tests of the fake engine (no EFV code): hex math, GameInfo, property
-- copy semantics and storage-rule checks, events, turn simulation. If these
-- fail, every other result is suspect.

test("hex distance: odd-r offset layout", function()
	H.world{ w = 20, h = 20, wrapX = false }
	H.eq(Map.GetPlotDistance(0, 0, 0, 0), 0)
	H.eq(Map.GetPlotDistance(5, 5, 9, 5), 4, "same row")
	H.eq(Map.GetPlotDistance(0, 0, 0, 1), 1, "even row NE neighbour is (x, y+1)")
	H.eq(Map.GetPlotDistance(0, 0, 1, 1), 2, "even row: (x+1, y+1) is two steps")
	H.eq(Map.GetPlotDistance(0, 1, 1, 2), 1, "odd row NE neighbour is (x+1, y+1)")
	H.eq(Map.GetPlotDistance(5, 5, 5, 11), 6, "straight column zig-zag")
	H.eq(Map.GetPlotDistance(2, 3, 7, 9), Map.GetPlotDistance(7, 9, 2, 3), "symmetric")
end)

test("hex distance: X wrap", function()
	H.world{ w = 84, h = 54 }  -- wrapX default true
	H.eq(Map.GetPlotDistance(1, 10, 82, 10), 3, "wraps across the date line")
	H.eq(Map.GetPlot(-1, 10):GetX(), 83, "GetPlot wraps x")
	H.isnil(Map.GetPlot(5, -1), "no y wrap")
end)

test("adjacency: 6 neighbours at distance 1, directions NE..NW", function()
	H.world{ w = 20, h = 20, wrapX = false }
	for _, c in ipairs({ { 5, 5 }, { 5, 6 } }) do
		local seen = {}
		for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
			local p = Map.GetAdjacentPlot(c[1], c[2], dir)
			H.notnil(p)
			H.eq(Map.GetPlotDistance(c[1], c[2], p:GetX(), p:GetY()), 1)
			H.isnil(seen[p:GetIndex()], "distinct")
			seen[p:GetIndex()] = true
		end
	end
	local ne = Map.GetAdjacentPlot(5, 5, DirectionTypes.DIRECTION_NORTHEAST)
	H.eq(ne:GetY(), 6, "north is +y")
end)

test("GetNeighborPlots returns the full disc, unsorted", function()
	H.world{ w = 30, h = 30, wrapX = false }
	for r = 1, 5 do
		H.len(Map.GetNeighborPlots(15, 15, r), 1 + 3 * r * (r + 1), "disc of radius " .. r)
	end
	local ps = Map.GetNeighborPlots(15, 15, 2)
	H.ok(ps[1]:GetIndex() > ps[#ps]:GetIndex(), "descending order (callers must sort)")
end)

test("areas: one-tile lake has area 1", function()
	H.world{ w = 20, h = 20, wrapX = false }
	H.terrain(10, 10, "LAKE")
	H.eq(H.plot(10, 10):GetArea():GetPlotCount(), 1)
	H.ok(H.plot(10, 10):IsLake() and H.plot(10, 10):IsWater())
	H.fill(0, 0, 4, 4, "OCEAN")
	H.eq(H.plot(0, 0):GetArea():GetPlotCount(), 25)
end)

test("GameInfo from the cached DB", function()
	H.world{}
	local sw = GameInfo.Units["UNIT_SWORDSMAN"]
	H.eq(sw.Cost, 90); H.eq(sw.Maintenance, 2); H.eq(sw.Domain, "DOMAIN_LAND")
	H.eq(GameInfo.Units[sw.Index], sw, "lookup by index")
	H.eq(GameInfo.Units[sw.Hash], sw, "lookup by hash")
	H.eq(GameInfo.Units["UNIT_GALLEY"].Cost, 65)
	H.eq(GameInfo.GameSpeeds["GAMESPEED_STANDARD"].CostMultiplier, 100)
	H.eq(tonumber(GameInfo.GlobalParameters["GOLD_PURCHASE_MULTIPLIER"].Value), 2)
	H.eq(tonumber(GameInfo.GlobalParameters["GOLD_EQUIVALENT_OTHER_YIELDS"].Value), 2)
	H.eq(type(sw.CanTrain), "boolean", "BOOLEAN columns are Lua booleans like the engine")
	local n = 0
	for row in GameInfo.UnitPromotions() do n = n + 1; H.eq(GameInfo.UnitPromotions[row.Index], row) end
	H.ok(n > 100, "promotions iterate")
	H.notnil(GameInfo.Types["EFV_NOTIF_DEPARTED"], "EFV notification types synthesised")
	H.eq(GameInfo.Maps["MAPSIZE_HUGE"].GridWidth, 106)
	H.eq(GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()].GameSpeedType, "GAMESPEED_STANDARD")
end)

test("Game properties: copy semantics and SPIKES S3 rule checks", function()
	H.world{}
	local t = { a = 1, list = { 1, 2, 3 } }
	Game:SetProperty("K", t)
	t.a = 99
	H.eq(Game:GetProperty("K").a, 1, "SetProperty copies")
	local r = Game:GetProperty("K")
	r.a = 5
	H.eq(Game:GetProperty("K").a, 1, "GetProperty returns a copy")
	H.len(FAKE.propViolations, 0)
	Game:SetProperty("BAD", { [0] = 1 })
	Game:SetProperty("BAD2", { 1, nil, 3 })
	Game:SetProperty("BAD3", { flag = true })
	H.len(FAKE.propViolations, 3, "key 0, hole, boolean reported")
end)

test("events: Add, fire, handler errors captured", function()
	H.world{}
	local got = {}
	GameEvents.EFV_Test.Add(function(a, b) got[#got + 1] = a + b end)
	GameEvents.EFV_Test.Add(function() error("boom") end)
	GameEvents.EFV_Test(2, 3)
	H.deq(got, { 5 })
	H.len(FAKE.handlerErrors, 1)
	FAKE.handlerErrors = {}
end, { allowErrors = true })

test("players: sorted IDs are NOT given by the engine", function()
	H.world{}
	local ids = PlayerManager.GetAliveIDs()
	H.ok(ids[1] > ids[#ids], "descending on purpose")
	H.ok(Players[0]:IsHuman() and Players[0]:IsMajor())
	H.ok(Players[63]:IsBarbarian())
	H.eq(PlayerManager.GetFreeCitiesPlayerID(), 62)
end)

test("diplomacy: war clears alliance, OB is directional", function()
	H.world{}
	H.ally(0, 1); H.openBorders(0, 1)
	H.ok(Players[0]:GetDiplomacy():HasAllied(1) and Players[1]:GetDiplomacy():HasAllied(0))
	-- HasOpenBordersFrom exists only in the UI context (Session A T09)
	H.isnil(Players[0]:GetDiplomacy().HasOpenBordersFrom, "nil in G")
	FAKE.context = "UI"
	H.ok(Players[0]:GetDiplomacy():HasOpenBordersFrom(1))
	H.ok(not Players[1]:GetDiplomacy():HasOpenBordersFrom(0))
	FAKE.context = "G"
	-- G reads it from the enacted deal (grantor = from-player; T19 pending)
	local deals = DealManager.GetPlayerDeals(0, 1)
	H.len(deals, 1)
	local item = deals[1]:FindItemByType(DealItemTypes.AGREEMENTS, DealAgreementTypes.OPEN_BORDERS, 1)
	H.eq(item:GetFromPlayerID(), 1); H.eq(item:GetToPlayerID(), 0)
	H.isnil(deals[1]:FindItemByType(DealItemTypes.AGREEMENTS, DealAgreementTypes.OPEN_BORDERS, 0))
	H.isnil(DealManager.GetPlayerDeals(0, 2), "no deal -> nil (Session A)")
	H.war(0, 1)
	H.ok(Players[1]:GetDiplomacy():IsAtWarWith(0))
	H.ok(not Players[0]:GetDiplomacy():HasAllied(1))
	H.isnil(DealManager.GetPlayerDeals(0, 1), "war ends open borders")
end)

test("units: create, find, destroy, damage death, xp", function()
	H.world{}
	local u = Players[0]:GetUnits():Create(GameInfo.Units["UNIT_SWORDSMAN"].Index, 5, 5)
	H.eq(Players[0]:GetUnits():FindID(u:GetID()), u)
	H.isnil(Players[1]:GetUnits():FindID(u:GetID()))
	H.eq(H.plot(5, 5):GetUnitCount(), 1)
	u:GetExperience():ChangeExperience(20)
	H.eq(u:GetExperience():GetExperiencePoints(), 15, "capped at the threshold (Session B / F T08)")
	H.eq(u:GetExperience():GetExperienceForNextLevel(), 15)
	u:GetExperience():SetPromotion(GameInfo.UnitPromotions["PROMOTION_BATTLECRY"].Index)
	H.isnil(u:GetExperience().GetLevel, "GetLevel is UI-only (Session A T09)")
	FAKE.context = "UI"
	H.eq(u:GetExperience():GetLevel(), 1, "a script-created unit stays level 1 (Session F T08)")
	FAKE.context = "G"
	H.eq(u:GetExperience():GetExperienceForNextLevel(), 15)
	local vet = H.unit(0, "UNIT_SWORDSMAN", 7, 7, { promotions = { "PROMOTION_BATTLECRY" } })
	H.eq(vet:GetExperience():GetExperienceForNextLevel(), 45, "a unit that earned its promotion is level 2")
	u:SetDamage(100)
	H.isnil(Players[0]:GetUnits():FindID(u:GetID()), "100 damage kills")
	local v = H.unit(0, "UNIT_WARRIOR", 6, 6)
	H.ok(Players[0]:GetUnits():Destroy(v))
	H.eq(FAKE.killLog[#FAKE.killLog].how, "DESTROY")
end)

test("cities: territory and transfer gives a new ID", function()
	H.world{}
	local c = H.city(1, 20, 20)
	H.eq(H.plot(21, 20):GetOwner(), 1)
	H.eq(CityManager.GetCityAt(20, 20), c)
	local oldID = c:GetID()
	H.ok(CityManager.TransferCity(c, 2, CityTransferTypes.BY_GIFT))
	local c2 = CityManager.GetCityAt(20, 20)
	H.eq(c2:GetOwner(), 2)
	H.ne(c2:GetID(), oldID)
	H.eq(H.plot(21, 20):GetOwner(), 2)
end)

test("turn simulation order = in-game order (Session C T04, Session E T26)", function()
	H.world{}
	local order = {}
	GameEvents.OnPlayerTurnEnded.Add(function(p) if p <= 1 then order[#order + 1] = "end" .. p end end)
	GameEvents.OnGameTurnEnded.Add(function(t) order[#order + 1] = "gte" .. t .. "@" .. Game.GetCurrentGameTurn() end)
	GameEvents.OnGameTurnStarted.Add(function(t) order[#order + 1] = "gts" .. t end)
	GameEvents.PlayerTurnStarted.Add(function(p) if p <= 1 then order[#order + 1] = "pts" .. p end end)
	GameEvents.PlayerTurnStartComplete.Add(function(p) if p <= 1 then order[#order + 1] = "psc" .. p end end)
	Events.TurnEnd.Add(function(t) order[#order + 1] = "te" .. t end)
	Events.TurnBegin.Add(function(t) order[#order + 1] = "tb" .. t end)
	-- End Turn in turn 1: the AI (1) plays turn 1, TurnEnd(1), then turn 2
	-- starts and the human (0) gets its start hooks. OnPlayerTurnEnded never.
	H.endTurn{ act = function(p, t) if p == 1 then order[#order + 1] = "act1@" .. t end end }
	H.deq(order, { "pts1", "psc1", "act1@1", "gte1@1", "te1", "gts2", "tb2", "pts0", "psc0" })
	H.eq(Game.GetCurrentGameTurn(), 2)
	order = {}
	H.endTurn{ legacyTurnEnded = true }
	H.deq(order, { "pts1", "psc1", "gte2@2", "te2", "end0", "end1", "gts3", "tb3", "pts0", "psc0" }, "legacy option")
	-- A second human (MP-like): all humans start after OnGameTurnStarted.
	Players[1].human = true
	order = {}
	H.endTurn()
	H.deq(order, { "gte3@3", "te3", "gts4", "tb4", "pts0", "psc0", "pts1", "psc1" }, "humans after the round start")
end)

test("round heal: after the last player (63), before OnGameTurnEnded; skips units created by script this turn (Session E)", function()
	H.world{}
	local old = H.unit(1, "UNIT_WARRIOR", 5, 5, { damage = 40 })
	local new = Players[1]:GetUnits():Create(GameInfo.Units["UNIT_WARRIOR"].Index, 7, 5)
	H.notnil(new); new.damage = 40
	local seen = {}
	GameEvents.PlayerTurnStartComplete.Add(function(p) if p == 63 then seen.psc63 = old.damage end end)
	GameEvents.OnGameTurnEnded.Add(function() seen.gte = old.damage end)
	H.endTurn{ heal = 15 }
	H.eq(seen.psc63, 40, "no heal before the last player's turn")
	H.eq(seen.gte, 25, "healed before OnGameTurnEnded")
	H.eq(new.damage, 40, "created this turn: no heal in its creation round")
	H.endTurn{ heal = 15 }
	H.eq(new.damage, 25, "heals from the next round")
	H.eq(old.damage, 10)
end)

test("fake Create: nil on a plot whose owner's borders are closed to the new owner (Session D 3)", function()
	H.world{}
	local p = H.plot(20, 20); p.owner = 2
	local idx = GameInfo.Units["UNIT_WARRIOR"].Index
	H.isnil(Players[1]:GetUnits():Create(idx, 20, 20), "closed")
	H.eq(FAKE.createRefused[1].why, "CLOSED_BORDERS")
	H.openBorders(1, 2)
	H.notnil(Players[1]:GetUnits():Create(idx, 20, 20), "open borders from the owner")
	local q = H.plot(22, 20); q.owner = 4
	H.notnil(UnitManager.InitUnit(1, "UNIT_WARRIOR", 22, 20), "city-state land")
end)

test("RNG deterministic, math.random flagged", function()
	H.world{}
	FAKE.rngSeed = 7
	local a = { Game.GetRandNum(10, "x"), Game.GetRandNum(10, "x") }
	FAKE.rngSeed = 7
	local b = { Game.GetRandNum(10, "x"), Game.GetRandNum(10, "x") }
	H.deq(a, b)
	math.random(3)
	H.len(FAKE.forbidden, 1)
	FAKE.forbidden = {}
end)
