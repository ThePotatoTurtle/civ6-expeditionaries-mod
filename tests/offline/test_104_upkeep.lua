-- @harness native
-- 1.0.4 designer ruling (2026-10-05): the top bar's gold per turn leaves out
-- the upkeep VEF charges at each turn start for units in transit
-- (EFV_Transit.ChargeTransitMaintenance). The tracker shows that upkeep and
-- the real net gold per turn (top bar minus the upkeep). UI only.
--   * EFV_UI_TransitUpkeep: Maintenance summed over the local player's SENT
--     records in OUTBOUND / RETURNING; received and on-map units excluded;
--     equals what the gameplay charge takes from a full treasury;
--   * EFV_UI_SignedNumText / EFV_UI_TransitUpkeepText: the sign on the net,
--     hidden (nil) at 0;
--   * EFV_UI_TopBarGoldPerTurn: GetGoldYield - GetTotalMaintenance;
--   * the tracker panel: the line renders, follows gold changes through the
--     poll, hides at 0.

local function G(fn, ...) FAKE_UI.AsGameplay(fn, ...) end

local function BootUI(opts)
	opts = opts or {}
	local S = H.baseScenario({ turn = 50 })
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local tr = nil
	if opts.tracker ~= false then
		tr = FAKE_UI.LoadContext("EFV/UI/EFV_Tracker.lua")
	else
		include("EFV_UIShared")
	end
	H.markBody()
	return S, tr
end

-- A record (gameplay side); on-map states get a unit.
local function MakeRec(S, f)
	local rec
	G(function()
		local turn = Game.GetCurrentGameTurn()
		local ft = f.forceType or "EXPEDITIONARY"
		local sender, recipient = f.senderID or 0, f.recipientID or 1
		local state = f.state or "DEPLOYED"
		local dest = f.dest or S.c1
		local fields = {
			forceType = ft, state = state, senderID = sender, recipientID = recipient,
			accessBasis = "ALLIANCE", unitType = f.unitType or "UNIT_SWORDSMAN",
			originCityID = S.c0.id, originX = S.c0.x, originY = S.c0.y,
			destCityID = dest.id, destX = dest.x, destY = dest.y, rerouted = 0,
			sentTurn = turn - 5, arrivalTurn = turn + 2, transitTurns = 2, band = 2, distance = 12,
			lapsed = 0, spawnFailCount = 0, feePaid = 100, maintGoldPaid = 0,
			graceTurnsLeft = f.graceTurnsLeft,
		}
		if ft ~= "VOLUNTEER" and state ~= "OUTBOUND" then
			fields.durationTurns = 20
		end
		if state == "RETURNING" then
			fields.returnCityID, fields.returnX, fields.returnY = S.c0.id, S.c0.x, S.c0.y
		end
		if state ~= "OUTBOUND" and state ~= "RETURNING" then
			local owner = (ft == "VOLUNTEER") and sender or recipient
			local unit = H.unit(owner, fields.unitType, dest.x + 1, dest.y)
			fields.onMapPlayerID, fields.onMapUnitID = owner, unit.id
			fields.lastX, fields.lastY = unit.x, unit.y
			fields.deployedTurn = turn - 3
		end
		local store = EFV_Records.Load()
		rec = EFV_Records.New(store, fields)
		EFV_Records.Commit(store)
	end)
	return rec.id
end

local function SetState(id, state)
	G(function()
		local s = EFV_Records.Load()
		EFV_Records.Get(s, id).state = state
		EFV_Records.Touch(s); EFV_Records.Commit(s)
	end)
end

local function Maint(unitType) return GameInfo.Units[unitType].Maintenance end

-- ===========================================================================
-- Helper
-- ===========================================================================
test("1.0.4 upkeep helper: sums the local player's sent OUTBOUND / RETURNING records only", function()
	local S = BootUI({ tracker = false })
	H.eq(Maint("UNIT_SWORDSMAN"), 2); H.eq(Maint("UNIT_KNIGHT"), 4); H.eq(Maint("UNIT_WARRIOR"), 0)
	MakeRec(S, { state = "OUTBOUND", unitType = "UNIT_SWORDSMAN" })                         -- 2
	MakeRec(S, { state = "RETURNING", unitType = "UNIT_KNIGHT" })                           -- 4
	MakeRec(S, { state = "OUTBOUND", unitType = "UNIT_WARRIOR" })                           -- 0
	MakeRec(S, { state = "OUTBOUND", forceType = "VOLUNTEER", recipientID = 2, unitType = "UNIT_SWORDSMAN" }) -- 2
	MakeRec(S, { state = "DEPLOYED", unitType = "UNIT_KNIGHT" })                            -- on the map: no
	MakeRec(S, { state = "GRACE", graceTurnsLeft = 2, unitType = "UNIT_KNIGHT" })           -- on the map: no
	MakeRec(S, { state = "OUTBOUND", senderID = 1, recipientID = 0, dest = S.c0, unitType = "UNIT_KNIGHT" }) -- received: no
	MakeRec(S, { state = "RETURNING", senderID = 2, recipientID = 1, unitType = "UNIT_KNIGHT" })            -- not ours
	H.eq(EFV_UI_TransitUpkeep(0), 8, "2 + 4 + 0 + 2")
	H.eq(EFV_UI_TransitUpkeep(1), 4, "England's own Knight on its way to Rome")
	H.eq(EFV_UI_TransitUpkeep(2), 4)
	H.eq(EFV_UI_TransitUpkeep(3), 0)
	H.eq(EFV_UI_TransitUpkeep(-1), 0, "no local player")
	H.eq(EFV_UI_TransitUpkeep(0, EFV_UI_ReadStore()), 8, "explicit store")
	H.eq(EFV_UI_TransitUpkeep(0, { ids = {}, recs = {} }), 0, "empty store")
	H.clean()
end)

test("1.0.4 upkeep helper: matches what the gameplay charge takes from a full treasury", function()
	local S = BootUI({ tracker = false })
	MakeRec(S, { state = "OUTBOUND", unitType = "UNIT_SWORDSMAN" })
	MakeRec(S, { state = "RETURNING", unitType = "UNIT_KNIGHT" })
	MakeRec(S, { state = "DEPLOYED", unitType = "UNIT_KNIGHT" })
	MakeRec(S, { state = "OUTBOUND", senderID = 1, recipientID = 0, dest = S.c0, unitType = "UNIT_KNIGHT" })
	local shown = EFV_UI_TransitUpkeep(0)
	local before, after
	G(function()
		Players[0]:GetTreasury():SetGoldBalance(500)
		before = Players[0]:GetTreasury():GetGoldBalance()
		local s = EFV_Records.Load()
		EFV_Transit.ChargeTransitMaintenance(s, Game.GetCurrentGameTurn())
		EFV_Records.Commit(s)
		after = Players[0]:GetTreasury():GetGoldBalance()
	end)
	H.eq(shown, 6)
	H.eq(before - after, shown, "the tracker shows what the turn start charges")
	H.clean()
end)

test("1.0.4 upkeep text: signed net, one decimal at most, hidden at 0", function()
	BootUI({ tracker = false })
	H.eq(EFV_UI_SignedNumText(12), "+12")
	H.eq(EFV_UI_SignedNumText(-3), "-3")
	H.eq(EFV_UI_SignedNumText(0), "0")
	H.eq(EFV_UI_SignedNumText(-0.04), "0", "rounds to 0: no sign")
	H.eq(EFV_UI_SignedNumText(2.5), "+2.5")
	H.eq(EFV_UI_SignedNumText(12.25), "+12.3")
	H.eq(EFV_UI_SignedNumText(-7.0), "-7")
	H.eq(EFV_UI_SignedNumText(1234), "+1,234")
	H.eq(EFV_UI_SignedNumText(-1234567.5), "-1,234,567.5")
	H.eq(EFV_UI_SignedNumText(999.96), "+1,000")
	H.isnil(EFV_UI_TransitUpkeepText(0, 10), "no upkeep -> no line")
	H.isnil(EFV_UI_TransitUpkeepText(nil, 10))
	H.eq(EFV_UI_TransitUpkeepText(6, 10), Locale.Lookup("LOC_EFV_TRACKER_UPKEEP", 6, "+4"))
	H.eq(EFV_UI_TransitUpkeepText(6, 10), "Transit upkeep: -6 [ICON_Gold] per turn (net +4 [ICON_Gold] per turn)")
	H.eq(EFV_UI_TransitUpkeepText(6, 3), "Transit upkeep: -6 [ICON_Gold] per turn (net -3 [ICON_Gold] per turn)")
	H.eq(EFV_UI_TransitUpkeepText(6, 6), "Transit upkeep: -6 [ICON_Gold] per turn (net 0 [ICON_Gold] per turn)")
	H.eq(EFV_UI_TransitUpkeepText(2, 10.5), "Transit upkeep: -2 [ICON_Gold] per turn (net +8.5 [ICON_Gold] per turn)")
	H.eq(EFV_UI_TransitUpkeepText(6, nil), "Transit upkeep: -6 [ICON_Gold] per turn", "top bar unavailable")
	H.clean()
end)

test("1.0.4 top-bar gold per turn: GetGoldYield - GetTotalMaintenance; nil when unavailable", function()
	BootUI({ tracker = false })
	Players[0].goldYield, Players[0].totalMaintenance = 20.5, 8
	H.eq(EFV_UI_TopBarGoldPerTurn(0), 12.5)
	H.eq(EFV_UI_TopBarGoldPerTurn(1), 0)
	H.isnil(EFV_UI_TopBarGoldPerTurn(99), "no such player")
	H.isnil(EFV_UI_TopBarGoldPerTurn(-1))
	H.clean()
end)

-- ===========================================================================
-- Tracker panel
-- ===========================================================================
test("1.0.4 tracker: the upkeep line renders with the real net, follows the gold per turn, hides at 0", function()
	local S, tr = BootUI()
	local C = tr.Controls
	Players[0].goldYield, Players[0].totalMaintenance = 20, 8         -- top bar +12
	Events.LoadGameViewStateDone()
	LuaEvents.EFV_TrackerOpen()
	H.ok(C.TrackerUpkeep:IsHidden(), "no units in transit: hidden")
	C.TrackerCloseButton:Click()
	local a = MakeRec(S, { state = "OUTBOUND", unitType = "UNIT_SWORDSMAN" })     -- 2
	local b = MakeRec(S, { state = "RETURNING", unitType = "UNIT_KNIGHT" })       -- 4
	MakeRec(S, { state = "OUTBOUND", senderID = 1, recipientID = 0, dest = S.c0, unitType = "UNIT_KNIGHT" }) -- received
	LuaEvents.EFV_TrackerOpen()
	H.ok(not C.TrackerUpkeep:IsHidden(), "shown while units are on their way")
	H.eq(C.TrackerUpkeep:GetText(), "Transit upkeep: -6 [ICON_Gold] per turn (net +6 [ICON_Gold] per turn)")
	H.eq(C.TrackerSummary:GetText(), Locale.Lookup("LOC_EFV_TRACKER_SUMMARY", 2, 1, 0), "summary line unchanged")
	-- the gold per turn changes without any VEF change: the poll picks it up
	Players[0].goldYield = 10                                                   -- top bar +2
	FAKE_UI.Update(tr, 0.6)
	H.eq(C.TrackerUpkeep:GetText(), "Transit upkeep: -6 [ICON_Gold] per turn (net -4 [ICON_Gold] per turn)")
	-- one unit arrives
	SetState(a, "DEPLOYED")
	FAKE_UI.Update(tr, 0.6)
	H.eq(C.TrackerUpkeep:GetText(), "Transit upkeep: -4 [ICON_Gold] per turn (net -2 [ICON_Gold] per turn)")
	-- turn start refresh
	SetState(b, "DEPLOYED")
	Events.PlayerTurnActivated(0, true)
	H.ok(C.TrackerUpkeep:IsHidden(), "nothing of ours in transit: hidden again")
	H.clean()
end)

test("1.0.4 tracker: the upkeep label exists in the panel XML with its tooltip; texts have no dashes", function()
	BootUI({ tracker = false })
	local xml = __py_read("EFV/UI/EFV_Tracker.xml")
	H.ok(string.find(xml, '<Label ID="TrackerUpkeep"[^>]*ToolTip="LOC_EFV_TRACKER_UPKEEP_TT"[^>]*Hidden="1"') ~= nil)
	for _, k in ipairs({ "LOC_EFV_TRACKER_UPKEEP", "LOC_EFV_TRACKER_UPKEEP_ONLY", "LOC_EFV_TRACKER_UPKEEP_TT" }) do
		local t = FAKE_TEXT[k]
		H.ok(type(t) == "string" and t ~= "", k .. " has a text")
		H.isnil(string.find(t, "\226\128\147", 1, true), k .. ": no en dash")
		H.isnil(string.find(t, "\226\128\148", 1, true), k .. ": no em dash")
		H.isnil(string.find(t, "EFV", 1, true), k .. ": the displayed name is VEF")
	end
	H.clean()
end)
