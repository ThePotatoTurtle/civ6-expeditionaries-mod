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
		-- Base fields (UnitFlag.Initialize): m_Player, m_UnitID.
		local o = setmetatable({ pid = pid, uid = uid, m_Player = Players[pid], m_UnitID = uid,
			m_Instance = im:GetInstance() }, UnitFlag)
		o.m_Instance.ReligionIconBacking:SetHide(true)
		flags[pid .. ":" .. uid] = o
		o:UpdateReligion()
		return o
	end
	-- Base UnitFlag.GetUnit: m_Player:GetUnits():FindID(m_UnitID), which
	-- resolves the slot only (Session C) and still returns a dead unit's
	-- object for a while (Session F).
	function UnitFlag.GetUnit(self)
		return self.m_Player:GetUnits():FindID(self.m_UnitID)
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

-- 0.7.2: SetColor gets the engine value of the hex literal
-- (UI.GetColorValueFromHexLiteral, Colors.lua:6); the fake returns the
-- literal as a signed int32, so a raw literal no longer matches.
local HEX_GOLD, HEX_GREEN, HEX_LIGHT_BLUE = 0xFF3CC8FF, 0xFF4BE810, 0xFFFFC878
local function Int32(hex) return hex - 4294967296 end
local GOLD, GREEN, LIGHT_BLUE = Int32(HEX_GOLD), Int32(HEX_GREEN), Int32(HEX_LIGHT_BLUE)
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

-- Re-test 0.7 step 3: the emblem was dark and identical for the three force
-- types because the raw literal went to SetColor. Each type must get its own
-- converted tint, and every tint must be bright (each 0xAABBGGRR channel
-- decoded; the dark religion tag needs a light glyph).
test("flags: 0.7.2 tints go through UI.GetColorValueFromHexLiteral, differ per force type and are bright", function()
	local S = Boot()
	local rec = Deploy(S, 1)[1]
	local f = FlagFor(rec)
	local seen = {}
	for _, case in ipairs({ { "EXPEDITIONARY", HEX_GOLD }, { "VOLUNTEER", HEX_GREEN }, { "CS_EXPEDITIONARY", HEX_LIGHT_BLUE } }) do
		EditRecord(rec.id, function(r) r.forceType = case[1] end)
		Poll()
		UnitFlag.UpdateReligion(f)
		local c = f.m_Instance.ReligionIcon.color
		H.ok(c ~= case[2], case[1] .. ": the raw literal must not reach SetColor")
		H.eq(FAKE_UI.colorValues[c], case[2], case[1] .. ": converted from its own literal")
		local a = math.floor(case[2] / 16777216) % 256
		local b = math.floor(case[2] / 65536) % 256
		local g = math.floor(case[2] / 256) % 256
		local r = case[2] % 256
		H.eq(a, 255, case[1] .. ": opaque")
		H.ok(0.299 * r + 0.587 * g + 0.114 * b >= 120, case[1] .. string.format(": bright (r=%d g=%d b=%d)", r, g, b))
		H.ok(seen[c] == nil, case[1] .. ": tint differs from the other types")
		seen[c] = true
		H.ok(not f.m_Instance.ReligionIconBacking:IsHidden(), case[1] .. ": badge shown")
	end
	H.clean()
end)

test("flags: 0.7.2 without the converter the literal is used (no error, badge shown)", function()
	local S = Boot()
	UI.GetColorValueFromHexLiteral = nil
	local rec = Deploy(S, 1)[1]
	local f = FlagFor(rec)
	UnitFlag.UpdateReligion(f)
	H.ok(not f.m_Instance.ReligionIconBacking:IsHidden(), "badge shown")
	H.eq(f.m_Instance.ReligionIcon.color, HEX_GOLD)
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- 0.7.2 (0.7.1 report "the Volunteer Swordsman turned into a Warrior"): a VEF
-- badge / tooltip only on the flag's own live unit that a record names.
-- ---------------------------------------------------------------------------
local function DeployVolunteer(S)
	FAKE_UI.AsGameplay(function()
		H.openBorders(0, 1, true)
		H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER", 999)
		H.turns(2)
	end)
	local rec = EFV_UI_RecordsFor(0)[1]
	H.eq(rec.state, "DEPLOYED"); H.eq(rec.forceType, "VOLUNTEER"); H.eq(rec.onMapPlayerID, 0)
	return rec
end

local function AuditRows()
	local got = nil
	local fn = function(rows) got = rows end
	LuaEvents.EFV_BadgeAuditReport.Add(fn)
	LuaEvents.EFV_BadgeAuditRequest()
	LuaEvents.EFV_BadgeAuditReport.Remove(fn)
	return got
end

local function Bad(rows)
	local out = {}
	for _, r in ipairs(rows or {}) do if r.bad ~= nil then out[#out + 1] = r end end
	return out
end

test("flags 0.7.2: the dead Volunteer's slot reused by a new Warrior of the same owner: no badge, no VEF tooltip on it", function()
	local S = Boot()
	local rec = DeployVolunteer(S)
	local sw = FAKE.units[rec.onMapUnitID]
	local f = FlagFor(rec)
	H.ok(not f.m_Instance.ReligionIconBacking:IsHidden(), "badge on the Volunteer")
	H.len(Bad(AuditRows()), 0, "audit clean while alive")
	H.killUnit(sw)
	local w = H.unitInSlot(sw, 0, "UNIT_WARRIOR", sw.x, sw.y)   -- same owner, same slot, same tile
	H.ok(w.id ~= sw.id and w.id % 65536 == sw.id % 65536)
	H.eq(f:GetUnit(), w, "the base flag's FindID now resolves to the Warrior")
	UnitFlag.UpdateReligion(f)
	H.ok(f.m_Instance.ReligionIconBacking:IsHidden(), "old flag: badge off, never moved to the Warrior")
	local fw = UnitFlag.new(0, w.id)
	H.ok(fw.m_Instance.ReligionIconBacking:IsHidden(), "the Warrior's own flag: no badge")
	H.ok(not string.find(Tip(fw), "Warrior", 1, true), "no VEF tooltip names the Warrior")
	H.len(Bad(AuditRows()), 0, "audit: nothing shows a VEF tag")
	H.clean()
end)

test("flags 0.7.2: a dead unit's object (combat death, FindID still returns it) loses the badge", function()
	local S = Boot()
	local rec = DeployVolunteer(S)
	local f = FlagFor(rec)
	FAKE.CombatKill(FAKE.units[rec.onMapUnitID])
	UnitFlag.UpdateReligion(f)
	H.ok(f.m_Instance.ReligionIconBacking:IsHidden(), "GONE_DEAD: no badge")
	H.clean()
end)

test("flags 0.7.2: another player's unit with the dead unit's ID number never gets the badge", function()
	local S = Boot()
	local rec = DeployVolunteer(S)
	local sw = FAKE.units[rec.onMapUnitID]
	local f = FlagFor(rec)
	H.killUnit(sw)
	local b = H.unit(63, "UNIT_WARRIOR", sw.x, sw.y)   -- the Barbarian that took the tile
	FAKE.units[b.id] = nil
	b.id = sw.id                                        -- IDs are per player: the same number
	FAKE.units[b.id] = b
	local fb = UnitFlag.new(63, b.id)
	H.ok(fb.m_Instance.ReligionIconBacking:IsHidden(), "Barbarian flag: no badge")
	UnitFlag.UpdateReligion(f)
	H.ok(f.m_Instance.ReligionIconBacking:IsHidden(), "the old flag (unit gone for player 0): badge off")
	H.len(Bad(AuditRows()), 0)
	H.clean()
end)

test("flags 0.7.2: the audit hook reports a VEF tag on a unit that is not the record's live unit", function()
	local S = Boot()
	local rec = DeployVolunteer(S)
	local f = FlagFor(rec)
	local rows = AuditRows()
	H.len(rows, 1, "one decorated flag")
	H.eq(rows[1].fp, 0); H.eq(rows[1].fu, rec.onMapUnitID); H.eq(rows[1].ut, "UNIT_SWORDSMAN"); H.eq(rows[1].rid, rec.id)
	H.isnil(rows[1].bad)
	-- Simulate the reported glitch: a tag left visible on another unit's flag.
	local w = H.unit(0, "UNIT_WARRIOR", 12, 12)
	local fw = UnitFlag.new(0, w.id)
	fw.m_Instance.ReligionIconBacking:SetHide(false)
	local bad = Bad(AuditRows())
	H.len(bad, 1)
	H.eq(bad[1].fu, w.id); H.eq(bad[1].ut, "UNIT_WARRIOR"); H.eq(bad[1].bad, "no on-map record for this unit")
	H.clean()
end)

test("flags 0.7.2: EFV_Dev Badge audit logs PASS at the turn start and FAIL when a VEF tag sits on another unit", function()
	local S = Boot()
	local rec = DeployVolunteer(S)
	FlagFor(rec)
	local panel = FAKE_UI.LoadContext("EFV_Dev/UI/EFV_Dev_Panel.lua")
	Events.PlayerTurnActivated(0, true)
	FAKE_UI.Update(panel, 0.5)
	H.ok(H.hasLine("[EFV][CHECK] BADGE_AUDIT PASS"), "turn-start audit")
	H.ok(H.hasLine("1 VEF tag(s), each on its record's live unit; tracker: 1 on-map row(s)"))
	local w = H.unit(0, "UNIT_WARRIOR", 12, 12)
	local fw = UnitFlag.new(0, w.id)
	fw.m_Instance.ReligionIconBacking:SetHide(false)   -- the reported glitch, forced
	Events.UnitKilledInCombat(0, rec.onMapUnitID, 63, 1)
	FAKE_UI.Update(panel, 0.5)
	H.ok(H.hasLine("[EFV][CHECK] BADGE_AUDIT FAIL"))
	H.ok(H.hasLine("flag P0/" .. w.id .. " (unit P0/" .. w.id .. " UNIT_WARRIOR): no on-map record for this unit"))
	H.clean()
end)
