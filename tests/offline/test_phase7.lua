-- @harness native
-- Phase 7 (PLAN 5.7): WP7.2 full tracker panel and WP7.3 text / icon
-- completeness, on the fake engine.
--   * row building (EFV_UI_TrackerRows): sent and received records only,
--     partner "To X" / "From X", force labels, short state labels, turns
--     column, destination / return city for units in transit, sorting
--     (MUTINY, GRACE by id = the D9 banner order; then DEPLOYED, OUTBOUND,
--     RETURNING, fewest turns first, unlimited last);
--   * 0.7.1 column sort: click cycle (asc, desc, default) per column, text
--     and numeric columns, record-id tie-break, header marks, the panel's
--     header buttons (UI-only state, nothing saved);
--   * the panel: launch-bar button (attach once, backing resize, toggle,
--     alert indicator, count tooltip), row highlight, row click (own unit:
--     select + look; partner unit: camera only; in transit: the city),
--     refresh by the (EFV_Rev, turn) poll while open, ESC;
--   * WP7.3: plural forms rendered, the runtime text-argument audit of the
--     fake Locale.Lookup, every notification type has texts and an icon
--     alias, every reason code has a text, the retired key is gone.

local function G(fn, ...) FAKE_UI.AsGameplay(fn, ...) end

local function BootUI(opts)
	opts = opts or {}
	local S = H.baseScenario({ turn = opts.turn or 50 })
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
	FAKE_UI.looked = {}
	UI.LookAtPlot = function(x, y) FAKE_UI.looked[#FAKE_UI.looked + 1] = { "own", x, y } end
	UI.LookAtPlotScreenPosition = function(x, y) FAKE_UI.looked[#FAKE_UI.looked + 1] = { "look", x, y } end
	H.markBody()
	return S, tr
end

-- Creates a record (gameplay side). f: fields over the defaults below; a unit
-- is placed for on-map states (owner = f.owner or the natural owner).
local function MakeRec(S, f)
	local rec, unit
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
			sentTurn = turn - 5, arrivalTurn = f.arrivalTurn or (turn - 3), transitTurns = 2, band = 2, distance = 12,
			deployedTurn = f.deployedTurn, durationTurns = f.durationTurns,
			graceTurnsLeft = f.graceTurnsLeft, lastDamage = f.lastDamage, lapsed = f.lapsed or 0,
			lapseReason = f.lapseReason, spawnFailCount = f.spawnFailCount or 0, feePaid = 100, maintGoldPaid = 0,
			returnCityID = f.returnCityID, returnX = f.returnX, returnY = f.returnY,
		}
		if ft ~= "VOLUNTEER" and fields.durationTurns == nil and state ~= "OUTBOUND" then
			fields.durationTurns = (ft == "CS_EXPEDITIONARY") and 10 or 20
		end
		if state ~= "OUTBOUND" and state ~= "RETURNING" then
			local owner = f.owner or ((ft == "VOLUNTEER") and sender or recipient)
			unit = H.unit(owner, fields.unitType, f.x or (dest.x + 1), f.y or dest.y)
			fields.onMapPlayerID, fields.onMapUnitID = owner, unit.id
			fields.lastX, fields.lastY = unit.x, unit.y
			fields.deployedTurn = fields.deployedTurn or (turn - 3)
		end
		local store = EFV_Records.Load()
		rec = EFV_Records.New(store, fields)
		EFV_Records.Commit(store)
	end)
	return rec.id, unit
end

local function RowIM()
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_TrackerRowInstance" then return im end
	end
end

local function Ids(rows)
	local out = {}
	for _, r in ipairs(rows) do out[#out + 1] = r.id end
	return out
end

-- ===========================================================================
-- WP7.2 row building
-- ===========================================================================
test("tracker rows: sent and received records only; partner To/From; force labels", function()
	local S = BootUI({ tracker = false })
	local a = MakeRec(S, { forceType = "EXPEDITIONARY", senderID = 0, recipientID = 1 })            -- sent
	local b = MakeRec(S, { forceType = "VOLUNTEER", senderID = 0, recipientID = 2 })                -- sent
	local c = MakeRec(S, { forceType = "CS_EXPEDITIONARY", senderID = 0, recipientID = 4, dest = S.c4 })
	local d = MakeRec(S, { forceType = "EXPEDITIONARY", senderID = 1, recipientID = 0, dest = S.c0 }) -- received
	MakeRec(S, { forceType = "EXPEDITIONARY", senderID = 2, recipientID = 1 })                       -- not ours
	local rows = EFV_UI_TrackerRows(0, FAKE.turn)
	H.len(rows, 4, "the record between players 2 and 1 is not listed")
	local byId = {}
	for _, r in ipairs(rows) do byId[r.id] = r end
	H.eq(byId[a].partner, Locale.Lookup("LOC_EFV_TRACKER_TO", EFV_UI_PlayerName(1)))
	H.eq(byId[d].partner, Locale.Lookup("LOC_EFV_TRACKER_FROM", EFV_UI_PlayerName(1)))
	H.ok(byId[a].sent and not byId[d].sent)
	H.eq(byId[a].force, Locale.Lookup("LOC_EFV_FORCE_EXPEDITIONARY"))
	H.eq(byId[b].force, Locale.Lookup("LOC_EFV_FORCE_VOLUNTEER"))
	H.eq(byId[c].force, Locale.Lookup("LOC_EFV_FORCE_CS_EXPEDITIONARY"))
	H.eq(byId[a].unit, EFV_UnitDisplayName("UNIT_SWORDSMAN"))
	H.ok(not byId[a].own, "a lent EXP unit is the recipient's")
	H.ok(byId[b].own, "a Volunteer stays the sender's")
	H.ok(byId[d].own, "a received EXP unit is ours")
	H.len(EFV_UI_TrackerRows(-1), 0, "no local player")
	local sent, received, alerts = EFV_UI_TrackerCounts(0)
	H.eq(sent, 3); H.eq(received, 1); H.eq(alerts, 0)
	H.clean()
end)

test("tracker rows: state labels and turns (Outbound N / Deployed N left / Grace N / Mutiny N / Lapse / Returning N)", function()
	local S = BootUI({ tracker = false })
	local T = FAKE.turn
	local out = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 2 })
	local dep = MakeRec(S, { state = "DEPLOYED", deployedTurn = T - 5 })                   -- 20 - 5 = 15 left
	local exp = MakeRec(S, { state = "DEPLOYED", deployedTurn = T - 20 })                  -- served
	local vol = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2, deployedTurn = T - 4 })
	local gr = MakeRec(S, { state = "GRACE", graceTurnsLeft = 3 })
	local mu = MakeRec(S, { state = "MUTINY", lastDamage = 60 })                          -- ceil(40 / 20) = 2
	local lap = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2, state = "GRACE", graceTurnsLeft = 4,
		lapsed = 1, lapseReason = "WAR" })
	local ret = MakeRec(S, { state = "RETURNING", arrivalTurn = T + 1, returnCityID = S.c0b.id, returnX = S.c0b.x, returnY = S.c0b.y })
	local blk = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T, spawnFailCount = 2 })
	local byId = {}
	for _, r in ipairs(EFV_UI_TrackerRows(0, T)) do byId[r.id] = r end
	local function St(key, ...) return Locale.Lookup(key, ...) end
	H.eq(byId[out].state, St("LOC_EFV_TRACKER_ST_OUTBOUND")); H.eq(byId[out].turns, 2)
	H.eq(byId[dep].state, St("LOC_EFV_TRACKER_ST_DEPLOYED")); H.eq(byId[dep].turns, 15)
	H.eq(byId[exp].state, St("LOC_EFV_TRACKER_ST_EXPIRED")); H.eq(byId[exp].turns, 0)
	H.eq(byId[vol].state, St("LOC_EFV_TRACKER_ST_DEPLOYED")); H.isnil(byId[vol].turns, "Volunteers: unlimited")
	H.eq(byId[vol].turnsText, "-")
	H.eq(byId[gr].state, St("LOC_EFV_TRACKER_ST_GRACE")); H.eq(byId[gr].turns, 3); H.eq(byId[gr].alert, "GRACE")
	H.eq(byId[mu].state, St("LOC_EFV_TRACKER_ST_MUTINY")); H.eq(byId[mu].turns, 2); H.eq(byId[mu].alert, "MUTINY")
	H.eq(byId[lap].state, St("LOC_EFV_TRACKER_ST_LAPSE", St("LOC_EFV_TRACKER_ST_GRACE")))
	H.eq(byId[lap].state, "Lapse: Grace")
	H.eq(byId[ret].state, St("LOC_EFV_TRACKER_ST_RETURNING")); H.eq(byId[ret].turns, 1)
	H.eq(byId[blk].state, St("LOC_EFV_TRACKER_ST_BLOCKED")); H.eq(byId[blk].turns, 0)
	-- the full sentence stays in the tooltip (same text as the flag badge)
	H.ok(string.find(byId[dep].tooltip, Locale.Lookup("LOC_EFV_STATE_DEPLOYED", 15), 1, true) ~= nil)
	H.ok(string.find(byId[dep].tooltip, "Deployed, 15 turns left", 1, true) ~= nil, "plural rendered")
	H.ok(string.find(byId[lap].tooltip, Locale.Lookup("LOC_EFV_LAPSE_WAR"), 1, true) ~= nil, "lapse reason in the tooltip")
	H.clean()
end)

test("tracker rows: in-transit rows show the destination / return city; on-map rows none", function()
	local S = BootUI({ tracker = false })
	local T = FAKE.turn
	local out = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 2, dest = S.c1b })
	local ret = MakeRec(S, { state = "RETURNING", arrivalTurn = T + 1, returnCityID = S.c0b.id, returnX = S.c0b.x, returnY = S.c0b.y })
	local dep = MakeRec(S, {})
	local byId = {}
	for _, r in ipairs(EFV_UI_TrackerRows(0, T)) do byId[r.id] = r end
	H.eq(byId[out].place, EFV_UI_CityName(1, S.c1b.id, S.c1b.x, S.c1b.y))
	H.eq(byId[out].place, "LOC_CITY_B2")
	H.eq(byId[ret].place, "LOC_CITY_A2", "return city (the sender's)")
	H.eq(byId[dep].place, "")
	H.ok(byId[out].transit and byId[ret].transit and not byId[dep].transit)
	H.ok(string.find(byId[out].tooltip, Locale.Lookup("LOC_EFV_TRACKER_TT_TRANSIT", "LOC_CITY_B2"), 1, true) ~= nil)
	H.ok(string.find(byId[dep].tooltip, Locale.Lookup("LOC_EFV_TRACKER_TT_LOOK"), 1, true) ~= nil, "partner's unit")
	H.clean()
end)

test("tracker rows: sort MUTINY, GRACE (by id), DEPLOYED, OUTBOUND, RETURNING; fewest turns first, unlimited last", function()
	local S = BootUI({ tracker = false })
	local T = FAKE.turn
	local ret = MakeRec(S, { state = "RETURNING", arrivalTurn = T + 1, returnCityID = S.c0.id, returnX = S.c0.x, returnY = S.c0.y })
	local vol = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2 })             -- unlimited
	local out2 = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 3 })
	local g2 = MakeRec(S, { state = "GRACE", graceTurnsLeft = 1 })
	local dep15 = MakeRec(S, { deployedTurn = T - 5 })
	local m1 = MakeRec(S, { state = "MUTINY", lastDamage = 20 })
	local out1 = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 1 })
	local g1 = MakeRec(S, { state = "GRACE", graceTurnsLeft = 5 })
	local dep2 = MakeRec(S, { deployedTurn = T - 18 })
	local m2 = MakeRec(S, { state = "MUTINY", lastDamage = 80 })
	H.deq(Ids(EFV_UI_TrackerRows(0, T)), { m1, m2, g2, g1, dep2, dep15, vol, out1, out2, ret },
		"alerts by id (banner order), then groups by turns")
	H.deq(Ids(EFV_UI_TrackerRows(0, T)), Ids(EFV_UI_TrackerRows(0, T)), "deterministic")
	H.clean()
end)

-- ===========================================================================
-- 0.7.1 column sort (EFV_UI_TrackerSortClick / _SortRows / _SortMark)
-- ===========================================================================
test("tracker sort: click cycle per column asc -> desc -> default; another column restarts at asc; marks", function()
	BootUI({ tracker = false })
	H.len(EFV_UI_TRACKER_SORT_COLS, 6, "six sortable columns")
	for col = 1, 6 do
		local s = EFV_UI_TrackerSortClick(nil, col)
		H.deq(s, { col = col, dir = 1 }, "first click: A-Z / ascending")
		H.eq(EFV_UI_TrackerSortMark(s, col), "LOC_EFV_TRACKER_SORT_ASC")
		s = EFV_UI_TrackerSortClick(s, col)
		H.deq(s, { col = col, dir = -1 }, "second click: Z-A / descending")
		H.eq(EFV_UI_TrackerSortMark(s, col), "LOC_EFV_TRACKER_SORT_DESC")
		s = EFV_UI_TrackerSortClick(s, col)
		H.deq(s, { col = nil, dir = 0 }, "third click: default order")
		H.isnil(EFV_UI_TrackerSortMark(s, col), "no arrow on an unsorted column")
		H.deq(EFV_UI_TrackerSortClick(s, col), { col = col, dir = 1 }, "fourth click starts over")
	end
	-- only one column at a time: another column always starts ascending
	local s = EFV_UI_TrackerSortClick(EFV_UI_TrackerSortClick(nil, 2), 2)   -- Partner Z-A
	s = EFV_UI_TrackerSortClick(s, 5)
	H.deq(s, { col = 5, dir = 1 }, "Turns ascending replaces Partner")
	for col = 1, 6 do
		H.eq(EFV_UI_TrackerSortMark(s, col), col == 5 and "LOC_EFV_TRACKER_SORT_ASC" or nil)
	end
	-- 0.7.3 (designer, candidate B): the faded "sortable" pair shows on every
	-- column but the sorted one; the sorted column has its single arrow only.
	for col = 1, 6 do
		H.eq(EFV_UI_TrackerSortHint(nil, col), true, "no sort: sortable mark on column " .. col)
		H.eq(EFV_UI_TrackerSortHint({ col = nil, dir = 0 }, col), true, "default order: sortable mark on column " .. col)
		H.isnil(EFV_UI_TrackerSortMark(nil, col), "no sort: no arrow on column " .. col)
	end
	for sorted = 1, 6 do
		for _, dir in ipairs({ 1, -1 }) do
			local st = { col = sorted, dir = dir }
			local shown = 0
			for col = 1, 6 do
				local hint, mark = EFV_UI_TrackerSortHint(st, col), EFV_UI_TrackerSortMark(st, col)
				if col == sorted then
					H.eq(hint, false, "sorted column " .. col .. ": no sortable mark")
					H.eq(mark, dir == 1 and "LOC_EFV_TRACKER_SORT_ASC" or "LOC_EFV_TRACKER_SORT_DESC", "sorted column: one arrow")
				else
					H.eq(hint, true, "unsorted column " .. col .. " keeps the sortable mark")
					H.isnil(mark, "unsorted column " .. col .. ": no arrow")
				end
				if hint then shown = shown + 1 end
			end
			H.eq(shown, 5, "sortable mark on the five unsorted columns")
		end
	end
	H.deq(EFV_UI_TrackerSortClick(s, 9), s, "unknown column: unchanged")
	for _, key in ipairs({ "LOC_EFV_TRACKER_SORT_ASC", "LOC_EFV_TRACKER_SORT_DESC", "LOC_EFV_TRACKER_SORT_TT" }) do
		H.ne(Locale.Lookup(key), key, key .. " has a text")
	end
	-- 0.7.2: the marks are the base game's arrow font icons (bigger than the
	-- 0.7.1 U+02C6 / U+02C7 glyphs), which exist in Base FontIcons.xml.
	H.eq(Locale.Lookup("LOC_EFV_TRACKER_SORT_ASC"), "[ICON_PressureUp]")
	H.eq(Locale.Lookup("LOC_EFV_TRACKER_SORT_DESC"), "[ICON_PressureDown]")
	-- 0.7.3: each header has its faded PressureUp / PressureDown pair (40% alpha)
	local xml = __py_read("EFV/UI/EFV_Tracker.xml")
	for _, n in ipairs({ "Unit", "Partner", "Force", "State", "Turns", "Dest" }) do
		local hint = string.match(xml, '<Container ID="Sort' .. n .. 'Hint"[^>]*>.-</Container>')
		H.notnil(hint, n .. " header has a sortable mark")
		H.ok(string.find(hint, 'Texture="PressureUp" Color="255,255,255,102"', 1, true) ~= nil and
			string.find(hint, 'Texture="PressureDown" Color="255,255,255,102"', 1, true) ~= nil, n .. ": up + down pair at 40%")
	end
	H.clean()
end)

test("tracker sort: text columns A-Z / Z-A ignore case, ties by record id in both directions; alerts not pinned", function()
	BootUI({ tracker = false })
	local function Row(id, unit, alert) return { id = id, unit = unit, partner = "", force = "", state = "", place = "", alert = alert } end
	-- default order as EFV_UI_TrackerRows builds it: alerts pinned on top
	local rows = { Row(7, "Warrior", "MUTINY"), Row(3, "archer", "GRACE"), Row(9, "Spearman"), Row(2, "Warrior"), Row(5, "Archer") }
	H.eq(EFV_UI_TrackerSortRows(rows, nil), rows, "no sort: the same array")
	H.eq(EFV_UI_TrackerSortRows(rows, { col = nil, dir = 0 }), rows, "default: the same array")
	H.eq(EFV_UI_TrackerSortRows(rows, { col = 1, dir = 0 }), rows, "dir 0: the same array")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, { col = 1, dir = 1 })), { 3, 5, 9, 2, 7 },
		"A-Z; 'archer' = 'Archer' and 'Warrior' x2 ordered by id; the MUTINY row is not pinned")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, { col = 1, dir = -1 })), { 2, 7, 9, 3, 5 }, "Z-A; ties still by ascending id")
	H.deq(Ids(rows), { 7, 3, 9, 2, 5 }, "input array untouched")
	-- every text column reads its own field
	local fields = { "unit", "partner", "force", "state", nil, "place" }
	for col, field in pairs(fields) do
		local a, b = Row(1, ""), Row(2, "")
		a[field], b[field] = "Zulu", "Alpha"
		H.deq(Ids(EFV_UI_TrackerSortRows({ a, b }, { col = col, dir = 1 })), { 2, 1 }, field .. " A-Z")
		H.deq(Ids(EFV_UI_TrackerSortRows({ b, a }, { col = col, dir = -1 })), { 1, 2 }, field .. " Z-A")
	end
	-- empty text (no destination) sorts before any name A-Z
	local p1, p2 = Row(1, ""), Row(2, "")
	p2.place = "Rome"
	H.deq(Ids(EFV_UI_TrackerSortRows({ p2, p1 }, { col = 6, dir = 1 })), { 1, 2 })
	H.clean()
end)

test("tracker sort: Turns column by number (not text); unlimited '-' after every number; ties by id; deterministic", function()
	local S = BootUI({ tracker = false })
	local T = FAKE.turn
	local m = MakeRec(S, { state = "MUTINY", lastDamage = 20 })                  -- 4 turns
	local vol = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2 })         -- unlimited (nil)
	local d15a = MakeRec(S, { deployedTurn = T - 5 })                            -- 15
	local out = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 1 })          -- 1
	local g = MakeRec(S, { state = "GRACE", graceTurnsLeft = 5 })                -- 5
	local d15b = MakeRec(S, { deployedTurn = T - 5 })                            -- 15 (tie)
	local d2 = MakeRec(S, { deployedTurn = T - 18 })                             -- 2 ("2" > "15" as text)
	local rows = EFV_UI_TrackerRows(0, T)
	H.deq(Ids(rows), { m, g, d2, d15a, d15b, vol, out }, "default: alerts on top")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, { col = 5, dir = 1 })), { out, d2, m, g, d15a, d15b, vol },
		"ascending: 1, 2, 4, 5, 15, 15 (by id), unlimited")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, { col = 5, dir = -1 })), { vol, d15a, d15b, g, m, d2, out },
		"descending: unlimited, 15, 15 (still by id), 5, 4, 2, 1")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, { col = 5, dir = 1 })), Ids(EFV_UI_TrackerSortRows(EFV_UI_TrackerRows(0, T), { col = 5, dir = 1 })),
		"deterministic")
	H.deq(Ids(EFV_UI_TrackerSortRows(rows, EFV_UI_TrackerSortClick(EFV_UI_TrackerSortClick(EFV_UI_TrackerSortClick(nil, 5), 5), 5))),
		Ids(rows), "third click: default order again")
	H.clean()
end)

test("tracker panel: header click sorts the rows, marks follow, alerts stay red, third click restores; nothing saved", function()
	local S, tr = BootUI()
	local T = FAKE.turn
	local d15 = MakeRec(S, { deployedTurn = T - 5 })                             -- 15
	local m = MakeRec(S, { state = "MUTINY", lastDamage = 20 })                  -- 4
	local out = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 1 })          -- 1
	local vol = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2 })         -- -
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	local function Mark(key) return Locale.Lookup(key) end
	local function TurnsHeader() return C.SortTurnsLabel:GetText() end
	H.eq(TurnsHeader(), Locale.Lookup("LOC_EFV_TRACKER_COL_TURNS"), "no arrow at load")
	H.eq(C.SortUnitLabel:GetText(), Locale.Lookup("LOC_EFV_TRACKER_COL_UNIT"))
	-- 0.7.3: the faded sortable pair shows on all headers but the sorted one
	local HINTS = { "SortUnitHint", "SortPartnerHint", "SortForceHint", "SortStateHint", "SortTurnsHint", "SortDestHint" }
	local function Hints()
		local out = {}
		for i, id in ipairs(HINTS) do out[i] = not C[id]:IsHidden() end
		return out
	end
	local ALL = { true, true, true, true, true, true }
	local TURNS_SORTED = { true, true, true, true, false, true }
	H.deq(Hints(), ALL, "sortable mark on every header at load")
	C.BannerButton:RClick()
	local function Col()
		local cells = {}
		for _, inst in ipairs(RowIM().list) do
			local t = string.gsub(string.gsub(inst.TurnsLabel:GetText(), "%[COLOR:[^%]]*%]", ""), "%[ENDCOLOR%]", "")
			cells[#cells + 1] = t .. (inst.AlertHighlight:IsHidden() and "" or "!")
		end
		return cells
	end
	H.deq(Col(), { "4!", "15", "-", "1" }, "default: the mutiny row pinned on top")
	C.SortTurnsButton:Click()
	H.deq(Col(), { "1", "4!", "15", "-" }, "ascending; the mutiny row keeps its highlight")
	H.eq(TurnsHeader(), Locale.Lookup("LOC_EFV_TRACKER_COL_TURNS") .. " " .. Mark("LOC_EFV_TRACKER_SORT_ASC"))
	H.deq(Hints(), TURNS_SORTED, "ascending: Turns has the arrow only, the others the sortable mark")
	C.SortTurnsButton:Click()
	H.deq(Col(), { "-", "15", "4!", "1" }, "descending")
	H.eq(TurnsHeader(), Locale.Lookup("LOC_EFV_TRACKER_COL_TURNS") .. " " .. Mark("LOC_EFV_TRACKER_SORT_DESC"))
	H.deq(Hints(), TURNS_SORTED, "descending: Turns has the arrow only")
	C.SortTurnsButton:Click()
	H.deq(Col(), { "4!", "15", "-", "1" }, "third click: default order")
	H.eq(TurnsHeader(), Locale.Lookup("LOC_EFV_TRACKER_COL_TURNS"))
	H.deq(Hints(), ALL, "default order: the sortable mark is back on Turns")
	-- another column: Partner A-Z ("To <civ 1>" x3 by id, "To <civ 2>"), Turns mark back to neutral
	C.SortTurnsButton:Click()
	C.SortPartnerButton:Click()
	H.eq(TurnsHeader(), Locale.Lookup("LOC_EFV_TRACKER_COL_TURNS"), "one column at a time")
	H.eq(C.SortPartnerLabel:GetText(), Locale.Lookup("LOC_EFV_TRACKER_COL_PARTNER") .. " " .. Mark("LOC_EFV_TRACKER_SORT_ASC"))
	H.deq(Hints(), { true, false, true, true, true, true }, "Partner sorted: its mark swapped for the arrow, Turns back to sortable")
	local p1, p2 = Locale.Lookup("LOC_EFV_TRACKER_TO", EFV_UI_PlayerName(1)), Locale.Lookup("LOC_EFV_TRACKER_TO", EFV_UI_PlayerName(2))
	local want = (string.lower(p1) < string.lower(p2)) and { "15", "4!", "1", "-" } or { "-", "15", "4!", "1" }
	H.deq(Col(), want, "partner A-Z, same partner by record id")
	-- the sort survives a rebuild (new record while open) and is never written to the game
	MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 3 })
	local rev = EFV_UI_ReadStore().rev
	FAKE_UI.Update(tr, 1)
	H.len(RowIM().list, 5)
	H.eq(C.SortPartnerLabel:GetText(), Locale.Lookup("LOC_EFV_TRACKER_COL_PARTNER") .. " " .. Mark("LOC_EFV_TRACKER_SORT_ASC"), "kept")
	C.SortPartnerButton:Click()
	H.eq(EFV_UI_ReadStore().rev, rev, "sorting writes nothing to the store")
	H.len(FAKE_UI.requests, 0, "no player operation")
	H.ok(H.hasLine("sort col=2 dir=-1"))
	H.ok(d15 < m and m < out and out < vol, "record ids in creation order")
	H.clean()
end)

-- ===========================================================================
-- WP7.2 panel
-- ===========================================================================
test("tracker panel: launch-bar button attached once into the LaunchBar stack, backing resized, toggles the panel", function()
	local S, tr = BootUI()
	local resized = {}
	LuaEvents.LaunchBar_Resize.Add(function(w) resized[#resized + 1] = w end)
	local stack = tr.ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
	stack:SetSizeX(300)
	Events.LoadGameViewStateDone()
	Events.LoadGameViewStateDone()                   -- double-attach guard
	local built = FAKE_UI.builtInstances or {}
	H.len(built, 2, "LaunchBarItem + LaunchBarPinInstance, once")
	H.eq(built[1].name, "LaunchBarItem"); H.eq(built[2].name, "LaunchBarPinInstance")
	H.eq(built[1].parent, stack)
	H.eq(tr.ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking"):GetSizeX(), 416, "stack + 116")
	H.eq(tr.ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile"):GetSizeX(), 280, "stack - 20")
	H.deq(resized, { 300 }, "LaunchBar_Resize(w) once")
	local btn = built[1].inst.LaunchItemButton
	local C = tr.Controls
	H.ok(C.TrackerPanel:IsHidden())
	btn:Click()
	H.ok(not C.TrackerPanel:IsHidden(), "click opens")
	H.ok(not C.TrackerEmptyLabel:IsHidden(), "no records -> empty label")
	H.ok(tr.ContextPtr.updateHandler ~= nil, "poll installed while open")
	btn:Click()
	H.ok(C.TrackerPanel:IsHidden(), "click closes")
	H.isnil(tr.ContextPtr.updateHandler, "poll removed when closed")
	H.ok(H.hasLine("launch bar button attached"))
	H.clean()
end)

test("tracker panel: alert indicator and count tooltip follow the records; D9 banner unchanged", function()
	local S, tr = BootUI()
	Events.LoadGameViewStateDone()
	local inst = FAKE_UI.builtInstances[1].inst
	H.ok(inst.AlertIndicator:IsHidden(), "no alert")
	local id = MakeRec(S, { state = "GRACE", graceTurnsLeft = 2 })
	MakeRec(S, {})
	Events.PlayerTurnActivated(0, true)
	H.ok(not inst.AlertIndicator:IsHidden(), "alert indicator while a unit must return")
	H.ok(string.find(inst.LaunchItemButton.tooltip, Locale.Lookup("LOC_EFV_TRACKER_SUMMARY", 2, 0, 1), 1, true) ~= nil)
	H.ok(not tr.Controls.AlertBanner:IsHidden(), "D9 banner shown")
	H.eq(tr.Controls.BannerLabel:GetText(), Locale.Lookup("LOC_EFV_BANNER_ALERT", 1, 0))
	H.eq(tr.Controls.BannerLabel:GetText(), "VEF: 1 unit must return - 0 in mutiny", "plural form; displayed name VEF (0.5.2 ruling)")
	G(function()
		local s = EFV_Records.Load()
		EFV_Records.Get(s, id).state = "DEPLOYED"
		EFV_Records.Touch(s); EFV_Records.Commit(s)
	end)
	Events.PlayerTurnActivated(0, true)
	H.ok(inst.AlertIndicator:IsHidden())
	H.ok(tr.Controls.AlertBanner:IsHidden())
	H.clean()
end)

test("tracker panel: rows highlighted for grace / mutiny; summary line; row click selects own unit, looks at a partner's", function()
	local S, tr = BootUI()
	local idOwn, uOwn = MakeRec(S, { forceType = "VOLUNTEER", recipientID = 2 })        -- ours (VOL)
	local idLent, uLent = MakeRec(S, { state = "MUTINY", lastDamage = 40 })             -- recipient's
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	C.BannerButton:RClick()
	local im = RowIM()
	H.len(im.list, 2)
	H.eq(im.list[1].UnitLabel:GetText(), "[COLOR:Red]" .. EFV_UnitDisplayName("UNIT_SWORDSMAN") .. "[ENDCOLOR]", "mutiny row first, red")
	H.ok(not im.list[1].AlertHighlight:IsHidden(), "highlight")
	H.ok(im.list[2].AlertHighlight:IsHidden())
	H.eq(im.list[2].TurnsLabel:GetText(), "-")
	H.eq(im.list[2].PartnerLabel:GetText(), Locale.Lookup("LOC_EFV_TRACKER_TO", EFV_UI_PlayerName(2)))
	H.eq(C.TrackerSummary:GetText(), Locale.Lookup("LOC_EFV_TRACKER_SUMMARY", 2, 0, 1))
	-- partner-owned unit: camera only, no selection
	FAKE_UI.selectedUnit = nil
	im.list[1].RowButton:Click()
	H.deq(FAKE_UI.looked[1], { "look", uLent.x, uLent.y })
	H.isnil(FAKE_UI.selectedUnit, "a partner's unit is never selected")
	H.ok(C.TrackerPanel:IsHidden(), "closes after focusing")
	-- own unit: selected + LookAtPlot
	C.BannerButton:RClick()
	RowIM().list[2].RowButton:Click()
	H.eq(FAKE_UI.selectedUnit, uOwn)
	H.deq(FAKE_UI.looked[2], { "own", uOwn.x, uOwn.y })
	H.clean()
end)

test("tracker panel: in-transit row looks at the destination city; unrevealed city or hidden unit keeps the panel open", function()
	local S, tr = BootUI()
	local T = FAKE.turn
	local idOut = MakeRec(S, { state = "OUTBOUND", arrivalTurn = T + 2, dest = S.c1b })
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	C.BannerButton:RClick()
	local im = RowIM()
	H.eq(im.list[1].PlaceLabel:GetText(), "LOC_CITY_B2")
	im.list[1].RowButton:Click()
	H.deq(FAKE_UI.looked[1], { "look", S.c1b.x, S.c1b.y }, "camera on the destination city")
	H.ok(C.TrackerPanel:IsHidden())
	-- unrevealed destination: nothing to show, panel stays open
	FAKE.unrevealed[0] = { [Map.GetPlot(S.c1b.x, S.c1b.y).index] = true }
	C.BannerButton:RClick()
	RowIM().list[1].RowButton:Click()
	H.len(FAKE_UI.looked, 1, "no camera move")
	H.ok(not C.TrackerPanel:IsHidden(), "panel stays open")
	H.ok(FAKE_UI.KeyTo(tr, Keys.VK_ESCAPE), "ESC closes")
	H.ok(C.TrackerPanel:IsHidden())
	H.ok(not FAKE_UI.KeyTo(tr, Keys.VK_ESCAPE), "ESC passes through while closed")
	H.clean()
end)

test("tracker panel: refreshes on a store revision while open (poll), skips rebuilds while unchanged, and on turn change", function()
	local S, tr = BootUI()
	MakeRec(S, {})
	Events.LoadGameViewStateDone()
	local C = tr.Controls
	C.BannerButton:RClick()
	H.len(RowIM().list, 1)
	local builds = #H.lines("list rows=")
	FAKE_UI.Update(tr, 0.2)                           -- below the poll interval
	FAKE_UI.Update(tr, 1)                             -- poll: nothing changed
	H.len(H.lines("list rows="), builds, "no rebuild while (EFV_Rev, turn) is unchanged")
	MakeRec(S, { state = "GRACE", graceTurnsLeft = 5 })   -- gameplay commit: EFV_Rev + 1
	FAKE_UI.Update(tr, 1)
	H.len(RowIM().list, 2, "new record listed after the poll")
	H.len(H.lines("list rows="), builds + 1)
	H.ok(not C.AlertBanner:IsHidden(), "alerts refreshed with the rebuild")
	-- turn change: the turns column counts down without any store write
	local rows = RowIM().list
	local before = rows[2].TurnsLabel:GetText()
	FAKE.turn = FAKE.turn + 1
	Events.PlayerTurnActivated(0, true)
	H.ne(RowIM().list[2].TurnsLabel:GetText(), before, "turns column follows the turn")
	H.clean()
end)

-- ===========================================================================
-- WP7.3 text and icons
-- ===========================================================================
test("text: plural forms rendered; the fake Locale audit reports a missing argument", function()
	H.baseScenario()
	H.loadEFV()
	H.eq(Locale.Lookup("LOC_EFV_STATE_GRACE", 1), "Must return: mutiny in 1 turn")
	H.eq(Locale.Lookup("LOC_EFV_STATE_GRACE", 3), "Must return: mutiny in 3 turns")
	H.eq(Locale.Lookup("LOC_EFV_DURATION_TURNS", 1), "1 turn")
	H.eq(Locale.Lookup("LOC_EFV_TRACKER_SUMMARY", 3, 1, 0), "Sent: 3   Received: 1   Must return: 0")
	H.len(FAKE.textArgErrors, 0)
	Locale.Lookup("LOC_EFV_CONFIRM_SEND", "unit", "city")   -- 7 placeholders, 2 args
	H.ok(#FAKE.textArgErrors >= 1, "missing arguments recorded")
	H.ok(string.find(FAKE.textArgErrors[1], "LOC_EFV_CONFIRM_SEND", 1, true) ~= nil)
	-- the audit would fail this test through FAKE.handlerErrors: clear the planted error
	FAKE.textArgErrors = {}
	FAKE.handlerErrors = {}
end)

test("text / icons: every notification type has texts and an ICON_ alias; every reason code has a text; retired key gone", function()
	H.baseScenario()
	H.loadEFV()
	local icons = __py_read("EFV/Data/EFV_Icons.sql")
	local sql = __py_read("EFV/Data/EFV_Notifications.sql")
	local n = 0
	for _, name in ipairs(EFV_SortedKeys(EFV_Config.NOTIF)) do
		local t = EFV_Config.NOTIF[name]
		n = n + 1
		H.notnil(FAKE_TEXT["LOC_" .. t .. "_MESSAGE"], t .. " _MESSAGE")
		H.notnil(FAKE_TEXT["LOC_" .. t .. "_SUMMARY"], t .. " _SUMMARY")
		H.ok(string.find(icons, "'ICON_" .. t .. "'", 1, true) ~= nil, t .. " icon alias")
		H.ok(string.find(sql, "('" .. t .. "',", 1, true) ~= nil, t .. " Notifications row")
	end
	H.eq(n, 19, "19 notification types (LAPSE_PAUSED added in 0.5.1)")
	for _, code in ipairs(EFV_Rules.ALL_REASON_CODES) do
		H.notnil(FAKE_TEXT["LOC_EFV_REASON_" .. code], code)
	end
	H.isnil(FAKE_TEXT["LOC_EFV_REASON_RECALL_DAMAGED"], "retired (designer answer: recall needs no full HP)")
	for _, k in ipairs({ "LOC_EFV_TRACKER_COL_UNIT", "LOC_EFV_TRACKER_COL_PARTNER", "LOC_EFV_TRACKER_COL_FORCE",
			"LOC_EFV_TRACKER_COL_STATE", "LOC_EFV_TRACKER_COL_TURNS", "LOC_EFV_TRACKER_COL_DEST" }) do
		H.notnil(FAKE_TEXT[k], k)
		H.ok(string.find(__py_read("EFV/UI/EFV_Tracker.xml"), '"' .. k .. '"', 1, true) ~= nil, k .. " used by the header row")
	end
end)
