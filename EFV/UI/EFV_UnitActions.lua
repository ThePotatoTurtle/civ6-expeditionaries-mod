-- ===========================================================================
-- EFV_UnitActions.lua
-- Context:  UI, companion context of EFV_UnitActions.xml (AddUserInterfaces
--           InGame). Controls: EFV_ActionStack; instance EFV_ActionInstance
--           (UnitActionButton, UnitActionIcon).
-- Owner:    WP1.5 (EXP send), WP3.3 (VOL send, Recall), WP4.1 (CS send),
--           WP5.4 (status / merge-warning button).
--
-- Responsibility (PLAN 3.2; spec 14.1; D3, D8): inject EFV buttons into the
-- UnitPanel action stack and keep them in sync with the head-selected unit:
--   * Send buttons (EXP / VOL / CS): hidden when EFV_UnitClass == "NEVER",
--     not owned by the local player, or already tracked; disabled with a
--     reason tooltip otherwise; click -> LuaEvents.EFV_OpenDestinationPicker(
--     localID, unitID, forceType).
--   * Recall button (VOL records sent by the local player, on the map):
--     disabled per EFV_RecallReasons (no HP requirement, designer answer);
--     click -> PopupDialogInGame yes/no -> EFV_UI_Request("EFV_Recall",
--     { unitID = n }).
--   * Status / merge-warning button when the selected unit is tracked and
--     owned by the local player: recipient view for EXP / CS, sender view
--     for VOL (WP5.4, D3 ruling). Events.UnitFormCorps / UnitFormArmy only
--     refresh the panel (UI hints; gameplay detects merges at the turn
--     boundary).
-- Phase gating: EFV_Config.FLAG_RELEASED (the same switch EFV_Rules uses).
-- Phase 3 released VOLUNTEER and RECALL: all three send buttons and the
-- Recall button are shown.
-- Advisory only: gameplay re-validates every request.
--
-- Text keys: LOC_EFV_ACTION_SEND_<EXPEDITIONARY|VOLUNTEER|CS>(+_TT),
-- LOC_EFV_ACTION_RECALL(+_TT), LOC_EFV_ACTION_STATUS(+_TT),
-- LOC_EFV_WARN_MERGE_HEADER / _EXPEDITIONARY / _VOLUNTEER,
-- LOC_EFV_STATUS_MERGED_SURVIVOR, LOC_EFV_SEND_NO_DESTINATION,
-- LOC_EFV_SEND_NO_RECIPIENTS, LOC_EFV_CONFIRM_RECALL {1_Unit}, LOC_YES/LOC_NO.
-- ===========================================================================

include("InstanceManager")
include("PopupDialog")
include("EFV_UIShared")

local LOG_TAG = "UIActions"

-- Instance manager for the injected buttons (U12).
local m_ActionIM = InstanceManager:new("EFV_ActionInstance", "UnitActionButton", Controls.EFV_ActionStack)
local m_Attached = false  -- set by Attach() after the one-time ChangeParent
local m_LastCount = 0     -- buttons shown by the previous Refresh
local m_Count = 0         -- buttons added by the current Refresh (AddButton)
local m_WarnedNoTarget = false

-- Phase gating (PLAN 5.1: EXP only in Phase 1; VOL Phase 3; CS Phase 4):
-- EFV_Config.FLAG_RELEASED[key] for key = force type or "RECALL".
local function Released(key)
	local rel = EFV_Config.FLAG_RELEASED
	return rel ~= nil and rel[key] == true
end

-- Send buttons in display order: force type, action text key, icon.
-- Icons are existing atlas entries (UnitActions atlas); Phase 7 may replace.
local SEND_BUTTONS = {
	{ ft = EFV_Config.FT_EXP, key = "LOC_EFV_ACTION_SEND_EXPEDITIONARY", tt = "LOC_EFV_ACTION_SEND_EXPEDITIONARY_TT", icon = "ICON_UNITCOMMAND_GIFT" },
	{ ft = EFV_Config.FT_VOL, key = "LOC_EFV_ACTION_SEND_VOLUNTEER",     tt = "LOC_EFV_ACTION_SEND_VOLUNTEER_TT",     icon = "ICON_UNITOPERATION_DEPLOY" },
	{ ft = EFV_Config.FT_CS,  key = "LOC_EFV_ACTION_SEND_CS",            tt = "LOC_EFV_ACTION_SEND_CS_TT",            icon = "ICON_UNITOPERATION_MOVE_TO" },
}
local RECALL_ICON = "ICON_UNITOPERATION_REBASE"

-- pcall wrapper for rule calls: a failing rule must not break the panel.
local function Try(label, fn, ...)
	local ok, a, b, c = pcall(fn, ...)
	if not ok then
		EFV_Log(1, LOG_TAG, "%s failed: %s", label, tostring(a))
		return false
	end
	return true, a, b, c
end

-- ---------------------------------------------------------------------------
-- Attach()
-- Once: Controls.EFV_ActionStack:ChangeParent(ContextPtr:LookUpControl(
-- "/InGame/UnitPanel/" .. EFV_Config.FLAG_UNIT_ACTIONS_STACK)) (Secondary:
-- also AddChildAtIndex(stack, 0), GITM pattern); every call:
-- CalculateSize / ReprocessAnchoring of the target and, for the standard
-- stack, the UnitPanel resize replica (UnitPanel.lua:2120-2135:
-- ActionsStack:CalculateSize(); UnitPanelBaseContainer:SetSizeX(
-- max(ActionsStack:GetSizeX() + 18, 340))).
-- Params:  none.
-- Returns: nil.
-- PLAN 3.2; SPIKES UI-S1; T23. APIs: U07.
-- ---------------------------------------------------------------------------
local function Attach()
	local stackName = EFV_Config.FLAG_UNIT_ACTIONS_STACK
	local target = ContextPtr:LookUpControl("/InGame/UnitPanel/" .. stackName)
	if target == nil then
		if not m_WarnedNoTarget then
			EFV_Log(1, LOG_TAG, "UnitPanel stack %s not found; buttons not attached", tostring(stackName))
			m_WarnedNoTarget = true
		end
		return nil
	end
	local ok, err = pcall(function()
		if not m_Attached then
			Controls.EFV_ActionStack:ChangeParent(target)
			if stackName == "SecondaryActionsStack" then
				target:AddChildAtIndex(Controls.EFV_ActionStack, 0)
			end
			m_Attached = true
			EFV_Log(2, LOG_TAG, "attached to %s", stackName)
		end
		target:CalculateSize()
		target:ReprocessAnchoring()
		if stackName ~= "SecondaryActionsStack" then
			local actions = ContextPtr:LookUpControl("/InGame/UnitPanel/ActionsStack")
			local base = ContextPtr:LookUpControl("/InGame/UnitPanel/UnitPanelBaseContainer")
			if actions ~= nil and base ~= nil then
				actions:CalculateSize()
				base:SetSizeX(math.max(actions:GetSizeX() + 18, 340))
			end
		end
	end)
	if not ok then
		EFV_Log(1, LOG_TAG, "Attach failed: %s", tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- AddButton(icon, tooltip, disabled, onClick)
-- One EFV_ActionInstance: SetIcon, SetDisabled, SetAlpha(disabled and 0.7
-- or 1), SetToolTipString, click callback (reset interface mode to
-- SELECTION first, U22), hover sound "Main_Menu_Mouse_Over" (U18).
-- Mirrors UnitPanel.lua AddActionButton (:203-223).
-- Params:  icon string, tooltip string, disabled boolean, onClick function
--          or nil (nil = no click action).
-- Returns: nil.
-- PLAN 3.2; R4 1.4. APIs: U07, U12, U18, U22.
-- ---------------------------------------------------------------------------
local function AddButton(icon, tooltip, disabled, onClick)
	local inst = m_ActionIM:GetInstance()
	m_Count = m_Count + 1
	inst.UnitActionIcon:SetIcon(icon)
	inst.UnitActionButton:SetDisabled(disabled and true or false)
	inst.UnitActionButton:SetAlpha((disabled and 0.7) or 1)
	inst.UnitActionButton:SetToolTipString(tooltip or "")
	inst.UnitActionButton:RegisterCallback(Mouse.eLClick, function()
		if UI.GetInterfaceMode() ~= InterfaceModeTypes.SELECTION then
			UI.SetInterfaceMode(InterfaceModeTypes.SELECTION)
		end
		if onClick ~= nil and not disabled then
			onClick()
		end
	end)
	inst.UnitActionButton:RegisterCallback(Mouse.eMouseEnter, function()
		UI.PlaySound("Main_Menu_Mouse_Over")
	end)
	return nil
end

-- Destination summary for a send button: nil when some row is enabled,
-- else the text listing why no destination is available (distinct row
-- reasons that are not already listed as unit reasons).
local function DestinationSummary(rows, unitCodes, localID)
	if #rows == 0 then
		return "[NEWLINE][COLOR:Red]" .. Locale.Lookup("LOC_EFV_SEND_NO_RECIPIENTS") .. "[ENDCOLOR]"
	end
	local unitSet = {}
	for _, code in ipairs(unitCodes) do
		unitSet[code] = true
	end
	local codes, names, seenName = {}, {}, {}
	local minFee = nil
	for _, row in ipairs(rows) do
		if row.ok then
			return nil
		end
		for _, code in ipairs(row.reasons or {}) do
			if not unitSet[code] then
				if names[code] == nil then
					codes[#codes + 1] = code
					names[code] = {}
					seenName[code] = {}
				end
				if EFV_UIShared.NAME_REASONS[code] and not seenName[code][row.recipientID] then
					seenName[code][row.recipientID] = true
					names[code][#names[code] + 1] = EFV_UI_PlayerName(row.recipientID)
				end
				if code == "GOLD" and row.calc ~= nil and row.calc.fee ~= nil then
					if minFee == nil or row.calc.fee < minFee then
						minFee = row.calc.fee
					end
				end
			end
		end
	end
	if #codes == 0 then
		return ""  -- only unit-level reasons; already listed
	end
	local ctx = {}
	for _, code in ipairs(codes) do
		if EFV_UIShared.NAME_REASONS[code] then
			ctx[code] = { table.concat(names[code], ", ") }
		end
	end
	ctx.GOLD = { minFee or 0 }
	return "[NEWLINE][NEWLINE]" .. Locale.Lookup("LOC_EFV_SEND_NO_DESTINATION") .. EFV_UI_ReasonsText(codes, ctx)
end

-- ---------------------------------------------------------------------------
-- AddSendButtons(pUnit, localID, uiStore)
-- Send buttons per enabled force type. Disabled when EFV_UnitSendReasons is
-- non-empty or no row of EFV_DestinationRows is ok; tooltip = action name +
-- action help + unit reasons + destination summary (distinct row reasons).
-- The caller has already checked class, ownership and tracking.
-- Params:  pUnit unit object, localID player ID, uiStore (EFV_UI_ReadStore).
-- Returns: nil.
-- PLAN 3.2; spec 6, 14.1. APIs: via EFV_Rules, U21.
-- ---------------------------------------------------------------------------
local function AddSendButtons(pUnit, localID, uiStore)
	local unitID = pUnit:GetID()
	local okU, unitCodes = Try("EFV_UnitSendReasons", EFV_UnitSendReasons, pUnit, localID, uiStore)
	if not okU or type(unitCodes) ~= "table" then
		unitCodes = {}
	end
	for _, def in ipairs(SEND_BUTTONS) do
		if Released(def.ft) then
			local okR, rows = Try("EFV_DestinationRows", EFV_DestinationRows, localID, pUnit, def.ft, uiStore)
			if not okR or type(rows) ~= "table" then
				rows = {}
			end
			local summary = DestinationSummary(rows, unitCodes, localID)
			local disabled = (#unitCodes > 0) or (summary ~= nil)
			local tooltip = Locale.Lookup(def.key) .. "[NEWLINE]" .. Locale.Lookup(def.tt)
				.. EFV_UI_ReasonsText(unitCodes, nil) .. (summary or "")
			local ft = def.ft
			AddButton(def.icon, tooltip, disabled, function()
				EFV_Log(2, LOG_TAG, "open picker unit=%s ft=%s", tostring(unitID), tostring(ft))
				LuaEvents.EFV_OpenDestinationPicker(localID, unitID, ft)
			end)
			EFV_Log(3, LOG_TAG, "send button ft=%s unit=%s disabled=%s unitReasons=%s rows=%d",
				tostring(ft), tostring(unitID), tostring(disabled), table.concat(unitCodes, ","), #rows)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- ConfirmRecall(unitID)
-- PopupDialogInGame yes/no with LOC_EFV_CONFIRM_RECALL {1_Unit}; yes ->
-- EFV_UI_Request(EFV_Config.REQ_RECALL, { unitID = unitID }).
-- Params:  unitID number; unitName string (display only).
-- Returns: nil.
-- PLAN 3.2. APIs: U10, U01 (via EFV_UI_Request).
-- ---------------------------------------------------------------------------
local function ConfirmRecall(unitID, unitName)
	local pPopup = PopupDialogInGame:new("EFV_ConfirmRecall")
	pPopup:AddTitle(Locale.Lookup("LOC_EFV_ACTION_RECALL"))
	pPopup:AddText(Locale.Lookup("LOC_EFV_CONFIRM_RECALL", unitName or ""))
	pPopup:AddConfirmButton(Locale.Lookup("LOC_YES"), function()
		EFV_UI_Request(EFV_Config.REQ_RECALL, { unitID = unitID })
	end)
	pPopup:AddCancelButton(Locale.Lookup("LOC_NO"), nil)
	pPopup:Open()
	return nil
end

-- ---------------------------------------------------------------------------
-- AddRecallButton(pUnit, rec, turn)
-- Recall button for a Volunteer record with senderID == local and state
-- DEPLOYED / GRACE / MUTINY; disabled with EFV_RecallReasons(rec, pUnit,
-- turn) (RECALL_MIN_TURNS arg = turns still to serve; waived while lapsed;
-- RECALL_TERRITORY on neutral land; no HP rule); the tooltip also carries
-- the D3 Volunteer merge warning (LOC_EFV_WARN_MERGE_VOLUNTEER); click ->
-- ConfirmRecall. Gated by EFV_Config.FLAG_RELEASED.RECALL (released Phase 3).
-- Params:  pUnit unit object, rec record, turn number.
-- Returns: nil.
-- PLAN 3.2; spec 9.2 (amended). APIs: U10.
-- ---------------------------------------------------------------------------
local function AddRecallButton(pUnit, rec, turn)
	local okR, codes = Try("EFV_RecallReasons", EFV_RecallReasons, rec, pUnit, turn)
	if not okR or type(codes) ~= "table" then
		codes = {}
	end
	local left = EFV_Config.VOLUNTEER_MIN_DEPLOYMENT - (turn - (rec.deployedTurn or turn))
	local ctx = { RECALL_MIN_TURNS = { math.max(1, left) } }
	-- D3 ruling: warn on every selected Volunteer that merging ends its
	-- Volunteer status (gameplay closes the record on a merge, Phase 3). The
	-- status / merge-warning button (AddStatusButton, WP5.4) repeats it.
	local tooltip = Locale.Lookup("LOC_EFV_ACTION_RECALL") .. "[NEWLINE]" .. Locale.Lookup("LOC_EFV_ACTION_RECALL_TT")
		.. EFV_UI_ReasonsText(codes, ctx)
		.. "[NEWLINE][NEWLINE][COLOR:Red]" .. Locale.Lookup("LOC_EFV_WARN_MERGE_VOLUNTEER") .. "[ENDCOLOR]"
	local unitID = pUnit:GetID()
	local unitName = EFV_UnitDisplayName(rec.unitType, rec.veteranName)
	AddButton(RECALL_ICON, tooltip, #codes > 0, function()
		ConfirmRecall(unitID, unitName)
	end)
	return nil
end

-- ---------------------------------------------------------------------------
-- AddStatusButton(pUnit, rec)
-- Status / merge-warning button (WP5.4; D3 ruling; D8 fallback) for a
-- selected tracked unit owned by the local player: the recipient for EXP /
-- CS (the unit is theirs while it serves), the sender for VOL. Enabled look,
-- no click action (the engine has no merge veto, SPIKES S6: the warning is
-- shown whenever such a unit is selected). Tooltip: LOC_EFV_ACTION_STATUS,
-- LOC_EFV_ACTION_STATUS_TT, EFV_UI_StatusTooltip(rec) (force, unit, sender,
-- recipient, state and turns), then in red LOC_EFV_WARN_MERGE_HEADER +
-- LOC_EFV_WARN_MERGE_EXPEDITIONARY (EXP / CS: absorbed = lost to the
-- sender; survivor returns as a single unit) or LOC_EFV_WARN_MERGE_VOLUNTEER
-- (VOL: merging ends volunteer status, no return or recall). An EXP / CS
-- unit that already survived a merge (rec.formation not STANDARD) also gets
-- LOC_EFV_STATUS_MERGED_SURVIVOR. A record whose stored ID now names another
-- unit (reused slot, EFV_UnitMatches) gets no button. Advisory only: the
-- merge itself is detected by gameplay at the next turn boundary.
-- Params:  pUnit unit object, rec record.
-- Returns: nil.
-- PLAN 3.2; D3 ruling; D8. APIs: U07, U17.
-- ---------------------------------------------------------------------------
local STATUS_ICON = "ICON_UNITCOMMAND_FORM_CORPS"

local function AddStatusButton(pUnit, rec)
	local localID = Game.GetLocalPlayer()
	local okM, matches = Try("EFV_UnitMatches", EFV_UnitMatches, pUnit, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType)
	if not okM or not matches then
		return nil
	end
	local isVol = rec.forceType == EFV_Config.FT_VOL
	local viewer = isVol and rec.senderID or rec.onMapPlayerID
	if viewer ~= localID or pUnit:GetOwner() ~= localID then
		return nil
	end
	local st = rec.state
	if not (st == EFV_Config.ST_DEPLOYED or st == EFV_Config.ST_GRACE or st == EFV_Config.ST_MUTINY) then
		return nil
	end
	local warnKey = isVol and "LOC_EFV_WARN_MERGE_VOLUNTEER" or "LOC_EFV_WARN_MERGE_EXPEDITIONARY"
	local tooltip = Locale.Lookup("LOC_EFV_ACTION_STATUS") .. "[NEWLINE]" .. Locale.Lookup("LOC_EFV_ACTION_STATUS_TT")
		.. "[NEWLINE][NEWLINE]" .. EFV_UI_StatusTooltip(rec)
	local std = MilitaryFormationTypes ~= nil and MilitaryFormationTypes.STANDARD_FORMATION or nil
	if not isVol and std ~= nil and rec.formation ~= nil and rec.formation ~= std then
		tooltip = tooltip .. "[NEWLINE]" .. Locale.Lookup("LOC_EFV_STATUS_MERGED_SURVIVOR")
	end
	tooltip = tooltip .. "[NEWLINE][NEWLINE][COLOR:Red]" .. Locale.Lookup("LOC_EFV_WARN_MERGE_HEADER")
		.. "[NEWLINE]" .. Locale.Lookup(warnKey) .. "[ENDCOLOR]"
	AddButton(STATUS_ICON, tooltip, false, nil)
	EFV_Log(3, LOG_TAG, "status button id=%s force=%s unit=%s viewer=%s", tostring(rec.id), tostring(rec.forceType),
		tostring(pUnit:GetID()), tostring(localID))
	return nil
end

-- ---------------------------------------------------------------------------
-- Refresh()
-- Rebuilds the buttons for UI.GetHeadSelectedUnit() (local player's view):
-- m_ActionIM:ResetInstances(); untracked unit of the local player with
-- EFV_UnitClass "OK" -> AddSendButtons; tracked unit -> AddRecallButton
-- (VOL sent by local, gated) and AddStatusButton; EFV_ActionStack:
-- CalculateSize(); Attach().
-- Params:  none.
-- Returns: nil.
-- PLAN 3.2. APIs: U06, U02, U07, U12.
-- ---------------------------------------------------------------------------
local function Refresh()
	m_ActionIM:ResetInstances()
	m_Count = 0
	local count = 0
	local localID = Game.GetLocalPlayer()
	local pUnit = UI.GetHeadSelectedUnit()
	if localID ~= nil and localID >= 0 and pUnit ~= nil and pUnit:GetOwner() == localID then
		local uiStore = EFV_UI_ReadStore()
		local rec = EFV_UI_RecordForUnit(localID, pUnit:GetID())
		if rec == nil then
			local okC, status = Try("EFV_UnitClass", EFV_UnitClass, pUnit)
			if okC and status == "OK" then
				AddSendButtons(pUnit, localID, uiStore)
			end
		else
			local st = rec.state
			if Released("RECALL") and rec.forceType == EFV_Config.FT_VOL and rec.senderID == localID
				and (st == EFV_Config.ST_DEPLOYED or st == EFV_Config.ST_GRACE or st == EFV_Config.ST_MUTINY) then
				AddRecallButton(pUnit, rec, Game.GetCurrentGameTurn())
			end
			AddStatusButton(pUnit, rec)
		end
	end
	count = m_Count
	Controls.EFV_ActionStack:SetHide(count == 0)
	Controls.EFV_ActionStack:CalculateSize()
	if count > 0 or m_LastCount > 0 or not m_Attached then
		Attach()
	end
	m_LastCount = count
	return nil
end

-- Refresh handler (U08): batches refresh requests to once per frame.
local function OnRefresh()
	ContextPtr:ClearRequestRefresh()
	local ok, err = pcall(Refresh)
	if not ok then
		EFV_Log(1, LOG_TAG, "Refresh failed: %s", tostring(err))
	end
end

-- Any refresh trigger (PLAN 3.2 event list) just requests a refresh.
local function OnRefreshTrigger()
	ContextPtr:RequestRefresh()
end

-- Unit / turn events carry the player ID first (UnitPanel.lua:2386-2477,
-- 2837, 2957). Only the local player's units can be head-selected with EFV
-- buttons, so other players' events (AI moves) are ignored.
local function OnLocalPlayerTrigger(playerID)
	if playerID == Game.GetLocalPlayer() then
		ContextPtr:RequestRefresh()
	end
end

-- ---------------------------------------------------------------------------
-- Initialize(): event wiring. Events mirror UnitPanel.lua:4249-4266 (U16).
-- Civ VI loads every AddUserInterfaces context HIDDEN (Expansion2
-- InGame.lua:350-352); a hidden context draws nothing and gets no input, so
-- the context is shown here. Button visibility is per instance.
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	ContextPtr:SetRefreshHandler(OnRefresh)

	Events.UnitSelectionChanged.Add(OnRefreshTrigger)
	Events.UnitMoveComplete.Add(OnLocalPlayerTrigger)
	Events.UnitDamageChanged.Add(OnLocalPlayerTrigger)
	Events.UnitMovementPointsChanged.Add(OnLocalPlayerTrigger)
	Events.UnitMovementPointsCleared.Add(OnLocalPlayerTrigger)
	Events.UnitMovementPointsRestored.Add(OnLocalPlayerTrigger)
	Events.UnitPromoted.Add(OnLocalPlayerTrigger)
	Events.UnitCommandStarted.Add(OnLocalPlayerTrigger)
	Events.UnitOperationsCleared.Add(OnLocalPlayerTrigger)
	Events.UnitRemovedFromMap.Add(OnLocalPlayerTrigger)
	Events.PlayerTurnActivated.Add(OnLocalPlayerTrigger)
	Events.LoadGameViewStateDone.Add(OnRefreshTrigger)
	Events.LocalPlayerChanged.Add(OnRefreshTrigger)
	-- D3 / WP5.4: UI hints only (the panel refreshes after a merge). The
	-- record change itself comes from gameplay-side detection at the next
	-- turn boundary (MP rule; Session D 7: these events also fire for
	-- scripted formation changes).
	Events.UnitFormCorps.Add(OnLocalPlayerTrigger)
	Events.UnitFormArmy.Add(OnLocalPlayerTrigger)

	EFV_Log(2, LOG_TAG, "initialized")
end

Initialize()
