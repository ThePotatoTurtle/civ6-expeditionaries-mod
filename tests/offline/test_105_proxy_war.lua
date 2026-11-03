-- @harness native
-- 1.0.5 proxy war (F4 option b; FIXPLAN_proxy_war.md "1.0.5 build plan",
-- B0-B6; DECISIONS 2026-10-05 and 2026-10-24; SPIKES 8.1). An
-- Expeditionary send to a major passes the shared-enemy check also when the
-- host is at war with a living major civ that is in a denouncement with the
-- sender, either side. Volunteers and City-State sends are unchanged; a
-- proxy war that ends while the unit is on its way cancels the send with
-- half the fee back; a deployed unit keeps serving.
-- Readers (fake_engine, mirrors SPIKES 8.1): G
-- Players[a]:GetAi_Diplomacy():GetDiplomaticState(b) (StateType string), UI
-- Players[a]:GetDiplomaticAI():GetDiplomaticStateIndex(b); UI only
-- GetDenounceTurn / GetDenounceTimeLimit for the picker's turn count.
--
-- Scenario: 0 human (capital (10,10)); 1 = B, declared friend with open
-- borders (capital (22,10): band 2, Swordsman fee 18, half = 9); 2 = E and
-- 3 = X, both at war with B; 4 = a city-state at war with B; 5 = a major
-- friend with no wars; 62 Free Cities; 63 Barbarians.

local EXP, VOL, CS = "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"
local ME, B, E, X, CSP, F5, FREE, BARB = 0, 1, 2, 3, 4, 5, 62, 63
local N = function(name) return "EFV_NOTIF_" .. name end
local EM, EN = "\226\128\148", "\226\128\147"

local function Scenario(opts)
	opts = opts or {}
	H.world({ turn = opts.turn, players = {
		{ id = ME, human = true, gold = 1000 }, { id = B, gold = 1000, human = opts.humanB == true },
		{ id = E, gold = 1000 }, { id = X, gold = 1000 },
		{ id = CSP, kind = "CITY_STATE", gold = 0 }, { id = F5, gold = 1000 },
		{ id = FREE, kind = "FREE_CITIES" }, { id = BARB, kind = "BARBARIAN" },
	} })
	local S = {}
	S.c0 = H.city(ME, 10, 10, { capital = true, name = "LOC_CITY_A" })
	S.c1 = H.city(B, 22, 10, { capital = true, name = "LOC_CITY_B" })
	S.c2 = H.city(E, 40, 30, { capital = true, name = "LOC_CITY_E" })
	S.c3 = H.city(X, 70, 40, { capital = true, name = "LOC_CITY_X" })
	S.c4 = H.city(CSP, 30, 20, { capital = true, name = "LOC_CITY_CS" })
	S.c5 = H.city(F5, 12, 30, { capital = true, name = "LOC_CITY_F5" })
	H.friend(ME, B); H.openBorders(ME, B)
	H.friend(ME, F5)
	H.war(B, E); H.war(B, X); H.war(B, CSP)
	H.meet(ME, E); H.meet(ME, X); H.meet(ME, CSP)
	return S
end

local function Unit(x, y) return H.unit(ME, "UNIT_SWORDSMAN", x or 11, y or 10) end

local function Eval(u, rid, city, ft)
	local ok, r, calc = EFV_EvaluateSend(ME, u, rid, city, ft, EFV_Records.Load())
	return r, calc, ok
end

local function RowsOf(u, ft, rid)
	local out = {}
	for _, row in ipairs(EFV_DestinationRows(ME, u, ft, EFV_Records.Load())) do
		if row.recipientID == rid then out[#out + 1] = row end
	end
	return out
end

local function BothContexts(fn)
	fn("G")
	include("fake_ui")
	FAKE_UI.Enable()
	fn("UI")
end

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
local function Has(text, s) return string.find(text or "", s, 1, true) ~= nil end
local function UnitsOn(pid, typeName, x, y)
	local out = {}
	for _, u in ipairs(H.unitsOf(pid, typeName)) do
		if u.x == x and u.y == y then out[#out + 1] = u end
	end
	return out
end
local function Eliminate(pid)
	for _, u in ipairs(H.unitsOf(pid)) do H.killUnit(u) end
	H.kill(pid)
end

-- ===========================================================================
-- r: the rule (EFV_Rules, both contexts)
-- ===========================================================================
test("r1 no denouncement: Expeditionary and Volunteers to B are refused (NO_COMMON_WAR), both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	BothContexts(function(ctx)
		H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, ctx .. ": EXP")
		H.deq(Eval(u, B, S.c1, VOL), { "NO_COMMON_WAR" }, ctx .. ": VOL")
		H.deq(EFV_ProxyWarEnemies(ME, B), {}, ctx)
		H.ok(not EFV_HasProxyWar(ME, B), ctx)
	end)
	H.clean()
end)

test("r2 you denounced E: Expeditionary allowed (warBasis PROXY, enemies {E}), Volunteers still refused, both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.denounce(ME, E)
	BothContexts(function(ctx)
		local r, calc = Eval(u, B, S.c1, EXP)
		H.deq(r, {}, ctx .. ": EXP")
		H.eq(calc.warBasis, "PROXY", ctx)
		H.deq(calc.proxyEnemies, { E }, ctx)
		H.eq(calc.fee, 18, ctx .. ": fee unchanged")
		H.deq(Eval(u, B, S.c1, VOL), { "NO_COMMON_WAR" }, ctx .. ": VOL")
		H.ok(EFV_HasProxyWar(ME, B), ctx)
	end)
	H.clean()
end)

test("r3 E denounced you: the same (either side counts)", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.denounce(E, ME)
	BothContexts(function(ctx)
		local r, calc = Eval(u, B, S.c1, EXP)
		H.deq(r, {}, ctx .. ": EXP")
		H.eq(calc.warBasis, "PROXY", ctx)
		H.deq(calc.proxyEnemies, { E }, ctx)
		H.deq(Eval(u, B, S.c1, VOL), { "NO_COMMON_WAR" }, ctx .. ": VOL")
	end)
	H.clean()
end)

test("r4 E denounced, but B is not at war with E: NO_COMMON_WAR", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.peace(B, E)
	H.denounce(E, ME)
	BothContexts(function(ctx)
		H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, ctx)
	end)
	H.clean()
end)

test("r5 B at war only with a city-state, the Barbarians and the Free Cities (and a DENOUNCED pair with the city-state): NO_COMMON_WAR", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.peace(B, E); H.peace(B, X)
	H.ok(Players[B]:GetDiplomacy():IsAtWarWith(CSP) and Players[B]:GetDiplomacy():IsAtWarWith(FREE)
		and Players[B]:GetDiplomacy():IsAtWarWith(BARB), "B's remaining wars")
	FAKE.PairSet(FAKE.diplo.denounced, ME, CSP, true); FAKE.PairSet(FAKE.diplo.denounced, CSP, ME, true)
	FAKE.PairSet(FAKE.diplo.denounced, ME, FREE, true); FAKE.PairSet(FAKE.diplo.denounced, FREE, ME, true)
	BothContexts(function(ctx)
		H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, ctx)
		H.deq(EFV_ProxyWarEnemies(ME, B), {}, ctx .. ": never a city-state or the Free Cities")
	end)
	H.clean()
end)

test("r6 a real shared war plus a denouncement: ok, warBasis COMMON", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.war(ME, X)
	H.denounce(ME, E)
	BothContexts(function(ctx)
		local r, calc = Eval(u, B, S.c1, EXP)
		H.deq(r, {}, ctx)
		H.eq(calc.warBasis, "COMMON", ctx)
		H.isnil(calc.proxyEnemies, ctx)
		local rv, cv = Eval(u, B, S.c1, VOL)
		H.deq(rv, {}, ctx .. ": Volunteers on the real war")
		H.eq(cv.warBasis, "COMMON", ctx)
	end)
	H.clean()
end)

test("r7 kill switch FLAG_PROXY_WAR = false: r2's world -> NO_COMMON_WAR and the 1.0.4 text key", function()
	local S = Scenario()
	H.loadEFV({ flags = { FLAG_PROXY_WAR = false } })
	local u = Unit()
	H.denounce(ME, E)
	BothContexts(function(ctx)
		H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, ctx)
		H.deq(EFV_ProxyWarEnemies(ME, B), {}, ctx)
	end)
	H.eq(EFV_ReasonTextKey("NO_COMMON_WAR", EXP), "LOC_EFV_REASON_NO_COMMON_WAR")
	EFV_Config.FLAG_PROXY_WAR = true
	H.eq(EFV_ReasonTextKey("NO_COMMON_WAR", EXP), "LOC_EFV_NO_COMMON_WAR_EXP")
	H.eq(EFV_ReasonTextKey("NO_COMMON_WAR", VOL), "LOC_EFV_REASON_NO_COMMON_WAR")
	H.eq(EFV_ReasonTextKey("NO_COMMON_WAR", nil), "LOC_EFV_REASON_NO_COMMON_WAR")
	H.eq(EFV_ReasonTextKey("GOLD", EXP), "LOC_EFV_REASON_GOLD")
	H.clean()
end)

test("r8 City-State sends: no NO_COMMON_WAR and no warBasis, whatever the denouncements", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.peace(B, CSP)
	H.denounce(ME, E)
	BothContexts(function(ctx)
		local r, calc = Eval(u, CSP, S.c4, CS)
		H.deq(r, {}, ctx)
		H.isnil(calc.warBasis, ctx)
		H.isnil(calc.proxyEnemies, ctx)
	end)
	H.clean()
end)

test("r9 reader failures fail closed: G GetAi_Diplomacy missing or throwing, UI GetDiplomaticAI throwing -> NO_COMMON_WAR, one ERROR line per context", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.denounce(ME, E)
	FAKE.aiDiploMissing = true
	H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, "G missing")
	FAKE.aiDiploMissing = false
	FAKE.aiDiploThrows = true
	H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" }, "G throwing")
	H.deq(EFV_ProxyWarEnemies(ME, B), {}, "G throwing")
	FAKE.aiDiploThrows = false
	H.eq(#H.lines("denouncement reader unavailable in G"), 1, "logged once in G")
	H.ok(H.hasLine("] ERROR denouncement reader unavailable in G"), "an ERROR line")
	H.deq(Eval(u, B, S.c1, EXP), {}, "G readable again")
	include("fake_ui")
	FAKE_UI.Enable()
	FAKE.diploAIThrows = true
	H.contains(Eval(u, B, S.c1, EXP), "NO_COMMON_WAR", "UI throwing")
	H.deq(EFV_ProxyWarEnemies(ME, B), {}, "UI throwing")
	H.eq(#H.lines("denouncement reader unavailable in UI"), 1, "logged once in UI")
	FAKE.diploAIThrows = false
	H.deq(Eval(u, B, S.c1, EXP), {}, "UI readable again")
end, { allowErrors = true })

test("r10 E eliminated -> no proxy war; two enemies -> ascending list; e == s and e == r never listed", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.denounce(X, ME)
	H.denounce(ME, E)
	H.deq(EFV_ProxyWarEnemies(ME, B), { E, X }, "ascending")
	-- A denouncement between sender and host never makes the host its own enemy.
	H.denounce(ME, B)
	H.deq(EFV_ProxyWarEnemies(ME, B), { E, X })
	H.deq(EFV_ProxyWarEnemies(ME, ME), {}, "s == r")
	H.deq(EFV_ProxyWarEnemies(nil, B), {}, "nil")
	H.denounceEnd(ME, B)
	H.friend(ME, B)
	Eliminate(X)
	H.deq(EFV_ProxyWarEnemies(ME, B), { E }, "X eliminated")
	Eliminate(E)
	H.deq(EFV_ProxyWarEnemies(ME, B), {}, "E eliminated too")
	H.deq(Eval(u, B, S.c1, EXP), { "NO_COMMON_WAR" })
	H.clean()
end)

test("r11 UI rows and gameplay agree on ok and reasons for every row in the worlds of r1-r6", function()
	local S = Scenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	local u = Unit()
	local worlds = {
		{ "r1 none", function() end },
		{ "r2 you denounced E", function() H.denounce(ME, E) end },
		{ "r3 E denounced you", function() H.denounceEnd(ME, E); H.denounce(E, ME) end },
		{ "r4 B at peace with E", function() H.peace(B, E); H.denounce(E, ME) end },
		{ "r5 only a city-state", function() H.peace(B, X); FAKE.PairSet(FAKE.diplo.denounced, ME, CSP, true); FAKE.PairSet(FAKE.diplo.denounced, CSP, ME, true) end },
		{ "r6 real war + denouncement", function() H.war(B, E); H.war(B, X); H.war(ME, X); H.denounce(ME, E) end },
	}
	for _, w in ipairs(worlds) do
		w[2]()
		for _, ft in ipairs({ EXP, VOL }) do
			local uiRows = EFV_DestinationRows(ME, u, ft, EFV_Records.Load())
			H.ok(#uiRows >= 2, w[1] .. ": rows for B and F5")
			for _, row in ipairs(uiRows) do
				local city = CityManager.GetCity(row.recipientID, row.cityID)
				local g = {}
				FAKE_UI.AsGameplay(function()
					g.ok, g.r = EFV_EvaluateSend(ME, u, row.recipientID, city, ft, EFV_Records.Load())
				end)
				H.eq(row.ok, g.ok, w[1] .. " " .. ft .. " P" .. row.recipientID .. ": ok")
				H.deq(row.reasons, g.r, w[1] .. " " .. ft .. " P" .. row.recipientID .. ": reasons")
			end
		end
	end
	H.clean()
end)

-- ===========================================================================
-- s: the gameplay send handler
-- ===========================================================================
test("s1 the proxy send is accepted: record warBasis PROXY, fee 18, [Send] ok ... war=PROXY", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	local r = Only()
	H.eq(r.warBasis, "PROXY")
	H.eq(r.state, "OUTBOUND")
	H.eq(H.gold(ME), 982)
	H.ok(H.hasLine("[Send] ok id=1") and H.hasLine(" war=PROXY"), "send log")
	H.clean()
end)

test("s2 a forged Expeditionary send without a denouncement: no record, REQUEST_FAILED with the Expeditionary text naming B", function()
	local S = Scenario()
	H.loadEFV()
	local u = Unit()
	H.send(ME, u, B, S.c1, EXP, 18)
	H.len(H.records(), 0)
	H.eq(H.gold(ME), 1000)
	local n = Sent(ME, "REQUEST_FAILED")
	H.len(n, 1)
	local want = Locale.Lookup("LOC_EFV_NO_COMMON_WAR_EXP", EFV_PlayerName(B))
	H.ok(Has(Summary(n[1]), want), Summary(n[1]))
	H.ok(Has(want, "denounced"), "the proxy-war text")
	H.clean()
end)

test("s3 a forged Volunteer send with a denouncement: REQUEST_FAILED with the plain NO_COMMON_WAR text", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, VOL, 999)
	H.len(H.records(), 0)
	local n = Sent(ME, "REQUEST_FAILED")
	H.len(n, 1)
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_REASON_NO_COMMON_WAR", EFV_PlayerName(B))), Summary(n[1]))
	H.ok(not Has(Summary(n[1]), "denounced"))
	H.clean()
end)

-- ===========================================================================
-- t: transit cancel and deployed units
-- ===========================================================================
test("t1 the denouncement ends mid-transit -> cancelled at the next turn start, unit on its tile, refund 9, the Expeditionary cancel text", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	H.denounceEnd(ME, E)
	H.endTurn()
	H.len(H.records(), 0, "record closed")
	H.ok(H.hasLine("[Cancel] id=1 force=EXPEDITIONARY"))
	H.ok(H.hasLine("reason=NO_COMMON_WAR code=NO_COMMON_WAR hook=OnGameTurnStarted"))
	H.ok(H.hasLine(" war=PROXY"), "cancel log names the war basis")
	H.len(UnitsOn(ME, "UNIT_SWORDSMAN", 11, 10), 1, "back on its tile")
	H.eq(H.gold(ME), 1000 - 18 + 9, "half the fee back, once")
	local n = Sent(ME, "RETURNED")
	H.len(n, 1)
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR_EXP", EFV_PlayerName(B))), Summary(n[1]))
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REFUND", 9)))
	H.endTurn()
	H.eq(H.gold(ME), 991, "no second refund")
	H.clean()
end)

test("t1b a human host gets the _EXP_HOST text naming the sender", function()
	local S = Scenario({ humanB = true })
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	H.denounceEnd(ME, E)
	H.endTurn()
	H.len(H.records(), 0)
	local n = Sent(B, "ARRIVED")
	H.len(n, 1)
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR_EXP_HOST", EFV_PlayerName(ME))), Summary(n[1]))
	H.clean()
end)

test("t2 B makes peace with E mid-transit -> the same cancel", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	H.peace(B, E)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	H.eq(H.gold(ME), 991)
	H.clean()
end)

test("t3 E eliminated mid-transit -> the same cancel", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	Eliminate(E)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	H.eq(H.gold(ME), 991)
	H.clean()
end)

test("t4 auto-expiry (limit 3): the held send is cancelled at T+4 with one refund; the arrived unit keeps serving and goes home at its normal expiry", function()
	local S = Scenario({ turn = 1 })
	H.denounceLimit(3)
	H.loadEFV()
	H.denounce(ME, E)                                    -- turn T = 1
	H.send(ME, Unit(11, 10), B, S.c1, EXP, 18)
	local held = H.records()[1].id
	EditRecord(held, function(r) r.arrivalTurn = 1 + 8 end)
	H.send(ME, Unit(10, 11), B, S.c1, EXP, 18)
	local normal = H.records()[2].id
	H.eq(H.gold(ME), 1000 - 36)
	H.turns(2)                                           -- turn 3
	H.eq(Rec(normal).state, "DEPLOYED", "the normal send arrived")
	H.eq(Rec(held).state, "OUTBOUND")
	H.endTurn()                                          -- turn 4
	H.eq(Rec(held).state, "OUTBOUND", "the denouncement still lasts")
	local goldBefore = H.gold(ME)
	H.endTurn()                                          -- turn 5 = T + 4
	H.eq(FAKE.DiploStateName(ME, E), "DIPLO_STATE_UNFRIENDLY", "expired to UNFRIENDLY")
	H.isnil(Rec(held), "held send cancelled")
	H.eq(#H.lines("[Cancel] id=" .. held .. " "), 1)
	H.eq(H.gold(ME) - goldBefore, 9, "half of 18 back, once")
	local dep = Rec(normal)
	H.eq(dep.state, "DEPLOYED", "the arrived unit keeps serving")
	local deployedTurn = dep.deployedTurn
	H.clearNotifs()
	H.turns(3)
	H.eq(Rec(normal).state, "DEPLOYED")
	H.eq(Rec(normal).deployedTurn, deployedTurn, "untouched")
	H.len(H.notifs(ME), 0, "no notice about the deployed unit")
	H.len(H.lines("[Cancel] id=" .. normal .. " "), 0)
	H.len(H.lines("[War] sent home id=" .. normal), 0)
	-- Its normal tour: 20 turns after it arrived.
	H.turns(deployedTurn + EFV_Config.EXPEDITIONARY_DURATION - 1 - FAKE.turn)
	H.eq(Rec(normal) and Rec(normal).state or "closed", "DEPLOYED", "still serving on the last turn")
	H.endTurn()
	H.ok(Rec(normal) == nil or Rec(normal).state ~= "DEPLOYED", "the tour ended at its normal expiry")
	H.clean()
end)

test("t5 two proxy enemies: the first denouncement ends -> still OUTBOUND; the second ends -> cancelled", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E); H.denounce(X, ME)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	local id = Only().id
	EditRecord(id, function(r) r.arrivalTurn = FAKE.turn + 6 end)
	H.denounceEnd(ME, E)
	H.endTurn()
	H.eq(Rec(id).state, "OUTBOUND", "X still makes a proxy war")
	H.denounceEnd(X, ME)
	H.endTurn()
	H.isnil(Rec(id), "cancelled")
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	H.clean()
end)

test("t6 you declare war on E while B fights it: the transit continues on the real war and arrives", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	local id = Only().id
	H.war(ME, E)
	H.eq(FAKE.DiploStateName(ME, E), "DIPLO_STATE_WAR", "war replaces the denouncement")
	H.endTurn()
	H.eq(Rec(id).state, "OUTBOUND")
	H.endTurn()
	H.eq(Rec(id).state, "DEPLOYED", "arrived")
	H.len(H.lines("[Cancel] id="), 0)
	H.clean()
end)

test("t7 war between you and B: an outbound proxy send -> the WAR cancel; a deployed proxy unit -> sent home (unchanged)", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(11, 10), B, S.c1, EXP, 18)
	local first = H.records()[1].id
	H.turns(2)
	H.eq(Rec(first).state, "DEPLOYED")
	H.send(ME, Unit(10, 11), B, S.c1, EXP, 18)
	local second = H.records()[2].id
	H.war(ME, B)
	H.endTurn()
	H.isnil(Rec(second), "outbound cancelled")
	H.ok(H.hasLine("[Cancel] id=" .. second .. " ") and H.hasLine("reason=WAR code=AT_WAR_WITH_RECIPIENT"))
	H.ok(H.hasLine("[War] sent home id=" .. first), "deployed unit sent home")
	H.clean()
end)

test("t8 Volunteers to B on a real shared war, then only a denouncement left -> cancelled with the Volunteer text", function()
	local S = Scenario()
	H.loadEFV()
	H.war(ME, E)
	H.send(ME, Unit(), B, S.c1, VOL, 999)
	local r = Only()
	H.eq(r.warBasis, "COMMON")
	H.peace(ME, E)
	H.denounce(ME, E)
	H.endTurn()
	H.len(H.records(), 0)
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	local n = Sent(ME, "RETURNED")
	H.len(n, 1)
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR", EFV_PlayerName(B))), Summary(n[1]))
	H.ok(not Has(Summary(n[1]), "denounced"))
	H.clean()
end)

test("t9 save and load in transit: warBasis survives the property round trip; the cancel still works", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	local id = Only().id
	H.reloadEFV()
	H.eq(Rec(id).warBasis, "PROXY")
	H.denounceEnd(ME, E)
	H.endTurn()
	H.isnil(Rec(id))
	H.ok(H.hasLine("reason=NO_COMMON_WAR") and H.hasLine(" war=PROXY"))
	H.eq(H.gold(ME), 991)
	H.clean()
end)

test("t10 kill switch off at load with a PROXY record on its way -> cancelled NO_COMMON_WAR (the 1.0.4 rule and text)", function()
	local S = Scenario()
	H.loadEFV()
	H.denounce(ME, E)
	H.send(ME, Unit(), B, S.c1, EXP, 18)
	local id = Only().id
	H.reloadEFV()
	EFV_Config.FLAG_PROXY_WAR = false
	H.endTurn()
	H.isnil(Rec(id))
	H.ok(H.hasLine("reason=NO_COMMON_WAR"))
	local n = Sent(ME, "RETURNED")
	H.ok(Has(Summary(n[1]), Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR", EFV_PlayerName(B))), Summary(n[1]))
	H.clean()
end)

-- ===========================================================================
-- x: texts
-- ===========================================================================
test("x1 every new text renders with its arguments: no LOC_EFV, no {, VEF never EFV, no en or em dash, plural forms", function()
	H.world()
	H.loadEFV()
	local texts = {
		Locale.Lookup("LOC_EFV_NO_COMMON_WAR_EXP", "Rome"),
		Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR_EXP", "Rome"),
		Locale.Lookup("LOC_EFV_CANCEL_REASON_NO_COMMON_WAR_EXP_HOST", "Rome"),
		Locale.Lookup("LOC_EFV_PICKER_PROXY_WAR", "Rome", 1),
		Locale.Lookup("LOC_EFV_PICKER_PROXY_WAR", "Rome", 4),
		Locale.Lookup("LOC_EFV_PICKER_PROXY_WAR_ANY", "Rome"),
		Locale.Lookup("LOC_EFV_PICKER_PROXY_TRIP", 1),
		Locale.Lookup("LOC_EFV_PICKER_PROXY_TRIP", 4),
		Locale.Lookup("LOC_EFV_ACTION_SEND_EXPEDITIONARY_TT"),
	}
	H.len(FAKE.textArgErrors, 0)
	for _, t in ipairs(texts) do
		H.ok(not Has(t, "LOC_EFV"), "defined: " .. t)
		H.ok(not Has(t, "{"), "all placeholders filled: " .. t)
		H.ok(string.find(t, "%f[%w]EFV%f[%W]") == nil, "says VEF, never EFV: " .. t)
		H.ok(not Has(t, EM) and not Has(t, EN), "no en or em dash: " .. t)
	end
	H.ok(Has(texts[4], "1 turn of") and Has(texts[5], "4 turns of"), "plural forms")
	H.ok(Has(texts[7], "takes 1 turn.") and Has(texts[8], "takes 4 turns."), "plural forms")
	H.ok(Has(texts[9], "proxy war"), "the Send as Expeditionary help mentions the proxy war")
end)

-- ===========================================================================
-- u: the picker (UI)
-- ===========================================================================
local function IM(name)
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == name then return im end
	end
end

local function BootUI(opts)
	local S = Scenario(opts)
	H.setRes(B, "RESOURCE_IRON", 5)     -- no heal warning unless a test wants one
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	local ctx = {}
	ctx.actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	ctx.picker = FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	H.markBody()
	return S, ctx
end

-- Opens the picker for u and returns B's row instance (B has one city; the
-- rows are in ascending recipient order, B = P1 first).
local function BRow(u, ft)
	LuaEvents.EFV_OpenDestinationPicker(ME, u:GetID(), ft or EXP)
	return IM("EFV_DestRowInstance").list[1]
end

local function Note(enemy, n) return Locale.Lookup("LOC_EFV_PICKER_PROXY_WAR", EFV_UI_PlayerName(enemy), n) end
local function Trip(n) return Locale.Lookup("LOC_EFV_PICKER_PROXY_TRIP", n) end

test("u1 picker: an enabled proxy row's tooltip names the enemy and the turns left (31 on the denounce turn, limit 30); with a heal warning both lines show", function()
	local S, ctx = BootUI()
	local u = Unit()
	H.denounce(ME, E)
	local row = BRow(u)
	H.ok(not row.RowButton.disabled, "row enabled")
	H.eq(row.RowButton.tooltip, Note(E, 31))
	H.ok(Has(row.RowButton.tooltip, "Proxy war against ") and Has(row.RowButton.tooltip, ": 31 turns of denouncement left."))
	H.setRes(B, "RESOURCE_IRON", 0)
	row = BRow(u)
	local tip = row.RowButton.tooltip
	H.ok(string.find(tip, Note(E, 31) .. "[NEWLINE]", 1, true) == 1, tip)
	H.ok(Has(tip, Locale.Lookup("LOC_EFV_WARN_NO_HEAL", EFV_UI_PlayerName(B), "[ICON_RESOURCE_IRON] " .. Locale.Lookup(GameInfo.Resources["RESOURCE_IRON"].Name))), tip)
	H.clean()
end)

test("u2 the trip line shows exactly when the trip (2 turns) is as long as the turns left, or longer", function()
	local S, ctx = BootUI()
	local u = Unit()
	H.denounceLimit(3)
	H.denounce(ME, E)                                -- turn 1: N = 1 + 1 + 3 - 1 = 4
	H.eq(BRow(u).RowButton.tooltip, Note(E, 4))
	FAKE.turn = 2
	H.eq(BRow(u).RowButton.tooltip, Note(E, 3), "N = 3 > trip 2: no warning")
	FAKE.turn = 3
	H.eq(BRow(u).RowButton.tooltip, Note(E, 2) .. "[NEWLINE][COLOR:Red]" .. Trip(2) .. "[ENDCOLOR]", "N = 2 = trip")
	FAKE.turn = 4
	H.eq(BRow(u).RowButton.tooltip, Note(E, 1) .. "[NEWLINE][COLOR:Red]" .. Trip(2) .. "[ENDCOLOR]", "N = 1 < trip")
	H.clean()
end)

test("u3 two enemies: the one with more turns left is named; a tie names the lowest ID", function()
	local S, ctx = BootUI({ turn = 3 })
	local u = Unit()
	H.denounce(ME, E, 1)
	H.denounce(ME, X, 3)
	H.eq(BRow(u).RowButton.tooltip, Note(X, 31), "X: 31 left, E: 29")
	H.denounce(ME, X, 1)
	H.eq(BRow(u).RowButton.tooltip, Note(E, 29), "tie: E (lower ID)")
	H.clean()
end)

test("u4 a COMMON row has no proxy line; u5 GetDenounceTurn missing -> the _ANY line, no trip line", function()
	local S, ctx = BootUI()
	local u = Unit()
	H.denounce(ME, E)
	H.war(ME, X)
	H.eq(BRow(u).RowButton.tooltip, "", "u4: common war, no note")
	H.peace(ME, X)
	H.denounceLimit(1)                              -- N would be 2 = the trip
	FAKE.denounceTurnMissing = true
	H.eq(BRow(u).RowButton.tooltip, Locale.Lookup("LOC_EFV_PICKER_PROXY_WAR_ANY", EFV_UI_PlayerName(E)), "u5")
	H.ok(not Has(BRow(u).RowButton.tooltip, "trip"), "no trip line")
	H.clean()
end)

test("u6 disabled rows: Expeditionary uses LOC_EFV_NO_COMMON_WAR_EXP, Volunteers the plain key; the Send-button summary for Expeditionary lists both partners", function()
	local S, ctx = BootUI()
	local u = Unit()
	local row = BRow(u, EXP)
	H.ok(row.RowButton.disabled)
	H.eq(row.RowButton.tooltip, "[COLOR:Red]" .. Locale.Lookup("LOC_EFV_NO_COMMON_WAR_EXP", EFV_UI_PlayerName(B)) .. "[ENDCOLOR]")
	row = BRow(u, VOL)
	H.ok(row.RowButton.disabled)
	H.eq(row.RowButton.tooltip, "[COLOR:Red]" .. Locale.Lookup("LOC_EFV_REASON_NO_COMMON_WAR", EFV_UI_PlayerName(B)) .. "[ENDCOLOR]")
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(ME, u:GetID(), 0, 0, 0, true, false)
	FAKE_UI.Frame(ctx.actions)
	local expB, volB = nil, nil
	for _, b in ipairs(IM("EFV_ActionInstance").list) do
		local tt = b.UnitActionButton.tooltip or ""
		if Has(tt, Locale.Lookup("LOC_EFV_ACTION_SEND_EXPEDITIONARY_TT")) then expB = b end
		if Has(tt, Locale.Lookup("LOC_EFV_ACTION_SEND_VOLUNTEER_TT")) then volB = b end
	end
	H.notnil(expB); H.notnil(volB)
	H.ok(expB.UnitActionButton.disabled)
	local names = EFV_UI_PlayerName(B) .. ", " .. EFV_UI_PlayerName(F5)
	H.ok(Has(expB.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_NO_COMMON_WAR_EXP", names)), expB.UnitActionButton.tooltip)
	H.ok(Has(volB.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_REASON_NO_COMMON_WAR", EFV_UI_PlayerName(B))), volB.UnitActionButton.tooltip)
	H.ok(not Has(volB.UnitActionButton.tooltip, "denounced"))
	H.clean()
end)

test("u7 EFV_UI_DenounceTurnsLeft follows the base formula: you denounced, they denounced, both, the player-order term both ways, never -> nil", function()
	local S, ctx = BootUI({ turn = 10 })
	H.isnil(EFV_UI_DenounceTurnsLeft(ME, E), "-1 / -1")
	H.denounce(ME, E, 5)
	-- The player-order term is 1 when the later denouncer has the higher ID,
	-- from either side's view (DiplomacyActionView.lua:1488-1496).
	H.eq(EFV_UI_DenounceTurnsLeft(ME, E), 1 + 5 + 30 - 10, "you denounced (lower ID): 26")
	H.eq(EFV_UI_DenounceTurnsLeft(E, ME), 1 + 5 + 30 - 10, "the same seen from E")
	H.denounce(E, ME, 7)
	H.eq(EFV_UI_DenounceTurnsLeft(ME, E), 1 + 7 + 30 - 10 + 1, "both: the later is E (higher ID), +1")
	H.eq(EFV_UI_DenounceTurnsLeft(E, ME), 1 + 7 + 30 - 10 + 1, "the same seen from E")
	H.denounce(X, B, 5)
	H.eq(EFV_UI_DenounceTurnsLeft(X, B), 1 + 5 + 30 - 10 + 1, "s > e and s denounced: +1")
	H.eq(EFV_UI_DenounceTurnsLeft(B, X), 1 + 5 + 30 - 10 + 1, "s < e and e denounced: +1")
	FAKE.denounceTurnMissing = true
	H.isnil(EFV_UI_DenounceTurnsLeft(ME, E), "reader missing")
	H.clean()
end)

test("u8 the confirm dialog contains the proxy line, and the trip line when shown", function()
	local S, ctx = BootUI()
	local u = Unit()
	H.denounce(ME, E)
	FAKE_UI.popups = {}
	BRow(u).RowButton:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.notnil(popup)
	H.ok(Has(popup.texts[1], "[NEWLINE][NEWLINE]" .. Note(E, 31)), popup.texts[1])
	H.ok(not Has(popup.texts[1], Trip(2)))
	H.denounceLimit(1)                              -- N = 1 + 1 + 1 - 1 = 2 = the trip
	BRow(u).RowButton:Click()
	popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.ok(Has(popup.texts[1], Note(E, 2) .. "[NEWLINE][COLOR:Red]" .. Trip(2) .. "[ENDCOLOR]"), popup.texts[1])
	H.clean()
end)
