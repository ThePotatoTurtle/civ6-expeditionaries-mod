-- @harness native
-- Phase 2 (PLAN 5.2 WP2.1-2.3) and the Session C fixes, on the fake engine in
-- the CONFIRMED in-game hook order (lib/harness.lua H.endTurn: AI turns ->
-- TurnEnd -> OnGameTurnStarted -> human start hooks; OnPlayerTurnEnded never
-- fires):
--   P2.1 timeline (grace 5 turns, 20 damage per turn, death on the predicted
--        turn) with both players' texts;
--   P2.2 returns during grace and mutiny (damage kept, floored);
--   P2.3 heal cancel with the engine heal simulated at every hook point, no
--        heal at all (GS strategic-resource gate), combat during mutiny;
--   EXPIRY_SOON timing (3 and 1 turns, EXP / CS only);
--   unit identity on reused unit IDs (FindID resolves only the slot);
--   the turn-boundary abstraction with 1 human + several AIs, idempotency and
--   the harmless legacy OnPlayerTurnEnded;
--   the D9 tracker UI (banner, cycling, sound, stale dismissal, list).

local N = function(name) return "EFV_NOTIF_" .. name end
local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end

-- Deployed record for a unit already on the map (same shape as test_timers).
-- opts: forceType, sender, recipient, owner, x, y, elapsed, duration, basis,
-- dest, origin, damage, unitType.
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
	if duration == nil and ft ~= "VOLUNTEER" then duration = (ft == "CS_EXPEDITIONARY") and 10 or 20 end
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

local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	fn(EFV_Records.Get(s, id))
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end

-- Notifications of one type for pid sent on a turn (nil = any turn).
local function Sent(pid, name, turn)
	local out = {}
	for _, n in ipairs(H.notifs(pid, N(name))) do
		if turn == nil or n.turn == turn then out[#out + 1] = n end
	end
	return out
end

local function Summary(n) return n.data[ParameterTypes.SUMMARY] end

-- Runs an expired unit outside valid territory into MUTINY at damage 40
-- (E .. E+6). Returns id, unit.
local function IntoMutiny40(S, opts)
	local p = H.neutralPlot(30, 5)
	opts = opts or {}
	opts.elapsed = 19; opts.x = p:GetX(); opts.y = p:GetY()
	local id, u = Deploy(S, opts)
	H.turns(7)
	H.eq(Rec(id).state, "MUTINY"); H.eq(u:GetDamage(), 40)
	return id, u
end

-- ===========================================================================
-- P2.1 timeline
-- ===========================================================================
test("P2.1: GRACE 5..1 then 20 dmg/turn, death on the predicted turn; both players, own texts", function()
	local S = H.baseScenario()
	Players[1].human = true                           -- recipient human: sees its own texts
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	local unit, sender, recipient = EFV_UnitDisplayName("UNIT_SWORDSMAN"), EFV_PlayerName(0), EFV_PlayerName(1)
	H.endTurn()
	local E = FAKE.turn
	local predictedDeath = E + EFV_Config.GRACE_TURNS + math.ceil(100 / EFV_Config.MUTINY_DAMAGE_PER_TURN) - 1
	H.eq(predictedDeath, E + 9, "spec 9.1: 5 grace + 5 mutiny turns from full HP")
	for left = 5, 1, -1 do
		local r = Rec(id)
		H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, left)
		local g1, g0 = Sent(1, "GRACE", FAKE.turn), Sent(0, "GRACE", FAKE.turn)
		H.len(g1, 1, "recipient GRACE at turn " .. FAKE.turn); H.len(g0, 1, "sender GRACE")
		H.eq(Summary(g1[1]), Locale.Lookup("LOC_EFV_NOTIF_GRACE_SUMMARY", unit, sender, left), "recipient text")
		H.eq(Summary(g0[1]), Locale.Lookup("LOC_EFV_NOTIF_GRACE_SENDER_SUMMARY", unit, recipient, left), "sender text")
		H.eq(g0[1].data.EFV_RecordID, id); H.eq(g0[1].data.EFV_Kind, "GRACE")
		H.eq(g0[1].data.AlwaysAutoActivate, true, "D9 map focus")
		H.deq(g0[1].data[ParameterTypes.LOCATION], { x = p:GetX(), y = p:GetY() })
		H.eq(u:GetDamage(), 0, "no damage during grace")
		H.endTurn()
	end
	for i, dmg in ipairs({ 20, 40, 60, 80 }) do
		local r = Rec(id)
		H.eq(FAKE.turn, E + 4 + i)
		H.eq(r.state, "MUTINY"); H.eq(u:GetDamage(), dmg); H.eq(r.lastDamage, dmg)
		local m0, m1 = Sent(0, "MUTINY", FAKE.turn), Sent(1, "MUTINY", FAKE.turn)
		H.len(m0, 1); H.len(m1, 1)
		H.eq(Summary(m1[1]), Locale.Lookup("LOC_EFV_NOTIF_MUTINY_SUMMARY", unit, 5 - i, sender), "N = turns to death")
		H.eq(Summary(m0[1]), Locale.Lookup("LOC_EFV_NOTIF_MUTINY_SENDER_SUMMARY", unit, 5 - i, recipient))
		H.len(Sent(0, "GRACE", FAKE.turn), 0, "no GRACE once in mutiny")
		H.endTurn()
	end
	H.eq(FAKE.turn, predictedDeath)
	H.isnil(Rec(id), "record deleted at the predicted turn")
	H.ok(not H.unitAlive(u), "unit removed")
	H.eq(FAKE.killLog[#FAKE.killLog].how, "DESTROY", "explicit silent removal, not a kill by damage")
	H.len(Sent(0, "MUTINY_DEATH", FAKE.turn), 1); H.len(Sent(1, "MUTINY_DEATH", FAKE.turn), 1)
	H.ok(H.hasLine("[Mutiny] death"))
	H.clean()
end)

test("P2.1: a damaged unit dies proportionally sooner (50 dmg -> death at E+7)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY(), damage = 50 })
	H.endTurn()
	local E = FAKE.turn
	H.turns(5)                                        -- E+5: 70
	H.eq(u:GetDamage(), 70)
	H.eq(Summary(Sent(0, "MUTINY", FAKE.turn)[1]),
		Locale.Lookup("LOC_EFV_NOTIF_MUTINY_SENDER_SUMMARY", EFV_UnitDisplayName("UNIT_SWORDSMAN"), 2, EFV_PlayerName(1)))
	H.endTurn()                                       -- E+6: 90
	H.eq(u:GetDamage(), 90)
	H.endTurn()                                       -- E+7: 90 + 20 >= 100
	H.eq(FAKE.turn, E + 7)
	H.isnil(Rec(id)); H.ok(not H.unitAlive(u))
	H.clean()
end)

test("P2.1: AI recipient gets nothing; CS recipient (city-state) too; sender always", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, basis = "CITY_STATE",
		elapsed = 9, x = p:GetX() + 1, y = p:GetY() })
	H.endTurn()
	H.len(Sent(0, "GRACE", FAKE.turn), 2, "sender: one GRACE per record")
	H.len(Sent(1, "GRACE"), 0); H.len(Sent(4, "GRACE"), 0)
	H.clean()
end)

-- ===========================================================================
-- P2.2 returns
-- ===========================================================================
test("P2.2: grace -> sender territory at E+2 returns at E+3 (GRACE_RETURN); alerts stop", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.turns(3)                                        -- E, E+1, E+2
	H.eq(Rec(id).graceTurnsLeft, 3)
	H.moveUnit(u, S.c0.x + 1, S.c0.y + 1)             -- player 0's borders
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "GRACE_RETURN")
	H.isnil(r.graceTurnsLeft); H.isnil(r.onMapUnitID)
	H.ok(not H.unitAlive(u))
	H.len(Sent(0, "GRACE", FAKE.turn), 0, "no GRACE on the return turn")
	H.len(Sent(0, "RETURNING", FAKE.turn), 1)
	H.clean()
end)

test("P2.2: mutiny unit healed at round end then moved home returns with the FLOORED damage", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	H.moveUnit(u, S.c1.x + 1, S.c1.y)                 -- recipient territory
	H.endTurn{ heal = 15 }                            -- engine heal 40 -> 25 before OnGameTurnStarted
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "MUTINY_RETURN")
	H.eq(r.damage, 40, "healing during mutiny is cancelled before the return snapshot")
	H.isnil(r.lastDamage)
	H.turns(r.arrivalTurn - FAKE.turn)
	local back = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(back, 1)
	H.eq(back[1]:GetDamage(), 40, "returned unit keeps its damage")
	H.clean()
end)

-- ===========================================================================
-- P2.3 heal cancel at every hook point
-- ===========================================================================
test("P2.3(a..c): heal at round end / owner's turn start / owner's action is floored at the next hook", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	-- (b) ROBUSTNESS ONLY (never happens in game, Session E): heal between
	-- PlayerTurnStarted(1) and PlayerTurnStartComplete(1).
	local seenB = nil
	H.endTurn{ startHeal = 15, act = function(p) if p == 1 then seenB = u:GetDamage() end end }
	H.eq(seenB, 40, "floored at PlayerTurnStartComplete(owner)")
	H.ok(H.hasLine("[Floor] restore id=" .. id .. " hook=PlayerTurnStartComplete"))
	H.eq(u:GetDamage(), 60, "then the mutiny step")
	-- (c) mid-turn heal in the owner's action phase (medic, pillage, heal on kill).
	local seenC = nil
	H.endTurn{ act = function(p)
		if p == 1 then u.damage = 45 elseif p == 2 then seenC = u:GetDamage() end
	end }
	H.eq(seenC, 60, "floored at the next player's PlayerTurnStarted")
	H.ok(H.hasLine("[Floor] restore id=" .. id .. " hook=PlayerTurnStarted"))
	H.eq(u:GetDamage(), 80)
	-- (a) end-of-round heal (S8 CONFIRMED, Session E): floored at
	-- OnGameTurnEnded, then death at the next turn start.
	H.endTurn{ heal = 30 }
	H.isnil(Rec(id), "80 -> healed 50 -> floored 80 -> +20 = death")
	H.ok(H.hasLine("[Floor] restore id=" .. id .. " hook=OnGameTurnEnded"))
	H.clean()
end)

test("Session E: the round heal is reset at OnGameTurnEnded (same round); step 0d then restores nothing", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	local T = FAKE.turn
	local seenAtEnd, turnAtEnd = nil, nil
	GameEvents.OnGameTurnEnded.Add(function(t) seenAtEnd = u:GetDamage(); turnAtEnd = Game.GetCurrentGameTurn() end)
	H.markBody()
	H.endTurn{ heal = 10 }                            -- engine heal 40 -> 30 after the last player's turn
	H.eq(turnAtEnd, T, "OnGameTurnEnded runs in the ending turn")
	H.eq(seenAtEnd, 40, "already floored when the round ends")
	H.ok(H.hasLine("[Floor] restore id=" .. id .. " hook=OnGameTurnEnded healed=10"))
	H.ok(not H.hasLine("hook=OnGameTurnStarted healed"), "safety net found nothing")
	H.ok(not H.hasLine("[Floor] restore id=" .. id .. " hook=PlayerTurnStart"), "no per-player pass saw a heal")
	H.eq(u:GetDamage(), 60, "then +20 at the turn start")
	H.len(Sent(0, "MUTINY", FAKE.turn), 1)
	H.clean()
end)

test("Session E: without OnGameTurnEnded the OnGameTurnStarted safety net still floors the heal", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	GameEvents.OnGameTurnEnded.handlers = {}          -- the event never arrives
	H.markBody()
	H.endTurn{ heal = 10 }
	H.ok(H.hasLine("[Floor] restore id=" .. id .. " hook=OnGameTurnStarted healed=10"))
	H.eq(u:GetDamage(), 60)
	H.clean()
end)

test("P2.3(d): human recipient heals its mutiny unit during its own turn -> floored at the first AI start", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	u.damage = 10                                     -- the human recipient uses a medic / heals now
	local seen = nil
	H.endTurn{ act = function(p) if p == 2 then seen = u:GetDamage() end end }
	H.eq(seen, 40, "restored at PlayerTurnStarted(2), the end of the human's turn")
	H.eq(u:GetDamage(), 60)
	H.eq(Rec(id).lastDamage, 60)
	H.clean()
end)

test("P2.3(e): no heal at all (GS strategic-resource gate): nothing restored, timeline unchanged", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	local seen = {}
	H.turns(5)
	for _ = 1, 4 do
		H.endTurn()
		seen[#seen + 1] = u:GetDamage()
	end
	H.deq(seen, { 20, 40, 60, 80 })
	H.ok(not H.hasLine("[Floor] restore"), "the floor never assumes a heal happened")
	H.endTurn()
	H.isnil(Rec(id))
	H.clean()
end)

test("P2.3(f): combat damage during mutiny raises the floor; death comes earlier", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	H.endTurn{ act = function(p) if p == 3 then u.damage = 70 end end }   -- enemy attack
	H.ok(H.hasLine("[Floor] raise id=" .. id))
	H.eq(u:GetDamage(), 90, "70 + 20")
	H.eq(Rec(id).lastDamage, 90)
	H.endTurn()
	H.isnil(Rec(id), "90 + 20 >= 100: death")
	H.clean()
end)

test("P2.3: heal at every hook point at once still never lowers damage between [Mutiny] steps", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() })
	H.turns(5)
	local seen = {}
	for _ = 1, 4 do
		H.endTurn{ heal = 10, startHeal = 10, act = function(pid) if pid == 1 then u.damage = math.max(0, u.damage - 10) end end }
		seen[#seen + 1] = u:GetDamage()
	end
	H.deq(seen, { 20, 40, 60, 80 })
	H.clean()
end)

-- ===========================================================================
-- EXPIRY_SOON
-- ===========================================================================
test("EXPIRY_SOON exactly at 3 and 1 turns left, both players, own texts; none at 4, 2, 0", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local id = Deploy(S, { elapsed = 15 })            -- next turn: left 4
	local unit = EFV_UnitDisplayName("UNIT_SWORDSMAN")
	local expect = { [4] = 0, [3] = 1, [2] = 0, [1] = 1 }
	for left = 4, 1, -1 do
		H.endTurn()
		H.len(Sent(0, "EXPIRY_SOON", FAKE.turn), expect[left], "sender, left " .. left)
		H.len(Sent(1, "EXPIRY_SOON", FAKE.turn), expect[left], "recipient, left " .. left)
		if expect[left] == 1 then
			H.eq(Summary(Sent(1, "EXPIRY_SOON", FAKE.turn)[1]),
				Locale.Lookup("LOC_EFV_NOTIF_EXPIRY_SOON_SUMMARY", unit, left, EFV_PlayerName(0)))
			H.eq(Summary(Sent(0, "EXPIRY_SOON", FAKE.turn)[1]),
				Locale.Lookup("LOC_EFV_NOTIF_EXPIRY_SOON_SENDER_SUMMARY", unit, left, EFV_PlayerName(1)))
		end
	end
	H.endTurn()                                       -- left 0: expiry (inside B's borders)
	H.len(Sent(0, "EXPIRY_SOON", FAKE.turn), 0)
	H.eq(Rec(id).state, "RETURNING")
	H.clean()
end)

test("EXPIRY_SOON for CS Expeditionary at 3 and 1 (duration 10); never for Volunteers", function()
	local S = H.baseScenario()
	H.loadEFV()
	Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, basis = "CITY_STATE", elapsed = 6 })
	Deploy(S, { forceType = "VOLUNTEER", elapsed = 6 })
	local turns = {}
	for _ = 1, 3 do
		H.endTurn()
		turns[#turns + 1] = #Sent(0, "EXPIRY_SOON", FAKE.turn)
	end
	H.deq(turns, { 1, 0, 1 }, "CS left 3, 2, 1; the Volunteer adds nothing")
end)

-- ===========================================================================
-- Unit identity (Session C item 2)
-- ===========================================================================
test("identity: FindID slot reuse -> missing; an upgrade of the recorded type is accepted", function()
	H.world{}
	H.loadEFV()
	local a = H.unit(1, "UNIT_SWORDSMAN", 5, 5)
	H.eq(EFV_Units.Get(1, a.id, "UNIT_SWORDSMAN"), a)
	H.killUnit(a)
	local b = H.unitInSlot(a, 1, "UNIT_WARRIOR", 6, 6)
	H.ne(b.id, a.id)
	H.eq(b.id % 65536, a.id % 65536, "same slot")
	H.eq(Players[1]:GetUnits():FindID(a.id), b, "fake engine: FindID resolves the slot (Session C)")
	H.isnil(EFV_Units.Get(1, a.id), "different unit in the slot -> missing")
	H.isnil(EFV_Units.Get(1, a.id, "UNIT_WARRIOR"), "even with a matching type")
	H.ok(H.hasLine("stale ID pid=1 uid=" .. a.id .. " why=ID"))
	H.eq(EFV_Units.Get(1, b.id), b, "the new unit by its own ID")
	-- Upgrade keeping the ID (T26 open): accepted along GameInfo.UnitUpgrades.
	local c = H.unit(1, "UNIT_SWORDSMAN", 7, 7)
	c.typeIndex = GameInfo.Units["UNIT_MUSKETMAN"].Index; c.typeName = "UNIT_MUSKETMAN"
	H.ok(EFV_IsUpgradeOf("UNIT_MUSKETMAN", "UNIT_SWORDSMAN"), "Swordsman -> Man-at-Arms -> Musketman")
	H.eq(EFV_Units.Get(1, c.id, "UNIT_SWORDSMAN"), c, "upgrade accepted")
	c.typeIndex = GameInfo.Units["UNIT_ARCHER"].Index; c.typeName = "UNIT_ARCHER"
	H.isnil(EFV_Units.Get(1, c.id, "UNIT_SWORDSMAN"), "unrelated type -> missing")
	H.isnil(EFV_Units.Get(2, c.id), "other owner")
	H.clean()
end)

test("identity: mutiny unit killed, slot reused by a new unit -> record closed (KILLED), new unit untouched", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	local x, y = u:GetX(), u:GetY()
	GameEvents.OnCombatOccurred(3, 999, 1, u.id, nil, nil)   -- killed by C in combat
	H.killUnit(u)
	local nu = H.unitInSlot(u, 1, "UNIT_SWORDSMAN", x, y)     -- same type, same tile, same slot
	H.endTurn()
	H.isnil(Rec(id), "record closed")
	H.eq(#Sent(0, "UNIT_LOST", FAKE.turn), 1)
	H.ok(H.hasLine("class=KILLED"))
	H.ok(H.unitAlive(nu), "the new unit was not removed")
	H.eq(nu:GetDamage(), 0, "and not damaged by the mutiny step")
	H.len(Sent(0, "MUTINY", FAKE.turn), 0)
	H.clean()
end)

test("identity: expired unit disbanded, slot reused -> DISBANDED; the new unit is not sent home", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 19 })         -- would expire (and return) next turn
	H.killUnit(u)
	local nu = H.unitInSlot(u, 1, "UNIT_SWORDSMAN", u.x, u.y)
	H.endTurn()
	H.isnil(Rec(id))
	H.ok(H.hasLine("class=DISBANDED"))
	H.ok(H.unitAlive(nu)); H.eq(nu:GetOwner(), 1)
	H.len(H.records(), 0, "no RETURNING record for the new unit")
	H.clean()
end)

test("identity: an upgraded tracked unit (same ID) stays tracked; the snapshot moves unitType along", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.endTurn{ act = function(pid)
		if pid == 1 then u.typeIndex = GameInfo.Units["UNIT_MAN_AT_ARMS"].Index; u.typeName = "UNIT_MAN_AT_ARMS" end
	end }
	local r = Rec(id)
	H.eq(r.state, "DEPLOYED")
	H.eq(r.unitType, "UNIT_MAN_AT_ARMS", "tracked through the upgrade")
	H.clean()
end)

-- ===========================================================================
-- Turn-boundary abstraction (Session C item 1): 1 human + several AIs
-- ===========================================================================
test("turn boundary: each player's end-of-turn state is snapshotted before the next player starts", function()
	local S = H.baseScenario()
	H.loadEFV()
	-- Units owned by AI 1, AI 2, city-state 4 (followed by 62, 63) and the human 0 (a Volunteer).
	local id1, u1 = Deploy(S, { elapsed = 2 })
	local id2, u2 = Deploy(S, { recipient = 2, dest = S.c2, basis = "FRIEND", elapsed = 2 })
	local id4, u4 = Deploy(S, { forceType = "CS_EXPEDITIONARY", recipient = 4, dest = S.c4, basis = "CITY_STATE", elapsed = 2 })
	local id0, u0 = Deploy(S, { forceType = "VOLUNTEER", elapsed = 2 })
	-- The human (0) acts first, in its own turn: move and damage its Volunteer.
	u0.damage = 7; H.moveUnit(u0, S.c1.x + 2, S.c1.y)
	local seen = {}
	local owners = { [1] = { id1, u1 }, [2] = { id2, u2 }, [4] = { id4, u4 } }
	H.endTurn{ act = function(p, t)
		seen[p] = { r0 = Rec(id0), r1 = Rec(id1), r2 = Rec(id2), r4 = Rec(id4) }
		local o = owners[p]
		if o ~= nil then
			o[2].damage = 10 + p
			H.moveUnit(o[2], o[2].x, o[2].y + 1)
		end
	end }
	local T = FAKE.turn - 1
	-- human 0 -> snapshot at PlayerTurnStarted(1)
	H.eq(seen[1].r0.damage, 7); H.eq(seen[1].r0.lastX, S.c1.x + 2); H.eq(seen[1].r0.snapTurn, T)
	-- AI 1 -> seen at 2's action; AI 2 -> at 3's; CS 4 -> at 62's
	H.eq(seen[2].r1.damage, 11); H.eq(seen[2].r1.lastY, u1.y)
	H.eq(seen[3].r2.damage, 12); H.eq(seen[3].r2.lastY, u2.y)
	H.eq(seen[62].r4.damage, 14); H.eq(seen[62].r4.lastY, u4.y)
	-- and never before the owner acted
	H.eq(seen[1].r1.damage, 0, "AI 1 had not acted yet at its own action start")
	H.ok(not H.hasLine("OnPlayerTurnEnded"), "OnPlayerTurnEnded never fired")
	H.clean()
end)

test("turn boundary: idempotent; the legacy OnPlayerTurnEnded cannot double-process", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = IntoMutiny40(S)
	-- Repeated passes without a game change write nothing.
	local writes = FAKE.propWrites[EFV_Config.PROP.RECORDS] or 0
	local store = EFV_Records.Load()
	for _ = 1, 3 do
		EFV_Lifecycle.TurnBoundaryPass(store, FAKE.turn, "test", -1, nil)
	end
	EFV_Records.Commit(store)
	for pid = 0, 4 do GameEvents.OnPlayerTurnEnded(pid) end
	GameEvents.OnPlayerTurnEnded(4)                   -- same hook, same player, same turn
	H.ok(H.hasLine("boundary repeat skipped"))
	H.eq(FAKE.propWrites[EFV_Config.PROP.RECORDS] or 0, writes, "no record writes")
	-- A full turn with the legacy event firing everywhere = the same result.
	u.damage = 30
	H.endTurn{ legacyTurnEnded = true, heal = 5 }
	H.eq(u:GetDamage(), 60, "40 floored once, +20 once")
	H.eq(Rec(id).lastDamage, 60)
	H.len(Sent(0, "MUTINY", FAKE.turn), 1, "one MUTINY per turn")
	H.clean()
end)

test("turn boundary: registration lines; PlayerTurnStarted is hooked, OnPlayerTurnEnded kept as extra", function()
	H.baseScenario()
	H.loadEFV()
	local lines = H.lines("[Init] registered", true)
	local all = table.concat(lines, "\n")
	H.ok(string.find(all, "GameEvents.PlayerTurnStarted", 1, true) ~= nil)
	H.ok(string.find(all, "GameEvents.PlayerTurnStartComplete", 1, true) ~= nil)
	H.ok(string.find(all, "GameEvents.OnPlayerTurnEnded", 1, true) ~= nil)
	H.ok(string.find(all, "GameEvents.OnGameTurnEnded", 1, true) ~= nil, "Session E")
	H.len(lines, 11, "11 hooks")
end)

-- ===========================================================================
-- D9 tracker UI (EFV_Tracker)
-- ===========================================================================
local function BootUI()
	local S = H.baseScenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local tr = FAKE_UI.LoadContext("EFV/UI/EFV_Tracker.lua")
	FAKE_UI.looked = {}
	UI.LookAtPlot = function(x, y) FAKE_UI.looked[#FAKE_UI.looked + 1] = { "own", x, y } end
	UI.LookAtPlotScreenPosition = function(x, y) FAKE_UI.looked[#FAKE_UI.looked + 1] = { "look", x, y } end
	H.markBody()
	return S, tr
end

local function G(fn, ...) FAKE_UI.AsGameplay(fn, ...) end

-- Delivers NotificationAdded for every notification sent since index `from`.
local function Deliver(from)
	for i = from + 1, #FAKE.notifications do
		local n = FAKE.notifications[i]
		Events.NotificationAdded(n.pid, n.id)
	end
	return #FAKE.notifications
end

test("D9 UI: banner shows N / M, cycles the camera through alert units (mutiny first), hides when clear", function()
	local S, tr = BootUI()
	local p = H.neutralPlot(30, 5)
	local idG, idM, uG, uM
	G(function()
		idG, uG = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
		idM, uM = Deploy(S, { elapsed = 3, x = p:GetX() + 1, y = p:GetY() })
		Deploy(S, { elapsed = 3 })                    -- DEPLOYED: no alert
		EditRecord(idG, function(r) r.state = "GRACE"; r.graceTurnsLeft = 3 end)
		EditRecord(idM, function(r) r.state = "MUTINY"; r.lastDamage = 40 end)
	end)
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	H.ok(not C.AlertBanner:IsHidden(), "banner visible")
	H.eq(C.BannerLabel:GetText(), Locale.Lookup("LOC_EFV_BANNER_ALERT", 2, 1))
	H.ok(string.find(C.BannerButton.tooltip, Locale.Lookup("LOC_EFV_STATE_GRACE", 3), 1, true) ~= nil, "tooltip lists states")
	C.BannerButton:Click()
	H.deq(FAKE_UI.looked[1], { "look", uM.x, uM.y }, "mutiny unit first (AI-owned: look only)")
	C.BannerButton:Click()
	H.deq(FAKE_UI.looked[2], { "look", uG.x, uG.y })
	C.BannerButton:Click()
	H.deq(FAKE_UI.looked[3], { "look", uM.x, uM.y }, "cycles")
	G(function()
		EditRecord(idG, function(r) r.state = "DEPLOYED"; r.graceTurnsLeft = nil end)
		EditRecord(idM, function(r) r.state = "DEPLOYED"; r.lastDamage = nil end)
	end)
	Events.PlayerTurnActivated(0, true)
	H.ok(C.AlertBanner:IsHidden(), "no alerts -> hidden")
	H.clean()
end)

test("D9 UI: own unit in grace (Volunteer) is selected and looked at", function()
	local S, tr = BootUI()
	local p = H.neutralPlot(30, 5)
	local id, u
	G(function()
		id, u = Deploy(S, { forceType = "VOLUNTEER", elapsed = 3, x = p:GetX(), y = p:GetY() })
		EditRecord(id, function(r) r.state = "GRACE"; r.graceTurnsLeft = 2; r.lapsed = 1; r.lapseReason = "WAR" end)
	end)
	Events.LoadGameViewStateDone()
	tr.Controls.BannerButton:Click()
	H.eq(FAKE_UI.selectedUnit, u)
	H.deq(FAKE_UI.looked[1], { "own", u.x, u.y })
end)

test("D9 UI: alert sound once per turn; older GRACE copies and copies of returned records dismissed", function()
	local S, tr = BootUI()
	local p = H.neutralPlot(30, 5)
	local id, u
	G(function() id, u = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() }) end)
	Events.LoadGameViewStateDone()
	local mark = #FAKE.notifications
	G(function() H.endTurn() end)                     -- E: GRACE 5
	mark = Deliver(mark)
	H.len(FAKE_UI.sounds or {}, 1, "ALERT_NEGATIVE on the GRACE notification")
	H.eq(FAKE_UI.sounds[1], "ALERT_NEGATIVE")
	local first = Sent(0, "GRACE")[1]
	G(function() H.endTurn() end)                     -- E+1: GRACE 4 (a second copy)
	mark = Deliver(mark)
	H.len(FAKE_UI.sounds, 2, "one sound per turn")
	local second = Sent(0, "GRACE")[2]
	H.ok(first.dismissed == true, "older copy of the same record dismissed")
	H.ok(not second.dismissed, "newest copy kept")
	-- Replaying the same notification in the same turn: no second sound.
	Events.NotificationAdded(0, second.id)
	H.len(FAKE_UI.sounds, 2)
	-- The unit returns: at the next turn activation every copy goes.
	G(function()
		H.moveUnit(u, S.c1.x + 1, S.c1.y)
		H.endTurn()
	end)
	mark = Deliver(mark)
	Events.PlayerTurnActivated(0, true)
	H.eq(Rec(id).state, "RETURNING")
	H.ok(second.dismissed == true, "copy of a record no longer in grace dismissed")
	H.ok(tr.Controls.AlertBanner:IsHidden())
	H.clean()
end)

test("D9 UI: MUTINY replaces the GRACE copy; MUTINY_DEATH plays the sound and clears the rest", function()
	local S, tr = BootUI()
	local p = H.neutralPlot(30, 5)
	local id
	G(function() id = Deploy(S, { elapsed = 19, x = p:GetX(), y = p:GetY() }) end)
	Events.LoadGameViewStateDone()
	local mark = #FAKE.notifications
	for _ = 1, 6 do
		G(function() H.endTurn() end)                 -- E .. E+5 (first MUTINY)
		mark = Deliver(mark)
	end
	for _, n in ipairs(Sent(0, "GRACE")) do
		H.ok(n.dismissed == true, "all GRACE copies dismissed once in mutiny")
	end
	H.ok(not Sent(0, "MUTINY")[1].dismissed)
	for _ = 1, 4 do
		G(function() H.endTurn() end)                 -- E+6 .. E+9 (death)
		mark = Deliver(mark)
	end
	H.isnil(Rec(id))
	H.len(Sent(0, "MUTINY_DEATH"), 1)
	for _, n in ipairs(Sent(0, "MUTINY")) do
		H.ok(n.dismissed == true, "every MUTINY copy dismissed after the death")
	end
	H.ok(not Sent(0, "MUTINY_DEATH")[1].dismissed, "the death notice stays")
	H.len(FAKE_UI.sounds, 10, "one alert sound per turn E .. E+9")
	H.clean()
end)

test("D9 UI: right-click opens the minimal list, alert rows first and red; row click focuses; ESC closes", function()
	local S, tr = BootUI()
	local p = H.neutralPlot(30, 5)
	local idM, uM
	G(function()
		Deploy(S, { elapsed = 3 })
		idM, uM = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
		EditRecord(idM, function(r) r.state = "MUTINY"; r.lastDamage = 60 end)
	end)
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	H.ok(C.TrackerPanel:IsHidden())
	C.BannerButton.callbacks[Mouse.eRClick]()
	H.ok(not C.TrackerPanel:IsHidden(), "open")
	local im
	for _, x in ipairs(FAKE_UI.ims) do if x.instName == "EFV_TrackerRowInstance" then im = x end end
	H.len(im.list, 2)
	H.ok(string.find(im.list[1].StateLabel:GetText(), "[COLOR:Red]", 1, true) == 1, "alert row first and red")
	-- WP7.2: short state label + turns column; the full sentence is in the row tooltip.
	H.eq(im.list[1].StateLabel:GetText(), "[COLOR:Red]" .. Locale.Lookup("LOC_EFV_TRACKER_ST_MUTINY") .. "[ENDCOLOR]")
	H.ok(string.find(im.list[1].RowButton.tooltip, Locale.Lookup("LOC_EFV_STATE_MUTINY", 2), 1, true) ~= nil)
	H.eq(im.list[1].TurnsLabel:GetText(), "[COLOR:Red]2[ENDCOLOR]")
	H.ok(not im.list[1].AlertHighlight:IsHidden(), "alert row highlighted")
	H.ok(string.find(im.list[2].StateLabel:GetText(), "[COLOR:Red]", 1, true) == nil, "normal row not red")
	H.ok(im.list[2].AlertHighlight:IsHidden())
	H.ok(C.TrackerEmptyLabel:IsHidden())
	im.list[1].RowButton:Click()
	H.ok(C.TrackerPanel:IsHidden(), "row click closes the list")
	H.deq(FAKE_UI.looked[1], { "look", uM.x, uM.y })
	C.BannerButton.callbacks[Mouse.eRClick]()
	H.ok(FAKE_UI.KeyTo(tr, Keys.VK_ESCAPE), "ESC handled while open")
	H.ok(C.TrackerPanel:IsHidden())
	H.ok(not FAKE_UI.KeyTo(tr, Keys.VK_ESCAPE), "ESC passes through while closed")
	H.clean()
end)

test("UI identity: a reused slot is not shown as the tracked unit (EFV_UI_TrackedUnit, mutiny N)", function()
	local S, tr = BootUI()
	local id, u, nu
	G(function()
		id, u = Deploy(S, { elapsed = 3 })
		EditRecord(id, function(r) r.state = "MUTINY"; r.lastDamage = 20 end)
		H.killUnit(u)
		nu = H.unitInSlot(u, 1, "UNIT_SWORDSMAN", u.x, u.y)
		nu.damage = 90
	end)
	local rec = EFV_UI_RecordForUnit(1, u.id)
	H.notnil(rec)
	H.eq(UnitManager.GetUnit(1, u.id), nu, "GetUnit resolves the slot")
	H.isnil(EFV_UI_TrackedUnit(rec), "identity check: missing")
	H.eq(EFV_UI_StateText(rec, FAKE.turn), Locale.Lookup("LOC_EFV_STATE_MUTINY", 4), "N from the record, not the other unit")
	H.clean()
end)
