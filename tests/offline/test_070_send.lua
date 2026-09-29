-- @harness native
-- 0.7.0-dev WP1 (FIXPLAN_0.7.md items 1, 2, 12; INTERFACES note 33):
--   item 1  picker: one formatted line per row (EFV_UI_PickerRowText), the
--           header line (EFV_UI_PickerHeaderText), no LOC_ or dash left;
--   item 2  unit action icons: the five VEF icons are distinct and none is
--           an icon the base game shows on combat units;
--   item 12 send from the recipient's land (designer ruling): B's land ->
--           only B's cities (WRONG_TERRITORY names B), city-state land ->
--           only that city-state, neutral land -> NOT_OWN_TERRITORY, enemy
--           land -> every row WRONG_TERRITORY, tracked Volunteer ->
--           ALREADY_TRACKED; gameplay accepts B, rejects a forged send to F;
--   moved from test_phase4.lua: the "Send to City-State" button and picker.
-- Scenario (H.baseScenario, renamed so texts read like the game): 0 human
-- (cities (10,10), (14,20)), 1 ally B "Rome" (Roma (22,10), Antium (18,13)),
-- 2 friend F "Kongo" (Mbanza Kongo (40,30)), 3 enemy C (70,40), 4
-- city-state "Kumasi" (Kumasi (30,20)); optional second city-state 5
-- "Armagh" (Armagh (50,20)).

local EXP, VOL, CS = "EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"
local FEE_EXP = { 0, 36, 72, 108 }   -- Swordsman, Standard speed (0.5.2 fee ruling)
local EM, EN = "\226\128\148", "\226\128\147"

local function Scenario(opts)
	opts = opts or {}
	local wopts = {}
	if opts.secondCS then
		wopts.players = {
			{ id = 0, human = true, gold = 1000 }, { id = 1, gold = 1000 }, { id = 2, gold = 1000 },
			{ id = 3, gold = 1000 }, { id = 4, kind = "CITY_STATE", gold = 0 },
			{ id = 5, kind = "CITY_STATE", gold = 0 },
			{ id = 62, kind = "FREE_CITIES" }, { id = 63, kind = "BARBARIAN" },
		}
	end
	local S = H.baseScenario(wopts)
	Players[0].civ = "England"; Players[1].civ = "Rome"; Players[2].civ = "Kongo"; Players[4].civ = "Kumasi"
	S.c0.name = "London"; S.c0b.name = "York"
	S.c1.name = "Roma"; S.c1b.name = "Antium"; S.c2.name = "Mbanza Kongo"; S.c4.name = "Kumasi"
	if opts.secondCS then
		Players[5].civ = "Armagh"
		S.c5 = H.city(5, 50, 20, { capital = true, name = "Armagh" })
		H.meet(0, 5); H.war(3, 5)
	end
	return S
end

local function Boot(opts)
	local S = Scenario(opts)
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local ctx = {}
	ctx.actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	ctx.picker = FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	H.markBody()
	return S, ctx
end

local function IM(name)
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == name then return im end
	end
end
local function Select(ctx, u)
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(u and u:GetOwner() or -1, u and u:GetID() or -1, 0, 0, 0, true, false)
	FAKE_UI.Frame(ctx.actions)
end
local function Button(icon)
	for _, b in ipairs(IM("EFV_ActionInstance").list) do
		if b.UnitActionIcon.icon == icon then return b end
	end
end
local EXP_ICON, VOL_ICON, CS_ICON = "ICON_UNITCOMMAND_GIFT", "ICON_UNITOPERATION_DEPLOY", "ICON_UNITOPERATION_TELEPORT_TO_CITY"
local function Rows() return IM("EFV_DestRowInstance").list end
local function RowFor(city)
	for _, r in ipairs(Rows()) do
		if string.find(r.RowLabel.text, " - " .. EFV_CityName(city) .. " - ", 1, true) then return r end
	end
end
local function RowsTo(rows, pid)
	local out = {}
	for _, r in ipairs(rows) do
		if r.recipientID == pid then out[#out + 1] = r end
	end
	return out
end
local function Summary(n) return n.data[ParameterTypes.SUMMARY] end
local function Line(parts) return table.concat(parts, " - ") end
local function NoLocNoDash(s, what)
	H.ok(not string.find(s, "LOC_", 1, true), what .. " has an unresolved key: " .. s)
	H.ok(not string.find(s, EM, 1, true) and not string.find(s, EN, 1, true), what .. " has a dash: " .. s)
end

-- ===========================================================================
-- Item 1: row and header text
-- ===========================================================================
test("item 1: EFV_UI_PickerRowText formats one line per row (EXP, band 1, VOL, CS, no calc)", function()
	local S = Boot({ secondCS = true })
	local function Row(pid, city, calc)
		return { recipientID = pid, cityID = city.id, destX = city.x, destY = city.y, calc = calc }
	end
	H.eq(EFV_UI_PickerRowText(Row(1, S.c1, { distance = 34, transit = 4, fee = 108, duration = 20 }), EXP),
		"Rome - Roma - 34 tiles - 4 turns - 108 [ICON_Gold] - 20 turns")
	H.eq(EFV_UI_PickerRowText(Row(1, S.c1, { distance = 1, transit = 1, fee = 0, duration = 20 }), EXP),
		"Rome - Roma - 1 tile - 1 turn - Free - 20 turns", "band 1: singular words, Free")
	H.eq(EFV_UI_PickerRowText(Row(1, S.c1b, { distance = 8, transit = 1, fee = 45, duration = nil }), VOL),
		"Rome - Antium - 8 tiles - 1 turn - 45 [ICON_Gold] - Unlimited", "Volunteers serve without limit")
	H.eq(EFV_UI_PickerRowText(Row(5, S.c5, { distance = 11, transit = 2, fee = 36, duration = 10 }), CS),
		"Armagh - 11 tiles - 2 turns - 36 [ICON_Gold] - 10 turns", "city-state name not repeated")
	local obuasi = H.city(4, 34, 24, { name = "Obuasi", radius = 1 })
	H.eq(EFV_UI_PickerRowText(Row(4, obuasi, { distance = 20, transit = 2, fee = 36, duration = 10 }), CS),
		"Kumasi - Obuasi - 20 tiles - 2 turns - 36 [ICON_Gold] - 10 turns", "a second, differently named city stays")
	H.eq(EFV_UI_PickerRowText(Row(1, S.c1, nil), EXP), "Rome - Roma - 20 turns", "no calc: service only")
	H.eq(EFV_UI_PickerRowText(Row(1, S.c1, nil), VOL), "Rome - Roma - Unlimited")
	H.eq(EFV_UI_PickerRowText(Row(4, S.c4, nil), CS), "Kumasi - 10 turns")
	H.eq(EFV_UI_PickerRowText(nil, EXP), "")
	H.isnil(EFV_UI_FeeCell, "EFV_UI_FeeCell removed")
	H.clean()
end)

test("item 1: EFV_UI_PickerHeaderText per force type", function()
	Boot()
	H.eq(EFV_UI_PickerHeaderText(EXP), "Partner - City - Distance - Travel time - Fee - Service")
	H.eq(EFV_UI_PickerHeaderText(VOL), "Partner - City - Distance - Travel time - Fee - Service")
	H.eq(EFV_UI_PickerHeaderText(CS), "City-state - Distance - Travel time - Fee - Service")
	H.clean()
end)

test("item 1: picker end to end: HeaderLabel, one RowLabel per row, no LOC_ and no dashes, note hidden on own land", function()
	local S, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Select(ctx, u)
	Button(EXP_ICON).UnitActionButton:Click()
	local P = ctx.picker.Controls
	H.ok(not P.PickerRoot:IsHidden(), "picker open")
	H.eq(P.HeaderLabel.text, EFV_UI_PickerHeaderText(EXP))
	H.ok(P.LandNote:IsHidden(), "no land note on your own land")
	local rows = Rows()
	H.len(rows, 3, "Roma, Antium, Mbanza Kongo")
	local d = H.dist(S.c0, S.c1)
	H.eq(d, 12)
	H.eq(RowFor(S.c1).RowLabel.text, Line({ "Rome", "Roma", "12 tiles", "2 turns", "36 [ICON_Gold]", "20 turns" }))
	for _, r in ipairs(rows) do
		NoLocNoDash(r.RowLabel.text, "row")
		H.ok(not r.RowButton.disabled, r.RowLabel.text)
	end
	NoLocNoDash(P.HeaderLabel.text, "header")
	-- Volunteers: rows end in "Unlimited"; City-State: header without City.
	LuaEvents.EFV_OpenDestinationPicker(0, u:GetID(), VOL)
	H.ok(string.find(RowFor(S.c1).RowLabel.text, " - Unlimited", 1, true), RowFor(S.c1).RowLabel.text)
	LuaEvents.EFV_OpenDestinationPicker(0, u:GetID(), CS)
	H.eq(P.HeaderLabel.text, EFV_UI_PickerHeaderText(CS))
	local band, dcs = EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y)
	H.len(Rows(), 1)
	H.eq(Rows()[1].RowLabel.text, Line({ "Kumasi", dcs .. " tiles", band .. " turns", FEE_EXP[band] .. " [ICON_Gold]", "10 turns" }))
	H.clean()
end)

-- ===========================================================================
-- Item 2: unit action icons
-- ===========================================================================
local BASE_COMBAT_ICONS = {
	"MOVE_TO", "MOVE_TO_UNIT", "SKIP_TURN", "SLEEP", "FORTIFY", "ALERT", "HEAL", "DELETE", "PILLAGE",
	"PILLAGE_ROUTE", "RANGE_ATTACK", "COASTAL_RAID", "SWAP_UNITS", "EMBARK", "DISEMBARK", "WAIT_FOR",
	"AIRLIFT", "PROMOTE", "UPGRADE", "FORM_CORPS", "FORM_ARMY", "ENTER_FORMATION", "EXIT_FORMATION",
	"NAME_UNIT", "WAKE", "CANCEL", "AUTOMATE", "AUTO_EXPLORE", "STOP_AUTOMATION", "RETRAIN", "WMD_STRIKE",
	"BUILD_ROUTE", "REPAIR", "REPAIR_ROUTE", "CLEAR_CONTAMINATION",
}

test("item 2: the five VEF icons are distinct and none is a base combat-unit icon", function()
	local src = __py_read("EFV/UI/EFV_UnitActions.lua")
	local icons = {}
	for icon in string.gmatch(src, 'icon = "(ICON_[A-Z_]+)"') do icons[#icons + 1] = icon end
	icons[#icons + 1] = string.match(src, 'local RECALL_ICON = "(ICON_[A-Z_]+)"')
	icons[#icons + 1] = string.match(src, 'local STATUS_ICON = "(ICON_[A-Z_]+)"')
	H.len(icons, 5, "3 send + recall + status")
	local banned = {}
	for _, n in ipairs(BASE_COMBAT_ICONS) do banned[n] = true end
	local seen = {}
	for _, icon in ipairs(icons) do
		H.ok(not seen[icon], "duplicate icon " .. icon)
		seen[icon] = true
		local suffix = string.match(icon, "^ICON_UNITOPERATION_(.+)$") or string.match(icon, "^ICON_UNITCOMMAND_(.+)$")
		H.notnil(suffix, "unit action atlas icon " .. icon)
		H.ok(not banned[suffix], icon .. " is shown on base combat units")
	end
	H.ok(seen[CS_ICON], "Send to City-State uses Teleport to City")
	H.ok(seen["ICON_UNITOPERATION_SPY_LISTENING_POST"], "status uses the Listening Post")
end)

-- ===========================================================================
-- Moved from test_phase4.lua (WP1 / WP2): "Send to City-State" UI
-- ===========================================================================
local function MyUnit()
	return H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY" }, xp = 20 })
end

test("UI: Send to City-State button -> picker row (duration 10, EXP fee) -> flat EFV_Send accepted", function()
	local S, ctx = Boot()
	Select(ctx, MyUnit())
	local b = Button(CS_ICON)
	H.notnil(b, "CS button released (FLAG_RELEASED.CS_EXPEDITIONARY)")
	H.ok(not b.UnitActionButton.disabled)
	b.UnitActionButton:Click()
	H.ok(not ctx.picker.Controls.PickerRoot:IsHidden(), "picker opened")
	local rows = Rows()
	H.len(rows, 1, "the met city-state's city only")
	local band, d = EFV_Band(S.c0.x, S.c0.y, S.c4.x, S.c4.y)
	H.ok(FEE_EXP[band] > 0)
	H.eq(rows[1].RowLabel.text, Line({ "Kumasi", d .. " tiles", EFV_UI_DurationText(band),
		FEE_EXP[band] .. " [ICON_Gold]", EFV_UI_DurationText(10) }))
	H.ok(not rows[1].RowButton.disabled)
	rows[1].RowButton:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.notnil(popup)
	H.ok(string.find(popup.texts[1], Locale.Lookup("LOC_EFV_FORCE_CS_EXPEDITIONARY"), 1, true), popup.texts[1])
	H.ok(not string.find(popup.texts[1], "{", 1, true), popup.texts[1])
	popup.confirm()
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	H.eq(req.params.forceType, CS); H.eq(req.params.recipientID, 4); H.eq(req.params.expectedFee, FEE_EXP[band])
	FAKE_UI.AsGameplay(function() H.request(req.pid, req.params) end)
	local recs = H.records()
	H.len(recs, 1)
	H.eq(recs[1].forceType, CS); H.eq(recs[1].feePaid, FEE_EXP[band], "shown fee == charged fee")
	H.clean()
end)

test("UI: CS button disabled with the war reason when no met city-state shares a war", function()
	local _, ctx = Boot()
	H.peace(3, 4)
	Select(ctx, MyUnit())
	local b = Button(CS_ICON)
	H.notnil(b)
	H.ok(b.UnitActionButton.disabled)
	H.ok(string.find(b.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_REASON_NO_COMMON_WAR", EFV_UI_PlayerName(4)), 1, true),
		b.UnitActionButton.tooltip)
	H.clean()
end)

-- ===========================================================================
-- Item 12: send from the recipient's land
-- ===========================================================================
local function HasCode(row, code)
	for _, c in ipairs(row.reasons or {}) do
		if c == code then return true end
	end
	return false
end

test("item 12 rules: own land -> any recipient; B's land -> only B's rows, others WRONG_TERRITORY with landOwnerID", function()
	local S = Scenario()
	H.loadEFV()
	local store = EFV_Records.Load()
	-- Own land (regression).
	local home = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.isnil(EFV_SendLandOwner(home, 0))
	local rows = EFV_DestinationRows(0, home, EXP, store)
	H.len(rows, 3)
	for _, r in ipairs(rows) do
		H.ok(r.ok, "own land: every partner row ok")
		H.isnil(r.landOwnerID)
	end
	-- B's land.
	local u = H.unit(0, "UNIT_SWORDSMAN", 21, 10)
	H.eq(EFV_SendLandOwner(u, 0), 1)
	H.deq(EFV_UnitSendReasons(u, 0, store), {}, "partner land is no unit-level reason")
	rows = EFV_DestinationRows(0, u, EXP, store)
	H.len(rows, 3)
	for _, r in ipairs(rows) do
		H.eq(r.landOwnerID, 1)
		if r.recipientID == 1 then
			H.ok(r.ok, "B's city " .. tostring(r.cityID))
			H.ok(not HasCode(r, "WRONG_TERRITORY"))
		else
			H.ok(not r.ok)
			H.eq(r.reasons[1], "WRONG_TERRITORY", "F's row")
		end
	end
	-- Fee and travel time unchanged: origin = the sender's city nearest to the tile.
	local rb = RowsTo(rows, 1)[1]
	H.eq(rb.calc.origin:GetID(), EFV_NearestCity(0, 21, 10):GetID())
	H.eq(rb.calc.origin:GetID(), S.c0.id)
	local band, d = EFV_Band(S.c0.x, S.c0.y, S.c1.x, S.c1.y)
	H.eq(rb.calc.band, band); H.eq(rb.calc.distance, d); H.eq(rb.calc.fee, FEE_EXP[band])
	-- Volunteers from B's land: B ok, F wrong territory.
	rows = EFV_DestinationRows(0, u, VOL, store)
	for _, r in ipairs(rows) do
		H.eq(r.ok, r.recipientID == 1, "VOL row to " .. r.recipientID)
	end
	-- City-State from B's land: no city-state row can be picked.
	rows = EFV_DestinationRows(0, u, CS, store)
	H.len(rows, 1)
	H.ok(HasCode(rows[1], "WRONG_TERRITORY"))
	H.contains(EFV_Rules.ALL_REASON_CODES, "WRONG_TERRITORY")
	H.notContains(EFV_Rules.NAME_REASON_CODES, "WRONG_TERRITORY", "names the land owner, not the recipient")
	H.clean()
end)

test("item 12 rules: city-state land -> that city-state only; neutral land -> NOT_OWN_TERRITORY; enemy land -> all WRONG_TERRITORY", function()
	local S = Scenario({ secondCS = true })
	H.loadEFV()
	local store = EFV_Records.Load()
	local u = H.unit(0, "UNIT_SWORDSMAN", 29, 20)
	H.eq(EFV_SendLandOwner(u, 0), 4)
	local rows = EFV_DestinationRows(0, u, CS, store)
	H.len(rows, 2, "Kumasi and Armagh")
	H.ok(RowsTo(rows, 4)[1].ok, "Kumasi from Kumasi's land")
	H.ok(HasCode(RowsTo(rows, 5)[1], "WRONG_TERRITORY"), "Armagh from Kumasi's land")
	H.eq(RowsTo(rows, 4)[1].calc.origin:GetID(), EFV_NearestCity(0, 29, 20):GetID())
	for _, r in ipairs(EFV_DestinationRows(0, u, EXP, store)) do
		H.ok(HasCode(r, "WRONG_TERRITORY"), "every Expeditionary row")
	end
	-- Neutral land.
	local np = H.neutralPlot(11, 10)
	local n = H.unit(0, "UNIT_SWORDSMAN", np:GetX(), np:GetY())
	H.eq(EFV_SendLandOwner(n, 0), -1)
	H.contains(EFV_UnitSendReasons(n, 0, store), "NOT_OWN_TERRITORY")
	for _, ft in ipairs({ EXP, VOL, CS }) do
		for _, r in ipairs(EFV_DestinationRows(0, n, ft, store)) do
			H.ok(not r.ok and HasCode(r, "NOT_OWN_TERRITORY") and not HasCode(r, "WRONG_TERRITORY"), ft)
			H.isnil(r.landOwnerID)
		end
	end
	-- Enemy C's land.
	local e = H.unit(0, "UNIT_SWORDSMAN", 69, 40)
	H.eq(EFV_SendLandOwner(e, 0), 3)
	for _, ft in ipairs({ EXP, VOL, CS }) do
		local rows2 = EFV_DestinationRows(0, e, ft, store)
		H.ok(#rows2 > 0, ft)
		for _, r in ipairs(rows2) do
			H.ok(not r.ok and HasCode(r, "WRONG_TERRITORY"), ft .. " row in C's land")
		end
	end
	H.eq(EFV_SendLandOwner(nil, 0), -1)
	H.clean()
end)

test("item 12 gameplay: from B's land a send to B is accepted (origin = nearest own city), a forged send to F names B", function()
	local S = Scenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 21, 10)
	H.send(0, u, 2, S.c2, EXP)
	H.len(H.records(), 0, "forged send to F rejected")
	local failed = H.notifs(0, "EFV_NOTIF_REQUEST_FAILED")
	H.len(failed, 1)
	local want = Locale.Lookup("LOC_EFV_REASON_WRONG_TERRITORY", "Rome")
	H.ok(string.find(Summary(failed[1]), want, 1, true), Summary(failed[1]))
	H.ok(H.hasLine("reasons=WRONG_TERRITORY"), "rejection logged")
	H.ok(H.unitAlive(u), "unit untouched")
	local band = EFV_Band(S.c0.x, S.c0.y, S.c1.x, S.c1.y)
	H.send(0, u, 1, S.c1, EXP, FEE_EXP[band])
	local recs = H.records()
	H.len(recs, 1, "send to B accepted")
	local r = recs[1]
	H.eq(r.recipientID, 1)
	H.eq(r.originCityID, S.c0.id, "origin = the sender's city nearest to the unit's tile")
	H.eq(r.band, band); H.eq(r.transitTurns, band); H.eq(r.feePaid, FEE_EXP[band])
	H.eq(r.arrivalTurn, FAKE.turn + band)
	H.ok(not H.unitAlive(u))
	H.clean()
end)

test("item 12 gameplay: a City-State send from the city-state's own land is accepted", function()
	local S = Scenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 29, 20)
	local origin = EFV_NearestCity(0, 29, 20)
	local band = EFV_Band(origin:GetX(), origin:GetY(), S.c4.x, S.c4.y)
	H.send(0, u, 4, S.c4, CS)
	local recs = H.records()
	H.len(recs, 1)
	H.eq(recs[1].forceType, CS); H.eq(recs[1].originCityID, origin:GetID()); H.eq(recs[1].band, band)
	H.clean()
end)

test("item 12 gameplay: a tracked Volunteer standing in B's land is ALREADY_TRACKED (recall only)", function()
	local S = Scenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, VOL)
	local rec = H.records()[1]
	H.turns(rec.arrivalTurn - FAKE.turn)
	rec = H.records()[1]
	H.eq(rec.state, "DEPLOYED")
	local pu = Players[0]:GetUnits():FindID(rec.onMapUnitID)
	H.notnil(pu)
	H.eq(EFV_SendLandOwner(pu, 0), 1, "deployed in B's land")
	local store = EFV_Records.Load()
	H.contains(EFV_UnitSendReasons(pu, 0, store), "ALREADY_TRACKED")
	for _, r in ipairs(EFV_DestinationRows(0, pu, VOL, store)) do
		H.ok(not r.ok and HasCode(r, "ALREADY_TRACKED"))
	end
	H.clean()
end)

test("item 12 UI: picker from B's land shows the land note; F's row is disabled and names B", function()
	local S, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 21, 10)
	Select(ctx, u)
	local b = Button(EXP_ICON)
	H.ok(not b.UnitActionButton.disabled, "B's cities can be picked")
	b.UnitActionButton:Click()
	local P = ctx.picker.Controls
	H.ok(not P.LandNote:IsHidden(), "land note shown")
	H.eq(P.LandNote.text, "This unit stands in Rome's territory, so it can only be sent to Rome.")
	NoLocNoDash(P.LandNote.text, "land note")
	H.len(Rows(), 3, "other recipients' rows stay listed, disabled")
	H.ok(not RowFor(S.c1).RowButton.disabled)
	H.ok(not RowFor(S.c1b).RowButton.disabled)
	local rf = RowFor(S.c2)
	H.ok(rf.RowButton.disabled, "F's row")
	H.eq(rf.RowButton.tooltip, "[COLOR:Red]Standing in Rome's territory, the unit can only be sent to Rome.[ENDCOLOR]")
	for _, r in ipairs(Rows()) do NoLocNoDash(r.RowLabel.text, "row") end
	-- Confirm B's capital: gameplay accepts it.
	RowFor(S.c1).RowButton:Click()
	FAKE_UI.popups[#FAKE_UI.popups].confirm()
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	FAKE_UI.AsGameplay(function() H.request(req.pid, req.params) end)
	H.len(H.records(), 1)
	H.eq(H.records()[1].recipientID, 1)
	-- Back on own land the note is hidden again.
	local home = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	LuaEvents.EFV_OpenDestinationPicker(0, home:GetID(), EXP)
	H.ok(P.LandNote:IsHidden())
	H.clean()
end)

test("item 12 UI: on city-state land the Expeditionary button is disabled with the land summary; neutral land disables all", function()
	local _, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 29, 20)
	Select(ctx, u)
	local be = Button(EXP_ICON)
	H.ok(be.UnitActionButton.disabled)
	local tt = be.UnitActionButton.tooltip
	H.ok(string.find(tt, Locale.Lookup("LOC_EFV_SEND_NO_DESTINATION"), 1, true), tt)
	H.ok(string.find(tt, Locale.Lookup("LOC_EFV_REASON_WRONG_TERRITORY", "Kumasi"), 1, true), tt)
	H.ok(not string.find(tt, "LOC_", 1, true), tt)
	H.ok(not Button(CS_ICON).UnitActionButton.disabled, "Kumasi itself can be picked")
	Button(CS_ICON).UnitActionButton:Click()
	H.eq(ctx.picker.Controls.LandNote.text, "This unit stands in Kumasi's territory, so it can only be sent to Kumasi.")
	-- Neutral land: every button disabled with the unit reason.
	local np = H.neutralPlot(11, 10)
	Select(ctx, H.unit(0, "UNIT_SWORDSMAN", np:GetX(), np:GetY()))
	local list = IM("EFV_ActionInstance").list
	H.len(list, 3)
	for _, inst in ipairs(list) do
		H.ok(inst.UnitActionButton.disabled)
		H.ok(string.find(inst.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_REASON_NOT_OWN_TERRITORY"), 1, true))
	end
	H.clean()
end)
