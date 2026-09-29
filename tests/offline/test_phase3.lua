-- @harness native
-- Phase 3: Volunteer Force (PLAN 5.3; spec 9.2, 11, 14; DECISIONS D2, D3, D7,
-- Q2-Q4, "D2 reconfirmed", "Expelled Volunteers", "Mutiny duration", and
-- since 0.5.1 "Lapsed Volunteers on valid land" / "Healing during a paused
-- lapse": no auto-return, the lapse pauses on the sender's / recipient's land,
-- INTERFACES note 29; section "Paused lapse" below).
-- Runs on the fake engine with the confirmed in-game turn order (harness
-- H.endTurn), the gameplay open-borders deal scan (DealManager items with
-- GetFromPlayerID / GetEnactedTurn / GetDuration) and the engine's
-- open-borders expiry: on turn enacted + duration the deal is still listed at
-- OnGameTurnStarted and the receiver's units are moved to neutral land
-- outside the grantor's borders at its turn start (FAKE.ExpireOpenBorders,
-- Session D 2.3).
--
-- Scenario (H.baseScenario): 0 human (cities 10,10 / 14,20), 1 ally B
-- (22,10 / 18,13), 2 declared friend F (40,30), 3 enemy C at war with 0, 1,
-- 2 and city-state 4. City borders have radius 2.

local N = function(name) return "EFV_NOTIF_" .. name end

-- Creates a deployed Volunteer record for a unit of the sender already on
-- the map. opts: recipient (1), x, y, elapsed (turns since deployment),
-- basis ("ALLIANCE"), dest (city handle), damage.
local function Deploy(S, opts)
	opts = opts or {}
	local sender, recipient = 0, opts.recipient or 1
	local dest = opts.dest or ((recipient == 2) and S.c2 or S.c1)
	local x, y = opts.x or (dest.x + 1), opts.y or dest.y
	local u = H.unit(sender, opts.unitType or "UNIT_SWORDSMAN", x, y, { damage = opts.damage, xp = 20 })
	local store = EFV_Records.Load()
	local turn = Game.GetCurrentGameTurn()
	local band, d = EFV_Band(S.c0.x, S.c0.y, dest.x, dest.y)
	local rec = EFV_Records.New(store, {
		forceType = "VOLUNTEER", state = "DEPLOYED", senderID = sender, recipientID = recipient,
		accessBasis = opts.basis or "ALLIANCE",
		originCityID = S.c0.id, originX = S.c0.x, originY = S.c0.y,
		destCityID = dest.id, destX = dest.x, destY = dest.y, rerouted = 0,
		onMapPlayerID = sender, onMapUnitID = u.id,
		sentTurn = turn - (opts.elapsed or 0) - band, arrivalTurn = turn - (opts.elapsed or 0),
		transitTurns = band, band = band, distance = d,
		deployedTurn = turn - (opts.elapsed or 0),
		spawnFailCount = 0, feePaid = 144, maintGoldPaid = 0, lapsed = 0,
	})
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(u), turn)
	EFV_Records.Commit(store)
	H.clearNotifs()
	return rec.id, u
end

local function Rec(id) return EFV_Records.Get(EFV_Records.Load(), id) end
local function Count(pid, name, turn)
	local n = 0
	for _, x in ipairs(H.notifs(pid, N(name))) do
		if turn == nil or x.turn == turn then n = n + 1 end
	end
	return n
end
local function Recall(u) H.request(0, { OnStart = "EFV_Recall", unitID = u.id }) end
-- Summary text of the last REQUEST_FAILED notification to player 0.
local function LastFailure()
	local list = H.notifs(0, N("REQUEST_FAILED"))
	local n = list[#list]
	return n and n.data[ParameterTypes.SUMMARY] or nil
end
local function Has(text, key, ...)
	return text ~= nil and string.find(text, Locale.Lookup(key, ...), 1, true) ~= nil
end
local function OwnerAt(u) return Map.GetPlot(u.x, u.y):GetOwner() end
local function LineIndex(substr)
	for i, l in ipairs(FAKE.log) do
		if string.find(l, substr, 1, true) then return i end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Release and eligibility (D2, "D2 reconfirmed"; war overrides everything)
-- ---------------------------------------------------------------------------
test("release: Volunteers and Recall are released (FLAG_RELEASED), version 0.7.3-dev", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(EFV_Config.FLAG_RELEASED.VOLUNTEER, true)
	H.eq(EFV_Config.FLAG_RELEASED.RECALL, true)
	H.eq(EFV_Config.VERSION, "0.7.3-dev")
	local mi = __py_read("EFV/EFV.modinfo")
	H.ok(string.find(mi, "<en_US>Volunteers &amp; Expeditionary Forces v0.7.3-dev</en_US>", 1, true) ~= nil,
		"mod title = the designer's name")
end)

test("eligibility matrix: teammate / ally / friend+OB eligible; OB-only, friend-only, wrong direction, war are not", function()
	local S = H.baseScenario({ turn = 40 })
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local store = EFV_Records.Load()
	local function Eval(r, city)
		local ok, reasons, calc = EFV_EvaluateSend(0, u, r, city, "VOLUNTEER", store)
		return ok, reasons, calc
	end
	-- ally
	H.eq(EFV_VolunteerBasis(0, 1), "ALLIANCE")
	local ok, reasons, calc = Eval(1, S.c1)
	H.ok(ok, table.concat(reasons, ",")); H.eq(calc.basis, "ALLIANCE"); H.isnil(calc.duration, "no duration")
	-- declared friend without open borders
	H.isnil(EFV_VolunteerBasis(0, 2))
	ok, reasons = Eval(2, S.c2)
	H.eq(ok, false); H.eq(reasons[1], "VOL_NEEDS_ACCESS")
	-- the Expeditionary force still accepts the friend (D2 is Volunteer-only)
	H.ok((EFV_EvaluateSend(0, u, 2, S.c2, "EXPEDITIONARY", store)), "EXP to a friend")
	-- open borders in the wrong direction (0 grants 2)
	H.openBorders(2, 0)
	H.isnil(EFV_VolunteerBasis(0, 2), "wrong direction")
	-- friend + open borders granted by the recipient
	H.openBorders(0, 2)
	H.eq(EFV_VolunteerBasis(0, 2), "FRIEND_OB")
	ok, reasons, calc = Eval(2, S.c2)
	H.ok(ok, table.concat(reasons, ",")); H.eq(calc.basis, "FRIEND_OB")
	-- open borders without friendship
	H.friend(0, 2, false)
	H.isnil(EFV_VolunteerBasis(0, 2), "OB alone does not qualify")
	ok, reasons = Eval(2, S.c2)
	H.eq(reasons[1], "NOT_PARTNER")
	-- flag OFF: friends never qualify
	H.friend(0, 2)
	EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB = "OFF"
	H.isnil(EFV_VolunteerBasis(0, 2), "FLAG_VOLUNTEER_FRIENDS_OB OFF")
	EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB = "DEALS"
	-- teammate (friendship and open borders irrelevant)
	H.friend(0, 2, false); H.openBorders(0, 2, false)
	Players[2].team = Players[0].team
	H.eq(EFV_VolunteerBasis(0, 2), "TEAM")
	Players[2].team = 2
	-- war with each other overrides an alliance flag
	H.war(0, 1)
	FAKE.PairSet(FAKE.diplo.allied, 0, 1, true); FAKE.PairSet(FAKE.diplo.allied, 1, 0, true)
	H.isnil(EFV_VolunteerBasis(0, 1), "at war: no eligibility")
	ok, reasons = Eval(1, S.c1)
	H.contains(reasons, "AT_WAR_WITH_RECIPIENT")
	-- no common war
	H.peace(0, 1); H.peace(3, 2)
	H.friend(0, 2); H.openBorders(0, 2)
	ok, reasons = Eval(2, S.c2)
	H.contains(reasons, "NO_COMMON_WAR")
	H.clean()
end)

test("open-borders expiry prediction: enacted 44 + 30 is active on turn 73, ended on 74 while still listed", function()
	H.baseScenario({ turn = 73 })
	H.loadEFV()
	H.openBorders(0, 2, true, { enacted = 44, duration = 30 })
	H.eq(EFV_HasOpenBordersFrom(0, 2), true, "turn 73")
	H.eq(EFV_VolunteerBasis(0, 2), "FRIEND_OB")
	FAKE.turn = 74
	H.notnil(DealManager.GetPlayerDeals(0, 2), "the engine still lists the deal on the expiry turn")
	H.eq(EFV_HasOpenBordersFrom(0, 2), false, "turn 74: predicted expiry")
	H.isnil(EFV_VolunteerBasis(0, 2))
	H.eq(EFV_VolunteerLapseReason(0, 2), "PARTNER")
	-- an item without usable terms stays "active" (the engine decides)
	H.openBorders(0, 2, true, { enacted = -1, duration = 30 })
	H.eq(EFV_HasOpenBordersFrom(0, 2), true, "unknown enacted turn -> active")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Fee column and send
-- ---------------------------------------------------------------------------
test("fee column: Volunteer 20% + band surcharge (Swordsman 72/108/144/180, 0.5.2 ruling); picker rows and the charge use it", function()
	local S = H.baseScenario()
	H.loadEFV()
	local vol, exp = {}, {}
	for b = 1, 4 do
		vol[b] = EFV_Fee("UNIT_SWORDSMAN", "VOLUNTEER", b)
		exp[b] = EFV_Fee("UNIT_SWORDSMAN", "EXPEDITIONARY", b)
	end
	H.deq(vol, { 72, 108, 144, 180 }, "P3.4 Volunteer column")
	H.deq(exp, { 0, 36, 72, 108 }, "Expeditionary column for contrast (band 1 free)")
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local rows = EFV_DestinationRows(0, u, "VOLUNTEER", EFV_Records.Load())
	local row = nil
	for _, r in ipairs(rows) do
		if r.cityID == S.c1.id then row = r end
	end
	H.notnil(row); H.ok(row.ok); H.eq(row.calc.band, 2); H.eq(row.calc.fee, 108); H.isnil(row.calc.duration)
	H.send(0, u, 1, S.c1, "VOLUNTEER", row.calc.fee)
	H.eq(H.gold(0), 1000 - 108)
	H.eq(H.record().feePaid, 108)
	H.clean()
end)

test("send to a friend with open borders: sender keeps the unit, basis FRIEND_OB, transit maintenance, arrives in F's land", function()
	local S = H.baseScenario({ turn = 20 })
	H.loadEFV()
	H.openBorders(0, 2, true, { enacted = 20, duration = 30 })
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 2, S.c2, "VOLUNTEER")
	local r = H.record()
	H.notnil(r, "sent"); H.eq(r.accessBasis, "FRIEND_OB"); H.isnil(r.durationTurns)
	local transit = r.transitTurns
	H.turns(transit)
	r = H.record()
	H.eq(r.state, "DEPLOYED"); H.eq(r.onMapPlayerID, 0, "owned and controlled by the sender")
	H.ok(r.maintGoldPaid > 0, "transit maintenance paid by the sender (Phase 1)")
	local nu = Players[0]:GetUnits():FindID(r.onMapUnitID)
	H.notnil(nu)
	H.eq(nu:GetMovesRemaining(), 0, "0 moves on arrival")
	H.eq(Map.GetPlot(nu:GetX(), nu:GetY()):GetOwner(), 2, "spawned inside the friend's borders (open borders)")
	H.eq(Count(0, "ARRIVED"), 1)
	H.eq(#H.notifs(0, N("EXPIRY_SOON")), 0)
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Recall conditions (spec 9.2 as amended: min 10 turns unless lapsed, valid
-- territory = sender's or recipient's tiles only, NO HP requirement)
-- ---------------------------------------------------------------------------
test("recall: min 10 turns (N in the reason), neutral / third-party land refused, damaged unit accepted", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER")
	H.turns(2)
	local r = H.record()
	H.eq(r.state, "DEPLOYED")
	local u = FAKE.units[r.onMapUnitID]
	H.eq(OwnerAt(u), 1, "in the ally's territory")
	Recall(u)
	H.eq(H.record().state, "DEPLOYED")
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_MIN_TURNS", 10), tostring(LastFailure()))
	H.turns(4)
	u:SetDamage(50)
	Recall(u)
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_MIN_TURNS", 6), "6 turns left: " .. tostring(LastFailure()))
	H.turns(6)                                          -- 10 turns served
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	Recall(u)
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_TERRITORY"), "neutral land")
	H.deq(EFV_RecallReasons(H.record(), u, FAKE.turn), { "RECALL_TERRITORY" })
	H.moveUnit(u, 41, 30)                               -- the friend's (third party's) land
	Recall(u)
	H.eq(H.record().state, "DEPLOYED", "third-party land is not valid")
	H.moveUnit(u, 23, 10)                               -- back in the ally's territory, still damaged
	H.eq(u:GetDamage(), 50)
	local failures = #H.notifs(0, N("REQUEST_FAILED"))
	Recall(u)
	r = H.record()
	H.eq(r.state, "RETURNING", "no HP requirement"); H.eq(r.returnReason, "RECALL"); H.eq(r.damage, 50)
	H.eq(#H.notifs(0, N("REQUEST_FAILED")), failures)
	H.ok(not H.unitAlive(u), "unit left the map")
	H.turns(r.transitTurns)
	H.len(H.records(), 0, "returned")
	local back = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(back, 1); H.eq(back[1].damage, 50, "keeps its damage")
	H.eq(Count(0, "RETURNED"), 1)
	H.clean()
end)

test("recall: from the sender's own territory; untracked unit and unknown ID are rejected", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 12, x = 11, y = 11 })  -- inside player 0's borders
	H.eq(OwnerAt(u), 0)
	local plain = H.unit(0, "UNIT_WARRIOR", 12, 10)
	Recall(plain)
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_NOT_VOLUNTEER"))
	H.request(0, { OnStart = "EFV_Recall", unitID = 999999 })
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_REQ_STALE"))
	Recall(u)
	H.eq(Rec(id).state, "RETURNING"); H.eq(Rec(id).returnReason, "RECALL")
	H.ok(H.hasLine("[Recall] ok id=" .. id))
	H.clean()
end)

test("recall: the minimum is waived during a lapse (recall on the lapse turn at 2 turns served)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 2 })             -- in the ally's territory
	Recall(u)
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_MIN_TURNS", 8))
	H.peace(3, 1)                                        -- no common war
	H.endTurn()
	H.eq(Rec(id).state, "GRACE"); H.eq(Rec(id).lapsed, 1)
	H.deq(EFV_RecallReasons(Rec(id), u, FAKE.turn), {}, "minimum waived")
	Recall(u)
	H.eq(Rec(id).state, "RETURNING"); H.eq(Rec(id).returnReason, "RECALL")
	H.eq(Rec(id).lapsed, 0, "lapse fields cleared on return")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Lapse: start, cancel, reversal (Q2), deployedTurn preserved, no refund
-- ---------------------------------------------------------------------------
test("lapse WAR -> mutiny, then the war resumes: cancelled, DEPLOYED, deployedTurn kept, damage not refunded", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 4, x = p:GetX(), y = p:GetY() })
	local deployed = Rec(id).deployedTurn
	H.peace(3, 1)
	H.endTurn()
	local L = FAKE.turn
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapseReason, "WAR"); H.eq(r.lapseTurn, L); H.eq(r.preLapseState, "DEPLOYED")
	H.eq(Count(0, "VOLUNTEER_LAPSE", L), 1, "VOLUNTEER_LAPSE on the lapse turn")
	H.eq(Count(0, "GRACE", L), 0, "the lapse notice replaces GRACE 5")
	H.eq(H.notifs(0, N("VOLUNTEER_LAPSE"))[1].data.AlwaysAutoActivate, true, "unmissable (D9)")
	H.turns(5)                                           -- L+1..L+4 grace, L+5 first mutiny step
	r = Rec(id)
	H.eq(r.state, "MUTINY"); H.eq(u:GetDamage(), 20)
	H.war(3, 1)                                          -- common war again
	H.endTurn({ heal = 10 })                             -- the round heal is floored (still MUTINY this round)
	r = Rec(id)
	H.eq(r.state, "DEPLOYED", "lapse cancelled (Q2)")
	H.eq(r.lapsed, 0); H.isnil(r.lapseReason); H.isnil(r.lapseTurn); H.isnil(r.preLapseState)
	H.isnil(r.graceTurnsLeft); H.isnil(r.lastDamage)
	H.eq(r.deployedTurn, deployed, "deployedTurn never resets")
	H.eq(u:GetDamage(), 20, "mutiny damage not refunded, no +20 on the cancel turn")
	H.eq(Count(0, "LAPSE_CANCELLED", FAKE.turn), 1)
	H.ok(Has(H.notifs(0, N("LAPSE_CANCELLED"))[1].data[ParameterTypes.SUMMARY], "LOC_EFV_NOTIF_LAPSE_CANCELLED_SUMMARY",
		EFV_PlayerName(1), EFV_UnitDisplayName("UNIT_SWORDSMAN")))
	H.endTurn({ heal = 10 })
	H.eq(u:GetDamage(), 10, "heals normally after the cancel")
	-- 4 + 1 + 5 + 1 + 1 = 12 turns served: recall without a new minimum.
	H.moveUnit(u, 23, 10)
	Recall(u)
	H.eq(Rec(id).state, "RETURNING", "the minimum counts from the original deployedTurn")
	H.clean()
end)

test("lapse PARTNER: alliance lost -> ACCESS_LAPSE; alliance renewed in grace -> cancelled; lapses again later", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.ally(0, 1, false)
	H.endTurn()
	local L = FAKE.turn
	H.eq(Rec(id).lapseReason, "PARTNER"); H.eq(Count(0, "ACCESS_LAPSE", L), 1)
	H.endTurn()
	H.eq(Rec(id).graceTurnsLeft, 4)
	H.ally(0, 1)
	H.endTurn()
	H.eq(Rec(id).state, "DEPLOYED"); H.eq(Count(0, "LAPSE_CANCELLED"), 1)
	H.eq(Count(0, "GRACE"), 1, "only the L+1 grace notice")
	H.peace(3, 1)
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapseReason, "WAR"); H.eq(r.lapseTurn, FAKE.turn); H.eq(r.graceTurnsLeft, 5, "a new lapse restarts the grace")
	H.clean()
end)

test("lapse reason changes WAR -> PARTNER: the lapse continues (no restart)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.peace(3, 1)
	H.endTurn()
	H.endTurn()
	H.war(3, 1); H.ally(0, 1, false)                     -- war back, alliance gone
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, 3); H.eq(r.lapseReason, "PARTNER")
	H.eq(Count(0, "LAPSE_CANCELLED"), 0)
	H.clean()
end)

test("mutiny death timing: full HP dies on the 5th mutiny turn (L+9); no healing; sender-only alerts; no EXPIRY_SOON", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	H.peace(3, 1)
	H.endTurn()
	local L = FAKE.turn
	local seen = {}
	for i = 1, 8 do
		H.endTurn({ heal = 10 })
		seen[i] = H.unitAlive(u) and u:GetDamage() or "dead"
	end
	H.deq(seen, { 0, 0, 0, 0, 20, 40, 60, 80 }, "grace L+1..L+4, mutiny 20/40/60/80 at L+5..L+8 despite heal 10")
	H.eq(Rec(id).state, "MUTINY")
	H.endTurn({ heal = 10 })
	H.ok(not H.unitAlive(u), "dead on the 5th mutiny turn")
	H.isnil(Rec(id), "record closed")
	H.eq(FAKE.turn, L + 9)
	H.eq(Count(0, "GRACE"), 4); H.eq(Count(0, "MUTINY"), 4); H.eq(Count(0, "MUTINY_DEATH", L + 9), 1)
	H.eq(#H.notifs(1), 0, "the recipient gets no alerts for the sender's unit")
	H.eq(#H.notifs(0, N("EXPIRY_SOON")), 0, "Q4")
	H.ok(H.hasLine("[Floor] restore"), "heal suppressed")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Open-borders expiry: predicted lapse, engine expulsion, strict territory
-- ---------------------------------------------------------------------------
local function FriendOBScenario()
	local S = H.baseScenario({ turn = 40 })
	H.loadEFV()
	H.openBorders(0, 2, true, { enacted = 12, duration = 30 })   -- ends on turn 42
	local id, u = Deploy(S, { recipient = 2, basis = "FRIEND_OB", elapsed = 12, x = 41, y = 30 })
	return S, id, u
end

test("predicted expiry: the lapse starts on the expiry turn, before the engine expels the unit (same ID, neutral land)", function()
	local S, id, u = FriendOBScenario()
	H.eq(OwnerAt(u), 2)
	H.endTurn()                                          -- turn 41: agreement still running
	H.eq(Rec(id).state, "DEPLOYED")
	H.endTurn()                                          -- turn 42 = 12 + 30
	local E = FAKE.turn
	H.eq(E, 42)
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapsed, 1); H.eq(r.lapseReason, "PARTNER"); H.eq(r.lapseTurn, E)
	H.eq(Count(0, "ACCESS_LAPSE", E), 1, "ACCESS_LAPSE on the expiry turn")
	local iLapse, iExpel = LineIndex("[Lapse] start id=" .. id), LineIndex("[FAKE] expel unit " .. u.id)
	H.notnil(iLapse); H.notnil(iExpel)
	H.ok(iLapse < iExpel, "lapse (OnGameTurnStarted) before the expulsion (owner's turn start)")
	H.ok(H.unitAlive(u), "same unit")
	H.eq(OwnerAt(u), -1, "expelled to neutral land")
	H.ok(H.dist(u, { x = 41, y = 30 }) <= 3)
	H.eq(r.onMapUnitID, u.id)
	H.eq(r.lastX, u.x, "position followed by the boundary pass"); H.eq(r.lastY, u.y)
	H.clean()
end)

test("expelled Volunteer: no recall from neutral land; recall once it walks into the sender's territory", function()
	local S, id, u = FriendOBScenario()
	H.turns(2)                                           -- expiry turn 42: lapse + expulsion
	Recall(u)
	H.ok(Has(LastFailure(), "LOC_EFV_REASON_RECALL_TERRITORY"), "neutral land is not valid")
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.graceTurnsLeft, 4, "no auto-return from neutral land")
	-- the recipient's land would count, but its borders are closed now
	H.deq(EFV_RecallReasons(r, { GetX = function() return 41 end, GetY = function() return 30 end }, FAKE.turn), {},
		"a recipient-owned plot is valid territory")
	H.moveUnit(u, 11, 10)                                -- walked home
	Recall(u)
	r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECALL")
	H.clean()
end)

test("expelled Volunteer inside the sender's borders: grace paused, no automatic return; recall works (note 29)", function()
	local S, id, u = FriendOBScenario()
	H.turns(3)
	local left = Rec(id).graceTurnsLeft
	H.moveUnit(u, 11, 10)
	H.turns(2)
	local r = Rec(id)
	H.eq(r.state, "GRACE", "never GRACE_RETURN for a Volunteer"); H.eq(r.graceTurnsLeft, left, "paused")
	Recall(u)
	H.eq(Rec(id).state, "RETURNING"); H.eq(Rec(id).returnReason, "RECALL")
	H.clean()
end)

test("expelled Volunteer left on neutral land: grace, then mutiny until death (no special treatment)", function()
	local S, id, u = FriendOBScenario()
	H.turns(2)
	local E = FAKE.turn
	H.turns(9, { heal = 10 })
	H.ok(not H.unitAlive(u)); H.isnil(Rec(id))
	H.eq(Count(0, "MUTINY_DEATH", E + 9), 1)
	H.clean()
end)

test("open borders renewed during grace: the lapse is cancelled (Q2)", function()
	local S, id, u = FriendOBScenario()
	H.turns(3)
	H.eq(Rec(id).state, "GRACE")
	H.openBorders(0, 2, true, { enacted = FAKE.turn, duration = 30 })
	H.endTurn()
	H.eq(Rec(id).state, "DEPLOYED"); H.eq(Count(0, "LAPSE_CANCELLED"), 1)
	H.clean()
end)

test("friendship ends while open borders run: PARTNER lapse, the unit stays inside, paused, recalled (note 29)", function()
	local S = H.baseScenario({ turn = 40 })
	H.loadEFV()
	H.openBorders(0, 2, true, { enacted = 39, duration = 30 })
	local id, u = Deploy(S, { recipient = 2, basis = "FRIEND_OB", elapsed = 5, x = 41, y = 30 })
	H.friend(0, 2, false)
	H.endTurn()
	H.eq(Rec(id).lapseReason, "PARTNER"); H.eq(OwnerAt(u), 2, "not expelled (the agreement still runs)")
	H.eq(Rec(id).lapsePaused, 1)
	H.turns(2)
	H.eq(Rec(id).state, "GRACE", "no GRACE_RETURN"); H.eq(Rec(id).graceTurnsLeft, 5)
	Recall(u)
	H.eq(Rec(id).state, "RETURNING"); H.eq(Rec(id).returnReason, "RECALL")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Paused lapse (0.5.1; DECISIONS "Lapsed Volunteers on valid land", "Healing
-- during a paused lapse"; INTERFACES note 29): Volunteers never auto-return;
-- on the sender's / recipient's land the grace countdown and the mutiny
-- damage pause (no heal floor there), off it they resume where they stopped.
-- ---------------------------------------------------------------------------
-- UI texts of a record (switches the fake engine to the UI context: call it
-- last in a test). Returns EFV_UI_StateText, EFV_UI_TrackerState.
local function UITexts(id)
	local rec = Rec(id)
	include("fake_ui")
	FAKE_UI.Enable()
	include("EFV_UIShared")
	return EFV_UI_StateText(rec, FAKE.turn), EFV_UI_TrackerState(rec, FAKE.turn)
end

-- Lapses a Volunteer standing on neutral land (WAR: B makes peace with C)
-- and runs the lapse turn. Returns S, id, u, L (lapse turn).
local function LapsedOnNeutral(opts)
	opts = opts or {}
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = opts.elapsed or 4, x = p:GetX(), y = p:GetY() })
	H.peace(3, 1)
	H.endTurn()
	return S, id, u, FAKE.turn, p
end

test("paused on SENDER land: grace does not tick, no GRACE re-send, one LAPSE_PAUSED; state text 'Grace N (paused)'", function()
	local S, id, u, L = LapsedOnNeutral()
	H.endTurn()                                          -- L+1: 4
	H.eq(Rec(id).graceTurnsLeft, 4)
	H.isnil(Rec(id).lapsePaused)
	H.moveUnit(u, 11, 10)                                -- walks into the sender's territory
	H.endTurn()                                          -- the next boundary pauses it
	local r = Rec(id)
	H.eq(r.lapsePaused, 1); H.eq(r.graceTurnsLeft, 4, "no tick at L+2")
	H.eq(Count(0, "LAPSE_PAUSED"), 1, "LAPSE_PAUSED sent once")
	local pn = H.notifs(0, N("LAPSE_PAUSED"))[1]
	H.eq(pn.data.EFV_RecordID, id)
	H.ok(Has(pn.data[ParameterTypes.SUMMARY], "LOC_EFV_NOTIF_LAPSE_PAUSED_SUMMARY", EFV_UnitDisplayName("UNIT_SWORDSMAN"),
		EFV_PlayerName(1), Locale.Lookup("LOC_EFV_STATE_GRACE", 4)), tostring(pn.data[ParameterTypes.SUMMARY]))
	local graceSent = Count(0, "GRACE")
	H.turns(4)                                           -- well past the original mutiny turn
	r = Rec(id)
	H.eq(r.state, "GRACE", "no mutiny while paused"); H.eq(r.graceTurnsLeft, 4)
	H.eq(Count(0, "GRACE"), graceSent, "no GRACE spam while paused")
	H.eq(Count(0, "LAPSE_PAUSED"), 1, "no LAPSE_PAUSED spam either")
	H.ok(H.hasLine("[Lapse] paused id=" .. id))
	local st, tr = UITexts(id)
	H.eq(st, Locale.Lookup("LOC_EFV_STATE_GRACE_PAUSED", 4) .. " " .. Locale.Lookup("LOC_EFV_LAPSE_WAR"))
	H.ok(string.find(st, "Grace 4 (paused)", 1, true) ~= nil, st)
	H.eq(tr, "Lapse: Grace 4 (paused)")
	H.clean()
end)

test("paused on RECIPIENT land: mutiny damage stops, and the unit heals by engine rules (no floor)", function()
	local S, id, u, L = LapsedOnNeutral()
	H.turns(6)                                           -- L+5 20, L+6 40
	H.eq(Rec(id).state, "MUTINY"); H.eq(u:GetDamage(), 40)
	H.moveUnit(u, 23, 10)                                -- into the ally's (recipient's) territory
	H.endTurn({ heal = 15 })                             -- paused at the AI boundaries; the round heal counts
	local r = Rec(id)
	H.eq(r.lapsePaused, 1); H.eq(r.state, "MUTINY")
	H.eq(u:GetDamage(), 25, "healed 15, no +20 at the turn start")
	H.eq(Count(0, "LAPSE_PAUSED"), 1)
	H.ok(Has(H.notifs(0, N("LAPSE_PAUSED"))[1].data[ParameterTypes.SUMMARY], "LOC_EFV_STATE_MUTINY", 3),
		"paused notice: the mutiny count at the pause (ceil((100 - 40) / 20) = 3)")
	local mutinySent = Count(0, "MUTINY")
	H.turns(2, { heal = 15 })
	H.eq(u:GetDamage(), 0, "keeps healing while paused")
	H.eq(Rec(id).lastDamage, 0, "floor baseline follows the healing")
	H.eq(Count(0, "MUTINY"), mutinySent, "no MUTINY spam while paused")
	H.ok(not H.hasLine("[Floor] restore id=" .. id), "no heal reverted")
	local st, tr = UITexts(id)
	H.eq(tr, "Lapse: Mutiny 5 (paused)")
	H.ok(string.find(st, "Mutiny 5 (paused)", 1, true) ~= nil, st)
	H.clean()
end)

test("resume on leaving: grace continues from the paused count, then mutiny continues 20 flat per turn", function()
	local S, id, u, L = LapsedOnNeutral()
	H.turns(2)                                           -- L+1 4, L+2 3
	H.eq(Rec(id).graceTurnsLeft, 3)
	local home = { x = u.x, y = u.y }
	H.moveUnit(u, 11, 10)
	H.turns(3)
	H.eq(Rec(id).graceTurnsLeft, 3, "paused")
	H.moveUnit(u, home.x, home.y)                        -- back onto neutral land
	H.endTurn()
	local r = Rec(id)
	H.isnil(r.lapsePaused, "resumed at the next boundary"); H.eq(r.graceTurnsLeft, 2, "3 -> 2, exactly where it stopped")
	H.ok(H.hasLine("[Lapse] resumed id=" .. id))
	H.eq(Count(0, "GRACE", FAKE.turn), 1, "D9 GRACE re-send resumes")
	H.turns(2)                                           -- 1, then mutiny + first 20
	H.eq(Rec(id).state, "MUTINY"); H.eq(u:GetDamage(), 20)
	-- pause the mutiny on the recipient's land, then leave again: +20 continues
	H.moveUnit(u, 23, 10)
	H.turns(2)
	H.eq(u:GetDamage(), 20, "no damage while paused (no heal passed)")
	H.moveUnit(u, home.x, home.y)
	H.endTurn()
	H.eq(u:GetDamage(), 40, "20 flat on the next unpaused turn start")
	H.eq(Count(0, "MUTINY", FAKE.turn), 1)
	H.clean()
end)

test("healing taken while paused is not reverted after walking off; an unpaused heal is floored again", function()
	local S, id, u, L = LapsedOnNeutral()
	H.turns(7)                                           -- mutiny 20 / 40 / 60
	H.eq(u:GetDamage(), 60)
	local home = { x = u.x, y = u.y }
	H.moveUnit(u, 11, 10)                                -- the sender's own land
	H.turns(2, { heal = 15 })
	H.eq(u:GetDamage(), 30, "healed 2 x 15 while paused")
	H.moveUnit(u, home.x, home.y)                        -- leaves: resumes
	H.endTurn({ heal = 10 })                             -- neutral heal is floored (active mutiny); +20 at the start
	H.eq(u:GetDamage(), 50, "30 kept (baseline refreshed), neutral heal undone, +20")
	H.ok(H.hasLine("[Floor] restore id=" .. id), "the unpaused heal was floored")
	H.clean()
end)

test("recall from valid land during a paused lapse: minimum waived, damaged unit accepted, keeps healed damage", function()
	local S, id, u, L = LapsedOnNeutral({ elapsed = 2 })
	H.turns(6)                                           -- mutiny 20 / 40
	H.moveUnit(u, 11, 10)
	H.endTurn({ heal = 15 })                             -- paused, healed to 25
	H.eq(u:GetDamage(), 25)
	u:SetDamage(10)                                      -- a mid-turn heal on valid land (e.g. promotion)
	H.deq(EFV_RecallReasons(Rec(id), u, FAKE.turn), {}, "no minimum (lapsed), no HP rule, valid land")
	Recall(u)
	local r = Rec(id)
	H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "RECALL"); H.eq(r.damage, 10, "no floor on valid land")
	H.isnil(r.lapsePaused); H.eq(r.lapsed, 0)
	H.clean()
end)

test("no auto-return ever for Volunteers: grace and mutiny on sender and recipient land never produce GRACE_ / MUTINY_RETURN", function()
	local S, id, u, L = LapsedOnNeutral()
	H.moveUnit(u, 23, 10)
	H.turns(12, { heal = 10 })
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapsePaused, 1)
	H.moveUnit(u, 30, 5)
	H.turns(5)
	H.eq(Rec(id).state, "MUTINY")
	H.moveUnit(u, 11, 10)
	H.turns(6)
	H.eq(Rec(id).state, "MUTINY", "still lapsed, still waiting for a recall")
	H.ok(not H.hasLine("reason=GRACE_RETURN"), "no GRACE_RETURN"); H.ok(not H.hasLine("reason=MUTINY_RETURN"), "no MUTINY_RETURN")
	H.ok(H.unitAlive(u))
	H.clean()
end)

test("lapse cancel while paused: back to DEPLOYED, deployedTurn kept, no refund, pause cleared, LAPSE_CANCELLED", function()
	local S, id, u, L = LapsedOnNeutral()
	local deployed = Rec(id).deployedTurn
	H.turns(6)                                           -- mutiny 20 / 40
	H.moveUnit(u, 23, 10)
	H.endTurn()
	H.eq(Rec(id).lapsePaused, 1)
	H.war(3, 1)                                          -- common war again
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "DEPLOYED"); H.eq(r.lapsed, 0); H.isnil(r.lapsePaused); H.isnil(r.lastDamage)
	H.eq(r.deployedTurn, deployed); H.eq(u:GetDamage(), 40, "no refund")
	H.eq(Count(0, "LAPSE_CANCELLED"), 1)
	H.clean()
end)

test("lapse starting on valid land starts paused (silent: the lapse notice explains it)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 3 })             -- inside the ally's borders
	H.peace(3, 1)
	H.endTurn()
	local r = Rec(id)
	H.eq(r.state, "GRACE"); H.eq(r.lapsePaused, 1)
	H.eq(Count(0, "VOLUNTEER_LAPSE"), 1); H.eq(Count(0, "LAPSE_PAUSED"), 0, "no second notice on the lapse turn")
	H.ok(Has(H.notifs(0, N("VOLUNTEER_LAPSE"))[1].data[ParameterTypes.SUMMARY], "LOC_EFV_NOTIF_VOLUNTEER_LAPSE_SUMMARY",
		EFV_PlayerName(1), 5))
	H.clean()
end)

test("lapsed Volunteer GRACE / MUTINY alerts use the _VOLUNTEER texts (recall, pause)", function()
	local S, id, u, L = LapsedOnNeutral()
	H.turns(5)
	local unit, rcp = EFV_UnitDisplayName("UNIT_SWORDSMAN"), EFV_PlayerName(1)
	local g = H.notifs(0, N("GRACE"))
	H.eq(g[1].data[ParameterTypes.SUMMARY], Locale.Lookup("LOC_EFV_NOTIF_GRACE_VOLUNTEER_SUMMARY", unit, rcp, 4))
	local m = H.notifs(0, N("MUTINY"))
	H.eq(m[1].data[ParameterTypes.SUMMARY], Locale.Lookup("LOC_EFV_NOTIF_MUTINY_VOLUNTEER_SUMMARY", unit, 4, rcp))
	H.clean()
end)

test("Expeditionary keeps the spec 9.1 auto-return in grace (GRACE_RETURN) and mutiny (MUTINY_RETURN)", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local function DeployExp()
		local u = H.unit(1, "UNIT_SWORDSMAN", p:GetX(), p:GetY())
		local store = EFV_Records.Load()
		local turn = Game.GetCurrentGameTurn()
		local rec = EFV_Records.New(store, {
			forceType = "EXPEDITIONARY", state = "DEPLOYED", senderID = 0, recipientID = 1, accessBasis = "ALLIANCE",
			originCityID = S.c0.id, originX = S.c0.x, originY = S.c0.y,
			destCityID = S.c1.id, destX = S.c1.x, destY = S.c1.y, rerouted = 0,
			onMapPlayerID = 1, onMapUnitID = u.id, sentTurn = turn - 22, arrivalTurn = turn - 20,
			transitTurns = 2, band = 2, distance = 12, deployedTurn = turn - 20, durationTurns = 20,
			spawnFailCount = 0, feePaid = 100, maintGoldPaid = 0, lapsed = 0,
		})
		EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(u), turn)
		EFV_Records.Commit(store)
		return rec.id, u
	end
	local a, ua = DeployExp()
	H.endTurn()                                          -- expiry on neutral land -> GRACE
	H.eq(Rec(a).state, "GRACE")
	H.moveUnit(ua, 23, 10)
	H.endTurn()
	H.eq(Rec(a).state, "RETURNING"); H.eq(Rec(a).returnReason, "GRACE_RETURN")
	H.isnil(Rec(a).lapsePaused)
	local b, ub = DeployExp()
	H.turns(7)                                           -- grace 5..1, mutiny
	H.eq(Rec(b).state, "MUTINY")
	H.moveUnit(ub, 23, 10)
	H.endTurn()
	H.eq(Rec(b).state, "RETURNING"); H.eq(Rec(b).returnReason, "MUTINY_RETURN")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Merges (D3) and sender-recipient war (DV6)
-- ---------------------------------------------------------------------------
test("merge: a Volunteer that survives a merge closes its record at the next boundary; MERGED to the sender", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	u:SetMilitaryFormation(MilitaryFormationTypes.CORPS_FORMATION)
	H.endTurn()
	H.isnil(Rec(id), "record closed")
	H.ok(H.unitAlive(u), "the unit stays the sender's"); H.eq(u.owner, 0)
	H.eq(Count(0, "MERGED"), 1)
	H.eq(Count(0, "UNIT_LOST"), 0)
	H.ok(H.hasLine("[Merge] volunteer id=" .. id))
	H.clean()
end)

test("merge: a Volunteer absorbed into the sender's Corps closes its record (MERGED); a disband closes silently", function()
	local S = H.baseScenario()
	H.loadEFV()
	local p = H.neutralPlot(30, 5)
	local id, u = Deploy(S, { elapsed = 3, x = p:GetX(), y = p:GetY() })
	local q = H.neutralPlot(35, 5)
	local id2, u2 = Deploy(S, { elapsed = 3, x = q:GetX(), y = q:GetY() })
	-- u merged into an adjacent sender unit (which becomes a Corps); u2 disbanded.
	local adj = nil
	for _, n in ipairs(Map.GetNeighborPlots(u.x, u.y, 1)) do
		if n ~= nil and (n.x ~= u.x or n.y ~= u.y) and not n:IsWater() and n:GetUnitCount() == 0 then adj = n; break end
	end
	H.unit(0, "UNIT_SWORDSMAN", adj.x, adj.y, { formation = MilitaryFormationTypes.CORPS_FORMATION })
	FAKE.RemoveUnit(u, "MERGE")
	FAKE.RemoveUnit(u2, "DISBAND")
	H.endTurn()
	H.isnil(Rec(id)); H.isnil(Rec(id2))
	H.eq(Count(0, "MERGED"), 1, "one MERGED (the absorbed Volunteer)")
	H.eq(Count(0, "UNIT_LOST"), 0, "Volunteers: no UNIT_LOST")
	H.clean()
end)

test("war between sender and recipient: deployed Volunteer record closed (DV6), in-transit one returns", function()
	local S = H.baseScenario()
	H.loadEFV()
	local id, u = Deploy(S, { elapsed = 3 })
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER")
	local outID = H.records()[2].id
	H.eq(Rec(outID).state, "OUTBOUND")
	H.war(1, 0)                                          -- B declares war during its turn
	H.endTurn()
	H.isnil(Rec(id), "deployed Volunteer record closed")
	H.ok(H.unitAlive(u)); H.eq(u.owner, 0, "the unit stays the sender's (now hostile territory)")
	H.eq(Rec(outID).state, "RETURNING"); H.eq(Rec(outID).returnReason, "WAR")
	H.eq(Count(0, "VOLUNTEER_LAPSE") + Count(0, "ACCESS_LAPSE"), 0, "war overrides the lapse")
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- UI: Recall button (spec 9.2 tooltip, D3 merge warning)
-- ---------------------------------------------------------------------------
test("UI: Recall button lists failing conditions, turns until the minimum and the merge warning; enabled when met", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER")
	H.turns(2)
	local r = H.record()
	local u = FAKE.units[r.onMapUnitID]
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	local function Buttons()
		FAKE_UI.selectedUnit = u
		Events.UnitSelectionChanged(0, u.id, 0, 0, 0, true, false)
		FAKE_UI.Frame(actions)
		for _, im in ipairs(FAKE_UI.ims) do
			if im.instName == "EFV_ActionInstance" then return im.list end
		end
	end
	local list = Buttons()
	H.len(list, 2, "Recall + status (tracked unit: no send buttons; WP5.4 status button)")
	H.eq(list[2].UnitActionIcon.icon, "ICON_UNITOPERATION_SPY_LISTENING_POST")
	H.ok(Has(list[2].UnitActionButton.tooltip, "LOC_EFV_WARN_MERGE_VOLUNTEER"), "status button carries the D3 warning")
	local b = list[1].UnitActionButton
	H.ok(b.disabled)
	H.ok(Has(b.tooltip, "LOC_EFV_ACTION_RECALL"))
	H.ok(Has(b.tooltip, "LOC_EFV_REASON_RECALL_MIN_TURNS", 10), b.tooltip)
	H.ok(Has(b.tooltip, "LOC_EFV_WARN_MERGE_VOLUNTEER"), "D3 warning")
	local p = H.neutralPlot(30, 5)
	H.moveUnit(u, p:GetX(), p:GetY())
	b = Buttons()[1].UnitActionButton
	H.ok(Has(b.tooltip, "LOC_EFV_REASON_RECALL_TERRITORY"), "both failing conditions listed")
	FAKE_UI.AsGameplay(function() H.turns(10) end)
	H.moveUnit(u, 23, 10)
	b = Buttons()[1].UnitActionButton
	H.ok(not b.disabled, b.tooltip)
	b:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.notnil(popup); popup.confirm()
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	H.eq(req.params.OnStart, "EFV_Recall"); H.eq(req.params.unitID, u.id)
	FAKE_UI.AsGameplay(function() H.request(0, req.params) end)
	H.eq(H.record().state, "RETURNING")
	H.clean()
end)
