-- ===========================================================================
-- EFV_DestinationPicker.lua
-- Context:  UI, context of EFV_DestinationPicker.xml (AddUserInterfaces
--           InGame). Controls: PickerRoot, PickerWindow, PickerTitle,
--           CloseButton, HeaderLabel, LandNote, RowScroll, RowStack,
--           EmptyLabel; instance EFV_DestRowInstance (RowButton, RowLabel).
-- Owner:    WP1.5 (VOL rows WP3.3, CS rows WP4.1: rows come from EFV_Rules,
--           so this file needs no change for them).
--
-- Responsibility (PLAN 3.3; spec 14.2): modal destination picker opened by
-- LuaEvents.EFV_OpenDestinationPicker(playerID, unitID, forceType). Rows from
-- EFV_DestinationRows, one line each (EFV_UI_PickerRowText, 0.7); header
-- EFV_UI_PickerHeaderText; LandNote (LOC_EFV_PICKER_FROM_LAND) when the unit
-- stands on another player's land (EFV_SendLandOwner: only that player's
-- rows can be enabled, the others say WRONG_TERRITORY); disabled rows show
-- their reasons as tooltip; a row
-- click opens a confirm dialog repeating unit, city, recipient, fee, transit
-- and duration, then sends EFV_UI_Request("EFV_Send", { unitID, recipientID,
-- destX, destY, forceType, expectedFee = row.calc.fee }) and closes
-- (DV1, DV5). Closes on ESC, CloseButton, LocalPlayerTurnEnd and
-- DiplomacyActionView_HideIngameUI.
--
-- Text keys: LOC_EFV_PICKER_TITLE, LOC_EFV_PICKER_HEADER / _HEADER_CS,
-- LOC_EFV_PICKER_TILES, LOC_EFV_PICKER_FEE, LOC_EFV_PICKER_FROM_LAND {1_Name},
-- LOC_EFV_SEND_NO_RECIPIENTS
-- (empty list), LOC_EFV_ACTION_SEND_* (confirm title), LOC_EFV_CONFIRM_SEND
-- {1_Unit} {2_City} {3_Recipient} {4_Fee} {5_Transit} {6_Duration} {7_Force},
-- LOC_YES / LOC_NO (base game).
-- ===========================================================================

include("InstanceManager")
include("PopupDialog")
include("EFV_UIShared")

local LOG_TAG = "UIPicker"

-- Row instance manager (U12).
local m_RowIM = InstanceManager:new("EFV_DestRowInstance", "RowButton", Controls.RowStack)
-- Current picker context: { playerID, unitID, forceType } or nil when closed.
local m_Ctx = nil

-- Confirm-dialog title per force type.
local ACTION_KEYS = {
	EXPEDITIONARY    = "LOC_EFV_ACTION_SEND_EXPEDITIONARY",
	VOLUNTEER        = "LOC_EFV_ACTION_SEND_VOLUNTEER",
	CS_EXPEDITIONARY = "LOC_EFV_ACTION_SEND_CS",
}

-- Unit object of the picker context, or nil (A17). Identity-checked
-- (Session C item 2): GetUnit resolves only the slot, so a unit whose ID
-- differs (the picked unit died and its slot was reused) counts as gone.
local function CtxUnit(ctx)
	if ctx == nil then
		return nil
	end
	local ok, pUnit = pcall(function()
		return UnitManager.GetUnit(ctx.playerID, ctx.unitID)
	end)
	if ok and pUnit ~= nil and EFV_UnitMatches(pUnit, ctx.playerID, ctx.unitID, nil) then
		return pUnit
	end
	return nil
end

-- Display name of the unit (type name; veteran names are gameplay-only, A30).
local function UnitName(pUnit)
	local name = ""
	pcall(function()
		name = EFV_UnitDisplayName(GameInfo.Units[pUnit:GetType()].UnitType, nil) or ""
	end)
	return name
end

-- Heal-gate warning for a row (designer ruling "Strategic-resource heal
-- gate", 0.6.0): the unit's owner on the map is the recipient for
-- Expeditionary / City-State and the sender for Volunteers. "" when the
-- owner has the resource, the type needs none, or the stock is unreadable.
local function RowHealWarning(pUnit, row, ctx)
	local text = ""
	pcall(function()
		local unitType = GameInfo.Units[pUnit:GetType()].UnitType
		local owner = row.recipientID
		if ctx.forceType == EFV_Config.FT_VOL then
			owner = ctx.playerID
		end
		text = EFV_UI_HealWarning(unitType, owner)
	end)
	return text
end

-- "[NEWLINE]..." -> "..." (tooltips start without an empty line).
local function StripLeadingNewline(s)
	local prefix = "[NEWLINE]"
	if string.sub(s, 1, string.len(prefix)) == prefix then
		return string.sub(s, string.len(prefix) + 1)
	end
	return s
end

-- ---------------------------------------------------------------------------
-- Close()
-- UIManager:DequeuePopup(ContextPtr) if queued (sound "UI_Screen_Close"),
-- Controls.PickerRoot:SetHide(true), clear m_Ctx (the open/closed flag; never
-- use ContextPtr:IsHidden()). Safe to call when already closed.
-- Params:  none.
-- Returns: nil.
-- PLAN 3.3; R4 2.2. APIs: U09, U07, U18.
-- ---------------------------------------------------------------------------
local function Close()
	local wasOpen = (m_Ctx ~= nil)
	m_Ctx = nil
	pcall(function()
		if UIManager:IsInPopupQueue(ContextPtr) then
			UIManager:DequeuePopup(ContextPtr)
			UI.PlaySound("UI_Screen_Close")
		end
	end)
	Controls.PickerRoot:SetHide(true)
	m_RowIM:ResetInstances()
	if wasOpen then
		EFV_Log(3, LOG_TAG, "closed")
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- ConfirmRow(row)
-- PopupDialogInGame confirm (LOC_EFV_CONFIRM_SEND with unit, city,
-- recipient, fee, transit, duration, force); yes -> EFV_UI_Request(
-- EFV_Config.REQ_SEND, { unitID, recipientID = row.recipientID, destX =
-- row.destX, destY = row.destY, forceType, expectedFee = row.calc.fee })
-- -> Close(). Cancel keeps the picker open.
-- Params:  row destination row (INTERFACES "Destination row").
-- Returns: nil.
-- PLAN 3.3, 1.5; DV1, DV5. APIs: U10, U01 (via EFV_UI_Request).
-- ---------------------------------------------------------------------------
local function ConfirmRow(row)
	if m_Ctx == nil or row == nil or not row.ok or row.calc == nil or row.calc.fee == nil then
		return nil
	end
	local ctx = { playerID = m_Ctx.playerID, unitID = m_Ctx.unitID, forceType = m_Ctx.forceType }
	local pUnit = CtxUnit(ctx)
	if pUnit == nil then
		EFV_Log(2, LOG_TAG, "unit %s gone; closing", tostring(ctx.unitID))
		Close()
		return nil
	end
	local calc = row.calc
	local forceKey = EFV_ForceLabelKey(ctx.forceType)
	local text = Locale.Lookup("LOC_EFV_CONFIRM_SEND",
		UnitName(pUnit),
		EFV_UI_CityName(row.recipientID, row.cityID, row.destX, row.destY),
		EFV_UI_PlayerName(row.recipientID),
		EFV_UI_FeeText(calc.fee),        -- "Free" for a fee of 0 (0.5.2 fee ruling)
		calc.transit or 0,
		EFV_UI_DurationText(calc.duration),
		forceKey and Locale.Lookup(forceKey) or "")

	local params = {
		unitID      = ctx.unitID,
		recipientID = row.recipientID,
		destX       = row.destX,
		destY       = row.destY,
		forceType   = ctx.forceType,
		expectedFee = calc.fee,
	}
	local healWarn = RowHealWarning(pUnit, row, ctx)
	if healWarn ~= "" then
		text = text .. "[NEWLINE][NEWLINE]" .. healWarn
	end
	local pPopup = PopupDialogInGame:new("EFV_ConfirmSend")
	pPopup:AddTitle(Locale.Lookup(ACTION_KEYS[ctx.forceType] or "LOC_EFV_PICKER_TITLE"))
	pPopup:AddText(text)
	pPopup:AddConfirmButton(Locale.Lookup("LOC_YES"), function()
		EFV_UI_Request(EFV_Config.REQ_SEND, params)
		Close()
	end)
	pPopup:AddCancelButton(Locale.Lookup("LOC_NO"), nil)
	pPopup:Open()
	return nil
end

-- ---------------------------------------------------------------------------
-- Populate() -> bool
-- m_RowIM:ResetInstances(); for each row of EFV_DestinationRows(
-- m_Ctx.playerID, pUnit, m_Ctx.forceType, EFV_UI_ReadStore()): RowLabel =
-- EFV_UI_PickerRowText(row), SetDisabled(not row.ok), tooltip
-- EFV_UI_ReasonsText(row.reasons,
-- EFV_UI_RowReasonCtx(row)) for disabled rows, click -> ConfirmRow(row).
-- EmptyLabel when there are no rows. CalculateSize of RowStack / RowScroll.
-- Params:  none (uses m_Ctx).
-- Returns: false when the unit no longer exists (caller closes), else true.
-- PLAN 3.3; spec 14.2. APIs: U12, U07, U17, A17.
-- ---------------------------------------------------------------------------
local function Populate()
	m_RowIM:ResetInstances()
	local pUnit = CtxUnit(m_Ctx)
	if pUnit == nil then
		return false
	end
	local ok, rows = pcall(EFV_DestinationRows, m_Ctx.playerID, pUnit, m_Ctx.forceType, EFV_UI_ReadStore())
	if not ok or type(rows) ~= "table" then
		EFV_Log(1, LOG_TAG, "EFV_DestinationRows failed: %s", tostring(rows))
		rows = {}
	end
	local nOk = 0
	for _, row in ipairs(rows) do
		local inst = m_RowIM:GetInstance()
		local calc = row.calc
		inst.RowLabel:SetText(EFV_UI_PickerRowText(row, m_Ctx.forceType))
		local enabled = (row.ok == true) and calc ~= nil
		inst.RowButton:SetDisabled(not enabled)
		inst.RowButton:SetAlpha((enabled and 1) or 0.6)
		if enabled then
			nOk = nOk + 1
			inst.RowButton:SetToolTipString(RowHealWarning(pUnit, row, m_Ctx))
		else
			local reasons = EFV_UI_ReasonsText(row.reasons or {}, EFV_UI_RowReasonCtx(row, m_Ctx.playerID))
			inst.RowButton:SetToolTipString(StripLeadingNewline(reasons))
		end
		inst.RowButton:RegisterCallback(Mouse.eLClick, function()
			if enabled then
				ConfirmRow(row)
			end
		end)
		inst.RowButton:RegisterCallback(Mouse.eMouseEnter, function()
			UI.PlaySound("Main_Menu_Mouse_Over")
		end)
	end
	if #rows == 0 then
		Controls.EmptyLabel:SetText(Locale.Lookup("LOC_EFV_SEND_NO_RECIPIENTS"))
		Controls.EmptyLabel:SetHide(false)
	else
		Controls.EmptyLabel:SetHide(true)
	end
	Controls.RowStack:CalculateSize()
	Controls.RowScroll:CalculateSize()
	EFV_Log(2, LOG_TAG, "populated unit=%s ft=%s rows=%d enabled=%d",
		tostring(m_Ctx.unitID), tostring(m_Ctx.forceType), #rows, nOk)
	return true
end

-- ---------------------------------------------------------------------------
-- Open(playerID, unitID, forceType)
-- Handler of LuaEvents.EFV_OpenDestinationPicker (U21): m_Ctx = { playerID,
-- unitID, forceType }; header text; land note (0.7); Populate();
-- ContextPtr:SetHide(false) (a dequeued
-- popup may have been hidden by UIManager); Controls.PickerRoot:SetHide(
-- false); QueuePopup(ContextPtr, PopupPriority.Medium) if not already
-- queued (sound "UI_Screen_Open").
-- Params:  playerID local player ID, unitID number, forceType EFV_Config.FT_*.
-- Returns: nil.
-- PLAN 3.3. APIs: U09, U21, U18, U02.
-- ---------------------------------------------------------------------------
local function Open(playerID, unitID, forceType)
	if playerID ~= Game.GetLocalPlayer() then
		EFV_Log(1, LOG_TAG, "open ignored: player %s is not local", tostring(playerID))
		return nil
	end
	m_Ctx = { playerID = playerID, unitID = unitID, forceType = forceType }
	Controls.HeaderLabel:SetText(EFV_UI_PickerHeaderText(forceType))
	-- Send from the recipient's land (0.7): say whose land it is.
	local landOwner = nil
	pcall(function()
		landOwner = EFV_SendLandOwner(CtxUnit(m_Ctx), playerID)
	end)
	if type(landOwner) == "number" and landOwner >= 0 then
		Controls.LandNote:SetText(Locale.Lookup("LOC_EFV_PICKER_FROM_LAND", EFV_UI_PlayerName(landOwner)))
		Controls.LandNote:SetHide(false)
	else
		Controls.LandNote:SetText("")
		Controls.LandNote:SetHide(true)
	end
	local ok, populated = pcall(Populate)
	if not ok or not populated then
		EFV_Log(1, LOG_TAG, "open failed unit=%s: %s", tostring(unitID), tostring(populated))
		Close()
		return nil
	end
	ContextPtr:SetHide(false)
	Controls.PickerRoot:SetHide(false)
	if not UIManager:IsInPopupQueue(ContextPtr) then
		UIManager:QueuePopup(ContextPtr, PopupPriority.Medium)
		UI.PlaySound("UI_Screen_Open")
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- OnInput(pInput) -> handled
-- ESC (KeyEvents.KeyUp + Keys.VK_ESCAPE) while open (m_Ctx ~= nil) ->
-- Close(), true. Returns false whenever the picker is closed: the context
-- stays visible (see Initialize), so this handler sees all input.
-- Params:  pInput input struct.
-- Returns: boolean, true when consumed.
-- PLAN 3.3. APIs: U11.
-- ---------------------------------------------------------------------------
local function OnInput(pInput)
	if m_Ctx == nil then
		return false
	end
	if pInput:GetMessageType() == KeyEvents.KeyUp and pInput:GetKey() == Keys.VK_ESCAPE then
		Close()
		return true
	end
	return false
end

-- Close triggers (PLAN 3.3): end of the local turn, diplomacy screen.
local function OnCloseTrigger()
	if m_Ctx ~= nil then
		Close()
	end
end

-- ---------------------------------------------------------------------------
-- Initialize(): event wiring.
-- Civ VI loads every AddUserInterfaces context HIDDEN (Expansion2
-- InGame.lua:350-352, isHidden=true); a hidden context draws nothing and gets
-- no input. So: show the context here and keep open/closed state in the
-- PickerRoot control + the m_Ctx flag (PickerRoot starts Hidden="1").
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	Controls.PickerRoot:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, OnCloseTrigger)
	LuaEvents.EFV_OpenDestinationPicker.Add(Open)
	Events.LocalPlayerTurnEnd.Add(OnCloseTrigger)
	LuaEvents.DiplomacyActionView_HideIngameUI.Add(OnCloseTrigger)
	EFV_Log(2, LOG_TAG, "initialized")
end

Initialize()
