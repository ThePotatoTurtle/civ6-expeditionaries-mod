-- ===========================================================================
-- harness.lua  (T2 offline harness)
-- Test helpers on top of fake_engine.lua: world building, EFV loading, turn
-- simulation, request firing, log/notification queries and assertions.
--
-- Test files (tests/offline/test_*.lua) register tests with
--   test("name", function() ... end, { xfail = "reason", tags = {...} })
-- Each test runs in a FRESH Lua state: fake engine + this file + the test
-- file, then the named test function. A test usually does:
--   H.world{ map = "MAPSIZE_STANDARD" }      -- map, players 0 (human), 1..
--   H.loadEFV()                              -- EFV_Gameplay.lua + includes
--   ... build units / cities / diplomacy, fire hooks, assert ...
-- ===========================================================================

H = {}
TESTS = {}

function test(name, fn, opts)
	TESTS[#TESTS + 1] = { name = name, fn = fn, opts = opts or {} }
end

-- Explicit expected-fail declaration (the ONLY way to get XFAIL from the runner):
--   test("name", fn, xfail("Phase 6 (WP6.1): Entrust gameplay"))
-- The reason must name the pending work package ("WPx.y") or phase ("Phase N");
-- run_tests.py rejects other reasons. Stubs hit during a test never excuse a
-- failure (Phase 5 runner fix).
function xfail(reason, opts)
	opts = opts or {}
	opts.xfail = reason
	return opts
end

-- ---------------------------------------------------------------------------
-- Assertions (errors start with "ASSERT" so the runner can tell them apart)
-- ---------------------------------------------------------------------------
local function Ser(v, depth)
	depth = depth or 0
	if type(v) == "table" then
		if depth > 4 then return "{...}" end
		local parts = {}
		for _, k in ipairs(FAKE.SortedKeys(v)) do
			local ks = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
			parts[#parts + 1] = ks .. "=" .. Ser(v[k], depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end
H.Ser = Ser

local function Fail(msg, level)
	error("ASSERT " .. msg, (level or 2) + 1)
end
H.fail = function(msg) Fail(msg, 2) end
-- (Phase 5: the runtime H.pending / H.pendingIf markers were removed. They
-- turned any failure behind a condition into XFAIL; use xfail(reason) on the
-- test declaration instead.)

function H.ok(v, msg)
	if not v then Fail((msg or "expected truthy") .. " (got " .. Ser(v) .. ")", 2) end
end
function H.eq(actual, expected, msg)
	if actual ~= expected then
		Fail((msg or "values differ") .. ": expected " .. Ser(expected) .. ", got " .. Ser(actual), 2)
	end
end
function H.ne(actual, notExpected, msg)
	if actual == notExpected then
		Fail((msg or "value must differ") .. ": got " .. Ser(actual), 2)
	end
end
function H.isnil(v, msg)
	if v ~= nil then Fail((msg or "expected nil") .. " (got " .. Ser(v) .. ")", 2) end
end
function H.notnil(v, msg)
	if v == nil then Fail(msg or "expected non-nil", 2) end
end
local function DeepEq(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not DeepEq(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end
H.deepEqual = DeepEq
function H.deq(actual, expected, msg)
	if not DeepEq(actual, expected) then
		Fail((msg or "tables differ") .. ":\n  expected " .. Ser(expected) .. "\n  got      " .. Ser(actual), 2)
	end
end
function H.contains(list, v, msg)
	for _, x in ipairs(list or {}) do
		if x == v then return end
	end
	Fail((msg or "list does not contain value") .. ": " .. Ser(v) .. " not in " .. Ser(list), 2)
end
function H.notContains(list, v, msg)
	for _, x in ipairs(list or {}) do
		if x == v then Fail((msg or "list must not contain value") .. ": " .. Ser(v), 2) end
	end
end
function H.len(list, n, msg)
	local got = list and #list or -1
	if got ~= n then Fail((msg or "length differs") .. ": expected " .. n .. ", got " .. got .. " " .. Ser(list), 2) end
end
function H.throws(fn, msg)
	local ok = pcall(fn)
	if ok then Fail(msg or "expected an error", 2) end
end

-- ---------------------------------------------------------------------------
-- World building
-- ---------------------------------------------------------------------------
-- H.world{ map = "MAPSIZE_STANDARD" | w = , h = , wrapX = true,
--          speed = "GAMESPEED_STANDARD", turn = 1,
--          players = { {id=0, human=true, gold=1000}, {id=1}, ... } }
-- Default players: 0 human major (gold 1000), 1 major, 2 major, 3 major,
-- 4 city-state, 62 Free Cities, 63 barbarian. No cities, no diplomacy.
function H.world(opts)
	opts = opts or {}
	local w, h = opts.w, opts.h
	local sizeName = opts.map or "MAPSIZE_STANDARD"
	if w == nil then
		local row = GameInfo.Maps[sizeName]
		if row == nil then error("unknown map size " .. tostring(sizeName)) end
		w, h = row.GridWidth, row.GridHeight
	end
	FAKE.NewMap(w, h, opts.wrapX, opts.terrain)
	local row = GameInfo.Maps[sizeName]
	FAKE.map.sizeHash = row and row.Hash or nil
	FAKE.turn = opts.turn or 1
	FAKE.gameSpeed = opts.speed or "GAMESPEED_STANDARD"
	local players = opts.players or {
		{ id = 0, human = true, gold = 1000 },
		{ id = 1, gold = 1000 },
		{ id = 2, gold = 1000 },
		{ id = 3, gold = 1000 },
		{ id = 4, kind = "CITY_STATE", gold = 0 },
		{ id = 62, kind = "FREE_CITIES" },
		{ id = 63, kind = "BARBARIAN" },
	}
	for _, p in ipairs(players) do
		FAKE.NewPlayer(p.id, p)
	end
	return FAKE.map
end

function H.player(id) return Players[id] end
function H.gold(pid) return Players[pid]:GetTreasury():GetGoldBalance() end
function H.setGold(pid, n) Players[pid]:GetTreasury():SetGoldBalance(n) end
function H.res(pid, resType) return Players[pid]:GetResources():GetResourceAmount(GameInfo.Resources[resType].Index) end
function H.setRes(pid, resType, n)
	local idx = GameInfo.Resources[resType].Index
	local r = Players[pid]:GetResources()
	r:ChangeResourceAmount(idx, n - r:GetResourceAmount(idx))
end

-- H.city(pid, x, y, { radius = 2, capital = bool, name = })
function H.city(pid, x, y, opts)
	return FAKE.NewCity(pid, x, y, opts)
end

-- H.unit(pid, "UNIT_SWORDSMAN", x, y, { damage, xp, promotions = {"PROMOTION_BATTLECRY"},
--        vet = "Name", moves, formation, embarked, attacks })
function H.unit(pid, typeName, x, y, opts)
	opts = opts or {}
	local u = FAKE.NewUnit(pid, typeName, x, y)
	if opts.damage then u.damage = opts.damage end
	if opts.xp then u.xp = opts.xp end
	if opts.vet then u.vetName = opts.vet end
	if opts.moves then u.moves = opts.moves end
	if opts.formation then u.formation = opts.formation end
	if opts.embarked then u.embarked = true end
	if opts.attacks then u.attacks = opts.attacks end
	for _, pt in ipairs(opts.promotions or {}) do
		local row = GameInfo.UnitPromotions[pt]
		if row == nil then error("unknown promotion " .. pt) end
		u.promotions[row.Index] = true
	end
	return u
end
function H.unitAlive(u) return u ~= nil and FAKE.units[u.id] ~= nil end
function H.unitsOf(pid, typeName)
	local out = {}
	for _, u in ipairs(FAKE.UnitsOf(pid)) do
		if typeName == nil or u.typeName == typeName then out[#out + 1] = u end
	end
	return out
end
function H.moveUnit(u, x, y) u.x, u.y = x, y end
function H.killUnit(u) FAKE.RemoveUnit(u, "DEATH") end

-- Session F models (0.5.2; fake_engine.lua "stale unit objects"):
-- H.combat(attacker, defender, dmgDef, dmgAtt): a fight between two unit
--   objects (either may be a table { owner = pid, id = uid } for an untracked
--   enemy). The damage is applied before GameEvents.OnCombatOccurred when
--   FAKE.combatDamageBeforeEvent (default; T31 open), else after it. A unit
--   reaching 100 is killed: its object stays findable for the rest of the
--   frame (FAKE.CombatKill, Session F T20).
local function ApplyCombatDamage(u, d)
	if u == nil or d == nil or d == 0 or FAKE.units[u.id] == nil then
		return
	end
	if u.damage + d >= 100 then
		FAKE.CombatKill(u)
	else
		u.damage = u.damage + d
	end
end
function H.combat(att, def, dmgDef, dmgAtt)
	local before = FAKE.combatDamageBeforeEvent
	if before then
		ApplyCombatDamage(def, dmgDef)
		ApplyCombatDamage(att, dmgAtt)
	end
	GameEvents.OnCombatOccurred(att.owner, att.id, def.owner, def.id, nil, nil)
	if not before then
		ApplyCombatDamage(def, dmgDef)
		ApplyCombatDamage(att, dmgAtt)
	end
end
-- An upgrade by the unit's owner (Session F T30): new unit, new ID, same plot;
-- the old object stays findable until OnGameTurnEnded. Returns the new unit.
function H.upgrade(u, newType) return FAKE.UpgradeUnit(u, newType) end
-- A levy / levy end (Session F T28): see FAKE.LevyTransfer.
function H.levy(from, to, orig, shift) return FAKE.LevyTransfer(from, to, orig, shift) end
-- The damage writes EFV made to a unit (FAKE.damageWrites entries).
function H.damageWritesTo(u)
	local out = {}
	for _, w in ipairs(FAKE.damageWrites) do
		if w.id == u.id then out[#out + 1] = w end
	end
	return out
end
-- A new unit of pid that reuses the slot of oldUnit's ID (Session C: FindID
-- by oldUnit's ID then returns this unit once oldUnit is gone).
function H.unitInSlot(oldUnit, pid, typeName, x, y)
	return FAKE.NewUnitInSlot(oldUnit.id, pid, typeName, x, y)
end
function H.promotionTypes(u)
	local out = {}
	for _, idx in ipairs(FAKE.SortedKeys(u.promotions)) do
		out[#out + 1] = GameInfo.UnitPromotions[idx].UnitPromotionType
	end
	table.sort(out)
	return out
end

function H.plot(x, y) return Map.GetPlot(x, y) end
function H.terrain(x, y, t) local p = Map.GetPlot(x, y); p.terrain = t; FAKE.map.areaDirty = true; return p end
function H.fill(x1, y1, x2, y2, t)
	for y = y1, y2 do
		for x = x1, x2 do H.terrain(x, y, t) end
	end
	FAKE.map.areaDirty = true
end
function H.own(x, y, pid) Map.GetPlot(x, y).owner = pid end
function H.ownRect(x1, y1, x2, y2, pid)
	for y = y1, y2 do
		for x = x1, x2 do Map.GetPlot(x, y).owner = pid end
	end
end
-- A plot owned by nobody (for GRACE tests): the first unowned land plot scanning from (x, y).
function H.neutralPlot(x, y)
	for r = 0, 20 do
		for _, p in ipairs(Map.GetNeighborPlots(x, y, r)) do
			if p.owner == -1 and not p:IsWater() and not p:IsImpassable() and p:GetUnitCount() == 0 then return p end
		end
	end
	error("no neutral plot near " .. x .. "," .. y)
end

-- Diplomacy (symmetric unless noted)
function H.war(a, b) FAKE.SetWar(a, b, true) end
function H.peace(a, b) FAKE.SetWar(a, b, false) end
function H.ally(a, b, v)
	if v == nil then v = true end
	FAKE.PairSet(FAKE.diplo.allied, a, b, v); FAKE.PairSet(FAKE.diplo.allied, b, a, v)
	FAKE.PairSet(FAKE.diplo.met, a, b, true); FAKE.PairSet(FAKE.diplo.met, b, a, true)
end
function H.friend(a, b, v)
	if v == nil then v = true end
	FAKE.PairSet(FAKE.diplo.friend, a, b, v); FAKE.PairSet(FAKE.diplo.friend, b, a, v)
	FAKE.PairSet(FAKE.diplo.met, a, b, true); FAKE.PairSet(FAKE.diplo.met, b, a, true)
end
-- a has open borders FROM b (b grants a); directional. opts (optional):
-- { enacted = turn (default: now), duration = turns (default 30) }; the
-- agreement then ends on turn enacted + duration (FAKE.ExpireOpenBorders).
function H.openBorders(a, b, v, opts)
	if v == nil then v = true end
	FAKE.PairSet(FAKE.diplo.ob, a, b, v)
	FAKE.obTerms[a] = FAKE.obTerms[a] or {}
	if v then
		opts = opts or {}
		FAKE.obTerms[a][b] = { enacted = opts.enacted or FAKE.turn, duration = opts.duration or 30 }
	else
		FAKE.obTerms[a][b] = nil
	end
end
function H.meet(a, b)
	FAKE.PairSet(FAKE.diplo.met, a, b, true); FAKE.PairSet(FAKE.diplo.met, b, a, true)
end
function H.team(pid, team) Players[pid].team = team end
function H.kill(pid) Players[pid].alive = false end

-- ---------------------------------------------------------------------------
-- Standard scenario (PLAN 5.0 "EFV_BASE" in miniature):
--   Standard map (84x54, wrap), players 0 (human) / 1 ally B / 2 friend F /
--   3 enemy C (at war with 0, 1, 2) / 4 city-state (at war with 3).
--   Cities: 0 at (10,10) capital + (14,20); 1 at (22,10) capital (band 2 from
--   (10,10): d = 12) + (18,12); 2 at (40,30); 3 at (70,40); 4 at (30,20).
-- Returns a table of handles.
-- ---------------------------------------------------------------------------
function H.baseScenario(opts)
	opts = opts or {}
	H.world(opts)
	local S = {}
	S.c0 = H.city(0, 10, 10, { capital = true, name = "LOC_CITY_A" })
	S.c0b = H.city(0, 14, 20, { name = "LOC_CITY_A2" })
	S.c1 = H.city(1, 22, 10, { capital = true, name = "LOC_CITY_B" })
	S.c1b = H.city(1, 18, 13, { name = "LOC_CITY_B2" })
	S.c2 = H.city(2, 40, 30, { capital = true, name = "LOC_CITY_F" })
	S.c3 = H.city(3, 70, 40, { capital = true, name = "LOC_CITY_C" })
	S.c4 = H.city(4, 30, 20, { capital = true, name = "LOC_CITY_CS" })
	H.ally(0, 1)
	H.friend(0, 2)
	H.war(3, 0); H.war(3, 1); H.war(3, 2); H.war(3, 4)
	H.meet(0, 4)
	return S
end

-- ---------------------------------------------------------------------------
-- Loading EFV
-- ---------------------------------------------------------------------------
-- Loads EFV_Config first (to raise LOG_LEVEL to 3 so stub lines are visible),
-- then runs Scripts/EFV_Gameplay.lua exactly like the engine's
-- AddGameplayScripts. Marks the log position where the test body starts, so
-- the runner only counts "[Stub]" lines emitted by the test itself.
function H.loadEFV(opts)
	opts = opts or {}
	include("EFV_Config")
	EFV_Config.LOG_LEVEL = opts.logLevel or 3
	for k, v in pairs(opts.flags or {}) do
		EFV_Config[k] = v
	end
	if opts.gameplay == false then
		include("EFV_Util")
		include("EFV_Rules")
	else
		FAKE.dofile("EFV/Scripts/EFV_Gameplay.lua")
	end
	H.markBody()
end

-- Simulates quitting to the main menu and loading the save: every EFV global
-- and event handler is dropped (fresh Lua state in the real game), Game
-- properties and the world survive, EFV_Gameplay.lua runs again.
function H.reloadEFV()
	for _, name in ipairs({ "EFV_Config", "EFV_Util", "EFV_Rules", "EFV_Records", "EFV_Notify", "EFV_Units",
		"EFV_Spawn", "EFV_Transit", "EFV_Lifecycle", "EFV_Entrust", "EFV_Gameplay" }) do
		_G[name] = nil
	end
	for _, ns in ipairs({ GameEvents, Events, LuaEvents }) do
		for name, ev in pairs(ns) do
			ev.handlers = {}
		end
	end
	local level = 3
	include("EFV_Config")
	EFV_Config.LOG_LEVEL = level
	FAKE.dofile("EFV/Scripts/EFV_Gameplay.lua")
end

function H.markBody()
	FAKE.bodyStart = #FAKE.log
end

-- ---------------------------------------------------------------------------
-- Turn simulation in the CONFIRMED in-game order (Session C T04, confirmed
-- for every round by Session E T26, SESSION_E_REPORT 2):
--   OnGameTurnStarted(N) > human PTS > PTSC > acts > every other living
--   player in ID order PTS > PTSC > acts (... p62, p63 Barbarians last) >
--   ENGINE HEAL (once per round) > GameEvents.OnGameTurnEnded(N) >
--   Events.TurnEnd(N) > OnGameTurnStarted(N+1)
-- H.endTurn() is the human pressing End Turn in turn T:
--   1. every alive NON-human player p, ascending:
--        PlayerTurnStarted(p) -> [opts.startHeal] -> moves restored ->
--        PlayerTurnStartComplete(p) -> opts.act(p, T) (the AI acts)
--   2. [opts.heal: the engine's round heal, S8] -> GameEvents.OnGameTurnEnded(T)
--      (turn still T) -> Events.TurnEnd(T); GameEvents.OnPlayerTurnEnded is
--      NOT fired (it never fires in GS single player); opts.legacyTurnEnded =
--      true fires it for every alive player after TurnEnd, to test the
--      harmless legacy registration
--   3. turn T+1 -> GameEvents.OnGameTurnStarted(T+1) -> Events.TurnBegin(T+1)
--   4. every alive HUMAN player p, ascending: PlayerTurnStarted(p) ->
--      [open-borders expiry + expulsion of p's units, Session D 2.3] ->
--      [opts.startHeal] -> moves restored -> PlayerTurnStartComplete(p)
--      (step 1 does the same for the AI players)
-- It returns while the human(s) play turn T+1 (the test body acts as the
-- human). Heal points:
--   opts.heal = n       the engine's round heal (the only one in game): every
--                       damaged unit heals n after the last player's turn and
--                       before OnGameTurnEnded(T), except units created by
--                       script (Create / InitUnit) during turn T: a unit does
--                       not heal in the round it is created (Session E 3.5)
--   opts.startHeal = n  ROBUSTNESS TEST ONLY (never happens in game, Session
--                       E): units of p heal n between PlayerTurnStarted(p) and
--                       PlayerTurnStartComplete(p)
--   opts.act = fn(p, T) called in each AI's action phase (mid-turn heals such
--                       as promotion / medic / heal on kill, combat, reading
--                       state as seen at that point)
-- ---------------------------------------------------------------------------
local function AliveAscending()
	local ids = PlayerManager.GetAliveIDs()
	table.sort(ids)
	return ids
end

local function IsHumanID(pid)
	local p = Players[pid]
	return p ~= nil and p:IsHuman() == true
end

-- Heals n. roundTurn ~= nil: the engine's round heal of that turn, which
-- skips units created by script in that turn.
local function Heal(pid, n, roundTurn)
	for _, u in pairs(FAKE.units) do
		if (pid == nil or u.owner == pid) and u.damage > 0
				and not (roundTurn ~= nil and u.scriptCreated and u.createdTurn == roundTurn) then
			u.damage = math.max(0, u.damage - n)
		end
	end
end

local function StartPlayerTurn(pid, opts)
	FAKE.ExpireGhosts("frame")   -- Session F: a dead unit's object lasts one frame
	GameEvents.PlayerTurnStarted(pid)
	-- Session D 2.3: expired open borders are removed and the owner's units
	-- are moved out between its PlayerTurnStarted and PlayerTurnStartComplete.
	FAKE.ExpireOpenBorders(pid)
	if opts.startHeal then Heal(pid, opts.startHeal) end
	for _, u in ipairs(FAKE.UnitsOf(pid)) do
		u.moves = u.maxMoves
		u.attacks = 1
	end
	GameEvents.PlayerTurnStartComplete(pid)
end

function H.endTurn(opts)
	opts = opts or {}
	local T = FAKE.turn
	for _, pid in ipairs(AliveAscending()) do
		if not IsHumanID(pid) then
			StartPlayerTurn(pid, opts)
			if opts.act then opts.act(pid, T) end
		end
	end
	if opts.heal then Heal(nil, opts.heal, T) end
	FAKE.ExpireGhosts("turnEnd")   -- Session F T30: gone at OnGameTurnEnded
	GameEvents.OnGameTurnEnded(T)
	Events.TurnEnd(T)
	if opts.legacyTurnEnded then
		for _, pid in ipairs(AliveAscending()) do
			GameEvents.OnPlayerTurnEnded(pid)
		end
	end
	FAKE.turn = T + 1
	FAKE.ExpireGhosts("turnStart")   -- Session F T28: levied objects gone at the next turn start
	GameEvents.OnGameTurnStarted(FAKE.turn)
	Events.TurnBegin(FAKE.turn)
	for _, pid in ipairs(AliveAscending()) do
		if IsHumanID(pid) then
			StartPlayerTurn(pid, opts)
		end
	end
	return FAKE.turn
end

function H.turns(n, opts)
	for _ = 1, n do H.endTurn(opts) end
	return FAKE.turn
end

-- Fires a UI request the way EXECUTE_SCRIPT does: GameEvents[OnStart](playerID, params).
function H.request(pid, params)
	local p = FAKE.DeepCopy(params)
	GameEvents[p.OnStart](pid, p)
end

-- EFV_Send request for a unit and destination city.
function H.send(pid, unit, recipientID, city, forceType, expectedFee)
	H.request(pid, {
		OnStart = "EFV_Send", unitID = unit.id, recipientID = recipientID,
		destX = city.x, destY = city.y, forceType = forceType or "EXPEDITIONARY",
		expectedFee = expectedFee or 999999,
	})
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
function H.store() return EFV_Records.Load() end
function H.records()
	local s = EFV_Records.Load()
	local out = {}
	for _, id in ipairs(s.ids or {}) do out[#out + 1] = s.recs["r" .. id] end
	return out
end
function H.record(n)
	return H.records()[n or 1]
end
function H.prop(k) return Game:GetProperty(k) end

-- Notifications sent (after Flush). Filters: pid, typeName (either may be nil).
function H.notifs(pid, typeName)
	local out = {}
	for _, n in ipairs(FAKE.notifications) do
		if (pid == nil or n.pid == pid) and (typeName == nil or n.typeName == typeName) then
			out[#out + 1] = n
		end
	end
	return out
end
function H.clearNotifs() FAKE.notifications = {} end

-- Log lines (optionally only those containing a plain substring or matching a Lua pattern).
function H.lines(substr, fromStart)
	local out = {}
	local first = fromStart and 1 or ((FAKE.bodyStart or 0) + 1)
	for i = first, #FAKE.log do
		local l = FAKE.log[i]
		if substr == nil or string.find(l, substr, 1, true) then out[#out + 1] = l end
	end
	return out
end
function H.hasLine(substr) return #H.lines(substr) > 0 end
function H.errorLines()
	local out = {}
	for i = (FAKE.bodyStart or 0) + 1, #FAKE.log do
		local l = FAKE.log[i]
		if string.find(l, "%]%[[^%]]+%] ERROR ") or string.find(l, "Runtime Error", 1, true) then
			out[#out + 1] = l
		end
	end
	return out
end
-- Asserts that EFV logged no ERROR lines, no handler errors and no storage-rule violations.
function H.clean(msg)
	local errs = H.errorLines()
	if #errs > 0 then Fail((msg or "EFV logged errors") .. ":\n  " .. table.concat(errs, "\n  "), 2) end
	if #FAKE.propViolations > 0 then Fail("property storage violations:\n  " .. table.concat(FAKE.propViolations, "\n  "), 2) end
	if #FAKE.forbidden > 0 then Fail("MP-unsafe calls in gameplay: " .. table.concat(FAKE.forbidden, ", "), 2) end
end

-- Distance helper in the harness's own terms (for expected values).
function H.dist(a, b) return Map.GetPlotDistance(a.x, a.y, b.x, b.y) end
