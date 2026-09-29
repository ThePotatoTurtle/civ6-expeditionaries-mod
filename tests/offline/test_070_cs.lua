-- @harness native
-- 0.7 lifecycle (FIXPLAN_0.7 items 3 and 10, WP2):
--   City-State records never enter GRACE / MUTINY: at expiry they are recalled
--   from wherever the unit stands (own land, neutral land, a third party's
--   land, while levied); legacy GRACE / MUTINY records from a 0.6.x save are
--   recalled at the next turn start (MUTINY floored first, no extra damage);
--   the sender's EXPIRY_SOON uses the _CS text; Expeditionary is unchanged.
--   Item 10: no unit is removed at its owner's PlayerTurnStartComplete; a war
--   first seen there is handled at the next boundary.
-- Scenario (H.baseScenario): 0 human, 1 ally B, 2 friend F, 3 enemy C, 4
-- city-state at (30,20).

local N = function(name) return "EFV_NOTIF_" .. name end
local CS = "CS_EXPEDITIONARY"

-- Deployed record for a unit already on the map (same shape as test_timers).
local function Deploy(S, opts)
	opts = opts or {}
	local ft = opts.forceType or "EXPEDITIONARY"
	local sender = opts.sender or 0
	local recipient = opts.recipient or 1
	local owner = opts.owner or ((ft == "VOLUNTEER") and sender or recipient)
	local dest = opts.dest or S.c1
	local origin = opts.origin or S.c0
	local x, y = opts.x or (dest.x + 1), opts.y or dest.y
	local u = H.unit(owner, opts.unitType or "UNIT_SWORDSMAN", x, y,
		{ promotions = { "PROMOTION_BATTLECRY" }, xp = 20, damage = opts.damage })
	local store = EFV_Records.Load()
	local turn = Game.GetCurrentGameTurn()
	local band, d = EFV_Band(origin.x, origin.y, dest.x, dest.y)
	local duration = opts.duration
	if duration == nil and ft ~= "VOLUNTEER" then duration = (ft == CS) and 10 or 20 end
	local rec = EFV_Records.New(store, {
		forceType = ft, state = "DEPLOYED", senderID = sender, recipientID = recipient,
		accessBasis = opts.basis or "ALLIANCE",
		originCityID = origin.id, originX = origin.x, originY = origin.y,
		destCityID = dest.id, destX = dest.x, destY = dest.y, rerouted = 0,
		onMapPlayerID = owner, onMapUnitID = u.id,
		sentTurn = turn - (opts.elapsed or 0) - band, arrivalTurn = turn - (opts.elapsed or 0),
		transitTurns = band, band = band, distance = d,
		deployedTurn = turn - (opts.elapsed or 0), durationTurns = duration,
		spawnFailCount = 0, feePaid = 100, maintGoldPaid = 0, lapsed = 0,
	})
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(u), turn)
	EFV_Records.Commit(store)
	H.clearNotifs()
	return rec.id, u
end

local function DeployCS(S, opts)
	opts = opts or {}
	opts.forceType = CS; opts.recipient = 4; opts.dest = S.c4; opts.basis = "CITY_STATE"
	return Deploy(S, opts)
end

local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end

local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end

local function Sent(pid, name, recID)
	local out = {}
	for _, n in ipairs(H.notifs(pid, N(name))) do
		if recID == nil or n.data.EFV_RecordID == recID then out[#out + 1] = n end
	end
	return out
end
local function Summary(n) return n.data[ParameterTypes.SUMMARY] end

-- Expiry at the next turn start, then: RETURNING / EXPIRED, unit removed, no alert.
local function ExpectRecalled(id, u)
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(u), "unit removed")
	H.len(Sent(0, "GRACE"), 0, "no GRACE notification"); H.len(Sent(0, "MUTINY"), 0)
	H.ok(H.hasLine("cs=recall-anywhere"))
end

-- ===========================================================================
-- Expiry: recalled from anywhere
-- ===========================================================================
test("CS expiry on the city-state's land -> RETURNING (EXPIRED)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = DeployCS(S, { elapsed = 9 })
	H.endTurn()
	ExpectRecalled(id, u)
	H.clean()
end)

test("CS expiry on neutral land -> RETURNING (EXPIRED) at once, no GRACE, no alert in the tracker", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = DeployCS(S, { elapsed = 9, x = p:GetX(), y = p:GetY() })
	H.endTurn()
	ExpectRecalled(id, u)
	H.eq(Rec(id).arrivalTurn, FAKE.turn + EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y), "normal band from the destination")
	-- UI side: no alert record, the D9 banner stays hidden.
	include("fake_ui")
	FAKE_UI.Enable()
	local tr = FAKE_UI.LoadContext("EFV/UI/EFV_Tracker.lua")
	Events.LoadGameViewStateDone()
	H.len(EFV_UI_AlertRecords(0), 0, "banner count 0")
	H.ok(tr.Controls.AlertBanner:IsHidden(), "banner hidden")
	H.clean()
end)

test("CS expiry on a third party's land (ally B) -> RETURNING (EXPIRED)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = DeployCS(S, { elapsed = 9, x = 22, y = 11 })
	H.ok(not EFV_ValidReturnTerritory(Rec(id), H.plot(22, 11)), "not valid return land")
	H.endTurn()
	ExpectRecalled(id, u)
	H.len(Sent(1, "GRACE"), 0)
	H.clean()
end)

test("CS expiry while levied -> recalled from the suzerain, its copy removed", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = DeployCS(S, { elapsed = 7 })
	Players[4].suzerain = 1
	H.levy(4, 1, 4)
	H.endTurn()                                       -- relinked to the suzerain's copy
	local r = Rec(id)
	H.eq(r.onMapPlayerID, 1)
	local lu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(lu)
	H.moveUnit(lu, 22, 11)                            -- the suzerain's own land
	H.endTurn()                                       -- elapsed 9
	H.eq(Rec(id).state, "DEPLOYED")
	H.endTurn()                                       -- elapsed 10: expiry
	ExpectRecalled(id, lu)
	H.len(H.unitsOf(1, "UNIT_SWORDSMAN"), 0, "the suzerain keeps no copy")
	H.clean()
end)

-- ===========================================================================
-- Legacy records from a 0.6.x save
-- ===========================================================================
test("legacy CS GRACE record -> RETURNING (EXPIRED) at the next turn start, no GRACE notification", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = DeployCS(S, { elapsed = 12, x = p:GetX(), y = p:GetY() })
	EditRecord(id, function(r) r.state = "GRACE"; r.graceTurnsLeft = 3 end)
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.isnil(r.graceTurnsLeft)
	H.ok(not H.unitAlive(u))
	H.len(Sent(0, "GRACE"), 0)
	H.ok(H.hasLine("[Timer] legacy CS id=" .. id .. " state=GRACE -> recall"))
	H.clean()
end)

test("legacy CS MUTINY record at 40 damage -> RETURNING with 40 (healed round floored, no extra 20)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = DeployCS(S, { elapsed = 16, x = p:GetX(), y = p:GetY(), damage = 40 })
	EditRecord(id, function(r) r.state = "MUTINY"; r.lastDamage = 40 end)
	H.endTurn{ heal = 10 }                            -- the round heal is floored back to 40
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.eq(r.damage, 40, "no extra mutiny damage")
	H.ok(not H.unitAlive(u))
	H.len(Sent(0, "MUTINY"), 0); H.len(Sent(0, "MUTINY_DEATH"), 0)
	H.ok(H.hasLine("[Timer] legacy CS id=" .. id .. " state=MUTINY -> recall"))
	H.turns(r.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1)
	H.eq(home[1]:GetDamage(), 40)
	H.clean()
end)

test("EnterGrace refuses a City-State record (defensive): logged, recalled instead", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = DeployCS(S, { elapsed = 3 })
	local s = EFV_Records.Load()
	EFV_Lifecycle.EnterGrace(s, EFV_Records.Get(s, id), FAKE.turn, "TEST", false)
	EFV_Records.Commit(s)
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.ok(not H.unitAlive(u))
	H.ok(H.hasLine("must not enter grace"))
end, { allowErrors = true })

-- ===========================================================================
-- EXPIRY_SOON texts; Expeditionary regression
-- ===========================================================================
test("EXPIRY_SOON: CS sender gets the _CS text, Expeditionary sender still _SENDER", function()
	local S = H.baseScenario()
	H.loadEFV()
	local idCS = DeployCS(S, { elapsed = 6 })         -- next turn: 3 left
	local idEX = Deploy(S, { elapsed = 16 })          -- next turn: 3 left
	local unit = EFV_UnitDisplayName("UNIT_SWORDSMAN")
	H.endTurn()
	local c, e = Sent(0, "EXPIRY_SOON", idCS), Sent(0, "EXPIRY_SOON", idEX)
	H.len(c, 1); H.len(e, 1)
	H.eq(Summary(c[1]), Locale.Lookup("LOC_EFV_NOTIF_EXPIRY_SOON_CS_SUMMARY", unit, 3, EFV_PlayerName(4)))
	H.eq(Summary(e[1]), Locale.Lookup("LOC_EFV_NOTIF_EXPIRY_SOON_SENDER_SUMMARY", unit, 3, EFV_PlayerName(1)))
	H.len(Sent(4, "EXPIRY_SOON"), 0, "the city-state is not human")
	H.clean()
end)

test("Expeditionary regression: expiry off valid land -> GRACE 5 with notification", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, 5)
	H.len(Sent(0, "GRACE", id), 1)
	H.ok(not H.hasLine("cs=recall-anywhere"))
	H.clean()
end)

-- ===========================================================================
-- Item 10: no removal at the owner's PlayerTurnStartComplete
-- ===========================================================================
test("war first seen at the owner's PTSC is deferred to the next boundary; no removal at the owner's PTSC", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 3 })          -- EXP unit owned by AI recipient 1
	-- Current hook tracker (runs before EFV's handlers).
	local cur = { hook = "none", pid = -1 }
	local function Track(hook)
		return function(pid) cur = { hook = hook, pid = pid or -1 } end
	end
	table.insert(GameEvents.PlayerTurnStarted.handlers, 1, Track("PTS"))
	table.insert(GameEvents.OnGameTurnEnded.handlers, 1, Track("OnGameTurnEnded"))
	table.insert(GameEvents.OnGameTurnStarted.handlers, 1, Track("OnGameTurnStarted"))
	-- The war appears between PTS(1) and PTSC(1) (injected before EFV's PTSC handler).
	table.insert(GameEvents.PlayerTurnStartComplete.handlers, 1, function(pid)
		cur = { hook = "PTSC", pid = pid }
		if pid == 1 and not FAKE.atWarInjected then
			FAKE.atWarInjected = true
			H.war(0, 1)
		end
	end)
	-- Spy on every EFV unit removal.
	local removals = {}
	local realRemove = EFV_Units.Remove
	EFV_Units.Remove = function(pUnit)
		removals[#removals + 1] = { hook = cur.hook, pid = cur.pid, owner = pUnit:GetOwner() }
		return realRemove(pUnit)
	end
	H.endTurn()                                       -- PTS(1) no war; PTSC(1) war -> deferred
	H.ok(H.hasLine("[War] id=" .. id .. " deferred at the owner's PTSC"))
	-- Handled at the next boundary (PTS(2) of the same round): reverted to the sender.
	H.isnil(Rec(id), "record closed by the revert")
	H.ok(not H.unitAlive(u))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1, "the unit is the sender's again")
	H.ok(#removals >= 1, "the revert removed the recipient's unit")
	H.eq(removals[1].hook, "PTS"); H.eq(removals[1].pid, 2); H.eq(removals[1].owner, 1)
	for _, rm in ipairs(removals) do
		H.ok(not (rm.hook == "PTSC" and rm.owner == rm.pid), "removal of a unit of " .. rm.pid .. " at its own PTSC")
	end
	H.endTurn()
	for _, rm in ipairs(removals) do
		H.ok(not (rm.hook == "PTSC" and rm.owner == rm.pid), "removal of a unit of " .. rm.pid .. " at its own PTSC")
	end
	H.clean()
end)

test("war at PTSC of another player (not the owner) is still handled at once", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { elapsed = 3 })             -- owned by 1
	local fired = false
	table.insert(GameEvents.PlayerTurnStartComplete.handlers, 1, function(pid)
		if pid == 2 and not fired then fired = true; H.war(0, 1) end
	end)
	H.endTurn{ act = function(pid)
		if pid == 2 then H.isnil(Rec(id), "reverted at PTSC(2): the unit is not player 2's") end
	end }
	H.ok(not H.hasLine("deferred at the owner's PTSC"))
	H.clean()
end)
