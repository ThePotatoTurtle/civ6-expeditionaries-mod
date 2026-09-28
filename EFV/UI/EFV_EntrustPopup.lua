-- ===========================================================================
-- EFV_EntrustPopup.lua
-- Context:  UI, context of EFV_EntrustPopup.xml (AddUserInterfaces InGame).
--           Controls: EFV_EntrustStack (moved into
--           /InGame/RazeCity/PopupStack), EntrustMainButton,
--           EFV_RecipientStack; instance EFV_EntrustButtonInstance
--           (EntrustButton).
-- Owner:    WP6.2 (Phase 6, implemented; INTERFACES note 31).
--
-- Responsibility (PLAN 3.4; spec 12; D1, D5; SPIKES UI-S2, UI-S3; Session F
-- T24): when the capture-decision popup (RazeCity) opens, add an "Entrust..."
-- button under Keep / Raze for the city being decided
-- (GetNextCapturedCity). The button is enabled when the capture-time
-- snapshot (EFV_UI_EntrustState) lists at least one valid recipient;
-- otherwise it is disabled and its tooltip explains why
-- (EFV_UI_EntrustReasonsText). A click opens the recipient picker below it:
-- one "Entrust to [Civ]" button per recipient. The first click on a
-- recipient arms it ("Click again to entrust to [Civ]"), the second click
-- sends (two-click confirm, PLAN 3.4 fallback: a PopupDialog over RazeCity
-- was never tested, the injected buttons were).
--
-- Send (D5): CityManager.RequestCommand(city, DESTROY, KEEP) when
-- FLAG_ENTRUST_KEEP_FIRST (resolves the capture decision and its end-turn
-- blocker), then EFV_UI_Request("EFV_Entrust", { x, y, recipientID }), then
-- close RazeCity (UIManager:DequeuePopup of /InGame/RazeCity; Session F: it
-- returns true). Gameplay re-validates everything (EFV_Entrust); if it
-- refuses, the city stays the capturer's and REQUEST_FAILED says why.
--
-- Pending decision: closing the popup without a choice (X / Esc) leaves the
-- engine's capture notification and end-turn blocker in place; the
-- notification reopens RazeCity and this context rebuilds (armed state and
-- picker reset on every open). The AI never sees this popup.
-- ===========================================================================

include("InstanceManager")
include("EFV_UIShared")

local LOG_TAG = "UIEntrust"
local RAZE_STACK_PATH = "/InGame/RazeCity/PopupStack"
local RAZE_WINDOW_PATH = "/InGame/RazeCity/RazeCityWindow"
local RAZE_CONTEXT_PATH = "/InGame/RazeCity"

-- Recipient picker rows (U12), built in our own stack (same context).
local m_ButtonIM = InstanceManager:new("EFV_EntrustButtonInstance", "EntrustButton", Controls.EFV_RecipientStack)

-- Popup state for the city being decided; reset on every open.
local m_X, m_Y = nil, nil       -- captured city plot
local m_CityName = ""
local m_Expanded = false        -- recipient picker open
local m_Armed = nil             -- recipient ID waiting for the confirming click
local m_Sent = false            -- request sent for this opening

local function L(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function() return Locale.Lookup(key, unpack(args, 1, n)) end)
	if ok and type(s) == "string" then
		return s
	end
	return tostring(key)
end

local function LocalID()
	local ok, pid = pcall(function() return Game.GetLocalPlayer() end)
	if ok and type(pid) == "number" then
		return pid
	end
	return -1
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
-- Relayout()
-- Recomputes the injected stacks and the RazeCity layout after a change
-- (open, picker opened or closed). DoAutoSize on the popup window is
-- best-effort (pcall).
-- APIs: U07, ReprocessAnchoring, DoAutoSize.
-- ---------------------------------------------------------------------------
local function Relayout()
	pcall(function()
		Controls.EFV_RecipientStack:CalculateSize()
		Controls.EFV_EntrustStack:CalculateSize()
	end)
	local stack = ContextPtr:LookUpControl(RAZE_STACK_PATH)
	if stack ~= nil then
		pcall(function()
			stack:CalculateSize()
			stack:ReprocessAnchoring()
		end)
	end
	local window = ContextPtr:LookUpControl(RAZE_WINDOW_PATH)
	if window ~= nil then
		pcall(function() window:DoAutoSize() end)
	end
end

-- ---------------------------------------------------------------------------
-- ResetInjected()
-- Hides the injected stack and removes the recipient rows.
-- APIs: U12.
-- ---------------------------------------------------------------------------
local function ResetInjected()
	m_ButtonIM:ResetInstances()
	Controls.EFV_RecipientStack:SetHide(true)
	Controls.EFV_EntrustStack:SetHide(true)
	return nil
end

-- ---------------------------------------------------------------------------
-- CloseRazeCity()
-- UIManager:DequeuePopup(ContextPtr:LookUpControl("/InGame/RazeCity"))
-- (Session F T24: ok=true, return=true).
-- APIs: U09, U07.
-- ---------------------------------------------------------------------------
local function CloseRazeCity()
	local ctx = ContextPtr:LookUpControl(RAZE_CONTEXT_PATH)
	if ctx == nil then
		EFV_Log(1, LOG_TAG, "LookUpControl(%s) returned nil; popup left open", RAZE_CONTEXT_PATH)
		return nil
	end
	local ok, ret = pcall(function() return UIManager:DequeuePopup(ctx) end)
	EFV_Log(2, LOG_TAG, "RazeCity dequeued ok=%s ret=%s", tostring(ok), tostring(ret))
	return nil
end

-- ---------------------------------------------------------------------------
-- SendEntrust(recipientID)
-- D5 order: KEEP (if FLAG_ENTRUST_KEEP_FIRST and the engine accepts it),
-- then the EFV_Entrust request, then close RazeCity.
-- APIs: U03, U01 (via EFV_UI_Request), A44.
-- ---------------------------------------------------------------------------
local function SendEntrust(recipientID)
	local localID = LocalID()
	local pCity = CityManager.GetCityAt(m_X, m_Y)
	if pCity == nil or pCity:GetOwner() ~= localID then
		EFV_Log(1, LOG_TAG, "send: no city of player %d at %s,%s", localID, tostring(m_X), tostring(m_Y))
		return nil
	end
	if EFV_Config.FLAG_ENTRUST_KEEP_FIRST then
		local tParams = {}
		tParams[UnitOperationTypes.PARAM_FLAGS] = CityDestroyDirectives.KEEP
		local okC, can = pcall(function() return CityManager.CanStartCommand(pCity, CityCommandTypes.DESTROY, tParams) end)
		if okC and can then
			local okR, errR = pcall(function() CityManager.RequestCommand(pCity, CityCommandTypes.DESTROY, tParams) end)
			EFV_Log(2, LOG_TAG, "KEEP sent ok=%s%s", tostring(okR), okR and "" or (" err=" .. tostring(errR)))
		else
			EFV_Log(2, LOG_TAG, "KEEP not available (ok=%s can=%s); sending the transfer request anyway (T16)",
				tostring(okC), tostring(can))
		end
	end
	EFV_UI_Request(EFV_Config.REQ_ENTRUST, { x = m_X, y = m_Y, recipientID = recipientID })
	m_Sent = true
	m_Expanded = false
	m_Armed = nil
	ResetInjected()
	CloseRazeCity()
	return nil
end

local Render

-- ---------------------------------------------------------------------------
-- ConfirmEntrust(recipientID)
-- Two-click confirm: the first click arms the row, the second sends. The
-- state is re-read first, so a recipient that became invalid is refused.
-- ---------------------------------------------------------------------------
local function ConfirmEntrust(recipientID)
	if m_Sent then
		return nil
	end
	local st = EFV_UI_EntrustState(LocalID(), m_X, m_Y)
	local valid = false
	for _, row in ipairs(st.rows) do
		if row.recipientID == recipientID and #row.codes == 0 then
			valid = true
		end
	end
	if #st.codes > 0 or not valid then
		EFV_Log(2, LOG_TAG, "recipient %s no longer valid; picker rebuilt", tostring(recipientID))
		m_Armed = nil
		Render()
		return nil
	end
	if m_Armed ~= recipientID then
		m_Armed = recipientID
		Render()
		return nil
	end
	EFV_Log(2, LOG_TAG, "confirmed: entrust %s,%s to %d", tostring(m_X), tostring(m_Y), recipientID)
	SendEntrust(recipientID)
	return nil
end

-- ---------------------------------------------------------------------------
-- OnMainButton()
-- Opens / closes the recipient picker (disabled button: nothing).
-- ---------------------------------------------------------------------------
local function OnMainButton()
	if m_Sent or Controls.EntrustMainButton:IsDisabled() then
		return nil
	end
	m_Expanded = not m_Expanded
	m_Armed = nil
	Render()
	return nil
end

-- ---------------------------------------------------------------------------
-- InjectButtons(st) (= Render)
-- Main button: enabled "Entrust..." with LOC_EFV_ENTRUST_TT (+ who can
-- receive it) when st has no option-level codes; else disabled
-- ("Entrust (no eligible partner)" for ENTRUST_NO_PARTNER, "Entrust (not
-- available)" otherwise) with the reasons. Picker rows when expanded.
-- APIs: U12, U17.
-- ---------------------------------------------------------------------------
Render = function()
	local st = EFV_UI_EntrustState(LocalID(), m_X, m_Y)
	local main = Controls.EntrustMainButton
	m_ButtonIM:ResetInstances()
	if #st.codes > 0 then
		m_Expanded = false
		m_Armed = nil
		main:SetDisabled(true)
		if st.codes[1] == "ENTRUST_NO_PARTNER" then
			main:SetText(L("LOC_EFV_ENTRUST_DISABLED_NO_PARTNER"))
		else
			main:SetText(L("LOC_EFV_ENTRUST_DISABLED"))
		end
		main:SetToolTipString(L("LOC_EFV_ENTRUST_TT_DISABLED") .. EFV_UI_EntrustReasonsText(st))
	else
		main:SetDisabled(false)
		main:SetText(L("LOC_EFV_ENTRUST_HEADER"))
		local names = {}
		for _, row in ipairs(st.rows) do
			if #row.codes == 0 then
				names[#names + 1] = row.name
			end
		end
		main:SetToolTipString(L("LOC_EFV_ENTRUST_TT") .. "[NEWLINE][NEWLINE]" ..
			L("LOC_EFV_ENTRUST_TT_RECIPIENTS", table.concat(names, ", ")))
	end
	if m_Expanded then
		for _, row in ipairs(st.rows) do
			local inst = m_ButtonIM:GetInstance()
			local btn = inst.EntrustButton
			local rid = row.recipientID
			if #row.codes > 0 then
				btn:SetText(L("LOC_EFV_ENTRUST_TO", row.name))
				btn:SetDisabled(true)
				btn:SetToolTipString(StripLeadingNewline(EFV_UI_ReasonsText(row.codes)))
			elseif m_Armed == rid then
				btn:SetText(L("LOC_EFV_ENTRUST_CONFIRM_BUTTON", row.name))
				btn:SetDisabled(false)
				btn:SetToolTipString(L("LOC_EFV_ENTRUST_CONFIRM", m_CityName, row.name))
			else
				btn:SetText(L("LOC_EFV_ENTRUST_TO", row.name))
				btn:SetDisabled(false)
				btn:SetToolTipString(L("LOC_EFV_ENTRUST_TO_TT", m_CityName, row.name))
			end
			btn:RegisterCallback(Mouse.eLClick, function() ConfirmEntrust(rid) end)
		end
	end
	Controls.EFV_RecipientStack:SetHide(not m_Expanded)
	Controls.EFV_EntrustStack:SetHide(false)
	Relayout()
	EFV_Log(3, LOG_TAG, "render at=%s,%s codes=%s rows=%d enabled=%d expanded=%s armed=%s",
		tostring(m_X), tostring(m_Y), table.concat(st.codes, ","), #st.rows, st.enabled,
		tostring(m_Expanded), tostring(m_Armed))
	return nil
end

-- ---------------------------------------------------------------------------
-- OnOpenRazeCityChooser()
-- Handler of LuaEvents.NotificationPanel_OpenRazeCityChooser (U05; the same
-- event opens RazeCity, RazeCity.lua:172; order between the two handlers
-- does not matter, this one only adds children): only when FLAG_ENTRUST_UI
-- == "INJECT". city = Players[local]:GetCities():GetNextCapturedCity()
-- (U04); moves EFV_EntrustStack into RazeCity's PopupStack; resets the
-- picker; Render().
-- APIs: U05, U04, U02, U07.
-- ---------------------------------------------------------------------------
local function OnOpenRazeCityChooser()
	if EFV_Config.FLAG_ENTRUST_UI ~= "INJECT" then
		return nil
	end
	local ok, err = pcall(function()
		ResetInjected()
		m_Expanded, m_Armed, m_Sent = false, nil, false
		local localID = LocalID()
		local pPlayer = Players[localID]
		local pCity = nil
		if pPlayer ~= nil then
			pCity = pPlayer:GetCities():GetNextCapturedCity()
		end
		if pCity == nil then
			EFV_Log(2, LOG_TAG, "capture popup opened but no captured city pending; no Entrust button")
			return
		end
		m_X, m_Y = pCity:GetX(), pCity:GetY()
		m_CityName = EFV_CityName(pCity)
		local stack = ContextPtr:LookUpControl(RAZE_STACK_PATH)
		if stack == nil then
			EFV_Log(1, LOG_TAG, "LookUpControl(%s) returned nil; no Entrust button (E2 fallback needed)", RAZE_STACK_PATH)
			return
		end
		Controls.EFV_EntrustStack:ChangeParent(stack)
		Render()
		EFV_Log(2, LOG_TAG, "Entrust injected for %s at=%d,%d", m_CityName, m_X, m_Y)
	end)
	if not ok then
		EFV_Log(1, LOG_TAG, "OnOpenRazeCityChooser failed: %s", tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Initialize(): event wiring.
-- Civ VI loads every AddUserInterfaces context HIDDEN (Expansion2
-- InGame.lua:350-352); a hidden context draws nothing and gets no input, so
-- the context is shown here (it has no visible controls of its own; the
-- stack starts hidden and lives inside RazeCity once injected).
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	Controls.EntrustMainButton:RegisterCallback(Mouse.eLClick, OnMainButton)
	LuaEvents.NotificationPanel_OpenRazeCityChooser.Add(OnOpenRazeCityChooser)
	EFV_Log(2, LOG_TAG, "initialized")
end

Initialize()
