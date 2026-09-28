-- @harness native
-- Phase 5: spec 11 edge cases (PLAN 2.12, 5.5 WP5.1-5.4) and the D3 merge
-- warnings, end to end on the fake engine in the confirmed in-game hook order.
-- One section per spec 11 row / PLAN 2.12 row; earlier phases already cover
-- some rows (see EFV/TESTING_PHASE5.md, "Row -> test map"); the tests here
-- add the force types and branches those did not reach.
-- Scenario (H.baseScenario): 0 human (cities (10,10) capital, (14,20)),
-- 1 ally B (cities (22,10) capital, (18,13)), 2 friend F (40,30), 3 enemy C
-- (at war with 0, 1, 2 and the city-state), 4 city-state (30,20).

local N = function(name) return "EFV_NOTIF_" .. name end
local VOL, CS = "VOLUNTEER", "CS_EXPEDITIONARY"

local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end
local function Sent(pid, name)
	return H.notifs(pid, N(name))
end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] or "" end
local function Has(text, key, ...)
	return text ~= nil and string.find(text, Locale.Lookup(key, ...), 1, true) ~= nil
end

local function MyUnit(x, y)
	return H.unit(0, "UNIT_SWORDSMAN", x or 11, y or 10, { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 })
end

-- Sends a unit of player 0 and plays until it arrives. Returns the record and
-- the on-map unit.
local function Deploy(S, forceType, recipient, city, unit)
	recipient = recipient or 1
	local u = unit or MyUnit()
	H.send(0, u, recipient, city or S.c1, forceType or "EXPEDITIONARY", 999)
	local r = H.records()[#H.records()]
	H.notnil(r, "send accepted")
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Rec(r.id)
	H.eq(r.state, "DEPLOYED")
	return r, FAKE.units[r.onMapUnitID]
end

-- Engine elimination (Session D 4): the units vanish with the last city, then
-- the player is dead.
local function Eliminate(pid)
	for _, u in ipairs(H.unitsOf(pid)) do H.killUnit(u) end
	H.kill(pid)
end

-- A free land plot at exactly distance d from (x, y) with no units.
local function FreeAt(x, y, d)
	for _, p in ipairs(Map.GetNeighborPlots(x, y, d)) do
		if Map.GetPlotDistance(x, y, p.x, p.y) == d and not p:IsWater() and not p:IsImpassable()
			and p:GetUnitCount() == 0 and not p:IsCity() then
			return p
		end
	end
	error("no free plot at distance " .. d)
end

local CORPS = function() return MilitaryFormationTypes.CORPS_FORMATION end
local ARMY = function() return MilitaryFormationTypes.ARMY_FORMATION end
local STANDARD = function() return MilitaryFormationTypes.STANDARD_FORMATION end

-- ===========================================================================
-- Spec 11 row 1: sender and recipient go to war
-- ===========================================================================
test("row 1 EXP: B declares war during its own turn -> reverted at the next boundary of the SAME round (DV16)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local x, y = u:GetX(), u:GetY()
	local turnOfWar
	H.endTurn({ act = function(p, T)
		if p == 1 then H.war(1, 0); turnOfWar = T end
		if p == 2 then
			-- PTS(2) came after B's action: the unit is already the sender's.
			H.len(H.records(), 0, "reverted before F's turn")
		end
	end })
	H.eq(#H.unitsOf(0, "UNIT_SWORDSMAN"), 1)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	H.eq(mine:GetX(), x); H.eq(mine:GetY(), y)
	H.eq(mine.xp, 14); H.deq(H.promotionTypes(mine), { "PROMOTION_BATTLECRY" }) -- Session F T08 + FLAG_XP_CLAMP: a restored unit is level 1, XP above the first threshold (15) is lost (clamped to 14)
	H.len(Sent(0, "REVERTED"), 1)
	H.ok(Has(Summary(Sent(0, "REVERTED")[1]), "LOC_EFV_NOTIF_REVERTED_SUMMARY",
		EFV_UnitDisplayName("UNIT_SWORDSMAN", nil), EFV_PlayerName(0), EFV_PlayerName(1)))
	H.clean()
end)

test("row 1 EXP: the unit's tile is taken -> nearest valid tile by the spawn search around it", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S)
	local x, y = u:GetX(), u:GetY()
	H.unit(1, "UNIT_BUILDER", x, y)                  -- a civilian of B shares the tile
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.ok(Map.GetPlotDistance(x, y, mine[1]:GetX(), mine[1]:GetY()) >= 1, "not on the occupied tile")
	H.ok(Map.GetPlotDistance(x, y, mine[1]:GetX(), mine[1]:GetY()) <= EFV_Config.SPAWN_SEARCH_MAX_RING)
	H.len(Sent(0, "REVERTED"), 1); H.len(Sent(1, "REVERTED"), 1, "both players")
	H.clean()
end)

test("row 1 EXP: no tile at all (every Create refused) -> return trip instead (DV15)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = Deploy(S)
	H.war(0, 1)
	FAKE.createNil = function() return true end
	H.endTurn()
	FAKE.createNil = nil
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "WAR")
	H.isnil(rr.onMapUnitID)
	H.len(H.unitsOf(1, "UNIT_SWORDSMAN"), 0, "taken from the recipient")
	H.turns(rr.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1, "back home")
	H.eq(H.unitsOf(0, "UNIT_SWORDSMAN")[1].xp, 14) -- Session F T08 + FLAG_XP_CLAMP: a restored unit is level 1, XP above the first threshold (15) is lost (clamped to 14)
	H.clean()
end)

test("row 1 EXP: war while in MUTINY -> reverted (mutiny ends, damage kept)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	EditRecord(r.id, function(rec) rec.state = "MUTINY"; rec.lastDamage = 40 end)
	u.damage = 40
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1); H.eq(mine[1].damage, 40)
	H.len(Sent(0, "MUTINY_DEATH"), 0)
	H.clean()
end)

test("row 1: a RETURNING record ignores the war and still arrives home", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	EditRecord(r.id, function(rec) rec.deployedTurn = FAKE.turn - 20 end)
	H.endTurn()                                      -- expiry inside B's land -> RETURNING
	local rr = Only()
	H.eq(rr.state, "RETURNING")
	H.war(0, 1)
	H.turns(rr.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0)
	H.len(Sent(0, "RETURNED"), 1)
	H.len(Sent(0, "REVERTED"), 0)
	H.clean()
end)

test("row 1 VOL + CS in transit: both return (WAR); VOL deployed closes (DV6)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local rv, uv = Deploy(S, VOL)
	H.send(0, MyUnit(12, 10), 1, S.c1, VOL, 999)
	H.send(0, MyUnit(10, 11), 4, S.c4, CS, 999)
	local ids = {}
	for _, rec in ipairs(H.records()) do ids[rec.forceType .. rec.state] = rec.id end
	H.war(0, 1); H.war(0, 4)
	H.endTurn()
	H.isnil(Rec(rv.id), "deployed Volunteer record closed (DV6)")
	H.ok(H.unitAlive(uv)); H.eq(uv.owner, 0)
	H.eq(Rec(ids["VOLUNTEEROUTBOUND"]).returnReason, "WAR")
	H.eq(Rec(ids["CS_EXPEDITIONARYOUTBOUND"]).returnReason, "WAR")
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 2: the war requirement lapses
-- ===========================================================================
test("row 2: common war ends -> EXP and CS timers continue unchanged; a Volunteer lapses", function()
	local S = H.baseScenario()
	H.loadEFV()
	local re = Deploy(S)
	local rc = Deploy(S, CS, 4, S.c4, MyUnit(10, 11))
	local rv = Deploy(S, VOL, 1, S.c1, MyUnit(12, 10))
	H.peace(3, 0); H.peace(3, 1); H.peace(3, 4)      -- no common enemy left
	H.endTurn()
	H.eq(Rec(re.id).state, "DEPLOYED"); H.eq(Rec(re.id).deployedTurn, re.deployedTurn)
	H.eq(Rec(rc.id).state, "DEPLOYED"); H.eq(Rec(rc.id).durationTurns, 10)
	H.eq(Rec(rv.id).state, "GRACE"); H.eq(Rec(rv.id).lapseReason, "WAR")
	H.len(Sent(0, "VOLUNTEER_LAPSE"), 1)
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 3: alliance / friendship ends without war
-- ===========================================================================
test("row 3: EXP to a friend: friendship ends -> no effect; Volunteer (Q3) lapses PARTNER", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.openBorders(0, 2)
	local re = Deploy(S, "EXPEDITIONARY", 2, S.c2)
	local rv = Deploy(S, VOL, 2, S.c2, MyUnit(12, 10))
	H.eq(Rec(rv.id).accessBasis, "FRIEND_OB")
	H.friend(0, 2, false)
	H.endTurn()
	H.eq(Rec(re.id).state, "DEPLOYED", "Expeditionary: no effect")
	H.eq(Rec(rv.id).state, "GRACE"); H.eq(Rec(rv.id).lapseReason, "PARTNER")
	H.len(Sent(0, "ACCESS_LAPSE"), 1)
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 4: recipient eliminated
-- ===========================================================================
test("row 4 EXP: eliminated during another AI's turn -> returned from the latest boundary snapshot", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	H.endTurn({ act = function(p)
		if p == 1 then u.xp = 45 end                 -- gained during B's own turn
		if p == 3 then Eliminate(1) end              -- C takes B's last city
	end })
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "RECIPIENT_GONE")
	H.eq(rr.experience, 45, "snapshot taken at PTS(2), after B acted")
	H.len(Sent(0, "UNIT_LOST"), 0, "not DISBANDED")
	H.turns(rr.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1); H.eq(home[1].xp, 14) -- Session F T08 + FLAG_XP_CLAMP: a restored unit is level 1, XP above the first threshold (15) is lost (clamped to 14)
	H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" })
	H.clean()
end)

test("row 4 EXP: GameEvents.CityConquered takes a last-moment snapshot of the old owner's units (S9)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	H.endTurn({ act = function(p)
		if p == 3 then
			u.xp = 60                                -- after the last per-player boundary
			GameEvents.CityConquered(3, 1, S.c1.id, S.c1.x, S.c1.y)
			Eliminate(1)
		end
	end })
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.experience, 60)
	H.ok(H.hasLine("[Snapshot] CityConquered capturer=3 oldOwner=1 city=" .. S.c1.id))
	H.ok(H.hasLine("records=1 found=1"))
	H.clean()
end)

test("row 4 EXP in MUTINY: recipient gone -> returns (mutiny ends); damage from the snapshot", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	EditRecord(r.id, function(rec) rec.state = "MUTINY"; rec.lastDamage = 60 end)
	u.damage = 60
	H.endTurn({ act = function(pid) if pid == 3 then Eliminate(1) end end })
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.damage, 60)
	H.isnil(rr.graceTurnsLeft); H.isnil(rr.lastDamage)
	H.len(Sent(0, "MUTINY_DEATH"), 0)
	H.clean()
end)

test("row 4 EXP: sender has no city left -> lost (UNIT_LOST NO_CITY) to the sender only", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r = Deploy(S)
	CityManager.TransferCity(S.c0, 3, CityTransferTypes.BY_COMBAT)
	CityManager.TransferCity(S.c0b, 3, CityTransferTypes.BY_COMBAT)
	Eliminate(1)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), "LOC_EFV_LOSS_NO_CITY"))
	H.len(Sent(1, "UNIT_LOST"), 0, "the eliminated recipient gets nothing")
	H.clean()
end)

test("row 4 EXP: no unit and no usable snapshot -> lost (UNIT_LOST RECIPIENT_GONE)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = Deploy(S)
	EditRecord(r.id, function(rec) rec.unitType = "UNIT_DOES_NOT_EXIST" end)
	Eliminate(1)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), "LOC_EFV_LOSS_RECIPIENT_GONE"))
	H.ok(H.hasLine("no usable snapshot"))
	H.clean()
end)

test("row 4: OUTBOUND Volunteer returns; deployed Volunteer is the sender's and lapses; RETURNING unaffected", function()
	local S = H.baseScenario()
	H.loadEFV()
	local rv, uv = Deploy(S, VOL)
	local re = Deploy(S, "EXPEDITIONARY", 1, S.c1, MyUnit(12, 10))
	EditRecord(re.id, function(rec) rec.deployedTurn = FAKE.turn - 20 end)
	H.endTurn()
	H.eq(Rec(re.id).state, "RETURNING", "expired and returning")
	H.send(0, MyUnit(10, 11), 1, S.c1, VOL, 999)
	local outID = H.records()[#H.records()].id
	Eliminate(1)
	H.ok(H.unitAlive(uv), "the sender's Volunteer is not removed with B")
	H.endTurn()
	H.eq(Rec(outID).state, "RETURNING"); H.eq(Rec(outID).returnReason, "RECIPIENT_GONE")
	H.eq(Rec(rv.id).state, "GRACE", "lapse: B is no eligible partner any more")
	H.eq(Rec(rv.id).lapsed, 1)
	H.eq(Rec(re.id).state, "RETURNING"); H.ne(Rec(re.id).returnReason, "RECIPIENT_GONE")
	H.clean()
end)

test("row 4: Events.PlayerDefeat hint only logs (no store write, no async change)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = Deploy(S)
	Eliminate(1)
	local rev = H.prop(EFV_Config.PROP.REV)
	Events.PlayerDefeat(1, 0, 4711)
	H.eq(H.prop(EFV_Config.PROP.REV), rev, "nothing committed by the async hint")
	H.eq(Rec(r.id).state, "DEPLOYED", "handled by step 0b, not by the hint")
	H.ok(H.hasLine("[Defeat] hint pid=1 alive=false records: sender=0 recipient=1 onMap=1"))
	H.endTurn()
	H.eq(Rec(r.id).state, "RETURNING")
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 5: sender eliminated
-- ===========================================================================
test("row 5: sender eliminated -> EXP (even in MUTINY) stays with the recipient; in-transit and returning records deleted", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r1, u1 = Deploy(S)
	local r2 = Deploy(S, "EXPEDITIONARY", 1, S.c1, MyUnit(12, 10))
	local u2 = FAKE.units[r2.onMapUnitID]
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u2, p:GetX(), p:GetY())
	EditRecord(r2.id, function(rec) rec.state = "MUTINY"; rec.lastDamage = 20 end)
	u2.damage = 20
	H.send(0, MyUnit(10, 11), 1, S.c1, "EXPEDITIONARY", 999)   -- OUTBOUND
	local r3 = Deploy(S, "EXPEDITIONARY", 1, S.c1, MyUnit(9, 10))
	EditRecord(r3.id, function(rec) rec.deployedTurn = FAKE.turn - 20 end)
	H.endTurn()
	H.eq(Rec(r3.id).state, "RETURNING")
	u2.damage = 20; EditRecord(r2.id, function(rec) rec.lastDamage = 20 end)
	local gold1 = H.gold(0)
	Eliminate(0)
	H.endTurn()
	H.len(H.records(), 0, "every record of the dead sender deleted")
	H.ok(H.unitAlive(u1)); H.eq(u1.owner, 1)
	H.ok(H.unitAlive(u2)); H.eq(u2.owner, 1); H.eq(u2.damage, 20, "mutiny stopped")
	H.eq(H.gold(0), gold1, "no transit maintenance charged to a dead sender")
	H.clean()
end)

test("row 5 VOL: the engine removes the sender's Volunteers; records deleted without errors", function()
	local S = H.baseScenario()
	H.loadEFV()
	Deploy(S, VOL)
	Eliminate(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

-- ===========================================================================
-- Spec 11 rows 6-7: unit killed / disbanded
-- ===========================================================================
test("rows 6-7: EXP disbanded -> UNIT_LOST (DISBANDED); CS killed -> UNIT_LOST (KILLED); VOL killed -> silent", function()
	local S = H.baseScenario()
	H.loadEFV()
	local re, ue = Deploy(S)
	local rc, uc = Deploy(S, CS, 4, S.c4, MyUnit(10, 11))
	local rv, uv = Deploy(S, VOL, 1, S.c1, MyUnit(12, 10))
	GameEvents.OnCombatOccurred(3, 999, 4, uc.id, 0, 0)
	GameEvents.OnCombatOccurred(3, 998, 0, uv.id, 0, 0)
	FAKE.RemoveUnit(ue, "DISBAND")
	H.killUnit(uc); H.killUnit(uv)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	local lost = Sent(0, "UNIT_LOST")
	H.len(lost, 2, "EXP and CS only")
	local texts = Summary(lost[1]) .. Summary(lost[2])
	H.ok(Has(texts, "LOC_EFV_LOSS_DISBANDED")); H.ok(Has(texts, "LOC_EFV_LOSS_KILLED"))
	H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 8: merged into a Corps / Army (D3)
-- ===========================================================================
test("row 8 EXP survivor: record kept, MERGED to both, returns alone at expiry with XP and promotions", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S)
	u:SetMilitaryFormation(CORPS())
	H.endTurn()
	local rr = Only()
	H.eq(rr.state, "DEPLOYED"); H.eq(rr.formation, CORPS()); H.notnil(rr.mergedTurn)
	H.len(Sent(0, "MERGED"), 1); H.len(Sent(1, "MERGED"), 1)
	H.ok(Has(Summary(Sent(1, "MERGED")[1]), "LOC_EFV_NOTIF_MERGED_SURVIVOR_SUMMARY",
		EFV_UnitDisplayName("UNIT_SWORDSMAN", nil), EFV_PlayerName(0), EFV_PlayerName(1)))
	H.endTurn()
	H.len(Sent(0, "MERGED"), 1, "notified once per formation change")
	u:SetMilitaryFormation(ARMY())
	u.xp = 50
	H.endTurn()
	H.len(Sent(0, "MERGED"), 2, "Corps -> Army notifies again")
	EditRecord(r.id, function(rec) rec.deployedTurn = FAKE.turn - 20 end)
	H.endTurn()                                      -- expiry on B's land -> return
	rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "EXPIRED")
	H.turns(rr.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.eq(home[1]:GetMilitaryFormation(), STANDARD(), "a single unit: the formation is not kept")
	H.eq(home[1].xp, 14); H.deq(H.promotionTypes(home[1]), { "PROMOTION_BATTLECRY" }) -- Session F T08 + FLAG_XP_CLAMP: a restored unit is level 1, XP above the first threshold (15) is lost (clamped to 14)
	H.clean()
end)

test("row 8 EXP survivor then war: reverted as a single unit", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	u:SetMilitaryFormation(CORPS())
	H.endTurn()
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1); H.eq(mine[1]:GetMilitaryFormation(), STANDARD())
	H.clean()
end)

test("row 8 EXP absorbed into the recipient's Corps (moved first) -> MERGED ABSORBED to both, record closed", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S)
	local p = FreeAt(u:GetX(), u:GetY(), 3)          -- BaseMoves 2 + 1: moved 2, merged next door
	H.unit(1, "UNIT_SWORDSMAN", p.x, p.y, { formation = CORPS() })
	FAKE.RemoveUnit(u, "MERGE")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "MERGED"), 1); H.len(Sent(1, "MERGED"), 1)
	H.ok(Has(Summary(Sent(0, "MERGED")[1]), "LOC_EFV_NOTIF_MERGED_ABSORBED_SUMMARY",
		EFV_UnitDisplayName("UNIT_SWORDSMAN", nil), EFV_PlayerName(0), EFV_PlayerName(1)))
	H.len(Sent(0, "UNIT_LOST"), 0, "reported as absorbed, not disbanded")
	H.ok(H.hasLine("[Merge] absorbed id=" .. r.id))
	H.clean()
end)

test("row 8: a Corps farther than the search radius -> DISBANDED (UNIT_LOST), not absorbed", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local far = FreeAt(u:GetX(), u:GetY(), 5)       -- radius = BaseMoves 2 + 1 = 3
	H.unit(1, "UNIT_SWORDSMAN", far.x, far.y, { formation = CORPS() })
	FAKE.RemoveUnit(u, "DISBAND")
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), "LOC_EFV_LOSS_DISBANDED"))
	H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

test("row 8: a combat marker wins over a Corps next door -> KILLED (UNIT_LOST)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local near = FreeAt(u:GetX(), u:GetY(), 1)
	H.unit(1, "UNIT_ARCHER", near.x, near.y, { formation = CORPS() })
	GameEvents.OnCombatOccurred(3, 999, 1, u.id, 0, 0)
	H.killUnit(u)
	H.clearNotifs()
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(Has(Summary(Sent(0, "UNIT_LOST")[1]), "LOC_EFV_LOSS_KILLED"))
	H.len(Sent(0, "MERGED"), 0)
	H.clean()
end)

local function TwoTrackedMerge(survivorFirst)
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local ra, ua = Deploy(S)
	local rb, ub = Deploy(S, "EXPEDITIONARY", 1, S.c1, MyUnit(12, 10))
	H.ok(Map.GetPlotDistance(ua.x, ua.y, ub.x, ub.y) <= 3)
	local survivor, absorbed, sRec, aRec = ua, ub, ra, rb
	if not survivorFirst then survivor, absorbed, sRec, aRec = ub, ua, rb, ra end
	survivor:SetMilitaryFormation(CORPS())
	FAKE.RemoveUnit(absorbed, "MERGE")
	H.clearNotifs()
	H.endTurn()
	H.notnil(Rec(sRec.id), "survivor record kept")
	H.eq(Rec(sRec.id).formation, CORPS())
	H.isnil(Rec(aRec.id), "absorbed record closed")
	H.len(Sent(0, "MERGED"), 2, "survivor + absorbed")
	H.len(Sent(1, "MERGED"), 2)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end
test("row 8: two tracked EXP units merged together (survivor has the lower record ID)", function() TwoTrackedMerge(true) end)
test("row 8: two tracked EXP units merged together (survivor has the higher record ID)", function() TwoTrackedMerge(false) end)

test("row 8: step 0c alone (no boundary in between) still pairs the absorbed unit with an unhandled survivor", function()
	local S = H.baseScenario()
	H.loadEFV()
	local ra, ua = Deploy(S)
	local rb, ub = Deploy(S, "EXPEDITIONARY", 1, S.c1, MyUnit(12, 10))
	-- ra (lower ID) absorbed, rb survived; RefreshTrackedUnits sees ra first.
	ub:SetMilitaryFormation(CORPS())
	FAKE.RemoveUnit(ua, "MERGE")
	local store = EFV_Records.Load()
	EFV_Lifecycle.RefreshTrackedUnits(store, FAKE.turn)
	EFV_Records.Commit(store)
	H.isnil(Rec(ra.id)); H.eq(Rec(rb.id).formation, CORPS())
	H.ok(H.hasLine("[Merge] absorbed id=" .. ra.id))
	H.ok(H.hasLine("[Merge] survivor id=" .. rb.id))
	H.clean()
end)

test("row 8: scripted formation change of an UNTRACKED unit changes no record (Session D 7)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, u = Deploy(S)
	local other = H.unit(1, "UNIT_ARCHER", 25, 12)
	other:SetMilitaryFormation(CORPS())
	Events.UnitFormCorps(1, other.id)
	H.endTurn()
	H.eq(Only().state, "DEPLOYED"); H.eq(Only().formation, STANDARD())
	H.len(Sent(0, "MERGED"), 0)
	H.eq(#(Events.UnitFormCorps.handlers or {}), 0, "gameplay does not subscribe to UnitFormCorps")
	H.clean()
end)

-- ===========================================================================
-- Spec 11 row 9: destination lost in transit (spec 7.3)
-- ===========================================================================
test("row 9 VOL: destination captured -> rerouted to the recipient's nearest city, same arrival turn", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, MyUnit(), 1, S.c1, VOL, 999)
	local r = Only()
	local arrival = r.arrivalTurn
	CityManager.TransferCity(S.c1, 3, CityTransferTypes.BY_COMBAT)
	H.turns(arrival - FAKE.turn)
	local rr = Only()
	H.eq(rr.state, "DEPLOYED"); H.eq(rr.deployedTurn, arrival, "no transit recalculation")
	H.eq(rr.destX, S.c1b.x); H.eq(rr.destY, S.c1b.y); H.eq(rr.rerouted, 1)
	H.eq(FAKE.units[rr.onMapUnitID].owner, 0, "Volunteers stay the sender's")
	H.len(Sent(0, "REROUTED"), 1)
	H.clean()
end)

test("row 9 CS: the city-state's only city captured -> return (DEST_LOST) from the lost city", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, MyUnit(), 4, S.c4, CS, 999)
	local r = Only()
	CityManager.TransferCity(S.c4, 3, CityTransferTypes.BY_COMBAT)
	H.turns(r.arrivalTurn - FAKE.turn)
	local rr = Only()
	H.eq(rr.state, "RETURNING"); H.eq(rr.returnReason, "DEST_LOST")
	H.eq(rr.arrivalTurn, FAKE.turn + EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y), "band from the lost city")
	H.clean()
end)

-- ===========================================================================
-- PLAN 2.12 (added): unit upgraded by the recipient
-- ===========================================================================
-- Session F T30: the upgrade creates a new unit (new ID) on the same plot; the
-- old object stays findable until OnGameTurnEnded (FAKE.UpgradeUnit).
local function UpgradeInPlace(u, pid)
	local to = GameInfo.UnitUpgrades["UNIT_SWORDSMAN"].UpgradeUnit
	return H.upgrade(u, to), to
end

local function UpgradeCase(on)
	local S = H.baseScenario()
	H.loadEFV({ flags = { FLAG_UPGRADE_RELINK = on } })
	local r, u = Deploy(S)
	local nu, to = UpgradeInPlace(u, 1)
	H.clearNotifs()
	H.endTurn()
	if on then
		local rr = Only()
		H.eq(rr.onMapUnitID, nu.id); H.eq(rr.unitType, to)
		H.len(Sent(0, "UNIT_LOST"), 0)
		H.ok(H.hasLine("[Upgrade] relink id=" .. r.id))
	else
		H.len(H.records(), 0)
		H.len(Sent(0, "UNIT_LOST"), 1)
	end
	H.clean()
end
test("upgrade: FLAG_UPGRADE_RELINK on -> an upgrade with a NEW unit ID is relinked (type follows)", function() UpgradeCase(true) end)
test("upgrade: FLAG_UPGRADE_RELINK off (the pre-0.5.2 default) -> a new-ID upgrade reads as DISBANDED", function() UpgradeCase(false) end)

test("upgrade relink never takes an untracked twin of the SAME type", function()
	local S = H.baseScenario()
	H.loadEFV({ flags = { FLAG_UPGRADE_RELINK = true } })
	local r, u = Deploy(S)
	local p = FreeAt(u:GetX(), u:GetY(), 1)
	H.unit(1, "UNIT_SWORDSMAN", p.x, p.y)
	FAKE.RemoveUnit(u, "DISBAND")
	H.endTurn()
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.clean()
end)

-- ===========================================================================
-- WP5.4: status / merge-warning button and UI hints
-- ===========================================================================
local function BootUI(S)
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	return FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
end
local function Buttons(actions, u)
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(u:GetOwner(), u:GetID(), 0, 0, 0, true, false)
	FAKE_UI.Frame(actions)
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_ActionInstance" then return im.list end
	end
	return {}
end

test("UI: recipient selecting a lent EXP unit sees the status button with the EXP merge warning", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S)
	local actions = BootUI(S)
	FAKE.localPlayer = 1
	local list = Buttons(actions, u)
	H.len(list, 1, "status only: no send buttons for a tracked unit")
	local b = list[1].UnitActionButton
	H.ok(not b.disabled)
	H.eq(list[1].UnitActionIcon.icon, "ICON_UNITCOMMAND_FORM_CORPS")
	H.ok(Has(b.tooltip, "LOC_EFV_ACTION_STATUS"))
	H.ok(Has(b.tooltip, "LOC_EFV_WARN_MERGE_HEADER"))
	H.ok(Has(b.tooltip, "LOC_EFV_WARN_MERGE_EXPEDITIONARY"), b.tooltip)
	H.ok(not Has(b.tooltip, "LOC_EFV_STATUS_MERGED_SURVIVOR"))
	H.ok(string.find(b.tooltip, EFV_UI_StatusTooltip(EFV_UI_RecordForUnit(1, u.id)), 1, true) ~= nil, "status text")
	b:Click()
	H.len(FAKE_UI.requests, 0, "no request: the button only informs")
	-- After a merge (gameplay recorded the survivor) the status says so.
	FAKE_UI.AsGameplay(function()
		u:SetMilitaryFormation(CORPS())
		H.endTurn()
	end)
	b = Buttons(actions, u)[1].UnitActionButton
	H.ok(Has(b.tooltip, "LOC_EFV_STATUS_MERGED_SURVIVOR"), b.tooltip)
	H.clean()
end)

test("UI: sender's Volunteer shows the VOL warning; a reused slot or a foreign viewer shows no status", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r, u = Deploy(S, VOL)
	local actions = BootUI(S)
	FAKE.localPlayer = 0
	local list = Buttons(actions, u)
	H.len(list, 2, "Recall + status")
	H.ok(Has(list[2].UnitActionButton.tooltip, "LOC_EFV_WARN_MERGE_VOLUNTEER"))
	H.ok(not Has(list[2].UnitActionButton.tooltip, "LOC_EFV_WARN_MERGE_EXPEDITIONARY"))
	-- The unit is gone and its slot reused by a new unit of the sender:
	-- the stale record must not decorate the new unit.
	local x, y = u:GetX(), u:GetY()
	FAKE_UI.AsGameplay(function() FAKE.RemoveUnit(u, "DISBAND") end)
	local nu = H.unitInSlot(u, 0, "UNIT_ARCHER", x, y)
	list = Buttons(actions, nu)
	for _, inst in ipairs(list) do
		H.ne(inst.UnitActionIcon.icon, "ICON_UNITCOMMAND_FORM_CORPS", "no status button on a reused slot")
	end
	H.clean()
end)

test("UI hint: UnitFormCorps / UnitFormArmy of the local player refresh the panel; others do not", function()
	local S = H.baseScenario()
	H.loadEFV()
	local actions = BootUI(S)
	FAKE.localPlayer = 0
	actions.ContextPtr.refreshRequested = false
	Events.UnitFormCorps(3, 12345)
	H.ok(not actions.ContextPtr.refreshRequested, "AI formation ignored")
	Events.UnitFormCorps(0, 12345)
	H.ok(actions.ContextPtr.refreshRequested, "local Corps refreshes")
	actions.ContextPtr.refreshRequested = false
	Events.UnitFormArmy(0, 12345)
	H.ok(actions.ContextPtr.refreshRequested, "local Army refreshes")
	H.clean()
end)
