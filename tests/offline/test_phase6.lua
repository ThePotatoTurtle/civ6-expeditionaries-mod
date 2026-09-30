-- @harness native
-- Phase 6: Entrust (spec 12; PLAN 2.10, 3.4, 5.6; DECISIONS D1, D5 and
-- "Entrust transfer type resolved"; Session F T15 / T16 / T20 / T24;
-- INTERFACES note 31), plus the 0.6.0 heal-gate warning (designer ruling
-- "Strategic-resource heal gate").
-- Base scenario: 0 human, 1 ally, 2 declared friend, 3 enemy (at war with
-- 0, 1, 2 and the city-state 4), 62 Free Cities. Designer ruling 2026-09-30:
-- a city-state old owner (alive or not) or one knocked out of the game needs
-- no war with the recipient (EFV_EntrustSkipsWarCheck); LoneEnemy() gives a
-- living major (5) that only the human fights.

local N = function(name) return "EFV_NOTIF_" .. name end

-- Player 0 captures `city` (engine order: ownership changes, then
-- GameEvents.CityConquered). Returns the city object after the capture.
local function Capture(oldOwner, city, capturer)
	capturer = capturer or 0
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, capturer, CityTransferTypes.BY_COMBAT)
	GameEvents.CityConquered(capturer, oldOwner, oldID, x, y)
	return CityManager.GetCityAt(x, y)
end

local function Snap(city)
	return EFV_Records.Load().entrust[EFV_PlotKey(city.x, city.y)]
end

local function Entrust(pid, city, recipientID)
	H.request(pid, { OnStart = "EFV_Entrust", x = city.x, y = city.y, recipientID = recipientID })
end

local function Owner(city)
	local c = CityManager.GetCityAt(city.x, city.y)
	return c and c:GetOwner()
end

local function FailedText(pid)
	local list = H.notifs(pid, N("REQUEST_FAILED"))
	local n = list[#list]
	return n and n.data[ParameterTypes.SUMMARY] or ""
end

-- A living major (5) at war with the human only: its partners (1 ally, 2
-- friend) are not at war with it, so they cannot take its city. It keeps a
-- second city, so taking the first does not knock it out. Returns the city
-- to capture.
local function LoneEnemy()
	FAKE.NewPlayer(5, { gold = 0 })
	local c = H.city(5, 60, 12, { capital = true, name = "LOC_CITY_E" })
	H.city(5, 64, 16, { name = "LOC_CITY_E2" })
	H.war(0, 5)
	return c
end

-- Capture of the old owner's LAST city: the engine has already marked it
-- dead inside GameEvents.CityConquered (Session F T20).
local function CaptureLast(oldOwner, city)
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, 0, CityTransferTypes.BY_COMBAT)
	H.kill(oldOwner)
	GameEvents.CityConquered(0, oldOwner, oldID, x, y)
	return CityManager.GetCityAt(x, y)
end

-- ---------------------------------------------------------------------------
-- Capture-time eligibility snapshot (spec 12.2)
-- ---------------------------------------------------------------------------
test("P6.1 snapshot: ally and friend at war with the old owner qualify; partners recorded; keyed by plot", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	local snap = Snap(S.c3)
	H.notnil(snap)
	H.eq(snap.capturerID, 0); H.eq(snap.oldOwnerID, 3); H.eq(snap.turn, FAKE.turn)
	H.deq(snap.recipients, { 1, 2 })
	H.deq(snap.partners, { 1, 2 })
	H.ok(H.hasLine("[Entrust] snapshot"))
	H.clean()
end)

test("P6.2 snapshot: partners not at war with a living major old owner -> no recipient, partners kept for the tooltip", function()
	H.baseScenario()
	local c5 = LoneEnemy()                   -- the human fights 5 alone
	H.loadEFV()
	Capture(5, c5)
	local snap = Snap(c5)
	H.deq(snap.recipients, {})
	H.deq(snap.partners, { 1, 2 })
	H.deq(EFV_EntrustSnapshotReasons(snap, 0, FAKE.turn), { "ENTRUST_NO_PARTNER" })
	H.ok(H.hasLine("noWarCheck=no"))
	Entrust(0, c5, 1)
	H.eq(Owner(c5), 0, "still refused: 5 is alive, a major, and nobody else fights it")
	H.clean()
end)

test("P6.2b snapshot: a city-state's city qualifies every partner, at war with it or not (ruling 2026-09-30)", function()
	local S = H.baseScenario()
	H.war(0, 4); H.war(1, 4)
	H.loadEFV()
	Capture(4, S.c4)
	H.deq(Snap(S.c4).recipients, { 1, 2 })
	H.clean()
end)

test("P6.5 snapshot: Free City capture -> every partner qualifies (at war with everyone)", function()
	local S = H.baseScenario()
	local fc = H.city(62, 50, 30, { name = "LOC_CITY_FREE" })
	H.war(0, 62)                             -- only the capturer is formally at war
	H.loadEFV()
	Capture(62, fc)
	H.deq(Snap(fc).recipients, { 1, 2 })
	H.clean()
end)

test("snapshot: teammate qualifies; war with the capturer or a dead partner does not; city-states never", function()
	local S = H.baseScenario()
	FAKE.NewPlayer(5, { gold = 0 })
	H.team(5, 0)                             -- teammate of the human (team 0)
	H.war(5, 3)
	H.war(0, 2)                              -- the friend is now at war with the capturer (war wins)
	H.kill(1)                                -- the ally is dead
	H.war(4, 3)
	H.loadEFV()
	Capture(3, S.c3)
	H.deq(Snap(S.c3).recipients, { 5 })
	H.clean()
end)

test("snapshot: AI capturer -> none; a new capture at the same plot replaces the old snapshot", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	H.notnil(Snap(S.c3))
	-- the enemy retakes it (AI capturer): the old offer disappears
	Capture(0, CityManager.GetCityAt(S.c3.x, S.c3.y), 3)
	H.isnil(Snap(S.c3), "AI capture leaves no snapshot and drops the old one")
	H.ok(H.hasLine("replaced"))
	H.clean()
end)

test("snapshot survives a reload (property round trip); empty lists normalised", function()
	H.baseScenario()
	local c5 = LoneEnemy()
	H.loadEFV()
	Capture(5, c5)
	H.reloadEFV()
	local snap = Snap(c5)
	H.notnil(snap)
	H.deq(snap.recipients, {}); H.deq(snap.partners, { 1, 2 })
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Request: re-validation against the snapshot (spec 12.3)
-- ---------------------------------------------------------------------------
test("P6.1 transfer: KEEP-first flow, BY_GIFT, new city ID re-fetched by plot, ENTRUSTED to both, snapshot consumed", function()
	local S = H.baseScenario()
	Players[1].human = true
	H.loadEFV()
	local captured = Capture(3, S.c3)
	local capturedID = captured:GetID()
	Entrust(0, S.c3, 1)
	local c = CityManager.GetCityAt(S.c3.x, S.c3.y)
	H.eq(c:GetOwner(), 1)
	H.ne(c:GetID(), capturedID, "the transfer gives the city a new ID")
	local t = FAKE.transfers[#FAKE.transfers]
	H.eq(t.how, CityTransferTypes.BY_GIFT); H.eq(t.from, 0); H.eq(t.to, 1)
	H.isnil(Snap(S.c3), "capturer has no further relationship")
	local n0, n1 = H.notifs(0, N("ENTRUSTED")), H.notifs(1, N("ENTRUSTED"))
	H.len(n0, 1); H.len(n1, 1)
	local expect = Locale.Lookup("LOC_EFV_NOTIF_ENTRUSTED_SUMMARY", EFV_PlayerName(0), EFV_CityName(c), EFV_PlayerName(1))
	H.eq(n0[1].data[ParameterTypes.SUMMARY], expect)
	H.ok(H.hasLine("cityID " .. capturedID .. " -> " .. c:GetID()), "log names old and new city ID")
	-- a second (replayed) request finds no snapshot: nothing happens twice
	Entrust(0, S.c3, 2)
	H.eq(Owner(S.c3), 1)
	H.eq(#FAKE.transfers, 2, "only the capture and the one entrust transfer")
	H.ok(string.find(FailedText(0), Locale.Lookup("LOC_EFV_REASON_ENTRUST_STALE"), 1, true))
	H.clean()
end)

test("P6.6 transfer: a capital can be entrusted; recipient need not be allied (friend)", function()
	local S = H.baseScenario()
	H.loadEFV()
	H.ok(S.c3:IsCapital())
	Capture(3, S.c3)
	Entrust(0, S.c3, 2)
	H.eq(Owner(S.c3), 2)
	H.clean()
end)

test("P6.7 re-validation: next turn (stale), recipient not in the snapshot, other requester, AI requester", function()
	local S = H.baseScenario()
	Players[2].human = true
	H.loadEFV()
	Capture(3, S.c3)
	Entrust(0, S.c3, 4)                      -- city-state: never listed
	H.eq(Owner(S.c3), 0)
	H.ok(string.find(FailedText(0), Locale.Lookup("LOC_EFV_REASON_ENTRUST_RECIPIENT_INVALID"), 1, true))
	Entrust(2, S.c3, 1)                      -- another (human) player forges it
	H.eq(Owner(S.c3), 0)
	H.ok(string.find(FailedText(2), Locale.Lookup("LOC_EFV_REASON_ENTRUST_STALE"), 1, true))
	Entrust(1, S.c3, 2)                      -- AI requester: ignored (AI never entrusts)
	H.eq(Owner(S.c3), 0)
	H.ok(H.hasLine("reasons=NOT_HUMAN_MAJOR"))
	H.endTurn()
	H.isnil(Snap(S.c3), "step 0a dropped the stale snapshot")
	Entrust(0, S.c3, 1)
	H.eq(Owner(S.c3), 0, "only in the capture turn")
	H.clean()
end)

test("re-validation: recipient eliminated or now at war with the capturer -> RECIPIENT_INVALID", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	H.war(0, 1)
	Entrust(0, S.c3, 1)
	H.eq(Owner(S.c3), 0)
	H.kill(2)
	Entrust(0, S.c3, 2)
	H.eq(Owner(S.c3), 0)
	H.len(H.notifs(0, N("REQUEST_FAILED")), 2)
	H.notnil(Snap(S.c3), "snapshot kept: the choice stays open this turn")
	H.clean()
end)

test("re-validation: a city no longer owned by the capturer (liberated) -> STALE, nothing transferred", function()
	local S = H.baseScenario()
	H.loadEFV()
	local c = Capture(3, S.c3)
	CityManager.TransferCity(c, 3, CityTransferTypes.BY_GIFT)   -- e.g. liberated to the old owner
	local before = #FAKE.transfers
	Entrust(0, S.c3, 1)
	H.eq(Owner(S.c3), 3); H.eq(#FAKE.transfers, before)
	H.ok(string.find(FailedText(0), Locale.Lookup("LOC_EFV_REASON_ENTRUST_STALE"), 1, true))
	H.clean()
end)

test("P6.2 request with no qualifying partner -> NO_PARTNER naming the former owner", function()
	H.baseScenario()
	local c5 = LoneEnemy()
	H.loadEFV()
	Capture(5, c5)
	Entrust(0, c5, 1)
	H.eq(Owner(c5), 0)
	H.ok(string.find(FailedText(0), Locale.Lookup("LOC_EFV_REASON_ENTRUST_NO_PARTNER", EFV_PlayerName(5)), 1, true))
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Designer ruling 2026-09-30: no war test when the old owner is a city-state
-- (alive or not) or has been knocked out (EFV_EntrustSkipsWarCheck)
-- ---------------------------------------------------------------------------
test("ruling: EFV_EntrustSkipsWarCheck by old owner (Free Cities, city-state alive or dead, major dead or cityless)", function()
	H.baseScenario()
	LoneEnemy()
	H.loadEFV()
	H.deq({ EFV_EntrustSkipsWarCheck(62) }, { true, "FREE_CITIES" })
	H.deq({ EFV_EntrustSkipsWarCheck(4) }, { true, "CITY_STATE" })
	H.deq({ EFV_EntrustSkipsWarCheck(3) }, { false }, "living major with a city: war test applies")
	H.deq({ EFV_EntrustSkipsWarCheck(5) }, { false })
	H.kill(4)
	H.deq({ EFV_EntrustSkipsWarCheck(4) }, { true, "CITY_STATE" }, "a dead city-state is still recognised")
	H.kill(3)
	H.deq({ EFV_EntrustSkipsWarCheck(3) }, { true, "ELIMINATED" })
	-- 5 loses both cities but is not marked dead yet (the other event
	-- order): no city left counts as knocked out too
	for _, c in ipairs(FAKE.CitiesOf(5)) do
		CityManager.TransferCity(c, 0, CityTransferTypes.BY_COMBAT)
	end
	H.ok(Players[5]:IsAlive())
	H.deq({ EFV_EntrustSkipsWarCheck(5) }, { true, "ELIMINATED" })
	H.deq({ EFV_EntrustSkipsWarCheck(-1) }, { false })
	H.clean()
end)

test("ruling: city-state old owner, alive, nobody else at war with it -> any partner can take the city", function()
	local S = H.baseScenario()
	H.city(4, 33, 24, { name = "LOC_CITY_CS2" })   -- keeps the city-state alive
	H.war(0, 4)                              -- the human fights the city-state alone
	H.loadEFV()
	Capture(4, S.c4)
	H.ok(Players[4]:IsAlive())
	H.deq(Snap(S.c4).recipients, { 1, 2 })
	H.ok(H.hasLine("noWarCheck=CITY_STATE"))
	Entrust(0, S.c4, 2)
	H.eq(Owner(S.c4), 2)
	H.clean()
end)

test("ruling: city-state eliminated by the capture -> any partner can take the city", function()
	local S = H.baseScenario()
	H.war(0, 4)
	H.loadEFV()
	CaptureLast(4, S.c4)
	H.deq(Snap(S.c4).recipients, { 1, 2 })
	H.ok(H.hasLine("noWarCheck=CITY_STATE"))
	Entrust(0, S.c4, 1)
	H.eq(Owner(S.c4), 1)
	H.clean()
end)

test("ruling: major eliminated by the capture of its last city -> any partner can take the city", function()
	H.baseScenario()
	FAKE.NewPlayer(5, { gold = 0 })
	local c5 = H.city(5, 60, 12, { capital = true, name = "LOC_CITY_E" })
	H.war(0, 5)                              -- 1 and 2 were never at war with 5
	H.loadEFV()
	CaptureLast(5, c5)
	H.deq(Snap(c5).recipients, { 1, 2 })
	H.ok(H.hasLine("noWarCheck=ELIMINATED"))
	Entrust(0, c5, 2)
	H.eq(Owner(c5), 2)
	H.clean()
end)

test("ruling: Free City still qualifies every partner; a living major still needs the war", function()
	H.baseScenario()
	local fc = H.city(62, 50, 30, { name = "LOC_CITY_FREE" })
	local c5 = LoneEnemy()
	H.war(0, 62)
	H.war(1, 5)                              -- the ally fights 5 too, the friend does not
	H.loadEFV()
	Capture(62, fc)
	H.deq(Snap(fc).recipients, { 1, 2 })
	H.ok(H.hasLine("noWarCheck=FREE_CITIES"))
	Capture(5, c5)
	H.deq(Snap(c5).recipients, { 1 }, "only the partner at war with the living major")
	Entrust(0, c5, 2)
	H.eq(Owner(c5), 0, "the friend is refused")
	Entrust(0, c5, 1)
	H.eq(Owner(c5), 1)
	H.clean()
end)

test("transfer path: engine refuses the transfer -> ENTRUST_FAILED, city and snapshot kept", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	local real = CityManager.TransferCity
	CityManager.TransferCity = function() return false end
	Entrust(0, S.c3, 1)
	CityManager.TransferCity = real
	H.eq(Owner(S.c3), 0)
	H.ok(string.find(FailedText(0), Locale.Lookup("LOC_EFV_REASON_ENTRUST_FAILED"), 1, true))
	H.notnil(Snap(S.c3))
	H.eq(#H.errorLines(), 1, "one logged ERROR (transfer failed)")
end, { allowErrors = true })

test("transfer path: unknown FLAG_ENTRUST_TRANSFER_TYPE falls back to BY_GIFT", function()
	local S = H.baseScenario()
	H.loadEFV({ flags = { FLAG_ENTRUST_TRANSFER_TYPE = "BY_NONSENSE" } })
	Capture(3, S.c3)
	Entrust(0, S.c3, 1)
	H.eq(Owner(S.c3), 1)
	H.eq(FAKE.transfers[#FAKE.transfers].how, CityTransferTypes.BY_GIFT)
	H.len(H.lines("unknown FLAG_ENTRUST_TRANSFER_TYPE"), 1, "logged as an error")
end, { allowErrors = true })

-- ---------------------------------------------------------------------------
-- UI: the Entrust button in the capture popup (PLAN 3.4, T24)
-- ---------------------------------------------------------------------------
local function BootUI()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local env = FAKE_UI.LoadContext("EFV/UI/EFV_EntrustPopup.lua")
	H.markBody()
	return env
end

local function OpenPopup(city)
	FAKE.capturedCity = { [0] = CityManager.GetCityAt(city.x, city.y) }
	LuaEvents.NotificationPanel_OpenRazeCityChooser()
end

local function Rows()
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_EntrustButtonInstance" then return im.list end
	end
	return {}
end

test("P6.1 UI: Entrust injected into RazeCity; picker lists recipients; two clicks send KEEP then EFV_Entrust and close", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	local env = BootUI()
	OpenPopup(S.c3)
	local C = env.Controls
	H.eq(C.EFV_EntrustStack.parent, FAKE_UI.built["/InGame/RazeCity/PopupStack"], "moved into the popup stack")
	H.ok(not C.EFV_EntrustStack:IsHidden())
	H.ok(not C.EntrustMainButton:IsDisabled())
	H.ok(string.find(C.EntrustMainButton.tooltip, Locale.Lookup("LOC_EFV_ENTRUST_TT_RECIPIENTS",
		EFV_UI_PlayerName(1) .. ", " .. EFV_UI_PlayerName(2)), 1, true), C.EntrustMainButton.tooltip)
	H.ok(C.EFV_RecipientStack:IsHidden(), "picker closed until clicked")
	C.EntrustMainButton:Click()
	H.ok(not C.EFV_RecipientStack:IsHidden())
	local rows = Rows()
	H.len(rows, 2)
	H.eq(rows[1].EntrustButton.text, Locale.Lookup("LOC_EFV_ENTRUST_TO", EFV_UI_PlayerName(1)))
	rows[1].EntrustButton:Click()                          -- arm
	H.len(FAKE_UI.requests, 0, "first click only arms")
	rows = Rows()
	H.eq(rows[1].EntrustButton.text, Locale.Lookup("LOC_EFV_ENTRUST_CONFIRM_BUTTON", EFV_UI_PlayerName(1)))
	rows[1].EntrustButton:Click()                          -- confirm
	H.len(FAKE_UI.cityCommands, 1)
	H.eq(FAKE_UI.cityCommands[1].flags, CityDestroyDirectives.KEEP, "KEEP first (D5)")
	H.len(FAKE_UI.requests, 1)
	local req = FAKE_UI.requests[1]
	H.eq(req.params.OnStart, "EFV_Entrust"); H.eq(req.params.x, S.c3.x); H.eq(req.params.y, S.c3.y)
	H.eq(req.params.recipientID, 1)
	H.eq(FAKE_UI.dequeued[#FAKE_UI.dequeued], FAKE_UI.built["/InGame/RazeCity"], "RazeCity closed")
	FAKE_UI.AsGameplay(function() H.request(req.pid, req.params) end)
	H.eq(Owner(S.c3), 1)
	H.clean()
end)

test("UI: popup reopened without a decision rebuilds (picker closed, nothing armed); no KEEP when unavailable", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	local env = BootUI()
	OpenPopup(S.c3)
	env.Controls.EntrustMainButton:Click()
	Rows()[2].EntrustButton:Click()
	OpenPopup(S.c3)                                        -- closed with X, notification reopened it
	H.ok(env.Controls.EFV_RecipientStack:IsHidden())
	env.Controls.EntrustMainButton:Click()
	Rows()[2].EntrustButton:Click()
	H.len(FAKE_UI.requests, 0, "arming was reset by the reopen")
	FAKE_UI.canKeep = false
	Rows()[2].EntrustButton:Click()
	H.len(FAKE_UI.cityCommands, 0, "KEEP not available -> not sent")
	H.len(FAKE_UI.requests, 1, "transfer request still sent (T16: works without KEEP)")
	H.clean()
end)

test("P6.2 UI: disabled button explains why (former owner named, partners not at war listed)", function()
	H.baseScenario()
	local c5 = LoneEnemy()
	H.loadEFV()
	Capture(5, c5)
	local env = BootUI()
	OpenPopup(c5)
	local b = env.Controls.EntrustMainButton
	H.ok(b:IsDisabled())
	H.eq(b.text, Locale.Lookup("LOC_EFV_ENTRUST_DISABLED_NO_PARTNER"))
	local old = EFV_UI_PlayerName(5)
	H.ok(string.find(b.tooltip, Locale.Lookup("LOC_EFV_REASON_ENTRUST_NO_PARTNER", old), 1, true), b.tooltip)
	H.ok(string.find(b.tooltip, Locale.Lookup("LOC_EFV_ENTRUST_NOT_AT_WAR",
		EFV_UI_PlayerName(1) .. ", " .. EFV_UI_PlayerName(2), old), 1, true), b.tooltip)
	H.ok(not string.find(b.tooltip, "{", 1, true), "all arguments filled")
	b:Click()
	H.len(Rows(), 0, "a disabled button opens no picker")
	H.clean()
end)

test("UI: disabled reasons - no partners at all, stale snapshot, recipients invalid now", function()
	local S = H.baseScenario()
	H.ally(0, 1, false); H.friend(0, 2, false); H.war(0, 4)
	H.loadEFV()
	Capture(4, S.c4)
	local env = BootUI()
	OpenPopup(S.c4)
	local b = env.Controls.EntrustMainButton
	H.ok(b:IsDisabled())
	H.ok(string.find(b.tooltip, Locale.Lookup("LOC_EFV_ENTRUST_NO_PARTNERS"), 1, true), b.tooltip)
	-- a captured city without a snapshot (e.g. taken before the mod was enabled)
	local other = H.city(3, 60, 20, { name = "LOC_CITY_C2" })
	CityManager.TransferCity(other, 0, CityTransferTypes.BY_COMBAT)
	OpenPopup(other)
	H.ok(b:IsDisabled()); H.eq(b.text, Locale.Lookup("LOC_EFV_ENTRUST_DISABLED"))
	H.ok(string.find(b.tooltip, Locale.Lookup("LOC_EFV_REASON_ENTRUST_STALE"), 1, true), b.tooltip)
	H.clean()
end)

test("UI: a recipient that became invalid is a disabled row; all invalid -> button disabled", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	H.war(0, 2)
	local env = BootUI()
	OpenPopup(S.c3)
	local b = env.Controls.EntrustMainButton
	H.ok(not b:IsDisabled())
	b:Click()
	local rows = Rows()
	H.len(rows, 2)
	H.ok(not rows[1].EntrustButton:IsDisabled())
	H.ok(rows[2].EntrustButton:IsDisabled())
	H.ok(string.find(rows[2].EntrustButton.tooltip, Locale.Lookup("LOC_EFV_REASON_ENTRUST_RECIPIENT_INVALID"), 1, true))
	rows[2].EntrustButton:Click()
	H.len(FAKE_UI.requests, 0)
	H.kill(1)
	OpenPopup(S.c3)
	H.ok(b:IsDisabled())
	H.ok(string.find(b.tooltip, Locale.Lookup("LOC_EFV_REASON_ENTRUST_RECIPIENT_INVALID"), 1, true), b.tooltip)
	H.clean()
end)

test("UI: no pending captured city -> no Entrust button", function()
	local S = H.baseScenario()
	H.loadEFV()
	local env = BootUI()
	FAKE.capturedCity = nil
	LuaEvents.NotificationPanel_OpenRazeCityChooser()
	H.ok(env.Controls.EFV_EntrustStack:IsHidden())
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Heal-gate warning (designer ruling "Strategic-resource heal gate", 0.6.0)
-- ---------------------------------------------------------------------------
test("heal gate: EFV_HealResourceType / EFV_HealGateBlocked follow the owner's stock", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(EFV_HealResourceType("UNIT_SWORDSMAN"), "RESOURCE_IRON")
	H.isnil(EFV_HealResourceType("UNIT_WARRIOR"))
	H.eq((EFV_HealGateBlocked("UNIT_SWORDSMAN", 1)), true, "no Iron")
	H.setRes(1, "RESOURCE_IRON", 1)
	H.eq((EFV_HealGateBlocked("UNIT_SWORDSMAN", 1)), false)
	H.eq((EFV_HealGateBlocked("UNIT_WARRIOR", 1)), false)
	H.eq((EFV_HealGateBlocked("UNIT_SWORDSMAN", 99)), false, "unknown owner -> no guess")
end)

test("heal gate UI: picker row tooltip and confirm warn when the recipient has no Iron; flag/tracker tooltip too", function()
	local S = H.baseScenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	H.markBody()
	local warn = Locale.Lookup("LOC_EFV_WARN_NO_HEAL", EFV_UI_PlayerName(1),
		"[ICON_RESOURCE_IRON] " .. Locale.Lookup(GameInfo.Resources["RESOURCE_IRON"].Name))
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(0, u:GetID(), 0, 0, 0, true, false)
	FAKE_UI.Frame(actions)
	local actIM, rowIM
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_ActionInstance" then actIM = im end
	end
	actIM.list[1].UnitActionButton:Click()                 -- Send as Expeditionary
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_DestRowInstance" then rowIM = im end
	end
	local row
	for _, r in ipairs(rowIM.list) do
		if string.find(r.RowLabel.text, " - " .. EFV_CityName(S.c1) .. " - ", 1, true) then row = r end
	end
	H.notnil(row)
	H.ok(string.find(row.RowButton.tooltip, warn, 1, true), "row tooltip: " .. tostring(row.RowButton.tooltip))
	row.RowButton:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.ok(string.find(popup.texts[1], warn, 1, true), popup.texts[1])
	-- with Iron the warning is gone
	H.setRes(1, "RESOURCE_IRON", 3)
	actIM.list[1].UnitActionButton:Click()
	for _, r in ipairs(rowIM.list) do
		if string.find(r.RowLabel.text, " - " .. EFV_CityName(S.c1) .. " - ", 1, true) then row = r end
	end
	H.ok(not string.find(row.RowButton.tooltip or "", "LOC_EFV_WARN", 1, true))
	H.eq(row.RowButton.tooltip, "")
	-- deployed Expeditionary unit: status tooltip (flag badge, tracker row)
	H.setRes(1, "RESOURCE_IRON", 0)
	FAKE_UI.AsGameplay(function()
		H.send(0, u, 1, S.c1, "EXPEDITIONARY")
		H.turns(H.records()[1].arrivalTurn - FAKE.turn)
	end)
	local rec = H.records()[1]
	H.eq(rec.state, "DEPLOYED")
	H.ok(string.find(EFV_UI_StatusTooltip(rec), warn, 1, true), EFV_UI_StatusTooltip(rec))
	local rows = EFV_UI_TrackerRows(0, FAKE.turn)
	H.ok(string.find(rows[1].tooltip, warn, 1, true), "tracker row tooltip")
	H.setRes(1, "RESOURCE_IRON", 2)
	H.ok(not string.find(EFV_UI_StatusTooltip(rec), warn, 1, true))
	H.clean()
end)
