-- @harness native
-- 0.7 integration (FIXPLAN_0.7 WP5 item 6): route B across the other flows
-- (a send while a restore job is open, a veteran that served an AI host and
-- comes home) and the S13 flow (a unit sent from B's land arrives and is
-- tracked). Route B is enabled explicitly (H.loadEFV{ routeB = true }).

local BATTLECRY, TORTOISE = "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE"

local function Jobs() return EFV_Records.Load().vet end

local function PromoNames(list)
	local out = {}
	for _, n in ipairs(list or {}) do out[#out + 1] = n end
	table.sort(out)
	return out
end

test("route B: a unit sent again while its restore job is open is settled first (fallback), the send snapshot keeps both promotions", function()
	local S = H.baseScenario()
	H.loadEFV{ routeB = true }
	local store = EFV_Records.Load()
	local u = EFV_Units.Recreate(store, 0, { id = 9, unitType = "UNIT_SWORDSMAN", promotions = { BATTLECRY, TORTOISE },
		experience = 50, xpNext = 90, level = 3, damage = 0, veteranName = "VEF-VET", formation = 0 }, H.plot(11, 10), FAKE.turn)
	EFV_Records.Commit(store)
	H.notnil(u)
	H.len(Jobs(), 1, "job open (no PROMOTE yet)")
	H.len(H.promotionTypes(u), 0)
	u.moves = u.maxMoves
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.record()
	H.notnil(r, "send accepted")
	H.eq(r.state, "OUTBOUND")
	H.deq(PromoNames(r.promotions), { BATTLECRY, TORTOISE }, "promotions in the snapshot")
	H.len(Jobs(), 0, "job closed before the snapshot")
	H.ok(H.hasLine("[Vet] fallback"), "settled by fallback")
	H.clean()
end)

test("route B: a veteran lent to an AI host gets the clamp there (no job), and a restore job when it comes home to you", function()
	local S = H.baseScenario()
	H.loadEFV{ routeB = true }
	local v = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { BATTLECRY }, xp = 20 })
	H.send(0, v, 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.record()
	H.turns(r.arrivalTurn - FAKE.turn)
	r = H.record()
	H.eq(r.state, "DEPLOYED")
	H.len(Jobs(), 0, "AI host: classic path, no job")
	local host = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.deq(H.promotionTypes(host), { BATTLECRY }, "SetPromotion on the AI host's copy")
	-- the service ends on the host's land -> home
	local store = EFV_Records.Load()
	local rec = EFV_Records.Get(store, r.id)
	rec.deployedTurn = FAKE.turn + 1 - rec.durationTurns
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	H.endTurn()
	r = H.record()
	H.eq(r.state, "RETURNING")
	H.turns(r.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0, "home")
	local jobs = Jobs()
	H.len(jobs, 1, "human owner: route B job")
	H.eq(jobs[1].p, 0)
	H.deq(jobs[1].want, { BATTLECRY })
	H.clean()
end)

test("S13 flow: the Spearman sent from B's land arrives at B's city and is tracked as B's Expeditionary unit", function()
	H.world({ turn = 2 })
	local c0 = H.city(0, 10, 10, { capital = true, name = "LOC_CITY_A" })
	H.city(0, 14, 20, { name = "LOC_CITY_A2" })
	local c1 = H.city(1, 22, 10, { capital = true, name = "LOC_CITY_B" })
	H.city(1, 18, 13, { name = "LOC_CITY_B2" })
	H.city(2, 40, 30, { capital = true, name = "LOC_CITY_F" })
	H.city(3, 70, 40, { capital = true, name = "LOC_CITY_C" })
	H.city(4, 30, 20, { capital = true, name = "LOC_CITY_CS" })
	H.loadEFV{ routeB = true }
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	local function Dev(cmd)
		H.request(0, { OnStart = "EFV_Dev", cmd = cmd, target = 1, unitOwner = -1, unitID = -1, cityOwner = -1, cityID = -1, x = -1, y = -1 })
	end
	Dev("scn_setup")
	Dev("scn_inland")
	local u = H.unitsOf(0, "UNIT_SPEARMAN")[1]
	H.notnil(u)
	H.send(0, u, 1, c1, "EXPEDITIONARY", 999)
	local r = H.record(#H.records())
	H.eq(r.unitType, "UNIT_SPEARMAN")
	H.eq(r.originX, c0.x, "origin = your city nearest to the unit"); H.eq(r.originY, c0.y)
	Dev("scn_arrive")
	H.endTurn()
	local rec = nil
	for _, x in ipairs(H.records()) do if x.unitType == "UNIT_SPEARMAN" then rec = x end end
	H.notnil(rec)
	H.eq(rec.state, "DEPLOYED"); H.eq(rec.onMapPlayerID, 1)
	H.ok(H.hasLine("[EFV][CHECK] FROM_LAND PASS"))
	H.ok(H.hasLine("[EFV][CHECK] ARRIVE PASS"))
	H.clean()
end)
