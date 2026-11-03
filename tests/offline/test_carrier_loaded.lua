-- @harness native
-- Loaded carrier (designer ruling 2026-10-05, 1.0.5; FIXPLAN_air_units
-- section 9): a unit with air slots (GameInfo.Units AirSlots > 0, the
-- Aircraft Carrier) can't be sent while a plane of the sender (DOMAIN_AIR)
-- stands on its plot. Unit-level reason CARRIER_LOADED, shown by the unit
-- action buttons and the picker, enforced by the gameplay send handler.
-- Scenario (H.baseScenario): 0 human (London (10,10)), 1 ally B (Roma
-- (22,10)); rows y 0..7 are ocean, (10,7) is the sender's water tile.

local EXP = "EXPEDITIONARY"
local EM, EN = "\226\128\148", "\226\128\147"
local TEXT = "Unload its planes first: a carrier can't be sent with aircraft aboard."

local function Sea(S)
	H.fill(0, 0, 83, 7, "OCEAN")
	H.own(10, 7, 0); H.own(14, 7, 0)
	return S
end

local function Codes(u)
	return EFV_UnitSendReasons(u, 0, EFV_Records.Load())
end

local function Summary(n) return n.data[ParameterTypes.SUMMARY] end

local function BootUI()
	local S = Sea(H.baseScenario())
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
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
local function ExpButton()
	for _, b in ipairs(IM("EFV_ActionInstance").list) do
		if b.UnitActionIcon.icon == "ICON_UNITCOMMAND_GIFT" then return b end
	end
end

test("data: the Aircraft Carrier has air slots, a Galley and a Destroyer have none", function()
	H.world()
	H.eq(GameInfo.Units["UNIT_AIRCRAFT_CARRIER"].AirSlots, 2)
	H.eq(GameInfo.Units["UNIT_GALLEY"].AirSlots, 0)
	H.eq(GameInfo.Units["UNIT_DESTROYER"].AirSlots, 0)
	H.eq(GameInfo.Units["UNIT_FIGHTER"].Domain, "DOMAIN_AIR")
end)

test("text: LOC_EFV_REASON_CARRIER_LOADED exists, plain wording, no dash, says VEF never EFV", function()
	H.world()
	H.loadEFV()
	H.contains(EFV_Rules.ALL_REASON_CODES, "CARRIER_LOADED")
	H.notContains(EFV_Rules.NAME_REASON_CODES, "CARRIER_LOADED", "no arguments")
	local t = FAKE_TEXT["LOC_EFV_REASON_CARRIER_LOADED"]
	H.notnil(t)
	H.eq(Locale.Lookup("LOC_EFV_REASON_CARRIER_LOADED"), TEXT)
	H.ok(not string.find(t, EM, 1, true) and not string.find(t, EN, 1, true), "no em or en dash")
	H.ok(not string.find(t, "EFV", 1, true), "no EFV")
	H.clean()
end)

test("gameplay: a carrier with no planes can be sent", function()
	local S = Sea(H.baseScenario())
	H.loadEFV()
	local cv = H.unit(0, "UNIT_AIRCRAFT_CARRIER", 10, 7)
	H.notContains(Codes(cv), "CARRIER_LOADED")
	H.len(Codes(cv), 0, "eligible")
	H.send(0, cv, 1, S.c1, EXP)
	H.len(H.records(), 1, "send accepted")
	H.eq(H.records()[1].unitType, "UNIT_AIRCRAFT_CARRIER")
	H.ok(not H.unitAlive(cv), "carrier left the map")
	H.clean()
end)

test("gameplay: a carrier with a plane of the sender aboard is rejected (CARRIER_LOADED), nothing is lost", function()
	local S = Sea(H.baseScenario())
	H.loadEFV()
	local cv = H.unit(0, "UNIT_AIRCRAFT_CARRIER", 10, 7)
	local f = H.unit(0, "UNIT_FIGHTER", 10, 7)
	H.eq(EFV_IsGameplay(), true)
	H.contains(Codes(cv), "CARRIER_LOADED")
	local ok, reasons = EFV_EvaluateSend(0, cv, 1, CityManager.GetCityAt(S.c1.x, S.c1.y), EXP, EFV_Records.Load())
	H.ok(not ok)
	H.contains(reasons, "CARRIER_LOADED")
	local gold = H.gold(0)
	H.send(0, cv, 1, S.c1, EXP)
	H.len(H.records(), 0, "send rejected")
	H.ok(H.hasLine("CARRIER_LOADED"), "rejection logged")
	local failed = H.notifs(0, "EFV_NOTIF_REQUEST_FAILED")
	H.len(failed, 1)
	H.ok(string.find(Summary(failed[1]), TEXT, 1, true), Summary(failed[1]))
	H.ok(H.unitAlive(cv), "carrier untouched")
	H.ok(H.unitAlive(f), "plane untouched")
	H.eq(H.gold(0), gold, "no fee taken")
	-- Rebase the plane away: the carrier can go.
	f.x, f.y = 10, 10
	H.notContains(Codes(cv), "CARRIER_LOADED")
	H.send(0, cv, 1, S.c1, EXP)
	H.len(H.records(), 1, "accepted once unloaded")
	H.ok(H.unitAlive(f), "the plane stays home")
	H.clean()
end)

test("rules: a plane missing from the plot list is still found through the sender's units; another player's plane does not count", function()
	local S = Sea(H.baseScenario())
	H.loadEFV()
	FAKE.airInPlot = false
	local cv = H.unit(0, "UNIT_AIRCRAFT_CARRIER", 10, 7)
	local f = H.unit(0, "UNIT_FIGHTER", 10, 7)
	H.len(Units.GetUnitsInPlot(Map.GetPlot(10, 7)), 1, "only the carrier is listed")
	H.contains(Codes(cv), "CARRIER_LOADED")
	FAKE.airInPlot = true
	f.owner = 1
	H.notContains(Codes(cv), "CARRIER_LOADED", "B's plane is not the sender's")
	H.clean()
end)

test("rules: a non-carrier naval unit with a plane on its plot is unaffected", function()
	local S = Sea(H.baseScenario())
	H.loadEFV()
	local d = H.unit(0, "UNIT_DESTROYER", 14, 7)
	H.unit(0, "UNIT_FIGHTER", 14, 7)
	H.notContains(Codes(d), "CARRIER_LOADED")
	H.len(Codes(d), 0)
	H.send(0, d, 1, S.c1, EXP)
	H.len(H.records(), 1, "Destroyer sent")
	H.clean()
end)

test("UI: a loaded carrier's Send button is disabled with the reason; the picker row too; an empty carrier is enabled", function()
	local S, ctx = BootUI()
	H.eq(EFV_IsGameplay(), false)
	local cv = H.unit(0, "UNIT_AIRCRAFT_CARRIER", 10, 7)
	H.unit(0, "UNIT_FIGHTER", 10, 7)
	H.contains(Codes(cv), "CARRIER_LOADED", "UI evaluation")
	Select(ctx, cv)
	local b = ExpButton()
	H.ok(b.UnitActionButton.disabled, "button disabled")
	H.ok(string.find(b.UnitActionButton.tooltip, TEXT, 1, true), b.UnitActionButton.tooltip)
	LuaEvents.EFV_OpenDestinationPicker(0, cv:GetID(), EXP)
	local rows = IM("EFV_DestRowInstance").list
	H.ok(#rows > 0, "rows listed")
	for _, r in ipairs(rows) do
		H.ok(r.RowButton.disabled, "row disabled")
	end
	-- A carrier with no plane on its tile is enabled.
	local cv2 = H.unit(0, "UNIT_AIRCRAFT_CARRIER", 14, 7)
	Select(ctx, cv2)
	H.ok(not ExpButton().UnitActionButton.disabled, "empty carrier can be sent")
	H.clean()
end)
