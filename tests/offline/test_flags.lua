-- @harness native
-- WP7.1 unit flag badges (EFV/UI/EFV_UnitFlagManager.lua) on the fake engine.
-- The base UnitFlagManager is not part of the project, so include("UnitFlagManager")
-- is answered by a minimal stand-in (FakeBase) with the parts the wrapper uses:
-- UnitFlag class (GetUnit, UpdateReligion that hides the religion tag of
-- non-religious units, UnitFlagManager.lua:796-814), GetUnitFlag (:166),
-- Subscribe / Unsubscribe (:1987, :2031) and Initialize. Records are real
-- (sent by the gameplay side); state changes are written to the store the
-- way gameplay commits do (records + EFV_Rev bump).
-- 0.7 (FIXPLAN_0.7 item 4): the badge icon is the sender's civ emblem
-- ("ICON_" .. civ type; ICON_CIVILIZATION_UNKNOWN when the local player has
-- not met the sender), tinted by force type; SetIcon returning false walks
-- the fallback chain.

local BASE = {}   -- stand-in state: calls, flags, handler

local function FakeBase()
	local flags = {}
	BASE.calls = 0
	UnitFlag = {}
	UnitFlag.__index = UnitFlag
	function UnitFlag.new(pid, uid)
		local im = InstanceManager:new("UnitFlag", "Anchor")
		local o = setmetatable({ pid = pid, uid = uid, m_Instance = im:GetInstance() }, UnitFlag)
		o.m_Instance.ReligionIconBacking:SetHide(true)
		flags[pid .. ":" .. uid] = o
		o:UpdateReligion()
		return o
	end
	function UnitFlag.GetUnit(self)
		return UnitManager.GetUnit(self.pid, self.uid)
	end
	function UnitFlag.UpdateReligion(self)
		BASE.calls = BASE.calls + 1
		self.m_Instance.ReligionIconBacking:SetHide(true)
	end
	BASE.UpdateReligion = UnitFlag.UpdateReligion
	function GetUnitFlag(pid, uid)
		return flags[pid .. ":" .. uid]
	end
	BASE.onAdded = function(pid, uid) UnitFlag.new(pid, uid) end
	function Subscribe() Events.UnitAddedToMap.Add(BASE.onAdded) end
	function Unsubscribe() Events.UnitAddedToMap.Remove(BASE.onAdded) end
	function Initialize() end
end

-- World + gameplay + UI context + wrapper (Subscribe = the base OnInit call).
local function Boot(opts)
	opts = opts or {}
	local S = H.baseScenario()
	H.loadEFV()
	include("fake_ui")
	FAKE_UI.Enable()
	EFV_Config.LOG_LEVEL = 3
	if opts.badges == false then
		EFV_Config.FLAG_FLAG_BADGES = false
	end
	Modding = { IsModActive = function() return false end }
	local realInclude = include
	include = function(name)
		if name == "UnitFlagManager" then
			return FakeBase()
		end
		return realInclude(name)
	end
	FAKE.dofile("EFV/UI/EFV_UnitFlagManager.lua")
	include = realInclude
	getmetatable(InstanceManager:new("x", "y"):GetInstance().Any).SetColor = function(c, v) c.color = v end
	Subscribe()
	H.markBody()
	return S
end

-- Sends n swordsmen A(0) -> B(1) as Expeditionary and deploys them. Returns records.
local function Deploy(S, n)
	FAKE_UI.AsGameplay(function()
		for i = 1, n or 1 do
			H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 9 + i, { vet = "Brutus" .. i }), 1, S.c1, "EXPEDITIONARY", 999)
		end
		H.turns(2)
	end)
	return EFV_UI_RecordsFor(0)
end

local function FlagFor(rec)
	return GetUnitFlag(rec.onMapPlayerID, rec.onMapUnitID) or UnitFlag.new(rec.onMapPlayerID, rec.onMapUnitID)
end

-- Gameplay-style commit of a record edit (EFV_Rev bump, INTERFACES note 16).
local function EditRecord(id, fn)
	FAKE_UI.AsGameplay(function()
		local recs = Game:GetProperty("EFV_Records")
		fn(recs["r" .. id])
		Game:SetProperty("EFV_Records", recs)
		Game:SetProperty("EFV_Rev", (Game:GetProperty("EFV_Rev") or 0) + 1)
	end)
end

local GOLD, GREEN, LIGHT_BLUE = 0xFF3CC8FF, 0xFF4BE810, 0xFFFFC878
local function Emblem(pid) return "ICON_" .. PlayerConfigurations[pid]:GetCivilizationTypeName() end

local function Tip(flag) return flag.m_Instance.ReligionIconBacking.tooltip or "" end
local function Has(s, sub) return string.find(s, sub, 1, true) ~= nil end
local function Poll() Events.UnitSelectionChanged(0, 0, 0, 0, 0, true, false) end

test("flags: tracked EXP unit gets the badge and the 5-arg tooltip; an untracked unit stays base", function()
	local S = Boot()
	local rec = Deploy(S, 1)[1]
	H.eq(rec.state, "DEPLOYED")
	local f = FlagFor(rec)
	local inst = f.m_Instance
	H.ok(not inst.ReligionIconBacking:IsHidden(), "badge shown")
	H.eq(inst.ReligionIcon.icon, Emblem(0), "the sender's emblem")
	H.ok(Emblem(0) ~= Emblem(1))
	H.eq(inst.ReligionIcon.color, GOLD, "EXP tint")
	local tt = Tip(f)
	H.ok(Has(tt, "[" .. Locale.Lookup("LOC_EFV_BADGE_EXP") .. "]"), tt)
	H.ok(Has(tt, "Brutus1"), "unit name: " .. tt)
	H.ok(Has(tt, EFV_UI_PlayerName(0)) and Has(tt, EFV_UI_PlayerName(1)), "sender + recipient: " .. tt)
	H.ok(Has(tt, Locale.Lookup("LOC_EFV_STATE_DEPLOYED", 20)), "state + remaining turns: " .. tt)
	H.ok(not Has(tt, "{"), "all LOC_EFV_FLAG_TT args filled: " .. tt)
	local plain = UnitFlag.new(0, H.unit(0, "UNIT_WARRIOR", 12, 12):GetID())
	H.ok(plain.m_Instance.ReligionIconBacking:IsHidden(), "untracked unit: base result")
	H.ok(plain.m_Instance.ReligionIcon.icon == nil, "no icon touched")
	H.clean()
end)

test("flags: EFV_Rev refresh -> Grace N, lapsed VOL, CS, Mutiny N; ended record loses the badge", function()
	local S = Boot()
	local rec = Deploy(S, 1)[1]
	local f = FlagFor(rec)
	Poll()
	local calls = BASE.calls
	Poll()
	H.eq(BASE.calls, calls, "same rev and turn: no flag update")
	EditRecord(rec.id, function(r) r.state = "GRACE"; r.graceTurnsLeft = 3 end)
	Poll()
	H.ok(Has(Tip(f), Locale.Lookup("LOC_EFV_STATE_GRACE", 3)), Tip(f))
	EditRecord(rec.id, function(r) r.forceType = "VOLUNTEER"; r.lapsed = 1; r.lapseReason = "WAR" end)
	Poll()
	H.eq(f.m_Instance.ReligionIcon.icon, Emblem(0))
	H.eq(f.m_Instance.ReligionIcon.color, GREEN, "VOL tint")
	H.ok(Has(Tip(f), "[" .. Locale.Lookup("LOC_EFV_BADGE_VOL") .. "]"), Tip(f))
	H.ok(Has(Tip(f), Locale.Lookup("LOC_EFV_LAPSE_WAR")), "volunteer lapse: " .. Tip(f))
	EditRecord(rec.id, function(r) r.forceType = "CS_EXPEDITIONARY"; r.lapsed = nil; r.state = "MUTINY"; r.lastDamage = 40 end)
	Poll()
	H.eq(f.m_Instance.ReligionIcon.icon, Emblem(0))
	H.eq(f.m_Instance.ReligionIcon.color, LIGHT_BLUE, "CS tint")
	H.ok(Has(Tip(f), "[" .. Locale.Lookup("LOC_EFV_BADGE_CS") .. "]"), Tip(f))
	H.ok(Has(Tip(f), Locale.Lookup("LOC_EFV_STATE_MUTINY", 3)), Tip(f))
	EditRecord(rec.id, function(r) r.state = "RETURNING"; r.arrivalTurn = FAKE.turn + 2 end)
	Poll()
	H.ok(f.m_Instance.ReligionIconBacking:IsHidden(), "not on-map state: base look again")
	H.clean()
end)

test("flags: new turn updates the remaining turns; UnitDamageChanged updates Mutiny N", function()
	local S = Boot()
	local recs = Deploy(S, 2)
	local f1, f2 = FlagFor(recs[1]), FlagFor(recs[2])
	FAKE_UI.AsGameplay(function() H.turns(1) end)
	Events.PlayerTurnActivated(0, true)
	H.ok(Has(Tip(f1), Locale.Lookup("LOC_EFV_STATE_DEPLOYED", 19)), Tip(f1))
	EditRecord(recs[2].id, function(r) r.state = "MUTINY"; r.lastDamage = 40 end)
	Poll()
	H.ok(Has(Tip(f2), Locale.Lookup("LOC_EFV_STATE_MUTINY", 3)), Tip(f2))
	local u = UnitManager.GetUnit(recs[2].onMapPlayerID, recs[2].onMapUnitID)
	u.damage = 80
	Events.UnitDamageChanged(u:GetOwner(), u:GetID(), 80, 40)
	H.ok(Has(Tip(f2), Locale.Lookup("LOC_EFV_STATE_MUTINY", 1)), "live damage: " .. Tip(f2))
	-- Base OnShutdown -> Unsubscribe removes the EFV handlers too.
	Unsubscribe()
	H.eq(Events.UnitDamageChanged.Count(), 0)
	H.eq(Events.UnitSelectionChanged.Count(), 0)
	H.clean()
end)

test("flags: FLAG_FLAG_BADGES=false -> base UnitFlagManager runs unwrapped", function()
	local S = Boot({ badges = false })
	H.eq(UnitFlag.UpdateReligion, BASE.UpdateReligion, "UpdateReligion not wrapped")
	local f = FlagFor(Deploy(S, 1)[1])
	H.ok(f.m_Instance.ReligionIconBacking:IsHidden(), "no badge")
	H.eq(Events.UnitDamageChanged.Count(), 0, "no EFV handlers")
	H.ok(#H.lines("badges disabled", true) == 1, "logged at load")
	H.clean()
end)

test("flags: an EFV error restores the base look of every badged flag and stops badges", function()
	local S = Boot()
	local recs = Deploy(S, 2)
	local f1, f2 = FlagFor(recs[1]), FlagFor(recs[2])
	H.ok(not f1.m_Instance.ReligionIconBacking:IsHidden() and not f2.m_Instance.ReligionIconBacking:IsHidden())
	local real = EFV_UI_RecordForUnit
	EFV_UI_RecordForUnit = function() error("boom") end
	UnitFlag.UpdateReligion(f2)
	EFV_UI_RecordForUnit = real
	H.ok(f2.m_Instance.ReligionIconBacking:IsHidden(), "failing flag: base result")
	H.ok(f1.m_Instance.ReligionIconBacking:IsHidden(), "other badged flag restored")
	H.ok(H.hasLine("badges off for this session"))
	EditRecord(recs[1].id, function(r) r.state = "GRACE"; r.graceTurnsLeft = 2 end)
	Poll()
	UnitFlag.UpdateReligion(f1)
	H.ok(f1.m_Instance.ReligionIconBacking:IsHidden(), "off for the session")
	H.len(H.lines("badges off for this session"), 1, "logged once")
end, { allowErrors = true })

test("flags: unmet sender -> unknown emblem; the sender and a player who met it see the emblem", function()
	local S = Boot()
	local rec = Deploy(S, 1)[1]
	local f = FlagFor(rec)
	FAKE.localPlayer = 2
	FAKE.PairSet(FAKE.diplo.met, 2, 0, false)
	UnitFlag.UpdateReligion(f)
	H.ok(not f.m_Instance.ReligionIconBacking:IsHidden(), "badge still shown")
	H.eq(f.m_Instance.ReligionIcon.icon, "ICON_CIVILIZATION_UNKNOWN")
	H.eq(f.m_Instance.ReligionIcon.color, GOLD)
	FAKE.PairSet(FAKE.diplo.met, 2, 0, true)
	UnitFlag.UpdateReligion(f)
	H.eq(f.m_Instance.ReligionIcon.icon, Emblem(0), "met: emblem")
	FAKE.localPlayer = 0
	FAKE.PairSet(FAKE.diplo.met, 0, 0, false)
	UnitFlag.UpdateReligion(f)
	H.eq(f.m_Instance.ReligionIcon.icon, Emblem(0), "the sender always sees its own emblem")
	H.clean()
end)

test("flags: SetIcon returning false walks the fallback chain (unknown emblem, then the city-state glyph)", function()
	local S = Boot()
	local rec = Deploy(S, 1)[1]
	local f = FlagFor(rec)
	local icon = f.m_Instance.ReligionIcon
	local missing = { [Emblem(0)] = true }
	local tried = {}
	icon.SetIcon = function(c, name)
		tried[#tried + 1] = name
		if missing[name] then return false end
		c.icon = name
		return true
	end
	UnitFlag.UpdateReligion(f)
	H.deq(tried, { Emblem(0), "ICON_CIVILIZATION_UNKNOWN" })
	H.eq(icon.icon, "ICON_CIVILIZATION_UNKNOWN")
	missing["ICON_CIVILIZATION_UNKNOWN"] = true
	tried = {}
	UnitFlag.UpdateReligion(f)
	H.deq(tried, { Emblem(0), "ICON_CIVILIZATION_UNKNOWN", "ICON_CITYSTATE_MILITARISTIC" })
	H.eq(icon.icon, "ICON_CITYSTATE_MILITARISTIC")
	H.eq(icon.color, GOLD, "tint kept")
	H.ok(not f.m_Instance.ReligionIconBacking:IsHidden())
	H.clean()
end)
