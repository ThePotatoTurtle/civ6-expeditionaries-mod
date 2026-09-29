-- @harness native
-- 1.0.1 common-war fix (research/bug_common_war/Lua.log L2008): on 1.0.0 an
-- Expeditionary to Mali (P5), a declared friend at war with nobody, was
-- enabled in the picker and accepted by gameplay (basis=FRIEND). Cause: the
-- engine keeps every major permanently at war with the Free Cities player
-- (62) and the barbarians (63) (Session E H_DIPLO matrix,
-- research/phase0_results/raw/sessionE_Lua.log L17468-L17483), and
-- EFV_HasCommonWar counted the Free Cities as a common enemy, so any two
-- majors "shared" one. City-states are not at war with the Free Cities,
-- which is why the City-State path (Kandy blocked) looked right.
-- Rule now (spec 6.1.3, DECISIONS "Common enemy"): only real wars against a
-- major civ or a city-state count; barbarians and Free Cities never do.
--
-- Scenario = the designer's game: 0 Rome (human), 1 England (friend + open
-- borders), 2 Japan (friend), 3 Gaul (at war with 0, 1, 2 and Rapa Nui),
-- 5 Mali (friend, no wars), 6 Rapa Nui (city-state at war with Gaul),
-- 7 Kandy (city-state, no wars), 62 Free Cities (one city), 63 barbarians.
-- The fake engine applies the permanent Free Cities / barbarian wars
-- (FAKE.permanentWars), like the real one.

local EXP, VOL, CS = "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"
local ROME, ENGLAND, JAPAN, GAUL, MALI, RAPA, KANDY, FREE, BARB = 0, 1, 2, 3, 5, 6, 7, 62, 63

local function Scenario()
	H.world({ players = {
		{ id = ROME, human = true, gold = 1000 }, { id = ENGLAND, gold = 1000 }, { id = JAPAN, gold = 1000 },
		{ id = GAUL, gold = 1000 }, { id = MALI, gold = 1000 },
		{ id = RAPA, kind = "CITY_STATE", gold = 0 }, { id = KANDY, kind = "CITY_STATE", gold = 0 },
		{ id = FREE, kind = "FREE_CITIES" }, { id = BARB, kind = "BARBARIAN" },
	} })
	local S = {}
	S.c0 = H.city(ROME, 10, 10, { capital = true, name = "Roma" })
	S.c1 = H.city(ENGLAND, 22, 10, { capital = true, name = "London" })
	S.c2 = H.city(JAPAN, 40, 30, { capital = true, name = "Kyoto" })
	S.c3 = H.city(GAUL, 70, 40, { capital = true, name = "Gergovia" })
	S.c5 = H.city(MALI, 12, 30, { capital = true, name = "Niani" })
	S.c6 = H.city(RAPA, 30, 20, { capital = true, name = "Rapa Nui" })
	S.c7 = H.city(KANDY, 50, 20, { capital = true, name = "Kandy" })
	S.cf = H.city(FREE, 60, 10, { name = "Free City" })
	H.friend(ROME, ENGLAND); H.openBorders(ROME, ENGLAND)
	H.friend(ROME, JAPAN)
	H.friend(ROME, MALI)
	H.war(GAUL, ROME); H.war(GAUL, ENGLAND); H.war(GAUL, JAPAN); H.war(GAUL, RAPA)
	H.meet(ROME, RAPA); H.meet(ROME, KANDY)
	return S
end

local function MyUnit() return H.unit(ROME, "UNIT_SWORDSMAN", 11, 10) end

local function Reasons(u, rid, city, ft)
	local _, r = EFV_EvaluateSend(ROME, u, rid, city, ft, EFV_Records.Load())
	return r
end

-- The rows of one recipient in a picker build: { ok, reasons } per row.
local function RowsOf(u, ft, rid)
	local out = {}
	for _, row in ipairs(EFV_DestinationRows(ROME, u, ft, EFV_Records.Load())) do
		if row.recipientID == rid then out[#out + 1] = row end
	end
	return out
end

-- Runs fn once as gameplay and once as UI (fake_ui adapters: UI ~= nil,
-- Player:IsFreeCities instead of GetFreeCitiesPlayerID, OB via
-- HasOpenBordersFrom).
local function BothContexts(fn)
	fn("G")
	include("fake_ui")
	FAKE_UI.Enable()
	fn("UI")                             -- the test stays in the UI context afterwards
end

test("1.0.1 exact case: friend with no wars -> Expeditionary blocked (NO_COMMON_WAR) in both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	-- The engine state that caused the bug is present.
	H.ok(Players[ROME]:GetDiplomacy():IsAtWarWith(FREE), "Rome at war with the Free Cities (engine)")
	H.ok(Players[MALI]:GetDiplomacy():IsAtWarWith(FREE), "Mali at war with the Free Cities (engine)")
	H.ok(Players[MALI]:GetDiplomacy():IsAtWarWith(BARB), "Mali at war with the barbarians (engine)")
	H.ok(not Players[KANDY]:GetDiplomacy():IsAtWarWith(FREE), "city-states are not")
	BothContexts(function(ctx)
		H.ok(not EFV_HasCommonWar(ROME, MALI), ctx .. ": no common enemy with Mali")
		H.deq(Reasons(u, MALI, S.c5, EXP), { "NO_COMMON_WAR" }, ctx .. ": Expeditionary to Mali")
		H.deq(Reasons(u, MALI, S.c5, VOL), { "VOL_NEEDS_ACCESS", "NO_COMMON_WAR" }, ctx .. ": Volunteers to Mali")
		local rows = RowsOf(u, EXP, MALI)
		H.len(rows, 1, ctx .. ": Mali row listed")
		H.ok(not rows[1].ok, ctx .. ": Mali row greyed"); H.contains(rows[1].reasons, "NO_COMMON_WAR")
		-- England and Japan share Gaul: Expeditionary allowed, Volunteers to England only.
		H.deq(Reasons(u, ENGLAND, S.c1, EXP), {}, ctx .. ": Expeditionary to England")
		H.deq(Reasons(u, JAPAN, S.c2, EXP), {}, ctx .. ": Expeditionary to Japan")
		H.deq(Reasons(u, ENGLAND, S.c1, VOL), {}, ctx .. ": Volunteers to England")
		H.deq(Reasons(u, JAPAN, S.c2, VOL), { "VOL_NEEDS_ACCESS" }, ctx .. ": Volunteers to Japan")
		-- City-State path unchanged: Rapa Nui (at war with Gaul) ok, Kandy blocked.
		H.deq(Reasons(u, RAPA, S.c6, CS), {}, ctx .. ": Rapa Nui")
		H.deq(Reasons(u, KANDY, S.c7, CS), { "NO_COMMON_WAR" }, ctx .. ": Kandy")
	end)
	H.clean()
end)

test("1.0.1 exact case: gameplay rejects the forged Expeditionary to Mali (no record, REQUEST_FAILED)", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.send(ROME, u, MALI, S.c5, EXP, 999)
	H.len(H.records(), 0, "no record for Mali")
	H.ok(u.owner == ROME and FAKE.units[u.id] ~= nil, "unit still Rome's")
	H.len(H.notifs(ROME, "EFV_NOTIF_REQUEST_FAILED"), 1)
	H.len(H.lines("[Send] ok"), 0)
	-- The legitimate send still works.
	H.send(ROME, u, ENGLAND, S.c1, EXP, 999)
	H.len(H.records(), 1, "Expeditionary to England accepted")
	H.eq(H.record().recipientID, ENGLAND)
	H.clean()
end)

test("1.0.1: recipient at war with the same enemy -> allowed, all three force types, both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.war(GAUL, MALI)                                 -- Mali joins the war on Gaul
	H.war(GAUL, KANDY)                                -- and so does Kandy
	BothContexts(function(ctx)
		H.ok(EFV_HasCommonWar(ROME, MALI), ctx)
		H.deq(Reasons(u, MALI, S.c5, EXP), {}, ctx .. ": Expeditionary")
		H.deq(Reasons(u, MALI, S.c5, VOL), { "VOL_NEEDS_ACCESS" }, ctx .. ": Volunteers still need open borders")
		H.deq(Reasons(u, KANDY, S.c7, CS), {}, ctx .. ": City-State")
	end)
	FAKE_UI.AsGameplay(function()
		H.openBorders(ROME, MALI)
		H.deq(Reasons(u, MALI, S.c5, VOL), {}, "G: Volunteers with open borders")
	end)
	H.deq(Reasons(u, MALI, S.c5, VOL), {}, "UI: Volunteers with open borders")
	H.clean()
end)

test("1.0.1: Free Cities never make a common war (all force types, both contexts, even a real CS war on them)", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.peace(GAUL, ROME)                               -- Rome's only real war ends
	H.war(FREE, KANDY); H.war(FREE, RAPA)             -- the city-states fight the Free Cities too
	H.ok(Players[ROME]:GetDiplomacy():IsAtWarWith(FREE))
	H.ok(Players[KANDY]:GetDiplomacy():IsAtWarWith(FREE))
	BothContexts(function(ctx)
		for _, rid in ipairs({ ENGLAND, JAPAN, MALI, RAPA, KANDY }) do
			H.ok(not EFV_HasCommonWar(ROME, rid), ctx .. ": no common war with " .. rid)
		end
		H.contains(Reasons(u, ENGLAND, S.c1, EXP), "NO_COMMON_WAR", ctx .. ": EXP England")
		H.contains(Reasons(u, MALI, S.c5, EXP), "NO_COMMON_WAR", ctx .. ": EXP Mali")
		H.contains(Reasons(u, ENGLAND, S.c1, VOL), "NO_COMMON_WAR", ctx .. ": VOL England")
		H.contains(Reasons(u, KANDY, S.c7, CS), "NO_COMMON_WAR", ctx .. ": CS Kandy")
		H.contains(Reasons(u, RAPA, S.c6, CS), "NO_COMMON_WAR", ctx .. ": CS Rapa Nui")
		H.eq(EFV_PlayerKind(FREE), "FREE_CITIES", ctx)
		H.ok(not EFV_IsCommonEnemyCandidate(FREE), ctx)
	end)
	H.clean()
end)

test("1.0.1: barbarians never count (declared or permanent), all force types, both contexts", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.peace(GAUL, ROME)
	for _, p in ipairs({ ROME, ENGLAND, JAPAN, MALI, RAPA, KANDY }) do H.war(BARB, p) end
	BothContexts(function(ctx)
		H.ok(not EFV_IsCommonEnemyCandidate(BARB), ctx)
		H.contains(Reasons(u, ENGLAND, S.c1, EXP), "NO_COMMON_WAR", ctx .. ": EXP")
		H.contains(Reasons(u, ENGLAND, S.c1, VOL), "NO_COMMON_WAR", ctx .. ": VOL")
		H.contains(Reasons(u, RAPA, S.c6, CS), "NO_COMMON_WAR", ctx .. ": CS")
	end)
	H.clean()
end)

test("1.0.1: a city-state both sides really fight counts; sender and recipient at war is still refused", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.peace(GAUL, ROME)
	H.war(ROME, KANDY); H.war(MALI, KANDY)            -- both fight Kandy
	BothContexts(function(ctx)
		H.ok(EFV_HasCommonWar(ROME, MALI), ctx .. ": Kandy is a real common enemy")
		H.deq(Reasons(u, MALI, S.c5, EXP), {}, ctx)
	end)
	FAKE_UI.AsGameplay(function()
		H.war(ROME, MALI)
		H.contains(Reasons(u, MALI, S.c5, EXP), "AT_WAR_WITH_RECIPIENT", "G")
		H.contains(Reasons(u, MALI, S.c5, EXP), "NOT_PARTNER", "war ends the friendship")
	end)
	H.clean()
end)

test("1.0.1 lifecycle: a Volunteer's WAR lapse fires when the shared war ends (Free Cities no longer mask it)", function()
	local S = Scenario()
	H.loadEFV()
	local u = MyUnit()
	H.send(ROME, u, ENGLAND, S.c1, VOL, 999)
	H.len(H.records(), 1, "Volunteer to England sent")
	local id = H.record().id
	H.turns(4)
	H.eq(EFV_Records.Get(EFV_Records.Load(), id).state, "DEPLOYED")
	H.isnil(EFV_VolunteerLapseReason(ROME, ENGLAND))
	H.peace(GAUL, ENGLAND)                            -- England leaves the war; only the Free Cities / barbarians remain
	H.eq(EFV_VolunteerLapseReason(ROME, ENGLAND), "WAR")
	H.endTurn()
	local r = EFV_Records.Get(EFV_Records.Load(), id)
	H.eq(r.lapsed, 1); H.eq(r.lapseReason, "WAR")
	H.war(GAUL, ENGLAND)
	H.endTurn()
	r = EFV_Records.Get(EFV_Records.Load(), id)
	H.eq(r.lapsed, 0, "lapse cancelled when the real war resumes")
	H.clean()
end)
