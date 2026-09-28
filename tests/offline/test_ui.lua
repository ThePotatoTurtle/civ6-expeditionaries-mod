-- @harness native
-- UI contexts (WP1.5) on the fake engine: EFV_UnitActions, EFV_DestinationPicker,
-- EFV_Tracker and EFV_UIShared, each context in its own environment
-- (lib/fake_ui.lua LoadContext), against the REAL rules in UI mode and real
-- records written by the gameplay side. Ported from the WP1.5 scratchpad
-- smoke test (tests/offline/scratch_salvage/smoke_ui.py), with assertions.

local function Boot(opts)
	opts = opts or {}
	local S = H.baseScenario()
	H.loadEFV()                                       -- gameplay side (store init)
	include("fake_ui")
	FAKE_UI.Enable()                                  -- UI global set -> UI context
	EFV_Config.LOG_LEVEL = 3
	local ctx = {}
	ctx.actions = FAKE_UI.LoadContext("EFV/UI/EFV_UnitActions.lua")
	ctx.picker = FAKE_UI.LoadContext("EFV/UI/EFV_DestinationPicker.lua")
	if opts.tracker then
		ctx.tracker = FAKE_UI.LoadContext("EFV/UI/EFV_Tracker.lua")
	end
	H.markBody()
	return S, ctx
end

local function ActionIM()
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_ActionInstance" then return im end
	end
end
local function RowIM()
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "EFV_DestRowInstance" then return im end
	end
end

-- Select a unit and run one UI frame (UnitSelectionChanged -> RequestRefresh -> handler).
local function Select(ctx, u)
	FAKE_UI.selectedUnit = u
	Events.UnitSelectionChanged(u and u:GetOwner() or -1, u and u:GetID() or -1, 0, 0, 0, true, false)
	FAKE_UI.Frame(ctx.actions)
end

test("UI contexts load hidden-safe: each un-hides itself; picker root starts hidden (note 19)", function()
	local _, ctx = Boot({ tracker = true })
	H.ok(not ctx.actions.ContextPtr:IsHidden())
	H.ok(not ctx.picker.ContextPtr:IsHidden())
	H.ok(not ctx.tracker.ContextPtr:IsHidden())
	H.ok(ctx.picker.Controls.PickerRoot:IsHidden(), "PickerRoot hidden until opened")
	H.ok(not FAKE_UI.KeyTo(ctx.picker, Keys.VK_ESCAPE), "ESC ignored while the picker is closed")
	H.clean()
end)

test("UI: eligible unit gets the EXP, VOL and CS send buttons; they attach to the unit panel", function()
	local _, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Select(ctx, u)
	local im = ActionIM()
	H.len(im.list, 3, "Phase 3: Expeditionary + Volunteer + City-State buttons (FLAG_RELEASED)")
	H.eq(im.list[2].UnitActionIcon.icon, "ICON_UNITOPERATION_DEPLOY", "VOL button second")
	H.ok(string.find(im.list[2].UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_ACTION_SEND_VOLUNTEER"), 1, true))
	H.ok(not im.list[2].UnitActionButton.disabled, "ally B is an eligible Volunteer partner")
	H.eq(im.list[3].UnitActionIcon.icon, "ICON_UNITOPERATION_MOVE_TO", "CS button third")
	H.ok(string.find(im.list[3].UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_ACTION_SEND_CS"), 1, true))
	local b = im.list[1]
	H.eq(b.UnitActionIcon.icon, "ICON_UNITCOMMAND_GIFT")
	H.ok(not b.UnitActionButton.disabled, "enabled")
	H.ok(string.find(b.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_ACTION_SEND_EXPEDITIONARY"), 1, true))
	H.ok(string.find(b.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_ACTION_SEND_EXPEDITIONARY_TT"), 1, true))
	local target = FAKE_UI.built["/InGame/UnitPanel/StandardActionsStack"]
	H.notnil(target, "looked up the standard actions stack (T23)")
	H.eq(ctx.actions.Controls.EFV_ActionStack.parent, target)
	H.ok(not ctx.actions.Controls.EFV_ActionStack:IsHidden())
	-- The release switch still hides a force type (same switch as the rules).
	EFV_Config.FLAG_RELEASED.VOLUNTEER = false
	Select(ctx, u)
	H.len(ActionIM().list, 2)
	H.clean()
end)

test("UI: damaged unit -> disabled button with the unit reason; enemy/other units get none", function()
	local _, ctx = Boot()
	local hurt = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { damage = 10 })
	Select(ctx, hurt)
	local b = ActionIM().list[1]
	H.ok(b.UnitActionButton.disabled)
	H.ok(string.find(b.UnitActionButton.tooltip, Locale.Lookup("LOC_EFV_REASON_DAMAGED"), 1, true))
	Select(ctx, H.unit(1, "UNIT_SWORDSMAN", 22, 11))
	H.len(ActionIM().list, 0, "not the local player's unit")
	H.ok(ctx.actions.Controls.EFV_ActionStack:IsHidden())
	Select(ctx, H.unit(0, "UNIT_BUILDER", 11, 11))
	H.len(ActionIM().list, 0, "civilian: class NEVER hides the button")
	H.clean()
end)

test("UI: picker lists partner cities with fee/transit; disabled rows explain (name, fee)", function()
	local S, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Select(ctx, u)
	ActionIM().list[1].UnitActionButton:Click()
	H.ok(not ctx.picker.Controls.PickerRoot:IsHidden(), "picker opened via LuaEvents.EFV_OpenDestinationPicker")
	local rows = RowIM().list
	H.len(rows, 3, "B's two cities + F's city")
	local byCity = {}
	for _, r in ipairs(rows) do byCity[r.CityLabel.text] = r end
	local rb = byCity[EFV_CityName(S.c1)]
	H.notnil(rb, "B's capital row")
	H.eq(rb.FeeLabel.text, "36[ICON_Gold]"); H.eq(rb.TransitLabel.text, "2"); H.eq(rb.DistanceLabel.text, "12")
	H.ok(not rb.RowButton.disabled)
	-- Not enough gold: rows disabled, tooltip shows the fee.
	H.setGold(0, 20)
	FAKE_UI.KeyTo(ctx.picker, Keys.VK_ESCAPE)
	H.ok(ctx.picker.Controls.PickerRoot:IsHidden(), "ESC closes")
	LuaEvents.EFV_OpenDestinationPicker(0, u:GetID(), "EXPEDITIONARY")
	for _, r in ipairs(RowIM().list) do
		-- 0.5.2 fee ruling: a band-1 row is free and stays enabled with 20 gold.
		H.eq(r.RowButton.disabled, r.FeeLabel.text ~= Locale.Lookup("LOC_EFV_FEE_FREE"), r.CityLabel.text)
		if r.CityLabel.text == EFV_CityName(S.c1) then
			H.ok(r.RowButton.disabled)
			H.ok(string.find(r.RowButton.tooltip, "36", 1, true), "GOLD reason shows the fee: " .. r.RowButton.tooltip)
		end
	end
	-- No common war with B: the reason names B.
	H.setGold(0, 1000)
	H.peace(1, 3)
	LuaEvents.EFV_OpenDestinationPicker(0, u:GetID(), "EXPEDITIONARY")
	for _, r in ipairs(RowIM().list) do
		if r.CityLabel.text == EFV_CityName(S.c1) then
			H.ok(r.RowButton.disabled)
			H.ok(string.find(r.RowButton.tooltip, EFV_UI_PlayerName(1), 1, true), "names the recipient: " .. r.RowButton.tooltip)
		end
	end
	H.clean()
end)

test("UI -> gameplay: confirm sends a flat EFV_Send (expectedFee = shown fee) that gameplay accepts", function()
	local S, ctx = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Select(ctx, u)
	ActionIM().list[1].UnitActionButton:Click()
	local row
	for _, r in ipairs(RowIM().list) do
		if r.CityLabel.text == EFV_CityName(S.c1) then row = r end
	end
	row.RowButton:Click()
	local popup = FAKE_UI.popups[#FAKE_UI.popups]
	H.notnil(popup, "confirm dialog")
	H.ok(string.find(popup.texts[1], Locale.Lookup("LOC_EFV_FEE_GOLD", 36), 1, true), "confirm repeats the fee")
	H.ok(not string.find(popup.texts[1], "{", 1, true), "all 7 CONFIRM_SEND args filled: " .. popup.texts[1])
	popup.confirm()
	H.ok(ctx.picker.Controls.PickerRoot:IsHidden(), "picker closes after confirm")
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	H.eq(req.op, PlayerOperations.EXECUTE_SCRIPT)
	local p = req.params
	H.eq(p.OnStart, "EFV_Send"); H.eq(p.unitID, u:GetID()); H.eq(p.recipientID, 1)
	H.eq(p.destX, S.c1.x); H.eq(p.destY, S.c1.y); H.eq(p.forceType, "EXPEDITIONARY"); H.eq(p.expectedFee, 36)
	for k, v in pairs(p) do
		H.ok(type(v) == "number" or type(v) == "string", "flat param " .. k)
	end
	FAKE_UI.AsGameplay(function() H.request(req.pid, p) end)
	local recs = H.records()
	H.len(recs, 1, "gameplay accepted the UI request")
	H.eq(recs[1].feePaid, 36, "shown fee == charged fee")
	H.eq(H.gold(0), 964)
	H.clean()
end)

test("UI: tracked unit shows no send button; UIShared queries and texts on real records", function()
	local S, ctx = Boot()
	FAKE_UI.AsGameplay(function()
		H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10, { vet = "Brutus" }), 1, S.c1, "EXPEDITIONARY", 999)
	end)
	local rec = EFV_UI_RecordsFor(0)[1]
	H.notnil(rec)
	H.eq(EFV_UI_StateText(rec, FAKE.turn), Locale.Lookup("LOC_EFV_STATE_OUTBOUND", 2))
	FAKE_UI.AsGameplay(function() H.turns(2) end)
	rec = EFV_UI_RecordsFor(0)[1]
	H.eq(rec.state, "DEPLOYED")
	H.eq(EFV_UI_StateText(rec, FAKE.turn), Locale.Lookup("LOC_EFV_STATE_DEPLOYED", 20))
	H.len(EFV_UI_RecordsFor(1), 1, "recipient sees it too")
	H.len(EFV_UI_AlertRecords(0), 0)
	H.eq(EFV_UI_RecordForUnit(rec.onMapPlayerID, rec.onMapUnitID).id, rec.id)
	local tt = EFV_UI_StatusTooltip(rec)
	H.ok(string.find(tt, "Brutus", 1, true) and not string.find(tt, "{", 1, true), tt)
	-- The recipient (as local player) selecting the tracked unit gets no send
	-- button, only the status / merge-warning button (WP5.4).
	FAKE.localPlayer = 1
	Select(ctx, Players[1]:GetUnits():FindID(rec.onMapUnitID))
	H.len(ActionIM().list, 1)
	H.eq(ActionIM().list[1].UnitActionIcon.icon, "ICON_UNITCOMMAND_FORM_CORPS", "status button, not a send button")
	-- Lapsed Volunteer / mutiny texts (records built by hand).
	H.ok(string.find(EFV_UI_StateText({ state = "GRACE", graceTurnsLeft = 3, forceType = "VOLUNTEER",
		lapsed = 1, lapseReason = "PARTNER" }, 5), Locale.Lookup("LOC_EFV_LAPSE_PARTNER"), 1, true))
	H.eq(EFV_UI_StateText({ state = "MUTINY", lastDamage = 40, forceType = "EXPEDITIONARY" }, 5),
		Locale.Lookup("LOC_EFV_STATE_MUTINY", 3))
	H.clean()
end)

test("UI: only the local player's unit events request a refresh", function()
	local _, ctx = Boot()
	ctx.actions.ContextPtr.refreshRequested = false
	Events.UnitMoveComplete(3, 12345, 0, 0)
	H.ok(not ctx.actions.ContextPtr.refreshRequested, "AI move ignored")
	Events.UnitMoveComplete(0, 12345, 0, 0)
	H.ok(ctx.actions.ContextPtr.refreshRequested, "local move refreshes")
end)

test("UI tracker: NotificationAdded replays before LoadGameViewStateDone are ignored (T21)", function()
	local _, ctx = Boot({ tracker = true })
	Events.NotificationAdded(0, 7)
	H.ok(H.hasLine("NotificationAdded replay ignored"), "load-time replay ignored")
	Events.LoadGameViewStateDone()
	Events.NotificationAdded(0, 8)
	H.len(H.lines("replay ignored"), 1, "live notifications are processed after the view is ready")
	H.clean()
end)
