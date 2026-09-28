-- ===========================================================================
-- EFV_Tracker.lua
-- Context:  UI, context of EFV_Tracker.xml (AddUserInterfaces InGame).
--           Controls: AlertBanner (BannerButton, BannerLabel), TrackerPanel
--           (TrackerWindow, TrackerTitle, TrackerCloseButton, TrackerHeader,
--           TrackerScroll, TrackerStack, TrackerEmptyLabel, TrackerSummary);
--           instances EFV_TrackerRowInstance (RowButton, AlertHighlight,
--           UnitLabel, PartnerLabel, ForceLabel, StateLabel, TurnsLabel,
--           PlaceLabel), LaunchBarItem (LaunchItemButton, LaunchItemLabel,
--           AlertIndicator), LaunchBarPinInstance (Pin).
-- Owner:    WP2.2 (D9 alerts: banner with camera cycling, alert sound,
--           stale-copy dismissal), WP7.2 (launch-bar button, full panel).
--
-- Responsibility (PLAN 3.6; spec 14.5; D9) for the LOCAL player:
--   * launch-bar button "VEF" (/InGame/LaunchBar/ButtonStack, attached once
--     on LoadGameViewStateDone): opens / closes the panel; its AlertIndicator
--     shows while any record is in GRACE / MUTINY; tooltip = counts;
--   * panel: every record of the local player, sent and received
--     (EFV_UI_TrackerRows): unit, partner ("To X" / "From X"), force type,
--     short state (Outbound / Deployed / Service ended / Grace / Mutiny /
--     Lapse: .. / Returning / Blocked), turns remaining, destination or
--     return city for units in transit; GRACE / MUTINY rows first, red text
--     on a red highlight (D9); row tooltip = status tooltip + click hint;
--     summary line (sent / received / must return). Row click: own unit on
--     the map -> UI.SelectUnit + UI.LookAtPlot; partner-owned unit -> camera
--     only, and only when the tile is visible; in transit -> camera on the
--     destination / return city when revealed. The panel closes when the
--     camera moved. ESC and the close button close it;
--   * refresh: on the PLAN 3.6 events and, while the panel is open, a poll of
--     (EFV_Rev, turn) every POLL_SECONDS (ContextPtr:SetUpdate); rebuilds
--     are skipped while (EFV_Rev, turn) is unchanged;
--   * D9 banner (top centre) while any record is in GRACE or MUTINY: "EFV: N
--     unit(s) must return - M in mutiny"; left click cycles the camera
--     through those units (MUTINY first); right click opens / closes the
--     panel;
--   * "ALERT_NEGATIVE" sound when an EFV GRACE / MUTINY / MUTINY_DEATH /
--     VOLUNTEER_LAPSE / ACCESS_LAPSE notification arrives for the local
--     player (at most once per turn);
--   * stale-copy dismissal (T21: AlwaysUnique copies stack): for the local
--     player, GRACE / MUTINY notifications are grouped by data EFV_RecordID;
--     only the newest copy of a record that is still in GRACE / MUTINY stays,
--     every other copy (older turns, returned / dead / closed records) is
--     dismissed. LAPSE_PAUSED copies (0.5.1, note 29) likewise, kept only
--     while that record's lapse is still paused (rec.lapsePaused == 1).
--     While paused, gameplay re-sends no GRACE / MUTINY, so the last copy
--     (its count is frozen too) stays next to the paused notice; the record
--     stays in the banner (the Volunteer still has to be recalled). UI NotificationManager.Dismiss is deferred (Session A T21):
--     never verified in the same call;
--   * map focus on the unit: gameplay sends GRACE / MUTINY / MUTINY_DEATH
--     with AlwaysAutoActivate and a LOCATION (EFV_Notify).
-- ===========================================================================

include("InstanceManager")
include("EFV_UIShared")

local LOG_TAG = "UITracker"
local POLL_SECONDS = 0.5        -- (EFV_Rev, turn) poll interval while the panel is open

-- Row instance manager (U12).
local m_RowIM = InstanceManager:new("EFV_TrackerRowInstance", "RowButton", Controls.TrackerStack)
local m_LaunchAttached = false  -- double-attach guard (R4 5.1 step 4)
local m_LaunchInst = nil        -- LaunchBarItem instance (WP7.2)
local m_LastRev = -1            -- EFV_Rev of the last list rebuild
local m_LastTurn = -1           -- turn of the last list rebuild
local m_AlertCycleIndex = 0     -- banner camera-cycling position
local m_PanelOpen = false       -- TrackerPanel open flag (never ContextPtr:IsHidden, note 19)
local m_LastSoundTurn = -1      -- alert sound at most once per turn
local m_PollElapsed = 0         -- seconds since the last poll
-- false until Events.LoadGameViewStateDone: on load the engine replays
-- NotificationAdded for every persisted notification BEFORE that event
-- (Session A T21), so replays must not play the alert sound or dismiss
-- anything (SESSION_A_REPORT 5).
local m_ViewReady = false

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------
local function LocalPlayer()
	local ok, pid = pcall(function() return Game.GetLocalPlayer() end)
	if ok and type(pid) == "number" then
		return pid
	end
	return -1
end

local function CurrentTurn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

local function L(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function() return Locale.Lookup(key, unpack(args, 1, n)) end)
	if ok and type(s) == "string" then
		return s
	end
	return tostring(key)
end

-- Type hashes of the EFV alert notifications (GameInfo.Types, U16).
local m_Hash = nil
local function Hashes()
	if m_Hash ~= nil then
		return m_Hash
	end
	local h = {}
	for _, name in ipairs({ "GRACE", "MUTINY", "MUTINY_DEATH", "VOLUNTEER_LAPSE", "ACCESS_LAPSE", "LAPSE_PAUSED" }) do
		local typeName = EFV_Config.NOTIF[name]
		local row = typeName and GameInfo.Types[typeName] or nil
		h[name] = row and row.Hash or nil
	end
	m_Hash = h
	return h
end

-- Alert records of the local player, MUTINY first, then GRACE; ascending id
-- inside each group (the same order as the panel rows and the banner cycle).
local function SortedAlerts(localID)
	local mutiny, grace = {}, {}
	for _, rec in ipairs(EFV_UI_AlertRecords(localID)) do
		if rec.state == EFV_Config.ST_MUTINY then
			mutiny[#mutiny + 1] = rec
		else
			grace[#grace + 1] = rec
		end
	end
	for _, rec in ipairs(grace) do
		mutiny[#mutiny + 1] = rec
	end
	return mutiny
end

local function UnitText(rec)
	local name = ""
	pcall(function() name = EFV_UnitDisplayName(rec.unitType, rec.veteranName) or "" end)
	return name
end

local function Red(s)
	return "[COLOR:Red]" .. tostring(s) .. "[ENDCOLOR]"
end

-- ---------------------------------------------------------------------------
-- RealizeLaunchBacking()
-- ButtonStack:CalculateSize(); LaunchBacking:SetSizeX(w + 116);
-- LaunchBackingTile:SetSizeX(w - 20); LuaEvents.LaunchBar_Resize(w)
-- (LaunchBar.lua:498-517 math; the spike panel's launch button uses the
-- same calls in game).
-- Params:  none.
-- Returns: true on success, false (logged) otherwise.
-- PLAN 3.6; R4 5.1 step 3. APIs: U07, U13.
-- ---------------------------------------------------------------------------
local function RealizeLaunchBacking()
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		buttonStack:CalculateSize()
		local w = buttonStack:GetSizeX()
		ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking"):SetSizeX(w + 116)
		ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile"):SetSizeX(w - 20)
		LuaEvents.LaunchBar_Resize(w)
	end)
	if not ok then
		EFV_Log(1, LOG_TAG, "launch bar resize failed: %s", tostring(err))
	end
	return ok
end

local TogglePanel -- forward

-- ---------------------------------------------------------------------------
-- AttachLaunchButton()
-- Once (m_LaunchAttached guard): ContextPtr:BuildInstanceForControl(
-- "LaunchBarItem", inst, /InGame/LaunchBar/ButtonStack) and
-- "LaunchBarPinInstance"; click -> TogglePanel; then RealizeLaunchBacking().
-- A failure is logged once; the banner's right click still opens the panel.
-- Params:  none.
-- Returns: nil.
-- PLAN 3.6; R4 5.1. APIs: U07, U13.
-- ---------------------------------------------------------------------------
local function AttachLaunchButton()
	if m_LaunchAttached then
		return nil
	end
	m_LaunchAttached = true
	local inst = {}
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		ContextPtr:BuildInstanceForControl("LaunchBarItem", inst, buttonStack)
		inst.LaunchItemButton:RegisterCallback(Mouse.eLClick, function() TogglePanel() end)
		ContextPtr:BuildInstanceForControl("LaunchBarPinInstance", {}, buttonStack)
	end)
	if ok then
		m_LaunchInst = inst
		RealizeLaunchBacking()
		EFV_Log(2, LOG_TAG, "launch bar button attached")
	else
		EFV_Log(1, LOG_TAG, "launch bar button attach failed (the banner right click still opens the list): %s", tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- FocusRecord(rec)
-- Unit on the map (identity-checked) and owned by the local player ->
-- UI.SelectUnit + UI.LookAtPlot; a unit of another owner -> camera only
-- (UI.LookAtPlotScreenPosition), and only when the tile is visible to the
-- local player (PlayersVisibility[local]:IsVisible); in transit (OUTBOUND /
-- RETURNING) -> camera on the destination / return city when it is revealed.
-- A missing unit falls back to its last known position (lastX / lastY).
-- Closes the panel when the camera moved. Used by rows and the banner.
-- Params:  rec record.
-- Returns: true if the camera moved, else false.
-- PLAN 3.6; spec 14.5. APIs: U06, A17, A59.
-- ---------------------------------------------------------------------------
local ClosePanel -- forward

local function FocusRecord(rec)
	if rec == nil then
		return false
	end
	local localID = LocalPlayer()
	local moved = false
	if rec.state == EFV_Config.ST_OUTBOUND or rec.state == EFV_Config.ST_RETURNING then
		local x, y = rec.destX, rec.destY
		if rec.state == EFV_Config.ST_RETURNING then
			x, y = rec.returnX, rec.returnY
		end
		if type(x) == "number" and type(y) == "number" then
			local revealed = false
			pcall(function() revealed = PlayersVisibility[localID]:IsRevealed(x, y) == true end)
			if revealed then
				moved = pcall(function() UI.LookAtPlotScreenPosition(x, y, 0.5, 0.5) end)
			end
			EFV_Log(3, LOG_TAG, "focus id=%s in transit city at=%d,%d revealed=%s", tostring(rec.id), x, y, tostring(revealed))
		else
			EFV_Log(2, LOG_TAG, "focus id=%s in transit: no city position", tostring(rec.id))
		end
	else
		local pUnit = EFV_UI_TrackedUnit(rec)
		local x, y = rec.lastX, rec.lastY
		if pUnit ~= nil then
			x, y = pUnit:GetX(), pUnit:GetY()
		end
		if type(x) ~= "number" or type(y) ~= "number" then
			EFV_Log(2, LOG_TAG, "focus id=%s: no position", tostring(rec.id))
		elseif pUnit ~= nil and pUnit:GetOwner() == localID then
			local ok, err = pcall(function()
				UI.SelectUnit(pUnit)
				UI.LookAtPlot(x, y)
			end)
			moved = ok
			EFV_Log(3, LOG_TAG, "focus id=%s own unit at=%d,%d ok=%s %s", tostring(rec.id), x, y, tostring(ok), ok and "" or tostring(err))
		else
			local visible = false
			pcall(function()
				visible = PlayersVisibility[localID]:IsVisible(x, y) == true
			end)
			if visible then
				local ok, err = pcall(function() UI.LookAtPlotScreenPosition(x, y, 0.5, 0.5) end)
				moved = ok
				EFV_Log(3, LOG_TAG, "focus id=%s look at=%d,%d ok=%s %s", tostring(rec.id), x, y, tostring(ok), ok and "" or tostring(err))
			else
				EFV_Log(3, LOG_TAG, "focus id=%s at=%d,%d not visible", tostring(rec.id), x, y)
			end
		end
	end
	if moved and m_PanelOpen then
		ClosePanel()
	end
	return moved
end

-- ---------------------------------------------------------------------------
-- RefreshLaunchButton(sent, received, alerts)
-- AlertIndicator shown while alerts > 0 (D9); tooltip = title + counts.
-- ---------------------------------------------------------------------------
local function RefreshLaunchButton(sent, received, alerts)
	if m_LaunchInst == nil then
		return nil
	end
	pcall(function()
		m_LaunchInst.AlertIndicator:SetHide(alerts == 0)
		m_LaunchInst.LaunchItemButton:SetToolTipString(L("LOC_EFV_TRACKER_TITLE") .. "[NEWLINE]"
			.. L("LOC_EFV_TRACKER_SUMMARY", sent, received, alerts))
	end)
	return nil
end

-- ---------------------------------------------------------------------------
-- RefreshPanel(force)
-- If the panel is open and (force or (EFV_Rev, turn) changed): rebuild rows
-- from EFV_UI_TrackerRows(local) (sorted: MUTINY, GRACE, DEPLOYED, OUTBOUND,
-- RETURNING); GRACE / MUTINY rows red with AlertHighlight shown (D9); row
-- click -> FocusRecord. Empty -> TrackerEmptyLabel. Summary line
-- LOC_EFV_TRACKER_SUMMARY {sent, received, must return}.
-- Params:  force boolean (true = ignore the EFV_Rev check).
-- Returns: nil.
-- PLAN 3.6; spec 14.5; D9. APIs: U12, U07, U17.
-- ---------------------------------------------------------------------------
local function RefreshPanel(force)
	if not m_PanelOpen then
		return nil
	end
	local store = EFV_UI_ReadStore()
	local turn = CurrentTurn()
	if not force and store.rev == m_LastRev and turn == m_LastTurn then
		return nil
	end
	m_LastRev, m_LastTurn = store.rev, turn
	local localID = LocalPlayer()
	local rows = EFV_UI_TrackerRows(localID, turn)
	m_RowIM:ResetInstances()
	for _, row in ipairs(rows) do
		local inst = m_RowIM:GetInstance()
		local cells = { row.unit, row.partner, row.force, row.state, row.turnsText, row.place }
		if row.alert ~= nil then
			for i = 1, #cells do
				cells[i] = Red(cells[i])
			end
		end
		inst.UnitLabel:SetText(cells[1])
		inst.PartnerLabel:SetText(cells[2])
		inst.ForceLabel:SetText(cells[3])
		inst.StateLabel:SetText(cells[4])
		inst.TurnsLabel:SetText(cells[5])
		inst.PlaceLabel:SetText(cells[6])
		inst.AlertHighlight:SetHide(row.alert == nil)
		inst.RowButton:SetToolTipString(row.tooltip)
		local target = row.rec
		inst.RowButton:RegisterCallback(Mouse.eLClick, function() FocusRecord(target) end)
	end
	local sent, received, alerts = EFV_UI_TrackerCounts(localID)
	Controls.TrackerSummary:SetText(L("LOC_EFV_TRACKER_SUMMARY", sent, received, alerts))
	Controls.TrackerEmptyLabel:SetHide(#rows > 0)
	Controls.TrackerStack:CalculateSize()
	Controls.TrackerScroll:CalculateSize()
	EFV_Log(3, LOG_TAG, "list rows=%d rev=%s turn=%s", #rows, tostring(store.rev), tostring(turn))
	return nil
end

-- ---------------------------------------------------------------------------
-- RefreshAlerts()
-- alerts = EFV_UI_AlertRecords(local): AlertBanner shown with
-- LOC_EFV_BANNER_ALERT {N, M} (N units in grace or mutiny, M in mutiny) and
-- a tooltip listing the units, hidden when N == 0. The launch-bar
-- AlertIndicator and tooltip follow (RefreshLaunchButton).
-- Params:  none.
-- Returns: nil.
-- PLAN 3.6; D9. APIs: U07, U17.
-- ---------------------------------------------------------------------------
local function RefreshAlerts()
	local localID = LocalPlayer()
	local alerts = SortedAlerts(localID)
	local n, m = #alerts, 0
	local lines = {}
	for _, rec in ipairs(alerts) do
		if rec.state == EFV_Config.ST_MUTINY then
			m = m + 1
		end
		lines[#lines + 1] = L("LOC_EFV_BANNER_TT_LINE", UnitText(rec), EFV_UI_StateText(rec, CurrentTurn()))
	end
	if n > 0 then
		Controls.BannerLabel:SetText(L("LOC_EFV_BANNER_ALERT", n, m))
		Controls.BannerButton:SetToolTipString(table.concat(lines, "[NEWLINE]") .. "[NEWLINE][NEWLINE]" .. L("LOC_EFV_BANNER_ALERT_TT"))
	end
	Controls.AlertBanner:SetHide(n == 0)
	local sent, received = EFV_UI_TrackerCounts(localID)
	RefreshLaunchButton(sent, received, n)
	if m_AlertCycleIndex > n then
		m_AlertCycleIndex = 0
	end
	EFV_Log(3, LOG_TAG, "alerts n=%d mutiny=%d", n, m)
	return nil
end

-- ---------------------------------------------------------------------------
-- OnUpdate(fDTime)
-- While the panel is open: every POLL_SECONDS, RefreshPanel(false) (a
-- rebuild only when EFV_Rev or the turn changed) and RefreshAlerts when it
-- rebuilt. Installed by OpenPanel, removed by ClosePanel.
-- APIs: ContextPtr:SetUpdate / ClearUpdate (harvested base UI).
-- ---------------------------------------------------------------------------
local function OnUpdate(fDTime)
	m_PollElapsed = m_PollElapsed + (tonumber(fDTime) or 0)
	if m_PollElapsed < POLL_SECONDS then
		return
	end
	m_PollElapsed = 0
	local rev, turn = m_LastRev, m_LastTurn
	RefreshPanel(false)
	if m_LastRev ~= rev or m_LastTurn ~= turn then
		RefreshAlerts()
	end
end

-- ---------------------------------------------------------------------------
-- OpenPanel() / ClosePanel() / TogglePanel()
-- Show / hide TrackerPanel (sounds UI_Screen_Open / UI_Screen_Close);
-- opening forces RefreshPanel(true) and starts the (EFV_Rev, turn) poll.
-- Params:  none.
-- Returns: nil.
-- PLAN 3.6. APIs: U07, U18.
-- ---------------------------------------------------------------------------
local function OpenPanel()
	ContextPtr:SetHide(false)
	m_PanelOpen = true
	Controls.TrackerPanel:SetHide(false)
	pcall(function() UI.PlaySound("UI_Screen_Open") end)
	RefreshPanel(true)
	m_PollElapsed = 0
	ContextPtr:SetUpdate(OnUpdate)
	return nil
end

ClosePanel = function()
	if not m_PanelOpen then
		return nil
	end
	m_PanelOpen = false
	ContextPtr:ClearUpdate()
	Controls.TrackerPanel:SetHide(true)
	pcall(function() UI.PlaySound("UI_Screen_Close") end)
	return nil
end

TogglePanel = function()
	if m_PanelOpen then
		ClosePanel()
	else
		OpenPanel()
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- OnBannerClicked()
-- Cycles m_AlertCycleIndex through the local player's alert records
-- (MUTINY first) and focuses the next one.
-- Params:  none.
-- Returns: nil.
-- PLAN 3.6; D9. APIs: via FocusRecord.
-- ---------------------------------------------------------------------------
local function OnBannerClicked()
	local alerts = SortedAlerts(LocalPlayer())
	if #alerts == 0 then
		RefreshAlerts()
		return nil
	end
	m_AlertCycleIndex = (m_AlertCycleIndex % #alerts) + 1
	local rec = alerts[m_AlertCycleIndex]
	EFV_Log(3, LOG_TAG, "banner cycle %d/%d id=%s", m_AlertCycleIndex, #alerts, tostring(rec.id))
	FocusRecord(rec)
	return nil
end

-- ---------------------------------------------------------------------------
-- SweepStale(localID)
-- D9 stale-copy dismissal. Reads the local player's notifications; groups
-- EFV GRACE / MUTINY copies by GetValue("EFV_RecordID"); keeps only the
-- newest copy (highest EFV_Turn, then highest ID) of a record that is still
-- in GRACE / MUTINY for the local player; dismisses every other copy.
-- LAPSE_PAUSED copies form their own group per record and are kept (newest
-- only) while the record's lapse is still paused (note 29).
-- Copies without a readable EFV_RecordID are left alone.
-- Params:  localID player ID.
-- Returns: number of Dismiss calls.
-- PLAN 3.6; D9; T21. APIs: U15, A51.
-- ---------------------------------------------------------------------------
local function SweepStale(localID)
	if localID == nil or localID < 0 then
		return 0
	end
	local h = Hashes()
	if h.GRACE == nil and h.MUTINY == nil then
		return 0
	end
	local live, livePaused = {}, {}
	for _, rec in ipairs(EFV_UI_AlertRecords(localID)) do
		live[rec.id] = true
		if rec.lapsed == 1 and rec.lapsePaused == 1 then
			livePaused[rec.id] = true
		end
	end
	local entries, newest = {}, {}
	local okList, list = pcall(function() return NotificationManager.GetList(localID) end)
	if not okList or type(list) ~= "table" then
		return 0
	end
	for _, nid in ipairs(list) do
		pcall(function()
			local p = NotificationManager.Find(localID, nid)
			if p == nil then
				return
			end
			local t = p:GetType()
			local paused = (h.LAPSE_PAUSED ~= nil and t == h.LAPSE_PAUSED)
			if t ~= h.GRACE and t ~= h.MUTINY and not paused then
				return
			end
			local rid = p:GetValue("EFV_RecordID")
			if type(rid) ~= "number" then
				return
			end
			local key = (paused and "P" or "A") .. tostring(rid)
			local e = { nid = nid, rid = rid, key = key, paused = paused,
				turn = tonumber(p:GetValue("EFV_Turn")) or -1 }
			entries[#entries + 1] = e
			local best = newest[key]
			if best == nil or e.turn > best.turn or (e.turn == best.turn and e.nid > best.nid) then
				newest[key] = e
			end
		end)
	end
	local dismissed = 0
	for _, e in ipairs(entries) do
		local alive = e.paused and livePaused[e.rid] or (not e.paused and live[e.rid])
		if not (alive and newest[e.key] == e) then
			local ok = pcall(function() NotificationManager.Dismiss(localID, e.nid) end)
			if ok then
				dismissed = dismissed + 1
			end
			EFV_Log(3, LOG_TAG, "dismiss stale id=%s rec=%s turn=%s live=%s", tostring(e.nid), tostring(e.rid),
				tostring(e.turn), tostring(live[e.rid] == true))
		end
	end
	return dismissed
end

-- ---------------------------------------------------------------------------
-- OnNotificationAdded(pid, nid)
-- Local player only, after LoadGameViewStateDone: pNotif =
-- NotificationManager.Find(pid, nid); type hash of EFV_NOTIF_GRACE / _MUTINY
-- / _MUTINY_DEATH -> UI.PlaySound("ALERT_NEGATIVE") (NotificationPanel.lua:
-- 242; once per turn), then SweepStale (older copies of the same record,
-- copies of closed records). Then RefreshAlerts / RefreshPanel.
-- Params:  pid player ID, nid notification ID.
-- Returns: nil.
-- PLAN 3.6; D9; T21. APIs: U15, U18, U16, A51.
-- ---------------------------------------------------------------------------
local function OnNotificationAdded(pid, nid)
	if not m_ViewReady then
		EFV_Log(3, LOG_TAG, "NotificationAdded replay ignored pid=%s id=%s (before LoadGameViewStateDone)",
			tostring(pid), tostring(nid))
		return nil
	end
	local localID = LocalPlayer()
	if pid ~= localID then
		return nil
	end
	local t = nil
	pcall(function()
		local p = NotificationManager.Find(pid, nid)
		if p ~= nil then
			t = p:GetType()
		end
	end)
	local h = Hashes()
	if t ~= nil and (t == h.GRACE or t == h.MUTINY or t == h.MUTINY_DEATH
			or t == h.VOLUNTEER_LAPSE or t == h.ACCESS_LAPSE) then
		local turn = CurrentTurn()
		if m_LastSoundTurn ~= turn then
			m_LastSoundTurn = turn
			pcall(function() UI.PlaySound("ALERT_NEGATIVE") end)
			EFV_Log(3, LOG_TAG, "alert sound id=%s", tostring(nid))
		end
		SweepStale(localID)
	elseif t ~= nil and h.LAPSE_PAUSED ~= nil and t == h.LAPSE_PAUSED then
		-- Paused lapse (note 29): no alert sound, only the older-copy sweep.
		SweepStale(localID)
	end
	RefreshAlerts()
	RefreshPanel(false)
	return nil
end

-- Generic refresh trigger (PLAN 3.6 event list).
local function OnRefreshTrigger()
	RefreshAlerts()
	RefreshPanel(false)
end

-- Turn activation of the local player: also sweep stale copies (a record
-- that returned or died leaves ExpiresEndOfTurn=0 copies behind).
local function OnPlayerTurnActivated(pid, isFirstTime)
	if m_ViewReady and pid == LocalPlayer() then
		SweepStale(pid)
	end
	OnRefreshTrigger()
end

-- LoadGameViewStateDone: attach the launch button, sweep, then rebuild.
local function OnLoadGameViewStateDone()
	m_ViewReady = true
	AttachLaunchButton()
	SweepStale(LocalPlayer())
	OnRefreshTrigger()
end

-- ESC closes the list; input passes through while it is closed (note 19).
local function OnInput(pInput)
	if not m_PanelOpen then
		return false
	end
	if pInput:GetMessageType() == KeyEvents.KeyUp and pInput:GetKey() == Keys.VK_ESCAPE then
		ClosePanel()
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Initialize(): event wiring.
-- Civ VI loads every AddUserInterfaces context HIDDEN (Expansion2
-- InGame.lua:350-352); a hidden context draws nothing and gets no input, so
-- the context is shown here. Panel / banner open state is kept in their own
-- controls (TrackerPanel, AlertBanner start Hidden="1") plus a Lua flag, never
-- via ContextPtr:IsHidden().
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	-- Match the Lua flags (the XML roots also start Hidden="1").
	Controls.TrackerPanel:SetHide(true)
	Controls.AlertBanner:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.BannerButton:RegisterCallback(Mouse.eLClick, OnBannerClicked)
	Controls.BannerButton:RegisterCallback(Mouse.eRClick, function() TogglePanel() end)
	Controls.TrackerCloseButton:RegisterCallback(Mouse.eLClick, function() ClosePanel() end)
	Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
	Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
	Events.UnitAddedToMap.Add(OnRefreshTrigger)
	Events.UnitRemovedFromMap.Add(OnRefreshTrigger)
	Events.LocalPlayerChanged.Add(OnRefreshTrigger)
	Events.NotificationAdded.Add(OnNotificationAdded)
	EFV_Log(2, LOG_TAG, "initialized")
end

Initialize()
