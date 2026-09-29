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
-- EFV:GLOBALS EFV_Config EFV_UI_ReadStore EFV_UI_RecordForUnit EFV_UI_StateText

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

local function SessionText()
	local ok, st = pcall(function() return Game:GetProperty("EFV_DEV_SCN") end)
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
	Controls.RecordLabel:SetText(RecordText(unit))
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

local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_FocusWait ~= nil and m_Clock >= m_FocusWait.nextAt then
		m_FocusWait.nextAt = m_Clock + 0.3
		local st = ScnState()
		local f = st and st.focus
		if type(f) == "table" and f.stamp == m_FocusWait.stamp then
			LookAt(f)
			if m_FocusWait.cmd == "scn_setup" and st.ally ~= nil then TargetTo(st.ally) end
			m_FocusWait = nil
		elseif m_Clock > m_FocusWait.untilClock then
			m_FocusWait = nil
		end
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

-- ---------------------------------------------------------------------------
-- Buttons: cmd = gameplay command (EFV_Dev_Gameplay.lua), ui = local function
-- ---------------------------------------------------------------------------
local UIFN = { ForgeSend = ForgeSend, ForgeRecall = ForgeRecall, ForgeEntrust = ForgeEntrust, UIStore = UIStore,
	VetStart = VetStart, GoTo = GoTo }

local BUTTONS = {
	{ header = "Final session (EFV/TESTING_FINAL.md): start a NEW game; one click sets up each step" },
	{ label = "S0 Setup session",       scn = "scn_setup" },
	{ label = "S1 Arrive next turn",    scn = "scn_arrive" },
	{ label = "S2 Expire CS unit",      scn = "scn_expire_cs" },
	{ label = "S3 Grace/mutiny step",   scn = "scn_grace" },
	{ label = "S4 Lapse on/off",        scn = "scn_lapse" },
	{ label = "S5 Upgrade test",        scn = "scn_upgrade" },
	{ label = "S6 Veteran copies",      ui = "VetStart" },
	{ label = "S7 Killed unit",         scn = "scn_kill" },
	{ label = "S8 Relink guard",        scn = "scn_guard" },
	{ label = "S9 Crowded arrival",     scn = "scn_place" },
	{ label = "S10 Mutiny combat",      scn = "scn_t31" },
	{ label = "S11 Entrust city",       scn = "scn_entrust" },
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
local function SetOpen(open)
	m_Open = open and true or false
	if ContextPtr:IsHidden() then ContextPtr:SetHide(false) end
	if m_Open then
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
	RebuildTargets()
	Log("ready (Ctrl+Shift+D); EFV_UIShared loaded=" .. tostring(m_UIShared and EFV_UI_ReadStore ~= nil))
end

Initialize()
