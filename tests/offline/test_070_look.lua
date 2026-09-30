-- @harness native
-- 0.7 WP4 (FIXPLAN_0.7 items 5, 6, 13 hooks): tracker look and the two dev
-- hooks, on the fake engine.
--   * item 6: the paused lapse state reads "Lapse: Grace 5 (paused)" in full;
--     every State text EFV_UI_TrackerState can produce and every Force label
--     fits its column (8 px per character, a conservative FontNormal14 bound,
--     against the row label's TruncateWidth in EFV_Tracker.xml);
--   * item 5: header and row columns have the same widths; header labels and
--     TrackerSummary use BodyTextDark14 (dark on the light panel body), the
--     summary sits 33 px above the bottom edge (0.7.1: 3 px higher);
--   * item 13: LuaEvents.EFV_TrackerOpen opens the tracker (never toggles);
--     LuaEvents.EFV_EntrustExpand expands the Entrust picker once (no-op when
--     expanded, disabled or with no capture popup).

local PX_PER_CHAR = 8

local function BootUI(loadTracker)
	local S = H.baseScenario({ turn = 50 })
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local tr = nil
	if loadTracker then
		tr = FAKE_UI.LoadContext("EFV/UI/EFV_Tracker.lua")
	else
		include("EFV_UIShared")
	end
	H.markBody()
	return S, tr
end

local function Strip(s)
	s = string.gsub(s, "%[COLOR:[^%]]*%]", "")
	s = string.gsub(s, "%[ENDCOLOR%]", "")
	return s
end

-- Tracker XML: the row instance's columns { id, width, truncate } in order,
-- and the header's columns { key, width, style } in order.
local function Columns()
	local xml = __py_read("EFV/UI/EFV_Tracker.xml")
	local header = string.match(xml, '<Stack ID="TrackerHeader".-</Stack>%s*<ScrollPanel')
	local row = string.match(xml, '<Instance Name="EFV_TrackerRowInstance">.-</Instance>')
	local hcols, rcols = {}, {}
	-- 0.7.1: each header column is a click target (Button) holding its label.
	for w, style, key in string.gmatch(header, '<Button ID="Sort%w+Button" Size="(%d+),%d+"[^>]*>%s*<Stack ID="Sort%w+Stack"[^>]*>%s*<Label [^>]-Style="([%w_]+)"[^>]-String="LOC_EFV_TRACKER_COL_(%u+)"') do
		hcols[#hcols + 1] = { key = key, width = tonumber(w), style = style }
	end
	for w, id, tw in string.gmatch(row, '<Container Size="(%d+),%d+"><Label ID="(%w+)"[^>]-TruncateWidth="(%d+)"') do
		rcols[#rcols + 1] = { id = id, width = tonumber(w), truncate = tonumber(tw) }
	end
	return xml, hcols, rcols
end

local function RowCol(rcols, id)
	for _, c in ipairs(rcols) do
		if c.id == id then return c end
	end
end

local function Fits(text, col, what)
	text = Strip(text)
	H.ok(#text * PX_PER_CHAR <= col.truncate,
		string.format("%s %q (%d chars) fits %s TruncateWidth %d", what, text, #text, col.id, col.truncate))
	H.ok(not string.find(text, "LOC_", 1, true) and not string.find(text, "{", 1, true), "resolved: " .. text)
end

-- ===========================================================================
-- Item 6: lapse text and column widths
-- ===========================================================================
test("look: paused GRACE lapse with 5 turns reads exactly 'Lapse: Grace 5 (paused)'", function()
	BootUI(false)
	local rec = { state = "GRACE", forceType = "VOLUNTEER", lapsed = 1, lapsePaused = 1, graceTurnsLeft = 5,
		senderID = 0, recipientID = 1 }
	H.eq(EFV_UI_TrackerState(rec, FAKE.turn), "Lapse: Grace 5 (paused)")
	H.clean()
end)

test("look: every State text and Force label fits its tracker column (8 px per character)", function()
	BootUI(false)
	local _, _, rcols = Columns()
	local stateCol, forceCol = RowCol(rcols, "StateLabel"), RowCol(rcols, "ForceLabel")
	H.notnil(stateCol, "StateLabel column"); H.notnil(forceCol, "ForceLabel column")
	local turn = FAKE.turn
	local base = { senderID = 0, recipientID = 1, destX = 1, destY = 1, returnX = 1, returnY = 1 }
	local function R(f)
		local r = {}
		for k, v in pairs(base) do r[k] = v end
		for k, v in pairs(f) do r[k] = v end
		return r
	end
	local recs = {
		R({ state = "OUTBOUND", forceType = "EXPEDITIONARY", arrivalTurn = turn + 2 }),
		R({ state = "OUTBOUND", forceType = "EXPEDITIONARY", arrivalTurn = turn, spawnFailCount = 1 }),   -- Blocked
		R({ state = "RETURNING", forceType = "VOLUNTEER", arrivalTurn = turn + 1 }),
		R({ state = "DEPLOYED", forceType = "EXPEDITIONARY", deployedTurn = turn - 3, durationTurns = 20 }),
		R({ state = "DEPLOYED", forceType = "CS_EXPEDITIONARY", deployedTurn = turn - 10, durationTurns = 10 }), -- Service ended
		R({ state = "DEPLOYED", forceType = "VOLUNTEER", deployedTurn = turn - 3 }),
	}
	for _, ft in ipairs({ "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY" }) do
		for n = 0, 99 do
			recs[#recs + 1] = R({ state = "GRACE", forceType = ft, graceTurnsLeft = n })
		end
		for d = 0, 99, 10 do
			recs[#recs + 1] = R({ state = "MUTINY", forceType = ft, lastDamage = d })
		end
	end
	-- Lapsed Volunteers: unpaused and paused, Grace counts up to 2 digits;
	-- a Mutiny count is at most ceil(100 / MUTINY_DAMAGE_PER_TURN) = 5.
	for n = 0, 99 do
		recs[#recs + 1] = R({ state = "GRACE", forceType = "VOLUNTEER", lapsed = 1, graceTurnsLeft = n })
		recs[#recs + 1] = R({ state = "GRACE", forceType = "VOLUNTEER", lapsed = 1, lapsePaused = 1, graceTurnsLeft = n })
	end
	for d = 0, 99 do
		recs[#recs + 1] = R({ state = "MUTINY", forceType = "VOLUNTEER", lapsed = 1, lastDamage = d })
		recs[#recs + 1] = R({ state = "MUTINY", forceType = "VOLUNTEER", lapsed = 1, lapsePaused = 1, lastDamage = d })
	end
	local seen = {}
	for _, rec in ipairs(recs) do
		-- the sender's labels and the recipient's (Inbound / Departed)
		for _, viewer in ipairs({ rec.senderID, rec.recipientID }) do
			local text = EFV_UI_TrackerState(rec, turn, viewer)
			if not seen[text] then
				seen[text] = true
				Fits(text, stateCol, "state")
			end
		end
	end
	H.ok(seen["Lapse: Grace 5 (paused)"] and seen["Lapse: Mutiny 5 (paused)"] and seen["Service ended"]
		and seen["Blocked"] and seen["Inbound"] and seen["Departed"], "all state kinds rendered")
	for _, ft in ipairs({ "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY" }) do
		Fits(Locale.Lookup(EFV_ForceLabelKey(ft)), forceCol, "force")
	end
	H.eq(Locale.Lookup("LOC_EFV_FORCE_CS_EXPEDITIONARY"), "City-State Expeditionary")
	H.clean()
end)

-- ===========================================================================
-- Item 5: header / footer look, matching columns
-- ===========================================================================
-- 0.7.3 (designer, candidate B): each header label plus its mark fits its
-- column. Label widths are Myriad Pro Semibold-MOD 14 (BodyTextDark14)
-- advances measured with the font of workshop/ui_icons/make_sort_icons.py,
-- plus a 2 px glow / rounding margin. Unsorted: label + stack padding + the
-- 30 px faded pair; sorted: label + space (3 px) + 22 px arrow font icon.
-- Both end at least 2 px before the next column starts.
local LABEL_PX = { UNIT = 26, PARTNER = 45, FORCE = 33, STATE = 31, TURNS = 34, DEST = 72 }
local LABEL_EN = { UNIT = "Unit", PARTNER = "Partner", FORCE = "Force", STATE = "State", TURNS = "Turns", DEST = "Destination" }
local HEADER_ID = { UNIT = "Unit", PARTNER = "Partner", FORCE = "Force", STATE = "State", TURNS = "Turns", DEST = "Dest" }
local GLOW_PX, SPACE_PX, ARROW_PX, GAP_PX = 2, 3, 22, 2

test("look: every header label plus its sort mark (sortable pair or arrow) fits its column", function()
	BootUI(false)
	local xml, hcols = Columns()
	H.len(hcols, 6)
	for _, c in ipairs(hcols) do
		H.eq(Locale.Lookup("LOC_EFV_TRACKER_COL_" .. c.key), LABEL_EN[c.key], c.key .. ": the label the widths were measured for")
		local n = HEADER_ID[c.key]
		local pad = tonumber(string.match(xml, '<Stack ID="Sort' .. n .. 'Stack"[^>]-Padding="(%d+)"'))
		local hintW = tonumber(string.match(xml, '<Container ID="Sort' .. n .. 'Hint"[^>]-Size="(%d+),'))
		H.notnil(pad, n .. " stack padding"); H.notnil(hintW, n .. " hint width")
		local label = LABEL_PX[c.key] + GLOW_PX
		local unsorted = label + pad + hintW
		local sorted = label + SPACE_PX + ARROW_PX
		H.ok(unsorted + GAP_PX <= c.width, string.format("%s unsorted: %d + %d + %d (+%d gap) <= %d",
			c.key, label, pad, hintW, GAP_PX, c.width))
		H.ok(sorted + GAP_PX <= c.width, string.format("%s sorted: %d + %d + %d (+%d gap) <= %d",
			c.key, label, SPACE_PX, ARROW_PX, GAP_PX, c.width))
	end
	-- the hint pair: two 16 px textures overlapping by 2 px = 30 px
	local hint = string.match(xml, '<Container ID="SortTurnsHint"[^>]*>.-</Container>')
	H.ok(string.find(hint, '<Image Size="16,17" Texture="PressureUp"', 1, true) ~= nil and
		string.find(hint, '<Image Offset="14,0" Size="16,17" Texture="PressureDown"', 1, true) ~= nil, hint)
	-- the header row ends before the scroll bar (panel 960 wide)
	local total = 0
	for _, c in ipairs(hcols) do total = total + c.width end
	local scrollW = tonumber(string.match(xml, '<ScrollPanel ID="TrackerScroll"[^>]-Size="(%d+),'))
	local panelW = tonumber(string.match(xml, '<Container ID="TrackerPanel"[^>]-Size="(%d+),'))
	H.eq(panelW, 960, "panel width unchanged")
	H.ok(6 + total <= scrollW - 11, string.format("header ends at %d, scroll bar starts at %d", 6 + total, scrollW - 11))
	H.clean()
end)

test("look: header columns match the row columns; dark header and summary, summary 33 px up", function()
	BootUI(false)
	local xml, hcols, rcols = Columns()
	H.len(hcols, 6, "six header columns")
	H.len(rcols, 6, "six row columns")
	local order = { "UNIT", "PARTNER", "FORCE", "STATE", "TURNS", "DEST" }
	local total = 0
	for i = 1, 6 do
		H.eq(hcols[i].key, order[i])
		-- 0.7.3: header and row columns line up again (the 0.7.2 Turns shift
		-- is gone; Turns is wide enough for its label plus the mark).
		H.eq(hcols[i].width, rcols[i].width, order[i] .. " header width = row width")
		H.eq(hcols[i].style, "BodyTextDark14", order[i] .. " header style")
		H.eq(rcols[i].truncate, rcols[i].width - 6, rcols[i].id .. " TruncateWidth = width - 6")
		total = total + rcols[i].width
	end
	local rowW = tonumber(string.match(xml, '<GridButton ID="RowButton" Size="(%d+),'))
	H.eq(rowW, total + 6, "row width = columns + 6 padding")
	local scrollW = tonumber(string.match(xml, '<ScrollPanel ID="TrackerScroll"[^>]-Size="(%d+),'))
	local panelW = tonumber(string.match(xml, '<Container ID="TrackerPanel"[^>]-Size="(%d+),'))
	H.ok(rowW < scrollW and scrollW < panelW and panelW <= 1280, string.format("row %d < scroll %d < panel %d", rowW, scrollW, panelW))
	local summary = string.match(xml, '<Label ID="TrackerSummary"[^>]*/>')
	H.notnil(summary)
	H.ok(string.find(summary, 'Style="BodyTextDark14"', 1, true) ~= nil, summary)
	H.ok(string.find(summary, 'Offset="22,33"', 1, true) ~= nil, summary)
	H.ok(string.find(summary, "Color=", 1, true) == nil, "no light colour override: " .. summary)
	for _ in string.gmatch(string.match(xml, '<Stack ID="TrackerHeader".-</Stack>%s*<ScrollPanel'), '<Label [^>]-Color=') do
		H.ok(false, "header label with a Color override")
	end
	-- The scroll area ends above the summary line (window 500 high).
	local sy, sh = string.match(xml, '<ScrollPanel ID="TrackerScroll"[^>]-Offset="%d+,(%d+)" Size="%d+,(%d+)"')
	H.ok(tonumber(sy) + tonumber(sh) <= 500 - 33 - 24, "scroll bottom " .. (tonumber(sy) + tonumber(sh)))
	H.clean()
end)

-- ===========================================================================
-- Item 13 hooks
-- ===========================================================================
test("hooks: LuaEvents.EFV_TrackerOpen opens the tracker; a second call keeps it open", function()
	local _, tr = BootUI(true)
	local C = tr.Controls
	H.ok(C.TrackerPanel:IsHidden())
	LuaEvents.EFV_TrackerOpen()
	H.ok(not C.TrackerPanel:IsHidden(), "opened")
	H.ok(tr.ContextPtr.updateHandler ~= nil, "poll running")
	LuaEvents.EFV_TrackerOpen()
	H.ok(not C.TrackerPanel:IsHidden(), "still open (never toggles)")
	H.clean()
end)

local function Capture(oldOwner, city)
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, 0, CityTransferTypes.BY_COMBAT)
	GameEvents.CityConquered(0, oldOwner, oldID, x, y)
end

local function EntrustUI()
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

test("hooks: LuaEvents.EFV_EntrustExpand expands the picker once; no-op before a popup and when expanded", function()
	local S = H.baseScenario()
	H.loadEFV()
	Capture(3, S.c3)
	local env = EntrustUI()
	local C = env.Controls
	LuaEvents.EFV_EntrustExpand()                       -- no capture popup yet
	H.len(Rows(), 0, "nothing built before the popup")
	OpenPopup(S.c3)
	H.ok(C.EFV_RecipientStack:IsHidden())
	LuaEvents.EFV_EntrustExpand()
	H.ok(not C.EFV_RecipientStack:IsHidden(), "expanded")
	H.len(Rows(), 2)
	LuaEvents.EFV_EntrustExpand()
	H.ok(not C.EFV_RecipientStack:IsHidden(), "still expanded (never toggles)")
	H.len(FAKE_UI.requests, 0, "nothing sent")
	H.clean()
end)

test("hooks: LuaEvents.EFV_EntrustExpand does nothing on a disabled Entrust button", function()
	H.baseScenario()
	-- a living major that only the human fights (a city-state's city would
	-- be open to any partner since the 2026-09-30 ruling)
	FAKE.NewPlayer(5, { gold = 0 })
	local c5 = H.city(5, 60, 12, { capital = true, name = "LOC_CITY_E" })
	H.city(5, 64, 16, { name = "LOC_CITY_E2" })
	H.war(0, 5)
	H.loadEFV()
	Capture(5, c5)
	local env = EntrustUI()
	OpenPopup(c5)
	H.ok(env.Controls.EntrustMainButton:IsDisabled())
	LuaEvents.EFV_EntrustExpand()
	H.ok(env.Controls.EFV_RecipientStack:IsHidden(), "stays closed")
	H.len(Rows(), 0)
	H.clean()
end)
