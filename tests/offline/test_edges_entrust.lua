-- @harness native
-- Spec 11 edge cases (PLAN 2.9, 2.12), Volunteer send/recall (spec 9.2) and
-- Entrust (spec 12, PLAN 2.10). The three Entrust tests were xfail until
-- Phase 6 and pass since WP6.1; the full Phase 6 suite is test_phase6.lua
-- and the full Phase 5 edge-case suite is test_phase5.lua.

local N = function(name) return "EFV_NOTIF_" .. name end
local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end

local function SendAndDeploy(S, forceType, recipient, city)
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY" } }),
		recipient or 1, city or S.c1, forceType or "EXPEDITIONARY")
	local r = H.records()[1]
	H.notnil(r, "send accepted")
	H.turns(r.arrivalTurn - FAKE.turn)
	return H.records()[1]
end

-- ---------------------------------------------------------------------------
-- Spec 11 rows
-- ---------------------------------------------------------------------------
test("recipient eliminated while OUTBOUND -> transit cancelled (RECIPIENT_GONE), unit back on its tile", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.kill(1)
	H.endTurn()
	H.len(H.records(), 0, "cancelled: record closed, no return trip")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), 11); H.eq(mine[1]:GetY(), 10)
	H.ok(H.hasLine("reason=RECIPIENT_GONE"))
	H.eq(H.gold(0), 1000 - 36 + 18, "half the fee back")
	H.clean()
end)

test("recipient eliminated with a deployed EXP unit -> returned from the snapshot (S9)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = SendAndDeploy(S)
	for _, u in ipairs(H.unitsOf(1)) do H.killUnit(u) end   -- engine removes the dead player's units
	H.kill(1)
	H.endTurn()
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECIPIENT_GONE")
	H.deq(r.promotions, { "PROMOTION_BATTLECRY" })
end)

test("sender eliminated -> records deleted, deployed unit stays with the recipient", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = SendAndDeploy(S)
	local uid = r.onMapUnitID
	H.kill(0)
	H.endTurn()
	H.len(H.records(), 0)
	H.notnil(Players[1]:GetUnits():FindID(uid))
end)

test("sender and recipient at war: deployed EXP reverts to the sender in place (REVERTED)", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r = SendAndDeploy(S)
	local u = Players[1]:GetUnits():FindID(r.onMapUnitID)
	local x, y = u:GetX(), u:GetY()
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0, "record closed")
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), x); H.eq(mine[1]:GetY(), y)
	H.deq(H.promotionTypes(mine[1]), { "PROMOTION_BATTLECRY" })
	H.eq(#H.notifs(0, N("REVERTED")), 1)
	H.eq(#H.notifs(1, N("REVERTED")), 1)
end)

test("sender and recipient at war while OUTBOUND -> transit cancelled (WAR)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	H.war(0, 1)
	H.endTurn()
	H.len(H.records(), 0)
	local mine = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(mine, 1)
	H.eq(mine[1]:GetX(), 11); H.eq(mine[1]:GetY(), 10)
	H.ok(H.hasLine("reason=WAR"))
	H.clean()
end)

test("merge survivor (formation change) keeps the EXP record, MERGED to both (D3)", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local r = SendAndDeploy(S)
	local u = Players[1]:GetUnits():FindID(r.onMapUnitID)
	u:SetMilitaryFormation(MilitaryFormationTypes.CORPS_FORMATION)
	H.endTurn()
	H.len(H.records(), 1)
	H.eq(#H.notifs(0, N("MERGED")), 1)
	H.eq(#H.notifs(1, N("MERGED")), 1)
end)

-- ---------------------------------------------------------------------------
-- Volunteers: send and recall
-- ---------------------------------------------------------------------------
test("Volunteer send: sender keeps ownership, fee 30% (20% + band 2 surcharge 10%, 0.5.2 ruling), no duration", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "VOLUNTEER")
	local r = H.records()[1]
	H.notnil(r)
	H.eq(H.gold(0), 1000 - 108); H.isnil(r.durationTurns); H.eq(r.accessBasis, "ALLIANCE")
	H.turns(2)
	r = Only()
	H.eq(r.state, "DEPLOYED"); H.eq(r.onMapPlayerID, 0, "Volunteers stay the sender's")
end)

test("Volunteer recall: rejected before 10 turns, accepted after (RECALL)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER")
	H.turns(2)
	local r = Only()
	H.request(0, { OnStart = "EFV_Recall", unitID = r.onMapUnitID })
	H.eq(Only().state, "DEPLOYED")
	H.eq(#H.notifs(0, N("REQUEST_FAILED")), 1)
	H.turns(10)
	H.request(0, { OnStart = "EFV_Recall", unitID = r.onMapUnitID })
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECALL")
end)

-- ---------------------------------------------------------------------------
-- Entrust
-- ---------------------------------------------------------------------------
local function Capture(S, oldOwner, city)
	-- player 0 captures `city` of oldOwner (engine: ownership changes, then CityConquered fires)
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, 0, CityTransferTypes.BY_COMBAT)
	GameEvents.CityConquered(0, oldOwner, oldID, x, y)
	return CityManager.GetCityAt(x, y)
end

test("Entrust: capture snapshot lists partners at war with the old owner", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(S, 3, S.c3)
	local s = EFV_Records.Load()
	local snap = s.entrust[EFV_PlotKey(S.c3.x, S.c3.y)]
	H.notnil(snap, "snapshot keyed by plot")
	H.eq(snap.capturerID, 0); H.eq(snap.oldOwnerID, 3); H.eq(snap.turn, FAKE.turn)
	H.deq(snap.recipients, { 1, 2 }, "ally and friend, both at war with 3")
	H.deq(EFV_Entrust.EligibleRecipients(0, 3), { 1, 2 })
	H.deq(EFV_Entrust.EligibleRecipients(0, 1), {}, "nobody is at war with the ally")
end)

test("Entrust: request transfers the city (BY_GIFT) and notifies both", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	Capture(S, 3, S.c3)
	H.request(0, { OnStart = "EFV_Entrust", x = S.c3.x, y = S.c3.y, recipientID = 1 })
	local c = CityManager.GetCityAt(S.c3.x, S.c3.y)
	H.eq(c:GetOwner(), 1)
	H.eq(FAKE.transfers[#FAKE.transfers].how, CityTransferTypes.BY_GIFT)
	H.eq(#H.notifs(0, N("ENTRUSTED")), 1)
	H.eq(#H.notifs(1, N("ENTRUSTED")), 1)
	H.isnil(EFV_Records.Load().entrust[EFV_PlotKey(S.c3.x, S.c3.y)], "snapshot consumed")
end)

test("Entrust: stale (next turn) or ineligible recipient is rejected", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(S, 3, S.c3)
	H.request(0, { OnStart = "EFV_Entrust", x = S.c3.x, y = S.c3.y, recipientID = 4 })
	H.eq(CityManager.GetCityAt(S.c3.x, S.c3.y):GetOwner(), 0, "city-state not eligible")
	H.endTurn()
	H.request(0, { OnStart = "EFV_Entrust", x = S.c3.x, y = S.c3.y, recipientID = 1 })
	H.eq(CityManager.GetCityAt(S.c3.x, S.c3.y):GetOwner(), 0, "snapshot expired")
	H.ok(#H.notifs(0, N("REQUEST_FAILED")) >= 1)
end)
