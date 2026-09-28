-- @harness native
-- Session F MUST-FIX items (0.5.2; INTEGRATION_NOTES_SESSION_F.md items 1-5,
-- 7; INTERFACES note 30), end to end on the fake engine in the confirmed hook
-- order. The fake models the Session F engine facts (fake_engine.lua header):
-- stale unit objects that FindID still returns (killed in combat: this frame,
-- damage 100; upgraded: until OnGameTurnEnded; levied away: -9999,-9999 until
-- the next turn start), NEW unit IDs on upgrade (same plot, T30) and levy
-- (tile kept or shifted, T28), and the T08 level reset.
--   1. stale handles count as missing; a unit killed defending the recipient
--      city-state's last city is never sent home alive;
--   2. relinks only to a provably identical unit (unique; ambiguous -> lost);
--   3. upgrade into a civilization's unique unit (Warrior -> Hypaspist);
--   4. combat damage in the same interval as a heal is kept (OnCombat raise);
--   plus: an untracked unit is never written by the floor / tick; CityConquered
--   returns a living unit of an eliminated recipient at once (S9, item 7).
-- Scenario (H.baseScenario): 0 human (cities (10,10), (14,20)), 1 ally B
-- (22,10), 2 friend F (40,30), 3 enemy C (at war with 0, 1, 2 and the
-- city-state), 4 city-state (30,20), 63 Barbarians.

local N = function(name) return "EFV_NOTIF_" .. name end

local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end
local function Sent(pid, name) return H.notifs(pid, N(name)) end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] or "" end
local function LossText(n) return Summary(n) end
local function IsKilled(n) return string.find(LossText(n), Locale.Lookup("LOC_EFV_LOSS_KILLED"), 1, true) ~= nil end
local function IsDisbanded(n) return string.find(LossText(n), Locale.Lookup("LOC_EFV_LOSS_DISBANDED"), 1, true) ~= nil end

-- A deployed record for a unit already on the map (test_phase2 shape).
-- opts: forceType, recipient, dest, x, y, unitType, damage, xp, promotions.
local function Deploy(S, opts)
	opts = opts or {}
	local ft = opts.forceType or "EXPEDITIONARY"
	local recipient = opts.recipient or 1
	local dest = opts.dest or S.c1
	local x, y = opts.x or (dest.x + 1), opts.y or dest.y
	local u = H.unit(recipient, opts.unitType or "UNIT_SWORDSMAN", x, y, {
		promotions = opts.promotions or { "PROMOTION_BATTLECRY" }, xp = opts.xp or 20, damage = opts.damage })
	local store = EFV_Records.Load()
	local turn = Game.GetCurrentGameTurn()
	local band, d = EFV_Band(S.c0.x, S.c0.y, dest.x, dest.y)
	local rec = EFV_Records.New(store, {
		forceType = ft, state = "DEPLOYED", senderID = 0, recipientID = recipient,
		accessBasis = (ft == "CS_EXPEDITIONARY") and "CITY_STATE" or "ALLIANCE",
		originCityID = S.c0.id, originX = S.c0.x, originY = S.c0.y,
		destCityID = dest.id, destX = dest.x, destY = dest.y, rerouted = 0,
		onMapPlayerID = recipient, onMapUnitID = u.id,
		sentTurn = turn - band, arrivalTurn = turn, transitTurns = band, band = band, distance = d,
		deployedTurn = turn, durationTurns = (ft == "CS_EXPEDITIONARY") and 10 or 20,
		spawnFailCount = 0, feePaid = 0, maintGoldPaid = 0, lapsed = 0,
	})
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(u), turn)
	EFV_Records.Commit(store)
	H.clearNotifs()
	return rec.id, u
end

-- Puts a deployed EXP record into MUTINY at `dmg` on neutral land.
local function Mutiny(id, u, dmg)
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	u.damage = dmg
	EditRecord(id, function(rec)
		rec.state = "MUTINY"; rec.lastDamage = dmg; rec.lastX = p:GetX(); rec.lastY = p:GetY()
	end)
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

-- An untracked enemy unit reference for H.combat (never on the map).
local function Enemy(pid) return { owner = pid, id = 900000 + pid } end

-- ===========================================================================
-- MUST-FIX 1: stale unit objects count as missing
-- ===========================================================================
test("stale: a unit killed in combat is still returned by FindID (damage 100) -> Get = nil (GONE_DEAD)", function()
	H.baseScenario()
	H.loadEFV()
	local u = H.unit(1, "UNIT_SWORDSMAN", 23, 10)
	FAKE.CombatKill(u)
	H.eq(Players[1]:GetUnits():FindID(u.id), u, "the engine still returns the object (T20)")
	local p, why = EFV_Units.Get(1, u.id)
	H.isnil(p); H.eq(why, "GONE_DEAD")
	local ok, why2 = EFV_UnitMatches(u, 1, u.id, "UNIT_SWORDSMAN")
	H.eq(ok, false); H.eq(why2, "GONE_DEAD", "UI and EFV_Dev lookups share the check")
	H.ok(H.hasLine("why=GONE_DEAD"))
	H.clean()
end)

test("stale: a levied unit's old object at -9999,-9999 -> missing (GONE_OFFMAP); ghosts expire at the next turn start", function()
	H.baseScenario()
	H.loadEFV()
	local u = H.unit(4, "UNIT_SWORDSMAN", 31, 20)
	Players[4].suzerain = 2
	local copies = H.levy(4, 2, 4)
	H.len(copies, 1); H.ne(copies[1].id, u.id, "new ID (T28)")
	H.eq(Players[4]:GetUnits():FindID(u.id), u, "old object still in the city-state's list")
	H.eq(u.x, -9999)
	local p, why = EFV_Units.Get(4, u.id)
	H.isnil(p); H.eq(why, "GONE_OFFMAP")
	H.endTurn()
	H.isnil(Players[4]:GetUnits():FindID(u.id), "gone after the next turn start")
	H.clean()
end)

test("stale: an object no longer in its plot's unit list -> missing (GONE_PLOT) when the engine drops it there", function()
	H.baseScenario()
	H.loadEFV()
	FAKE.ghostsInPlot = false
	local u = H.unit(1, "UNIT_WARRIOR", 23, 10)
	local nu = H.upgrade(u, "UNIT_SWORDSMAN")
	H.eq(Players[1]:GetUnits():FindID(u.id), u, "old object findable for the rest of the turn (T30)")
	local p, why = EFV_Units.Get(1, u.id, "UNIT_WARRIOR")
	H.isnil(p); H.eq(why, "GONE_PLOT")
	H.eq(EFV_Units.Get(1, nu.id), nu, "the live unit passes")
	H.clean()
end)

test("stale: an off-map snapshot position is never stored (ApplySnapshot / boundaries)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4 })
	local rec = Rec(id)
	local x0, y0 = rec.lastX, rec.lastY
	EFV_Units.ApplySnapshot(rec, { unitType = "UNIT_SWORDSMAN", damage = 0, experience = 0, xpNext = 15,
		promotions = {}, level = 1, formation = 0, lastX = -9999, lastY = -9999 }, FAKE.turn)
	H.eq(rec.lastX, x0); H.eq(rec.lastY, y0)
	H.ok(H.hasLine("off-map position -9999,-9999 not stored"))
	-- A levy with a copy 3 hexes away (no relink): the record never takes -9999.
	Players[4].suzerain = 2
	H.levy(4, 2, 4, function(u) local p = FreeAt(u.x, u.y, 3); return p.x, p.y end)
	H.endTurn({ act = function()
		local r = Rec(id)
		if r ~= nil then H.ok(r.lastX >= 0 and r.lastY >= 0, "lastX/lastY stay on the map") end
	end })
	H.errorLines()   -- the ApplySnapshot ERROR line above is expected
end, { allowErrors = true })

test("MUST-FIX 1: CS unit killed defending the city-state's last city -> KILLED at CityConquered, never sent home", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4 })
	H.endTurn({ act = function(p)
		if p == 3 then
			H.combat(Enemy(3), cu, 100)               -- C kills the defender (72 -> 100 in T20)
			H.eq(Players[4]:GetUnits():FindID(cu.id), cu, "still found in this frame")
			H.kill(4)                                 -- T20: IsAlive() is false inside CityConquered
			GameEvents.CityConquered(3, 4, S.c4.id, S.c4.x, S.c4.y)
			H.len(H.records(), 0, "closed inside CityConquered")
			for _, u in ipairs(H.unitsOf(4)) do H.killUnit(u) end
		end
	end })
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.ok(IsKilled(Sent(0, "UNIT_LOST")[1]), "UNIT_LOST says killed")
	H.ok(H.hasLine("CityConquered capturer=3 oldOwner=4"))
	H.ok(H.hasLine("killed=1"))
	H.turns(6)
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 0, "no resurrection")
	H.len(H.damageWritesTo(cu), 0, "the dead object was never written")
	H.clean()
end)

test("MUST-FIX 1: recipient eliminated without CityConquered after its unit's combat death -> step 0b KILLED, no return", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4 })
	H.endTurn({ act = function(p)
		if p == 3 then
			H.combat(Enemy(3), cu, 100)
			for _, u in ipairs(H.unitsOf(4)) do H.killUnit(u) end
			H.kill(4)
		end
	end })
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1); H.ok(IsKilled(Sent(0, "UNIT_LOST")[1]))
	H.ok(H.hasLine("unit killed"))
	H.turns(6)
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 0, "no resurrection")
	H.clean()
end)

test("item 7: recipient eliminated, unit alive at CityConquered -> RETURNING at once from that fresh state", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, xp = 10 })
	H.endTurn({ act = function(p)
		if p == 3 then
			cu.damage = 30                             -- after the last per-player boundary
			H.kill(4)
			GameEvents.CityConquered(3, 4, S.c4.id, S.c4.x, S.c4.y)
			local r = Only()
			H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECIPIENT_GONE"); H.eq(r.damage, 30)
			H.ok(not H.unitAlive(cu), "taken off the map by EFV")
			for _, u in ipairs(H.unitsOf(4)) do H.killUnit(u) end
		end
	end })
	H.ok(H.hasLine("recipient gone at CityConquered id=" .. id))
	H.ok(H.hasLine("returned=1"))
	local r = Only()
	H.turns(r.arrivalTurn - FAKE.turn)
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(home, 1); H.eq(home[1].damage, 30); H.eq(home[1].xp, 10)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.clean()
end)

test("MUST-FIX 1: a MUTINY unit whose dead object stays findable is never written; KILLED, not MUTINY_DEATH", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 60)
	local twin = H.unit(1, "UNIT_SWORDSMAN", FreeAt(u.x, u.y, 1).x, FreeAt(u.x, u.y, 1).y, { damage = 30 })
	H.endTurn({ heal = 10, act = function(p)
		if p == 63 then
			H.combat(Enemy(63), u, 50)                -- the Barbarians kill it
			u.ghost = "manual"                         -- worst case: the object outlives the round
		end
	end })
	H.len(H.records(), 0, "closed at step 0c")
	H.len(Sent(0, "UNIT_LOST"), 1); H.ok(IsKilled(Sent(0, "UNIT_LOST")[1]))
	H.len(Sent(0, "MUTINY_DEATH"), 0)
	H.len(H.damageWritesTo(u), 0, "no floor / tick on the dead object")
	H.len(H.damageWritesTo(twin), 0, "the untracked twin is never touched")
	H.eq(twin.damage, 20, "the twin only healed (engine)")
	FAKE.ExpireGhosts("manual")
	H.clean()
end)

-- ===========================================================================
-- MUST-FIX 2: relink only a provably identical unit
-- ===========================================================================
local function CsDeployed(S)
	local id, cu = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, xp = 12 })
	return id, cu
end

test("levy relink: the true copy (snapshot match) vs a native unit of the same type with fewer promotions -> the copy", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = CsDeployed(S)
	local x, y = cu.x, cu.y
	local shiftTo = FreeAt(x, y, 1)
	local native = H.unit(4, "UNIT_SWORDSMAN", FreeAt(x, y, 1, function(p) return p == shiftTo end).x,
		FreeAt(x, y, 1, function(p) return p == shiftTo end).y, { xp = 12 })   -- no BATTLECRY
	Players[4].suzerain = 2
	local copies = H.levy(4, 2, 4, function(u)
		if u == cu then return shiftTo.x, shiftTo.y end                        -- the copy shifts by 1 (T28)
		return x, y                                                            -- the native lands on our old tile
	end)
	local mine
	for _, c in ipairs(copies) do if c.x == shiftTo.x and c.y == shiftTo.y then mine = c end end
	H.endTurn()
	local r = Only()
	H.eq(r.onMapPlayerID, 2); H.eq(r.onMapUnitID, mine.id, "the copy, not the native unit on the old tile")
	H.ok(H.hasLine("[Levy] relink id=" .. id))
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.ok(native ~= nil)
	H.clean()
end)

test("levy relink: two equal candidates within reach -> no relink, record lost (DISBANDED) with an ambiguity log line", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = CsDeployed(S)
	local x, y = cu.x, cu.y
	local a = FreeAt(x, y, 1)
	local b = FreeAt(x, y, 1, function(p) return p == a end)
	local native = H.unit(4, "UNIT_SWORDSMAN", b.x, b.y, { xp = 12, promotions = { "PROMOTION_BATTLECRY" } })
	Players[4].suzerain = 2
	local copies = H.levy(4, 2, 4, function(u)
		if u == cu then return a.x, a.y end
		return u.x, u.y
	end)
	H.len(copies, 2)
	H.endTurn({ heal = 10 })
	H.len(H.records(), 0, "fail safe: lost, not hijacked")
	H.len(Sent(0, "UNIT_LOST"), 1); H.ok(IsDisbanded(Sent(0, "UNIT_LOST")[1]))
	H.ok(H.hasLine("[Levy] ambiguous id=" .. id .. " candidates=2"))
	for _, c in ipairs(copies) do
		H.len(H.damageWritesTo(c), 0, "no EFV write to either candidate")
		H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 2, c.id), "neither is tracked")
	end
	H.ok(native ~= nil)
	H.clean()
end)

test("levy relink: a native unit with fewer promotions than the record is rejected even when it is the only one", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = CsDeployed(S)
	local x, y = cu.x, cu.y
	H.killUnit(cu)                                     -- ours is gone (disbanded)
	local nat = H.unit(4, "UNIT_SWORDSMAN", x, y, { xp = 30 })   -- no BATTLECRY, on our tile
	Players[4].suzerain = 2
	H.levy(4, 2, 4)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(IsDisbanded(Sent(0, "UNIT_LOST")[1]))
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 2, nat.id))
	H.clean()
end)

test("levy relink runs at the per-player boundary: relinked before the suzerain's next player acts", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, cu = CsDeployed(S)
	local seenAt = nil
	H.endTurn({ act = function(p)
		if p == 2 then
			Players[4].suzerain = 2
			H.levy(4, 2, 4)                            -- the suzerain levies in its own turn
		elseif p == 3 and seenAt == nil then
			local r = Rec(id)
			if r ~= nil and r.onMapPlayerID == 2 then seenAt = p end
		end
	end })
	H.eq(seenAt, 3, "relinked at PTS(3), not only in step 0c")
	H.ok(H.hasLine("hook=PlayerTurnStarted"))
	H.clean()
end)

test("upgrade relink: two untracked upgrade-type units on the snapshot plot -> no relink (ambiguous), DISBANDED", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	local x, y = u.x, u.y
	FAKE.RemoveUnit(u, "UPGRADE")
	H.unit(1, "UNIT_MAN_AT_ARMS", x, y, { promotions = { "PROMOTION_BATTLECRY" } })
	H.unit(1, "UNIT_MAN_AT_ARMS", x, y, { promotions = { "PROMOTION_BATTLECRY" } })
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("[Upgrade] ambiguous id=" .. id .. " candidates=2"))
	H.ok(IsDisbanded(Sent(0, "UNIT_LOST")[1]))
	H.clean()
end)

test("upgrade relink: an upgrade-type unit one tile away is not taken (same plot only, T30)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	local p = FreeAt(u.x, u.y, 1)
	FAKE.RemoveUnit(u, "DISBAND")
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", p.x, p.y)
	H.endTurn()
	H.len(H.records(), 0)
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, other.id))
	H.clean()
end)

test("upgrade relink: an upgrade-type unit on the snapshot plot without the record's promotions is not taken (disband + move in)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)                           -- BATTLECRY
	local x, y = u.x, u.y
	FAKE.RemoveUnit(u, "DISBAND")
	local other = H.unit(1, "UNIT_MAN_AT_ARMS", x, y) -- the host's own unit moves onto the tile
	H.endTurn()
	H.len(H.records(), 0)
	H.isnil(EFV_Records.FindByUnit(EFV_Records.Load(), 1, other.id))
	H.ok(IsDisbanded(Sent(0, "UNIT_LOST")[1]))
	H.clean()
end)

test("untracked units are never touched by the floor or the tick: a MUTINY record whose unit vanished near same-type units", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 40)
	local x, y = u.x, u.y
	local near = FreeAt(x, y, 1)
	FAKE.RemoveUnit(u, "DISBAND")
	local sameType = H.unit(1, "UNIT_SWORDSMAN", near.x, near.y, { damage = 50 })
	local upgraded = H.unit(1, "UNIT_MAN_AT_ARMS", FreeAt(x, y, 1, function(p) return p == near end).x,
		FreeAt(x, y, 1, function(p) return p == near end).y, { damage = 50 })
	H.turns(3, { heal = 10 })
	H.len(H.records(), 0)
	H.len(H.damageWritesTo(sameType), 0); H.len(H.damageWritesTo(upgraded), 0)
	H.eq(sameType.damage, 20); H.eq(upgraded.damage, 20, "engine heals only")
	H.clean()
end)

-- ===========================================================================
-- MUST-FIX 3: upgrades into a civilization's unique unit (T30)
-- ===========================================================================
test("UU: EFV_IsUpgradeOf / EFV_BaseUnitType / EFV_UpgradeTargets follow GameInfo.UnitReplaces", function()
	H.world{ players = { { id = 0, human = true }, { id = 1, civType = "CIVILIZATION_MACEDON" }, { id = 2 } } }
	H.loadEFV()
	H.ok(EFV_IsUpgradeOf("UNIT_MACEDONIAN_HYPASPIST", "UNIT_WARRIOR"), "Warrior -> Hypaspist (T30)")
	H.ok(EFV_IsUpgradeOf("UNIT_SWORDSMAN", "UNIT_MACEDONIAN_HYPASPIST"), "a UU counts as its base type")
	H.ok(EFV_IsUpgradeOf("UNIT_MAN_AT_ARMS", "UNIT_MACEDONIAN_HYPASPIST"))
	H.ok(not EFV_IsUpgradeOf("UNIT_WARRIOR", "UNIT_MACEDONIAN_HYPASPIST"), "no downgrade")
	H.ok(EFV_IsUpgradeOf("UNIT_ROMAN_LEGION", "UNIT_WARRIOR"))
	H.eq(EFV_BaseUnitType("UNIT_MACEDONIAN_HYPASPIST"), "UNIT_SWORDSMAN")
	H.eq(EFV_BaseUnitType("UNIT_SWORDSMAN"), "UNIT_SWORDSMAN")
	local mac = EFV_UpgradeTargets("UNIT_WARRIOR", 1)
	H.ok(mac["UNIT_MACEDONIAN_HYPASPIST"], "Macedon's own unique unit")
	H.ok(mac["UNIT_SWORDSMAN"]); H.ok(mac["UNIT_MAN_AT_ARMS"])
	H.ok(not mac["UNIT_ROMAN_LEGION"], "another civilization's unique unit is not a target")
	H.ok(not mac["UNIT_WARRIOR"], "strict: never the same type")
	local other = EFV_UpgradeTargets("UNIT_WARRIOR", 2)
	H.ok(not other["UNIT_MACEDONIAN_HYPASPIST"], "not Macedon: no Hypaspist")
	H.clean()
end)

local function HypaspistCase(ghostsInPlot)
	local S = H.baseScenario()
	Players[1].civType = "CIVILIZATION_MACEDON"
	FAKE.ghostsInPlot = ghostsInPlot
	H.loadEFV()
	local id, u = Deploy(S, { unitType = "UNIT_WARRIOR", promotions = {}, xp = 5 })
	local nu
	H.endTurn({ act = function(p)
		if p == 1 then nu = H.upgrade(u, "UNIT_MACEDONIAN_HYPASPIST") end   -- T30: 0/983047 -> 0/1048584
	end })
	local r = Only()
	H.eq(r.onMapUnitID, nu.id, "new ID"); H.eq(r.unitType, "UNIT_MACEDONIAN_HYPASPIST", "new type")
	H.eq(r.lastX, nu.x); H.eq(r.lastY, nu.y)
	H.len(Sent(0, "UNIT_LOST"), 0)
	H.ok(H.hasLine("[Upgrade] relink id=" .. id))
	H.ok(H.hasLine("type=UNIT_WARRIOR->UNIT_MACEDONIAN_HYPASPIST"))
	H.clean()
	return r
end
test("UU: a Warrior upgraded into a Macedonian Hypaspist on the same plot is relinked (old object still findable until OnGameTurnEnded)", function()
	HypaspistCase(true)
	H.ok(H.hasLine("hook=OnGameTurnEnded"), "relinked once the old object was gone")
end)
test("UU: same, when the engine drops the old object from the plot at once -> relinked at the next player's boundary", function()
	HypaspistCase(false)
	H.ok(H.hasLine("hook=PlayerTurnStarted"))
end)

test("UU: a Hypaspist appearing for a non-Macedonian owner is not an upgrade target -> no relink", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { unitType = "UNIT_WARRIOR", promotions = {}, xp = 5 })
	H.endTurn({ act = function(p)
		if p == 1 then H.upgrade(u, "UNIT_MACEDONIAN_HYPASPIST") end
	end })
	H.len(H.records(), 0)
	H.len(Sent(0, "UNIT_LOST"), 1)
	H.clean()
end)

-- ===========================================================================
-- MUST-FIX 4: combat damage in the same interval as a heal is kept
-- ===========================================================================
-- The MUTINY unit's damage at OnGameTurnEnded (after the floor, before the
-- +20 tick of the next turn start): the last restore write at that hook.
local function FloorResultAtTurnEnd(u, dmg0, act, heal)
	local atEnd = nil
	local ev = GameEvents.OnGameTurnEnded
	H.endTurn({ heal = heal, act = act })
	for _, w in ipairs(H.damageWritesTo(u)) do
		if w.from < w.to and w.to ~= w.from + 20 then atEnd = w.to end
	end
	return atEnd, ev
end

test("MUST-FIX 4: Barbarian hit +25 then round heal 10 on a MUTINY unit at 50 -> 75 kept (was 65)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 50)
	local restored = FloorResultAtTurnEnd(u, 50, function(p)
		if p == 63 then H.combat(Enemy(63), u, 25) end
	end, 10)
	H.eq(restored, 75, "heal restored to a baseline that includes the Barbarian hit")
	H.ok(H.hasLine("[Floor] raise id=" .. id .. " hook=OnCombat from=50 to=75"))
	H.eq(u.damage, 95, "then the +20 tick at the turn start")
	H.clean()
end)

test("MUST-FIX 4: Barbarian hit +5 then round heal 15 on a MUTINY unit at 50 -> 55 kept (was 50)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 50)
	local restored = FloorResultAtTurnEnd(u, 50, function(p)
		if p == 63 then H.combat(Enemy(63), u, 5) end
	end, 15)
	H.eq(restored, 55)
	H.eq(u.damage, 75)
	H.clean()
end)

test("MUST-FIX 4: human-owned MUTINY unit attacks (+20) and is promoted (heal 50) in its own turn -> PTS(next) ends at the combat value", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 50)
	-- The humans play turn T (the test body): B's unit attacks, then promotes.
	H.combat(u, Enemy(3), nil, 20)                    -- 50 -> 70
	H.eq(Rec(id).lastDamage, 70, "baseline raised at the combat")
	u.damage = u.damage - 50                          -- EXPERIENCE_PROMOTE_HEALED
	H.endTurn({ act = function(p)
		if p == 2 then H.eq(u.damage, 70, "PTS(2) restored the promotion heal to the combat value") end
	end })
	H.clean()
end)

test("MUST-FIX 4: OnCombat never changes the baseline of a non-MUTINY record and never writes the unit", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	H.combat(Enemy(3), u, 30)
	local r = Rec(id)
	H.isnil(r.lastDamage); H.eq(r.lastCombatTurn, FAKE.turn)
	H.len(H.damageWritesTo(u), 0)
	H.ok(not H.hasLine("hook=OnCombat"))
	H.clean()
end)

test("MUST-FIX 4 (T31 open): if the engine applied combat damage AFTER OnCombatOccurred, the residual is at most one heal", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S)
	Mutiny(id, u, 50)
	FAKE.combatDamageBeforeEvent = false
	H.endTurn({ heal = 10, act = function(p)
		if p == 63 then H.combat(Enemy(63), u, 25) end
	end })
	-- 50 + 25 - 10 = 65 at OnGameTurnEnded (net up: raised, heal not cancelled),
	-- then +20: the documented residual (10 = min(25, 10)); T31 decides.
	H.eq(u.damage, 85)
	H.ok(not H.hasLine("hook=OnCombat from="), "the raise found nothing to raise")
	H.clean()
end)
