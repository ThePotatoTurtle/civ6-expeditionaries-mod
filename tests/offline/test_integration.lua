-- @harness native
-- WP1.7 integration tests: cases from INTEGRATION_NOTES.md and the salvaged
-- smoke tests (tests/offline/wp14/smoke.lua, scratch_salvage/tests_wp13.lua)
-- that the other test files did not cover, run against the real modules on
-- the shared fake engine (which mirrors the Session A/B in-game facts:
-- UI-only methods are nil in gameplay, open borders come from deals, the
-- property round trip drops "" and {}).

local N = function(name) return "EFV_NOTIF_" .. name end
local function Only() local r = H.records(); H.len(r, 1, "exactly one record"); return r[1] end

-- Edits one record through the public store API (like the EFV_Dev "setfield").
local function EditRecord(id, fn)
	local s = EFV_Records.Load()
	local r = EFV_Records.Get(s, id)
	fn(r)
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
end

-- Sends a unit to B's capital and plays until it is DEPLOYED. Returns the record and the unit.
local function SendAndArrive(S, u)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = Only()
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "DEPLOYED")
	return r, Players[1]:GetUnits():FindID(r.onMapUnitID)
end

-- ---------------------------------------------------------------------------
-- Item 15: a returned unit is re-sendable (recreated for the sender, so its
-- original owner is the sender; the levy rule must not block it).
-- ---------------------------------------------------------------------------
test("returned unit is re-sendable (levy rule: original owner = sender after recreate)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r = SendAndArrive(S, H.unit(0, "UNIT_SWORDSMAN", 11, 10))
	EditRecord(r.id, function(rec) rec.deployedTurn = FAKE.turn - rec.durationTurns + 1 end)
	H.endTurn()
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "EXPIRED")
	H.turns(r.arrivalTurn - FAKE.turn)
	H.len(H.records(), 0, "returned home")
	local home = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	H.notnil(home)
	H.eq(home:GetOriginalOwner(), 0, "recreated for the sender")
	H.eq(EFV_UnitClass(home), "OK", "not treated as levied")
	H.endTurn()                                       -- moves restored
	H.deq(EFV_UnitSendReasons(home, 0, EFV_Records.Load()), {}, "eligible again")
	-- A unit whose original owner is someone else (levy, other mod's gift) stays excluded.
	local gift = H.unit(0, "UNIT_SWORDSMAN", 11, 11)
	gift.originalOwner = 2
	H.eq(select(2, EFV_UnitClass(gift)), "CLASS_NEVER")
	H.send(0, home, 1, S.c1, "EXPEDITIONARY", 999)
	H.eq(Only().state, "OUTBOUND", "second send accepted")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Items 27/29: the Game property round trip drops "" and {}; every record
-- field must be read nil-safe after Load.
-- ---------------------------------------------------------------------------
test("nil-safe load: empty promotions / names dropped by the property round trip", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.ok(FAKE.dropEmpty, "fake engine drops empty values like the game (Session B)")
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "EXPEDITIONARY", 999)
	local raw = H.prop(EFV_Config.PROP.RECORDS)
	local rawRec = raw["r" .. H.records()[1].id]
	H.isnil(rawRec.promotions, "empty promotions table not persisted")
	H.isnil(rawRec.veteranName, "no name stored")
	local r = Only()
	H.deq(r.promotions, {}, "Load normalises promotions")
	H.eq(r.lapsed, 0); H.eq(r.rerouted, 0); H.eq(r.spawnFailCount, 0)
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "DEPLOYED")
	local nu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.eq(nu:GetExperience():GetVeteranName(), "", "unnamed stays unnamed")
	H.deq(H.promotionTypes(nu), {})
	-- The empty EFV_PendingExhaust after exhaust is re-seeded silently on load.
	H.reloadEFV()
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Item 20: REQUEST_FAILED text arguments (recipient name, fee).
-- ---------------------------------------------------------------------------
test("REQUEST_FAILED names the recipient (NO_COMMON_WAR) and shows the fee (GOLD)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.peace(1, 3)                                     -- B no longer shares the war on C
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	local n = H.notifs(0, N("REQUEST_FAILED"))
	H.len(n, 1)
	local summary = n[1].data[ParameterTypes.SUMMARY]
	H.ok(string.find(summary, EFV_PlayerName(1), 1, true), "recipient name in: " .. summary)
	H.ok(not string.find(summary, "{", 1, true), "no unfilled placeholder: " .. summary)
	H.war(1, 3)
	H.setGold(0, 20)                                  -- band 2 Expeditionary fee is 36 (0.5.2 ruling)
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 11), 1, S.c1)
	n = H.notifs(0, N("REQUEST_FAILED"))
	summary = n[#n].data[ParameterTypes.SUMMARY]
	H.ok(string.find(summary, "36", 1, true), "fee in: " .. summary)
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Items 28/30: gameplay never uses HasOpenBordersFrom / IsCannotAttack /
-- IsFreeCities (nil in G); open borders come from the deal scan (T19).
-- ---------------------------------------------------------------------------
test("gameplay reads open borders from deals; FLAG_VOLUNTEER_FRIENDS_OB modes", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB, "DEALS", "default mode (Session A: no G reader)")
	H.isnil(Players[0]:GetDiplomacy().HasOpenBordersFrom, "nil in G (fake mirrors T09)")
	H.ok(not EFV_HasOpenBordersFrom(0, 2))
	H.isnil(EFV_VolunteerBasis(0, 2), "friend without open borders")
	H.openBorders(0, 2)                               -- F grants 0 open borders
	H.ok(EFV_HasOpenBordersFrom(0, 2), "deal scan finds the agreement")
	H.ok(not EFV_HasOpenBordersFrom(2, 0), "direction matters")
	H.eq(EFV_VolunteerBasis(0, 2), "FRIEND_OB")
	EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB = "OFF"
	H.ok(not EFV_HasOpenBordersFrom(0, 2), "OFF")
	EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB = "HAS_OB_FROM"
	H.ok(EFV_HasOpenBordersFrom(0, 2), "legacy value behaves like DEALS")
	-- Free Cities and the full-moves check (replaces ATTACKED) in G use the
	-- G-safe paths (GetMovesRemaining / GetMaxMoves, A23).
	H.eq(EFV_PlayerKind(62), "FREE_CITIES")
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { moves = 1 })
	H.contains(EFV_UnitSendReasons(u, 0, EFV_Records.Load()), "NOT_FULL_MOVES")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Item 1 / salvaged tests_wp13: EFV_Spawn delegates to the single search in
-- EFV_Rules; Valid reports the failing rule.
-- ---------------------------------------------------------------------------
test("EFV_Spawn delegates to EFV_Rules; Valid reports the failing rule", function()
	local S = H.baseScenario()
	H.loadEFV()
	local ringR, plotsR = EFV_SpawnCandidates(S.c1.x, S.c1.y, "LAND", 1, nil)
	local ringS, plotsS = EFV_Spawn.Candidates(S.c1.x, S.c1.y, "LAND", 1, nil)
	H.eq(ringS, ringR); H.len(plotsS, #plotsR)
	for i = 1, #plotsR do H.eq(plotsS[i]:GetIndex(), plotsR[i]:GetIndex()) end
	H.ok(EFV_Spawn.DryRun(S.c1.x, S.c1.y, "LAND", 1, nil))
	H.ok(not EFV_Spawn.DryRun(S.c1.x, S.c1.y, "SEA", 1, nil), "inland city: no naval tile")
	local ok, why = EFV_Spawn.Valid(Map.GetPlot(S.c1.x, S.c1.y), "LAND", 0)
	H.eq(ok, false); H.eq(why, "CITY", "another player's city centre")
	H.ok((EFV_Spawn.Valid(Map.GetPlot(S.c1.x, S.c1.y), "LAND", 1)), "own city centre is fine")
	local busy = H.unit(2, "UNIT_WARRIOR", S.c1.x + 1, S.c1.y)
	ok, why = EFV_Spawn.Valid(Map.GetPlot(busy.x, busy.y), "LAND", 1)
	H.eq(why, "UNITS", "occupied by any player (Create does not check stacking, T05)")
	ok, why = EFV_Spawn.Valid(Map.GetPlot(S.c1.x, S.c1.y), "SEA", 1)
	H.eq(why, "DOMAIN")
	local enemy = Map.GetPlot(S.c1.x - 2, S.c1.y + 3)
	enemy.owner = 3                                   -- C is at war with B
	ok, why = EFV_Spawn.Valid(enemy, "LAND", 1)
	H.eq(why, "WAR_OWNER")
	H.ok((EFV_Spawn.Valid(enemy, "LAND", 1, { ignoreWarOwner = true })), "ignoreWarOwner admits it (no caller since 1.0.4)")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Salvaged wp14/smoke.lua cases not covered elsewhere.
-- ---------------------------------------------------------------------------
test("double send of the same unit: second request is stale, fee charged once", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 36)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 36)
	H.len(H.records(), 1)
	H.eq(H.gold(0), 1000 - 36)
	H.ok(H.hasLine("reasons=REQ_STALE"))
	H.eq(#H.notifs(0, N("REQUEST_FAILED")), 1)
end)

test("turn-end snapshot (S9) without OnPlayerTurnEnded: taken at the recipient's turn end", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, nu = SendAndArrive(S, H.unit(0, "UNIT_SWORDSMAN", 11, 10))
	local seen = nil
	-- The AI recipient (1) moves and takes damage while it acts in turn T. The
	-- next boundary (PlayerTurnStarted(2)) must snapshot it: checked from
	-- player 2's action phase, i.e. before OnGameTurnStarted of T+1.
	H.endTurn{ act = function(p, t)
		if p == 1 then
			nu.damage = 30
			H.moveUnit(nu, S.c1.x + 1, S.c1.y + 1)
		elseif p == 2 then
			seen = Only()
		end
	end }
	H.ok(not H.hasLine("OnPlayerTurnEnded"), "the legacy event never fired")
	H.notnil(seen)
	H.eq(seen.damage, 30); H.eq(seen.lastX, S.c1.x + 1); H.eq(seen.lastY, S.c1.y + 1)
	H.eq(seen.snapTurn, FAKE.turn - 1, "snapshot taken in turn T, at the recipient's turn end")
	H.ok(H.hasLine("boundary hook=PlayerTurnStarted"), "boundary pass logged")
	r = Only()
	H.eq(r.snapTurn, FAKE.turn, "refreshed again in turn T+1")
	H.clean()
end)

test("expired unit outside valid territory enters GRACE (Phase 2), returns once back (GRACE_RETURN)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local r, nu = SendAndArrive(S, H.unit(0, "UNIT_SWORDSMAN", 11, 10))
	local away = H.neutralPlot(S.c2.x - 8, S.c2.y)
	H.moveUnit(nu, away:GetX(), away:GetY())
	EditRecord(r.id, function(rec) rec.deployedTurn = FAKE.turn - rec.durationTurns + 1 end)
	H.endTurn()
	r = Only()
	H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, 5)
	H.ok(H.hasLine("[Grace] start"))
	H.endTurn()
	H.eq(Only().graceTurnsLeft, 4)
	H.moveUnit(nu, S.c1.x + 1, S.c1.y)
	H.endTurn()
	r = Only()
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "GRACE_RETURN")
	H.clean()
end)

test("recipient eliminated in transit: cancelled at the next turn start (RECIPIENT_GONE), nothing spawned for it", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "EXPEDITIONARY", 999)
	local arrival = Only().arrivalTurn
	H.kill(1)
	H.turns(arrival - FAKE.turn)
	H.len(H.records(), 0, "cancelled at step 0b, no return trip")
	H.ok(H.hasLine("reason=RECIPIENT_GONE"))
	H.ok(H.hasLine("hook=OnGameTurnStarted"))
	H.len(H.unitsOf(1), 0, "nothing spawned for a dead player")
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1, "the unit is back with its sender")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Item 14: missing unit / city / unknown force -> REQ_STALE; destination
-- reason order.
-- ---------------------------------------------------------------------------
test("send validation: REQ_STALE cases and destination reason order", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local store = EFV_Records.Load()
	local ok, reasons = EFV_EvaluateSend(0, u, 1, S.c1, "NOPE", store)
	H.eq(ok, false); H.deq(reasons, { "REQ_STALE" }, "unknown force type")
	ok, reasons = EFV_EvaluateSend(0, nil, 1, S.c1, "EXPEDITIONARY", store)
	H.contains(reasons, "REQ_STALE", "missing unit")
	ok, reasons = EFV_EvaluateSend(0, u, 1, nil, "EXPEDITIONARY", store)
	H.contains(reasons, "REQ_STALE", "missing city")
	-- Enemy C: partner basis first, then war with recipient, then no common war.
	ok, reasons = EFV_EvaluateSend(0, u, 3, S.c3, "EXPEDITIONARY", store)
	H.deq(reasons, { "NOT_PARTNER", "AT_WAR_WITH_RECIPIENT", "NO_COMMON_WAR" })
	-- Phase 3: Volunteers are released. The gate stays a kill switch: an
	-- unreleased force type is rejected in gameplay too (FLAG_RELEASED).
	ok, reasons = EFV_EvaluateSend(0, u, 1, S.c1, "VOLUNTEER", store)
	H.ok(ok, "released -> ok")
	EFV_Config.FLAG_RELEASED.VOLUNTEER = false
	ok, reasons = EFV_EvaluateSend(0, u, 1, S.c1, "VOLUNTEER", store)
	H.eq(reasons[1], "NOT_IMPLEMENTED")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Session D item 3: Create returns nil on a plot the new owner may not enter.
-- ---------------------------------------------------------------------------
test("spawn: Create nil on the picked plot -> the next candidates are tried in the same call (Session D 3)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = Only()
	-- The engine refuses every ring-1 plot of B's capital: 6 ring-1 tries, then ring 2.
	FAKE.createNil = function(pid, x, y) return Map.GetPlotDistance(S.c1.x, S.c1.y, x, y) == 1 end
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "DEPLOYED", "arrived on the arrival turn")
	H.eq(r.spawnFailCount or 0, 0, "no SPAWN_BLOCKED")
	local pNew = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(pNew)
	H.eq(Map.GetPlotDistance(S.c1.x, S.c1.y, pNew:GetX(), pNew:GetY()), 2, "ring 2")
	H.len(FAKE.createRefused, 6, "six refused ring-1 plots")
	H.ok(H.hasLine("succeeded on try 7"))
	H.len(H.notifs(0, N("SPAWN_BLOCKED")), 0)
	H.clean()
end)

test("spawn: every try refused -> SPAWN_BLOCKED after SPAWN_CREATE_TRIES plots, retried next turn", function()
	local S = H.baseScenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = Only()
	FAKE.createNil = function() return true end
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "OUTBOUND"); H.eq(r.spawnFailCount, 1)
	H.len(FAKE.createRefused, EFV_Config.SPAWN_CREATE_TRIES, "bounded")
	H.len(H.notifs(0, N("SPAWN_BLOCKED")), 1)
	FAKE.createNil = nil
	H.endTurn()
	H.eq(Only().state, "DEPLOYED", "next turn it arrives")
	H.len(H.lines("ERROR"), 1, "one ERROR: recreate failed after all tries")
end, { allowErrors = true })

test("spawn: closed third-party borders (fake engine rule) are filtered by ACCESS before any Create", function()
	local S = H.baseScenario()
	H.loadEFV()
	-- A third major (2: no alliance with B, no open borders) owns ring 1 around B's capital.
	for _, p in ipairs(Map.GetNeighborPlots(S.c1.x, S.c1.y, 1)) do
		if Map.GetPlotDistance(S.c1.x, S.c1.y, p:GetX(), p:GetY()) == 1 then p.owner = 2 end
	end
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = Only()
	H.turns(r.arrivalTurn - FAKE.turn)
	r = Only()
	H.eq(r.state, "DEPLOYED")
	H.len(FAKE.createRefused, 0, "no refused Create")
	local pNew = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.ne(Map.GetPlot(pNew:GetX(), pNew:GetY()):GetOwner(), 2, "not in closed third-party land")
	H.clean()
end)
