-- ===========================================================================
-- EFV_Dev_Panel.lua  (EFV_Dev mod, WP T3; PLAN 5.0)
-- Context: UI (AddUserInterfaces, Context InGame). TESTING ONLY.
--
-- Panel toggled by Ctrl+Shift+D (input handler pattern U11) or the "DEV"
-- launch bar button. Buttons send flat EXECUTE_SCRIPT requests
--   UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT,
--     { OnStart = "EFV_Dev", cmd = "...", target, unitOwner, unitID, cityOwner,
--       cityID, x, y, type, amount, <extra k=v> })
-- handled by Scripts/EFV_Dev_Gameplay.lua. The "Forged requests" buttons
-- send EFV's own requests (EFV_Send / EFV_Recall / EFV_Entrust) directly,
-- bypassing EFV's UI checks, to test gameplay re-validation (P1.2g).
--
-- The info lines show the selection and, through EFV's UI API
-- (EFV_UI_RecordForUnit, INTERFACES 3.12), the EFV record of the selected unit.
--
-- AddUserInterfaces contexts load HIDDEN (INTERFACES note 19): Initialize
-- calls ContextPtr:SetHide(false); only Controls.Main is toggled and the open
-- state lives in m_Open.
-- ===========================================================================
include("InstanceManager")
-- EFV's UI API (EFV_UI_ReadStore, EFV_UI_RecordForUnit, ...). Guarded: the panel
-- must keep working even if EFV's UI module fails to load.
local m_UIShared = pcall(include, "EFV_UIShared")
include("EFV_Config")
-- EFV:GLOBALS EFV_Config EFV_UI_ReadStore EFV_UI_RecordForUnit EFV_UI_StateText EFV_UI_TrackerState EFV_SortedKeys EFV_UI_RecordsFor EFV_UI_TrackedUnit
-- EFV:GLOBALS EFV_DestinationRows EFV_PartnerBasis EFV_VolunteerBasis

local PREFIX = "[EFV][Dev][UI]"
local m_ButtonIM = InstanceManager:new("DevButtonInstance", "Button", Controls.ButtonStack)
local m_HeaderIM = InstanceManager:new("DevHeaderInstance", "Header", Controls.ButtonStack)
local m_Targets = {}
local m_TargetIdx = 1
local m_Open = false
local m_LaunchInst = {}
local m_LaunchDone = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Str(v)
	if v == nil then return "nil" end
	return tostring(v)
end

local function Log(msg)
	print(PREFIX .. " " .. Str(msg))
end

local function Trim(s)
	if s == nil then return "" end
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function EditText(ctrl)
	local ok, t = pcall(function() return ctrl:GetText() end)
	if ok and t ~= nil then return Trim(t) end
	return ""
end

-- Request stamp (turn * 1000 + counter): lets the UI match gameplay's
-- answer in the EFV_DEV_SCN property to its own request.
local m_StampN = 0
local function NextStamp()
	m_StampN = m_StampN + 1
	local t = 0
	pcall(function() t = Game.GetCurrentGameTurn() end)
	return (tonumber(t) or 0) * 1000 + m_StampN
end

local function LocalID()
	return Game.GetLocalPlayer()
end

local function PlayerName(id)
	local name = "P" .. Str(id)
	pcall(function()
		name = name .. " " .. Locale.Lookup(PlayerConfigurations[id]:GetCivilizationShortDescription())
	end)
	local kind = ""
	pcall(function()
		if Players[id]:IsMajor() then kind = " (major)" else kind = " (minor/other)" end
	end)
	return name .. kind
end

-- The head-selected city (base-game UI API, used by CityPanel; not in PLAN
-- Appendix A because EFV itself never needs it).
local function SelectedCity()
	local ok, c = pcall(function() return UI.GetHeadSelectedCity() end)
	if ok then return c end
	return nil
end

local function CurrentTarget()
	return m_Targets[m_TargetIdx] or -1
end

-- The session roles S0 wrote to the Game property EFV_DEV_SCN (B = your
-- partner, F = your friend, C = the common enemy, CS = the city-state), for
-- the info line: the tester must know which civ is B without the log.
local function CivName(id)
	local name = "P" .. Str(id)
	pcall(function() name = Locale.Lookup(PlayerConfigurations[id]:GetCivilizationShortDescription()) end)
	return name
end

-- After T1 / T2 the first line is the role map ("T2: E=Gaul, FW=Japan, ...").
local function EligText(e)
	if type(e) ~= "table" or e.test == nil then return nil end
	if e.err ~= nil then return Str(e.test) .. ": " .. Str(e.err) end
	local parts = {}
	for _, c in ipairs(e.civs or {}) do
		if c.role ~= "OTHER" and c.role ~= "CSO" then parts[#parts + 1] = Str(c.role) .. "=" .. CivName(c.pid) end
	end
	return Str(e.test) .. ": " .. table.concat(parts, ", ") .. (e.skipped and (" (skipped " .. Str(e.skipped) .. ")") or "")
end

local function SessionText()
	local ok, st = pcall(function() return Game:GetProperty("EFV_DEV_SCN") end)
	local elig = ok and type(st) == "table" and EligText(st.elig) or nil
	if elig ~= nil then return elig end
	if not ok or type(st) ~= "table" or st.ally == nil then
		return "Final session: start a NEW game, then press S0"
	end
	return "Session: B=" .. CivName(st.ally) .. " F=" .. CivName(st.friend) .. " C=" .. CivName(st.enemy) ..
		" CS=" .. CivName(st.cs)
end

local function RebuildTargets()
	local prev = CurrentTarget()
	m_Targets = {}
	for i = 0, 63 do
		local p = Players[i]
		if p ~= nil then
			local ok, alive = pcall(function() return p:IsAlive() end)
			if ok and alive then m_Targets[#m_Targets + 1] = i end
		end
	end
	m_TargetIdx = 1
	for i, id in ipairs(m_Targets) do
		if id == prev then m_TargetIdx = i; return end
	end
	for i, id in ipairs(m_Targets) do
		local okM, major = pcall(function() return Players[id]:IsMajor() end)
		if id ~= LocalID() and okM and major then m_TargetIdx = i; return end
	end
end

-- ---------------------------------------------------------------------------
-- Info lines
-- ---------------------------------------------------------------------------
local function RecordText(unit)
	if unit == nil then return "VEF: no unit selected" end
	local ok, rec = pcall(function() return EFV_UI_RecordForUnit(unit:GetOwner(), unit:GetID()) end)
	if not ok then return "VEF: UI API unavailable (" .. Str(rec) .. ")" end
	if rec == nil then return "VEF: unit not tracked" end
	local s = "VEF record " .. Str(rec.id) .. " " .. Str(rec.forceType) .. " " .. Str(rec.state) ..
		" sender=" .. Str(rec.senderID) .. " recipient=" .. Str(rec.recipientID) ..
		" deployed=" .. Str(rec.deployedTurn) .. " duration=" .. Str(rec.durationTurns) ..
		" grace=" .. Str(rec.graceTurnsLeft) .. " lapsed=" .. Str(rec.lapsed)
	pcall(function() s = s .. " | " .. EFV_UI_StateText(rec, Game.GetCurrentGameTurn()) end)
	return s
end

local m_EligStatus = nil     -- short T1 / T2 result shown in the panel

local function RefreshInfo()
	local s = SessionText() .. " | Local " .. PlayerName(LocalID()) .. " | turn " .. Str(Game.GetCurrentGameTurn())
	local unit = UI.GetHeadSelectedUnit()
	if unit ~= nil then
		local tn = "?"
		pcall(function() tn = GameInfo.Units[unit:GetType()].UnitType end)
		s = s .. " | Unit " .. unit:GetOwner() .. "/" .. unit:GetID() .. " " .. tn .. " @" .. unit:GetX() .. "," .. unit:GetY() ..
			" dmg=" .. Str(unit:GetDamage())
	else
		s = s .. " | no unit"
	end
	local city = SelectedCity()
	if city ~= nil then
		s = s .. " | City " .. city:GetOwner() .. "/" .. city:GetID() .. " @" .. city:GetX() .. "," .. city:GetY()
	end
	Controls.InfoLabel:SetText(s)
	Controls.RecordLabel:SetText((m_EligStatus and (m_EligStatus .. " | ") or "") .. RecordText(unit))
	Controls.TargetLabel:SetText(PlayerName(CurrentTarget()))
end

-- Target cycle -> player pid (after S0: B, so the diplomacy buttons act on B).
local function TargetTo(pid)
	RebuildTargets()
	for i, id in ipairs(m_Targets) do
		if id == pid then m_TargetIdx = i end
	end
	RefreshInfo()
end

local function OnTargetPrev()
	RebuildTargets()
	m_TargetIdx = m_TargetIdx - 1
	if m_TargetIdx < 1 then m_TargetIdx = #m_Targets end
	RefreshInfo()
end

local function OnTargetNext()
	RebuildTargets()
	m_TargetIdx = m_TargetIdx + 1
	if m_TargetIdx > #m_Targets then m_TargetIdx = 1 end
	RefreshInfo()
end

-- ---------------------------------------------------------------------------
-- Requests (flat params: numbers and strings only)
-- ---------------------------------------------------------------------------
local function ParseExtra(p)
	local extra = EditText(Controls.ExtraEdit)
	for k, v in string.gmatch(extra, "([%w_]+)%s*=%s*([^;]*)") do
		if k ~= "OnStart" and k ~= "cmd" then
			v = Trim(v)
			local n = tonumber(v)
			if n ~= nil then p[k] = n else p[k] = v end
		end
	end
end

local function Send(p)
	local keys = {}
	for k in pairs(p) do keys[#keys + 1] = k end
	table.sort(keys)
	local shown = {}
	for _, k in ipairs(keys) do shown[#shown + 1] = k .. "=" .. Str(p[k]) end
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(LocalID(), PlayerOperations.EXECUTE_SCRIPT, p)
	end)
	Log("request ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " {" .. table.concat(shown, ", ") .. "}")
end

local function BaseParams(cmd)
	local p = { OnStart = "EFV_Dev", cmd = cmd, target = CurrentTarget(),
		unitOwner = -1, unitID = -1, cityOwner = -1, cityID = -1, x = -1, y = -1 }
	p.stamp = NextStamp()
	local unit = UI.GetHeadSelectedUnit()
	if unit ~= nil then
		p.unitOwner, p.unitID, p.x, p.y = unit:GetOwner(), unit:GetID(), unit:GetX(), unit:GetY()
	end
	local city = SelectedCity()
	if city ~= nil then
		p.cityOwner, p.cityID = city:GetOwner(), city:GetID()
		if p.x < 0 then p.x, p.y = city:GetX(), city:GetY() end
	end
	local t = EditText(Controls.TypeEdit)
	if t ~= "" then p.type = t end
	local a = tonumber(EditText(Controls.AmountEdit))
	if a ~= nil then p.amount = a end
	ParseExtra(p)
	return p
end

local function DevCommand(cmd)
	Send(BaseParams(cmd))
end

-- Target player's city for forged sends: the selected city if it belongs to
-- the target, else the target's city nearest to the selected unit.
local function TargetCity(unit)
	local target = CurrentTarget()
	local sel = SelectedCity()
	if sel ~= nil and sel:GetOwner() == target then return sel end
	local best, bestD = nil, nil
	local pPlayer = Players[target]
	if pPlayer == nil then return nil end
	for _, c in pPlayer:GetCities():Members() do
		local d = 0
		if unit ~= nil then d = Map.GetPlotDistance(unit:GetX(), unit:GetY(), c:GetX(), c:GetY()) end
		if bestD == nil or d < bestD or (d == bestD and c:GetID() < best:GetID()) then best, bestD = c, d end
	end
	return best
end

local FORCES = { EXPEDITIONARY = true, VOLUNTEER = true, CS_EXPEDITIONARY = true }

local function ForgeSend()
	local unit = UI.GetHeadSelectedUnit()
	if unit == nil then Log("forge send: select a unit"); return end
	local city = TargetCity(unit)
	if city == nil then Log("forge send: target has no city"); return end
	local ft = EditText(Controls.TypeEdit)
	if not FORCES[ft] then ft = "EXPEDITIONARY" end
	local fee = tonumber(EditText(Controls.AmountEdit)) or 99999
	local p = { OnStart = EFV_Config.REQ_SEND, unitID = unit:GetID(), recipientID = CurrentTarget(),
		destX = city:GetX(), destY = city:GetY(), forceType = ft, expectedFee = fee }
	ParseExtra(p)
	Send(p)
end

local function ForgeRecall()
	local unit = UI.GetHeadSelectedUnit()
	if unit == nil then Log("forge recall: select a unit"); return end
	Send({ OnStart = EFV_Config.REQ_RECALL, unitID = unit:GetID() })
end

local function ForgeEntrust()
	local city = SelectedCity()
	if city == nil then Log("forge entrust: select the captured city"); return end
	Send({ OnStart = EFV_Config.REQ_ENTRUST, x = city:GetX(), y = city:GetY(), recipientID = CurrentTarget() })
end

local function UIStore()
	local ok, s = pcall(EFV_UI_ReadStore)
	if not ok or s == nil then Log("UI store unavailable: " .. Str(s)); return end
	Log("UI store rev=" .. Str(s.rev) .. " records=" .. Str(s.ids and #s.ids))
	for _, id in ipairs(s.ids or {}) do
		local r = s.recs["r" .. id]
		if r ~= nil then
			Log("  " .. id .. " " .. Str(r.forceType) .. " " .. Str(r.state) .. " s=" .. Str(r.senderID) .. " r=" .. Str(r.recipientID) ..
				" onMap=" .. Str(r.onMapPlayerID) .. "/" .. Str(r.onMapUnitID))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Final session (EFV/TESTING_FINAL.md): camera focus after a scenario button,
-- "Go to scenario", and route B of the S6 veteran test (the engine PROMOTE
-- command is UI only: UnitPromotionPopup.lua:70-72). Gameplay writes its
-- scenario state to the Game property EFV_DEV_SCN; the UI only reads it.
-- ---------------------------------------------------------------------------
local SCN_PROP = "EFV_DEV_SCN"
local m_Clock = 0
local m_FocusWait = nil     -- { stamp, nextAt, untilClock } after a scenario button
local m_Vet = nil           -- S6 route B state
local VET_TIMEOUT = 10      -- seconds without a gameplay answer
local VET_PROMO_WAIT = 5    -- seconds for a PROMOTE command to land
local ROUTE = {
	A = "route A (XP to the threshold, then SetPromotion)",
	B = "route B (XP to the threshold, then the PROMOTE command)",
	C = "route C (SetPromotion only: the current restore)",
}

local function ScnState()
	local ok, st = pcall(function() return Game:GetProperty(SCN_PROP) end)
	if ok and type(st) == "table" then return st end
	return nil
end

local function UICheck(id, verdict, msg)
	local t = -1
	pcall(function() t = Game.GetCurrentGameTurn() end)
	print("[EFV][CHECK] " .. Str(id) .. " " .. Str(verdict) .. " T" .. Str(t) .. " " .. Str(msg))
end

local function OwnUnit(o, id)
	o, id = tonumber(o), tonumber(id)
	if o == nil or id == nil or Players[o] == nil then return nil end
	local u = nil
	pcall(function() u = Players[o]:GetUnits():FindID(id) end)
	if u ~= nil and u:GetID() ~= id then return nil end
	return u
end

local function LookAt(f)
	if type(f) ~= "table" or f.x == nil or f.y == nil or f.x < 0 then return false end
	pcall(function() UI.LookAtPlot(f.x, f.y) end)
	if f.o == LocalID() then
		local u = OwnUnit(f.o, f.u)
		if u ~= nil then pcall(function() UI.SelectUnit(u) end) end
	end
	return true
end

local function GoTo()
	local st = ScnState()
	if not LookAt(st and st.focus) then Log("go to scenario: no scenario position yet") end
end

local function Level(u)
	if u == nil then return nil end
	local ok, l = pcall(function() return u:GetExperience():GetLevel() end)
	if ok then return tonumber(l) end
	return nil
end

local function HasPromo(u, row)
	local ok, has = pcall(function()
		for _, idx in ipairs(u:GetExperience():GetPromotions()) do
			if idx == row.Index then return true end
		end
		return false
	end)
	return ok and has == true
end

local function VetStart()
	local unit = UI.GetHeadSelectedUnit()
	local p = BaseParams("scn_vet")
	m_Vet = { stamp = p.stamp, phase = "wait", t0 = m_Clock, nextAt = m_Clock + 0.5, i = 1, origLevel = Level(unit) }
	Send(p)
end

local function VetFinish(v)
	Send(BaseParams("scn_vetdone"))
	v.phase = "final"
	v.nextAt = m_Clock + 1.0
end

local function VetStep()
	local v = m_Vet
	if m_Clock < v.nextAt then return end
	v.nextAt = m_Clock + 0.4
	if v.phase == "wait" then
		local st = ScnState()
		local vet = st and st.vet
		if type(vet) ~= "table" or vet.stamp ~= v.stamp then
			if m_Clock - v.t0 > VET_TIMEOUT then
				m_Vet = nil
				Log("S6: no answer from gameplay (select one of your veterans, then press S6 again)")
			end
			return
		end
		v.vet = vet
		if vet.B == nil then v.phase = "final"; return end
		v.phase = "promote"
		return
	end
	local vet = v.vet
	if v.phase == "promote" then
		local b = OwnUnit(vet.o, vet.B)
		local name = (vet.promos or {})[v.i]
		local row = name and GameInfo.UnitPromotions[name]
		if b == nil or row == nil then
			UICheck("VET_B", "CHECK", "VEF-B or its promotion " .. Str(v.i) .. " not found")
			VetFinish(v)
			return
		end
		if HasPromo(b, row) then
			v.i = v.i + 1
			v.sentAt = nil
			if v.i > #vet.promos then
				VetFinish(v)
			else
				local q = BaseParams("scn_vetb")
				q.i = v.i
				Send(q)
				v.nextAt = m_Clock + 0.8
			end
			return
		end
		if v.sentAt == nil then
			local ok, err = pcall(function()
				local t = {}
				t[UnitCommandTypes.PARAM_PROMOTION_TYPE] = row.Index
				UnitManager.RequestCommand(b, UnitCommandTypes.PROMOTE, t)
			end)
			Log("S6 VEF-B PROMOTE " .. row.UnitPromotionType .. " sent ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
			v.sentAt = m_Clock
			if not ok then
				UICheck("VET_B", "CHECK", "the PROMOTE command failed: " .. Str(err))
				VetFinish(v)
			end
		elseif m_Clock - v.sentAt > VET_PROMO_WAIT then
			UICheck("VET_B", "CHECK", row.UnitPromotionType .. " did not arrive within " .. VET_PROMO_WAIT .. " s of the PROMOTE command")
			VetFinish(v)
		end
		return
	end
	-- final: the UI levels (GetLevel is UI only)
	local lv0 = v.origLevel
	if lv0 == nil then lv0 = Level(OwnUnit(vet.o, vet.id)) end
	for _, k in ipairs({ "A", "B", "C" }) do
		local l = Level(OwnUnit(vet.o, vet[k]))
		UICheck("VET_LEVEL_" .. k, (l ~= nil and lv0 ~= nil and l == lv0) and "PASS" or "CHECK",
			ROUTE[k] .. ": level " .. Str(l) .. " (original " .. Str(lv0) .. ")")
	end
	m_Vet = nil
end

-- ---------------------------------------------------------------------------
-- Workshop Shot buttons, UI side (workshop/SCREENSHOTS.md B3 / B4). Gameplay
-- writes st.focus with open / ft / zoom / tx / ty; after the camera move the
-- panel zooms (pcall: not proven from a mod context, the designer can use
-- the mouse wheel), closes itself, hides the DEV launch button (back with
-- Ctrl+Shift+D) and runs the open action:
--   PICKER   one tick later LuaEvents.EFV_OpenDestinationPicker(local, unit, ft)
--            (the call EFV_UnitActions makes)
--   TRACKER  LuaEvents.EFV_TrackerOpen() (0.7 hook; a no-op without it)
--   CAPTURE  Tank 1 attacks (x, y) like the base RequestMoveOperation
--            (Civ6Common.lua:147-163); when /InGame/RazeCity shows (up to
--            SHOT_WAIT s) LuaEvents.EFV_EntrustExpand() (0.7 hook)
-- Every shot also looks at the plot again after 1 s (flag badges of units
-- created and recorded in the same gameplay call, not proven yet).
-- ---------------------------------------------------------------------------
local SHOT_WAIT = 8
local m_Shot = nil          -- { cmd, id, f, phase, nextAt, relookAt, untilClock }
local SetOpen               -- forward (defined with the show / hide code below)

local function HideLaunch(hide)
	pcall(function() m_LaunchInst.LaunchItemButton:SetHide(hide) end)
end

-- Dismisses the local player's VEF notifications (every EFV_Config.NOTIF
-- type; the EFV_Tracker SweepStale pattern). Returns the number dismissed.
local function DismissVefNotifications()
	local localID = LocalID()
	local hashes = {}
	local notif = EFV_Config.NOTIF or {}
	for _, key in ipairs(EFV_SortedKeys(notif)) do
		local typeName = notif[key]
		if type(typeName) == "string" then
			local ok, h = pcall(function() return GameInfo.Types[typeName].Hash end)
			if ok and h ~= nil then hashes[h] = true end
		end
	end
	local okL, list = pcall(function() return NotificationManager.GetList(localID) end)
	if not okL or type(list) ~= "table" then return 0 end
	local n = 0
	for _, nid in ipairs(list) do
		pcall(function()
			local pN = NotificationManager.Find(localID, nid)
			if pN ~= nil and hashes[pN:GetType()] then
				NotificationManager.Dismiss(localID, nid)
				n = n + 1
			end
		end)
	end
	return n
end

-- S15 (scn_receive) runs as a Shot too: its UI lines read RECEIVE and the DEV
-- launch button stays visible.
local function IsShotCmd(cmd)
	return string.sub(Str(cmd), 1, 4) == "shot"
end

local function ShotID(cmd)
	if not IsShotCmd(cmd) then return "RECEIVE" end
	return "SHOT" .. string.sub(Str(cmd), 5)
end

local function StartShot(cmd, f)
	if type(f.zoom) == "number" then
		local okG, before = pcall(function() return UI.GetMapZoom() end)
		local ok, err = pcall(function() UI.SetMapZoom(f.zoom, 0.0, 0.0) end)
		Log(cmd .. " zoom " .. (okG and Str(before) or "?") .. " -> " .. f.zoom .. " ok=" .. tostring(ok) ..
			(ok and "" or (" err=" .. Str(err) .. " (use the mouse wheel)")))
	end
	m_Shot = { cmd = cmd, id = ShotID(cmd), f = f, phase = f.open or "DONE", nextAt = m_Clock + 0.3, relookAt = m_Clock + 1.0 }
	SetOpen(false)
	if IsShotCmd(cmd) then HideLaunch(true) end
end

local function ShotAttack(s)
	local f = s.f
	local tank = OwnUnit(f.o, f.u)
	if tank == nil or f.tx == nil or f.ty == nil then return false, "Tank 1 not found" end
	local ok, res = pcall(function()
		local t = {}
		t[UnitOperationTypes.PARAM_X] = f.tx
		t[UnitOperationTypes.PARAM_Y] = f.ty
		t[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK + UnitOperationMoveModifiers.MOVE_IGNORE_UNEXPLORED_DESTINATION
		if UnitManager.CanStartOperation(tank, UnitOperationTypes.MOVE_TO, nil, t) then
			UnitManager.RequestOperation(tank, UnitOperationTypes.MOVE_TO, t)
			return true
		end
		return false
	end)
	if not ok then return false, "error " .. Str(res) end
	if res ~= true then return false, "CanStartOperation refused (no moves?)" end
	return true, nil
end

local function RazeCityShown()
	local ok, shown = pcall(function()
		local c = ContextPtr:LookUpControl("/InGame/RazeCity")
		return c ~= nil and not c:IsHidden()
	end)
	return ok and shown == true
end

local function ShotStep()
	local s = m_Shot
	if m_Clock < s.nextAt then return end
	s.nextAt = m_Clock + 0.3
	if s.relookAt ~= nil and m_Clock >= s.relookAt then
		s.relookAt = nil
		pcall(function() UI.LookAtPlot(s.f.x, s.f.y) end)
	end
	if s.phase == "PICKER" then
		local ok, err = pcall(function() LuaEvents.EFV_OpenDestinationPicker(LocalID(), s.f.u, s.f.ft) end)
		UICheck(s.id, ok and "INFO" or "CHECK", "destination picker opened=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
			"; if it hides the unit panel, take frame 1b after Esc while hovering Send as " ..
			((s.f.ft == "VOLUNTEER") and "Volunteers" or "Expeditionary"))
		s.phase = "DONE"
	elseif s.phase == "TRACKER" then
		local ok, err = pcall(function() LuaEvents.EFV_TrackerOpen() end)
		UICheck(s.id, ok and "INFO" or "CHECK", "tracker open hook sent ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
			"; if the panel is closed, click the VEF button once")
		s.phase = "DONE"
	elseif s.phase == "CAPTURE" then
		local sent, why = ShotAttack(s)
		UICheck(s.id, "INFO", sent and "attack on the city requested; waiting for the capture screen" or
			("attack not sent (" .. Str(why) .. "): click the city with the selected Tank"))
		s.phase = "WAIT_RAZE"
		s.untilClock = m_Clock + SHOT_WAIT
	elseif s.phase == "WAIT_RAZE" then
		local shown = RazeCityShown()
		if shown or m_Clock > s.untilClock then
			local ok = pcall(function() LuaEvents.EFV_EntrustExpand() end)
			UICheck(s.id, "INFO", shown and ("capture screen open; Entrust list expand sent ok=" .. tostring(ok)) or
				("no capture screen within " .. SHOT_WAIT .. " s: take the city, then click Entrust... once"))
			s.phase = "DONE"
		end
	end
	if s.phase == "DONE" and s.relookAt == nil then m_Shot = nil end
end

-- ---------------------------------------------------------------------------
-- 0.7 re-test UI checks (EFV/TESTING_RETEST_0.7.md), polled every 0.5 s:
--   VET_RESTORE_LEVEL  S12: once gameplay named VEF-VET's unit (st.s12.uid)
--                      and its route B job is gone from the store: level 3
--                      (GetLevel is UI only), XP 50/90, damage 30, the unit
--                      panel name logged; then Check now for VET_RESTORE
--   LAPSE_TEXT         the first paused lapse of a local Volunteer record in
--                      GRACE: the tracker state reads "Lapse: Grace N (paused)"
-- ---------------------------------------------------------------------------
local m_CheckAt = 0
local m_VetLevelDone = {}
local m_LapseSeen = {}

local function VetLevelCheck()
	local st = ScnState()
	local s = st and st.s12
	if type(s) ~= "table" or s.uid == nil or st.me ~= LocalID() or m_VetLevelDone[s.uid] then return end
	local ok, store = pcall(EFV_UI_ReadStore)
	if not ok or type(store) ~= "table" then return end
	for _, j in ipairs(store.vet or {}) do
		if j.p == st.me and j.u == s.uid then return end
	end
	m_VetLevelDone[s.uid] = true
	local u = OwnUnit(st.me, s.uid)
	if u == nil then
		UICheck("VET_RESTORE_LEVEL", "CHECK", "VEF-VET (unit " .. Str(s.uid) .. ") not found")
	else
		local lvl = Level(u)
		local xp, nxt, dmg, name = -1, -1, -1, "?"
		pcall(function()
			local e = u:GetExperience()
			xp, nxt = e:GetExperiencePoints(), e:GetExperienceForNextLevel()
		end)
		pcall(function() dmg = u:GetDamage() end)
		pcall(function() name = Locale.Lookup(u:GetName()) end)
		-- 0.7.2 (re-test 0.7 step 5): the level must be back in the arrival
		-- turn (S12 turn + 1); a later turn is reported, and its damage may
		-- be lower by the engine's heal of 15 per round in your land.
		local turn = -1
		pcall(function() turn = Game.GetCurrentGameTurn() end)
		local late = math.max(0, turn - ((tonumber(s.turn) or turn) + 1))
		local pass = lvl == 3 and xp == 50 and nxt == 90 and late == 0 and dmg == 30
		UICheck("VET_RESTORE_LEVEL", pass and "PASS" or "CHECK", "level " .. Str(lvl) .. " (expected 3), XP " .. Str(xp) .. "/" .. Str(nxt) ..
			", damage " .. Str(dmg) .. ", " .. (late == 0 and "in the arrival turn" or (late .. " turn(s) after the arrival turn (expected the arrival turn)")) ..
			"; unit panel name '" .. Str(name) .. "'")
	end
	Send(BaseParams("scn_check"))
end

local function LapseTextCheck()
	local ok, store = pcall(EFV_UI_ReadStore)
	if not ok or type(store) ~= "table" then return end
	local me = LocalID()
	for _, id in ipairs(store.ids or {}) do
		local r = store.recs and store.recs["r" .. id]
		if r ~= nil and not m_LapseSeen[id] and r.senderID == me and r.forceType == EFV_Config.FT_VOL and r.lapsed == 1
				and r.lapsePaused == 1 and r.state == EFV_Config.ST_GRACE then
			m_LapseSeen[id] = true
			local okT, text = pcall(EFV_UI_TrackerState, r)
			if okT then text = string.gsub(Str(text), "%[COLOR[^%]]*%]", "") else text = "error " .. Str(text) end
			local expect = "Lapse: Grace " .. Str(r.graceTurnsLeft) .. " (paused)"
			UICheck("LAPSE_TEXT", text == expect and "PASS" or "CHECK", "tracker state of Volunteer record " .. id .. ": '" .. text ..
				"' (expected '" .. expect .. "')")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Badge audit (EFV_Dev 0.7.2-dev.1, always on; 0.7.1 report "the Volunteer
-- Swordsman turned into a Warrior, same VEF tooltip"). At every turn start of
-- the local player and 0.3 s after Events.UnitAddedToMap / UnitRemovedFromMap
-- / UnitKilledInCombat, asks VEF's flag wrapper for every flag showing a VEF
-- tag (LuaEvents.EFV_BadgeAuditRequest -> EFV_BadgeAuditReport rows, see
-- EFV_UnitFlagManager) and checks the tracker's on-map rows: each tag must
-- sit on the live unit (owner AND ID AND type) of an on-map record. Logs
-- "[EFV][CHECK] BADGE_AUDIT PASS|FAIL": always at a turn start, after unit
-- events only when the result changed or failed.
-- ---------------------------------------------------------------------------
local m_AuditDue = nil
local m_AuditWhy = ""
local m_AuditForce = false
local m_AuditLast = nil
local m_AuditReplied = false

local function RowTag(r)
	return "flag P" .. Str(r.fp) .. "/" .. Str(r.fu) .. " (unit " .. (r.up ~= nil and ("P" .. Str(r.up) .. "/" .. Str(r.uu) ..
		" " .. Str(r.ut)) or "none") .. (r.rid ~= nil and (", record " .. Str(r.rid) .. " " .. Str(r.rs) .. " " .. Str(r.rt)) or "") .. ")"
end

local function OnAuditReport(rows)
	m_AuditReplied = true
	local bad, ok = {}, 0
	for _, r in ipairs(rows or {}) do
		if r.bad ~= nil then bad[#bad + 1] = RowTag(r) .. ": " .. Str(r.bad) else ok = ok + 1 end
	end
	local onMap, waiting = 0, {}
	pcall(function()
		for _, rec in ipairs(EFV_UI_RecordsFor(LocalID())) do
			if rec.state == EFV_Config.ST_DEPLOYED or rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY then
				onMap = onMap + 1
				if EFV_UI_TrackedUnit(rec) == nil then waiting[#waiting + 1] = Str(rec.id) end
			end
		end
	end)
	local text = ok .. " VEF tag(s), each on its record's live unit; tracker: " .. onMap .. " on-map row(s)" ..
		(#waiting > 0 and (", " .. #waiting .. " waiting for the turn start with the unit gone (record " ..
			table.concat(waiting, ",") .. ")") or "")
	local verdict = #bad == 0 and "PASS" or "FAIL"
	if #bad > 0 then text = table.concat(bad, "; ") .. "; " .. text end
	if m_AuditForce or verdict == "FAIL" or text ~= m_AuditLast then
		UICheck("BADGE_AUDIT", verdict, "(" .. m_AuditWhy .. ") " .. text)
		m_AuditLast = text
	end
	m_AuditForce = false
end

local function ScheduleAudit(why, force)
	if m_AuditDue == nil then
		m_AuditDue = m_Clock + 0.3
		m_AuditWhy = why
	end
	if force then
		m_AuditForce = true
		m_AuditWhy = why
	end
end

local function RunAudit()
	m_AuditDue = nil
	m_AuditReplied = false
	LuaEvents.EFV_BadgeAuditRequest()
	if not m_AuditReplied and m_AuditForce then
		UICheck("BADGE_AUDIT", "INFO", "(" .. m_AuditWhy .. ") no answer from VEF's flag wrapper (badges off or another mod replaces the unit flags)")
		m_AuditForce = false
	end
end

-- ---------------------------------------------------------------------------
-- Eligibility tests T1 / T2, UI side (EFV_Dev 1.0.1.3; T2 City-State lines
-- 1.0.2.1). Gameplay sets up the
-- roles, logs its ELIG_Tn lines (gameplay rules) and writes st.elig (roles,
-- expected results, facts, the two Swordsmen). ELIG_UI_DELAY s after its
-- answer the panel asks VEF's picker rows again with the UI rules (the
-- destination picker's own adapters: GetDiplomaticStateIndex and
-- HasOpenBordersFrom) and logs ELIG_Tn_UI lines in the same format, then
-- shows a short status on the panel.
-- ---------------------------------------------------------------------------
local ELIG_UI_DELAY = 1.0
local m_Elig = nil          -- { cmd, stamp, at }
local ELIG_CODES = { NOT_PARTNER = true, VOL_NEEDS_ACCESS = true, CS_NOT_MET = true,
	AT_WAR_WITH_RECIPIENT = true, NO_COMMON_WAR = true }

-- Same classification as the gameplay side (EligClass in EFV_Dev_Gameplay.lua).
local function EligClass(rows, pid)
	local any, open, best = false, false, nil
	for _, r in ipairs(rows) do
		if r.recipientID == pid then
			any = true
			if r.ok then open = true
			elseif best == nil or #(r.reasons or {}) < #best then best = r.reasons or {} end
		end
	end
	if not any then return "ABSENT", {} end
	if open then return "ALLOWED", {} end
	local elig, other = {}, {}
	for _, c in ipairs(best) do
		if ELIG_CODES[c] then elig[#elig + 1] = c else other[#other + 1] = c end
	end
	table.sort(elig)
	return "GREY:" .. table.concat(elig, "+"), other
end

local function EligCompare(want, got)
	if want == got then return "PASS" end
	if want == "ALLOWED" and got == "GREY:" then return "CHECK" end
	return "FAIL"
end

local function EligUI(test, stamp)
	local id = "ELIG_" .. test .. "_UI"
	local st = ScnState()
	local e = st and st.elig
	if type(e) ~= "table" or e.stamp ~= stamp then
		UICheck(id, "CHECK", "no answer from gameplay")
		m_EligStatus = test .. ": no answer from gameplay (see Lua.log)"
		return
	end
	if e.err ~= nil then
		m_EligStatus = test .. ": " .. Str(e.err)
		return
	end
	if type(EFV_DestinationRows) ~= "function" then
		UICheck(id, "CHECK", "VEF's UI rules are not loaded (EFV_UIShared)")
		m_EligStatus = test .. ": gameplay " .. Str(e.pass) .. "/" .. Str(e.n) .. " PASS, UI rules not loaded"
		return
	end
	local me = LocalID()
	local u1, u2 = OwnUnit(me, e.u1), OwnUnit(me, e.u2)
	local store = nil
	pcall(function() store = EFV_UI_ReadStore() end)
	local rowsExp, rowsVol, rowsCs = {}, {}, {}
	if u1 ~= nil then
		rowsExp = EFV_DestinationRows(me, u1, EFV_Config.FT_EXP, store)
		rowsVol = EFV_DestinationRows(me, u2 or u1, EFV_Config.FT_VOL, store)
		if (tonumber(e.ncs) or 0) > 0 then rowsCs = EFV_DestinationRows(me, u1, EFV_Config.FT_CS, store) end
	end
	local n, pass, fail, chk, bad = 0, 0, 0, 0, {}
	local function Act(a, o) return a .. (#o > 0 and (" (also " .. table.concat(o, "+") .. ")") or "") end
	for _, c in ipairs(e.civs or {}) do
		if c.cs ~= nil then
			-- City-State line (T2, EFV_Dev 1.0.2.1): VEF 1.0.2 needs no shared enemy.
			local aCs, oCs = EligClass(rowsCs, c.pid)
			local v = EligCompare(c.cs, aCs)
			if c.setup ~= nil or u1 == nil then v = "CHECK" end
			n = n + 1
			if v == "PASS" then pass = pass + 1 elseif v == "FAIL" then fail = fail + 1 else chk = chk + 1 end
			if v ~= "PASS" then bad[#bad + 1] = Str(c.role) .. " " .. v end
			UICheck(id, v, Str(c.role) .. "=" .. PlayerName(c.pid) .. " | " .. Str(c.facts) ..
				" | City-State expected " .. Str(c.cs) .. " actual " .. Act(aCs, oCs) ..
				(c.setup and (" | SETUP: " .. Str(c.setup)) or "") .. " [UI rules]")
		else
			local aExp, oExp = EligClass(rowsExp, c.pid)
			local aVol, oVol = EligClass(rowsVol, c.pid)
			local v = "PASS"
			for _, w in ipairs({ EligCompare(c.exp, aExp), EligCompare(c.vol, aVol) }) do
				if w == "FAIL" then v = "FAIL" elseif w == "CHECK" and v == "PASS" then v = "CHECK" end
			end
			if c.setup ~= nil or u1 == nil then v = "CHECK" end
			n = n + 1
			if v == "PASS" then pass = pass + 1 elseif v == "FAIL" then fail = fail + 1 else chk = chk + 1 end
			if v ~= "PASS" then bad[#bad + 1] = Str(c.role) .. " " .. v end
			local okB, pb = pcall(EFV_PartnerBasis, me, c.pid)
			local okV, vb = pcall(EFV_VolunteerBasis, me, c.pid)
			UICheck(id, v, Str(c.role) .. "=" .. PlayerName(c.pid) .. " | " .. Str(c.facts) .. "; UI basis " ..
				(okB and Str(pb) or "error") .. ", Volunteer basis " .. (okV and Str(vb) or "error") ..
				" | Expeditionary expected " .. Str(c.exp) .. " actual " .. Act(aExp, oExp) ..
				" | Volunteers expected " .. Str(c.vol) .. " actual " .. Act(aVol, oVol) ..
				(c.setup and (" | SETUP: " .. Str(c.setup)) or "") .. " [UI rules]")
		end
	end
	local sv = (fail > 0) and "FAIL" or ((chk > 0 or e.skipped ~= nil) and "CHECK" or "PASS")
	local ncs = tonumber(e.ncs) or 0
	UICheck(id, sv, "summary (UI rules): " .. test .. ", " .. (n - ncs) .. " civ(s)" ..
		(ncs > 0 and (" + " .. ncs .. " city-state(s)") or "") .. ": " .. pass .. " PASS, " .. fail .. " FAIL, " .. chk ..
		" CHECK" .. (e.skipped and ("; roles " .. Str(e.skipped) .. " skipped (too few civs)") or ""))
	m_EligStatus = test .. ": gameplay " .. Str(e.pass) .. "/" .. Str(e.n) .. " PASS, UI " .. pass .. "/" .. n .. " PASS" ..
		(#bad > 0 and (" (UI: " .. table.concat(bad, ", ") .. ")") or "") ..
		(e.skipped and ("; skipped " .. Str(e.skipped)) or "") .. "; details: Lua.log [EFV][CHECK] ELIG_" .. test
end

local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_AuditDue ~= nil and m_Clock >= m_AuditDue then
		local ok, err = pcall(RunAudit)
		if not ok then Log("badge audit error: " .. Str(err)) end
	end
	if m_FocusWait ~= nil and m_Clock >= m_FocusWait.nextAt then
		m_FocusWait.nextAt = m_Clock + 0.3
		local st = ScnState()
		local f = st and st.focus
		if type(f) == "table" and f.stamp == m_FocusWait.stamp then
			LookAt(f)
			if m_FocusWait.cmd == "scn_setup" and st.ally ~= nil then TargetTo(st.ally) end
			if m_FocusWait.shot then StartShot(m_FocusWait.cmd, f) end
			if m_FocusWait.elig then
				m_Elig = { test = m_FocusWait.elig, stamp = m_FocusWait.stamp, at = m_Clock + ELIG_UI_DELAY }
				m_EligStatus = m_FocusWait.elig .. ": set up, checking the UI rules..."
				RefreshInfo()
			end
			m_FocusWait = nil
		elseif m_Clock > m_FocusWait.untilClock then
			if m_FocusWait.shot then UICheck(ShotID(m_FocusWait.cmd), "CHECK", "no answer from gameplay within " .. SHOT_WAIT .. " s") end
			if m_FocusWait.elig then
				UICheck("ELIG_" .. m_FocusWait.elig .. "_UI", "CHECK", "no answer from gameplay within " .. SHOT_WAIT .. " s")
				m_EligStatus = m_FocusWait.elig .. ": no answer from gameplay (see Lua.log)"
				RefreshInfo()
			end
			m_FocusWait = nil
		end
	end
	if m_Shot ~= nil then
		local ok, err = pcall(ShotStep)
		if not ok then
			Log("shot error: " .. Str(err))
			m_Shot = nil
		end
	end
	if m_Elig ~= nil and m_Clock >= m_Elig.at then
		local e = m_Elig
		m_Elig = nil
		local ok, err = pcall(EligUI, e.test, e.stamp)
		if not ok then
			Log("eligibility UI check error: " .. Str(err))
			m_EligStatus = e.test .. ": UI check error (see Lua.log)"
		end
		RefreshInfo()
	end
	if m_Clock >= m_CheckAt then
		m_CheckAt = m_Clock + 0.5
		pcall(VetLevelCheck)
		pcall(LapseTextCheck)
	end
	if m_Vet ~= nil then
		local ok, err = pcall(VetStep)
		if not ok then
			Log("S6 route B error: " .. Str(err))
			m_Vet = nil
		end
	end
end

-- Scenario button: send, then move the camera to the scenario once gameplay
-- has written its position (same stamp).
local function Scenario(cmd)
	local p = BaseParams(cmd)
	m_FocusWait = { stamp = p.stamp, nextAt = m_Clock + 0.3, untilClock = m_Clock + 4, cmd = cmd }
	Send(p)
end

-- Workshop Shot buttons (EFV_Dev 0.7.0-dev.1; workshop/SCREENSHOTS.md B3):
-- deselect (a unit removed while selected broke SelectedUnit.lua:195 in the
-- final session), dismiss the local player's VEF notifications, send the
-- stamped request and wait up to SHOT_WAIT s for the scene.
local function Shot(cmd)
	pcall(function() UI.DeselectAllUnits() end)
	local n = DismissVefNotifications()
	local p = BaseParams(cmd)
	m_Shot = nil
	m_FocusWait = { stamp = p.stamp, nextAt = m_Clock + 0.3, untilClock = m_Clock + SHOT_WAIT, cmd = cmd, shot = true }
	Log(cmd .. ": units deselected, " .. n .. " VEF notification(s) dismissed")
	Send(p)
end

-- Eligibility tests T1 / T2: stamped request, then the UI check (EligUI).
local function Elig(cmd, test)
	local p = BaseParams(cmd)
	m_Elig = nil
	m_EligStatus = test .. ": waiting for gameplay..."
	m_FocusWait = { stamp = p.stamp, nextAt = m_Clock + 0.3, untilClock = m_Clock + SHOT_WAIT, cmd = cmd, elig = test }
	Send(p)
	RefreshInfo()
end

-- ---------------------------------------------------------------------------
-- Buttons: cmd = gameplay command (EFV_Dev_Gameplay.lua), ui = local function
-- ---------------------------------------------------------------------------
local UIFN = { ForgeSend = ForgeSend, ForgeRecall = ForgeRecall, ForgeEntrust = ForgeEntrust, UIStore = UIStore,
	VetStart = VetStart, GoTo = GoTo }

local BUTTONS = {
	{ header = "Screenshots (VEF 0.7+, new game after one End Turn)" },
	{ label = "Shot 1 Send picker",     shot = "shot1" },
	{ label = "Shot 2 Arrival",         shot = "shot2" },
	{ label = "Shot 3 Tracker",         shot = "shot3" },
	{ label = "Shot 4 Entrust",         shot = "shot4" },
	{ label = "Shot 5 Mutiny",          shot = "shot5" },
	{ header = "Test sessions (EFV/TESTING_RETEST_0.7.md, TESTING_FINAL.md): start a NEW game; one click sets up each step" },
	{ label = "S0 Setup session",       scn = "scn_setup" },
	{ label = "S1 Arrive next turn",    scn = "scn_arrive" },
	{ label = "S2 Expire CS unit (off its land)", scn = "scn_expire_cs" },
	{ label = "S3 Grace/mutiny step",   scn = "scn_grace" },
	{ label = "S4 Lapse on/off",        scn = "scn_lapse" },
	{ label = "S5 Upgrade test",        scn = "scn_upgrade" },
	{ label = "S6 Veteran copies",      ui = "VetStart" },
	{ label = "S7 Killed unit",         scn = "scn_kill" },
	{ label = "S8 Relink guard",        scn = "scn_guard" },
	{ label = "S9 Crowded arrival",     scn = "scn_place" },
	{ label = "S10 Mutiny combat",      scn = "scn_t31" },
	{ label = "S11 Entrust city",       scn = "scn_entrust" },
	{ label = "S12 Veteran return",     scn = "scn_vetret" },
	{ label = "S13 Unit in B's land",   scn = "scn_inland" },
	{ label = "S14 Mutiny death",       scn = "scn_mutdeath" },
	{ label = "S15 Receive forces",     shot = "scn_receive" },
	{ label = "S16 Break transit",      scn = "scn_cancel" },
	{ label = "T1 Volunteer partners",  elig = "elig_t1", test = "T1" },
	{ label = "T2 Shared enemy",        elig = "elig_t2", test = "T2" },
	{ label = "Go to scenario",         ui = "GoTo" },
	{ label = "Check now",              cmd = "scn_check" },
	{ header = "Units (selected unit, or extra rec=<id>; Type/Amount fields)" },
	{ label = "Spawn Type x Amt -> Tgt", cmd = "spawn" },
	{ label = "Fill rings (Amt) -> Tgt", cmd = "fill" },
	{ label = "Damage = Amount",        cmd = "damage" },
	{ label = "Heal",                   cmd = "heal" },
	{ label = "XP + Amount",            cmd = "xp" },
	{ label = "Promote (Type)",         cmd = "promote" },
	{ label = "Finish moves",           cmd = "finish" },
	{ label = "Corps on/off (Amt 0)",   cmd = "corps" },
	{ label = "Kill (Destroy)",         cmd = "kill" },
	{ label = "Place at tx,ty (extra)", cmd = "place" },
	{ label = "Unit info (G)",          cmd = "unit" },
	{ header = "Economy (me; extra who=<pid>)" },
	{ label = "Gold + Amount",          cmd = "gold" },
	{ label = "Set gold = Amount",      cmd = "setgold" },
	{ label = "Resource + Amount",      cmd = "res" },
	{ label = "Set resource = Amt",     cmd = "setres" },
	{ header = "Diplomacy (me or extra a=<pid>, with Target)" },
	{ label = "Ally (Amt 0 = end)",     cmd = "ally" },
	{ label = "Friend (Amt 0 = end)",   cmd = "friend" },
	{ label = "War",                    cmd = "war" },
	{ label = "Peace (try)",            cmd = "peace" },
	{ label = "Meet",                   cmd = "meet" },
	{ label = "Diplo matrix",           cmd = "diplo" },
	{ header = "VEF records (selected unit's record, or extra rec=<id>)" },
	{ label = "Dump",                   cmd = "dump" },
	{ label = "List records",           cmd = "records" },
	{ label = "Shift clock by Amt",     cmd = "shift" },
	{ label = "Expire next turn",       cmd = "expire" },
	{ label = "Set field (extra)",      cmd = "setfield" },
	{ label = "VEF properties",         cmd = "state" },
	{ label = "UI store (UI)",          ui = "UIStore" },
	{ header = "Forged VEF requests (Target = recipient; Type = force; Amount = expectedFee)" },
	{ label = "EFV_Send sel. unit",     ui = "ForgeSend" },
	{ label = "EFV_Recall sel. unit",   ui = "ForgeRecall" },
	{ label = "EFV_Entrust sel. city",  ui = "ForgeEntrust" },
}

local function OnButton(def)
	RefreshInfo()
	if def.ui ~= nil then
		local ok, err = pcall(UIFN[def.ui])
		if not ok then Log(def.label .. " threw: " .. Str(err)) end
	elseif def.shot ~= nil then
		Shot(def.shot)
	elseif def.elig ~= nil then
		Elig(def.elig, def.test)
	elseif def.scn ~= nil then
		Scenario(def.scn)
	else
		DevCommand(def.cmd)
	end
end

local function BuildButtons()
	m_ButtonIM:ResetInstances()
	m_HeaderIM:ResetInstances()
	for _, def in ipairs(BUTTONS) do
		if def.header ~= nil then
			local h = m_HeaderIM:GetInstance()
			h.HeaderLabel:SetText(def.header)
		else
			local b = m_ButtonIM:GetInstance()
			b.Button:SetText(def.label)
			b.Button:RegisterCallback(Mouse.eLClick, function() OnButton(def) end)
		end
	end
	Controls.ButtonStack:CalculateSize()
	Controls.ButtonScroll:CalculateInternalSize()
end

-- ---------------------------------------------------------------------------
-- Show / hide, hotkey, launch bar
-- ---------------------------------------------------------------------------
SetOpen = function(open)
	m_Open = open and true or false
	if ContextPtr:IsHidden() then ContextPtr:SetHide(false) end
	if m_Open then
		HideLaunch(false)
		RebuildTargets()
		RefreshInfo()
	end
	Controls.Main:SetHide(not m_Open)
end

local function Toggle()
	SetOpen(not m_Open)
end

local function OnInput(pInput)
	if pInput:GetMessageType() == KeyEvents.KeyUp then
		local key = pInput:GetKey()
		if key == Keys.D and pInput:IsControlDown() and pInput:IsShiftDown() then
			Toggle()
			return true
		end
		if key == Keys.VK_ESCAPE and m_Open then
			SetOpen(false)
			return true
		end
	end
	return false
end

local function AttachLaunchButton()
	if m_LaunchDone then return end
	m_LaunchDone = true
	local ok, err = pcall(function()
		local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
		ContextPtr:BuildInstanceForControl("DevLaunchBarItem", m_LaunchInst, buttonStack)
		m_LaunchInst.LaunchItemButton:RegisterCallback(Mouse.eLClick, Toggle)
		ContextPtr:BuildInstanceForControl("DevLaunchBarPinInstance", {}, buttonStack)
		buttonStack:CalculateSize()
		local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
		backing:SetSizeX(buttonStack:GetSizeX() + 116)
		local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
		backingTile:SetSizeX(buttonStack:GetSizeX() - 20)
		LuaEvents.LaunchBar_Resize(buttonStack:GetSizeX())
	end)
	Log("launch bar button ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " (Ctrl+Shift+D works regardless)")
end

local function OnSelectionChanged()
	if m_Open then RefreshInfo() end
end

local function Subscribe(label, getter, fn)
	local ok, err = pcall(function()
		local ev = getter()
		if ev == nil then error("event is nil") end
		ev.Add(function(...)
			local okH, errH = pcall(fn, ...)
			if not okH then Log(label .. " listener error: " .. Str(errH)) end
		end)
	end)
	if not ok then Log("subscribe FAILED " .. label .. ": " .. Str(err)) end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)       -- contexts load hidden (INTERFACES note 19)
	Controls.Main:SetHide(true)
	ContextPtr:SetInputHandler(OnInput, true)
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, function() SetOpen(false) end)
	Controls.RefreshButton:RegisterCallback(Mouse.eLClick, RefreshInfo)
	Controls.TargetPrev:RegisterCallback(Mouse.eLClick, OnTargetPrev)
	Controls.TargetNext:RegisterCallback(Mouse.eLClick, OnTargetNext)
	Controls.TypeEdit:SetText("UNIT_SWORDSMAN")
	ContextPtr:SetUpdate(OnUpdate)
	BuildButtons()
	Subscribe("Events.LoadGameViewStateDone", function() return Events.LoadGameViewStateDone end, AttachLaunchButton)
	Subscribe("Events.UnitSelectionChanged", function() return Events.UnitSelectionChanged end, OnSelectionChanged)
	Subscribe("Events.PlayerTurnActivated", function() return Events.PlayerTurnActivated end, OnSelectionChanged)
	Subscribe("LuaEvents.EFV_BadgeAuditReport", function() return LuaEvents.EFV_BadgeAuditReport end, OnAuditReport)
	Subscribe("Events.PlayerTurnActivated (audit)", function() return Events.PlayerTurnActivated end, function(pid)
		if pid == LocalID() then ScheduleAudit("turn start", true) end
	end)
	Subscribe("Events.UnitAddedToMap (audit)", function() return Events.UnitAddedToMap end, function() ScheduleAudit("unit added") end)
	Subscribe("Events.UnitRemovedFromMap (audit)", function() return Events.UnitRemovedFromMap end, function() ScheduleAudit("unit removed") end)
	Subscribe("Events.UnitKilledInCombat (audit)", function() return Events.UnitKilledInCombat end, function() ScheduleAudit("unit killed") end)
	RebuildTargets()
	Log("ready (Ctrl+Shift+D); EFV_UIShared loaded=" .. tostring(m_UIShared and EFV_UI_ReadStore ~= nil))
end

Initialize()
