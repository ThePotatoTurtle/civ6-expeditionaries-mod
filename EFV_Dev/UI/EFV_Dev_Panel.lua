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
--
-- Register limit: Civ VI's Havok Script rejects a function that needs too
-- many registers ("too complex"; 172 loads, 206 fails), and every main-chunk
-- local holds one register until the end of its block. So each section keeps
-- its private helpers inside its own do ... end block; only the names other
-- sections use are declared just before the block. tools/check_lua.py
-- (check_all) fails above 180.
-- ===========================================================================
include("InstanceManager")
-- EFV's UI API (EFV_UI_ReadStore, EFV_UI_RecordForUnit, ...). Guarded: the panel
-- must keep working even if EFV's UI module fails to load.
local m_UIShared = pcall(include, "EFV_UIShared")
include("EFV_Config")
-- EFV:GLOBALS EFV_Config EFV_UI_ReadStore EFV_UI_RecordForUnit EFV_UI_StateText EFV_UI_TrackerState EFV_SortedKeys EFV_UI_RecordsFor EFV_UI_TrackedUnit
-- EFV:GLOBALS EFV_DestinationRows EFV_PartnerBasis EFV_VolunteerBasis EFV_UI_TrackerRows EFV_UI_EntrustState
-- EFV:GLOBALS EFV_UI_DenounceTurnsLeft EFV_UnitSendReasons

local PREFIX = "[EFV][Dev][UI]"
-- Dev-tools version and the VEF build they are made for (EFV_Dev 1.0.5.2;
-- keep equal to EFV_Dev.VERSION / EFV_Dev.FOR_EFV in EFV_Dev_Gameplay.lua,
-- test_dev_mod checks it). The panel title shows both and the VEF version
-- that is really loaded (EFV_Config.VERSION from VEF's own files), so a
-- tester sees at a glance whether the local copy or the Workshop copy runs.
local DEV_VERSION = "1.0.5.2"
local DEV_FOR_EFV = "1.0.5"
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
	-- VEF 1.0.5 test (P1 leaves F, C and CS empty)
	if ok and type(st) == "table" and type(st.proxy) == "table" and st.proxy.b ~= nil then
		return "Proxy test: B=" .. CivName(st.proxy.b) .. " E=" .. CivName(st.proxy.e) .. " X=" .. CivName(st.proxy.x)
	end
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

local m_EligStatus = nil     -- short T1 / T2 / denounce / air spike result shown in the panel

-- Title line: "VEF Dev 1.0.4.3 | VEF 1.0.4  (Ctrl+Shift+D)", or a warning
-- when the loaded VEF is not the build these tools are made for.
local function TitleText()
	local v = (EFV_Config ~= nil) and EFV_Config.VERSION or nil
	if v ~= DEV_FOR_EFV then
		return "VEF Dev " .. DEV_VERSION .. " | WRONG VEF " .. Str(v) .. ", needs " .. DEV_FOR_EFV
	end
	return "VEF Dev " .. DEV_VERSION .. " | VEF " .. Str(v) .. "  (Ctrl+Shift+D)"
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
	Controls.RecordLabel:SetText((m_EligStatus and (m_EligStatus .. " | ") or "") .. RecordText(unit))
	Controls.TargetLabel:SetText(PlayerName(CurrentTarget()))
	-- the status may take several lines (denounce probe): move the rows below it
	pcall(function() Controls.MainStack:CalculateSize() end)
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
local m_Clock, m_FocusWait, m_Vet, VET_TIMEOUT, ScnState, UICheck, OwnUnit, LookAt, GoTo, Level
local HasPromo, VetStart, VetStep
do
local SCN_PROP = "EFV_DEV_SCN"
m_Clock = 0
m_FocusWait = nil           -- { stamp, nextAt, untilClock } after a scenario button
m_Vet = nil                 -- S6 route B state
VET_TIMEOUT = 10            -- seconds without a gameplay answer
local VET_PROMO_WAIT = 5    -- seconds for a PROMOTE command to land
local ROUTE = {
	A = "route A (XP to the threshold, then SetPromotion)",
	B = "route B (XP to the threshold, then the PROMOTE command)",
	C = "route C (SetPromotion only: the current restore)",
}

function ScnState()
	local ok, st = pcall(function() return Game:GetProperty(SCN_PROP) end)
	if ok and type(st) == "table" then return st end
	return nil
end

function UICheck(id, verdict, msg)
	local t = -1
	pcall(function() t = Game.GetCurrentGameTurn() end)
	print("[EFV][CHECK] " .. Str(id) .. " " .. Str(verdict) .. " T" .. Str(t) .. " " .. Str(msg))
end

function OwnUnit(o, id)
	o, id = tonumber(o), tonumber(id)
	if o == nil or id == nil or Players[o] == nil then return nil end
	local u = nil
	pcall(function() u = Players[o]:GetUnits():FindID(id) end)
	if u ~= nil and u:GetID() ~= id then return nil end
	return u
end

function LookAt(f)
	if type(f) ~= "table" or f.x == nil or f.y == nil or f.x < 0 then return false end
	pcall(function() UI.LookAtPlot(f.x, f.y) end)
	if f.o == LocalID() then
		local u = OwnUnit(f.o, f.u)
		if u ~= nil then pcall(function() UI.SelectUnit(u) end) end
	end
	return true
end

function GoTo()
	local st = ScnState()
	if not LookAt(st and st.focus) then Log("go to scenario: no scenario position yet") end
end

function Level(u)
	if u == nil then return nil end
	local ok, l = pcall(function() return u:GetExperience():GetLevel() end)
	if ok then return tonumber(l) end
	return nil
end

function HasPromo(u, row)
	local ok, has = pcall(function()
		for _, idx in ipairs(u:GetExperience():GetPromotions()) do
			if idx == row.Index then return true end
		end
		return false
	end)
	return ok and has == true
end

function VetStart()
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

function VetStep()
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
end -- Final session

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
local SHOT_WAIT, m_Shot, SetOpen, HideLaunch, DismissVefNotifications, ShotID, StartShot, ShotStep
do
SHOT_WAIT = 8
m_Shot = nil                -- { cmd, id, f, phase, nextAt, relookAt, untilClock }
-- SetOpen: forward, defined with the show / hide code below

function HideLaunch(hide)
	pcall(function() m_LaunchInst.LaunchItemButton:SetHide(hide) end)
end

-- Dismisses the local player's VEF notifications (every EFV_Config.NOTIF
-- type; the EFV_Tracker SweepStale pattern). Returns the number dismissed.
function DismissVefNotifications()
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

-- S17 (scn_labels, EFV_Dev 1.0.3.2) runs the same way: it opens the tracker.
function ShotID(cmd)
	if cmd == "scn_labels" then return "TRACKER_LABELS" end
	if not IsShotCmd(cmd) then return "RECEIVE" end
	return "SHOT" .. string.sub(Str(cmd), 5)
end

function StartShot(cmd, f)
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

function ShotStep()
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
end -- Workshop Shot buttons, UI side

-- ---------------------------------------------------------------------------
-- 0.7 re-test UI checks (EFV/TESTING_RETEST_0.7.md), polled every 0.5 s:
--   VET_RESTORE_LEVEL  S12: once gameplay named VEF-VET's unit (st.s12.uid)
--                      and its route B job is gone from the store: level 3
--                      (GetLevel is UI only), XP 50/90, damage 30, the unit
--                      panel name logged; then Check now for VET_RESTORE
--   LAPSE_TEXT         the first paused lapse of a local Volunteer record in
--                      GRACE: the tracker state reads "Lapse: Grace N (paused)"
-- ---------------------------------------------------------------------------
local m_CheckAt, VetLevelCheck, LapseTextCheck
do
m_CheckAt = 0
local m_VetLevelDone = {}
local m_LapseSeen = {}

function VetLevelCheck()
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

function LapseTextCheck()
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
end -- 0.7 re-test UI checks

-- ---------------------------------------------------------------------------
-- VEF 1.0.3 session UI checks (EFV_Dev 1.0.3.2; EFV/TESTING_1.0.3.md),
-- polled with the ones above:
--   TRACKER_LABELS    S17: the tracker rows of the four S17 records, read
--                     with VEF's own EFV_UI_TrackerRows for the local
--                     player: Inbound / Departed on the rows sent to you,
--                     Outbound / Returning on yours; the Departed and
--                     Returning tooltips carry their state sentence. One
--                     line per row, then a summary. Waits up to 5 s for the
--                     UI store to show the records.
--   ENTRUST_CS_UI     S18 / S19: once the scene's city is yours and VEF's
--   ENTRUST_MAJOR_UI  capture snapshot is there, VEF's own
--                     EFV_UI_EntrustState (what the Entrust button shows):
--                     S18 must offer B (the old owner is a city-state),
--                     S19 must be greyed with ENTRUST_NO_PARTNER.
-- ---------------------------------------------------------------------------
local CurrentTurn, LabelsCheck, Listed, EntrustUICheck
do
local m_LabelsDone = {}
local m_LabelsSince = {}
local m_EntrustDone = {}

local function Plain(s)
	s = string.gsub(Str(s), "%[COLOR[^%]]*%]", "")
	s = string.gsub(s, "%[ENDCOLOR%]", "")
	return s
end

function CurrentTurn()
	local t = -1
	pcall(function() t = Game.GetCurrentGameTurn() end)
	return tonumber(t) or -1
end

function LabelsCheck()
	local st = ScnState()
	local s = st and st.s17
	if type(s) ~= "table" or s.stamp == nil or m_LabelsDone[s.stamp] or st.me ~= LocalID() then return end
	if type(EFV_UI_TrackerRows) ~= "function" then
		m_LabelsDone[s.stamp] = true
		UICheck("TRACKER_LABELS", "CHECK", "VEF's tracker functions are not loaded (EFV_UIShared)")
		return
	end
	local turn = CurrentTurn()
	if turn ~= tonumber(s.turn) then m_LabelsDone[s.stamp] = true; return end
	local byId = {}
	for _, r in ipairs(EFV_UI_TrackerRows(LocalID(), turn)) do byId[r.id] = r end
	local missing = 0
	for _, e in ipairs(s.rows or {}) do
		if byId[e.id] == nil then missing = missing + 1 end
	end
	if missing > 0 then
		m_LabelsSince[s.stamp] = m_LabelsSince[s.stamp] or m_Clock
		if m_Clock - m_LabelsSince[s.stamp] < 5 then return end
	end
	m_LabelsDone[s.stamp] = true
	local pass, n = 0, 0
	for _, e in ipairs(s.rows or {}) do
		n = n + 1
		local r = byId[e.id]
		local want = Locale.Lookup("LOC_EFV_TRACKER_ST_" .. Str(e.role))
		if r == nil then
			UICheck("TRACKER_LABELS", "FAIL", Str(e.role) .. " record " .. Str(e.id) .. ": no tracker row (expected '" .. want .. "')")
		else
			local got = Plain(r.state)
			local ok = got == want
			local extra = ""
			local left = math.max(0, (tonumber(r.rec and r.rec.arrivalTurn) or turn) - turn)
			local sentence = nil
			if e.role == "DEPARTED" then sentence = Locale.Lookup("LOC_EFV_STATE_DEPARTED", left) end
			if e.role == "RETURNING" then sentence = Locale.Lookup("LOC_EFV_STATE_RETURNING", left) end
			if sentence ~= nil then
				local has = string.find(Plain(r.tooltip), sentence, 1, true) ~= nil
				ok = ok and has
				extra = "; tooltip " .. (has and "has" or "LACKS") .. " '" .. sentence .. "'"
			end
			if ok then pass = pass + 1 end
			UICheck("TRACKER_LABELS", ok and "PASS" or "FAIL", Str(e.role) .. " record " .. Str(e.id) .. " (" .. Plain(r.unit) .. ", " ..
				Plain(r.partner) .. "): tracker shows '" .. got .. "' (expected '" .. want .. "')" .. extra)
		end
	end
	UICheck("TRACKER_LABELS", (pass == n and n > 0) and "PASS" or "FAIL", "summary: " .. pass .. "/" .. n ..
		" rows as expected (received: Inbound, Departed; sent: Outbound, Returning)")
end

function Listed(list, v)
	for _, x in ipairs(list or {}) do
		if x == v then return true end
	end
	return false
end

local function Names(ids)
	local out = {}
	for _, pid in ipairs(ids or {}) do out[#out + 1] = CivName(pid) end
	return #out > 0 and table.concat(out, ", ") or "none"
end

function EntrustUICheck()
	local st = ScnState()
	if st == nil or st.me ~= LocalID() or type(EFV_UI_EntrustState) ~= "function" then return end
	for _, spec in ipairs({ { key = "s18", id = "ENTRUST_CS_UI" }, { key = "s19", id = "ENTRUST_MAJOR_UI" } }) do
		local s = st[spec.key]
		if type(s) == "table" and s.cx ~= nil then
			local tag = spec.key .. ":" .. Str(s.cx) .. "," .. Str(s.cy) .. ":" .. Str(s.turn)
			local city = nil
			pcall(function() city = CityManager.GetCityAt(s.cx, s.cy) end)
			if not m_EntrustDone[tag] and city ~= nil and city:GetOwner() == LocalID() then
				local ok, es = pcall(EFV_UI_EntrustState, LocalID(), s.cx, s.cy)
				if ok and type(es) == "table" and type(es.snap) == "table" then
					m_EntrustDone[tag] = true
					local enabled = {}
					for _, row in ipairs(es.rows or {}) do
						if #(row.codes or {}) == 0 then enabled[#enabled + 1] = row.recipientID end
					end
					local codes = table.concat(es.codes or {}, "+")
					local facts = "old owner " .. CivName(es.snap.oldOwnerID) .. ", snapshot recipients " .. Names(es.snap.recipients) ..
						", partners " .. Names(es.snap.partners) .. ", button " .. (#enabled > 0 and ("enabled for " .. Names(enabled)) or
						("greyed (" .. (codes ~= "" and codes or "no reason") .. ")"))
					if spec.key == "s18" then
						local pass = Listed(enabled, st.ally) or Listed(enabled, st.friend)
						UICheck(spec.id, pass and "PASS" or "FAIL", "city-state city captured: " .. facts ..
							(pass and "; a partner at peace with the city-state can take it" or "; expected B (or F) to be offered"))
					else
						local pass = #enabled == 0 and Listed(es.codes, "ENTRUST_NO_PARTNER")
						UICheck(spec.id, pass and "PASS" or "FAIL", "living major's city captured: " .. facts ..
							(pass and "; still greyed, nobody was at war with it" or "; expected greyed with ENTRUST_NO_PARTNER"))
					end
				end
			end
		end
	end
end
end -- VEF 1.0.3 session UI checks

-- ---------------------------------------------------------------------------
-- V Veteran spike, UI side (EFV_Dev 1.0.3.2; gameplay: "V Veteran spike" in
-- EFV_Dev_Gameplay.lua). After the V button's answer (st.vs, same stamp)
-- the panel restores V0, V1 and V2 like EFV_VetRestore does for a real
-- veteran: for each copy the first wanted promotion the engine offers
-- (UnitManager.CanStartCommand(u, PROMOTE, true, true) ->
-- UnitCommandResults.PROMOTIONS, UnitPromotionPopup.lua:81-82, 285-290) is
-- sent with UnitManager.RequestCommand(u, PROMOTE, { PARAM_PROMOTION_TYPE })
-- (UnitPromotionPopup.lua:70-72); once it landed, vs_sync lets gameplay
-- sync (XP to the next threshold; V2: moves back). V1 then gets vs_off (the
-- keep-moves ability removed) and one more normal promotion, whose moves
-- must be 0 (VSPIKE_V1_OFF). The copies' UI state (GetLevel is UI only) is
-- logged as VSPIKE_UI lines at every step and at each new turn, for
-- VS_TURNS turns after the press. Verdicts:
--   VSPIKE_V0  PASS: exactly 1 promotion in the first turn, then PROMOTE is
--              not offered (the limit reproduced); INFO when all are back.
--   VSPIKE_V1  PASS: all wanted promotions in the first turn, level 1 + n.
--   VSPIKE_V2  the same for V2.
--   VSPIKE_V3  PASS: level 1 + n, XP kept, no pending promotion.
-- The runner lives in UI memory (a reload stops it; the gameplay lines
-- continue at each turn start). Play a civ other than Gran Colombia: the
-- button logs a CHECK line when the local civ is Gran Colombia
-- (PlayerConfigurations[id]:GetCivilizationTypeName(), Civ6Common.lua:580).
-- Other UI calls: exp:GetLevel() (UI only; UnitPanel.lua:2264),
-- exp:GetPromotions() (UI only; Session A T09), u:GetMovesRemaining() /
-- GetMaxMoves() / GetMaxDamage() / GetDamage() (PLAN A23, A25).
-- ---------------------------------------------------------------------------
local m_VS, VsStart, VsStep
do
local VS_WAIT_S = 3.0       -- first turn: no wanted promotion offered this long = the limit
local VS_RESEND_S = 3.0
local VS_TURNS = 3
local VS_METHOD = {
	V0 = "V0 control (route B, one PROMOTE per turn)",
	V1 = "V1 hidden keep-moves ability + chained PROMOTE",
	V2 = "V2 moves restored after each promotion",
	V3 = "V3 level-adjust ability + SetPromotion + XP",
}
m_VS = nil

local function VsNames(u)
	local out = {}
	pcall(function()
		for _, idx in ipairs(u:GetExperience():GetPromotions() or {}) do
			local row = GameInfo.UnitPromotions[idx]
			out[#out + 1] = row and row.UnitPromotionType or Str(idx)
		end
	end)
	return out
end

local function VsWanted(u, promos)
	local n = 0
	for _, nm in ipairs(promos or {}) do
		local row = GameInfo.UnitPromotions[nm]
		if row ~= nil and HasPromo(u, row) then n = n + 1 end
	end
	return n
end

-- Indexes the engine offers for PROMOTE now, and whether PROMOTE can start.
local function VsOffered(u)
	local ok, can, res = pcall(function() return UnitManager.CanStartCommand(u, UnitCommandTypes.PROMOTE, true, true) end)
	if not ok or not can or type(res) ~= "table" then return {}, false end
	local list = res[UnitCommandResults.PROMOTIONS]
	if type(list) ~= "table" then return {}, true end
	return list, true
end

local function VsMoves(u)
	local m = -1
	pcall(function() m = u:GetMovesRemaining() end)
	return tonumber(m) or -1
end

local function VsUIState(u)
	if u == nil then return "unit not found" end
	local s = "?"
	pcall(function()
		local exp = u:GetExperience()
		local list, can = VsOffered(u)
		local names = VsNames(u)
		s = "level=" .. Str(Level(u)) .. " moves=" .. Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves()) .. " xp=" ..
			Str(exp:GetExperiencePoints()) .. "/" .. Str(exp:GetExperienceForNextLevel()) .. " PROMOTE=" ..
			(can and ("yes(" .. #list .. ")") or "no") .. " hp=" .. Str(u:GetMaxDamage() - u:GetDamage()) .. " promotions=" ..
			(#names > 0 and table.concat(names, "+") or "-")
	end)
	return s
end

local function VsUILog(k, step, u)
	UICheck("VSPIKE_UI", "INFO", Str(k) .. " " .. step .. " | " .. VsUIState(u))
end

local function VsPromote(u, row, k, attempt)
	local ok, err = pcall(function()
		local t = {}
		t[UnitCommandTypes.PARAM_PROMOTION_TYPE] = row.Index
		UnitManager.RequestCommand(u, UnitCommandTypes.PROMOTE, t)
	end)
	VsUILog(k, "PROMOTE " .. Str(row.UnitPromotionType) .. " sent (attempt " .. attempt .. ", ok=" .. tostring(ok) ..
		(ok and "" or (" err=" .. Str(err))) .. ")", u)
end

function VsStart()
	local civ = nil
	pcall(function() civ = PlayerConfigurations[LocalID()]:GetCivilizationTypeName() end)
	if civ == "CIVILIZATION_GRAN_COLOMBIA" then
		UICheck("VSPIKE", "CHECK", "you play Gran Colombia: its trait lets every promotion keep the unit's moves, so the spike " ..
			"cannot show the one-per-turn limit. Start a new game with another civ")
	end
	local p = BaseParams("vs_start")
	m_VS = { stamp = p.stamp, phase = "wait", t0 = m_Clock, nextAt = m_Clock + 0.5, m = {}, civ = civ }
	Send(p)
end

local function VsSend(cmd, k, have)
	local q = BaseParams(cmd)
	q.k = k
	if have ~= nil then q.have = have end
	Send(q)
end

-- One copy, one poll (see the header).
local function VsCopy(v, vs, c, turn, newTurn)
	local k = Str(c.k)
	local m = v.m[k]
	if m == nil then
		m = { phase = "run" }
		v.m[k] = m
	end
	if m.phase == "gone" then return end
	local u = OwnUnit(LocalID(), c.u)
	if u == nil then
		m.phase = "gone"
		UICheck("VSPIKE_" .. k, "CHECK", VS_METHOD[k] .. ": copy VEF-" .. k .. " (unit " .. Str(c.u) .. ") not found")
		return
	end
	local promos = vs.promos or {}
	local want = #promos
	local first = (turn == v.turn0)
	local held = #VsNames(u)
	local wanted = VsWanted(u, promos)
	if newTurn then VsUILog(k, first and "start" or "turn start", u) end
	if k == "V3" then
		if not m.verdict then
			m.verdict = true
			local lvl = Level(u)
			local list, can = VsOffered(u)
			local xp, nxt = -1, -1
			pcall(function()
				local e = u:GetExperience()
				xp, nxt = e:GetExperiencePoints(), e:GetExperienceForNextLevel()
			end)
			local ok = lvl == 1 + want and not can and xp == tonumber(vs.xp) and wanted == want
			m.nxt = nxt
			UICheck("VSPIKE_V3", ok and "PASS" or "CHECK", VS_METHOD.V3 .. ": level " .. Str(lvl) .. " (want " .. (1 + want) ..
				"), XP " .. Str(xp) .. "/" .. Str(nxt) .. " (want XP " .. Str(vs.xp) .. "), PROMOTE offered " ..
				(can and ("yes, " .. #list .. " choice(s)") or "no") .. ", promotions " .. wanted .. "/" .. want)
		end
		return
	end
	if m.lastHeld ~= nil and held > m.lastHeld then
		VsUILog(k, "promotion " .. held .. " landed", u)
		m.waitSince = nil
		if first and k == "V0" and wanted >= 2 and not m.v1 then
			m.v1 = true
			UICheck("VSPIKE_V0", "CHECK", VS_METHOD.V0 .. ": a 2nd promotion landed in the first turn, so there is no one-per-turn " ..
				"limit here (Gran Colombia, or promoting keeps the moves)")
		end
	end
	m.lastHeld = held
	if held > (tonumber(c.synced) or 0) then
		if m.syncFor ~= held or m_Clock - (m.syncAt or 0) >= VS_RESEND_S then
			VsSend("vs_sync", k, held)
			m.syncFor, m.syncAt = held, m_Clock
		end
		return
	end
	if m.phase == "run" then
		if wanted >= want then
			local lvl = Level(u)
			local span = first and "in the first turn" or ("by turn " .. turn .. " (" .. (turn - v.turn0 + 1) .. " turns)")
			if k == "V0" then
				UICheck("VSPIKE_V0", "INFO", VS_METHOD.V0 .. ": all " .. want .. " promotions back " .. span .. ", level " .. Str(lvl))
			else
				local ok = first and lvl == 1 + want
				UICheck("VSPIKE_" .. k, ok and "PASS" or "CHECK", VS_METHOD[k] .. ": " .. wanted .. "/" .. want .. " promotions " .. span ..
					", level " .. Str(lvl) .. " (want " .. (1 + want) .. "), moves " .. VsMoves(u))
				m.v1 = true
			end
			if k == "V1" then
				m.phase = "off"
				m.offAt = m_Clock
				VsSend("vs_off", k)
			else
				m.phase = "done"
			end
			return
		end
		local list = VsOffered(u)
		local pick = nil
		for _, nm in ipairs(promos) do
			local row = GameInfo.UnitPromotions[nm]
			if pick == nil and row ~= nil and not HasPromo(u, row) and Listed(list, row.Index) then pick = row end
		end
		if pick ~= nil then
			if m.promFor ~= held then
				m.promFor, m.promAt, m.promN = held, m_Clock, 1
				VsPromote(u, pick, k, 1)
			elseif (m.promN or 1) < 2 and m_Clock - (m.promAt or 0) >= VS_RESEND_S then
				m.promN, m.promAt = 2, m_Clock
				VsPromote(u, pick, k, 2)
			end
			m.waitSince = nil
			return
		end
		if m.waitSince == nil then
			m.waitSince = m_Clock
			VsUILog(k, "no wanted promotion offered", u)
		end
		if first and not m.v1 and m_Clock - m.waitSince >= VS_WAIT_S then
			m.v1 = true
			if k == "V0" then
				UICheck("VSPIKE_V0", wanted == 1 and "PASS" or "CHECK", VS_METHOD.V0 .. ": " .. wanted .. " promotion(s) in the first turn, " ..
					"then PROMOTE is not offered (moves " .. VsMoves(u) .. "): " .. (wanted == 1 and "the one-per-turn limit is reproduced" or
					"expected exactly 1"))
			else
				UICheck("VSPIKE_" .. k, "CHECK", VS_METHOD[k] .. ": stopped at " .. wanted .. "/" .. want .. " in the first turn, " ..
					"PROMOTE not offered (moves " .. VsMoves(u) .. ")")
			end
		end
		return
	end
	if m.phase == "off" then
		if tonumber(c.off) == 1 then
			local list = VsOffered(u)
			local row = list[1] ~= nil and GameInfo.UnitPromotions[list[1]] or nil
			if row ~= nil then
				m.offBase = held
				m.phase = "offwait"
				m.offAt = m_Clock
				VsPromote(u, row, k, 1)
			elseif m_Clock - (m.offAt or 0) > VS_WAIT_S then
				m.phase = "done"
				UICheck("VSPIKE_V1_OFF", "CHECK", "after the keep-moves ability was removed no promotion is offered (" .. VsUIState(u) .. ")")
			end
		elseif m_Clock - (m.offAt or 0) > VS_RESEND_S * 2 then
			m.phase = "done"
			UICheck("VSPIKE_V1_OFF", "CHECK", "no answer from gameplay to vs_off")
		end
		return
	end
	if m.phase == "offwait" then
		if held > (m.offBase or held) then
			local mv = VsMoves(u)
			m.phase = "done"
			UICheck("VSPIKE_V1_OFF", mv == 0 and "PASS" or "CHECK", "ability removed, one normal promotion " .. (mv == 0 and
				"ended the unit's turn again (moves 0)" or ("left the unit " .. mv .. " moves: its turn did NOT end")))
		elseif m_Clock - (m.offAt or 0) > VS_RESEND_S * 2 then
			m.phase = "done"
			UICheck("VSPIKE_V1_OFF", "CHECK", "the promotion after the ability was removed did not land (" .. VsUIState(u) .. ")")
		end
	end
end

function VsStep()
	local v = m_VS
	if m_Clock < v.nextAt then return end
	v.nextAt = m_Clock + 0.3
	local st = ScnState()
	local vs = st and st.vs
	if v.phase == "wait" then
		if type(vs) ~= "table" or vs.stamp ~= v.stamp then
			if m_Clock - v.t0 > VET_TIMEOUT then
				m_VS = nil
				Log("V spike: no answer from gameplay (found your capital first)")
			end
			return
		end
		LookAt(st.focus)
		v.phase = "run"
		v.turn0 = tonumber(vs.turn) or CurrentTurn()
		return
	end
	if type(vs) ~= "table" or vs.stamp ~= v.stamp then
		m_VS = nil
		return
	end
	local turn = CurrentTurn()
	if turn > v.turn0 + VS_TURNS then
		UICheck("VSPIKE_UI", "INFO", "spike logging ends at turn " .. turn)
		m_VS = nil
		return
	end
	local newTurn = v.loggedTurn ~= turn
	v.loggedTurn = turn
	for _, c in ipairs(vs.c or {}) do
		local ok, err = pcall(VsCopy, v, vs, c, turn, newTurn)
		if not ok then Log("V spike " .. Str(c.k) .. " error: " .. Str(err)) end
	end
end
end -- V Veteran spike, UI side

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
local m_AuditDue, OnAuditReport, ScheduleAudit, RunAudit
do
m_AuditDue = nil
local m_AuditWhy = ""
local m_AuditForce = false
local m_AuditLast = nil
local m_AuditReplied = false

local function RowTag(r)
	return "flag P" .. Str(r.fp) .. "/" .. Str(r.fu) .. " (unit " .. (r.up ~= nil and ("P" .. Str(r.up) .. "/" .. Str(r.uu) ..
		" " .. Str(r.ut)) or "none") .. (r.rid ~= nil and (", record " .. Str(r.rid) .. " " .. Str(r.rs) .. " " .. Str(r.rt)) or "") .. ")"
end

function OnAuditReport(rows)
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

function ScheduleAudit(why, force)
	if m_AuditDue == nil then
		m_AuditDue = m_Clock + 0.3
		m_AuditWhy = why
	end
	if force then
		m_AuditForce = true
		m_AuditWhy = why
	end
end

function RunAudit()
	m_AuditDue = nil
	m_AuditReplied = false
	LuaEvents.EFV_BadgeAuditRequest()
	if not m_AuditReplied and m_AuditForce then
		UICheck("BADGE_AUDIT", "INFO", "(" .. m_AuditWhy .. ") no answer from VEF's flag wrapper (badges off or another mod replaces the unit flags)")
		m_AuditForce = false
	end
end
end -- Badge audit

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
local ELIG_UI_DELAY, m_Elig, EligUI
do
ELIG_UI_DELAY = 1.0
m_Elig = nil                -- { cmd, stamp, at }
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

function EligUI(test, stamp)
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
end -- Eligibility tests T1 / T2, UI side

-- ---------------------------------------------------------------------------
-- Denouncement reader spike, UI side (EFV_Dev 1.0.4.2; gameplay: the
-- "Denouncement reader spike" block in EFV_Dev_Gameplay.lua, whose header
-- has the sources; EFV/TESTING_SPIKES.md). READ ONLY.
--   D Setup           stamped denounce_setup request; once gameplay answered
--                     (st.dsetup, same stamp) the camera goes to the civ to
--                     denounce, the Target is set to it and the status line
--                     says which civ to denounce.
--   D Denounce probe  stamped denounce_probe request; once gameplay answered
--                     (st.dprobe, same stamp, or after SHOT_WAIT s without
--                     an answer) the panel runs the SAME readers here, on the
--                     same pairs, and logs "[EFV][Probe] UI ..." lines, one
--                     "compare" line per reader (G and UI hits) and shows a
--                     three-line summary in the status line.
-- Keep DP_READERS equal to the gameplay table.
-- ---------------------------------------------------------------------------
local m_DP, DpMethod, DenounceProbe, DenounceSetup, DpStep
do
local DP_READERS = {
	{ id = "GetDenounceTurn", short = "Turn", acc = "GetDiplomacy", fn = "GetDenounceTurn", kind = "turn" },
	{ id = "IsDenouncing", short = "IsDen", acc = "GetDiplomacy", fn = "IsDenouncing", kind = "bool" },
	{ id = "HasDenounced", short = "HasDen", acc = "GetDiplomacy", fn = "HasDenounced", kind = "bool" },
	{ id = "AiDiplo:GetDiplomaticState", short = "AiState", acc = "GetAi_Diplomacy", fn = "GetDiplomaticState", kind = "state" },
	{ id = "DiploAI:GetDiplomaticStateIndex", short = "StateIdx", acc = "GetDiplomaticAI", fn = "GetDiplomaticStateIndex", kind = "state" },
	{ id = "AiDiplo:GetDiplomaticModifiers", short = "AiMods", acc = "GetAi_Diplomacy", fn = "GetDiplomaticModifiers", kind = "mods" },
	{ id = "DiploAI:GetDiplomaticModifiers", short = "AIMods", acc = "GetDiplomaticAI", fn = "GetDiplomaticModifiers", kind = "mods" },
}
m_DP = nil                  -- { kind = "probe" | "setup", stamp, untilClock }

local function DpPrint(msg)
	print("[EFV][Probe] UI " .. Str(msg))
end

function DpMethod(obj, name)
	if obj == nil then return nil, "object is nil" end
	local ok, f = pcall(function() return obj[name] end)
	if not ok then return nil, "lookup error " .. Str(f) end
	if f == nil then return nil, "is nil" end
	if type(f) ~= "function" then return nil, "is a " .. type(f) end
	return f, nil
end

local function DpRead(r, a, b)
	local pl = Players[a]
	local get, why = DpMethod(pl, r.acc)
	if get == nil then return "MISSING", "Player." .. r.acc .. " " .. why end
	local ok, obj = pcall(get, pl)
	if not ok then return "ERROR", r.acc .. "(): " .. Str(obj) end
	if obj == nil then return "MISSING", r.acc .. "() returned nil" end
	local f, why2 = DpMethod(obj, r.fn)
	if f == nil then return "MISSING", r.acc .. "()." .. r.fn .. " " .. why2 end
	if b == nil then return "OK", "function" end
	local ok2, v = pcall(f, obj, b)
	if not ok2 then return "ERROR", Str(v) end
	return "OK", v
end

local function DpStates()
	local s = { idx = {}, hash = {} }
	pcall(function()
		for row in GameInfo.DiplomaticStates() do
			s.idx[row.Index] = row.StateType
			s.hash[row.Hash] = row.StateType
		end
	end)
	return s
end

local function DpFormat(r, v, states)
	local t = type(v)
	if r.kind == "turn" then
		return Str(v) .. (t ~= "number" and (" (" .. t .. ")") or ""), t == "number" and v >= 0
	elseif r.kind == "bool" then
		return Str(v) .. (t ~= "boolean" and (" (" .. t .. ")") or ""), v == true
	elseif r.kind == "state" then
		local names, hit = {}, false
		if t == "number" then
			if states.idx[v] ~= nil then names[#names + 1] = "index " .. states.idx[v] end
			if states.hash[v] ~= nil then names[#names + 1] = "hash " .. states.hash[v] end
		end
		for _, n in ipairs(names) do
			if string.find(n, "DIPLO_STATE_DENOUNCED", 1, true) then hit = true end
		end
		if t == "string" and string.find(string.upper(v), "DENOUNC", 1, true) then hit = true end
		return Str(v) .. " (" .. t .. (#names > 0 and ("; " .. table.concat(names, ", ")) or "") .. ")", hit
	end
	if t ~= "table" then return Str(v) .. " (" .. t .. ")", false end
	local n, found = 0, {}
	for _, m in ipairs(v) do
		n = n + 1
		local text, score = Str(m), nil
		if type(m) == "table" then text, score = Str(m.Text), m.Score end
		-- the raw text (a LOC key) only: a translated text would differ between
		-- clients, and gameplay stores the hits in a synced property
		if string.find(string.lower(text), "denounc", 1, true) then
			found[#found + 1] = Str(score) .. " " .. text
		end
	end
	return n .. " modifier(s)" .. (#found > 0 and ("; denounce: " .. table.concat(found, " / ")) or "; none about a denouncement"), #found > 0
end

local function DpLimit()
	local get, why = DpMethod(Game, "GetGameDiplomacy")
	if get == nil then return "MISSING (Game.GetGameDiplomacy " .. why .. ")" end
	local ok, gd = pcall(get)
	if not ok or gd == nil then return (ok and "MISSING" or "ERROR") .. " (GetGameDiplomacy(): " .. Str(gd) .. ")" end
	local f, why2 = DpMethod(gd, "GetDenounceTimeLimit")
	if f == nil then return "MISSING (GetDenounceTimeLimit " .. why2 .. ")" end
	local ok2, v = pcall(f, gd)
	if not ok2 then return "ERROR " .. Str(v) end
	return Str(v)
end

-- Same as gameplay's DpRun: every reader for (me, b) and (b, me).
local function DpRun(me, pids)
	local states = DpStates()
	local names = {}
	for _, b in ipairs(pids) do names[#names + 1] = PlayerName(b) end
	DpPrint("T" .. Str(CurrentTurn()) .. " begin: you " .. PlayerName(me) .. "; majors (" .. #pids .. "): " ..
		(#names > 0 and table.concat(names, ", ") or "none"))
	local limit = DpLimit()
	DpPrint("GetDenounceTimeLimit()=" .. limit)
	local res = {}
	for i, r in ipairs(DP_READERS) do
		local hs, hv = DpRead(r, me, nil)
		DpPrint("has " .. r.acc .. "():" .. r.fn .. " = " .. (hs == "OK" and "yes" or (hs .. " (" .. Str(hv) .. ")")))
		local n, okN, missN, errN, hits = 0, 0, 0, 0, {}
		for _, b in ipairs(pids) do
			for _, d in ipairs({ { me, b }, { b, me } }) do
				local a, o = d[1], d[2]
				local s, v = DpRead(r, a, o)
				n = n + 1
				local text
				if s == "OK" then
					okN = okN + 1
					local okF, t, hit = pcall(DpFormat, r, v, states)
					if not okF then t, hit = Str(v) .. " (format error " .. Str(t) .. ")", false end
					text = t
					if hit then hits[#hits + 1] = a .. ">" .. o .. (r.kind == "turn" and ("=" .. Str(v)) or "") end
				else
					if s == "MISSING" then missN = missN + 1 else errN = errN + 1 end
					text = s .. " (" .. Str(v) .. ")"
				end
				DpPrint(r.id .. "(" .. a .. "->" .. o .. ")=" .. text)
			end
		end
		local st = "mixed"
		if n == 0 then st = "none" elseif okN == n then st = "ok" elseif missN == n then st = "nil" elseif errN == n then st = "err" end
		res[i] = { s = st, hits = (#hits > 0) and table.concat(hits, " ") or "-" }
	end
	return res, limit
end

local function DpRow(label, res)
	local parts = {}
	for i, r in ipairs(DP_READERS) do
		local x = res and res[i]
		parts[#parts + 1] = r.short .. " " .. (x and (Str(x.s) .. " " .. Str(x.hits)) or "?")
	end
	return label .. ": " .. table.concat(parts, " | ")
end

-- The UI half of the probe, after gameplay's answer g (nil: none came).
local function DpUI(g)
	local me = (g and tonumber(g.me)) or LocalID()
	local pids = {}
	if g ~= nil then
		for _, pid in ipairs(g.pids or {}) do pids[#pids + 1] = pid end
	else
		-- No gameplay answer: every other living major (HasMet is not probed here).
		for i = 0, 63 do
			local okM, major = pcall(function() return Players[i] ~= nil and Players[i]:IsAlive() and Players[i]:IsMajor() end)
			if i ~= me and okM and major then pids[#pids + 1] = i end
		end
	end
	local res, limit = DpRun(me, pids)
	local diff = 0
	for i, r in ipairs(DP_READERS) do
		local gr = g and g.r and g.r[i]
		local same = gr ~= nil and gr.s == res[i].s and gr.hits == res[i].hits
		if gr ~= nil and not same then diff = diff + 1 end
		DpPrint("compare " .. r.id .. ": G " .. (gr and (Str(gr.s) .. " [" .. Str(gr.hits) .. "]") or "no answer") .. " | UI " ..
			res[i].s .. " [" .. res[i].hits .. "]" .. (gr == nil and "" or (same and " -> same" or " -> DIFFERENT")))
	end
	local head = "Denounce probe T" .. CurrentTurn() .. ", you vs " .. #pids .. " major(s); limit G " .. Str(g and g.limit or "no answer") ..
		" / UI " .. limit .. "; " .. (g and (diff == 0 and "G = UI" or (diff .. " reader(s) differ")) or "no gameplay answer")
	DpPrint("summary: " .. head)
	DpPrint(DpRow("G", g and g.r))
	DpPrint(DpRow("UI", res))
	m_EligStatus = head .. "[NEWLINE]" .. (g and DpRow("G", g.r) or "G: no answer from gameplay (see Lua.log)") .. "[NEWLINE]" .. DpRow("UI", res)
end

local function DpStart(cmd, kind)
	local p = BaseParams(cmd)
	m_DP = { kind = kind, stamp = p.stamp, untilClock = m_Clock + SHOT_WAIT }
	m_EligStatus = (kind == "probe" and "Denounce probe" or "D Setup") .. ": waiting for gameplay..."
	Send(p)
	RefreshInfo()
end

function DenounceProbe() DpStart("denounce_probe", "probe") end
function DenounceSetup() DpStart("denounce_setup", "setup") end

function DpStep()
	local d = m_DP
	local st = ScnState()
	local a = st and st[d.kind == "probe" and "dprobe" or "dsetup"]
	local answered = type(a) == "table" and a.stamp == d.stamp
	if not answered and m_Clock <= d.untilClock then return end
	m_DP = nil
	if d.kind == "setup" then
		if answered then
			local x = tonumber(a.x) or -1
			if x < 0 then
				m_EligStatus = "D Setup: no major civ you could denounce (all at war with you, allied, friends or without a city): start a new game"
			else
				m_EligStatus = "D Setup: denounce " .. PlayerName(x) .. " (Target set to it): Diplomacy screen, its leader, Denounce. Met " ..
					((tonumber(a.met) == 1) and "yes" or "NO") .. ", capital revealed " .. Str(a.revealed)
			end
			local f = st.focus
			if type(f) == "table" and f.stamp == d.stamp then LookAt(f) end
			if (tonumber(a.x) or -1) >= 0 then TargetTo(tonumber(a.x)) end
		else
			m_EligStatus = "D Setup: no answer from gameplay (see Lua.log)"
		end
	else
		DpUI(answered and a or nil)
	end
	RefreshInfo()
end
end -- Denouncement reader spike, UI side

-- ---------------------------------------------------------------------------
-- Air-unit spike, UI side (EFV_Dev 1.0.4.3; gameplay: the "Air-unit spike"
-- block in EFV_Dev_Gameplay.lua; EFV/TESTING_SPIKES.md). Each A button
-- sends a stamped request. Once gameplay answered (st.air.ans, same stamp,
-- or after SHOT_WAIT s) the camera goes to the scene and selects your plane,
-- and the status line shows gameplay's summary plus what the UI sees:
--   based    the plane is in plot:GetAirUnits() or in its district's
--            GetAirUnits() list (UnitFlagManager.lua:1420-1446,
--            CityBannerManager.lua:367-368, CityManager.GetDistrictAt(plot))
--   ops      UnitManager.CanStartOperation(u, hash, nil, false, false) for
--            DEPLOY / REBASE as the unit panel asks (UnitPanel.lua:546-615)
--            and the REBASE targets (WorldInput.lua:2499)
--   carrier  unit:GetAirSlots() / GetAirUnits() (UnitFlagManager.lua:399-414)
-- All looked up by name and pcall-guarded. "[EFV][Air] UI ..." lines.
-- ---------------------------------------------------------------------------
local m_Air, AirStep, AirCity, AirHost, AirFuel, AirAlly, AirCarrier, AirStatus, AirRebase
do
m_Air = nil                  -- { cmd, label, stamp, untilClock }

local function AirPrint(msg)
	print("[EFV][Air] UI " .. Str(msg))
end

local function AirCall(obj, name, static, ...)
	local f, why = DpMethod(obj, name)
	if f == nil then return "MISSING", name .. " " .. Str(why) end
	local args, n = { ... }, select("#", ...)
	local r
	if static then r = { pcall(f, unpack(args, 1, n)) } else r = { pcall(f, obj, unpack(args, 1, n)) } end
	if not r[1] then return "ERROR", Str(r[2]) end
	return "OK", r[2], r[3]
end

local function AirOp(t)
	local ok, h = pcall(function() return GameInfo.UnitOperations[t].Hash end)
	return ok and h or nil
end

local function AirCount(list) return (type(list) == "table") and #list or 0 end

local function AirHas(list, u)
	if type(list) ~= "table" or u == nil then return false end
	for _, x in ipairs(list) do
		local ok, same = pcall(function() return x:GetOwner() == u:GetOwner() and x:GetID() == u:GetID() end)
		if ok and same then return true end
	end
	return false
end

-- Your spike unit with key k (from gameplay's list), type-checked.
local function AirUnit(st, k)
	local a = st and st.air
	local list = (type(a) == "table" and type(a.units) == "table") and a.units or {}
	for _, e in ipairs(list) do
		if e.k == k then
			local u = OwnUnit(e.o, e.u)
			local ok, t = pcall(function() return GameInfo.Units[u:GetType()].UnitType end)
			if ok and t == e.t then return u end
			return nil
		end
	end
	return nil
end

-- Is u based (listed by its plot or its district)? Logs the readers.
local function AirUIBase(label, u)
	if u == nil then return label .. " not on the map" end
	local x, y = u:GetX(), u:GetY()
	local plot = Map.GetPlot(x, y)
	local s1, plist = AirCall(plot, "GetAirUnits")
	local sD, d = AirCall(CityManager, "GetDistrictAt", true, plot)
	if sD ~= "OK" then d = nil end
	local s2, slots = AirCall(d, "GetAirSlots")
	local s3, _, dlist = AirCall(d, "GetAirUnits")
	local based = AirHas(plist, u) or AirHas(dlist, u)
	local slotText = (s2 == "OK") and Str(slots) or s2
	AirPrint(label .. " @" .. x .. "," .. y .. ": plot:GetAirUnits=" .. ((s1 == "OK") and AirCount(plist) or s1) ..
		", district:GetAirSlots=" .. slotText .. ", district:GetAirUnits=" .. ((s3 == "OK") and AirCount(dlist) or s3) ..
		", based=" .. tostring(based))
	return label .. " based " .. (based and "yes" or "no") .. " (slots " .. slotText .. ", listed " ..
		math.max(AirCount(plist), AirCount(dlist)) .. ")"
end

local function AirRebasePlots(u)
	local s, r = AirCall(UnitManager, "GetOperationTargets", true, u, AirOp("UNITOPERATION_REBASE"))
	if s ~= "OK" or type(r) ~= "table" then return nil end
	local ok, plots = pcall(function() return r[UnitOperationResults.PLOTS] end)
	if ok and type(plots) == "table" then return plots end
	return nil
end

-- Deploy / Rebase as the unit panel offers them, and the rebase targets.
local function AirUIOps(label, u)
	if u == nil then return label .. " not on the map" end
	local out = {}
	for _, op in ipairs({ { "Deploy", "UNITOPERATION_DEPLOY" }, { "Rebase", "UNITOPERATION_REBASE" } }) do
		local s, v = AirCall(UnitManager, "CanStartOperation", true, u, AirOp(op[2]), nil, false, false)
		AirPrint(label .. " CanStartOperation(" .. op[2] .. ")=" .. ((s == "OK") and Str(v) or (s .. " " .. Str(v))) ..
			" moves=" .. Str(u:GetMovesRemaining()))
		out[#out + 1] = op[1] .. " " .. ((s == "OK") and (v and "yes" or "no") or s)
	end
	local plots = AirRebasePlots(u)
	out[#out + 1] = "rebase targets " .. (plots and #plots or "?")
	return label .. " " .. table.concat(out, ", "), plots
end

local function AirUI(cmd, st, me)
	if cmd == "air_city" then
		local u1 = AirUnit(st, "AIR-1")
		local ops = AirUIOps("AIR-1", u1)
		return AirUIBase("AIR-1", u1) .. "; " .. ops .. "; " .. AirUIBase("AIR-2", AirUnit(st, "AIR-2"))
	elseif cmd == "air_host" then
		-- B's plane is not yours: look it up by owner and ID as well
		local a = st and st.air
		local e = nil
		for _, x in ipairs((type(a) == "table" and type(a.units) == "table") and a.units or {}) do if x.k == "AIR-B" then e = x end end
		return AirUIBase("AIR-B", e and OwnUnit(e.o, e.u) or nil)
	elseif cmd == "air_fuel" then
		local u = AirUnit(st, "AIR-1")
		if u == nil then return "AIR-1 not on the map" end
		local _, c = AirCall(u, "GetCombat")
		local _, r = AirCall(u, "GetRangedCombat")
		local al = "?"
		pcall(function() al = Players[me]:GetResources():GetResourceAmount(GameInfo.Resources["RESOURCE_ALUMINUM"].Index) end)
		AirPrint("AIR-1 damage " .. Str(u:GetDamage()) .. " GetCombat=" .. Str(c) .. " GetRangedCombat=" .. Str(r) .. " Aluminium=" .. Str(al))
		return "AIR-1 damage " .. Str(u:GetDamage()) .. ", strength " .. Str(c) .. "/" .. Str(r) .. ", Aluminium " .. Str(al)
	elseif cmd == "air_ally" then
		local uV = AirUnit(st, "AIR-V")
		local opsV = AirUIOps("AIR-V", uV)
		local reach = "?"
		local _, plots = AirUIOps("AIR-1", AirUnit(st, "AIR-1"))
		local capF = nil
		pcall(function() capF = Players[st.friend]:GetCities():GetCapitalCity() end)
		if plots ~= nil and capF ~= nil then
			local idx = Map.GetPlot(capF:GetX(), capF:GetY()):GetIndex()
			reach = "no"
			for _, i in ipairs(plots) do if i == idx then reach = "yes" end end
		end
		return AirUIBase("AIR-V", uV) .. "; " .. opsV .. "; AIR-1 may rebase to F's capital: " .. reach
	elseif cmd == "air_carrier" then
		local cv = AirUnit(st, "CV")
		local text = "carrier not on the map"
		if cv ~= nil then
			local s1, slots = AirCall(cv, "GetAirSlots")
			local s2, has, list = AirCall(cv, "GetAirUnits")
			AirPrint("CV GetAirSlots=" .. ((s1 == "OK") and Str(slots) or s1) .. " GetAirUnits=" .. ((s2 == "OK") and (Str(has) .. " #" .. AirCount(list)) or s2))
			text = "carrier aboard " .. ((s2 == "OK") and AirCount(list) or s2) .. " of " .. ((s1 == "OK") and Str(slots) or s1) .. " slots"
		end
		return text .. "; " .. AirUIBase("AIR-CV", AirUnit(st, "AIR-CV"))
	elseif cmd == "air_rebase" then
		-- A9 (EFV_Dev 1.0.5.1): a plane rebased by hand onto the carrier
		local cv = AirUnit(st, "CV9")
		local text = "carrier not on the map"
		local rule = "no carrier"
		if cv ~= nil then
			local s1, slots = AirCall(cv, "GetAirSlots")
			local s2, has, list = AirCall(cv, "GetAirUnits")
			AirPrint("CV9 GetAirSlots=" .. ((s1 == "OK") and Str(slots) or s1) .. " GetAirUnits=" .. ((s2 == "OK") and (Str(has) .. " #" .. AirCount(list)) or s2))
			text = "carrier aboard " .. ((s2 == "OK") and AirCount(list) or s2) .. " of " .. ((s1 == "OK") and Str(slots) or s1) .. " slots"
			local okR, codes = pcall(EFV_UnitSendReasons, cv, me, EFV_UI_ReadStore())
			rule = (not okR) and ("error " .. Str(codes)) or ((#codes == 0) and "ok" or table.concat(codes, "+"))
		end
		return text .. "; " .. AirUIBase("AIR-9", AirUnit(st, "AIR-9")) .. "; UI send rule " .. rule
	end
	local parts = {}
	for _, k in ipairs({ "AIR-1", "AIR-2", "AIR-3", "AIR-V", "AIR-CV" }) do
		local u = AirUnit(st, k)
		if u ~= nil then parts[#parts + 1] = AirUIBase(k, u) end
	end
	return (#parts > 0) and table.concat(parts, "; ") or "none of your spike planes on the map"
end

local function AirStart(cmd, label)
	local p = BaseParams(cmd)
	m_Air = { cmd = cmd, label = label, stamp = p.stamp, untilClock = m_Clock + SHOT_WAIT }
	m_EligStatus = label .. ": waiting for gameplay..."
	Send(p)
	RefreshInfo()
end

function AirStep()
	local m = m_Air
	local st = ScnState()
	local ans = (st ~= nil and type(st.air) == "table") and st.air.ans or nil
	local answered = type(ans) == "table" and ans.stamp == m.stamp
	if not answered and m_Clock <= m.untilClock then return end
	m_Air = nil
	if not answered then
		m_EligStatus = m.label .. ": no answer from gameplay (press S0 first; see Lua.log)"
		RefreshInfo()
		return
	end
	local f = st.focus
	if type(f) == "table" and f.stamp == m.stamp then LookAt(f) end
	local ok, ui = pcall(AirUI, m.cmd, st, LocalID())
	if not ok then ui = "error " .. Str(ui) end
	AirPrint("summary " .. m.cmd .. ": " .. Str(ui))
	m_EligStatus = Str(ans.text) .. "[NEWLINE]UI: " .. Str(ui)
	RefreshInfo()
end

function AirCity() AirStart("air_city", "A1") end
function AirHost() AirStart("air_host", "A2") end
function AirFuel() AirStart("air_fuel", "A3") end
function AirAlly() AirStart("air_ally", "A4") end
function AirCarrier() AirStart("air_carrier", "A5") end
function AirStatus() AirStart("air_status", "A Status") end
function AirRebase() AirStart("air_rebase", "A9") end
end -- Air-unit spike, UI side

-- ---------------------------------------------------------------------------
-- Corps spike, UI side (EFV_Dev 1.0.4.4, C8-C10 and the merge trace 1.0.4.5; gameplay: the "Corps spike" block
-- in EFV_Dev_Gameplay.lua; EFV/TESTING_SPIKES.md). Each C button sends a
-- stamped request. Once gameplay answered (st.corps.ans, same stamp) the
-- panel moves the camera there and shows the answer, then "UI:" with the
-- formation and strength of that button's units as the screen side reads
-- them (GetMilitaryFormation, GetCombat: UnitPanel.lua).
-- Merge-confirmation research (FIXPLAN_corps.md "Designer rulings"): the
-- base game has no confirm prompt for Form Corps / Form Army (the world
-- click calls RequestCommand at once, WorldInput.lua:2870-2888 and
-- 2940-2955). The hook a VEF warning could use is the mode change itself:
-- when you enter Form Corps or Form Army mode (Events.InterfaceModeChanged,
-- WorldInput.lua:3819-3820), the panel logs the selected unit, which gives
-- the command, and the units it can merge with
-- (UnitManager.GetCommandTargets, WorldInput.lua:2900), each with its VEF
-- record, and shows it on the status line. Read only, pcall-guarded.
-- "[EFV][Corps] UI ..." lines.
-- ---------------------------------------------------------------------------
local CorpsUI = {}
do
local C_PREFIX = { corps_probe = "C1", corps_give = "C2", corps_merge = "C3", corps_cs_ai = "C4", corps_cs_force = "C5",
	corps_host = "C6", corps_trip = "C7", corps_split = "C8", corps_vol = "C9" }
local m_C = nil              -- { cmd, label, stamp, untilClock }
local m_Guard = "off"        -- C10 merge guard: off / ask / block (UI only)
local GUARD_NEXT = { off = "ask", ask = "block", block = "off" }

local function CPrint(msg) print("[EFV][Corps] UI " .. Str(msg)) end

local function FName(f)
	local M = MilitaryFormationTypes or {}
	if f == M.STANDARD_FORMATION then return "STANDARD" end
	if f == M.CORPS_FORMATION then return "CORPS" end
	if f == M.ARMY_FORMATION then return "ARMY" end
	return "value " .. Str(f)
end

-- obj:name() looked up by name (not confirmed in the UI): the value as
-- text, or MISSING / ERROR.
local function UGet(obj, name)
	local ok, f = pcall(function() return obj[name] end)
	if not ok or type(f) ~= "function" then return "MISSING" end
	local ok2, v = pcall(f, obj)
	return ok2 and Str(v) or "ERROR"
end

-- "<key> <formation> strength <n>" for the C units with that key prefix.
local function UIFacts(st, prefix)
	local c = st and st.corps
	local parts = {}
	for _, e in ipairs((type(c) == "table" and type(c.units) == "table") and c.units or {}) do
		if prefix == nil or string.sub(e.k, 1, #prefix) == prefix then
			local u = OwnUnit(e.o, e.u)
			if u ~= nil then
				local f, s = "?", UGet(u, "GetCombat")
				pcall(function() f = FName(u:GetMilitaryFormation()) end)
				parts[#parts + 1] = e.k .. " " .. f .. " strength " .. s
			else
				parts[#parts + 1] = e.k .. " gone"
			end
		end
	end
	return (#parts > 0) and table.concat(parts, ", ") or "no C units"
end

local function UName(u)
	local n = nil
	pcall(function() n = UGet(u:GetExperience(), "GetVeteranName") end)
	if n == nil or n == "" or n == "MISSING" or n == "ERROR" then pcall(function() n = GameInfo.Units[u:GetType()].UnitType end) end
	return Str(n) .. " P" .. Str(u:GetOwner()) .. "/" .. Str(u:GetID())
end

local function LentText(u)
	local ok, rec = pcall(function() return EFV_UI_RecordForUnit(u:GetOwner(), u:GetID()) end)
	if not ok or type(rec) ~= "table" then return "not lent" end
	return "lent: record " .. Str(rec.id) .. " " .. Str(rec.forceType) .. " from P" .. Str(rec.senderID)
end

-- Events.InterfaceModeChanged(old, new): Form Corps / Form Army entered.
function CorpsUI.Mode(_, new)
	local IM = InterfaceModeTypes or {}
	if new == nil or (new ~= IM.FORM_CORPS and new ~= IM.FORM_ARMY) then return end
	local kind = (new == IM.FORM_CORPS) and "FORM_CORPS" or "FORM_ARMY"
	local sel = nil
	pcall(function() sel = UI.GetHeadSelectedUnit() end)
	if sel == nil then CPrint(kind .. " mode: no selected unit"); return end
	local targets, guarded = {}, { sel }
	local ok, err = pcall(function()
		local cmd = (kind == "FORM_CORPS") and UnitCommandTypes.FORM_CORPS or UnitCommandTypes.FORM_ARMY
		local res = UnitManager.GetCommandTargets(sel, cmd)
		for _, t in ipairs((res and res[UnitCommandResults.UNITS]) or {}) do
			local u = OwnUnit(sel:GetOwner(), t.id)
			if u ~= nil then
				targets[#targets + 1] = UName(u) .. " (" .. LentText(u) .. ")"
				guarded[#guarded + 1] = u
			end
		end
	end)
	local text = kind .. " mode: selected " .. UName(sel) .. " (" .. LentText(sel) .. "; it gives the command), can merge with: " ..
		((#targets > 0) and table.concat(targets, "; ") or (ok and "none" or ("ERROR " .. Str(err))))
	CPrint(text)
	m_EligStatus = text
	if m_Guard ~= "off" then
		local okG, g = pcall(CorpsUI.GuardAsk, kind, sel, guarded)
		if not okG then CPrint("guard ERROR " .. Str(g)) elseif g ~= nil then m_EligStatus = text .. "[NEWLINE]" .. g end
	end
	RefreshInfo()
end

-- C10 merge guard (EFV_Dev 1.0.4.5; FIXPLAN_corps.md R2.1 "UI guard", R2.7).
-- UI only, sends nothing. ask: on entering Form Corps / Form Army (Mode
-- above), when the selected unit or a merge target has a VEF record, a
-- PopupDialogInGame "EFV_DevMergeGuard" lists them with Continue / Cancel;
-- Cancel = UI.SetInterfaceMode(SELECTION) (UnitPanel.lua:2498-2509), then
-- the mode is read back. block: ask, plus the panel's input handler
-- swallows LButtonUp in Form Corps / Form Army mode when the plot under
-- the cursor (UI.GetCursorPlotID, WorldInput.lua:798) holds a unit with a
-- VEF record. Whether WorldInput gets the click first is what C10 asks.

-- "name (lent by P<n>)" / "name (Volunteer)" for a unit with a VEF record.
local function GuardLabel(u)
	local ok, rec = pcall(function() return EFV_UI_RecordForUnit(u:GetOwner(), u:GetID()) end)
	if not ok or type(rec) ~= "table" then return nil end
	if rec.forceType == EFV_Config.FT_VOL then return UName(u) .. " (Volunteer, record " .. Str(rec.id) .. ")" end
	return UName(u) .. " (lent by P" .. Str(rec.senderID) .. ", record " .. Str(rec.id) .. ")"
end

local function ModeName(m)
	local IM = InterfaceModeTypes or {}
	if m == IM.SELECTION then return "SELECTION" end
	if m == IM.FORM_CORPS then return "FORM_CORPS" end
	if m == IM.FORM_ARMY then return "FORM_ARMY" end
	return "value " .. Str(m)
end

function CorpsUI.Guard()
	m_Guard = GUARD_NEXT[m_Guard] or "off"
	CPrint("guard mode " .. m_Guard)
	local what = { off = "no popup, no block", ask = "a popup when you enter Form Corps / Form Army with a VEF unit involved",
		block = "the popup, and a click on a VEF unit in Form Corps / Form Army is swallowed" }
	m_EligStatus = "C10 merge guard: " .. m_Guard .. " (" .. what[m_Guard] .. ")"
	RefreshInfo()
end

-- Opens the guard popup for the VEF units among units (sel first). Returns
-- the status text.
function CorpsUI.GuardAsk(kind, sel, units)
	local list = {}
	for _, u in ipairs(units) do
		local l = GuardLabel(u)
		if l ~= nil then list[#list + 1] = l end
	end
	if #list == 0 then
		CPrint("guard " .. m_Guard .. " " .. kind .. ": no VEF unit involved, no popup")
		return "C10 guard " .. m_Guard .. ": no VEF unit involved, no popup"
	end
	if PopupDialogInGame == nil then pcall(include, "PopupDialog") end
	local ok, err = pcall(function()
		local d = PopupDialogInGame:new("EFV_DevMergeGuard")
		d:AddTitle("VEF Dev C10: merge guard")
		d:AddText(kind .. " with VEF units:[NEWLINE]" .. table.concat(list, "[NEWLINE]") ..
			"[NEWLINE]You selected " .. UName(sel) .. ". Continue or Cancel?")
		d:AddConfirmButton("Continue", function()
			CPrint("guard " .. kind .. " Continue")
			m_EligStatus = "C10 Continue: click the unit to merge with" .. ((m_Guard == "block") and " (block mode: a VEF unit's click is swallowed)" or "")
			RefreshInfo()
		end)
		d:AddCancelButton("Cancel", function()
			local okS, errS = pcall(function() UI.SetInterfaceMode(InterfaceModeTypes.SELECTION) end)
			local back = "ERROR"
			pcall(function() back = ModeName(UI.GetInterfaceMode()) end)
			CPrint("guard " .. kind .. " Cancel: SetInterfaceMode(SELECTION) ok=" .. tostring(okS) .. (okS and "" or (" err=" .. Str(errS))) ..
				", mode now " .. back)
			m_EligStatus = "C10 Cancel: mode now " .. back
			RefreshInfo()
		end)
		d:Open()
	end)
	if not ok then
		CPrint("guard popup ERROR " .. Str(err))
		return "C10 guard: popup ERROR " .. Str(err)
	end
	CPrint("guard " .. m_Guard .. " " .. kind .. ": popup for " .. table.concat(list, "; "))
	return "C10 guard " .. m_Guard .. ": popup for " .. table.concat(list, "; ")
end

-- Block mode: true swallows the click (the panel's input handler).
function CorpsUI.Input(pInput)
	if m_Guard ~= "block" or MouseEvents == nil then return false end
	if pInput:GetMessageType() ~= MouseEvents.LButtonUp then return false end
	local IM = InterfaceModeTypes or {}
	local mode = UI.GetInterfaceMode()
	if mode == nil or (mode ~= IM.FORM_CORPS and mode ~= IM.FORM_ARMY) then return false end
	local plot = Map.GetPlotByIndex(UI.GetCursorPlotID())
	if plot == nil then return false end
	local where = Str(plot:GetX()) .. "," .. Str(plot:GetY())
	local hit = nil
	for _, u in ipairs(Units.GetUnitsInPlot(plot) or {}) do
		if hit == nil then hit = GuardLabel(u) end
	end
	if hit == nil then
		CPrint("guard block " .. ModeName(mode) .. ": click at " .. where .. " passes (no VEF unit)")
		return false
	end
	CPrint("guard click blocked at " .. where .. " in " .. ModeName(mode) .. " (" .. hit .. ")")
	m_EligStatus = "C10: click blocked at " .. where .. " (" .. hit .. "). Esc leaves the mode"
	RefreshInfo()
	return true
end

-- Merge trace, UI side (armed by C3 / C9 press 1 for that turn,
-- st.corps.trace): Events.UnitFormCorps / UnitFormArmy (playerID, unitID;
-- UnitFlagManager.lua:1825) and UnitRemovedFromMap (playerID, unitID;
-- UnitFlagManager.lua:1100) about a C3 / C9 unit log every C3 / C9 unit as
-- the screen side reads it (FindID, formation, XP). Read only.
function CorpsUI.Trace(evName, pid, uid)
	local st = ScnState()
	local c = st and st.corps
	if type(c) ~= "table" or type(c.units) ~= "table" then return end
	local turn = -1
	pcall(function() turn = Game.GetCurrentGameTurn() end)
	if tonumber(c.trace) ~= turn then return end
	local hit, parts = nil, {}
	for _, e in ipairs(c.units) do
		local pre = string.sub(Str(e.k), 1, 2)
		if pre == "C3" or pre == "C9" then
			if tonumber(e.o) == pid and tonumber(e.u) == uid then hit = e.k end
			local u = OwnUnit(e.o, e.u)
			local t = "FindID nil"
			if u ~= nil then
				local f, xp = "?", "?"
				pcall(function() f = FName(u:GetMilitaryFormation()) end)
				pcall(function() xp = Str(u:GetExperience():GetExperiencePoints()) end)
				t = "alive " .. f .. " xp " .. xp
			end
			parts[#parts + 1] = Str(e.k) .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. " " .. t
		end
	end
	if hit == nil then return end
	CPrint("trace " .. evName .. " P" .. Str(pid) .. "/" .. Str(uid) .. " (" .. hit .. "): " .. table.concat(parts, "; "))
end

function CorpsUI.Start(cmd, label)
	local p = BaseParams(cmd)
	m_C = { cmd = cmd, label = label, stamp = p.stamp, untilClock = m_Clock + SHOT_WAIT }
	m_EligStatus = label .. ": waiting for gameplay..."
	Send(p)
	RefreshInfo()
end

function CorpsUI.Step()
	local m = m_C
	if m == nil then return end
	local st = ScnState()
	local ans = (st ~= nil and type(st.corps) == "table") and st.corps.ans or nil
	local answered = type(ans) == "table" and ans.stamp == m.stamp
	if not answered and m_Clock <= m.untilClock then return end
	m_C = nil
	if not answered then
		m_EligStatus = m.label .. ": no answer from gameplay (press S0 first; see Lua.log)"
		RefreshInfo()
		return
	end
	local f = st.focus
	if type(f) == "table" and f.stamp == m.stamp then LookAt(f) end
	local ok, ui = pcall(UIFacts, st, C_PREFIX[m.cmd])
	if not ok then ui = "error " .. Str(ui) end
	CPrint("summary " .. m.cmd .. ": " .. Str(ui))
	m_EligStatus = Str(ans.text) .. "[NEWLINE]UI: " .. Str(ui)
	RefreshInfo()
end
end -- corps spike (UI)

local ProxyUI = {}

-- ---------------------------------------------------------------------------
-- VEF 1.0.5 test, UI side (EFV_Dev 1.0.5.1; gameplay: the "VEF 1.0.5 test"
-- block in EFV_Dev_Gameplay.lua; EFV/TESTING_1.0.5.md). Each P button sends
-- a stamped request. Once gameplay answered (st.proxy.ans, same stamp, or
-- after SHOT_WAIT s) the camera goes to the scene and the status line shows
-- gameplay's text, then "UI:" with B, E and X by name, the U20 pair state,
-- who denounced on which turn (UI GetDenounceTurn, both ways), the turns
-- left (EFV_UI_DenounceTurnsLeft, the base game's count) and the engine's
-- denounce limit (UI GetDenounceTimeLimit).
-- P2 asks the engine for an AI-started denouncement:
-- DiplomacyManager.RequestSession(X, you, "DENOUNCE") (the base game passes
-- the local player as the first argument, DiplomacyActionView.lua:469; an AI
-- there is the test), then P Status after 1 s, with the verdict in front.
-- "[EFV][Proxy] UI ..." lines.
-- ---------------------------------------------------------------------------
do
local m_P = nil              -- { cmd, label, stamp, untilClock, p2 } or { delayUntil } (P2)

local function PPrint(msg) print("[EFV][Proxy] UI " .. Str(msg)) end

local function State(a, b)
	local ok, s = pcall(function() return GameInfo.DiplomaticStates[Players[a]:GetDiplomaticAI():GetDiplomaticStateIndex(b)].StateType end)
	if not ok or type(s) ~= "string" then return "?" end
	return (string.gsub(s, "^DIPLO_STATE_", ""))
end

local function DenTurn(a, b)
	local ok, t = pcall(function() return Players[a]:GetDiplomacy():GetDenounceTurn(b) end)
	return (ok and type(t) == "number") and t or nil
end

local function Limit()
	local ok, n = pcall(function() return Game.GetGameDiplomacy():GetDenounceTimeLimit() end)
	return (ok and n ~= nil) and Str(n) or "?"
end

local function EnemyText(label, me, e)
	if e == nil then return label .. ": none" end
	local ours, theirs = DenTurn(me, e), DenTurn(e, me)
	local who
	if ours == nil or theirs == nil then
		who = "denounce turns unreadable"
	elseif ours < 0 and theirs < 0 then
		who = "never denounced"
	elseif ours >= theirs then
		who = "you denounced on T" .. ours
	else
		who = "denounced you on T" .. theirs
	end
	local left = nil
	pcall(function() left = EFV_UI_DenounceTurnsLeft(me, e) end)
	return label .. ": " .. who .. (left and (", " .. left .. " turns left") or "") .. ", state " .. State(me, e)
end

local function UIHalf(st, me)
	local P = st and st.proxy
	if type(P) ~= "table" or P.b == nil then return "no P1 scene" end
	return "B=" .. CivName(P.b) .. " E=" .. CivName(P.e) .. " X=" .. CivName(P.x) .. "; " .. EnemyText("E", me, P.e) .. "; " ..
		EnemyText("X", me, P.x) .. "; denounce limit " .. Limit()
end

-- P2's verdict from the UI denounce turns (X -> you, you -> X).
local function P2Verdict(st, me)
	local x = st and st.proxy and st.proxy.x
	if x == nil then return "P2: press P1 first" end
	local theirs, ours = DenTurn(x, me), DenTurn(me, x)
	if theirs ~= nil and theirs >= 0 then return "P2: X denounced you on turn " .. theirs end
	if ours ~= nil and ours >= 0 then return "P2: WRONG WAY: the game made you denounce X" end
	return "P2: nothing happened: press P3"
end

function ProxyUI.Start(cmd, label, p2)
	local p = BaseParams(cmd)
	m_P = { cmd = cmd, label = label, stamp = p.stamp, untilClock = m_Clock + SHOT_WAIT, p2 = p2 }
	m_EligStatus = label .. ": waiting for gameplay..."
	Send(p)
	RefreshInfo()
end

function ProxyUI.AiDenounce()
	local st = ScnState()
	local x = st and st.proxy and st.proxy.x
	if x == nil then
		m_EligStatus = "P2: press P1 first"
		RefreshInfo()
		return
	end
	local me = LocalID()
	local ok, err = pcall(DiplomacyManager.RequestSession, x, me, "DENOUNCE")
	PPrint("P2 DiplomacyManager.RequestSession(" .. Str(x) .. ", " .. Str(me) .. ", DENOUNCE) ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	m_P = { delayUntil = m_Clock + 1 }
	m_EligStatus = "P2: asked the game for X's denouncement..."
	RefreshInfo()
end

function ProxyUI.Step()
	local m = m_P
	if m == nil then return end
	if m.delayUntil ~= nil then
		if m_Clock < m.delayUntil then return end
		ProxyUI.Start("proxy_status", "P2", true)
		return
	end
	local st = ScnState()
	local ans = (st ~= nil and type(st.proxy) == "table") and st.proxy.ans or nil
	local answered = type(ans) == "table" and ans.stamp == m.stamp
	if not answered and m_Clock <= m.untilClock then return end
	m_P = nil
	if not answered then
		m_EligStatus = m.label .. ": no answer from gameplay (see Lua.log)"
		RefreshInfo()
		return
	end
	local f = st.focus
	if type(f) == "table" and f.stamp == m.stamp then LookAt(f) end
	local me = LocalID()
	local ok, ui = pcall(UIHalf, st, me)
	if not ok then ui = "error " .. Str(ui) end
	local head = ""
	if m.p2 then
		local okV, v = pcall(P2Verdict, st, me)
		head = (okV and Str(v) or ("P2: error " .. Str(v))) .. "[NEWLINE]"
	end
	PPrint("summary " .. m.cmd .. ": " .. (m.p2 and (head .. " ") or "") .. Str(ui))
	m_EligStatus = head .. Str(ans.text) .. "[NEWLINE]UI: " .. Str(ui)
	RefreshInfo()
end

end -- VEF 1.0.5 test, UI side

-- ---------------------------------------------------------------------------
-- Upgrade spike U1, UI side (EFV_Dev 1.0.5.2; gameplay: the "Upgrade spike
-- U1" block in EFV_Dev_Gameplay.lua; EFV/TESTING_1.0.5.md). The button
-- sends a stamped upg_spike request; once gameplay answered (st.upg.ans,
-- same stamp, or after SHOT_WAIT s) the camera goes to the scene and the
-- status line shows gameplay's text. After press 1 the UI asks the engine
-- whether Upgrade is available for VEF-U1-M and VEF-U1-S, as the base unit
-- panel does (UnitManager.CanStartCommand(u, UnitCommandTypes.UPGRADE,
-- false, true) and tResults[UnitCommandResults.UNIT_TYPE], UnitPanel.lua:
-- 468-478). Events.UnitUpgraded (UI, UnitFlagManager.lua:1810, 2065) is
-- traced for your units in the press-1 turn. "[EFV][Upg] UI ..." lines.
-- The functions hang on ProxyUI (no new main-chunk local: register limit).
-- ---------------------------------------------------------------------------
do
local m_U = nil              -- { stamp, untilClock }

local function UPrint(msg) print("[EFV][Upg] UI " .. Str(msg)) end

-- "yes -> UNIT_X", "NO (greyed)" or why it could not be read.
local function Avail(e)
	local u = (type(e) == "table") and OwnUnit(e.o, e.u) or nil
	if u == nil then return "unit gone" end
	local ok, can, res = pcall(UnitManager.CanStartCommand, u, UnitCommandTypes.UPGRADE, false, true)
	if not ok then return "unreadable (" .. Str(can) .. ")" end
	local t = nil
	pcall(function() t = GameInfo.Units[res[UnitCommandResults.UNIT_TYPE]].UnitType end)
	return (can and "yes" or "NO (greyed)") .. (t and (" -> " .. t) or "")
end

local function Desc(u)
	if u == nil then return "FindID nil" end
	local s = "?"
	pcall(function()
		local id = u:GetID()
		s = "P" .. Str(u:GetOwner()) .. "/" .. Str(id) .. " serial=" .. math.floor(id / 65536) .. " slot=" .. (id % 65536) ..
			" type=" .. Str(GameInfo.Units[u:GetType()].UnitType) .. " at=" .. Str(u:GetX()) .. "," .. Str(u:GetY()) ..
			" moves=" .. Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves()) .. " dmg=" .. Str(u:GetDamage())
	end)
	return s
end

function ProxyUI.U1Start()
	local p = BaseParams("upg_spike")
	m_U = { stamp = p.stamp, untilClock = m_Clock + SHOT_WAIT }
	m_EligStatus = "U1: waiting for gameplay..."
	Send(p)
	RefreshInfo()
end

function ProxyUI.U1Step()
	local m = m_U
	if m == nil then return end
	local st = ScnState()
	local up = (st ~= nil and type(st.upg) == "table") and st.upg or nil
	local ans = up and up.ans or nil
	local answered = type(ans) == "table" and ans.stamp == m.stamp
	if not answered and m_Clock <= m.untilClock then return end
	m_U = nil
	if not answered then
		m_EligStatus = "U1: no answer from gameplay (see Lua.log)"
		RefreshInfo()
		return
	end
	local f = st.focus
	if type(f) == "table" and f.stamp == m.stamp then LookAt(f) end
	local ui = ""
	if type(up.k) == "table" and tonumber(up.step) == 1 then
		local a = "VEF-U1-M " .. Avail(up.k.M) .. ", VEF-U1-S " .. Avail(up.k.S)
		UPrint("press 1 Upgrade button: " .. a)
		ui = "[NEWLINE]UI: Upgrade " .. a
	end
	m_EligStatus = Str(ans.text) .. ui
	RefreshInfo()
end

function ProxyUI.U1Trace(pid, uid, upType)
	local st = ScnState()
	local up = st and st.upg
	if type(up) ~= "table" or type(up.k) ~= "table" or pid ~= LocalID() then return end
	local turn = -1
	pcall(function() turn = Game.GetCurrentGameTurn() end)
	if tonumber(up.turn) ~= turn then return end
	local parts = {}
	for _, k in ipairs({ "M", "S" }) do
		local e = up.k[k]
		if type(e) == "table" then parts[#parts + 1] = "VEF-U1-" .. k .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. ": " .. Desc(OwnUnit(e.o, e.u)) end
	end
	UPrint("Events.UnitUpgraded P" .. Str(pid) .. "/" .. Str(uid) .. " upgradeType=" .. Str(upType) .. " " .. Desc(OwnUnit(pid, uid)) ..
		"; " .. table.concat(parts, "; "))
end
end -- upgrade spike U1, UI side

local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_Air ~= nil then
		local ok, err = pcall(AirStep)
		if not ok then
			Log("air spike error: " .. Str(err))
			m_Air = nil
		end
	end
	local okC, errC = pcall(CorpsUI.Step)
	if not okC then Log("corps spike error: " .. Str(errC)) end
	local okP, errP = pcall(ProxyUI.Step)
	if not okP then Log("proxy test error: " .. Str(errP)) end
	local okU, errU = pcall(ProxyUI.U1Step)
	if not okU then Log("upgrade spike error: " .. Str(errU)) end
	if m_DP ~= nil then
		local ok, err = pcall(DpStep)
		if not ok then
			Log("denounce spike error: " .. Str(err))
			m_DP = nil
		end
	end
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
		local okL, errL = pcall(LabelsCheck)
		if not okL then Log("tracker label check error: " .. Str(errL)) end
		local okE, errE = pcall(EntrustUICheck)
		if not okE then Log("Entrust check error: " .. Str(errE)) end
	end
	if m_Vet ~= nil then
		local ok, err = pcall(VetStep)
		if not ok then
			Log("S6 route B error: " .. Str(err))
			m_Vet = nil
		end
	end
	if m_VS ~= nil then
		local ok, err = pcall(VsStep)
		if not ok then
			Log("V spike error: " .. Str(err))
			m_VS = nil
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
	VetStart = VetStart, GoTo = GoTo, VsStart = VsStart, DenounceSetup = DenounceSetup, DenounceProbe = DenounceProbe,
	AirCity = AirCity, AirHost = AirHost, AirFuel = AirFuel, AirAlly = AirAlly, AirCarrier = AirCarrier, AirStatus = AirStatus,
	C1 = function() CorpsUI.Start("corps_probe", "C1") end, C2 = function() CorpsUI.Start("corps_give", "C2") end,
	C3 = function() CorpsUI.Start("corps_merge", "C3") end, C4 = function() CorpsUI.Start("corps_cs_ai", "C4") end,
	C5 = function() CorpsUI.Start("corps_cs_force", "C5") end, C6 = function() CorpsUI.Start("corps_host", "C6") end,
	C7 = function() CorpsUI.Start("corps_trip", "C7") end, CStatus = function() CorpsUI.Start("corps_status", "C Status") end,
	C8 = function() CorpsUI.Start("corps_split", "C8") end, C9 = function() CorpsUI.Start("corps_vol", "C9") end,
	C10 = function() CorpsUI.Guard() end,
	P1 = function() ProxyUI.Start("scn_proxy", "P1") end, P2 = function() ProxyUI.AiDenounce() end,
	P3 = function() ProxyUI.Start("proxy_lower", "P3") end, P4 = function() ProxyUI.Start("proxy_hold", "P4") end,
	P5 = function() ProxyUI.Start("proxy_poor", "P5") end, PStatus = function() ProxyUI.Start("proxy_status", "P Status") end,
	U1 = function() ProxyUI.U1Start() end,
	AirRebase = AirRebase }

-- The list is built in a function of its own: a long table constructor holds up to
-- 50 registers until it flushes, which the main chunk cannot spare (Havok Script
-- register limit, see the do-block note at the top).
local function ButtonList()
return {
	{ header = "Screenshots (VEF 0.7+, new game after one End Turn)" },
	{ label = "Shot 1 Send picker",     shot = "shot1" },
	{ label = "Shot 2 Arrival",         shot = "shot2" },
	{ label = "Shot 3 Tracker",         shot = "shot3" },
	{ label = "Shot 4 Entrust",         shot = "shot4" },
	{ label = "Shot 5 Mutiny",          shot = "shot5" },
	{ header = "Test sessions (EFV/TESTING_1.0.4.md, older: TESTING_FINAL.md): start a NEW game; one click sets up each step" },
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
	{ label = "S17 Tracker labels",     shot = "scn_labels" },
	{ label = "S18 Entrust city-state", scn = "scn_entrust_cs" },
	{ label = "S19 Entrust major",      scn = "scn_entrust_major" },
	{ label = "S20 War sends home",     scn = "scn_war_home" },
	{ label = "S21 Veteran home",       scn = "scn_vet_home" },
	{ label = "V Veteran spike",        ui = "VsStart" },
	{ label = "T1 Volunteer partners",  elig = "elig_t1", test = "T1" },
	{ label = "T2 Shared enemy",        elig = "elig_t2", test = "T2" },
	{ label = "Go to scenario",         ui = "GoTo" },
	{ label = "Check now",              cmd = "scn_check" },
	{ header = "VEF 1.0.5 test (EFV/TESTING_1.0.5.md): start a NEW game and press P1 instead of S0" },
	{ label = "P1 Proxy war setup",     ui = "P1" },
	{ label = "P2 X denounces you",     ui = "P2" },
	{ label = "P3 X dislikes you (if P2 fails)", ui = "P3" },
	{ label = "P4 Hold the unit on its way", ui = "P4" },
	{ label = "P5 Poor host (press twice)", ui = "P5" },
	{ label = "P Status",               ui = "PStatus" },
	{ label = "U1 Upgrade spike (press 1, 2, 3)", ui = "U1" },
	{ label = "A9 Carrier for a rebase (press twice)", ui = "AirRebase" },
	{ header = "Denounce spike (EFV/TESTING_SPIKES.md): read only, details in Lua.log [EFV][Probe]" },
	{ label = "D Setup",                ui = "DenounceSetup" },
	{ label = "D Denounce probe",       ui = "DenounceProbe" },
	{ header = "Air spike (EFV/TESTING_SPIKES.md): Ancient-era game after S0, details in Lua.log [EFV][Air]" },
	{ label = "A1 Plane in your city",  ui = "AirCity" },
	{ label = "A2 Plane for B",         ui = "AirHost" },
	{ label = "A3 Fuel (press per step)", ui = "AirFuel" },
	{ label = "A4 Plane with ally F",   ui = "AirAlly" },
	{ label = "A5 Loaded carrier (again after the send)", ui = "AirCarrier" },
	{ label = "A Status",               ui = "AirStatus" },
	{ header = "Corps spike (EFV/TESTING_SPIKES.md): Ancient-era game after S0, details in Lua.log [EFV][Corps]" },
	{ label = "C1 Formation probe (press per step)", ui = "C1" },
	{ label = "C2 Formations for B and a city-state", ui = "C2" },
	{ label = "C3 Merge as host (again after End Turn)", ui = "C3" },
	{ label = "C4 City-state merges (optional)", ui = "C4" },
	{ label = "C5 Forced city-state merges", ui = "C5" },
	{ label = "C6 Host without the civic", ui = "C6" },
	{ label = "C7 Formation round trip (press twice)", ui = "C7" },
	{ label = "C8 Split a mixed Army (press twice)", ui = "C8" },
	{ label = "C9 Volunteer merges (again after End Turn)", ui = "C9" },
	{ label = "C10 Merge guard off/ask/block", ui = "C10" },
	{ label = "C Status",               ui = "CStatus" },
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
end
local BUTTONS = ButtonList()

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
	local okG, swallow = pcall(CorpsUI.Input, pInput)    -- C10 block mode
	if not okG then Log("merge guard input error: " .. Str(swallow)) elseif swallow then return true end
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
	Controls.TitleLabel:SetText(TitleText())
	ContextPtr:SetUpdate(OnUpdate)
	BuildButtons()
	Subscribe("Events.LoadGameViewStateDone", function() return Events.LoadGameViewStateDone end, AttachLaunchButton)
	Subscribe("Events.UnitSelectionChanged", function() return Events.UnitSelectionChanged end, OnSelectionChanged)
	Subscribe("Events.PlayerTurnActivated", function() return Events.PlayerTurnActivated end, OnSelectionChanged)
	Subscribe("Events.InterfaceModeChanged (corps)", function() return Events.InterfaceModeChanged end, CorpsUI.Mode)
	Subscribe("Events.UnitUpgraded (U1 trace)", function() return Events.UnitUpgraded end, ProxyUI.U1Trace)
	Subscribe("Events.UnitFormCorps (trace)", function() return Events.UnitFormCorps end, function(p, u) CorpsUI.Trace("UnitFormCorps", p, u) end)
	Subscribe("Events.UnitFormArmy (trace)", function() return Events.UnitFormArmy end, function(p, u) CorpsUI.Trace("UnitFormArmy", p, u) end)
	Subscribe("Events.UnitRemovedFromMap (trace)", function() return Events.UnitRemovedFromMap end,
		function(p, u) CorpsUI.Trace("UnitRemovedFromMap", p, u) end)
	Subscribe("LuaEvents.EFV_BadgeAuditReport", function() return LuaEvents.EFV_BadgeAuditReport end, OnAuditReport)
	Subscribe("Events.PlayerTurnActivated (audit)", function() return Events.PlayerTurnActivated end, function(pid)
		if pid == LocalID() then ScheduleAudit("turn start", true) end
	end)
	Subscribe("Events.UnitAddedToMap (audit)", function() return Events.UnitAddedToMap end, function() ScheduleAudit("unit added") end)
	Subscribe("Events.UnitRemovedFromMap (audit)", function() return Events.UnitRemovedFromMap end, function() ScheduleAudit("unit removed") end)
	Subscribe("Events.UnitKilledInCombat (audit)", function() return Events.UnitKilledInCombat end, function() ScheduleAudit("unit killed") end)
	RebuildTargets()
	Log("ready (Ctrl+Shift+D); EFV_UIShared loaded=" .. tostring(m_UIShared and EFV_UI_ReadStore ~= nil) .. "; " .. TitleText())
end

Initialize()
