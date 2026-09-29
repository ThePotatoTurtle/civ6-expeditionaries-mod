-- @harness native
-- Fee ruling 0.5.2 (designer): Expeditionary and City-State Expeditionary
-- pay 0% / 10% / 20% / 30% of the base gold cost for bands 1-4 (band 1 is
-- free), Volunteers 20% / 30% / 40% / 50%. A fee of 0 must work end to end:
-- the rules never report GOLD, the DV5 expectedFee check accepts 0, no gold
-- is deducted, the picker shows "Free", the confirm dialog reads "Fee: Free"
-- and the send is accepted. Scenario: H.baseScenario plus a city of the ally
-- B at (16,10), 6 hexes from the sender's capital (band 1).

local N = function(name) return "EFV_NOTIF_" .. name end

local function Scenario()
	local S = H.baseScenario()
	S.near = H.city(1, 16, 10, { name = "LOC_CITY_B3" })
	return S
end

test("fee 0: band-1 Expeditionary send with 0 gold is accepted; no gold taken; feePaid 0", function()
	local S = Scenario()
	H.loadEFV()
	H.setGold(0, 0)
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, reasons, calc = EFV_EvaluateSend(0, u, 1, S.near, "EXPEDITIONARY", EFV_Records.Load())
	H.ok(ok, table.concat(reasons or {}, ","))
	H.eq(calc.band, 1); H.eq(calc.fee, 0, "band 1 is free")
	H.send(0, u, 1, S.near, "EXPEDITIONARY", 0)
	local r = H.record()
	H.notnil(r, "accepted with expectedFee = 0")
	H.eq(r.feePaid, 0); H.eq(H.gold(0), 0, "nothing deducted")
	H.ok(not H.hasLine("reasons=GOLD")); H.ok(not H.hasLine("FEE_CHANGED"))
	H.len(H.notifs(0, N("REQUEST_FAILED")), 0)
	local dep = H.notifs(0, N("DEPARTED"))
	H.len(dep, 1)
	H.ok(not string.find(dep[1].data[ParameterTypes.SUMMARY], "{", 1, true), "DEPARTED reads well")
	H.clean()
end)

test("fee 0: a City-State Expeditionary to a band-1 city-state is free too; a Volunteer to the same city pays 20%", function()
	local S = Scenario()
	local cs = H.city(4, 14, 16, { name = "LOC_CITY_CS_NEAR" })
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local store = EFV_Records.Load()
	local okC, rC, cC = EFV_EvaluateSend(0, u, 4, cs, "CS_EXPEDITIONARY", store)
	H.ok(okC, table.concat(rC or {}, ",")); H.eq(cC.band, 1); H.eq(cC.fee, 0)
	local okV, rV, cV = EFV_EvaluateSend(0, u, 1, S.near, "VOLUNTEER", store)
	H.ok(okV, table.concat(rV or {}, ",")); H.eq(cV.fee, 72, "Volunteer band 1 = 20% of 360")
	H.setGold(0, 50)
	local _, rV2 = EFV_EvaluateSend(0, u, 1, S.near, "VOLUNTEER", store)
	H.contains(rV2, "GOLD", "the Volunteer fee is still charged")
	local okC2 = EFV_EvaluateSend(0, u, 4, cs, "CS_EXPEDITIONARY", store)
	H.ok(okC2, "a free send needs no gold")
	H.clean()
end)

test("fee 0: DV5 still needs the player's consent (a request without expectedFee is refused)", function()
	local S = Scenario()
	H.loadEFV()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.request(0, { OnStart = "EFV_Send", unitID = u.id, recipientID = 1, destX = S.near.x, destY = S.near.y,
		forceType = "EXPEDITIONARY" })
	H.len(H.records(), 0)
	H.ok(H.hasLine("FEE_CHANGED"))
	H.clean()
end)

test("fee 0 in the UI: picker shows Free, the confirm dialog reads 'Fee: Free', expectedFee 0 is accepted", function()
	local S = Scenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	local actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	local picker = FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	H.markBody()
	H.setGold(0, 0)
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(0, u:GetID(), 0, 0, 0, true, false)
	FAKE_UI.Frame(actions)
	local actIM, rowIM
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_ActionInstance" then actIM = im end
	end
	H.notnil(actIM)
	H.ok(not actIM.list[1].UnitActionButton.disabled, "EXP button enabled with 0 gold (a free destination exists)")
	actIM.list[1].UnitActionButton:Click()
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_DestRowInstance" then rowIM = im end
	end
	local row
	for _, r in ipairs(rowIM.list) do
		if string.find(r.RowLabel.text, " - " .. EFV_CityName(S.near) .. " - ", 1, true) then row = r end
	end
	H.notnil(row, "band-1 row listed")
	H.ok(string.find(row.RowLabel.text, " - " .. Locale.Lookup("LOC_EFV_FEE_FREE") .. " - ", 1, true), row.RowLabel.text)
	H.ok(not string.find(row.RowLabel.text, "[ICON_Gold]", 1, true), row.RowLabel.text)
	H.eq(Locale.Lookup("LOC_EFV_FEE_FREE"), "Free")
	H.ok(not row.RowButton.disabled, "free row enabled with 0 gold")
	row.RowButton:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.notnil(popup)
	H.ok(string.find(popup.texts[1], "Fee: Free", 1, true), popup.texts[1])
	H.ok(not string.find(popup.texts[1], "[ICON_Gold]", 1, true), "no gold icon for a free send: " .. popup.texts[1])
	H.ok(not string.find(popup.texts[1], "{", 1, true), popup.texts[1])
	popup.confirm()
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	H.eq(req.params.expectedFee, 0)
	FAKE_UI.AsGameplay(function() H.request(req.pid, req.params) end)
	local recs = H.records()
	H.len(recs, 1, "gameplay accepted the free send")
	H.eq(recs[1].feePaid, 0); H.eq(H.gold(0), 0)
	H.clean()
end)

test("fee texts: EFV_UI_FeeText for 0, n and nil (EFV_UI_FeeCell removed in 0.7)", function()
	Scenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	H.eq(EFV_UI_FeeText(0), "Free")
	H.eq(EFV_UI_FeeText(36), Locale.Lookup("LOC_EFV_FEE_GOLD", 36))
	H.eq(EFV_UI_FeeText(nil), "-")
	H.isnil(EFV_UI_FeeCell, "EFV_UI_FeeCell removed (picker rows use EFV_UI_PickerRowText)")
	H.clean()
end)
