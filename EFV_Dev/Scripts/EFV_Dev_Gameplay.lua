-- ===========================================================================
-- EFV_Dev_Gameplay.lua  (EFV_Dev mod, WP T3; PLAN 5.0)
-- Context: gameplay (AddGameplayScripts). TESTING ONLY.
--
-- One handler, GameEvents.EFV_Dev(playerID, params), dispatching on
-- params.cmd. Requests come from UI/EFV_Dev_Panel.lua as FLAT params
-- (numbers and strings only, SPIKES S2):
--   cmd        command name (table CMD below)
--   target     target player (panel "Target" cycle)
--   unitOwner, unitID   head-selected unit (-1 if none)
--   cityOwner, cityID   head-selected city (-1 if none)
--   x, y       selected unit's plot, else the selected city's plot (-1)
--   type       text field (unit / promotion / resource type, force type)
--   amount     number field
--   k=v pairs from the "Extra" field are copied as extra params
--              (e.g. rec=3, a=1, field=graceTurnsLeft, value=1)
--
-- EFV state is read and written ONLY through Game properties via EFV's own
-- public module EFV_Records (INTERFACES 3.4, 5): Load -> Get/Touch -> Commit.
-- This script runs in its own Lua state, so the EFV modules are included
-- here again (ImportFiles of the EFV mod); they hold no cached state.
--
-- Every line is logged as "[EFV][T<turn>][Dev] <cmd>: ..." so that
-- tools/install.ps1 -Watch shows it together with EFV's own lines.
--
-- Register limit: Civ VI's Havok Script rejects a function that needs too
-- many registers ("too complex"; 172 loads, 206 fails), and every main-chunk
-- local holds one register until the end of its block. So each section keeps
-- its private helpers inside its own do ... end block; only the names other
-- sections use are declared just before the block, and the turn checks go in
-- the EV table. tools/check_lua.py (check_all) fails above 180.
-- ===========================================================================

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")
include("EFV_Units")
include("EFV_Spawn")
include("EFV_Notify")
-- EFV:GLOBALS EFV_Spawn EFV_Notify EFV_DestinationRows EFV_PlayerName EFV_CityName EFV_UnitDisplayName
-- EFV:GLOBALS EFV_Config EFV_Util EFV_Records EFV_Units EFV_SortedAlivePlayers EFV_HasOpenBordersFrom EFV_UnitMatches
-- EFV:GLOBALS EFV_SortedKeys EFV_PlayerKind EFV_ValidReturnTerritory EFV_IsUpgradeOf EFV_UnitGoneReason EFV_UpgradeTargets
-- EFV:GLOBALS EFV_PartnerBasis EFV_VolunteerBasis EFV_EvaluateSend EFV_HealResourceType
-- EFV:GLOBALS EFV_ProxyWarEnemies EFV_SendRecipientReasons EFV_UnitSendReasons EFV_Band EFV_Fee

EFV_Dev = {}

-- Dev-tools version (EFV_Dev.modinfo Name) and the EFV version it was built
-- for (EFV_Config.VERSION). EFV_Dev may be bumped on its own (final-session
-- scenarios: 0.6.0-dev.1; the session from a brand-new game: 0.6.1-dev.1;
-- the 0.7 re-test S12 / S13 and the Workshop Shot buttons: 0.7.0-dev.1;
-- rebuilt for EFV 0.7.1-dev without changes: 0.7.1-dev.1; re-test 0.7
-- fixes (S4 holds the Volunteer, S10 removes the Barbarians after your
-- fight, S12 checks the arrival turn): 0.7.2-dev.1; rebuilt for EFV
-- 0.7.3-dev without changes: 0.7.3-dev.1; rebuilt for EFV 0.7.4-dev
-- without changes: 0.7.4-dev.2; S15 Receive forces: 0.7.4-dev.3; rebuilt for
-- the EFV 1.0.0 release without changes: 1.0.0.1; eligibility tests T1 / T2:
-- 1.0.1.3; VEF 1.0.2 City-State rule (no shared enemy needed), S0 without
-- the city-state's war, T2 City-State lines: 1.0.2.1; S16 Break transit for
-- the VEF transit cancel, built on EFV 1.0.2 plus the unreleased change:
-- 1.0.2.2; rebuilt for the EFV 1.0.3 release without changes: 1.0.3.1; the
-- 1.0.3 test session (S17 tracker labels, S18 / S19 Entrust rules) and the
-- veteran one-turn restore spike (V button, Data/EFV_Dev_Spike.xml):
-- 1.0.3.2; the VEF 1.0.4 session (S20 war sends lent units home, S21
-- veteran home with three promotions): 1.0.4.1; the denouncement reader
-- spike (D Setup, D Denounce probe): 1.0.4.2; the air-unit spike (A1-A5,
-- A Status): 1.0.4.3; the Corps spike (C1-C7, C Status): 1.0.4.4; C8
-- split, C9 Volunteer merges, C10 merge guard and the merge trace:
-- 1.0.4.5; the VEF 1.0.5 session (P buttons, A9, 3-turn denouncements):
-- 1.0.5.1; the upgrade spike U1 and its trace, run in the same session:
-- 1.0.5.2); a mismatch of FOR_EFV with the loaded EFV build is logged at load.
EFV_Dev.VERSION = "1.0.5.2"
EFV_Dev.FOR_EFV = "1.0.5"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function Turn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and t ~= nil then return t end
	return -1
end

local function Log(cmd, msg)
	print("[EFV][T" .. tostring(Turn()) .. "][Dev] " .. tostring(cmd) .. ": " .. tostring(msg))
end

local function Str(v)
	if v == nil then return "nil" end
	return tostring(v)
end

local function Num(v, default)
	local n = tonumber(v)
	if n == nil then return default end
	return n
end

local function Call(obj, method, ...)
	if obj == nil then return false, "object is nil" end
	local args = { ... }
	local n = select("#", ...)
	return pcall(function()
		local f = obj[method]
		if f == nil then error("method missing: " .. method) end
		return f(obj, unpack(args, 1, n))
	end)
end

local function PlayerName(pid)
	local name = "P" .. Str(pid)
	pcall(function()
		name = name .. " " .. Locale.Lookup(PlayerConfigurations[pid]:GetCivilizationShortDescription())
	end)
	return name
end

local function FindUnit(owner, uid)
	if owner < 0 or uid < 0 or Players[owner] == nil then return nil end
	local u = Players[owner]:GetUnits():FindID(uid)
	-- FindID resolves only the slot (Session C): reject a different unit.
	if u ~= nil and u:GetID() ~= uid then return nil end
	return u
end

-- The unit to act on: with extra rec=<id>, the on-map unit of that record
-- (AI-owned Expeditionary units cannot be selected by the tester; Phase 2
-- tests P2.1-P2.3), identity-checked; else the selected unit.
local function SelectedUnit(p)
	local rid = Num(p.rec, nil)
	if rid ~= nil then
		local rec = EFV_Records.Get(EFV_Records.Load(), rid)
		if rec ~= nil and rec.onMapPlayerID ~= nil and rec.onMapUnitID ~= nil then
			local u = FindUnit(rec.onMapPlayerID, rec.onMapUnitID)
			if u ~= nil and EFV_UnitMatches(u, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType) then
				return u
			end
		end
		return nil
	end
	return FindUnit(Num(p.unitOwner, -1), Num(p.unitID, -1))
end

local function SelectedCity(p)
	local owner, cid = Num(p.cityOwner, -1), Num(p.cityID, -1)
	if owner < 0 or cid < 0 then return nil end
	return CityManager.GetCity(owner, cid)
end

local function UnitTypeName(u)
	local ok, t = pcall(function() return GameInfo.Units[u:GetType()].UnitType end)
	if ok then return t end
	return "?"
end

local function DescribeUnit(u)
	if u == nil then return "nil" end
	local s = PlayerName(u:GetOwner()) .. " unit " .. Str(u:GetID()) .. " " .. UnitTypeName(u) ..
		" @" .. Str(u:GetX()) .. "," .. Str(u:GetY())
	pcall(function()
		local exp = u:GetExperience()
		local promos = {}
		for row in GameInfo.UnitPromotions() do
			if exp:HasPromotion(row.Index) then promos[#promos + 1] = row.UnitPromotionType end
		end
		s = s .. " dmg=" .. Str(u:GetDamage()) .. " xp=" .. Str(exp:GetExperiencePoints()) ..
			" next=" .. Str(exp:GetExperienceForNextLevel()) .. " promotions=" .. table.concat(promos, "+") ..
			" name=" .. Str(exp:GetVeteranName())
	end)
	pcall(function()
		s = s .. " moves=" .. Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves()) ..
			" formation=" .. Str(u:GetMilitaryFormation())
	end)
	pcall(function()
		local plot = Map.GetPlot(u:GetX(), u:GetY())
		s = s .. " plotOwner=" .. Str(plot:GetOwner())
	end)
	return s
end

local function FreeLand(plot)
	if plot == nil then return false end
	local ok, res = pcall(function()
		return plot:GetUnitCount() == 0 and not plot:IsWater() and not plot:IsImpassable()
			and CityManager.GetCityAt(plot:GetX(), plot:GetY()) == nil
	end)
	return ok and res == true
end

local function FreeWater(plot)
	if plot == nil then return false end
	local ok, res = pcall(function()
		return plot:GetUnitCount() == 0 and plot:IsWater() and not plot:IsImpassable()
	end)
	return ok and res == true
end

-- Nearest free plot to (x, y): the plot itself, then ring by ring (sorted by
-- index for a deterministic result), up to 6 rings.
local function FindFreePlot(x, y, water)
	local test = water and FreeWater or FreeLand
	local centre = Map.GetPlot(x, y)
	if test(centre) then return centre end
	for ring = 1, 6 do
		local list = {}
		local ok, plots = pcall(function() return Map.GetNeighborPlots(x, y, ring) end)
		if ok and plots ~= nil then
			for _, p in ipairs(plots) do
				if Map.GetPlotDistance(x, y, p:GetX(), p:GetY()) == ring and test(p) then list[#list + 1] = p end
			end
		end
		if #list > 0 then
			table.sort(list, function(a, b) return a:GetIndex() < b:GetIndex() end)
			return list[1]
		end
	end
	return nil
end

local function Anchor(p)
	local x, y = Num(p.x, -1), Num(p.y, -1)
	if x >= 0 and y >= 0 then return x, y end
	local c = nil
	pcall(function() c = Players[Num(p.target, 0)]:GetCities():GetCapitalCity() end)
	if c ~= nil then return c:GetX(), c:GetY() end
	return nil, nil
end

local function CreateUnit(cmd, ownerID, unitType, x, y)
	local row = GameInfo.Units[unitType]
	if row == nil then Log(cmd, "unknown unit type " .. Str(unitType)); return nil end
	local ok, u = pcall(function() return Players[ownerID]:GetUnits():Create(row.Index, x, y) end)
	if not ok or u == nil then
		Log(cmd, "Create failed for " .. unitType .. " at " .. x .. "," .. y .. ": " .. Str(u))
		return nil
	end
	return u
end

-- The record of the selected unit, or params.rec.
local function ResolveRecord(store, p)
	local id = Num(p.rec, nil)
	if id ~= nil then return EFV_Records.Get(store, id) end
	local u = SelectedUnit(p)
	if u ~= nil then return EFV_Records.FindByUnit(store, u:GetOwner(), u:GetID()) end
	-- a single record is unambiguous
	local ids = EFV_Records.IDs(store)
	if #ids == 1 then return EFV_Records.Get(store, ids[1]) end
	return nil
end

local function RecordLine(rec)
	return "id=" .. Str(rec.id) .. " " .. Str(rec.forceType) .. " " .. Str(rec.state) ..
		" s=" .. Str(rec.senderID) .. " r=" .. Str(rec.recipientID) .. " unit=" .. Str(rec.unitType) ..
		" onMap=" .. Str(rec.onMapPlayerID) .. "/" .. Str(rec.onMapUnitID) ..
		" sent=" .. Str(rec.sentTurn) .. " arr=" .. Str(rec.arrivalTurn) .. " dep=" .. Str(rec.deployedTurn) ..
		" dur=" .. Str(rec.durationTurns) .. " grace=" .. Str(rec.graceTurnsLeft) .. " lapsed=" .. Str(rec.lapsed) ..
		" ret=" .. Str(rec.returnReason) .. " dest=" .. Str(rec.destX) .. "," .. Str(rec.destY)
end

local function SetDiploPair(cmd, a, b, method, value)
	local ok1, e1 = Call(Players[a]:GetDiplomacy(), method, b, value)
	local ok2, e2 = Call(Players[b]:GetDiplomacy(), method, a, value)
	Log(cmd, PlayerName(a) .. " <-> " .. PlayerName(b) .. " " .. method .. "(" .. tostring(value) .. ") ok=" ..
		tostring(ok1 and ok2) .. ((ok1 and ok2) and "" or (" err=" .. Str(e1) .. " / " .. Str(e2))))
end

-- ---------------------------------------------------------------------------
-- Commands. Each: function(playerID, params) ; playerID = requesting (local) player.
-- ---------------------------------------------------------------------------
local CMD = {}

-- spawn: type (default UNIT_SWORDSMAN) x amount (default 1) for target at the selected plot.
CMD.spawn = function(me, p)
	local owner = Num(p.owner, Num(p.target, me))
	local ut = p.type
	if type(ut) ~= "string" or GameInfo.Units[ut] == nil then ut = "UNIT_SWORDSMAN" end
	local x, y = Anchor(p)
	if x == nil then Log("spawn", "no plot selected"); return end
	local water = GameInfo.Units[ut].Domain == "DOMAIN_SEA"
	for _ = 1, math.max(1, Num(p.amount, 1)) do
		local plot = FindFreePlot(x, y, water)
		if plot == nil then Log("spawn", "no free plot near " .. x .. "," .. y); return end
		local u = CreateUnit("spawn", owner, ut, plot:GetX(), plot:GetY())
		if u ~= nil then Log("spawn", DescribeUnit(u)) end
	end
end

-- fill: occupy every free land plot in rings 1..amount (default 5) around the
-- selected city (or plot) with type (default UNIT_WARRIOR) for target (P1.6).
CMD.fill = function(me, p)
	local owner = Num(p.owner, Num(p.target, me))
	local ut = p.type
	if type(ut) ~= "string" or GameInfo.Units[ut] == nil then ut = "UNIT_WARRIOR" end
	local c = SelectedCity(p)
	local x, y = Anchor(p)
	if c ~= nil then x, y = c:GetX(), c:GetY() end
	if x == nil then Log("fill", "no city or plot selected"); return end
	local rings = math.min(6, math.max(1, Num(p.amount, 5)))
	local n = 0
	local plots = Map.GetNeighborPlots(x, y, rings)
	local list = {}
	for _, plot in ipairs(plots) do list[#list + 1] = plot end
	table.sort(list, function(a, b) return a:GetIndex() < b:GetIndex() end)
	for _, plot in ipairs(list) do
		-- any empty passable land plot except the centre (other city centres too:
		-- a spawn may use the recipient's own city tile)
		local centre = plot:GetX() == x and plot:GetY() == y
		local ok, empty = pcall(function() return plot:GetUnitCount() == 0 and not plot:IsWater() and not plot:IsImpassable() end)
		if not centre and ok and empty then
			if CreateUnit("fill", owner, ut, plot:GetX(), plot:GetY()) ~= nil then n = n + 1 end
		end
	end
	Log("fill", "created " .. n .. " " .. ut .. " for " .. PlayerName(owner) .. " within " .. rings .. " of " .. x .. "," .. y)
end

CMD.damage = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("damage", "no unit selected"); return end
	u:SetDamage(Num(p.amount, 10))
	Log("damage", DescribeUnit(u))
end

CMD.heal = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("heal", "no unit selected"); return end
	u:SetDamage(0)
	Log("heal", DescribeUnit(u))
end

CMD.xp = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("xp", "no unit selected"); return end
	u:GetExperience():ChangeExperience(Num(p.amount, 15))
	Log("xp", DescribeUnit(u))
end

-- promote: type = PROMOTION_X, else the first promotion of the unit's class it lacks.
CMD.promote = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("promote", "no unit selected"); return end
	local exp = u:GetExperience()
	local row = nil
	if type(p.type) == "string" then row = GameInfo.UnitPromotions[p.type] end
	if row == nil then
		local cls = GameInfo.Units[u:GetType()].PromotionClass
		for r in GameInfo.UnitPromotions() do
			if r.PromotionClass == cls and not exp:HasPromotion(r.Index) then row = r; break end
		end
	end
	if row == nil then Log("promote", "no promotion found (type=" .. Str(p.type) .. ")"); return end
	local ok, err = pcall(function() exp:SetPromotion(row.Index) end)
	Log("promote", row.UnitPromotionType .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " -> " .. DescribeUnit(u))
end

CMD.finish = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("finish", "no unit selected"); return end
	UnitManager.FinishMoves(u)
	Log("finish", DescribeUnit(u))
end

-- corps: put the selected unit into a Corps (FORMATION send reason; D3 merge
-- tests). amount 0 = back to STANDARD. SetMilitaryFormation is CONFIRMED in G
-- (A34, WarMachineScenario.lua:189-191); no CanFormMilitaryFormation guard on
-- purpose (test tool).
CMD.corps = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("corps", "no unit selected"); return end
	local f = MilitaryFormationTypes.CORPS_FORMATION
	if Num(p.amount, 1) == 0 then f = MilitaryFormationTypes.STANDARD_FORMATION end
	local ok, err = pcall(function() u:SetMilitaryFormation(f) end)
	Log("corps", "SetMilitaryFormation(" .. Str(f) .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " -> " .. DescribeUnit(u))
end

CMD.kill = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("kill", "no unit selected"); return end
	local o, id = u:GetOwner(), u:GetID()
	local ok, err = pcall(function() Players[o]:GetUnits():Destroy(u) end)
	Log("kill", "Destroy " .. o .. "/" .. id .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
end

-- place: move the unit (selected, or extra rec=<id>) to extra tx=<x>;ty=<y>
-- with UnitManager.PlaceUnit (AustraliaScenario.lua:854, gameplay). Used to
-- put an AI-owned Expeditionary unit on neutral land or back on valid
-- territory (Phase 2 tests). Test tool only: no stacking or terrain check.
CMD.place = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("place", "no unit (select one or extra rec=<id>)"); return end
	local tx, ty = Num(p.tx, -1), Num(p.ty, -1)
	if tx < 0 or ty < 0 or Map.GetPlot(tx, ty) == nil then Log("place", "need extra tx=<x>;ty=<y>"); return end
	local ok, err = pcall(function() UnitManager.PlaceUnit(u, tx, ty) end)
	Log("place", "PlaceUnit(" .. tx .. "," .. ty .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. " -> " .. DescribeUnit(u))
end

CMD.unit = function(me, p)
	local u = SelectedUnit(p)
	if u == nil then Log("unit", "no unit selected"); return end
	local store = EFV_Records.Load()
	local rec = EFV_Records.FindByUnit(store, u:GetOwner(), u:GetID())
	Log("unit", DescribeUnit(u) .. " record=" .. (rec and RecordLine(rec) or "none"))
end

-- gold: change the balance of `who` (default me; extra who=<pid>) by amount (default 1000).
CMD.gold = function(me, p)
	local who = Num(p.who, me)
	local t = Players[who]:GetTreasury()
	t:ChangeGoldBalance(Num(p.amount, 1000))
	Log("gold", PlayerName(who) .. " gold now " .. Str(t:GetGoldBalance()))
end

-- setgold: set the balance to amount (P1.2c "gold -(balance-10)" in one click).
CMD.setgold = function(me, p)
	local who = Num(p.who, me)
	local t = Players[who]:GetTreasury()
	t:ChangeGoldBalance(Num(p.amount, 0) - t:GetGoldBalance())
	Log("setgold", PlayerName(who) .. " gold now " .. Str(t:GetGoldBalance()))
end

local function ResourceRow(p)
	if type(p.type) == "string" and GameInfo.Resources[p.type] ~= nil then return GameInfo.Resources[p.type] end
	return GameInfo.Resources["RESOURCE_OIL"]
end

CMD.res = function(me, p)
	local who = Num(p.who, me)
	local row = ResourceRow(p)
	local r = Players[who]:GetResources()
	local ok, err = pcall(function() r:ChangeResourceAmount(row.Index, Num(p.amount, 5)) end)
	Log("res", PlayerName(who) .. " " .. row.ResourceType .. " now " .. Str(r:GetResourceAmount(row.Index)) ..
		" ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
end

CMD.setres = function(me, p)
	local who = Num(p.who, me)
	local row = ResourceRow(p)
	local r = Players[who]:GetResources()
	local ok, err = pcall(function() r:ChangeResourceAmount(row.Index, Num(p.amount, 0) - r:GetResourceAmount(row.Index)) end)
	Log("setres", PlayerName(who) .. " " .. row.ResourceType .. " now " .. Str(r:GetResourceAmount(row.Index)) ..
		" ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
end

-- Diplomacy between a (extra a=<pid>, default me) and the target.
-- amount 0 = remove (ally/friend).
CMD.ally = function(me, p)
	SetDiploPair("ally", Num(p.a, me), Num(p.target, -1), "SetHasAllied", Num(p.amount, 1) ~= 0)
end

CMD.friend = function(me, p)
	SetDiploPair("friend", Num(p.a, me), Num(p.target, -1), "SetHasDeclaredFriendship", Num(p.amount, 1) ~= 0)
end

CMD.meet = function(me, p)
	local a, b = Num(p.a, me), Num(p.target, -1)
	local ok1 = Call(Players[a]:GetDiplomacy(), "SetHasMet", b)
	local ok2 = Call(Players[b]:GetDiplomacy(), "SetHasMet", a)
	Log("meet", PlayerName(a) .. " <-> " .. PlayerName(b) .. " ok=" .. tostring(ok1 and ok2))
end

CMD.war = function(me, p)
	local a, b = Num(p.a, me), Num(p.target, -1)
	local ok, err = pcall(function() Players[a]:GetDiplomacy():DeclareWarOn(b, WarTypes.FORMAL_WAR, true) end)
	local okW, w = Call(Players[a]:GetDiplomacy(), "IsAtWarWith", b)
	Log("war", PlayerName(a) .. " -> " .. PlayerName(b) .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
		" IsAtWarWith=" .. (okW and Str(w) or "err"))
end

-- peace: PLAN 5.0 "NEW-VERIFY: no evidenced peace API; make peace manually via
-- the diplomacy screen". Reports the war state and what to do.
CMD.peace = function(me, p)
	local a, b = Num(p.a, me), Num(p.target, -1)
	local okW, w = Call(Players[a]:GetDiplomacy(), "IsAtWarWith", b)
	Log("peace", PlayerName(a) .. " / " .. PlayerName(b) .. " IsAtWarWith=" .. (okW and Str(w) or "err") ..
		((okW and w) and " -> no scripted peace API: make peace manually in the diplomacy screen" or " (already at peace)"))
end

CMD.diplo = function(me, p)
	local ids = EFV_SortedAlivePlayers and EFV_SortedAlivePlayers() or {}
	if #ids == 0 then
		for i = 0, 63 do
			local pl = Players[i]
			if pl ~= nil and pl:IsAlive() then ids[#ids + 1] = i end
		end
	end
	Log("diplo", "per pair a->b: W=war A=allied F=friend O=a has open borders from b M=met T=team")
	for _, a in ipairs(ids) do
		local d = Players[a]:GetDiplomacy()
		local cells = {}
		for _, b in ipairs(ids) do
			if a ~= b then
				local f = ""
				local ok1, w = Call(d, "IsAtWarWith", b); if ok1 and w then f = f .. "W" end
				local ok2, al = Call(d, "HasAllied", b); if ok2 and al then f = f .. "A" end
				local ok3, fr = Call(d, "HasDeclaredFriendship", b); if ok3 and fr then f = f .. "F" end
				-- HasOpenBordersFrom is nil in gameplay (Session A T09): use EFV's
				-- gameplay reader (open-borders deal scan, pending T19).
				local ok4, ob = pcall(EFV_HasOpenBordersFrom, a, b); if ok4 and ob then f = f .. "O" end
				local ok5, m = Call(d, "HasMet", b); if ok5 and m then f = f .. "M" end
				if Players[a]:GetTeam() == Players[b]:GetTeam() then f = f .. "T" end
				if f ~= "" then cells[#cells + 1] = b .. ":" .. f end
			end
		end
		Log("diplo", PlayerName(a) .. " -> " .. table.concat(cells, " "))
	end
end

-- ---------------------------------------------------------------------------
-- EFV record commands (EFV_Records public API, INTERFACES 3.4)
-- ---------------------------------------------------------------------------
CMD.dump = function(me, p)
	EFV_Records.Dump(EFV_Records.Load())
	Log("dump", "done (see [Dump] lines)")
end

CMD.records = function(me, p)
	local store = EFV_Records.Load()
	local ids = EFV_Records.IDs(store)
	Log("records", #ids .. " record(s) nextID=" .. Str(store.nextID) .. " lastTurn=" .. Str(store.lastTurn) ..
		" rev=" .. Str(store.rev) .. " pending=" .. Str(store.pending and #store.pending))
	for _, id in ipairs(ids) do
		Log("records", RecordLine(EFV_Records.Get(store, id)))
	end
end

-- shift: move record R's clock back by N turns (amount, default 1):
-- DEPLOYED/GRACE/MUTINY -> deployedTurn - N; OUTBOUND/RETURNING -> arrivalTurn - N.
-- R = extra rec=<id>, else the selected unit's record, else the only record.
CMD.shift = function(me, p)
	local store = EFV_Records.Load()
	local rec = ResolveRecord(store, p)
	if rec == nil then Log("shift", "no record (select a tracked unit or set rec=<id>)"); return end
	local n = Num(p.amount, 1)
	if rec.state == "OUTBOUND" or rec.state == "RETURNING" then
		rec.arrivalTurn = (rec.arrivalTurn or Turn()) - n
	else
		rec.deployedTurn = (rec.deployedTurn or Turn()) - n
	end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	Log("shift", "by " .. n .. " -> " .. RecordLine(rec))
end

-- expire: make the selected record expire at the next turn start
-- (deployedTurn = turn + 1 - durationTurns; Expeditionary / CS only).
CMD.expire = function(me, p)
	local store = EFV_Records.Load()
	local rec = ResolveRecord(store, p)
	if rec == nil then Log("expire", "no record"); return end
	if rec.durationTurns == nil then Log("expire", "record " .. rec.id .. " has no duration (Volunteer)"); return end
	rec.deployedTurn = Turn() + 1 - rec.durationTurns
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	Log("expire", RecordLine(rec))
end

-- setfield: rec=<id> field=<name> value=<number|string|nil> (direct poke; use with care).
local NUMERIC = { graceTurnsLeft = true, deployedTurn = true, arrivalTurn = true, lastDamage = true,
	lapsed = true, spawnFailCount = true, durationTurns = true, lastCombatTurn = true, damage = true,
	experience = true, lapseTurn = true }
CMD.setfield = function(me, p)
	local store = EFV_Records.Load()
	local rec = ResolveRecord(store, p)
	local field = p.field
	if rec == nil or type(field) ~= "string" or field == "id" then Log("setfield", "need rec and field"); return end
	local v = p.value
	if v == "nil" then v = nil elseif NUMERIC[field] then v = tonumber(v) end
	rec[field] = v
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	Log("setfield", field .. "=" .. Str(v) .. " -> " .. RecordLine(rec))
end

CMD.state = function(me, p)
	local P = EFV_Config.PROP
	local parts = {}
	for _, k in ipairs({ "INIT", "SCHEMA", "NEXT_ID", "LAST_TURN", "REV" }) do
		parts[#parts + 1] = P[k] .. "=" .. Str(Game:GetProperty(P[k]))
	end
	Log("state", table.concat(parts, " "))
end

-- ===========================================================================
-- Final acceptance session (EFV_Dev 0.6.0-dev.1, from a brand-new game since
-- 0.6.1-dev.1; EFV/TESTING_FINAL.md)
-- One-click scenarios (panel section "Final session", cmd "scn_*") that build
-- each situation with the helpers above and EFV's public EFV_Records /
-- EFV_Units API, and checks that print one line each:
--   [EFV][CHECK] <ID> <PASS|CHECK|INFO> T<turn> <detail>
-- tools/summarize_efv_log.py turns these lines into the step list.
-- Checks run at the requesting human's GameEvents.PlayerTurnStartComplete
-- (after EFV's turn pipeline; EFV registers its handlers first) and on the
-- "Check now" button. Scenario state: Game property EFV_DEV_SCN (numbers,
-- strings and tables; empty strings and tables do not survive the property
-- round trip, Session B, so every sub-table is re-created on use).
-- Units held in place for the pipeline: FinishMoves now plus an EFV pending
-- exhaust entry (EFV_Records.AddPending), so EFV repeats FinishMoves at the
-- owner's PlayerTurnStartComplete of this turn (Session B T06) and the AI
-- cannot walk the unit away before the next turn start.
-- ===========================================================================
do
local SCN_PROP = "EFV_DEV_SCN"
local FT_EXP, FT_VOL, FT_CS = EFV_Config.FT_EXP, EFV_Config.FT_VOL, EFV_Config.FT_CS
local ST = { OUT = EFV_Config.ST_OUTBOUND, DEP = EFV_Config.ST_DEPLOYED, GRACE = EFV_Config.ST_GRACE,
	MUT = EFV_Config.ST_MUTINY, RET = EFV_Config.ST_RETURNING }

local function Has(t, v)
	for _, x in ipairs(t or {}) do if x == v then return true end end
	return false
end

local function Check(id, verdict, msg)
	print("[EFV][CHECK] " .. Str(id) .. " " .. Str(verdict) .. " T" .. Str(Turn()) .. " " .. Str(msg))
end

local function ScnLoad()
	local ok, st = pcall(function() return Game:GetProperty(SCN_PROP) end)
	if ok and type(st) == "table" then return st end
	return { v = 1 }
end

local function ScnSave(st)
	local ok, err = pcall(function() Game:SetProperty(SCN_PROP, st) end)
	if not ok then Log("scn", "SetProperty " .. SCN_PROP .. " failed: " .. Str(err)) end
end

local function Sub(st, key)
	if type(st[key]) ~= "table" then st[key] = {} end
	return st[key]
end

local function Alive(pid)
	local ok, a = pcall(function() return Players[pid] ~= nil and Players[pid]:IsAlive() end)
	return ok and a == true
end

local function Diplo(a, method, b)
	local ok, v = Call(Players[a]:GetDiplomacy(), method, b)
	return ok and v == true
end

local function AtWar(a, b) return Diplo(a, "IsAtWarWith", b) end

-- a declares formal war on b; if that does not take (e.g. a city-state as
-- the declarer), b declares on a (the war state is the same both ways).
local function DeclareWar(a, b)
	if a == nil or b == nil or AtWar(a, b) then return end
	local ok, err = pcall(function() Players[a]:GetDiplomacy():DeclareWarOn(b, WarTypes.FORMAL_WAR, true) end)
	Log("scn", PlayerName(a) .. " declares war on " .. PlayerName(b) .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	if not AtWar(a, b) then
		local ok2, err2 = pcall(function() Players[b]:GetDiplomacy():DeclareWarOn(a, WarTypes.FORMAL_WAR, true) end)
		Log("scn", PlayerName(b) .. " declares war on " .. PlayerName(a) .. " (fallback) ok=" .. tostring(ok2) ..
			(ok2 and "" or (" err=" .. Str(err2))) .. " at war=" .. tostring(AtWar(a, b)))
	end
end

local function MeetPair(a, b)
	Call(Players[a]:GetDiplomacy(), "SetHasMet", b)
	Call(Players[b]:GetDiplomacy(), "SetHasMet", a)
end

local function SortedIDs(pred)
	local out = {}
	for i = 0, 63 do
		if Alive(i) then
			local ok, yes = pcall(pred, i)
			if ok and yes then out[#out + 1] = i end
		end
	end
	return out
end

local function IsMajorID(pid)
	local ok, m = pcall(function() return Players[pid]:IsMajor() end)
	return ok and m == true
end

local function IsCityStateID(pid)
	local ok, k = pcall(EFV_PlayerKind, pid)
	return ok and k == "CITY_STATE"
end

local function BarbarianID()
	for i = 63, 0, -1 do
		local ok, b = pcall(function() return Players[i] ~= nil and Players[i]:IsBarbarian() end)
		if ok and b then return i end
	end
	return nil
end

local function Capital(pid)
	local c = nil
	pcall(function() c = Players[pid]:GetCities():GetCapitalCity() end)
	if c ~= nil then return c end
	pcall(function()
		for _, city in Players[pid]:GetCities():Members() do
			if c == nil or city:GetID() < c:GetID() then c = city end
		end
	end)
	return c
end

local function Cities(pid)
	local out = {}
	pcall(function()
		for _, city in Players[pid]:GetCities():Members() do out[#out + 1] = city end
	end)
	table.sort(out, function(a, b) return a:GetID() < b:GetID() end)
	return out
end

local function Dist(x1, y1, x2, y2)
	local ok, d = pcall(function() return Map.GetPlotDistance(x1, y1, x2, y2) end)
	if ok and type(d) == "number" then return d end
	return 999
end

-- Plots at exactly distance ring from (x, y), sorted by index (deterministic).
local function Ring(x, y, ring)
	local out = {}
	if ring == 0 then
		local p = Map.GetPlot(x, y)
		if p ~= nil then out[1] = p end
		return out
	end
	local ok, plots = pcall(function() return Map.GetNeighborPlots(x, y, ring) end)
	if ok and plots ~= nil then
		for _, p in ipairs(plots) do
			if Dist(x, y, p:GetX(), p:GetY()) == ring then out[#out + 1] = p end
		end
	end
	table.sort(out, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return out
end

local function PlotOwner(plot)
	local ok, o = pcall(function() return plot:GetOwner() end)
	if ok and type(o) == "number" then return o end
	return -1
end

local function NotWonder(plot)
	local ok, w = pcall(function() return plot:IsNaturalWonder() end)
	return not (ok and w == true)
end

-- First free land plot (FreeLand) within maxRing of (x, y) passing test(plot).
local function FindPlot(x, y, maxRing, test, minRing)
	for ring = minRing or 0, maxRing do
		for _, p in ipairs(Ring(x, y, ring)) do
			if FreeLand(p) and NotWonder(p) and (test == nil or test(p)) then return p end
		end
	end
	return nil
end

local function OwnedBy(owner) return function(p) return PlotOwner(p) == owner end end
-- Plots whose owner is one of the listed players (-1 = unowned): a unit
-- created there is not refused by closed borders (Session D 3).
local function OwnedByAny(list) return function(p) return Has(list, PlotOwner(p)) end end
local function Neutral(p) return PlotOwner(p) < 0 end

local function Place(u, plot)
	local ok, err = pcall(function() UnitManager.PlaceUnit(u, plot:GetX(), plot:GetY()) end)
	Log("scn", "place " .. Str(u:GetOwner()) .. "/" .. Str(u:GetID()) .. " at " .. plot:GetX() .. "," .. plot:GetY() ..
		" ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	return ok
end

-- Keeps u where it is until the next turn start (see the header).
local function Hold(store, u)
	pcall(function() UnitManager.FinishMoves(u) end)
	pcall(function() EFV_Records.AddPending(store, u:GetOwner(), u:GetID(), Turn()) end)
end

local function RecUnit(rec)
	local ok, u = pcall(function() return EFV_Units.GetForRecord(rec) end)
	if ok then return u end
	return nil
end

local function UnitDamage(u)
	local ok, d = pcall(function() return u:GetDamage() end)
	if ok and type(d) == "number" then return d end
	return -1
end

-- Newest record (highest ID) matching pred.
local function Newest(store, pred)
	local ids = EFV_Records.IDs(store)
	for i = #ids, 1, -1 do
		local rec = EFV_Records.Get(store, ids[i])
		if rec ~= nil and pred(rec) then return rec end
	end
	return nil
end

-- A record for a unit that is (or was) on the map, built like EFV_Transit's
-- send (fields) and arrival (onMap*, deployedTurn); snapshot from u.
local function MakeRecord(store, u, f)
	local turn = Turn()
	local fields = {
		forceType = f.force, state = f.state or ST.DEP, senderID = f.sender, recipientID = f.recipient,
		accessBasis = f.basis, originCityID = f.origin:GetID(), originX = f.origin:GetX(), originY = f.origin:GetY(),
		destCityID = f.dest:GetID(), destX = f.dest:GetX(), destY = f.dest:GetY(), rerouted = 0,
		destNameKey = (function() local ok, n = pcall(function() return f.dest:GetName() end); return ok and n or nil end)(),
		sentTurn = turn - 1, arrivalTurn = turn, transitTurns = 1, band = 1,
		distance = Dist(f.origin:GetX(), f.origin:GetY(), f.dest:GetX(), f.dest:GetY()),
		durationTurns = f.duration, lapsed = 0, spawnFailCount = 0, feePaid = 0, maintGoldPaid = 0,
	}
	local rec = EFV_Records.New(store, fields)
	if rec == nil then return nil end
	local snap = EFV_Units.Snapshot(u)
	if snap ~= nil then EFV_Units.ApplySnapshot(rec, snap, turn) end
	if fields.state == ST.OUT then
		-- VEF transit cancel (2026-09-30): the tile the unit leaves from.
		rec.sentX, rec.sentY = u:GetX(), u:GetY()
	else
		rec.deployedTurn = f.deployedTurn or turn
		rec.onMapPlayerID = u:GetOwner()
		rec.onMapUnitID = u:GetID()
		rec.lastX, rec.lastY = u:GetX(), u:GetY()
	end
	EFV_Records.Touch(store)
	return rec
end

local function Focus(st, x, y, o, uid, stamp)
	st.focus = { x = x, y = y, o = o or -1, u = uid or -1, stamp = stamp or 0 }
end

local function NewUnit(cmd, owner, unitType, plot, name)
	if plot == nil then return nil end
	local u = CreateUnit(cmd, owner, unitType, plot:GetX(), plot:GetY())
	if u ~= nil and name ~= nil then
		pcall(function() u:GetExperience():SetVeteranName(name) end)
	end
	return u
end

-- The session's players (S0). Returns st or nil (a CHECK line is written).
local function Session(id, me)
	local st = ScnLoad()
	if st.me == nil or st.ally == nil then
		Check(id, "CHECK", "press S0 Setup session first")
		return nil
	end
	if st.me ~= me then
		Check(id, "CHECK", "S0 was run by player " .. Str(st.me) .. ", not by " .. Str(me))
		return nil
	end
	-- The AI may make peace with C after the 10-turn minimum war (Session F
	-- T27): renew the common war S0 set up (no-op while it lasts). The
	-- city-state needs none since VEF 1.0.2.
	if st.enemy ~= nil and Alive(st.enemy) then
		for _, pid in ipairs({ me, st.ally }) do
			if pid ~= nil and Alive(pid) then DeclareWar(pid, st.enemy) end
		end
	end
	return st
end

-- ---------------------------------------------------------------------------
-- Fresh-game helpers (EFV_Dev 0.6.1-dev.1). The final session starts from a
-- BRAND-NEW game (a save locks its mod set: an old save brings back whatever
-- mods it was made with), so S0 builds everything a new game lacks. All
-- calls are pcall-guarded; evidence (gameplay scripts or the GameCore tuner):
--   meet    Diplomacy:SetHasMet(p): AlexanderScenario.lua:13-15,
--           ColdWarScenario_StartScript.lua:36 (MeetPair above)
--   reveal  PlayersVisibility[p]:ChangeVisibilityCount(plotIndex, 1):
--           AlexanderScenario.lua:59, AustraliaScenario.lua:1273 (gameplay),
--           Debug/Map.ltp "Reveal All". Fallback when the city still is not
--           revealed: a Scout of yours next to it (its sight reveals it).
--   civic   Players[p]:GetCulture():SetCivic(idx, true):
--           IndonesiaKhmerScenario.lua:19/31 (CIVIC_EARLY_EMPIRE),
--           VikingScenario.lua:38. Open borders need Early Empire
--           (DiplomaticActions.InitiatorPrereqCivic).
--   deal    DealManager working deal, AGREEMENTS / OPEN_BORDERS with
--           SetDuration (Debug/Diplomacy.ltp:115-127 pattern; Session C: no
--           deal without SetDuration; Session F T27 PASS, F:L1080-L1082).
--   tech    Players[p]:GetTechs():SetTech(idx, true) (S5): AustraliaScenario.lua:1368.
--   city HP CityManager.GetDistrictAt(x, y) (BlackDeathScenario.lua:437),
--           district:SetDamage(DefenseTypes.DISTRICT_GARRISON / DISTRICT_OUTER, v)
--           and GetMaxDamage (PiratesScenario_StartScript.lua:1342-1369).
--   city    Players[p]:GetCities():Create(x, y): AustraliaScenario.lua:1163, 1346.
--   moves   UnitManager.RestoreMovementToFormation(u) (only if a created
--           unit lacks moves): BlackDeathScenario_UnitCommands.lua:281.
-- Partner basis: declared friendship (SetHasDeclaredFriendship works at once
-- both ways, Session F T27) plus open borders granted by B (scripted deal)
-- = EFV's FRIEND basis (Expeditionary, Entrust) and FRIEND_OB (Volunteers).
-- No alliance: at turn 1 nobody has Civil Service, and SetHasAllied(false) is
-- a no-op in game (T27), so S4 could never end one. SetHasAllied(true) is the
-- last resort only, when friendship + open borders give no Volunteer basis.
-- ---------------------------------------------------------------------------
local REVEAL_RADIUS = 3
local OB_TURNS = 30
local CIVIC_OB = "CIVIC_EARLY_EMPIRE"

local function HasCity(pid) return #Cities(pid) > 0 end

-- true / false, or nil when IsRevealed cannot be read (EFV then skips its
-- NOT_REVEALED check too, EFV_Rules IsRevealedTo).
local function RevealedTo(pid, x, y)
	local ok, v = pcall(function() return PlayersVisibility[pid]:IsRevealed(x, y) end)
	if ok and v ~= nil then return v == true end
	return nil
end

-- Reveals the plots within radius (default REVEAL_RADIUS) of city to pid
-- (the city tile included); a Scout of pid next to the city if that did not
-- work. owners: plot owners a Scout may be created on (nil: no Scout).
-- city may also be a plot (GetX / GetY / GetOwner), e.g. a Shot's scene.
-- Returns revealed, scout.
local function RevealCity(pid, city, owners, radius)
	local x, y = city:GetX(), city:GetY()
	local n, err = 0, nil
	for ring = 0, (radius or REVEAL_RADIUS) do
		for _, plot in ipairs(Ring(x, y, ring)) do
			local ok, e = pcall(function() PlayersVisibility[pid]:ChangeVisibilityCount(plot:GetIndex(), 1) end)
			if ok then n = n + 1 else err = e end
		end
	end
	local r = RevealedTo(pid, x, y)
	local scout = false
	if r == false and owners ~= nil then
		scout = NewUnit("reveal", pid, "UNIT_SCOUT", FindPlot(x, y, 2, OwnedByAny(owners), 1), "VEF-SCOUT") ~= nil
		r = RevealedTo(pid, x, y)
	end
	Log("reveal", PlayerName(city:GetOwner()) .. " city at " .. x .. "," .. y .. ": " .. n .. " plots for " .. PlayerName(pid) ..
		", revealed=" .. Str(r) .. (err and (" err=" .. Str(err)) or "") .. (scout and " (Scout placed)" or ""))
	return r, scout
end

local function GrantCivic(pid, civicType)
	local ok, err = pcall(function() Players[pid]:GetCulture():SetCivic(GameInfo.Civics[civicType].Index, true) end)
	Log("civic", PlayerName(pid) .. " " .. civicType .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
	return ok
end

-- grantor gives receiver open borders (one-way scripted deal). Returns true
-- when EFV's own gameplay reader (deal scan) sees it afterwards.
local function GrantOpenBorders(grantor, receiver)
	if EFV_HasOpenBordersFrom(receiver, grantor) then return true end
	local ok, err = pcall(function()
		DealManager.ClearWorkingDeal(DealDirection.OUTGOING, grantor, receiver)
		local pDeal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, grantor, receiver)
		if pDeal == nil then error("GetWorkingDeal returned nil") end
		local item = pDeal:AddItemOfType(DealItemTypes.AGREEMENTS, grantor)
		if item == nil then error("AddItemOfType returned nil") end
		item:SetSubType(DealAgreementTypes.OPEN_BORDERS)
		item:SetDuration(OB_TURNS)
		item:SetLocked(true)
		pDeal:Validate()
		DealManager.EnactWorkingDeal(grantor, receiver)
	end)
	local has = EFV_HasOpenBordersFrom(receiver, grantor)
	Log("ob", PlayerName(grantor) .. " grants " .. PlayerName(receiver) .. " open borders (" .. OB_TURNS .. " turns): enact ok=" ..
		tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. ", seen by VEF=" .. tostring(has))
	return has
end

-- Friendship + open borders from B (see the header); alliance flag only as
-- the last resort. Returns the Expeditionary and the Volunteer basis.
local function EnsurePartner(cmd, me, B)
	if EFV_PartnerBasis(me, B) == nil then SetDiploPair(cmd, me, B, "SetHasDeclaredFriendship", true) end
	GrantCivic(B, CIVIC_OB)
	GrantCivic(me, CIVIC_OB)
	GrantOpenBorders(B, me)
	if EFV_VolunteerBasis(me, B) == nil then
		Log(cmd, "friendship + open borders give no Volunteer basis: trying the alliance flag")
		SetDiploPair(cmd, me, B, "SetHasAllied", true)
	end
	return EFV_PartnerBasis(me, B), EFV_VolunteerBasis(me, B)
end

-- A unit created by script should have its full moves (Send needs them).
local function FullMoves(u)
	local function Full()
		local ok, f = pcall(function() return u:GetMovesRemaining() >= u:GetMaxMoves() end)
		return ok and f == true
	end
	if Full() then return true end
	pcall(function() UnitManager.RestoreMovementToFormation(u) end)
	return Full()
end

-- Walls down and the city centre at 1 HP: one attack takes the city.
local function WeakenCity(city)
	local ok, msg = pcall(function()
		local d = CityManager.GetDistrictAt(city:GetX(), city:GetY())
		if d == nil then error("no district at the city centre") end
		local G, O = DefenseTypes.DISTRICT_GARRISON, DefenseTypes.DISTRICT_OUTER
		local oMax = tonumber(d:GetMaxDamage(O)) or 0
		if oMax > 0 then d:SetDamage(O, oMax) end
		local gMax = tonumber(d:GetMaxDamage(G)) or 0
		if gMax > 1 then d:SetDamage(G, gMax - 1) end
		return "city HP " .. (gMax - (tonumber(d:GetDamage(G)) or 0)) .. "/" .. gMax .. ", walls " ..
			(oMax - (tonumber(d:GetDamage(O)) or 0)) .. "/" .. oMax
	end)
	Log("weaken", "city at " .. city:GetX() .. "," .. city:GetY() .. ": " .. (ok and Str(msg) or ("failed: " .. Str(msg))))
	return ok, ok and msg or "city not weakened"
end

local function FarFromCities(plot, minDist)
	for i = 0, 63 do
		if Alive(i) then
			for _, c in ipairs(Cities(i)) do
				if Dist(plot:GetX(), plot:GetY(), c:GetX(), c:GetY()) < minDist then return false end
			end
		end
	end
	return true
end

-- A new small city for pid on free neutral land 5-10 tiles from (x, y).
local function FoundCityFor(pid, x, y)
	local plot = FindPlot(x, y, 10, function(q) return Neutral(q) and FarFromCities(q, 4) end, 5)
	if plot == nil then return nil, "no free neutral land 5-10 tiles from your capital for a new city" end
	local ok, err = pcall(function() Players[pid]:GetCities():Create(plot:GetX(), plot:GetY()) end)
	local c = CityManager.GetCityAt(plot:GetX(), plot:GetY())
	if c == nil or c:GetOwner() ~= pid then
		return nil, "founding a city failed (ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) .. ")"
	end
	return c, "new city founded for " .. PlayerName(pid)
end

local EV = {}   -- turn checks and event handlers of the sections below, for Evaluate (see the do-block note at the top)
-- ---------------------------------------------------------------------------
-- S0 Setup, from a brand-new game (after your first End Turn, when every civ
-- has a city). B, F, C = the three lowest-ID other majors with a city, CS =
-- the lowest-ID city-state with a city. S0: you meet them (and they meet
-- each other); the land around their cities is revealed to you; you, B and
-- F declare war on C (the city-state stays at peace: since VEF 1.0.2 a
-- City-State send needs no shared enemy); B becomes your declared friend and
-- grants you open borders (Early Empire granted to both for the deal); F
-- becomes your friend; 2000 gold, 10 Iron and three Swordsmen with full
-- moves next to your capital. The check line asks VEF's own send rule
-- (EFV_EvaluateSend) what the destination picker will say for B's capital
-- (Expeditionary, Volunteers) and the city-state (City-State unit).
-- ---------------------------------------------------------------------------
CMD.scn_setup = function(me, p)
	local cap = Capital(me)
	if cap == nil then
		Check("SETUP", "CHECK", "you have no city yet: found your capital with the Settler, End Turn once, then press S0 again")
		return
	end
	local majors = SortedIDs(function(i) return i ~= me and IsMajorID(i) and HasCity(i) end)
	local css = SortedIDs(function(i) return IsCityStateID(i) and HasCity(i) end)
	if #majors < 3 or #css < 1 then
		Check("SETUP", "CHECK", "needs 3 other civs and 1 city-state with a city, found " .. #majors .. " and " .. #css ..
			": End Turn once more (the AI founds its capitals on its first turns), then press S0 again")
		return
	end
	local B, F, C, cs = majors[1], majors[2], majors[3], css[1]
	local st = ScnLoad()
	st.me, st.ally, st.friend, st.enemy, st.cs = me, B, F, C, cs
	-- 1. meet (every pair of the five: the war declarations need it too)
	local group = { me, B, F, C, cs }
	for i = 1, #group do
		for j = i + 1, #group do MeetPair(group[i], group[j]) end
	end
	local met = Diplo(me, "HasMet", B) and Diplo(me, "HasMet", F) and Diplo(me, "HasMet", C) and Diplo(me, "HasMet", cs)
	-- 2. wars on C, then the partners
	local peaceIssue = AtWar(me, B) or AtWar(me, F)
	DeclareWar(me, C); DeclareWar(B, C); DeclareWar(F, C)
	local partner, vol = EnsurePartner("scn_setup", me, B)
	st.partner, st.basis = partner, vol
	if EFV_PartnerBasis(me, F) == nil then SetDiploPair("scn_setup", me, F, "SetHasDeclaredFriendship", true) end
	-- 3. reveal the cities of B, C and the city-state (destinations; a Scout
	-- may stand on neutral, your, B's (open borders), the city-state's or C's
	-- land) and F's (not a destination: no Scout, not part of the check)
	local revealed, scouts = true, 0
	for _, pid in ipairs({ B, F, C, cs }) do
		for _, city in ipairs(Cities(pid)) do
			local r, sc = RevealCity(me, city, (pid ~= F) and { -1, me, B, cs, C } or nil)
			if r == false and pid ~= F then revealed = false end
			if sc then scouts = scouts + 1 end
		end
	end
	-- 4. gold, Iron, three Swordsmen with full moves
	pcall(function() Players[me]:GetTreasury():ChangeGoldBalance(2000) end)
	pcall(function() Players[me]:GetResources():ChangeResourceAmount(GameInfo.Resources["RESOURCE_IRON"].Index, 10) end)
	local swords, full = {}, 0
	st.setupUnits = {}
	for _ = 1, 3 do
		local plot = FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1) or FindPlot(cap:GetX(), cap:GetY(), 4, OwnedByAny({ -1, me }), 1)
		local u = NewUnit("scn_setup", me, "UNIT_SWORDSMAN", plot)
		if u ~= nil then
			swords[#swords + 1] = u
			st.setupUnits[#st.setupUnits + 1] = { o = me, u = u:GetID(), ut = "UNIT_SWORDSMAN" }
			if FullMoves(u) then full = full + 1 end
		end
	end
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	-- 5. what the destination picker will say (VEF's own rule)
	local store = EFV_Records.Load()
	local function Eval(r, ft)
		local city = Capital(r)
		if swords[1] == nil or city == nil then return "no unit or city" end
		local okC, ok, reasons = pcall(EFV_EvaluateSend, me, swords[1], r, city, ft, store)
		if not okC then return "error " .. Str(ok) end
		if ok then return "ok" end
		return table.concat(reasons or {}, "+")
	end
	local eExp, eVol, eCs = Eval(B, FT_EXP), Eval(B, FT_VOL), Eval(cs, FT_CS)
	local wars = AtWar(me, C) and AtWar(B, C) and AtWar(F, C)
	local csWar = AtWar(me, cs)
	local ok = met and revealed and wars and not csWar and partner ~= nil and vol ~= nil and #swords == 3 and full == 3 and
		eExp == "ok" and eVol == "ok" and eCs == "ok" and not peaceIssue
	Check("SETUP", ok and "PASS" or "CHECK", "B=" .. PlayerName(B) .. " (basis " .. Str(partner) .. ", Volunteers " .. Str(vol) ..
		"), F=" .. PlayerName(F) .. ", enemy C=" .. PlayerName(C) .. ", city-state=" .. PlayerName(cs) .. "; met=" .. tostring(met) ..
		", cities revealed=" .. tostring(revealed) .. (scouts > 0 and (" (" .. scouts .. " Scout(s))") or "") ..
		", you, B and F at war with C=" .. tostring(wars) .. ", city-state at war with C=" .. tostring(AtWar(cs, C)) ..
		" (not needed since VEF 1.0.2)" .. (csWar and ", YOU ARE AT WAR WITH THE CITY-STATE" or "") .. ", Swordsmen=" .. #swords .. " (full moves " .. full .. ")" ..
		"; picker: Expeditionary " .. eExp .. ", Volunteers " .. eVol .. ", City-State " .. eCs ..
		(peaceIssue and "; YOU ARE AT WAR WITH B OR F: start a new game" or ""))
end

-- ---------------------------------------------------------------------------
-- Watches (return home) and arrivals, used by several steps.
-- ---------------------------------------------------------------------------
local Watch, PlacementProblem
do
function Watch(st, rec)
	local w = Sub(st, "watch")
	local key = "r" .. rec.id
	if w[key] == nil then
		w[key] = { t = rec.unitType, rx = rec.returnX, ry = rec.returnY, dmg = tonumber(rec.damage) or 0,
			why = rec.returnReason, o = rec.senderID, f = rec.forceType }
	end
	if rec.returnReason == "RECALL" then
		local seen = Sub(st, "seen")
		if seen["c" .. rec.id] == nil then
			seen["c" .. rec.id] = 1
			Check("RECALL", "PASS", "Volunteer record " .. rec.id .. " recalled (" .. Str(rec.unitType) .. ")")
		end
	end
end

function EV.Observe(st, store, me)
	-- the S17 tracker records never come home (removed at the end of the turn)
	local labels = type(st.s17) == "table" and st.s17.ids or {}
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.senderID == me and rec.state == ST.RET and not Has(labels, id) then Watch(st, rec) end
	end
end

-- S1: every record you sent (or that is coming home) arrives next turn.
CMD.scn_arrive = function(me, p)
	local st = Session("FAST_TRAVEL", me)
	if st == nil then return end
	local store = EFV_Records.Load()
	local t, n = Turn(), 0
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.senderID == me and (rec.state == ST.OUT or rec.state == ST.RET) then
			if rec.state == ST.RET then Watch(st, rec) end
			if (tonumber(rec.arrivalTurn) or t + 1) > t + 1 then rec.arrivalTurn = t + 1 end
			n = n + 1
		end
	end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	ScnSave(st)
	Check("FAST_TRAVEL", "INFO", n .. " unit(s) in transit arrive at the next turn start")
end

-- Spawn-rule check of one on-map unit placed by EFV (spec 8): at most
-- SPAWN_SEARCH_MAX_RING from the city, not another player's city centre,
-- and a plot the new owner may enter (EFV_SpawnValid rule 5b).
function PlacementProblem(u, cx, cy)
	local x, y = u:GetX(), u:GetY()
	local plot = Map.GetPlot(x, y)
	local owner = u:GetOwner()
	local ring = Dist(cx, cy, x, y)
	local why = {}
	if ring > (EFV_Config.SPAWN_SEARCH_MAX_RING or 5) then why[#why + 1] = "ring " .. ring .. " > 5" end
	local cityAt = CityManager.GetCityAt(x, y)
	if cityAt ~= nil and cityAt:GetOwner() ~= owner then why[#why + 1] = "on a city centre of " .. PlayerName(cityAt:GetOwner()) end
	local po = PlotOwner(plot)
	if po >= 0 and po ~= owner and not IsCityStateID(po) then
		local team = false
		pcall(function() team = Players[po]:GetTeam() == Players[owner]:GetTeam() end)
		local open = team or Diplo(owner, "HasAllied", po)
		if not open then
			local okO, ob = pcall(EFV_HasOpenBordersFrom, owner, po)
			open = okO and ob == true
		end
		if AtWar(owner, po) then why[#why + 1] = "on land of " .. PlayerName(po) .. " (at war)"
		elseif not open then why[#why + 1] = "on closed-border land of " .. PlayerName(po) end
	end
	return why, ring, po
end

function EV.CheckArrivals(st, store, t)
	local seen = Sub(st, "seen")
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.deployedTurn == t and rec.state == ST.DEP and seen["a" .. id] == nil then
			seen["a" .. id] = 1
			local u = RecUnit(rec)
			if u == nil then
				Check("ARRIVE", "CHECK", "record " .. id .. " arrived but its unit is not found")
			else
				local why, ring, po = PlacementProblem(u, rec.destX, rec.destY)
				local wantOwner = rec.recipientID
				if rec.forceType == FT_VOL then wantOwner = rec.senderID end
				if u:GetOwner() ~= wantOwner then why[#why + 1] = "owner " .. u:GetOwner() .. " (expected " .. wantOwner .. ")" end
				Check("ARRIVE", #why == 0 and "PASS" or "CHECK", "record " .. id .. " " .. Str(rec.forceType) .. " " ..
					Str(rec.unitType) .. " owner=" .. PlayerName(u:GetOwner()) .. " ring=" .. ring .. " plot=" .. u:GetX() .. "," ..
					u:GetY() .. " plotOwner=" .. po .. (#why > 0 and (" PROBLEM: " .. table.concat(why, "; ")) or ""))
			end
		end
	end
end

function EV.CheckHome(st, store, t)
	local w = Sub(st, "watch")
	for _, k in ipairs(EFV_SortedKeys(w)) do
		local e = w[k]
		local id = tonumber(string.sub(k, 2))
		local rec = id and EFV_Records.Get(store, id)
		if rec == nil then
			w[k] = nil
			local best, bestD = nil, nil
			if e.o ~= nil and e.rx ~= nil and e.ry ~= nil then
				pcall(function()
					for _, u in Players[e.o]:GetUnits():Members() do
						local row = GameInfo.Units[u:GetType()]
						if row ~= nil and EFV_IsUpgradeOf(row.UnitType, e.t) and EFV_UnitGoneReason(u, e.o, u:GetID()) == nil then
							local d = Dist(e.rx, e.ry, u:GetX(), u:GetY())
							local score = d + ((UnitDamage(u) == e.dmg) and 0 or 100)
							if d <= 5 and (bestD == nil or score < bestD) then best, bestD = u, score end
						end
					end
				end)
			end
			if best == nil then
				Check("HOME", "CHECK", "record " .. Str(id) .. " (" .. Str(e.t) .. ", " .. Str(e.why) .. ") closed, but no such unit within 5 tiles of its return city")
			else
				local why, ring = PlacementProblem(best, e.rx, e.ry)
				local dmg = UnitDamage(best)
				if dmg ~= e.dmg then why[#why + 1] = "damage " .. dmg .. " (expected " .. e.dmg .. ")" end
				Check("HOME", #why == 0 and "PASS" or "CHECK", "record " .. Str(id) .. " " .. Str(e.f) .. " " .. Str(e.t) .. " home (" ..
					Str(e.why) .. ") ring=" .. ring .. " plot=" .. best:GetX() .. "," .. best:GetY() .. " damage=" .. dmg ..
					(#why > 0 and (" PROBLEM: " .. table.concat(why, "; ")) or ""))
			end
		end
	end
end
end -- Watches

-- ---------------------------------------------------------------------------
-- S2 (0.7): your newest deployed City-State unit ends its service next turn
-- OFF its host's land: it is moved onto free neutral land within 6 tiles
-- (else onto land owned by neither the city-state nor you). Designer ruling
-- "City-State units never mutiny": it must start home at once, wherever it
-- is, with no grace.
-- ---------------------------------------------------------------------------
do
CMD.scn_expire_cs = function(me, p)
	local st = Session("EXPIRE", me)
	if st == nil then return end
	local store = EFV_Records.Load()
	local rec = Newest(store, function(r) return r.forceType == FT_CS and r.senderID == me and r.state == ST.DEP end)
	if rec == nil then Check("EXPIRE", "CHECK", "no deployed City-State unit of yours (send one first)"); return end
	local u = RecUnit(rec)
	if u == nil then Check("EXPIRE", "CHECK", "record " .. rec.id .. ": unit not found"); return end
	local plot = FindPlot(u:GetX(), u:GetY(), 6, Neutral, 1)
	local where = "neutral land"
	if plot == nil then
		plot = FindPlot(u:GetX(), u:GetY(), 6, function(q)
			local o = PlotOwner(q)
			return o ~= rec.recipientID and o ~= me
		end, 1)
		where = "land owned by neither the city-state nor you"
	end
	if plot == nil then Check("EXPIRE", "CHECK", "no free land off the city-state's territory within 6 tiles of the unit"); return end
	Place(u, plot)
	Hold(store, u)
	rec.deployedTurn = Turn() + 1 - (tonumber(rec.durationTurns) or EFV_Config.CS_EXPEDITIONARY_DURATION)
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.s2 = { id = rec.id, turn = Turn(), x = u:GetX(), y = u:GetY(), where = where }
	Focus(st, u:GetX(), u:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("EXPIRE", "INFO", "record " .. rec.id .. " stands on " .. where .. " at " .. u:GetX() .. "," .. u:GetY() ..
		" and its service ends at the next turn start")
end

function EV.EvalS2(st, store, t)
	local s = st.s2
	if type(s) ~= "table" or t <= s.turn then return end
	st.s2 = nil
	local rec = EFV_Records.Get(store, s.id)
	local at = Str(s.where or "the unit's tile") .. " at " .. Str(s.x) .. "," .. Str(s.y)
	if rec ~= nil and rec.state == ST.RET and rec.returnReason == "EXPIRED" then
		Watch(st, rec)
		Check("EXPIRE", "PASS", "record " .. s.id .. " expired on " .. at .. " and is going home without grace (arrives turn " ..
			Str(rec.arrivalTurn) .. ")")
	elseif rec ~= nil and rec.state == ST.GRACE then
		Check("EXPIRE", "CHECK", "record " .. s.id .. " went into GRACE on " .. at .. ": the 0.7 City-State rule is missing")
	else
		Check("EXPIRE", "CHECK", "record " .. s.id .. " state=" .. Str(rec and rec.state) .. " reason=" .. Str(rec and rec.returnReason) ..
			" (expected RETURNING / EXPIRED)")
	end
end
end -- S2

-- ---------------------------------------------------------------------------
-- S3: grace and mutiny of your newest Expeditionary unit, one phase per press:
-- DEPLOYED -> moved to neutral land, expires next turn (GRACE, 5 turns);
-- GRACE -> 1 grace turn left (MUTINY next turn, 20 damage);
-- MUTINY -> moved into the host's land (it starts home next turn).
-- ---------------------------------------------------------------------------
do
CMD.scn_grace = function(me, p)
	local st = Session("GRACE", me)
	if st == nil then return end
	local store = EFV_Records.Load()
	local rec = Newest(store, function(r)
		return r.forceType == FT_EXP and r.senderID == me and (r.state == ST.DEP or r.state == ST.GRACE or r.state == ST.MUT)
	end)
	if rec == nil then Check("GRACE", "CHECK", "no deployed Expeditionary unit of yours (send one first)"); return end
	local u = RecUnit(rec)
	if u == nil then Check("GRACE", "CHECK", "record " .. rec.id .. ": unit not found"); return end
	local s = type(st.s3) == "table" and st.s3 or {}
	if s.id ~= rec.id then s = { id = rec.id } end
	local phase
	if rec.state == ST.DEP or rec.state == ST.GRACE then
		local here = Map.GetPlot(u:GetX(), u:GetY())
		if PlotOwner(here) >= 0 or not (s.nx == u:GetX() and s.ny == u:GetY()) then
			local plot = FindPlot(u:GetX(), u:GetY(), 12, Neutral, 1)
			if plot == nil then Check("GRACE", "CHECK", "no free neutral land within 12 tiles of the unit"); return end
			if PlotOwner(here) >= 0 then
				Place(u, plot)
				s.nx, s.ny = plot:GetX(), plot:GetY()
			else
				s.nx, s.ny = u:GetX(), u:GetY()
			end
		end
		if rec.state == ST.DEP then
			rec.deployedTurn = Turn() + 1 - (tonumber(rec.durationTurns) or EFV_Config.EXPEDITIONARY_DURATION)
			phase = "GRACE"
		else
			rec.graceTurnsLeft = 1
			phase = "MUTINY"
		end
		s.dmg = UnitDamage(u)
	else
		local plot = FindPlot(rec.destX, rec.destY, 4, OwnedBy(rec.recipientID), 1)
			or FindPlot(rec.originX, rec.originY, 4, OwnedBy(me), 1)
		if plot == nil then Check("GRACE", "CHECK", "no free tile in the host's or your land"); return end
		Place(u, plot)
		s.dmg = UnitDamage(u)
		phase = "RETURN"
	end
	Hold(store, u)
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	s.want, s.turn = phase, Turn()
	st.s3 = s
	Focus(st, u:GetX(), u:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("GRACE", "INFO", "record " .. rec.id .. " prepared; expected at the next turn start: " .. phase)
end

function EV.EvalS3(st, store, t)
	local s = st.s3
	if type(s) ~= "table" or s.want == nil or t <= s.turn then return end
	local want = s.want
	s.want = nil
	local rec = EFV_Records.Get(store, s.id)
	local u = rec and RecUnit(rec)
	local dmg = u and UnitDamage(u) or -1
	if want == "GRACE" then
		local ok = rec ~= nil and rec.state == ST.GRACE and tonumber(rec.graceTurnsLeft) == EFV_Config.GRACE_TURNS
		Check("GRACE", ok and "PASS" or "CHECK", "record " .. s.id .. " state=" .. Str(rec and rec.state) .. " grace=" ..
			Str(rec and rec.graceTurnsLeft) .. " (expected GRACE with " .. EFV_Config.GRACE_TURNS .. " turns)")
	elseif want == "MUTINY" then
		local expect = (tonumber(s.dmg) or 0) + EFV_Config.MUTINY_DAMAGE_PER_TURN
		local ok = rec ~= nil and rec.state == ST.MUT and dmg >= EFV_Config.MUTINY_DAMAGE_PER_TURN and dmg <= expect
		Check("MUTINY", ok and "PASS" or "CHECK", "record " .. s.id .. " state=" .. Str(rec and rec.state) .. " damage=" .. dmg ..
			" (expected MUTINY with " .. expect .. ")")
	else
		local ok = rec ~= nil and rec.state == ST.RET and rec.returnReason == "MUTINY_RETURN"
		if ok then Watch(st, rec) end
		Check("MUTINY_RETURN", ok and "PASS" or "CHECK", "record " .. s.id .. " state=" .. Str(rec and rec.state) .. " reason=" ..
			Str(rec and rec.returnReason) .. " damage kept=" .. Str(rec and rec.damage) .. " (expected RETURNING / MUTINY_RETURN)")
	end
end
end -- S3

-- ---------------------------------------------------------------------------
-- S4: ends (first press) or restores (second press) your Volunteer basis
-- with B: the declared friendship (S0; SetHasDeclaredFriendship works both
-- ways, Session F T27), plus the alliance flag if S0 had to use it (ending
-- it is a no-op in game, T27: then the LAPSE line says CHECK). Your
-- Volunteers with B lapse at the next turn start; standing in B's land
-- (moved there if needed) the lapse is paused. Restoring renews the
-- friendship and, if needed, B's open borders.
-- ---------------------------------------------------------------------------
do
CMD.scn_lapse = function(me, p)
	local st = Session("LAPSE", me)
	if st == nil then return end
	local B = st.ally
	local store = EFV_Records.Load()
	local rec = Newest(store, function(r)
		return r.forceType == FT_VOL and r.senderID == me and r.recipientID == B and r.state ~= ST.OUT and r.state ~= ST.RET
	end)
	if EFV_VolunteerBasis(me, B) ~= nil then
		SetDiploPair("scn_lapse", me, B, "SetHasDeclaredFriendship", false)
		if Diplo(me, "HasAllied", B) then SetDiploPair("scn_lapse", me, B, "SetHasAllied", false) end
		local still = EFV_VolunteerBasis(me, B)
		local u = rec and RecUnit(rec)
		if u ~= nil and not EFV_ValidReturnTerritory(rec, Map.GetPlot(u:GetX(), u:GetY())) then
			local plot = FindPlot(rec.destX, rec.destY, 4, OwnedBy(B), 1)
			if plot ~= nil then Place(u, plot) end
		end
		st.s4 = { want = "LAPSE", turn = Turn(), id = rec and rec.id or -1 }
		if u ~= nil then Focus(st, u:GetX(), u:GetY(), me, u:GetID(), p.stamp) end
		if still == nil then
			Check("LAPSE", "INFO", "friendship with " .. PlayerName(B) .. " ended; Volunteer record " .. Str(rec and rec.id) .. " should lapse (paused)")
		else
			Check("LAPSE", "CHECK", "the Volunteer basis with " .. PlayerName(B) .. " could not be ended (still " .. still ..
				"; a scripted alliance cannot be ended in game, Session F T27)")
		end
	else
		SetDiploPair("scn_lapse", me, B, "SetHasDeclaredFriendship", true)
		GrantOpenBorders(B, me)
		if EFV_VolunteerBasis(me, B) == nil and st.basis == "ALLIANCE" then SetDiploPair("scn_lapse", me, B, "SetHasAllied", true) end
		st.s4 = { want = "CANCEL", turn = Turn(), id = rec and rec.id or -1 }
		Check("LAPSE", "INFO", "friendship with " .. PlayerName(B) .. " restored (Volunteer basis " .. Str(EFV_VolunteerBasis(me, B)) .. ")")
	end
	EFV_Records.Commit(store)
	ScnSave(st)
end

function EV.EvalS4(st, store, t)
	local s = st.s4
	if type(s) ~= "table" or s.want == nil or t <= s.turn then return end
	local rec = EFV_Records.Get(store, s.id)
	if s.want == "LAPSE" then
		local ok = rec ~= nil and rec.lapsed == 1 and rec.lapsePaused == 1
		Check("LAPSE", ok and "PASS" or "CHECK", "Volunteer record " .. s.id .. " lapsed=" .. Str(rec and rec.lapsed) .. " paused=" ..
			Str(rec and rec.lapsePaused) .. " grace=" .. Str(rec and rec.graceTurnsLeft) .. " (expected a paused lapse on valid land)")
		s.want, s.turn, s.left = ok and "HOLD" or nil, t, rec and rec.graceTurnsLeft
		-- 0.7.2 (re-test 0.7 step 4): the pause only holds on B's or your
		-- land. In the re-test the Volunteer walked off B's land during this
		-- turn (50,33 -> 50,34, then a tile a turn), so the countdown ran, as
		-- designed. Hold it for this turn (no moves, nothing to order at End
		-- Turn) so the next turn start really checks the pause.
		local u = ok and RecUnit(rec) or nil
		if u ~= nil then
			Hold(store, u)
			Check("LAPSE_PAUSE", "INFO", "the Volunteer is held on " .. PlayerName(st.ally) .. "'s land at " .. u:GetX() .. "," ..
				u:GetY() .. " for this turn (no moves) so the countdown check at the next turn start is on valid land")
		end
	elseif s.want == "HOLD" then
		s.want = nil
		if rec == nil or rec.state == ST.RET then
			Check("LAPSE_PAUSE", "INFO", "Volunteer record " .. s.id .. " already recalled")
		elseif rec.lapsed == 1 and rec.lapsePaused ~= 1 then
			-- Not a VEF fault: off valid land the countdown must run.
			local u = RecUnit(rec)
			local where = u and (u:GetX() .. "," .. u:GetY() .. " (tile owner " ..
				Str(PlotOwner(Map.GetPlot(u:GetX(), u:GetY()))) .. ")") or "unknown"
			local ran = tonumber(s.left) ~= nil and rec.graceTurnsLeft == s.left - 1
			Check("LAPSE_PAUSE", "CHECK", "not verified: Volunteer record " .. s.id .. " left the valid land (now at " .. where ..
				"), so the countdown ran: grace " .. Str(s.left) .. " -> " .. Str(rec.graceTurnsLeft) ..
				(ran and " (correct off valid land)" or " (UNEXPECTED step)") .. "; leave the Volunteer on B's land")
		else
			local ok = rec.lapsed == 1 and rec.graceTurnsLeft == s.left
			Check("LAPSE_PAUSE", ok and "PASS" or "CHECK", "Volunteer record " .. s.id .. " grace=" .. Str(rec.graceTurnsLeft) ..
				" (was " .. Str(s.left) .. ": the countdown must not move while paused)")
		end
	else
		s.want = nil
		local basis = EFV_VolunteerBasis(st.me, st.ally)
		local restored = basis ~= nil
		if rec == nil or rec.state == ST.RET then
			Check("LAPSE_RESTORE", restored and "PASS" or "CHECK", "Volunteer basis restored=" .. Str(basis) .. " (the Volunteer was recalled)")
		else
			local ok = restored and rec.lapsed ~= 1
			Check("LAPSE_RESTORE", ok and "PASS" or "CHECK", "Volunteer basis restored=" .. Str(basis) .. ", Volunteer record " .. s.id ..
				" lapsed=" .. Str(rec.lapsed) .. " (expected the lapse cancelled)")
		end
	end
end
end -- S4

-- ---------------------------------------------------------------------------
-- S5: upgrade relink. A Volunteer of yours (deployed, standing in your land)
-- whose upgrade for your civilization is a unique unit when one exists. The
-- target's tech (SetTech) and civic (SetCivic), its strategic resource and
-- gold are granted, so it also works in a new game; you click Upgrade (no
-- gameplay upgrade call is proven).
-- ---------------------------------------------------------------------------
do
local function UpgradePair(me)
	local traits = {}
	pcall(function()
		local cfg = PlayerConfigurations[me]
		local civ, leader = cfg:GetCivilizationTypeName(), cfg:GetLeaderTypeName()
		for row in GameInfo.CivilizationTraits() do if row.CivilizationType == civ then traits[row.TraitType] = true end end
		for row in GameInfo.LeaderTraits() do if row.LeaderType == leader then traits[row.TraitType] = true end end
	end)
	local cands = {}
	pcall(function()
		for rep in GameInfo.UnitReplaces() do
			local uu = GameInfo.Units[rep.CivUniqueUnitType]
			if uu ~= nil and uu.TraitType ~= nil and traits[uu.TraitType] and uu.Domain == "DOMAIN_LAND" and (uu.Combat or 0) > 0 then
				for up in GameInfo.UnitUpgrades() do
					local from = GameInfo.Units[up.Unit]
					if up.UpgradeUnit == rep.ReplacesUnitType and from ~= nil and from.TraitType == nil
							and EFV_UpgradeTargets(up.Unit, me)[uu.UnitType] then
						cands[#cands + 1] = { from = up.Unit, to = uu.UnitType }
					end
				end
			end
		end
	end)
	table.sort(cands, function(a, b) return a.to .. a.from < b.to .. b.from end)
	if #cands > 0 then return cands[1].from, cands[1].to, true end
	local to = nil
	pcall(function()
		for up in GameInfo.UnitUpgrades() do if up.Unit == "UNIT_WARRIOR" then to = up.UpgradeUnit end end
	end)
	return "UNIT_WARRIOR", to or "UNIT_SWORDSMAN", false
end
EV.UpgradePair = UpgradePair   -- U1 (upgrade spike) uses the same pair

CMD.scn_upgrade = function(me, p)
	local st = Session("UPGRADE", me)
	if st == nil then return end
	local from, to, unique = UpgradePair(me)
	local row = GameInfo.Units[to]
	if row == nil then Check("UPGRADE", "CHECK", "no upgrade target found"); return end
	local notes = {}
	if row.PrereqTech ~= nil then
		local ok = pcall(function() Players[me]:GetTechs():SetTech(GameInfo.Technologies[row.PrereqTech].Index, true) end)
		notes[#notes + 1] = row.PrereqTech .. " granted=" .. tostring(ok)
	end
	if row.PrereqCivic ~= nil then notes[#notes + 1] = row.PrereqCivic .. " granted=" .. tostring(GrantCivic(me, row.PrereqCivic)) end
	if row.StrategicResource ~= nil and GameInfo.Resources[row.StrategicResource] ~= nil then
		pcall(function() Players[me]:GetResources():ChangeResourceAmount(GameInfo.Resources[row.StrategicResource].Index, 20) end)
		notes[#notes + 1] = row.StrategicResource .. " +20"
	end
	pcall(function() Players[me]:GetTreasury():ChangeGoldBalance(3000) end)
	local cap = Capital(me)
	local dest = Capital(st.ally)
	if cap == nil or dest == nil then Check("UPGRADE", "CHECK", "your capital or B's capital is missing"); return end
	local u = NewUnit("scn_upgrade", me, from, FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1), "VEF-UPGRADE")
	if u == nil then Check("UPGRADE", "CHECK", "could not create " .. from .. " in your land"); return end
	local store = EFV_Records.Load()
	local rec = MakeRecord(store, u, { force = FT_VOL, sender = me, recipient = st.ally, basis = st.basis or "FRIEND_OB", origin = cap, dest = dest })
	EFV_Records.Commit(store)
	if rec == nil then Check("UPGRADE", "CHECK", "record creation failed"); return end
	st.s5 = { id = rec.id, from = from, to = to, uid = u:GetID(), turn = Turn(), tries = 0 }
	Focus(st, u:GetX(), u:GetY(), me, u:GetID(), p.stamp)
	ScnSave(st)
	Check("UPGRADE", "INFO", "record " .. rec.id .. ": select 'VEF-UPGRADE' (" .. from .. ") and click Upgrade -> " .. to ..
		(unique and " (your unique unit)" or " (your civilization has no unique upgrade: normal upgrade)") .. "; " .. table.concat(notes, ", "))
end

function EV.EvalS5(st, store, t)
	local s = st.s5
	if type(s) ~= "table" or t <= s.turn then return end
	local rec = EFV_Records.Get(store, s.id)
	local u = rec and RecUnit(rec)
	if rec ~= nil and rec.unitType == s.to and u ~= nil then
		st.s5 = nil
		Check("UPGRADE", "PASS", "record " .. s.id .. " follows the upgraded unit: " .. s.from .. " " .. Str(s.uid) .. " -> " ..
			rec.unitType .. " " .. Str(rec.onMapUnitID))
	elseif rec ~= nil and rec.unitType == s.from and (s.tries or 0) < 2 then
		s.tries = (s.tries or 0) + 1
		s.turn = t
		Check("UPGRADE", "INFO", "record " .. s.id .. " is still " .. s.from .. ": click Upgrade on 'VEF-UPGRADE', then End Turn")
	else
		st.s5 = nil
		Check("UPGRADE", "CHECK", "record " .. s.id .. " " .. (rec == nil and "was closed (the upgraded unit was not followed)" or
			("type " .. Str(rec.unitType) .. " unit found=" .. tostring(u ~= nil))))
	end
end
end -- S5

-- ---------------------------------------------------------------------------
-- S6: veteran level restore (spike T08G idea). Three copies of the selected
-- own veteran next to it, named VEF-A / VEF-B / VEF-C:
--   A  per promotion: XP up to the threshold, then SetPromotion;
--   B  per promotion: XP up to the threshold (here), then the engine PROMOTE
--      command, sent by the panel (UI only, UnitPromotionPopup.lua:70-72);
--   C  SetPromotion only, then the XP (the current restore, EFV_Units.Recreate).
-- Gameplay compares the next-level XP threshold (the level is UI-only:
-- GetLevel is nil in G, Session A T09); the panel adds the UI levels.
-- ---------------------------------------------------------------------------
local PromoRows, SetPromo, XPInfo, XPToThreshold, TopUp, PromoCount
do
function PromoRows(u)
	local rows = {}
	local exp = u:GetExperience()
	for row in GameInfo.UnitPromotions() do
		if exp:HasPromotion(row.Index) then rows[#rows + 1] = row end
	end
	table.sort(rows, function(a, b)
		local la, lb = tonumber(a.Level) or 0, tonumber(b.Level) or 0
		if la ~= lb then return la < lb end
		return a.Index < b.Index
	end)
	return rows
end

-- exp:SetPromotion from gameplay (the restore VEF uses for AI owners,
-- EFV_Units.Recreate): S6 routes A / C and the V3 spike copy.
function SetPromo(u, idx)
	return pcall(function() u:GetExperience():SetPromotion(idx) end)
end

function XPInfo(u)
	local xp, nxt = -1, -1
	pcall(function()
		local exp = u:GetExperience()
		xp, nxt = exp:GetExperiencePoints(), exp:GetExperienceForNextLevel()
	end)
	return tonumber(xp) or -1, tonumber(nxt) or -1
end

function XPToThreshold(u)
	local xp, nxt = XPInfo(u)
	if xp >= 0 and nxt > xp then pcall(function() u:GetExperience():ChangeExperience(nxt - xp) end) end
end

function TopUp(u, want)
	local xp = XPInfo(u)
	if xp >= 0 and (tonumber(want) or 0) > xp then pcall(function() u:GetExperience():ChangeExperience(want - xp) end) end
end

function PromoCount(u, names)
	local n = 0
	pcall(function()
		local exp = u:GetExperience()
		for _, nm in ipairs(names) do
			local row = GameInfo.UnitPromotions[nm]
			if row ~= nil and exp:HasPromotion(row.Index) then n = n + 1 end
		end
	end)
	return n
end

local ROUTE = {
	A = "route A (XP to the threshold, then SetPromotion)",
	B = "route B (XP to the threshold, then the PROMOTE command)",
	C = "route C (SetPromotion only: the current restore)",
}

local function VetVerdict(id, v, u, vet)
	local _, nxt = XPInfo(u)
	local n = PromoCount(u, vet.promos)
	local ok = (nxt == vet.nxt) and (n == #vet.promos)
	Check(id, ok and "PASS" or "CHECK", ROUTE[v] .. ": next-level XP " .. nxt .. " (original " .. Str(vet.nxt) .. "), promotions " ..
		n .. "/" .. #vet.promos .. (ok and ": level kept" or ": level NOT kept"))
end

CMD.scn_vet = function(me, p)
	local st = ScnLoad()
	st.me = st.me or me
	local u = SelectedUnit(p)
	if u == nil or u:GetOwner() ~= me then Check("VET", "CHECK", "select one of your units with at least one promotion first"); return end
	local rows = PromoRows(u)
	if #rows == 0 then
		XPToThreshold(u)
		Check("VET", "INFO", "the selected unit had no promotion: it now has enough XP. Promote it in its unit panel, then press S6 again")
		return
	end
	local xp, nxt = XPInfo(u)
	local names = {}
	for _, r in ipairs(rows) do names[#names + 1] = r.UnitPromotionType end
	local ut = UnitTypeName(u)
	local water = GameInfo.Units[ut] ~= nil and GameInfo.Units[ut].Domain == "DOMAIN_SEA"
	local vet = { o = me, id = u:GetID(), promos = names, xp = xp, nxt = nxt, stamp = p.stamp or 0, turn = Turn() }
	for _, v in ipairs({ "A", "B", "C" }) do
		local plot = FindFreePlot(u:GetX(), u:GetY(), water)
		local c = NewUnit("scn_vet", me, ut, plot, "VEF-" .. v)
		if c ~= nil then vet[v] = c:GetID() end
	end
	local a = vet.A and FindUnit(me, vet.A)
	if a ~= nil then
		for _, r in ipairs(rows) do
			XPToThreshold(a)
			SetPromo(a, r.Index)
		end
		TopUp(a, xp)
		VetVerdict("VET_A", "A", a, vet)
	end
	local c = vet.C and FindUnit(me, vet.C)
	if c ~= nil then
		for _, r in ipairs(rows) do SetPromo(c, r.Index) end
		TopUp(c, xp)
		VetVerdict("VET_C", "C", c, vet)
	end
	local b = vet.B and FindUnit(me, vet.B)
	if b ~= nil then XPToThreshold(b) end
	st.vet = vet
	Focus(st, u:GetX(), u:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("VET", "INFO", "original " .. UnitTypeName(u) .. " " .. u:GetID() .. " xp=" .. xp .. " next=" .. nxt .. " promotions=" ..
		table.concat(names, "+") .. "; copies A=" .. Str(vet.A) .. " B=" .. Str(vet.B) .. " C=" .. Str(vet.C) ..
		"; the panel now promotes VEF-B with the PROMOTE command")
end

-- Panel step for B: XP up to the threshold again (after promotion i-1 landed).
CMD.scn_vetb = function(me, p)
	local st = ScnLoad()
	local vet = st.vet
	local b = type(vet) == "table" and vet.B and FindUnit(me, vet.B)
	if b == nil then Log("scn_vetb", "no VEF-B"); return end
	XPToThreshold(b)
	local xp, nxt = XPInfo(b)
	Log("scn_vetb", "VEF-B promotion " .. Str(p.i) .. ": xp=" .. xp .. " next=" .. nxt)
end

-- Panel step for B: XP top-up and the gameplay verdict.
CMD.scn_vetdone = function(me, p)
	local st = ScnLoad()
	local vet = st.vet
	local b = type(vet) == "table" and vet.B and FindUnit(me, vet.B)
	if b == nil then Check("VET_B", "CHECK", "VEF-B not found"); return end
	TopUp(b, vet.xp)
	VetVerdict("VET_B", "B", b, vet)
end
end -- S6

-- ---------------------------------------------------------------------------
-- S7: a unit killed in the fight for its host's last city is not sent home.
-- A damaged Warrior of a one-city city-state (not the S0 one) is tracked as
-- your City-State unit, next to its city; you are put at war with that
-- city-state and get three Tanks next to it. Kill the Warrior, then take the
-- city in the same turn.
-- ---------------------------------------------------------------------------
local PickCityState
do
function PickCityState(st, me, exclude)
	local cap = Capital(me)
	local best, bestD = nil, nil
	for _, cs in ipairs(SortedIDs(IsCityStateID)) do
		if not Has(exclude, cs) and #Cities(cs) == 1 then
			local c = Cities(cs)[1]
			local suz = -1
			pcall(function() suz = Players[cs]:GetInfluence():GetSuzerain() end)
			local d = cap and Dist(cap:GetX(), cap:GetY(), c:GetX(), c:GetY()) or 0
			if suz ~= nil and suz >= 0 then d = d + 1000 end
			if bestD == nil or d < bestD then best, bestD = cs, d end
		end
	end
	return best
end

CMD.scn_kill = function(me, p)
	local st = Session("KILLED", me)
	if st == nil then return end
	local cs = PickCityState(st, me, { st.cs, st.guardCs or -1 })
	if cs == nil then Check("KILLED", "CHECK", "no other one-city city-state is alive"); return end
	local city = Cities(cs)[1]
	local cap = Capital(me)
	MeetPair(me, cs)
	local def = NewUnit("scn_kill", cs, "UNIT_WARRIOR", FindPlot(city:GetX(), city:GetY(), 2, OwnedByAny({ -1, cs }), 1), "VEF-KILL")
	if def == nil then Check("KILLED", "CHECK", "could not create the city-state's Warrior"); return end
	local store = EFV_Records.Load()
	local rec = MakeRecord(store, def, { force = FT_CS, sender = me, recipient = cs, basis = "CITY_STATE", origin = cap, dest = city,
		duration = EFV_Config.CS_EXPEDITIONARY_DURATION })
	EFV_Records.Commit(store)
	pcall(function() def:SetDamage(60) end)
	DeclareWar(me, cs)
	RevealCity(me, city, { -1, cs, me })
	local _, weak = WeakenCity(city)
	local n = 0
	for _ = 1, 3 do
		if NewUnit("scn_kill", me, "UNIT_TANK", FindPlot(def:GetX(), def:GetY(), 4, OwnedByAny({ -1, cs, me, st.ally }), 1)) ~= nil then n = n + 1 end
	end
	st.killCs = cs
	st.s7 = { id = rec and rec.id or -1, cs = cs, cx = city:GetX(), cy = city:GetY(), uid = def:GetID(), turn = Turn() }
	Focus(st, def:GetX(), def:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("KILLED", "INFO", "record " .. Str(rec and rec.id) .. ": kill 'VEF-KILL' next to " .. PlayerName(cs) ..
		"'s city with the " .. n .. " Tanks, then take the city this turn (" .. weak .. ")")
end

function EV.EvalS7(st, store, t, manual)
	local s = st.s7
	if type(s) ~= "table" or (t <= s.turn and not manual) then return end
	local rec = EFV_Records.Get(store, s.id)
	local city = CityManager.GetCityAt(s.cx, s.cy)
	local taken = city == nil or city:GetOwner() ~= s.cs
	if rec == nil then
		st.s7 = nil
		Check("KILLED", taken and "PASS" or "CHECK", "record " .. s.id .. " closed without a return; city-state " ..
			(Alive(s.cs) and "still alive" or "eliminated") .. ", city taken=" .. tostring(taken))
	elseif rec.state == ST.RET then
		st.s7 = nil
		Check("KILLED", "CHECK", "record " .. s.id .. " is going home (" .. Str(rec.returnReason) .. "): a killed unit must not return")
	elseif not manual then
		st.s7 = nil
		Check("KILLED", "CHECK", "record " .. s.id .. " still " .. Str(rec.state) .. ": the Warrior was not killed in time")
	end
end
end -- S7

-- ---------------------------------------------------------------------------
-- S8: wrong-unit relink guard. A City-State unit of another city-state whose
-- record points to "a levied copy under you" is removed without combat, and
-- two identical Warriors of that city-state stand within 2 tiles: EFV must
-- not adopt either (ambiguous) and closes the record instead.
-- ---------------------------------------------------------------------------
do
CMD.scn_guard = function(me, p)
	local st = Session("GUARD", me)
	if st == nil then return end
	local cs = PickCityState(st, me, { st.cs, st.killCs or -1 })
	if cs == nil then
		for _, id in ipairs(SortedIDs(IsCityStateID)) do if id ~= st.cs and #Cities(id) > 0 then cs = id end end
	end
	if cs == nil then Check("GUARD", "CHECK", "no second city-state with a city"); return end
	MeetPair(me, cs)
	local city = Cities(cs)[1]
	local cap = Capital(me)
	local u = NewUnit("scn_guard", me, "UNIT_WARRIOR", FindPlot(city:GetX(), city:GetY(), 3, OwnedByAny({ -1, cs }), 2), "VEF-GUARD")
	if u == nil then Check("GUARD", "CHECK", "could not create the tracked Warrior"); return end
	local store = EFV_Records.Load()
	local rec = MakeRecord(store, u, { force = FT_CS, sender = me, recipient = cs, basis = "CITY_STATE", origin = cap, dest = city,
		duration = EFV_Config.CS_EXPEDITIONARY_DURATION })
	local strangers = {}
	for _ = 1, 2 do
		local plot = FindPlot(u:GetX(), u:GetY(), 2, OwnedByAny({ -1, cs }), 1)
		local w = NewUnit("scn_guard", cs, "UNIT_WARRIOR", plot)
		if w ~= nil then strangers[#strangers + 1] = w:GetID(); Hold(store, w) end
	end
	local ux, uy = u:GetX(), u:GetY()
	local okD = pcall(function() Players[me]:GetUnits():Destroy(u) end)
	EFV_Records.Commit(store)
	st.guardCs = cs
	st.s8 = { id = rec and rec.id or -1, cs = cs, s = strangers, turn = Turn() }
	Focus(st, ux, uy, nil, nil, p.stamp)
	ScnSave(st)
	Check("GUARD", "INFO", "record " .. Str(rec and rec.id) .. ": tracked Warrior removed=" .. tostring(okD) .. ", " .. #strangers ..
		" identical Warriors of " .. PlayerName(cs) .. " next to its tile")
end

function EV.EvalS8(st, store, t)
	local s = st.s8
	if type(s) ~= "table" or t <= s.turn then return end
	st.s8 = nil
	local rec = EFV_Records.Get(store, s.id)
	local adopted = rec ~= nil and Has(s.s, rec.onMapUnitID)
	if adopted then
		Check("GUARD", "CHECK", "record " .. s.id .. " was relinked to a stranger (unit " .. Str(rec.onMapUnitID) .. ")")
	elseif rec == nil then
		Check("GUARD", "PASS", "record " .. s.id .. " closed as lost; neither identical Warrior was adopted")
	else
		Check("GUARD", "CHECK", "record " .. s.id .. " still open (state " .. Str(rec.state) .. ", unit " .. Str(rec.onMapUnitID) .. ")")
	end
	for _, uid in ipairs(s.s or {}) do
		local w = FindUnit(s.cs, uid)
		if w ~= nil then pcall(function() Players[s.cs]:GetUnits():Destroy(w) end) end
	end
end
end -- S8

-- ---------------------------------------------------------------------------
-- S9: crowded arrival. Every free land tile of rings 1-2 around B's capital
-- gets one of B's Warriors (held in place; water, impassable and occupied
-- tiles are skipped), and a Swordsman of yours is sent to that city as
-- Expeditionary, arriving next turn. Designer ruling "Crowded arrival
-- accepted" (FIXPLAN_0.7 item 8): EFV must use the nearest ring that still
-- has a valid free tile (ring 2 is fine when one tile there is left), never
-- a city centre or closed / war land. EFV_Spawn.DryRun at setup time is
-- logged as info ("expected ring R").
-- ---------------------------------------------------------------------------
do
CMD.scn_place = function(me, p)
	local st = Session("CROWDED", me)
	if st == nil then return end
	local B = st.ally
	local dest = Capital(B)
	local cap = Capital(me)
	if dest == nil or cap == nil then Check("CROWDED", "CHECK", "your capital or B's capital is missing"); return end
	local store = EFV_Records.Load()
	local fill = {}
	for ring = 1, 2 do
		for _, plot in ipairs(Ring(dest:GetX(), dest:GetY(), ring)) do
			if FreeLand(plot) then
				local w = NewUnit("scn_place", B, "UNIT_WARRIOR", plot)
				if w ~= nil then fill[#fill + 1] = w:GetID(); Hold(store, w) end
			end
		end
	end
	local u = NewUnit("scn_place", me, "UNIT_SWORDSMAN", FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1))
	if u == nil then Check("CROWDED", "CHECK", "could not create the Swordsman"); return end
	local rec = MakeRecord(store, u, { force = FT_EXP, state = ST.OUT, sender = me, recipient = B, basis = st.partner or "FRIEND", origin = cap,
		dest = dest, duration = EFV_Config.EXPEDITIONARY_DURATION })
	if rec == nil then Check("CROWDED", "CHECK", "record creation failed"); return end
	rec.arrivalTurn = Turn() + 1
	rec.sentTurn = Turn()
	local removed = EFV_Units.Remove(u)
	if not removed then EFV_Records.Delete(store, rec.id) end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	local okD, found, ring, n = pcall(EFV_Spawn.DryRun, dest:GetX(), dest:GetY(), "LAND", B)
	local expect = (okD and found) and ("expected ring " .. Str(ring) .. " (" .. Str(n) .. " free valid tile(s) there)") or "no valid tile found now"
	st.s9 = { id = rec.id, cx = dest:GetX(), cy = dest:GetY(), fill = fill, turn = Turn() }
	Focus(st, dest:GetX(), dest:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("CROWDED", removed and "INFO" or "CHECK", "record " .. rec.id .. ": " .. #fill .. " Warriors fill the free land tiles of rings 1-2 of " ..
		PlayerName(B) .. "'s capital; the Swordsman arrives next turn; " .. expect)
end

-- Inner rings (1 .. ring-1) that still hold a valid spawn tile for owner.
local function InnerValidRings(cx, cy, ring, owner)
	local out = {}
	for r = 1, ring - 1 do
		for _, plot in ipairs(Ring(cx, cy, r)) do
			local ok, valid = pcall(EFV_Spawn.Valid, plot, "LAND", owner)
			if ok and valid then out[#out + 1] = r; break end
		end
	end
	return out
end

function EV.EvalS9(st, store, t)
	local s = st.s9
	if type(s) ~= "table" or t <= s.turn then return end
	st.s9 = nil
	local rec = EFV_Records.Get(store, s.id)
	local u = rec and rec.state ~= ST.OUT and RecUnit(rec)
	if u == nil then
		Check("CROWDED", "CHECK", "record " .. s.id .. " state=" .. Str(rec and rec.state) .. " (no unit placed; blocked=" ..
			Str(rec and rec.spawnFailCount) .. ")")
	else
		local why, ring = PlacementProblem(u, s.cx, s.cy)
		local count = -1
		pcall(function() count = Map.GetPlot(u:GetX(), u:GetY()):GetUnitCount() end)
		if count ~= 1 then why[#why + 1] = "the tile holds " .. Str(count) .. " units" end
		local inner = InnerValidRings(s.cx, s.cy, ring, u:GetOwner())
		if #inner > 0 then why[#why + 1] = "ring " .. inner[1] .. " still has a valid free tile" end
		Check("CROWDED", #why == 0 and "PASS" or "CHECK", "record " .. s.id .. " placed at ring " .. ring .. " plot=" .. u:GetX() ..
			"," .. u:GetY() .. (#why > 0 and (" PROBLEM: " .. table.concat(why, "; ")) or ": the nearest ring with a free valid tile"))
		pcall(function() Players[u:GetOwner()]:GetUnits():Destroy(u) end)
		EFV_Records.Delete(store, s.id)
		EFV_Records.Touch(store)
	end
	for _, uid in ipairs(s.fill or {}) do
		local w = FindUnit(st.ally, uid)
		if w ~= nil then pcall(function() Players[st.ally]:GetUnits():Destroy(w) end) end
	end
end
end -- S9

-- ---------------------------------------------------------------------------
-- S10: combat during mutiny (T31, EFV/TESTING_FINAL_DRAFT_T31.md). You host
-- B's Expeditionary Spearman in MUTINY on neutral land, next to two
-- Barbarian Warriors. Attack one (and let them attack you): the combat
-- damage must be seen at the combat event (EFV raises its heal floor) and
-- kept; the next turn start adds exactly the 20 mutiny damage.
-- 0.7 (FIXPLAN items 9, 10): the Spearman has no custom name (a name set
-- at creation was not shown by the unit panel); the verdict never removes a
-- unit of yours at your PlayerTurnStartComplete (the engine re-selected the
-- removed unit: SelectedUnit.lua:195 error). The Spearman and the two
-- Barbarians go to st.cleanup and are removed at GameEvents.OnGameTurnEnded
-- of that turn (DevCleanup below).
-- ---------------------------------------------------------------------------
do
CMD.scn_t31 = function(me, p)
	local st = Session("T31", me)
	if st == nil then return end
	local barb = BarbarianID()
	local cap = Capital(me)
	local host = Capital(st.ally)
	if barb == nil or cap == nil or host == nil then Check("T31", "CHECK", "no Barbarian player or capital"); return end
	local spot, next1, next2 = nil, nil, nil
	for ring = 2, 12 do
		for _, plot in ipairs(Ring(cap:GetX(), cap:GetY(), ring)) do
			if spot == nil and FreeLand(plot) and Neutral(plot) and NotWonder(plot) then
				local adj = {}
				for _, q in ipairs(Ring(plot:GetX(), plot:GetY(), 1)) do
					if FreeLand(q) and Neutral(q) then adj[#adj + 1] = q end
				end
				if #adj >= 2 then spot, next1, next2 = plot, adj[1], adj[2] end
			end
		end
	end
	if spot == nil then Check("T31", "CHECK", "no neutral land with two free neutral neighbours within 12 tiles of your capital"); return end
	local u = NewUnit("scn_t31", me, "UNIT_SPEARMAN", spot) or NewUnit("scn_t31", me, "UNIT_WARRIOR", spot)
	if u == nil then Check("T31", "CHECK", "could not create the Spearman"); return end
	local b1 = NewUnit("scn_t31", barb, "UNIT_WARRIOR", next1)
	local b2 = NewUnit("scn_t31", barb, "UNIT_WARRIOR", next2)
	local store = EFV_Records.Load()
	local rec = MakeRecord(store, u, { force = FT_EXP, sender = st.ally, recipient = me, basis = st.partner or "FRIEND", origin = host, dest = cap,
		duration = EFV_Config.EXPEDITIONARY_DURATION, deployedTurn = Turn() - EFV_Config.EXPEDITIONARY_DURATION })
	if rec == nil then Check("T31", "CHECK", "record creation failed"); return end
	rec.state = ST.MUT
	rec.lastDamage = UnitDamage(u)
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.s10 = { id = rec.id, uid = u:GetID(), b = { b1 and b1:GetID() or -1, b2 and b2:GetID() or -1 }, barb = barb,
		pre = UnitDamage(u), turn = Turn() }
	Focus(st, spot:GetX(), spot:GetY(), me, u:GetID(), p.stamp)
	ScnSave(st)
	Check("T31", "INFO", "record " .. rec.id .. ": the " .. UnitTypeName(u) .. " in mutiny (the camera selects it) stands at " ..
		spot:GetX() .. "," .. spot:GetY() .. " next to 2 Barbarian Warriors: attack one, then End Turn (they are removed before their own turn)")
end

-- 0.7.2 (re-test 0.7 step 6): after your fight both Barbarians attacked the
-- Spearman in their turn (27 -> 57 -> 88), and the mutiny's 20 at the next
-- turn start killed it before the check. Once the Spearman has fought, the
-- Barbarians are removed at the next player's GameEvents.PlayerTurnStarted
-- (the first hook after you end the turn, before the Barbarians act; never
-- a unit of yours, so no selection problem), so only your fight counts:
-- about 30 + 20 damage, the unit lives to the verdict.
function EV.OnTurnStartedT31(pid)
	local st = ScnLoad()
	local s = st.s10
	if type(s) ~= "table" or st.me == nil or pid == st.me or s.combat == nil or s.barbGone ~= nil then return end
	local n = 0
	for _, uid in ipairs(s.b or {}) do
		local b = FindUnit(s.barb, uid)
		if b ~= nil and pcall(function() Players[s.barb]:GetUnits():Destroy(b) end) then n = n + 1 end
	end
	s.barbGone = n
	ScnSave(st)
	Check("T31", "INFO", n .. " Barbarian Warrior(s) removed after the fight, before their turn: only your fight counts")
end

-- GameEvents.OnCombatOccurred (registered after EFV's own handler): what EFV
-- could see at the combat event.
function EV.OnCombatT31(aP, aU, dP, dU)
	local st = ScnLoad()
	local s = st.s10
	if type(s) ~= "table" or st.me == nil then return end
	if not ((aP == st.me and aU == s.uid) or (dP == st.me and dU == s.uid)) then return end
	local u = FindUnit(st.me, s.uid)
	local d = u and UnitDamage(u) or -1
	local store = EFV_Records.Load()
	local rec = EFV_Records.Get(store, s.id)
	local floor = rec and tonumber(rec.lastDamage) or -1
	local before = tonumber(s.last) or tonumber(s.pre) or 0
	if d > before then
		Check("T31_EVENT", floor >= d and "PASS" or "CHECK", "damage visible at the combat event: " .. before .. " -> " .. d ..
			", EFV heal floor=" .. floor)
	elseif d >= 0 then
		Check("T31_EVENT", "CHECK", "no new damage visible at the combat event (unit damage " .. d .. ", before " .. before ..
			"): if the unit was hurt, EFV sees it only later (at most one heal can offset it)")
	end
	if d > (tonumber(s.combat) or -1) then s.combat = d end
	s.last = d
	ScnSave(st)
end

function EV.EvalS10(st, store, t)
	local s = st.s10
	if type(s) ~= "table" or t <= s.turn then return end
	local u = FindUnit(st.me, s.uid)
	local rec = EFV_Records.Get(store, s.id)
	if s.combat == nil and (s.waited or 0) < 1 then
		s.waited, s.turn = 1, t
		Check("T31", "INFO", "no fight with the Spearman in mutiny yet: attack a Barbarian Warrior, then End Turn")
		return
	end
	st.s10 = nil
	local d = u and UnitDamage(u) or -1
	if s.combat == nil then
		Check("T31", "CHECK", "no fight happened (optional check skipped)")
	elseif u == nil or rec == nil then
		Check("T31", "CHECK", "the unit or its record is gone (damage " .. Str(s.combat) .. " + 20 may have killed it)")
	else
		local expect = s.combat + EFV_Config.MUTINY_DAMAGE_PER_TURN
		Check("T31", d >= expect and "PASS" or "CHECK", "after the round: damage " .. d .. " (fight " .. s.combat ..
			" + mutiny 20 = " .. expect .. ")" .. (d >= expect and ": combat damage kept, heal cancelled" or ": combat damage was healed away"))
	end
	if rec ~= nil then EFV_Records.Delete(store, s.id); EFV_Records.Touch(store) end
	-- Removed at the end of this turn (OnGameTurnEnded), never now.
	local c = Sub(st, "cleanup")
	if u ~= nil then c[#c + 1] = { o = st.me, u = s.uid, ut = UnitTypeName(u) } end
	for _, uid in ipairs(s.b or {}) do
		local b = FindUnit(s.barb, uid)
		if b ~= nil then c[#c + 1] = { o = s.barb, u = uid, ut = UnitTypeName(b) } end
	end
	Check("T31", "INFO", #c .. " test unit(s) are removed when you end this turn")
end
end -- S10

-- ---------------------------------------------------------------------------
-- S11: Entrust. A city of C that is not its last one (taking the last city
-- would eliminate C): C's nearest non-capital city, else a new small city
-- founded for C 5-10 tiles from your capital (Cities:Create), else C's only
-- city (noted). Its walls are removed and its centre is left at 1 HP, it is
-- revealed to you, and three Tanks of yours stand next to it (you and B at
-- war with C; your partner basis with B renewed if S4 left it off). Take the
-- city and press Entrust.
-- ---------------------------------------------------------------------------
-- The S11 scene (also Shot 4): returns city, tanks, note, weak, or nil, why.
-- opts (EFV_Dev 1.0.3.2, S19): owner = the city's owner (default C),
-- allyWar = false keeps B out of the war (default: B declares war too),
-- keepOwner = true refuses the owner's last city (taking it would eliminate
-- the owner, and VEF 1.0.3 then skips the at-war check).
local BuildEntrustScene
do
function BuildEntrustScene(cmd, me, st, radius, opts)
	opts = opts or {}
	local C = opts.owner or st.enemy
	local cap = Capital(me)
	if cap == nil then return nil, "you have no capital" end
	local capC = Capital(C)
	local best, bestD = nil, nil
	for _, c in ipairs(Cities(C)) do
		local d = Dist(cap:GetX(), cap:GetY(), c:GetX(), c:GetY())
		if (capC == nil or c:GetID() ~= capC:GetID()) and (bestD == nil or d < bestD) then best, bestD = c, d end
	end
	local note = PlayerName(C) .. "'s nearest city that is not its capital"
	if best == nil then
		best, note = FoundCityFor(C, cap:GetX(), cap:GetY())
		if best == nil then
			if opts.keepOwner then return nil, note .. "; its only city would eliminate it" end
			best = capC
			note = note .. "; using C's only city (taking it eliminates C)"
		end
	end
	if best == nil then return nil, "the enemy has no city" end
	if EFV_PartnerBasis(me, st.ally) == nil then EnsurePartner(cmd, me, st.ally) end
	DeclareWar(me, C)
	if opts.allyWar ~= false then DeclareWar(st.ally, C) end
	RevealCity(me, best, { -1, C, me, st.ally }, radius)
	local _, weak = WeakenCity(best)
	local tanks = {}
	for _ = 1, 3 do
		local t = NewUnit(cmd, me, "UNIT_TANK", FindPlot(best:GetX(), best:GetY(), 4, OwnedByAny({ -1, C, me, st.ally }), 1))
		if t ~= nil then tanks[#tanks + 1] = t end
	end
	return best, tanks, note, weak
end

CMD.scn_entrust = function(me, p)
	local st = Session("ENTRUST", me)
	if st == nil then return end
	local C = st.enemy
	local best, tanks, note, weak = BuildEntrustScene("scn_entrust", me, st)
	if best == nil then Check("ENTRUST", "CHECK", tanks); return end
	local n = #tanks
	st.s11 = { cx = best:GetX(), cy = best:GetY(), owner = C, turn = Turn(), tries = 0 }
	Focus(st, best:GetX(), best:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("ENTRUST", "INFO", n .. " Tanks next to " .. PlayerName(C) .. "'s city at " .. best:GetX() .. "," .. best:GetY() ..
		" (" .. note .. "; " .. weak .. "): take it and choose Entrust -> " .. PlayerName(st.ally))
end

function EV.EvalS11(st, store, t, manual)
	local s = st.s11
	if type(s) ~= "table" or (t <= s.turn and not manual) then return end
	local city = CityManager.GetCityAt(s.cx, s.cy)
	local owner = city and city:GetOwner() or -1
	if owner == st.ally or owner == st.friend then
		st.s11 = nil
		Check("ENTRUST", "PASS", "the city now belongs to " .. PlayerName(owner))
	elseif owner == st.me then
		st.s11 = nil
		Check("ENTRUST", "CHECK", "you kept the city (Entrust was not used or was refused)")
	elseif not manual then
		s.tries = (s.tries or 0) + 1
		if s.tries >= 3 then st.s11 = nil end
		Check("ENTRUST", s.tries >= 3 and "CHECK" or "INFO", "the city still belongs to " .. PlayerName(owner))
	end
end
end -- S11

-- ---------------------------------------------------------------------------
-- S12 (0.7): veteran return, route B (FIXPLAN item 7). A RETURNING Volunteer
-- record of yours (recipient B) that arrives at your capital at the next
-- turn start: "VEF-VET", a Warrior at level 3 with two promotions (the
-- first two level-1 promotions of the Warrior's class in DB order, so no
-- prerequisite issue), 50/90 XP and 30 damage. EFV recreates it at level 1
-- and your own UI takes the promotions back with the PROMOTE command
-- (EFV_VetRestore). The first check (INFO) names the open job; VET_RESTORE
-- is written once the job is gone (a later turn start, or Check now, which
-- the panel presses by itself after its UI check VET_RESTORE_LEVEL).
-- ---------------------------------------------------------------------------
local LevelOnePromotions
do
local VET_NAME = "VEF-VET"

function LevelOnePromotions(unitType, n)
	local out = {}
	local unit = GameInfo.Units[unitType]
	local cls = unit and unit.PromotionClass
	for row in GameInfo.UnitPromotions() do
		if #out < n and row.PromotionClass == cls and tonumber(row.Level) == 1 then
			out[#out + 1] = row.UnitPromotionType
		end
	end
	return out
end

local function FindVetJob(store, pid, rid, uid)
	for _, j in ipairs(store.vet or {}) do
		if j.p == pid and ((rid ~= nil and j.rid == rid) or (uid ~= nil and j.u == uid)) then return j end
	end
	return nil
end

-- Your newest unit with the given veteran name.
local function NamedUnit(pid, name)
	local best = nil
	pcall(function()
		for _, u in Players[pid]:GetUnits():Members() do
			local ok, n = pcall(function() return u:GetExperience():GetVeteranName() end)
			if ok and n == name and (best == nil or u:GetID() > best:GetID()) then best = u end
		end
	end)
	return best
end

CMD.scn_vetret = function(me, p)
	local st = Session("VET_RESTORE", me)
	if st == nil then return end
	local B = st.ally
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then Check("VET_RESTORE", "CHECK", "your capital or B's capital is missing"); return end
	local promos = LevelOnePromotions("UNIT_WARRIOR", 2)
	if #promos < 2 then Check("VET_RESTORE", "CHECK", "the Warrior's class has fewer than 2 level-1 promotions"); return end
	local t = Turn()
	local store = EFV_Records.Load()
	local rec = EFV_Records.New(store, {
		forceType = FT_VOL, state = ST.RET, senderID = me, recipientID = B, accessBasis = st.basis or "FRIEND_OB",
		originCityID = cap:GetID(), originX = cap:GetX(), originY = cap:GetY(),
		destCityID = capB:GetID(), destX = capB:GetX(), destY = capB:GetY(), rerouted = 0,
		sentTurn = t - 12, deployedTurn = t - 11, arrivalTurn = t + 1, transitTurns = 1, band = 1,
		distance = Dist(cap:GetX(), cap:GetY(), capB:GetX(), capB:GetY()),
		lapsed = 0, spawnFailCount = 0, feePaid = 0, maintGoldPaid = 0,
		returnCityID = cap:GetID(), returnX = cap:GetX(), returnY = cap:GetY(), returnReason = "RECALL",
		unitType = "UNIT_WARRIOR", veteranName = VET_NAME, damage = 30, experience = 50, xpNext = 90, level = 3,
		promotions = promos, formation = 0, snapTurn = t, lastX = capB:GetX(), lastY = capB:GetY(),
	})
	if rec == nil then Check("VET_RESTORE", "CHECK", "record creation failed"); return end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.s12 = { id = rec.id, turn = t, promos = promos }
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("VET_RESTORE", "INFO", "record " .. rec.id .. ": " .. VET_NAME .. " (Warrior, level 3, " .. table.concat(promos, "+") ..
		", XP 50/90, 30 damage) comes home next to your capital at the next turn start")
end

function EV.EvalS12(st, store, t, manual)
	local s = st.s12
	if type(s) ~= "table" or s.done ~= nil then return end
	local promos = type(s.promos) == "table" and s.promos or {}
	if s.uid == nil then
		if t <= s.turn and not manual then return end
		local rec = EFV_Records.Get(store, s.id)
		if rec ~= nil then
			if not manual then
				s.done = "CHECK"
				Check("VET_RESTORE", "CHECK", "record " .. s.id .. " did not arrive (state " .. Str(rec.state) .. ", blocked " ..
					Str(rec.spawnFailCount) .. ")")
			end
			return
		end
		local job = FindVetJob(store, st.me, s.id, nil)
		if job ~= nil then
			s.uid = job.u
			local want = type(job.want) == "table" and job.want or {}
			Check("VET_RESTORE", "INFO", VET_NAME .. " is home (unit " .. Str(job.u) .. "); your UI takes its promotions back (to take: " ..
				table.concat(want, "+") .. ")")
			return
		end
		local u = NamedUnit(st.me, VET_NAME)
		if u == nil then
			s.done = "CHECK"
			Check("VET_RESTORE", "CHECK", "record " .. s.id .. " closed, but no unit named " .. VET_NAME .. " is found")
			return
		end
		s.uid = u:GetID()
	end
	if FindVetJob(store, st.me, nil, s.uid) ~= nil then return end
	local u = FindUnit(st.me, s.uid)
	if u == nil then
		s.done = "CHECK"
		Check("VET_RESTORE", "CHECK", VET_NAME .. " (unit " .. Str(s.uid) .. ") is gone")
		return
	end
	local xp, nxt = XPInfo(u)
	local n = PromoCount(u, promos)
	local d = UnitDamage(u)
	-- 0.7.2 (re-test 0.7 step 5): each round after the arrival turn the
	-- engine heals the unit 15 in your land (COMBAT_HEAL_LAND_FRIENDLY); that
	-- is legitimate, only the promotion heal must be undone.
	local late = math.max(0, t - ((tonumber(s.turn) or t) + 1))
	local minD = math.max(0, 30 - 15 * late)
	local dmgOk = d <= 30 and d >= minD
	local ok = xp == 50 and nxt == 90 and n == #promos and n > 0 and dmgOk
	s.done = ok and "PASS" or "CHECK"
	Check("VET_RESTORE", s.done, VET_NAME .. ": XP " .. xp .. "/" .. nxt .. " (expected 50/90), promotions " .. n .. "/" .. #promos ..
		", damage " .. d .. " (expected " .. (late == 0 and "30" or (minD .. "-30: " .. late .. " round heal(s) of 15 in your land")) ..
		")" .. (ok and ": level, XP and damage kept" or ""))
end
end -- S12

-- ---------------------------------------------------------------------------
-- S13 (0.7): a unit in B's land (designer ruling "Send from the recipient's
-- land", FIXPLAN item 12). A Spearman of yours with full moves on a free
-- tile of B within 3 tiles of B's capital, selected by the camera. The
-- check FROM_LAND_RULES asks VEF's own picker rule right away: B's rows
-- open, every other row WRONG_TERRITORY. FROM_LAND passes at the next turn
-- start when that Spearman was sent to B this turn.
-- ---------------------------------------------------------------------------
do
CMD.scn_inland = function(me, p)
	local st = Session("FROM_LAND", me)
	if st == nil then return end
	local B = st.ally
	local capB = Capital(B)
	if capB == nil then Check("FROM_LAND", "CHECK", "B has no capital"); return end
	local plot = FindPlot(capB:GetX(), capB:GetY(), 3, OwnedBy(B), 1)
	if plot == nil then Check("FROM_LAND", "CHECK", "no free land tile of B within 3 tiles of its capital"); return end
	local u = NewUnit("scn_inland", me, "UNIT_SPEARMAN", plot)
	if u == nil then Check("FROM_LAND", "CHECK", "could not create the Spearman in B's land"); return end
	local full = FullMoves(u)
	st.s13 = { turn = Turn(), uid = u:GetID(), x = plot:GetX(), y = plot:GetY() }
	Focus(st, plot:GetX(), plot:GetY(), me, u:GetID(), p.stamp)
	ScnSave(st)
	local rows = EFV_DestinationRows(me, u, FT_EXP, EFV_Records.Load())
	local openB, wrong, bad = 0, 0, {}
	for _, r in ipairs(rows) do
		if r.recipientID == B then
			if r.ok then openB = openB + 1 else bad[#bad + 1] = "B's row: " .. table.concat(r.reasons or {}, "+") end
		elseif not r.ok and Has(r.reasons, "WRONG_TERRITORY") then
			wrong = wrong + 1
		else
			bad[#bad + 1] = PlayerName(r.recipientID) .. "'s row is not WRONG_TERRITORY"
		end
	end
	if not full then bad[#bad + 1] = "the Spearman lacks full moves" end
	if openB == 0 then bad[#bad + 1] = "no open row for B" end
	Check("FROM_LAND_RULES", #bad == 0 and "PASS" or "CHECK", "Spearman at " .. plot:GetX() .. "," .. plot:GetY() .. " in " ..
		PlayerName(B) .. "'s land: " .. openB .. " row(s) of B open, " .. wrong .. " other row(s) WRONG_TERRITORY" ..
		(#bad > 0 and (" PROBLEM: " .. table.concat(bad, "; ")) or ""))
	Check("FROM_LAND", "INFO", "send the selected Spearman as Expeditionary to " .. PlayerName(B) .. " this turn")
end

function EV.EvalS13(st, store, t, manual)
	local s = st.s13
	if type(s) ~= "table" then return end
	local rec = Newest(store, function(r)
		return r.senderID == st.me and r.forceType == FT_EXP and r.unitType == "UNIT_SPEARMAN" and r.sentTurn == s.turn
	end)
	if rec ~= nil then
		st.s13 = nil
		local ok = rec.recipientID == st.ally
		Check("FROM_LAND", ok and "PASS" or "CHECK", "record " .. rec.id .. ": the Spearman left B's land for " ..
			PlayerName(rec.recipientID) .. " (fee " .. Str(rec.feePaid) .. ", band " .. Str(rec.band) .. ", from your city at " ..
			Str(rec.originX) .. "," .. Str(rec.originY) .. ")")
	elseif not manual and t > s.turn then
		st.s13 = nil
		Check("FROM_LAND", "CHECK", "the Spearman standing in B's land was not sent to B in turn " .. Str(s.turn))
	end
end
end -- S13

-- ---------------------------------------------------------------------------
-- S14 (EFV_Dev 0.7.2-dev.1): mutiny death next to Barbarians. The 0.7.1
-- report: a Volunteer Swordsman in its 4th mutiny turn (80 damage) was killed
-- by a Barbarian Warrior, and the designer saw "a Warrior of mine, same VEF
-- tooltip" on its tile. Two copies of the situation, each a Swordsman of
-- yours in MUTINY at 80 damage (20 HP) as F's Volunteer (no open borders from
-- F, so the lapse cannot be cancelled), on neutral land next to F's land and
-- next to 2 Barbarian Warriors; one Warrior of C (your enemy) stands 2 tiles
-- from copy 1 (IDs are per player: it may share an ID number with yours).
-- Copy 1: leave it, the Barbarians kill it in their turn (or the mutiny's 20
-- at the next turn start does). Copy 2 (selected): attack a Barbarian with it
-- and it dies in the fight. MUT_DEATH (at the next turn start, per copy):
-- the record is closed, the Swordsman is gone, and no unit of yours and no
-- VEF record stands on or points at its tile. All unit IDs are logged.
-- ---------------------------------------------------------------------------
do
local function UnitsAt(x, y)
	local out = {}
	for pid = 0, 63 do
		pcall(function()
			if Players[pid] ~= nil then
				for _, u in Players[pid]:GetUnits():Members() do
					if u ~= nil and u:GetX() == x and u:GetY() == y then out[#out + 1] = u end
				end
			end
		end)
	end
	table.sort(out, function(a, b)
		if a:GetOwner() ~= b:GetOwner() then return a:GetOwner() < b:GetOwner() end
		return a:GetID() < b:GetID()
	end)
	return out
end

local function UnitTag(u)
	local id = u:GetID()
	return "P" .. Str(u:GetOwner()) .. "/" .. Str(id) .. " (slot " .. Str(id % 65536) .. ") " .. UnitTypeName(u)
end

-- A neutral free land tile next to F's land (a neighbour owned by F) with
-- two free neutral neighbours, at least minGap tiles from every plot of avoid.
local function MutDeathSpot(F, capF, avoid, minGap)
	for ring = 1, 8 do
		for _, plot in ipairs(Ring(capF:GetX(), capF:GetY(), ring)) do
			if FreeLand(plot) and Neutral(plot) and NotWonder(plot) then
				local far = true
				for _, a in ipairs(avoid) do
					if Dist(plot:GetX(), plot:GetY(), a:GetX(), a:GetY()) < minGap then far = false end
				end
				local byF, adj = false, {}
				for _, q in ipairs(Ring(plot:GetX(), plot:GetY(), 1)) do
					if PlotOwner(q) == F then byF = true end
					if FreeLand(q) and Neutral(q) then adj[#adj + 1] = q end
				end
				if far and byF and #adj >= 2 then return plot, adj[1], adj[2] end
			end
		end
	end
	return nil
end

CMD.scn_mutdeath = function(me, p)
	local st = Session("MUT_DEATH", me)
	if st == nil then return end
	local F, C, barb = st.friend, st.enemy, BarbarianID()
	local capF, cap = F and Capital(F), Capital(me)
	if F == nil or capF == nil or cap == nil or barb == nil then
		Check("MUT_DEATH", "CHECK", "F, its capital, your capital or the Barbarian player is missing"); return
	end
	if EFV_VolunteerBasis(me, F) ~= nil then
		Check("MUT_DEATH", "CHECK", "F grants your Volunteers access (" .. Str(EFV_VolunteerBasis(me, F)) ..
			"): the lapse would be cancelled; S14 needs F without open borders for you")
		return
	end
	local store = EFV_Records.Load()
	local copies, avoid, lines = {}, {}, {}
	for i = 1, 2 do
		local spot, b1p, b2p = MutDeathSpot(F, capF, avoid, 4)
		if spot == nil then break end
		avoid[#avoid + 1] = spot
		local u = NewUnit("scn_mutdeath", me, "UNIT_SWORDSMAN", spot)
		if u ~= nil then
			local b1 = NewUnit("scn_mutdeath", barb, "UNIT_WARRIOR", b1p)
			local b2 = NewUnit("scn_mutdeath", barb, "UNIT_WARRIOR", b2p)
			pcall(function() u:SetDamage(80) end)
			if i == 1 then pcall(function() UnitManager.FinishMoves(u) end) end   -- copy 1: nothing to order
			local t = Turn()
			local rec = MakeRecord(store, u, { force = FT_VOL, sender = me, recipient = F, basis = "FRIEND_OB", origin = cap,
				dest = capF, deployedTurn = t - 15 })
			if rec ~= nil then
				rec.state, rec.lapsed, rec.lapseReason, rec.lapseTurn = ST.MUT, 1, "PARTNER", t - 6
				rec.preLapseState, rec.graceTurnsLeft = ST.DEP, nil
				rec.lastDamage, rec.damage = UnitDamage(u), UnitDamage(u)
				EFV_Records.Touch(store)
				copies[#copies + 1] = { id = rec.id, uid = u:GetID(), x = spot:GetX(), y = spot:GetY(),
					b = { b1 and b1:GetID() or -1, b2 and b2:GetID() or -1 } }
				lines[#lines + 1] = "copy " .. i .. ": record " .. rec.id .. " " .. UnitTag(u) .. " at " .. spot:GetX() .. "," ..
					spot:GetY() .. " damage " .. UnitDamage(u) .. ", Barbarians " .. (b1 and UnitTag(b1) or "-") .. ", " ..
					(b2 and UnitTag(b2) or "-")
			end
		end
	end
	if #copies == 0 then
		EFV_Records.Commit(store)
		Check("MUT_DEATH", "CHECK", "no neutral tile with two free neutral neighbours next to " .. PlayerName(F) .. "'s land")
		return
	end
	local w = nil
	if C ~= nil then
		local c1 = Map.GetPlot(copies[1].x, copies[1].y)
		local wp = FindPlot(c1:GetX(), c1:GetY(), 3, function(q) return Neutral(q) end, 2)
		w = wp and NewUnit("scn_mutdeath", C, "UNIT_WARRIOR", wp) or nil
		if w ~= nil then lines[#lines + 1] = "enemy Warrior " .. UnitTag(w) .. " at " .. wp:GetX() .. "," .. wp:GetY() end
	end
	EFV_Records.Commit(store)
	st.s14 = { turn = Turn(), c = copies, barb = barb, w = w and w:GetID() or -1, wo = C or -1 }
	local last = copies[#copies]
	Focus(st, last.x, last.y, me, last.uid, p.stamp)
	ScnSave(st)
	for _, l in ipairs(lines) do Check("MUT_DEATH", "INFO", l) end
	Check("MUT_DEATH", "INFO", #copies .. " Volunteer Swordsman(s) of yours in MUTINY at 80 damage next to " .. PlayerName(F) ..
		"'s land: attack a Barbarian with the selected one (copy " .. #copies .. "), leave the other, then End Turn")
end

function EV.EvalS14(st, store, t, manual)
	local s = st.s14
	if type(s) ~= "table" or t <= s.turn then return end
	st.s14 = nil
	local c = Sub(st, "cleanup")
	for i, cp in ipairs(s.c or {}) do
		local rec = EFV_Records.Get(store, cp.id)
		local u = FindUnit(st.me, cp.uid)
		local here, bad = {}, {}
		for _, v in ipairs(UnitsAt(cp.x, cp.y)) do
			here[#here + 1] = UnitTag(v)
			if v:GetOwner() == st.me then bad[#bad + 1] = "a unit of yours stands there: " .. UnitTag(v) end
		end
		-- No record may point at the tile's units or at a Warrior of yours near it.
		for _, id in ipairs(EFV_Records.IDs(store)) do
			local r = EFV_Records.Get(store, id)
			if r ~= nil and r.onMapPlayerID ~= nil and r.id ~= cp.id then
				local ru = FindUnit(r.onMapPlayerID, r.onMapUnitID or -1)
				if ru ~= nil and ru:GetX() == cp.x and ru:GetY() == cp.y then
					bad[#bad + 1] = "record " .. r.id .. " tracks " .. UnitTag(ru) .. " on this tile"
				end
			end
		end
		if rec ~= nil then bad[#bad + 1] = "record " .. cp.id .. " still open (" .. Str(rec.state) .. ", unitType " .. Str(rec.unitType) .. ")" end
		if u ~= nil then bad[#bad + 1] = "the Swordsman " .. UnitTag(u) .. " is still alive" end
		Check("MUT_DEATH", #bad == 0 and "PASS" or "FAIL", "copy " .. i .. " (record " .. cp.id .. ", " .. cp.x .. "," .. cp.y ..
			"): " .. (#bad == 0 and "record closed, Swordsman gone" or table.concat(bad, "; ")) .. "; on the tile now: " ..
			(#here > 0 and table.concat(here, ", ") or "nothing"))
		for _, bid in ipairs(cp.b or {}) do
			local b = FindUnit(s.barb, bid)
			if b ~= nil then c[#c + 1] = { o = s.barb, u = bid, ut = UnitTypeName(b) } end
		end
	end
	local w = FindUnit(s.wo or -1, s.w or -1)
	if w ~= nil then c[#c + 1] = { o = s.wo, u = s.w, ut = UnitTypeName(w) } end
	Check("MUT_DEATH", "INFO", #c .. " test unit(s) are removed when you end this turn")
end
end -- S14

-- ---------------------------------------------------------------------------
-- S16 Break transit (EFV_Dev 1.0.2.2; VEF transit cancel, designer rulings
-- 2026-09-30). Your newest unit on its way out:
--   * to a city-state: its city at the destination is handed to C
--     (CityManager.TransferCity BY_GIFT, INTERFACES note 31; its only city,
--     so the city-state is eliminated, R3) -> mode CS_TAKEN;
--   * to a major: your declared friendship (and an alliance, if any) with it
--     ends (SetHasDeclaredFriendship false; SetHasAllied false is a no-op in
--     game, Session F T27) -> mode PARTNER_ENDED; a Warrior of yours
--     "VEF-BLOCK" is put on the unit's start tile when that tile is free
--     land, so the unit must take the nearest free tile (ring 1).
-- CANCEL (next turn start): the record is gone and exactly one new unit of
-- yours of that type stands within 5 tiles of the start tile, at ring 0
-- (not blocked) or ring 1 (blocked), with 0 moves; the expected refund is
-- half the fee (rounded down).
-- ---------------------------------------------------------------------------
do
local function MyUnitsOfType(pid, unitType)
	local out = {}
	pcall(function()
		for _, u in Players[pid]:GetUnits():Members() do
			if u ~= nil and UnitTypeName(u) == unitType then out[#out + 1] = u end
		end
	end)
	table.sort(out, function(a, b) return a:GetID() < b:GetID() end)
	return out
end

CMD.scn_cancel = function(me, p)
	local st = Session("CANCEL", me)
	if st == nil then return end
	local store = EFV_Records.Load()
	-- The S17 tracker records (st.s17.ids) are not real sends: skip them.
	local labels = type(st.s17) == "table" and st.s17.ids or {}
	local rec = Newest(store, function(r) return r.state == ST.OUT and r.senderID == me and not Has(labels, r.id) end)
	if rec == nil then
		Check("CANCEL_PREP", "CHECK", "send a unit first, then press S16")
		return
	end
	local ox, oy = rec.sentX, rec.sentY
	if ox == nil or oy == nil then ox, oy = rec.lastX, rec.lastY end
	local r = rec.recipientID
	local fee = math.max(0, math.floor(tonumber(rec.feePaid) or 0))
	local refund = math.floor(fee * EFV_Config.TRANSIT_CANCEL_REFUND_PCT / 100)
	local have = {}
	for _, u in ipairs(MyUnitsOfType(me, rec.unitType)) do have[#have + 1] = u:GetID() end
	local mode, blocked = nil, 0
	if IsCityStateID(r) then
		local city = CityManager.GetCityAt(rec.destX, rec.destY)
		local C = st.enemy
		if city == nil or C == nil or not Alive(C) then
			Check("CANCEL_PREP", "CHECK", "no city at the destination " .. Str(rec.destX) .. "," .. Str(rec.destY) ..
				" or no C to hand it to")
			return
		end
		local ok, err = pcall(function() CityManager.TransferCity(city, C, CityTransferTypes.BY_GIFT) end)
		Log("scn_cancel", "hand " .. PlayerName(r) .. "'s city at " .. rec.destX .. "," .. rec.destY .. " to " .. PlayerName(C) ..
			" ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))))
		if not ok then
			Check("CANCEL_PREP", "CHECK", "the city could not be handed to C: " .. Str(err))
			return
		end
		mode = "CS_TAKEN"
	else
		SetDiploPair("scn_cancel", me, r, "SetHasDeclaredFriendship", false)
		if Diplo(me, "HasAllied", r) then SetDiploPair("scn_cancel", me, r, "SetHasAllied", false) end
		mode = "PARTNER_ENDED"
		if EFV_PartnerBasis(me, r) ~= nil then
			Check("CANCEL_PREP", "CHECK", "partnership with " .. PlayerName(r) .. " could not be ended (still " ..
				Str(EFV_PartnerBasis(me, r)) .. "): use War")
		end
		local plot = (ox ~= nil and oy ~= nil) and Map.GetPlot(ox, oy) or nil
		if plot ~= nil and EFV_Spawn.DomainOf(rec.unitType) == "LAND" and FreeLand(plot) then
			local w = NewUnit("scn_cancel", me, "UNIT_WARRIOR", plot, "VEF-BLOCK")
			if w ~= nil then
				Hold(store, w)
				blocked = 1
			end
		end
	end
	st.s16 = { turn = Turn(), id = rec.id, force = rec.forceType, ox = ox, oy = oy, fee = fee, refund = refund,
		unitType = rec.unitType, have = have, mode = mode, blocked = blocked }
	if ox ~= nil and oy ~= nil then Focus(st, ox, oy, nil, nil, p.stamp) end
	EFV_Records.Commit(store)
	ScnSave(st)
	Check("CANCEL_PREP", "INFO", "record " .. rec.id .. " " .. Str(rec.forceType) .. " to " .. PlayerName(r) .. " " .. mode ..
		" origin " .. Str(ox) .. "," .. Str(oy) .. (blocked == 1 and " (start tile blocked by VEF-BLOCK)" or "") ..
		" expected refund " .. refund .. "; end the turn")
end

function EV.EvalS16(st, store, t, manual)
	local s = st.s16
	if type(s) ~= "table" or manual or t <= (tonumber(s.turn) or t) then return end
	st.s16 = nil
	local rec = EFV_Records.Get(store, s.id)
	if rec ~= nil then
		if rec.state == ST.RET and rec.returnReason == "CANCELLED" then
			Check("CANCEL", "INFO", "record " .. s.id .. " cancelled, but no free tile near the start tile or home: travelling home" ..
				" (arrives T" .. Str(rec.arrivalTurn) .. ", refund paid " .. Str(rec.refundPaid) .. ")")
		else
			Check("CANCEL", "CHECK", "record " .. s.id .. " still " .. Str(rec.state) .. " (expected the transit cancelled)")
		end
		return
	end
	local found = {}
	for _, u in ipairs(MyUnitsOfType(st.me, s.unitType)) do
		if not Has(s.have, u:GetID()) and s.ox ~= nil and Dist(s.ox, s.oy, u:GetX(), u:GetY()) <= 5 then found[#found + 1] = u end
	end
	if #found ~= 1 then
		Check("CANCEL", "CHECK", "record " .. s.id .. " closed, but " .. #found .. " new " .. Str(s.unitType) ..
			" of yours within 5 tiles of " .. Str(s.ox) .. "," .. Str(s.oy) .. " (expected exactly 1)")
		return
	end
	local u = found[1]
	local ring = Dist(s.ox, s.oy, u:GetX(), u:GetY())
	local want = (tonumber(s.blocked) == 1) and 1 or 0
	local moves = -1
	pcall(function() moves = u:GetMovesRemaining() end)
	Check("CANCEL", (ring == want and moves == 0) and "PASS" or "CHECK", "record " .. s.id .. " " .. Str(s.mode) ..
		": back at " .. u:GetX() .. "," .. u:GetY() .. " ring " .. ring .. " (expected ring " .. want .. ") moves=" .. moves ..
		" (expected 0) refund expected " .. Str(s.refund) .. " of fee " .. Str(s.fee))
end
end -- S16 Break transit

-- ---------------------------------------------------------------------------
-- End-of-turn cleanup (0.7, FIXPLAN item 10): units queued in st.cleanup
-- ({ o, u, ut }) are removed at GameEvents.OnGameTurnEnded, identity-checked
-- by type, never at a player's PlayerTurnStartComplete.
-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.3.2: records queued in st.cleanRecs (record IDs; the S17
-- tracker records) are deleted first, through EFV's own record API.
do
local function DevCleanRecords(st, turn)
	local ids = st.cleanRecs
	if type(ids) ~= "table" or #ids == 0 then return false end
	local store = EFV_Records.Load()
	local n = 0
	for _, id in ipairs(ids) do
		if EFV_Records.Get(store, tonumber(id) or -1) ~= nil then
			EFV_Records.Delete(store, tonumber(id))
			n = n + 1
		end
	end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.cleanRecs = nil
	Log("scn", "end of turn " .. Str(turn) .. ": removed " .. n .. " of " .. #ids .. " test record(s)")
	return true
end

function EV.DevCleanup(turn)
	local st = ScnLoad()
	local changed = DevCleanRecords(st, turn)
	local c = st.cleanup
	if type(c) ~= "table" or #c == 0 then
		if changed then ScnSave(st) end
		return
	end
	local n = 0
	for _, e in ipairs(c) do
		local o = tonumber(e.o) or -1
		local u = FindUnit(o, tonumber(e.u) or -1)
		if u ~= nil and (e.ut == nil or UnitTypeName(u) == e.ut) then
			if pcall(function() Players[o]:GetUnits():Destroy(u) end) then n = n + 1 end
		end
	end
	st.cleanup = nil
	ScnSave(st)
	Log("scn", "end of turn " .. Str(turn) .. ": removed " .. n .. " of " .. #c .. " test unit(s)")
end
end -- End-of-turn cleanup

-- ===========================================================================
-- Workshop screenshots (EFV_Dev 0.7.0-dev.1; workshop/SCREENSHOTS.md Part B).
-- CMD.shot1 .. shot5: each runs S0 itself when needed (ShotPrep), removes
-- what the previous Shot button created (ShotReset; list in st.shot), builds
-- its scene and writes st.focus with the extra fields the panel reads:
-- open ("PICKER" | "TRACKER" | "CAPTURE"), ft (picker force type), zoom
-- (UI.SetMapZoom value, 0 = closest), tx / ty (Shot 4's target city).
-- One line each: [EFV][CHECK] SHOTn PASS|CHECK ...
-- ===========================================================================
local ZOOM_CLOSE, ZOOM_MID
do
ZOOM_CLOSE, ZOOM_MID = 0.25, 0.5

local function ShotList(st)
	if type(st.shot) ~= "table" then st.shot = {} end
	if type(st.shot.recs) ~= "table" then st.shot.recs = {} end
	if type(st.shot.units) ~= "table" then st.shot.units = {} end
	return st.shot
end

local function ShotUnit(st, u)
	if u == nil then return end
	local l = ShotList(st)
	l.units[#l.units + 1] = { o = u:GetOwner(), u = u:GetID(), ut = UnitTypeName(u) }
end

local function ShotRec(st, rec)
	if rec == nil then return end
	local l = ShotList(st)
	l.recs[#l.recs + 1] = rec.id
end

-- Removes every record and unit the previous Shot created: the records
-- first (committed, so VEF never sees a tracked unit vanish), then the units.
-- Cities founded for a shot and a captured city stay.
local function ShotReset(st)
	local l = ShotList(st)
	local store = EFV_Records.Load()
	local doomed = {}
	local nr = 0
	for _, id in ipairs(l.recs) do
		local rec = EFV_Records.Get(store, tonumber(id) or -1)
		if rec ~= nil then
			local u = RecUnit(rec)
			if u ~= nil then doomed[#doomed + 1] = { o = u:GetOwner(), u = u:GetID(), ut = UnitTypeName(u) } end
			EFV_Records.Delete(store, rec.id)
			nr = nr + 1
		end
	end
	for _, e in ipairs(l.units) do doomed[#doomed + 1] = e end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	local nu = 0
	for _, e in ipairs(doomed) do
		local o = tonumber(e.o) or -1
		local u = FindUnit(o, tonumber(e.u) or -1)
		if u ~= nil and (e.ut == nil or UnitTypeName(u) == e.ut) then
			if pcall(function() Players[o]:GetUnits():Destroy(u) end) then nu = nu + 1 end
		end
	end
	st.shot = { recs = {}, units = {} }
	Log("shot", "reset: " .. nr .. " record(s) and " .. nu .. " unit(s) of the previous shot removed")
end

-- Session for a Shot: S0 when needed (its three Swordsmen are removed with
-- the reset), the wars renewed, the Volunteer basis with B renewed, the
-- previous shot removed, gold at least 2000. Returns st or nil.
local function ShotPrep(cmd, me, p)
	local st = ScnLoad()
	local ranSetup = false
	if st.ally == nil or st.me ~= me then
		CMD.scn_setup(me, p)
		ranSetup = true
		st = ScnLoad()
		if st.ally == nil or st.me ~= me then
			Check(cmd, "CHECK", "setup failed: see the SETUP line")
			return nil
		end
	end
	st = Session(cmd, me)
	if st == nil then return nil end
	if EFV_VolunteerBasis(me, st.ally) == nil then EnsurePartner(cmd, me, st.ally) end
	if type(st.setupUnits) == "table" then
		local l = ShotList(st)
		for _, e in ipairs(st.setupUnits) do l.units[#l.units + 1] = e end
		st.setupUnits = nil
	end
	ShotReset(st)
	pcall(function()
		local t = Players[me]:GetTreasury()
		local g = t:GetGoldBalance()
		if g < 2000 then t:ChangeGoldBalance(2000 - g) end
	end)
	-- Screenshots: give every major civ and city-state at least 10 Iron so no
	-- "won't heal" (strategic resource) warning shows on lent Legions or
	-- Swordsmen, whoever owns them.
	local iron = GameInfo.Resources["RESOURCE_IRON"]
	if iron ~= nil then
		for _, pid in ipairs(SortedIDs(function(i) return IsMajorID(i) or IsCityStateID(i) end)) do
			pcall(function()
				local r = Players[pid]:GetResources()
				local have = r:GetResourceAmount(iron.Index)
				if have < 10 then r:ChangeResourceAmount(iron.Index, 10 - have) end
			end)
		end
	end
	return st
end

local function ShotName(rec)
	local ok, s = pcall(EFV_UnitDisplayName, rec.unitType, rec.veteranName)
	if ok and type(s) == "string" and s ~= "" then return s end
	return Str(rec.unitType)
end

-- The designer plays Rome: the Shot units you send in place of a Swordsman
-- are Roman Legions (any owner can get one by script). Units other civs send
-- you stay non-unique (Shot 3's received row). Legion in GS: 10 Iron to
-- build (S0 grants 10).
local SHOT_UT = "UNIT_ROMAN_LEGION"

-- Shot 1 grey rows: EFV_DestinationRows lists only civs with a partner basis
-- (EFV_PartnerBasis), so a civ you only met never gets a row. true: F and D
-- are declared friends WITHOUT open borders (greyed "needs open borders");
-- false: F and D are met only (no friendship, so no row in the picker).
local SHOT1_GREY_FRIENDS = true

-- Shot 1 Send picker: "Legio VEF" selected next to your capital, the
-- Volunteer picker opened by the panel. B (friend with open borders to you)
-- is the one Volunteer partner; F and D (the next major) are met, at war
-- with C, and give you no open borders, so their rows are greyed. B and F
-- get a second city when they have one only.
CMD.shot1 = function(me, p)
	local st = ShotPrep("SHOT1", me, p)
	if st == nil then return end
	local cap = Capital(me)
	local notes = {}
	for _, pid in ipairs({ st.ally, st.friend }) do
		local c0 = Capital(pid)
		if c0 ~= nil and #Cities(pid) < 2 then
			local c, msg = FoundCityFor(pid, c0:GetX(), c0:GetY())
			notes[#notes + 1] = msg
			if c ~= nil then RevealCity(me, c, nil, 5) end
		end
	end
	local D = nil
	for _, i in ipairs(SortedIDs(function(i) return i ~= me and IsMajorID(i) and HasCity(i) end)) do
		if D == nil and i ~= st.ally and i ~= st.friend and i ~= st.enemy then D = i end
	end
	if D == nil then notes[#notes + 1] = "NO 4th AI civ for D: start a game with at least 5 civs" end
	for _, pid in ipairs({ st.friend, D or false }) do
		if pid then
			MeetPair(me, pid)
			if st.enemy ~= nil then MeetPair(pid, st.enemy); DeclareWar(pid, st.enemy) end
			local friend = Diplo(me, "HasDeclaredFriendship", pid)
			if friend ~= SHOT1_GREY_FRIENDS then SetDiploPair("shot1", me, pid, "SetHasDeclaredFriendship", SHOT1_GREY_FRIENDS) end
			local c0 = Capital(pid)
			if c0 ~= nil then RevealCity(me, c0, nil, 5) end
		end
	end
	local u = NewUnit("shot1", me, SHOT_UT, FindPlot(cap:GetX(), cap:GetY(), 2, OwnedBy(me), 1), "Legio VEF")
	if u == nil then
		ScnSave(st)
		Check("SHOT1", "CHECK", "could not create the Legion next to your capital")
		return
	end
	local full = FullMoves(u)
	ShotUnit(st, u)
	Focus(st, cap:GetX(), cap:GetY(), me, u:GetID(), p.stamp)
	st.focus.open, st.focus.ft, st.focus.zoom = "PICKER", FT_VOL, ZOOM_MID
	ScnSave(st)
	local rows = EFV_DestinationRows(me, u, FT_VOL, EFV_Records.Load())
	local okCivs, greySeen, extra = {}, {}, {}
	local nOk, nGrey, greyText = 0, 0, {}
	for _, r in ipairs(rows) do
		if r.ok then
			if not okCivs[r.recipientID] then okCivs[r.recipientID] = true; nOk = nOk + 1 end
		else
			if not greySeen[r.recipientID] then
				greySeen[r.recipientID] = true
				nGrey = nGrey + 1
				greyText[#greyText + 1] = PlayerName(r.recipientID) .. " " .. table.concat(r.reasons or {}, "+")
			end
			for _, why in ipairs(r.reasons or {}) do if why ~= "VOL_NEEDS_ACCESS" then extra[#extra + 1] = why end end
		end
	end
	table.sort(greyText)
	local want = SHOT1_GREY_FRIENDS and 2 or 0
	local ok = full and nOk == 1 and okCivs[st.ally] and nGrey == want and #extra == 0 and D ~= nil
	Check("SHOT1", ok and "PASS" or "CHECK", "'Legio VEF' next to your capital (full moves " .. tostring(full) ..
		"); Volunteer picker rows " .. #rows .. ", partner civs " .. nOk .. " (" .. PlayerName(st.ally) .. "), greyed civs " .. nGrey ..
		(#greyText > 0 and (" (" .. table.concat(greyText, ", ") .. ")") or "") .. (#notes > 0 and ("; " .. table.concat(notes, "; ")) or ""))
end

-- Shot 2 Arrival: your Expeditionary Legion (B's colours) and your
-- Volunteer Legion (your colours) next to B's capital, both recorded
-- DEPLOYED this turn, two "Unit Arrived" notifications.
CMD.shot2 = function(me, p)
	local st = ShotPrep("SHOT2", me, p)
	if st == nil then return end
	local B = st.ally
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then ScnSave(st); Check("SHOT2", "CHECK", "your capital or B's capital is missing"); return end
	RevealCity(me, capB, nil, 5)
	local store = EFV_Records.Load()
	local e = NewUnit("shot2", B, SHOT_UT, FindPlot(capB:GetX(), capB:GetY(), 2, OwnedBy(B), 1))
	if e == nil then ScnSave(st); Check("SHOT2", "CHECK", "no free tile of B next to its capital"); return end
	ShotUnit(st, e)
	local recE = MakeRecord(store, e, { force = FT_EXP, sender = me, recipient = B, basis = st.partner or "FRIEND", origin = cap,
		dest = capB, duration = EFV_Config.EXPEDITIONARY_DURATION })
	local p2 = FindPlot(e:GetX(), e:GetY(), 1, OwnedBy(B), 1) or FindPlot(capB:GetX(), capB:GetY(), 2, OwnedBy(B), 1)
	local v = NewUnit("shot2", me, SHOT_UT, p2)
	ShotUnit(st, v)
	local recV = nil
	if v ~= nil then
		recV = MakeRecord(store, v, { force = FT_VOL, sender = me, recipient = B, basis = st.basis or "FRIEND_OB", origin = cap, dest = capB })
	end
	Hold(store, e)
	EFV_Records.Commit(store)
	for _, rec in ipairs({ recE or false, recV or false }) do
		if rec then
			ShotRec(st, rec)
			EFV_Notify.Queue(me, EFV_Config.NOTIF.ARRIVED, "LOC_" .. EFV_Config.NOTIF.ARRIVED,
				{ ShotName(rec), EFV_PlayerName(me), EFV_CityName(capB) }, rec.lastX, rec.lastY, { recordID = rec.id, kind = "ARRIVED" })
		end
	end
	EFV_Notify.Flush()
	local mx, my = e:GetX(), e:GetY()
	if v ~= nil then mx, my = math.floor((e:GetX() + v:GetX()) / 2), math.floor((e:GetY() + v:GetY()) / 2) end
	Focus(st, mx, my, nil, nil, p.stamp)
	st.focus.zoom = ZOOM_CLOSE
	ScnSave(st)
	local ok = recE ~= nil and recV ~= nil and e:GetOwner() == B and v:GetOwner() == me
	Check("SHOT2", ok and "PASS" or "CHECK", "Expeditionary " .. (recE and ("record " .. recE.id) or "MISSING") .. " (owner " ..
		PlayerName(e:GetOwner()) .. "), Volunteers " .. (recV and ("record " .. recV.id) or "MISSING") .. " next to " .. PlayerName(B) ..
		"'s capital; Unit Arrived notifications sent")
end

-- Shot 3 Tracker: six records in different states (Grace first), one Grace
-- notification, the tracker opened by the panel (LuaEvents.EFV_TrackerOpen).
CMD.shot3 = function(me, p)
	local st = ShotPrep("SHOT3", me, p)
	if st == nil then return end
	local B, F, cs = st.ally, st.friend, st.cs
	local cap, capB, capF, capCS = Capital(me), Capital(B), Capital(F), Capital(cs)
	if cap == nil or capB == nil or capF == nil or capCS == nil then
		ScnSave(st)
		Check("SHOT3", "CHECK", "a capital of you, B, F or the city-state is missing")
		return
	end
	local store = EFV_Records.Load()
	local T = Turn()
	local EXP_D = EFV_Config.EXPEDITIONARY_DURATION
	local made, why = {}, {}
	local function Add(label, rec, u)
		if u ~= nil then ShotUnit(st, u) end
		if rec ~= nil then ShotRec(st, rec); made[#made + 1] = label else why[#why + 1] = label .. " failed" end
		return rec
	end
	-- 1 Expeditionary to B in Grace (3 turns), on neutral land near B's border
	local spot = FindPlot(capB:GetX(), capB:GetY(), 8, Neutral, 3)
	local u1 = NewUnit("shot3", B, SHOT_UT, spot)
	local r1 = nil
	if u1 ~= nil then
		r1 = MakeRecord(store, u1, { force = FT_EXP, sender = me, recipient = B, basis = st.partner or "FRIEND", origin = cap,
			dest = capB, duration = EXP_D, deployedTurn = T - EXP_D - 2 })
	end
	if r1 ~= nil then
		r1.state, r1.graceTurnsLeft, r1.lastDamage = ST.GRACE, 3, nil
		Hold(store, u1)
		RevealCity(me, spot, nil, 5)
	end
	Add("Grace", r1, u1)
	-- 2 Expeditionary to F, Deployed, 14 turns left
	local u2 = NewUnit("shot3", F, "UNIT_ARCHER", FindPlot(capF:GetX(), capF:GetY(), 3, OwnedBy(F), 1))
	local r2 = nil
	if u2 ~= nil then
		r2 = MakeRecord(store, u2, { force = FT_EXP, sender = me, recipient = F, basis = EFV_PartnerBasis(me, F) or "FRIEND",
			origin = cap, dest = capF, duration = EXP_D, deployedTurn = T - 6 })
	end
	Add("Deployed (F)", r2, u2)
	-- 3 Volunteers in B's land, Deployed
	local u3 = NewUnit("shot3", me, "UNIT_SPEARMAN", FindPlot(capB:GetX(), capB:GetY(), 3, OwnedBy(B), 1))
	local r3 = nil
	if u3 ~= nil then
		r3 = MakeRecord(store, u3, { force = FT_VOL, sender = me, recipient = B, basis = st.basis or "FRIEND_OB",
			origin = cap, dest = capB, deployedTurn = T - 12 })
	end
	Add("Volunteers", r3, u3)
	-- 4 City-State unit Returning, 2 turns (the fields EFV_Transit's EnterReturning sets)
	local u4 = NewUnit("shot3", cs, "UNIT_WARRIOR", FindPlot(capCS:GetX(), capCS:GetY(), 3, OwnedByAny({ -1, cs }), 1))
	local r4 = nil
	if u4 ~= nil then
		r4 = MakeRecord(store, u4, { force = FT_CS, sender = me, recipient = cs, basis = "CITY_STATE", origin = cap, dest = capCS,
			duration = EFV_Config.CS_EXPEDITIONARY_DURATION, deployedTurn = T - 10 })
	end
	if r4 ~= nil then
		if EFV_Units.Remove(u4) then
			u4 = nil
			r4.state, r4.arrivalTurn, r4.transitTurns, r4.band = ST.RET, T + 2, 2, 2
			r4.returnCityID, r4.returnX, r4.returnY, r4.returnReason = cap:GetID(), cap:GetX(), cap:GetY(), "EXPIRED"
			r4.onMapPlayerID, r4.onMapUnitID, r4.graceTurnsLeft, r4.lastDamage, r4.lapsed = nil, nil, nil, nil, 0
		else
			why[#why + 1] = "City-State unit not removed"
		end
	end
	Add("Returning (CS)", r4, u4)
	-- 5 Expeditionary to B, Outbound, 3 turns (the S9 pattern)
	local destB = Cities(B)[2] or capB
	local u5 = NewUnit("shot3", me, "UNIT_HORSEMAN", FindPlot(cap:GetX(), cap:GetY(), 3, OwnedBy(me), 1))
	local r5 = nil
	if u5 ~= nil then
		r5 = MakeRecord(store, u5, { force = FT_EXP, state = ST.OUT, sender = me, recipient = B, basis = st.partner or "FRIEND",
			origin = cap, dest = destB, duration = EXP_D })
	end
	if r5 ~= nil then
		r5.sentTurn, r5.arrivalTurn, r5.transitTurns, r5.band = T, T + 3, 3, 3
		if EFV_Units.Remove(u5) then u5 = nil else why[#why + 1] = "Horseman not removed" end
	end
	Add("Outbound", r5, u5)
	-- 6 received from B, Deployed, 12 turns left
	local u6 = NewUnit("shot3", me, "UNIT_SWORDSMAN", FindPlot(cap:GetX(), cap:GetY(), 3, OwnedBy(me), 1))
	local r6 = nil
	if u6 ~= nil then
		r6 = MakeRecord(store, u6, { force = FT_EXP, sender = B, recipient = me, basis = st.partner or "FRIEND", origin = capB,
			dest = cap, duration = EXP_D, deployedTurn = T - 8 })
	end
	Add("Received", r6, u6)
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	if r1 ~= nil then
		EFV_Notify.Queue(me, EFV_Config.NOTIF.GRACE, "LOC_" .. EFV_Config.NOTIF.GRACE .. "_SENDER",
			{ ShotName(r1), EFV_PlayerName(B), 3 }, u1:GetX(), u1:GetY(), { recordID = r1.id, kind = "GRACE" })
		EFV_Notify.Flush()
		Focus(st, u1:GetX(), u1:GetY(), nil, nil, p.stamp)
	else
		Focus(st, capB:GetX(), capB:GetY(), nil, nil, p.stamp)
	end
	st.focus.open, st.focus.zoom = "TRACKER", ZOOM_MID
	ScnSave(st)
	local alerts = 0
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local r = EFV_Records.Get(store, id)
		if r ~= nil and r.senderID == me and (r.state == ST.GRACE or r.state == ST.MUT) then alerts = alerts + 1 end
	end
	Check("SHOT3", (#made == 6 and #why == 0 and alerts == 1) and "PASS" or "CHECK", #made .. " of 6 records (" ..
		table.concat(made, ", ") .. "), alerts " .. alerts .. (#why > 0 and (" PROBLEM: " .. table.concat(why, "; ")) or ""))
end

-- Shot 4 Entrust: the S11 scene; the panel orders Tank 1 to attack the city
-- (the base MOVE_TO with ATTACK), waits for the capture screen and expands
-- the Entrust list (LuaEvents.EFV_EntrustExpand).
CMD.shot4 = function(me, p)
	local st = ShotPrep("SHOT4", me, p)
	if st == nil then return end
	local city, tanks, note, weak = BuildEntrustScene("shot4", me, st, 5)
	if city == nil then ScnSave(st); Check("SHOT4", "CHECK", Str(tanks)); return end
	for _, t in ipairs(tanks) do ShotUnit(st, t) end
	local t1 = tanks[1]
	if t1 ~= nil then
		Focus(st, city:GetX(), city:GetY(), me, t1:GetID(), p.stamp)
		st.focus.open, st.focus.tx, st.focus.ty, st.focus.zoom = "CAPTURE", city:GetX(), city:GetY(), ZOOM_MID
	else
		Focus(st, city:GetX(), city:GetY(), nil, nil, p.stamp)
	end
	ScnSave(st)
	Check("SHOT4", #tanks == 3 and "PASS" or "CHECK", #tanks .. " Tanks next to " .. PlayerName(st.enemy) .. "'s city at " ..
		city:GetX() .. "," .. city:GetY() .. " (" .. Str(note) .. "; " .. Str(weak) .. "); the panel orders Tank 1 to attack")
end

-- Shot 5 Mutiny: your Expeditionary Legion (B's) on neutral land near
-- B's border, MUTINY with 40 damage, one Mutiny notification.
CMD.shot5 = function(me, p)
	local st = ShotPrep("SHOT5", me, p)
	if st == nil then return end
	local B = st.ally
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then ScnSave(st); Check("SHOT5", "CHECK", "your capital or B's capital is missing"); return end
	local spot = FindPlot(capB:GetX(), capB:GetY(), 8, Neutral, 3)
	if spot == nil then ScnSave(st); Check("SHOT5", "CHECK", "no free neutral land 3-8 tiles from B's capital"); return end
	RevealCity(me, spot, nil, 5)
	local u = NewUnit("shot5", B, SHOT_UT, spot)
	if u == nil then ScnSave(st); Check("SHOT5", "CHECK", "could not create the Legion"); return end
	ShotUnit(st, u)
	pcall(function() u:SetDamage(40) end)
	local store = EFV_Records.Load()
	local D = EFV_Config.EXPEDITIONARY_DURATION
	local rec = MakeRecord(store, u, { force = FT_EXP, sender = me, recipient = B, basis = st.partner or "FRIEND", origin = cap,
		dest = capB, duration = D, deployedTurn = Turn() - D - EFV_Config.GRACE_TURNS - 2 })
	if rec ~= nil then
		rec.state, rec.graceTurnsLeft, rec.lastDamage = ST.MUT, nil, 40
		ShotRec(st, rec)
	end
	Hold(store, u)
	EFV_Records.Commit(store)
	if rec ~= nil then
		EFV_Notify.Queue(me, EFV_Config.NOTIF.MUTINY, "LOC_" .. EFV_Config.NOTIF.MUTINY .. "_SENDER",
			{ ShotName(rec), 3, EFV_PlayerName(B) }, u:GetX(), u:GetY(), { recordID = rec.id, kind = "MUTINY" })
		EFV_Notify.Flush()
	end
	Focus(st, spot:GetX(), spot:GetY(), nil, nil, p.stamp)
	st.focus.zoom = ZOOM_CLOSE
	ScnSave(st)
	local ok = rec ~= nil and UnitDamage(u) == 40 and PlotOwner(spot) < 0 and u:GetOwner() == B
	Check("SHOT5", ok and "PASS" or "CHECK", "record " .. Str(rec and rec.id) .. " MUTINY, damage " .. UnitDamage(u) .. ", owner " ..
		PlayerName(u:GetOwner()) .. " at " .. spot:GetX() .. "," .. spot:GetY() .. " (tile owner " .. PlotOwner(spot) .. ")")
end

-- S15 Receive forces (EFV_Dev 0.7.4-dev.3): B is the SENDER, you the
-- RECIPIENT. Two records DEPLOYED this turn next to your capital, no transit:
-- an Expeditionary Swordsman of B's now owned by you (20-turn timer) and a
-- Volunteer Swordsman owned by B in your land (held until the next turn
-- start). B's Volunteer basis toward you: friendship + open borders from
-- you to B (EnsurePartner with the roles swapped). S0 runs when needed; the
-- previous Shot / S15 scene is removed first (ShotReset, not S0's units).
-- The panel opens the tracker (focus open = TRACKER).
CMD.scn_receive = function(me, p)
	local st = ScnLoad()
	if st.ally == nil or st.me ~= me then CMD.scn_setup(me, p) end
	st = Session("RECEIVE", me)
	if st == nil then return end
	local B = st.ally
	if EFV_VolunteerBasis(B, me) == nil then EnsurePartner("RECEIVE", B, me) end
	ShotReset(st)
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then ScnSave(st); Check("RECEIVE", "CHECK", "your capital or B's capital is missing"); return end
	local store = EFV_Records.Load()
	local e = NewUnit("receive", me, "UNIT_SWORDSMAN", FindPlot(cap:GetX(), cap:GetY(), 2, OwnedBy(me), 1))
	ShotUnit(st, e)
	local recE = nil
	if e ~= nil then
		recE = MakeRecord(store, e, { force = FT_EXP, sender = B, recipient = me, basis = EFV_PartnerBasis(B, me) or "FRIEND",
			origin = capB, dest = cap, duration = EFV_Config.EXPEDITIONARY_DURATION })
	end
	local p2 = (e and FindPlot(e:GetX(), e:GetY(), 1, OwnedBy(me), 1)) or FindPlot(cap:GetX(), cap:GetY(), 2, OwnedBy(me), 1)
	local v = NewUnit("receive", B, "UNIT_SWORDSMAN", p2)
	ShotUnit(st, v)
	local recV = nil
	if v ~= nil then
		recV = MakeRecord(store, v, { force = FT_VOL, sender = B, recipient = me, basis = EFV_VolunteerBasis(B, me) or "FRIEND_OB",
			origin = capB, dest = cap })
		Hold(store, v)
	end
	EFV_Records.Commit(store)
	ShotRec(st, recE)
	ShotRec(st, recV)
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	st.focus.open, st.focus.zoom = "TRACKER", ZOOM_MID
	ScnSave(st)
	local function Row(label, rec, u)
		if rec == nil then return label .. " MISSING" end
		return label .. " record " .. rec.id .. " " .. Str(rec.state) .. " sender " .. PlayerName(rec.senderID) .. " recipient " ..
			PlayerName(rec.recipientID) .. " owner " .. PlayerName(u:GetOwner()) .. " basis " .. Str(rec.accessBasis) ..
			" at " .. u:GetX() .. "," .. u:GetY() .. (rec.durationTurns and (" timer " .. rec.durationTurns) or "")
	end
	local ok = recE ~= nil and recV ~= nil and e:GetOwner() == me and v:GetOwner() == B and EFV_VolunteerBasis(B, me) ~= nil
	Check("RECEIVE", ok and "PASS" or "CHECK", Row("Expeditionary", recE, e) .. "; " .. Row("Volunteers", recV, v) ..
		"; next to your capital " .. EFV_CityName(cap))
end
end -- Workshop screenshots

-- ---------------------------------------------------------------------------
-- Eligibility tests T1 / T2 (EFV_Dev 1.0.1.3; VEF 1.0.1 common-war fix;
-- T2 City-State lines: EFV_Dev 1.0.2.1, VEF 1.0.2 City-State rule).
-- From a fresh game after founding the capital (Large map, 8 civs): every
-- major and city-state meets every other, two Swordsmen with full moves
-- next to your capital, and the other majors with a city (ascending ID) get
-- the roles below. Then VEF's own EFV_DestinationRows (gameplay rules) says
-- for each civ whether its Expeditionary / Volunteer rows are ALLOWED, GREY
-- (with the eligibility reasons) or ABSENT, against the expected result.
-- T2 also checks the City-State picker (VEF 1.0.2: any met city-state you
-- are not at war with, no shared enemy needed) for the city-states with a
-- city (ascending ID): CSN at war with nobody (ALLOWED), CSX at war with you
-- (GREY:AT_WAR_WITH_RECIPIENT), any further one met only (CSO, ALLOWED).
-- One line per civ and city-state, then a summary:
--   [EFV][CHECK] ELIG_T1|ELIG_T2 PASS|FAIL|CHECK T<turn> <ROLE>=<civ> | facts | Expeditionary ... | Volunteers ...
--   [EFV][CHECK] ELIG_T2 PASS|FAIL|CHECK T<turn> <CS ROLE>=<city-state> | facts | City-State ...
--   [EFV][CHECK] ELIG_T1|ELIG_T2 <verdict> T<turn> summary (gameplay rules): ...
-- The panel repeats the check with the UI rules (ELIG_T1_UI / ELIG_T2_UI).
-- FAIL = the picker disagrees with the rule; CHECK = the setup did not come
-- out as planned (e.g. the engine pulled an ally into your war), so the
-- verdict says nothing about VEF. Wars are only declared for the roles that
-- need one, before any friendship or alliance, and nobody makes peace.
-- ---------------------------------------------------------------------------
local CIVIC_ALLY
do
local ELIG_CODES = { NOT_PARTNER = true, VOL_NEEDS_ACCESS = true, CS_NOT_MET = true,
	AT_WAR_WITH_RECIPIENT = true, NO_COMMON_WAR = true }
CIVIC_ALLY = "CIVIC_CIVIL_SERVICE"

-- war: at war with E. peace: at war with nobody (majors / city-states).
local ELIG_TESTS = {
	T1 = { title = "Volunteer partners", roles = {
		{ r = "E",  enemy = true,               exp = "ABSENT",  vol = "ABSENT" },
		{ r = "A",  ally = true, war = true,    exp = "ALLOWED", vol = "ALLOWED" },
		{ r = "F",  friend = true, war = true,  exp = "ALLOWED", vol = "GREY:VOL_NEEDS_ACCESS" },
		{ r = "FO", friend = true, ob = true, war = true, exp = "ALLOWED", vol = "ALLOWED" },
		{ r = "N",  war = true,                 exp = "ABSENT",  vol = "ABSENT" },
	} },
	T2 = { title = "Shared enemy", roles = {
		{ r = "E",   enemy = true,              exp = "ABSENT",  vol = "ABSENT" },
		{ r = "FW",  friend = true, war = true, exp = "ALLOWED", vol = "GREY:VOL_NEEDS_ACCESS" },
		{ r = "FOW", friend = true, ob = true, war = true, exp = "ALLOWED", vol = "ALLOWED" },
		{ r = "FN",  friend = true, peace = true, exp = "GREY:NO_COMMON_WAR", vol = "GREY:NO_COMMON_WAR+VOL_NEEDS_ACCESS" },
		{ r = "FON", friend = true, ob = true, peace = true, exp = "GREY:NO_COMMON_WAR", vol = "GREY:NO_COMMON_WAR" },
		{ r = "NW",  war = true,                exp = "ABSENT",  vol = "ABSENT" },
		{ r = "AN",  ally = true, peace = true, exp = "GREY:NO_COMMON_WAR", vol = "GREY:NO_COMMON_WAR" },
	}, cs = {
		{ r = "CSN", peace = true,  cs = "ALLOWED" },
		{ r = "CSX", youWar = true, cs = "GREY:AT_WAR_WITH_RECIPIENT" },
	} },
}
-- Majors beyond the roles: met only, never partners.
local ELIG_OTHER = { r = "OTHER", exp = "ABSENT", vol = "ABSENT" }
-- City-states beyond the T2 roles: met only, not at war with you.
local ELIG_OTHER_CS = { r = "CSO", cs = "ALLOWED" }

local function IsRealPlayer(i) return IsMajorID(i) or IsCityStateID(i) end

-- Real enemies of pid (majors and city-states; the engine's permanent wars
-- with the Free Cities and the barbarians never count, VEF 1.0.1).
local function RealWars(pid)
	local out = {}
	for _, e in ipairs(SortedIDs(IsRealPlayer)) do
		if e ~= pid and AtWar(pid, e) then out[#out + 1] = e end
	end
	return out
end

-- The picker result for pid from EFV_DestinationRows rows: "ALLOWED" (a
-- row is open), "ABSENT" (no row) or "GREY:<eligibility codes, sorted>" of
-- its row with the fewest reasons; other codes (NOT_REVEALED, GOLD, unit
-- reasons) are returned separately.
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

-- PASS when equal; CHECK when an expected open row is greyed only by other
-- codes (setup: not revealed, gold, unit); FAIL otherwise.
local function EligCompare(want, got)
	if want == got then return "PASS" end
	if want == "ALLOWED" and got == "GREY:" then return "CHECK" end
	return "FAIL"
end

local function YesNo(b) return b and "yes" or "no" end

-- Facts of pid toward you, and what does not match its role (nil = all fine).
local function EligFacts(me, pid, role, E)
	local ally = Diplo(me, "HasAllied", pid)
	local friend = Diplo(me, "HasDeclaredFriendship", pid)
	local okOB, ob = pcall(EFV_HasOpenBordersFrom, me, pid)
	ob = okOB and ob == true
	local warYou = AtWar(me, pid)
	local warE = E ~= nil and pid ~= E and AtWar(pid, E)
	local wars = RealWars(pid)
	local names = {}
	for _, e in ipairs(wars) do names[#names + 1] = PlayerName(e) end
	local facts = "at war with E: " .. (pid == E and "-" or YesNo(warE)) .. " (real wars: " ..
		(#names > 0 and table.concat(names, ", ") or "none") .. "), ally: " .. YesNo(ally) .. ", friend: " .. YesNo(friend) ..
		", OB to you: " .. YesNo(ob) .. ", at war with you: " .. YesNo(warYou)
	local bad = {}
	if role.enemy then
		if not warYou then bad[#bad + 1] = "not at war with you" end
	else
		if warYou then bad[#bad + 1] = "at war with you" end
		if role.war and not warE then bad[#bad + 1] = "not at war with E" end
		if role.peace and #wars > 0 then
			if ally and warE then
				bad[#bad + 1] = "ENGINE EFFECT, not a VEF failure: the alliance pulled it into your war with E"
			else
				bad[#bad + 1] = "at war although this role must be at peace"
			end
		end
		if role.ally and not ally then bad[#bad + 1] = "the alliance did not take" end
		if not role.ally and ally then bad[#bad + 1] = "allied although this role is not" end
		if role.friend and not friend then bad[#bad + 1] = "no declared friendship" end
		if not role.friend and not role.ally and friend then bad[#bad + 1] = "declared friend although this role is not" end
		if role.ob and not ob then bad[#bad + 1] = "no open borders to you" end
		if role.friend and not role.ob and ob then bad[#bad + 1] = "grants you open borders although this role must not" end
	end
	return facts, (#bad > 0) and table.concat(bad, "; ") or nil
end

-- Facts of city-state pid toward you, and what does not match its role.
local function EligFactsCS(me, pid, role)
	local met = Diplo(me, "HasMet", pid)
	local warYou = AtWar(me, pid)
	local wars = RealWars(pid)
	local names = {}
	for _, e in ipairs(wars) do names[#names + 1] = PlayerName(e) end
	local facts = "city-state, met: " .. YesNo(met) .. ", at war with you: " .. YesNo(warYou) .. " (real wars: " ..
		(#names > 0 and table.concat(names, ", ") or "none") .. ")"
	local bad = {}
	if not met then bad[#bad + 1] = "not met" end
	if role.youWar and not warYou then bad[#bad + 1] = "not at war with you" end
	if not role.youWar and warYou then bad[#bad + 1] = "at war with you" end
	if role.peace and #wars > 0 then bad[#bad + 1] = "at war although this role must be at peace" end
	return facts, (#bad > 0) and table.concat(bad, "; ") or nil
end

-- Removes the Swordsmen an earlier T1 / T2 press created (unless VEF tracks
-- them now: the tester sent one).
local function EligCleanup(st)
	local e = st.elig
	if type(e) ~= "table" or type(e.units) ~= "table" then return end
	local store = EFV_Records.Load()
	for _, x in ipairs(e.units) do
		local o = tonumber(x.o) or -1
		local u = FindUnit(o, tonumber(x.u) or -1)
		if u ~= nil and UnitTypeName(u) == x.ut and EFV_Records.FindByUnit(store, o, u:GetID()) == nil then
			pcall(function() Players[o]:GetUnits():Destroy(u) end)
		end
	end
end

local function EligTest(test, me, p)
	local spec = ELIG_TESTS[test]
	local id = "ELIG_" .. test
	local st = ScnLoad()
	local function Fail(msg)
		st.elig = { test = test, err = msg, stamp = p.stamp }
		Focus(st, -1, -1, nil, nil, p.stamp)
		ScnSave(st)
		Check(id, "CHECK", msg)
	end
	local cap = Capital(me)
	if cap == nil then return Fail("you have no city yet: found your capital, then press " .. test .. " again") end
	local majors = SortedIDs(function(i) return i ~= me and IsMajorID(i) and HasCity(i) end)
	if #majors < 2 then
		return Fail("needs at least 2 other civs with a city, found " .. #majors .. ": End Turn once more, then press " .. test .. " again")
	end
	local notes = {}
	if type(st.elig) == "table" and st.elig.test ~= nil and st.elig.test ~= test and st.elig.err == nil then
		notes[#notes + 1] = "an earlier " .. Str(st.elig.test) .. " in this game set up other wars: use a fresh game for each test"
	end
	if st.ally ~= nil then notes[#notes + 1] = "S0 ran in this game: its wars and friendships may disturb the roles" end
	EligCleanup(st)
	-- 1. everybody meets everybody (the diplomacy screen shows every relation)
	local all = SortedIDs(IsRealPlayer)
	for i = 1, #all do
		for j = i + 1, #all do MeetPair(all[i], all[j]) end
	end
	-- 2. roles by ascending ID
	local civs, skipped = {}, {}
	for i, role in ipairs(spec.roles) do
		if majors[i] ~= nil then civs[#civs + 1] = { pid = majors[i], role = role } else skipped[#skipped + 1] = role.r end
	end
	for i = #spec.roles + 1, #majors do civs[#civs + 1] = { pid = majors[i], role = ELIG_OTHER } end
	local css = {}
	if spec.cs ~= nil then
		local ids = SortedIDs(function(i) return IsCityStateID(i) and HasCity(i) end)
		for i, role in ipairs(spec.cs) do
			if ids[i] ~= nil then css[#css + 1] = { pid = ids[i], role = role } else skipped[#skipped + 1] = role.r end
		end
		for i = #spec.cs + 1, #ids do css[#css + 1] = { pid = ids[i], role = ELIG_OTHER_CS } end
	end
	local E = civs[1].pid
	-- 3. wars first (only for the roles that need one), then the partners
	DeclareWar(me, E)
	for _, c in ipairs(civs) do
		if c.role.war then DeclareWar(c.pid, E) end
	end
	for _, c in ipairs(css) do
		if c.role.youWar then DeclareWar(me, c.pid) end
	end
	local civicOB, civicAlly = false, false
	for _, c in ipairs(civs) do
		local r, pid = c.role, c.pid
		if (r.friend or r.ally) and not Diplo(me, "HasDeclaredFriendship", pid) then
			SetDiploPair(id, me, pid, "SetHasDeclaredFriendship", true)
		end
		if r.ob then
			if not civicOB then GrantCivic(me, CIVIC_OB); civicOB = true end
			GrantCivic(pid, CIVIC_OB)
			GrantOpenBorders(pid, me)
		end
		if r.ally and not Diplo(me, "HasAllied", pid) then
			-- Alliances need Civil Service (nobody has it early on).
			if not civicAlly then GrantCivic(me, CIVIC_ALLY); civicAlly = true end
			GrantCivic(pid, CIVIC_ALLY)
			SetDiploPair(id, me, pid, "SetHasAllied", true)
		end
	end
	-- 4. their cities revealed (no NOT_REVEALED), gold and Iron for the fees
	for _, c in ipairs(civs) do
		for _, city in ipairs(Cities(c.pid)) do RevealCity(me, city, nil) end
	end
	for _, c in ipairs(css) do
		for _, city in ipairs(Cities(c.pid)) do RevealCity(me, city, nil) end
	end
	pcall(function()
		local t = Players[me]:GetTreasury()
		local g = t:GetGoldBalance()
		if g < 2000 then t:ChangeGoldBalance(2000 - g) end
	end)
	pcall(function()
		local r = Players[me]:GetResources()
		local idx = GameInfo.Resources["RESOURCE_IRON"].Index
		local have = r:GetResourceAmount(idx)
		if have < 10 then r:ChangeResourceAmount(idx, 10 - have) end
	end)
	-- 5. two Swordsmen with full moves next to your capital
	local swords, units, full = {}, {}, 0
	for _ = 1, 2 do
		local plot = FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1) or FindPlot(cap:GetX(), cap:GetY(), 4, OwnedByAny({ -1, me }), 1)
		local u = NewUnit(id, me, "UNIT_SWORDSMAN", plot)
		if u ~= nil then
			swords[#swords + 1] = u
			units[#units + 1] = { o = me, u = u:GetID(), ut = "UNIT_SWORDSMAN" }
			if FullMoves(u) then full = full + 1 end
		end
	end
	-- 6. VEF's picker rows (gameplay rules) against the expected results
	local store = EFV_Records.Load()
	local rowsExp, rowsVol, rowsCs = {}, {}, {}
	if swords[1] ~= nil then
		rowsExp = EFV_DestinationRows(me, swords[1], FT_EXP, store)
		rowsVol = EFV_DestinationRows(me, swords[2] or swords[1], FT_VOL, store)
		if #css > 0 then rowsCs = EFV_DestinationRows(me, swords[1], FT_CS, store) end
	end
	local n, pass, fail, chk = 0, 0, 0, 0
	local map, saved = {}, {}
	for _, c in ipairs(civs) do
		local r = c.role
		local facts, setup = EligFacts(me, c.pid, r, E)
		local aExp, oExp = EligClass(rowsExp, c.pid)
		local aVol, oVol = EligClass(rowsVol, c.pid)
		local v = "PASS"
		for _, w in ipairs({ EligCompare(r.exp, aExp), EligCompare(r.vol, aVol) }) do
			if w == "FAIL" then v = "FAIL" elseif w == "CHECK" and v == "PASS" then v = "CHECK" end
		end
		if setup ~= nil then v = "CHECK" end
		if swords[1] == nil then v = "CHECK" end
		n = n + 1
		if v == "PASS" then pass = pass + 1 elseif v == "FAIL" then fail = fail + 1 else chk = chk + 1 end
		local function Act(a, o) return a .. (#o > 0 and (" (also " .. table.concat(o, "+") .. ")") or "") end
		Check(id, v, r.r .. "=" .. PlayerName(c.pid) .. " | " .. facts .. " | Expeditionary expected " .. r.exp .. " actual " ..
			Act(aExp, oExp) .. " | Volunteers expected " .. r.vol .. " actual " .. Act(aVol, oVol) ..
			(setup and (" | SETUP: " .. setup) or "") .. " [gameplay rules]")
		if r ~= ELIG_OTHER then map[#map + 1] = r.r .. "=" .. PlayerName(c.pid) end
		saved[#saved + 1] = { pid = c.pid, role = r.r, exp = r.exp, vol = r.vol, facts = facts, setup = setup, g = v }
	end
	local ncs = 0
	for _, c in ipairs(css) do
		local r = c.role
		local facts, setup = EligFactsCS(me, c.pid, r)
		local aCs, oCs = EligClass(rowsCs, c.pid)
		local v = EligCompare(r.cs, aCs)
		if setup ~= nil or swords[1] == nil then v = "CHECK" end
		ncs = ncs + 1
		if v == "PASS" then pass = pass + 1 elseif v == "FAIL" then fail = fail + 1 else chk = chk + 1 end
		local function Act(a, o) return a .. (#o > 0 and (" (also " .. table.concat(o, "+") .. ")") or "") end
		Check(id, v, r.r .. "=" .. PlayerName(c.pid) .. " | " .. facts .. " | City-State expected " .. r.cs .. " actual " ..
			Act(aCs, oCs) .. (setup and (" | SETUP: " .. setup) or "") .. " [gameplay rules]")
		if r ~= ELIG_OTHER_CS then map[#map + 1] = r.r .. "=" .. PlayerName(c.pid) end
		saved[#saved + 1] = { pid = c.pid, role = r.r, cs = r.cs, facts = facts, setup = setup, g = v }
	end
	if #skipped > 0 then notes[#notes + 1] = "only " .. #majors .. " other civ(s) with a city: roles " .. table.concat(skipped, ", ") .. " skipped" end
	if #swords < 2 or full < #swords then notes[#notes + 1] = "Swordsmen " .. #swords .. " of 2 (full moves " .. full .. ")" end
	local sv = (fail > 0) and "FAIL" or ((chk > 0 or #notes > 0) and "CHECK" or "PASS")
	st.elig = { test = test, stamp = p.stamp, units = units, civs = saved, n = n + ncs, ncs = ncs, pass = pass, fail = fail, check = chk,
		u1 = swords[1] and swords[1]:GetID() or -1, u2 = swords[2] and swords[2]:GetID() or -1,
		skipped = (#skipped > 0) and table.concat(skipped, ",") or nil }
	Focus(st, cap:GetX(), cap:GetY(), me, swords[1] and swords[1]:GetID() or -1, p.stamp)
	ScnSave(st)
	Check(id, sv, "summary (gameplay rules): " .. test .. " " .. spec.title .. ", " .. n .. " civ(s)" ..
		(ncs > 0 and (" + " .. ncs .. " city-state(s)") or "") .. ": " .. pass .. " PASS, " ..
		fail .. " FAIL, " .. chk .. " CHECK; roles " .. table.concat(map, ", ") ..
		(#notes > 0 and ("; " .. table.concat(notes, "; ")) or ""))
end

CMD.elig_t1 = function(me, p) EligTest("T1", me, p) end
CMD.elig_t2 = function(me, p) EligTest("T2", me, p) end

-- ===========================================================================
-- VEF 1.0.3 session (EFV_Dev 1.0.3.2; EFV/TESTING_1.0.3.md). Works against
-- the released VEF 1.0.3 (Steam Workshop) without changes to it.
-- ===========================================================================
end -- Eligibility tests T1 / T2

-- ---------------------------------------------------------------------------
-- S17 Tracker labels (VEF 1.0.3: the recipient reads Inbound / Departed,
-- the sender Outbound / Returning). The tracker shows only the local
-- player's view, so S17 builds four records in transit between you and F
-- (your friend since S0; B is kept for S16), without units (the S12 field
-- set), all arriving in 2 turns:
--   INBOUND    F -> you, Expeditionary, on its way to your capital
--   DEPARTED   F -> you, Volunteers, going home to F's capital
--   OUTBOUND   you -> F, Expeditionary, on its way to F's capital
--   RETURNING  you -> F, Volunteers, coming home to your capital
-- They are deleted at the end of this turn (GameEvents.OnGameTurnEnded,
-- st.cleanRecs), before any VEF turn-start step could move or cancel them;
-- S16 and the HOME watch skip them. The panel opens the tracker (focus open
-- = TRACKER) and checks its rows with VEF's own UI functions
-- (TRACKER_LABELS, UI side).
-- ---------------------------------------------------------------------------
do
local LABEL_ROWS = {
	{ role = "INBOUND",   fromF = true,  state = ST.OUT, force = FT_EXP, ut = "UNIT_SPEARMAN", name = "VEF-IN" },
	{ role = "DEPARTED",  fromF = true,  state = ST.RET, force = FT_VOL, ut = "UNIT_ARCHER",   name = "VEF-DEPARTED" },
	{ role = "OUTBOUND",  fromF = false, state = ST.OUT, force = FT_EXP, ut = "UNIT_HORSEMAN", name = "VEF-OUT" },
	{ role = "RETURNING", fromF = false, state = ST.RET, force = FT_VOL, ut = "UNIT_WARRIOR",  name = "VEF-RET" },
}
local LABEL_TURNS = 2

CMD.scn_labels = function(me, p)
	local st = Session("TRACKER_PREP", me)
	if st == nil then return end
	local F = st.friend
	local cap, capF = Capital(me), (F ~= nil) and Capital(F) or nil
	if cap == nil or capF == nil then Check("TRACKER_PREP", "CHECK", "your capital or F's capital is missing"); return end
	local store = EFV_Records.Load()
	if type(st.s17) == "table" then
		for _, id in ipairs(st.s17.ids or {}) do
			if EFV_Records.Get(store, id) ~= nil then EFV_Records.Delete(store, id) end
		end
	end
	local t = Turn()
	local ids, rows, made = {}, {}, {}
	for _, d in ipairs(LABEL_ROWS) do
		local sender, recipient = me, F
		local origin, dest = cap, capF
		if d.fromF then sender, recipient, origin, dest = F, me, capF, cap end
		local basis = (d.force == FT_VOL) and (EFV_VolunteerBasis(sender, recipient) or "FRIEND_OB")
			or (EFV_PartnerBasis(sender, recipient) or "FRIEND")
		local fields = {
			forceType = d.force, state = d.state, senderID = sender, recipientID = recipient, accessBasis = basis,
			originCityID = origin:GetID(), originX = origin:GetX(), originY = origin:GetY(),
			destCityID = dest:GetID(), destX = dest:GetX(), destY = dest:GetY(), rerouted = 0,
			sentTurn = t, arrivalTurn = t + LABEL_TURNS, transitTurns = LABEL_TURNS, band = LABEL_TURNS,
			distance = Dist(origin:GetX(), origin:GetY(), dest:GetX(), dest:GetY()),
			lapsed = 0, spawnFailCount = 0, feePaid = 0, maintGoldPaid = 0,
			unitType = d.ut, veteranName = d.name, damage = 0, experience = 0, xpNext = 15, level = 1,
			formation = 0, snapTurn = t,
		}
		if d.state == ST.OUT then
			fields.sentX, fields.sentY = origin:GetX(), origin:GetY()
		else
			-- the unit served at dest and goes home to the sender's capital
			fields.sentTurn, fields.deployedTurn = t - 6, t - 5
			fields.returnCityID, fields.returnX, fields.returnY, fields.returnReason = origin:GetID(), origin:GetX(), origin:GetY(), "RECALL"
			fields.lastX, fields.lastY = dest:GetX(), dest:GetY()
		end
		local rec = EFV_Records.New(store, fields)
		if rec ~= nil then
			ids[#ids + 1] = rec.id
			rows[#rows + 1] = { role = d.role, id = rec.id }
			made[#made + 1] = d.role .. " record " .. rec.id .. " " .. d.name .. " (" .. PlayerName(sender) .. " -> " .. PlayerName(recipient) .. ")"
		end
	end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.s17 = { stamp = p.stamp or 0, turn = t, ids = ids, rows = rows }
	local clean = Sub(st, "cleanRecs")
	for _, id in ipairs(ids) do clean[#clean + 1] = id end
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	st.focus.open, st.focus.zoom = "TRACKER", ZOOM_MID
	ScnSave(st)
	Check("TRACKER_PREP", #ids == #LABEL_ROWS and "INFO" or "CHECK", #ids .. " record(s) in transit: " .. table.concat(made, "; ") ..
		"; they are removed when you end this turn")
end
end -- S17 Tracker labels

-- ---------------------------------------------------------------------------
-- S18 Entrust a city-state's city (VEF 1.0.3: Entrust skips the at-war
-- check when the old owner was a city-state or has been eliminated). A
-- one-city city-state other than CS (S16 needs CS), which neither B nor F
-- is at war with: you meet it and declare war on it (B stays at peace), its
-- city is revealed, left at 1 HP with its walls down, 3 Tanks of yours next
-- to it. Taking its only city eliminates it; Entrust must offer B (and F).
-- ENTRUST_CS_UI (panel, at the capture) reads VEF's own Entrust state;
-- ENTRUST_CS (next turn start or Check now) passes when B or F owns it.
-- ---------------------------------------------------------------------------
do
local function EntrustCityState(st, me)
	local excl = { st.cs, st.killCs or -1, st.guardCs or -1 }
	for _ = 1, 16 do
		local cs = PickCityState(st, me, excl)
		if cs == nil then return nil end
		if not AtWar(st.ally, cs) and not (st.friend ~= nil and AtWar(st.friend, cs)) then return cs end
		excl[#excl + 1] = cs
	end
	return nil
end

CMD.scn_entrust_cs = function(me, p)
	local st = Session("ENTRUST_CS", me)
	if st == nil then return end
	local B = st.ally
	local cs = EntrustCityState(st, me)
	if cs == nil then
		Check("ENTRUST_CS", "CHECK", "no one-city city-state other than CS that B and F are at peace with: start a game with at least 3 city-states")
		return
	end
	if EFV_PartnerBasis(me, B) == nil then EnsurePartner("scn_entrust_cs", me, B) end
	local city = Cities(cs)[1]
	MeetPair(me, cs)
	DeclareWar(me, cs)
	RevealCity(me, city, { -1, cs, me, B })
	local _, weak = WeakenCity(city)
	local n = 0
	for _ = 1, 3 do
		if NewUnit("scn_entrust_cs", me, "UNIT_TANK", FindPlot(city:GetX(), city:GetY(), 4, OwnedByAny({ -1, cs, me, B }), 1)) ~= nil then n = n + 1 end
	end
	local bWar = AtWar(B, cs)
	st.entrustCs = cs
	st.s18 = { cx = city:GetX(), cy = city:GetY(), owner = cs, turn = Turn(), tries = 0, bWar = bWar and 1 or 0 }
	Focus(st, city:GetX(), city:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	local ok = AtWar(me, cs) and not bWar and n > 0 and EFV_PartnerBasis(me, B) ~= nil
	Check("ENTRUST_CS", ok and "INFO" or "CHECK", n .. " Tanks next to " .. PlayerName(cs) .. "'s only city at " .. city:GetX() .. "," ..
		city:GetY() .. " (" .. weak .. "); you at war with it=" .. tostring(AtWar(me, cs)) .. ", B at war with it=" .. tostring(bWar) ..
		": take it and choose Entrust -> " .. PlayerName(B))
end

function EV.EvalS18(st, store, t, manual)
	local s = st.s18
	if type(s) ~= "table" or (t <= s.turn and not manual) then return end
	local city = CityManager.GetCityAt(s.cx, s.cy)
	local owner = city and city:GetOwner() or -1
	local facts = PlayerName(s.owner) .. " alive=" .. tostring(Alive(s.owner)) .. ", B was at war with it=" .. tostring(tonumber(s.bWar) == 1)
	if owner == st.ally or owner == st.friend then
		st.s18 = nil
		Check("ENTRUST_CS", "PASS", "the city-state's city now belongs to " .. PlayerName(owner) .. " (entrusted); " .. facts)
	elseif owner == st.me then
		if not manual then
			st.s18 = nil
			Check("ENTRUST_CS", "CHECK", "you kept the city (Entrust was not used, greyed or refused: see ENTRUST_CS_UI); " .. facts)
		end
	elseif not manual then
		s.tries = (tonumber(s.tries) or 0) + 1
		if s.tries >= 3 then st.s18 = nil end
		Check("ENTRUST_CS", s.tries >= 3 and "CHECK" or "INFO", "the city still belongs to " .. PlayerName(owner))
	end
end
end -- S18 Entrust a city-state's city

-- ---------------------------------------------------------------------------
-- S19 Entrust a living major's city: still greyed (VEF 1.0.3 keeps the
-- at-war check for a major that is alive and keeps a city). D = the next
-- major with a city after B, F and C (needs 5 civs). You meet D and declare
-- war on it; B and F stay at peace with D. D's nearest non-capital city, or
-- a small new city founded for D 5-10 tiles from your capital (never D's
-- last city: that would eliminate D and skip the check) is revealed, left at
-- 1 HP, with 3 Tanks of yours next to it. After the capture the Entrust
-- button must read "Entrust (no eligible partner)": choose Keep.
-- ENTRUST_MAJOR_UI (panel) reads VEF's Entrust state at the capture;
-- ENTRUST_MAJOR (next turn start) passes when the city is still yours and
-- fails when a partner got it.
-- ---------------------------------------------------------------------------
do
local function FourthMajor(st, me)
	for _, i in ipairs(SortedIDs(function(i) return i ~= me and IsMajorID(i) and HasCity(i) end)) do
		if i ~= st.ally and i ~= st.friend and i ~= st.enemy then return i end
	end
	return nil
end

CMD.scn_entrust_major = function(me, p)
	local st = Session("ENTRUST_MAJOR", me)
	if st == nil then return end
	local D = FourthMajor(st, me)
	if D == nil then Check("ENTRUST_MAJOR", "CHECK", "needs a 4th AI civ (D): start a game with at least 5 civs"); return end
	MeetPair(me, D)
	if AtWar(st.ally, D) or (st.friend ~= nil and AtWar(st.friend, D)) then
		Check("ENTRUST_MAJOR", "CHECK", "B or F is at war with " .. PlayerName(D) .. ": the city could be entrusted; this game cannot show the greyed case")
		return
	end
	local city, tanks, note, weak = BuildEntrustScene("scn_entrust_major", me, st, nil, { owner = D, allyWar = false, keepOwner = true })
	if city == nil then Check("ENTRUST_MAJOR", "CHECK", tanks); return end
	local bWar = AtWar(st.ally, D) or (st.friend ~= nil and AtWar(st.friend, D))
	st.entrustMajor = D
	st.s19 = { cx = city:GetX(), cy = city:GetY(), owner = D, turn = Turn(), tries = 0 }
	Focus(st, city:GetX(), city:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	local ok = AtWar(me, D) and not bWar and #tanks > 0 and #Cities(D) >= 2
	Check("ENTRUST_MAJOR", ok and "INFO" or "CHECK", #tanks .. " Tanks next to " .. PlayerName(D) .. "'s city at " .. city:GetX() .. "," ..
		city:GetY() .. " (" .. note .. "; " .. weak .. "); " .. PlayerName(D) .. " keeps " .. (#Cities(D) - 1) .. " other city(ies); B or F at war with it=" ..
		tostring(bWar) .. ": take it, Entrust must be greyed, then choose Keep")
end

function EV.EvalS19(st, store, t, manual)
	local s = st.s19
	if type(s) ~= "table" or (t <= s.turn and not manual) then return end
	local city = CityManager.GetCityAt(s.cx, s.cy)
	local owner = city and city:GetOwner() or -1
	if owner == st.ally or owner == st.friend then
		st.s19 = nil
		Check("ENTRUST_MAJOR", "FAIL", "the city went to " .. PlayerName(owner) .. " although nobody was at war with " .. PlayerName(s.owner) ..
			" (alive=" .. tostring(Alive(s.owner)) .. ")")
	elseif owner == st.me then
		if not manual then
			st.s19 = nil
			Check("ENTRUST_MAJOR", "PASS", "the city is still yours: nobody could take it (" .. PlayerName(s.owner) .. " alive=" ..
				tostring(Alive(s.owner)) .. ", " .. #Cities(s.owner) .. " city(ies) left)")
		end
	elseif not manual then
		s.tries = (tonumber(s.tries) or 0) + 1
		if s.tries >= 3 then st.s19 = nil end
		Check("ENTRUST_MAJOR", s.tries >= 3 and "CHECK" or "INFO", "the city still belongs to " .. PlayerName(owner))
	end
end
end -- S19 Entrust a living major's city

-- ===========================================================================
-- V Veteran spike (EFV_Dev 1.0.3.2): can a returning human-owned veteran
-- take all its promotions back in ONE turn? Today (route B) VEF raises the
-- XP and the owner's UI sends the engine PROMOTE command, one promotion per
-- turn, because promoting ends the unit's turn (no moves -> PROMOTE is not
-- offered). Four fresh copies of one template (3 wanted promotions) are
-- made next to your capital, named VEF-V0 .. VEF-V3:
--   V0  control: route B as today (XP to the threshold, PROMOTE, sync).
--   V1  a hidden unit ability (Data/EFV_Dev_Spike.xml,
--       EFV_DEV_ABILITY_PROMOTE_KEEP_MOVES: COLLECTION_OWNER +
--       EFFECT_ADJUST_UNIT_PROMOTE_NO_FINISH_MOVES, NoFinishMoves = true,
--       the Gran Colombia trait's effect on one unit) is granted, the panel
--       chains PROMOTE in the same turn, then the ability is removed and one
--       more normal promotion must end the turn again (VSPIKE_V1_OFF).
--   V2  no DB change: after each landed promotion gameplay restores the
--       moves, then the panel sends the next PROMOTE.
--   V3  a level-adjust ability (EFV_DEV_ABILITY_VET_LEVEL:
--       MODIFIER_PLAYER_UNIT_ADJUST_EXPERIENCE_LEVEL, Amount 3, the Giant
--       Death Robot's ABILITY_UNIT_AUTO_VETERANCY pattern) plus SetPromotion
--       for each promotion plus the XP: what level, threshold and pending
--       promotion result.
-- The UI side (panel) sends every PROMOTE and writes the verdicts
-- (VSPIKE_V0 .. V3, VSPIKE_V1_OFF) with the UI level; gameplay writes
-- "[EFV][CHECK] VSPIKE INFO" lines (moves, XP / next-level XP, CanPromote,
-- HP, promotions, ability counts) at every step and at each of your next
-- VS_TURNS turn starts. Gameplay changes happen only in this EXECUTE_SCRIPT
-- handler (vs_start, vs_sync, vs_off); the panel issues the engine command.
-- Play as a civ OTHER than Gran Colombia: its trait keeps every unit's moves.
-- API evidence (shipped gameplay scripts):
--   u:GetAbility():ChangeAbilityCount(name, n) / :GetAbilityCount(name):
--     PiratesScenario_UnitCommands.lua:661-662 (+1),
--     CivRoyaleScenario_UnitCommands.lua:53-54 (+1),
--     PiratesScenario_StartScript.lua:1516-1518 (GetAbilityCount, -n)
--   u:ChangeMovesRemaining(n) with u:GetMaxMoves():
--     PiratesScenario_UnitCommands.lua:665-666 (moves for the current
--     turn), PiratesScenario_StartScript.lua:1524-1525; the static form
--     UnitManager.ChangeMovesRemaining(unit, n) is AustraliaScenario.lua:918
--   exp:SetPromotion / :ChangeExperience / :CanPromote: EFV_Units.lua,
--     EFV_Veteran.lua (Session A T09: CanPromote in G)
-- ===========================================================================
local VsPicks
do
local VS_KEYS = { "V0", "V1", "V2", "V3" }
local VS_KEEP_MOVES = "EFV_DEV_ABILITY_PROMOTE_KEEP_MOVES"
local VS_LEVEL = "EFV_DEV_ABILITY_VET_LEVEL"
local VS_TYPE = "UNIT_WARRIOR"
-- The XP of the template: the minimum of a level-4 unit (thresholds 15 /
-- 45 / 90; Session B T08 "xp=45 nextLvlXP=90" for level 3).
local VS_XP = 90
local VS_TURNS = 3

local function AbilityCount(u, name)
	local ok, n = pcall(function() return u:GetAbility():GetAbilityCount(name) end)
	if ok and type(n) == "number" then return n end
	return -1
end

local function ChangeAbility(u, name, d)
	local ok, err = pcall(function() u:GetAbility():ChangeAbilityCount(name, d) end)
	return ok, err
end

-- Refills the moves (PiratesScenario_UnitCommands.lua:665-666 pattern).
local function RestoreMoves(u)
	return pcall(function()
		local d = u:GetMaxMoves() - u:GetMovesRemaining()
		if d > 0 then u:ChangeMovesRemaining(d) end
	end)
end

-- Promotion type names the unit holds, in DB order (HasPromotion; G).
local function HeldNames(u)
	local out = {}
	pcall(function()
		local exp = u:GetExperience()
		for row in GameInfo.UnitPromotions() do
			if exp:HasPromotion(row.Index) then out[#out + 1] = row.UnitPromotionType end
		end
	end)
	return out
end

-- The first two level-1 and the first level-2 promotion of the type's
-- class (DB order). Every level-2 promotion of a class follows one of its
-- two level-1 promotions, so the three can be taken in this order.
function VsPicks(unitType)
	local row = GameInfo.Units[unitType]
	local cls = row and row.PromotionClass
	local l1, l2 = {}, nil
	for r in GameInfo.UnitPromotions() do
		if cls ~= nil and r.PromotionClass == cls then
			local lv = tonumber(r.Level)
			if lv == 1 and #l1 < 2 then l1[#l1 + 1] = r.UnitPromotionType
			elseif lv == 2 and l2 == nil then l2 = r.UnitPromotionType end
		end
	end
	if #l1 == 2 and l2 ~= nil then l1[3] = l2 end
	return l1
end

-- Template: your selected land unit with promotions (its type, promotions
-- and XP), else a Warrior with three promotions and VS_XP.
local function VsTemplate(me, p)
	local u = SelectedUnit(p)
	if u ~= nil and u:GetOwner() == me then
		local ut = UnitTypeName(u)
		local row = GameInfo.Units[ut]
		local rows = PromoRows(u)
		if row ~= nil and row.PromotionClass ~= nil and row.Domain == "DOMAIN_LAND" and #rows > 0 then
			local names = {}
			for _, r in ipairs(rows) do names[#names + 1] = r.UnitPromotionType end
			local xp = XPInfo(u)
			return ut, names, math.max(0, xp), "your selected unit " .. u:GetID()
		end
	end
	return VS_TYPE, VsPicks(VS_TYPE), VS_XP, "scenario template"
end

local function VsState(u)
	if u == nil then return "unit not found" end
	local s = "?"
	pcall(function()
		local exp = u:GetExperience()
		local cp = "?"
		pcall(function() cp = tostring(exp:CanPromote()) end)
		local held = HeldNames(u)
		s = "moves=" .. Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves()) .. " xp=" .. Str(exp:GetExperiencePoints()) .. "/" ..
			Str(exp:GetExperienceForNextLevel()) .. " canPromote=" .. cp .. " hp=" .. Str(u:GetMaxDamage() - u:GetDamage()) ..
			" promotions=" .. (#held > 0 and table.concat(held, "+") or "-") .. " keepMoves=" .. AbilityCount(u, VS_KEEP_MOVES) ..
			" levelAdjust=" .. AbilityCount(u, VS_LEVEL)
	end)
	return s
end

local function VsLog(k, step, u)
	Check("VSPIKE", "INFO", Str(k) .. " " .. step .. " | " .. VsState(u))
end

local function VsCopyOf(vs, k)
	for _, c in ipairs(vs.c or {}) do
		if c.k == k then return c end
	end
	return nil
end

CMD.vs_start = function(me, p)
	local st = ScnLoad()
	st.me = st.me or me
	local cap = Capital(me)
	if cap == nil then Check("VSPIKE", "CHECK", "found your capital first"); return end
	-- the copies of a previous press go (identity-checked by type)
	if type(st.vs) == "table" then
		for _, c in ipairs(st.vs.c or {}) do
			local old = FindUnit(me, tonumber(c.u) or -1)
			if old ~= nil and UnitTypeName(old) == st.vs.ut then pcall(function() Players[me]:GetUnits():Destroy(old) end) end
		end
	end
	local ut, promos, xpT, src = VsTemplate(me, p)
	if #promos == 0 then Check("VSPIKE", "CHECK", ut .. " has no promotion class with level-1 and level-2 promotions"); return end
	local vs = { stamp = p.stamp or 0, turn = Turn(), ut = ut, promos = promos, xp = xpT, src = src, c = {} }
	local units = {}
	for _, k in ipairs(VS_KEYS) do
		local plot = FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1) or FindPlot(cap:GetX(), cap:GetY(), 4, OwnedByAny({ -1, me }), 1)
		local u = NewUnit("vs_start", me, ut, plot, "VEF-" .. k)
		local c = { k = k, u = -1, synced = 0, off = 0 }
		if u ~= nil then
			c.u = u:GetID()
			FullMoves(u)
		end
		units[k] = u
		vs.c[#vs.c + 1] = c
	end
	-- V0 and V2: XP to the first threshold (route B step 1, EFV_Veteran.Begin)
	for _, k in ipairs({ "V0", "V2" }) do
		if units[k] ~= nil then
			XPToThreshold(units[k])
			VsLog(k, "created, XP to the first threshold", units[k])
		end
	end
	-- V1: the hidden keep-moves ability, then XP to the first threshold
	if units.V1 ~= nil then
		local ok, err = ChangeAbility(units.V1, VS_KEEP_MOVES, 1)
		XPToThreshold(units.V1)
		VsLog("V1", "created, keep-moves ability +1 ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
			((AbilityCount(units.V1, VS_KEEP_MOVES) == 1) and "" or " (NOT GRANTED: is Data/EFV_Dev_Spike.xml loaded? see Database.log)") ..
			", XP to the first threshold", units.V1)
	end
	-- V3: level-adjust ability, SetPromotion for each, then the XP
	local v3 = units.V3
	if v3 ~= nil then
		local ok, err = ChangeAbility(v3, VS_LEVEL, 1)
		VsLog("V3", "created, level-adjust ability +1 ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))), v3)
		for _, nm in ipairs(promos) do
			local row = GameInfo.UnitPromotions[nm]
			if row ~= nil then SetPromo(v3, row.Index) end
		end
		VsLog("V3", "SetPromotion x" .. #promos, v3)
		TopUp(v3, xpT)
		VsLog("V3", "XP raised toward " .. xpT, v3)
		local c3 = VsCopyOf(vs, "V3")
		if c3 ~= nil then c3.synced = #HeldNames(v3) end
	end
	st.vs = vs
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	local ids = {}
	for _, c in ipairs(vs.c) do ids[#ids + 1] = c.k .. "=" .. Str(c.u) end
	Check("VSPIKE", "INFO", "template " .. ut .. " (" .. src .. "), promotions " .. table.concat(promos, "+") .. ", XP " .. xpT ..
		"; copies " .. table.concat(ids, " ") .. "; the panel now promotes V0, V1 and V2")
end

-- Panel step after a promotion landed (the EFV_VetStep pattern): derived
-- from the unit, idempotent. V2 gets its moves back; XP to the next
-- threshold while a wanted promotion is missing, else the template XP.
CMD.vs_sync = function(me, p)
	local st = ScnLoad()
	local vs = st.vs
	local c = type(vs) == "table" and VsCopyOf(vs, p.k) or nil
	local u = c and FindUnit(me, tonumber(c.u) or -1)
	if u == nil then Log("vs_sync", "copy " .. Str(p.k) .. " not found"); return end
	local held = HeldNames(u)
	if #held <= (tonumber(c.synced) or 0) then Log("vs_sync", Str(c.k) .. ": nothing new (" .. #held .. " held)"); return end
	VsLog(c.k, "promotion " .. #held .. " landed", u)
	if c.k == "V2" then
		local ok, err = RestoreMoves(u)
		VsLog("V2", "moves restored with ChangeMovesRemaining ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))), u)
	end
	local left = 0
	for _, nm in ipairs(vs.promos or {}) do
		if not Has(held, nm) then left = left + 1 end
	end
	if left > 0 then
		XPToThreshold(u)
	elseif tonumber(c.off) ~= 1 then
		TopUp(u, vs.xp)
	end
	c.synced = #held
	ScnSave(st)
	VsLog(c.k, "synced, " .. (left > 0 and (left .. " to go, XP to the next threshold") or "every wanted promotion held"), u)
end

-- Panel step for V1 once its wanted promotions are back: the ability goes,
-- XP to the next threshold for one normal promotion (it must end the turn).
CMD.vs_off = function(me, p)
	local st = ScnLoad()
	local vs = st.vs
	local c = type(vs) == "table" and VsCopyOf(vs, "V1") or nil
	local u = c and FindUnit(me, tonumber(c.u) or -1)
	if u == nil or tonumber(c.off) == 1 then Log("vs_off", "V1 not found or already done"); return end
	local ok, err = ChangeAbility(u, VS_KEEP_MOVES, -1)
	XPToThreshold(u)
	c.off = 1
	ScnSave(st)
	VsLog("V1", "keep-moves ability -1 ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
		", XP to the next threshold for one normal promotion", u)
end

-- Your turn starts after the button's turn: one state line per copy.
function EV.EvalVS(st, t)
	local vs = st.vs
	if type(vs) ~= "table" then return end
	local t0 = tonumber(vs.turn) or t
	if t <= t0 or t > t0 + VS_TURNS or vs.logged == t then return end
	vs.logged = t
	for _, c in ipairs(vs.c or {}) do VsLog(c.k, "turn start", FindUnit(st.me, tonumber(c.u) or -1)) end
end
end -- V Veteran spike

-- ===========================================================================
-- The VEF 1.0.4 session (EFV_Dev 1.0.4.1; EFV/TESTING_1.0.4.md). Both
-- buttons only set the scene up and write one INFO line; the tester checks
-- the result by eye (no verdict lines).
-- ---------------------------------------------------------------------------
-- S20 War sends lent units home (VEF 1.0.4, designer ruling 2026-09-30):
-- two Expeditionary Swordsmen, DEPLOYED (MakeRecord, the Shot 2 / S15
-- pattern): "VEF-LENT", yours, lent to B and controlled by B next to B's
-- capital (held in place until the next turn start), and "VEF-BORROWED", B's,
-- lent to you and controlled by you next to your capital. Then your declared
-- friendship with B ends (an alliance too, if the game lets it) and you
-- declare war on B (DeclareWar: B declares on you if yours does not take).
-- At the end of your turn VEF sends both home on the normal return trip: you
-- get "Unit Coming Home" for VEF-LENT (tracker: Returning) and "Lent Unit
-- Gone Home" for VEF-BORROWED (tracker: Departed). Once per game: a second
-- press while at war with B changes nothing.
-- ---------------------------------------------------------------------------
CMD.scn_war_home = function(me, p)
	local st = Session("WAR_HOME", me)
	if st == nil then return end
	local B = st.ally
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then Check("WAR_HOME", "CHECK", "your capital or B's capital is missing"); return end
	if AtWar(me, B) then
		Check("WAR_HOME", "CHECK", "you are already at war with B (S20 works once per game): start a new game to repeat it")
		return
	end
	local store = EFV_Records.Load()
	local D = EFV_Config.EXPEDITIONARY_DURATION
	local t = Turn()
	local lent = NewUnit("scn_war_home", B, "UNIT_SWORDSMAN", FindPlot(capB:GetX(), capB:GetY(), 2, OwnedBy(B), 1), "VEF-LENT")
	local recL = nil
	if lent ~= nil then
		recL = MakeRecord(store, lent, { force = FT_EXP, sender = me, recipient = B, basis = EFV_PartnerBasis(me, B) or "FRIEND",
			origin = cap, dest = capB, duration = D, deployedTurn = t - 3 })
		Hold(store, lent)
	end
	local borrowed = NewUnit("scn_war_home", me, "UNIT_SWORDSMAN", FindPlot(cap:GetX(), cap:GetY(), 2, OwnedBy(me), 1), "VEF-BORROWED")
	local recB = nil
	if borrowed ~= nil then
		recB = MakeRecord(store, borrowed, { force = FT_EXP, sender = B, recipient = me, basis = EFV_PartnerBasis(B, me) or "FRIEND",
			origin = capB, dest = cap, duration = D, deployedTurn = t - 3 })
	end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	-- No war on a declared friend: the friendship ends first.
	SetDiploPair("scn_war_home", me, B, "SetHasDeclaredFriendship", false)
	if Diplo(me, "HasAllied", B) then SetDiploPair("scn_war_home", me, B, "SetHasAllied", false) end
	DeclareWar(me, B)
	local war = AtWar(me, B)
	st.s20 = { turn = t, lent = recL and recL.id or -1, borrowed = recB and recB.id or -1 }
	if lent ~= nil then Focus(st, lent:GetX(), lent:GetY(), nil, nil, p.stamp) else Focus(st, capB:GetX(), capB:GetY(), nil, nil, p.stamp) end
	ScnSave(st)
	local ok = recL ~= nil and recB ~= nil and war
	Check("WAR_HOME", ok and "INFO" or "CHECK", "VEF-LENT (yours, held by " .. PlayerName(B) .. ") " ..
		(recL and ("record " .. recL.id .. " at " .. lent:GetX() .. "," .. lent:GetY()) or "MISSING") .. "; VEF-BORROWED (" ..
		PlayerName(B) .. "'s, held by you) " .. (recB and ("record " .. recB.id .. " at " .. borrowed:GetX() .. "," .. borrowed:GetY()) or "MISSING") ..
		"; at war with B=" .. tostring(war) .. ": end the turn, both must go home")
end

-- ---------------------------------------------------------------------------
-- S21 Veteran home (VEF 1.0.4 one-turn restore, designer ruling 2026-10-05):
-- a RETURNING Expeditionary record of yours (the S12 pattern) coming home
-- from F at the next turn start: "VEF-VETERAN", a Swordsman at level 4 with
-- three promotions (VsPicks: two level-1 and one level-2 of its class, takeable
-- in that order), XP 100/150, no damage. VEF recreates it next to your
-- capital through its normal return path and your UI takes the promotions
-- back with the PROMOTE command; since 1.0.4 all three land in the arrival
-- turn, and the unit ends that turn with 0 moves. F is the partner, so S20's
-- war with B never touches it.
-- ---------------------------------------------------------------------------
do
local VET_HOME_NAME = "VEF-VETERAN"
local VET_HOME_TYPE = "UNIT_SWORDSMAN"
local VET_HOME_XP, VET_HOME_NEXT = 100, 150

CMD.scn_vet_home = function(me, p)
	local st = Session("VET_HOME", me)
	if st == nil then return end
	local F = st.friend
	local cap, capF = Capital(me), (F ~= nil) and Capital(F) or nil
	if cap == nil or capF == nil then Check("VET_HOME", "CHECK", "your capital or F's capital is missing"); return end
	local promos = VsPicks(VET_HOME_TYPE)
	if #promos < 3 then Check("VET_HOME", "CHECK", VET_HOME_TYPE .. " has fewer than 3 takeable promotions"); return end
	local t = Turn()
	local D = EFV_Config.EXPEDITIONARY_DURATION
	local store = EFV_Records.Load()
	local rec = EFV_Records.New(store, {
		forceType = FT_EXP, state = ST.RET, senderID = me, recipientID = F, accessBasis = EFV_PartnerBasis(me, F) or "FRIEND",
		originCityID = cap:GetID(), originX = cap:GetX(), originY = cap:GetY(),
		destCityID = capF:GetID(), destX = capF:GetX(), destY = capF:GetY(), rerouted = 0,
		sentTurn = t - D - 2, deployedTurn = t - D - 1, durationTurns = D, arrivalTurn = t + 1, transitTurns = 1, band = 1,
		distance = Dist(cap:GetX(), cap:GetY(), capF:GetX(), capF:GetY()),
		lapsed = 0, spawnFailCount = 0, feePaid = 0, maintGoldPaid = 0,
		returnCityID = cap:GetID(), returnX = cap:GetX(), returnY = cap:GetY(), returnReason = "EXPIRED",
		unitType = VET_HOME_TYPE, veteranName = VET_HOME_NAME, damage = 0, experience = VET_HOME_XP, xpNext = VET_HOME_NEXT,
		level = 1 + #promos, promotions = promos, formation = 0, snapTurn = t, lastX = capF:GetX(), lastY = capF:GetY(),
	})
	if rec == nil then Check("VET_HOME", "CHECK", "record creation failed"); return end
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	st.s21 = { id = rec.id, turn = t }
	Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
	ScnSave(st)
	Check("VET_HOME", "INFO", "record " .. rec.id .. ": " .. VET_HOME_NAME .. " (" .. VET_HOME_TYPE .. ", level " .. (1 + #promos) .. ", " ..
		table.concat(promos, "+") .. ", XP " .. VET_HOME_XP .. "/" .. VET_HOME_NEXT .. ") comes home next to your capital at the next turn start")
end
end -- S21 Veteran home

-- ===========================================================================
-- Denouncement reader spike (EFV_Dev 1.0.4.2; FIXPLAN_proxy_war.md "Spike";
-- EFV/TESTING_SPIKES.md). Question: can GAMEPLAY Lua (the synced
-- context) read a denouncement? Readers known so far are UI only
-- (DiplomacyActionView.lua:1473-1505: GetDiplomaticAI():GetDiplomaticStateIndex
-- compared with DIPLO_STATE_DENOUNCED, GetDiplomacy():GetDenounceTurn,
-- Game.GetGameDiplomacy():GetDenounceTimeLimit). Gameplay candidate:
-- GetAi_Diplomacy():GetDiplomaticState (Debug/Diplomacy.ltp:260, GameCore
-- tuner); Session D found many Diplomacy getters nil in gameplay
-- (research/phase0_results/raw/sessionD_Lua.log ~L360-372).
--   D Denounce probe (denounce_probe): READ ONLY. For you and every major
--     civ you have met, both directions, every reader in DP_READERS is looked
--     up BY NAME (a missing method is logged as MISSING, an error as ERROR,
--     nothing is thrown) and logged as
--       [EFV][Probe] G <reader>(<a>-><b>)=<value>
--     The answer for the panel (status and "denounced" hits per reader) goes
--     to the dev tools' own property EFV_DEV_SCN (st.dprobe); nothing else is
--     written. The panel then runs the same readers in the UI context ("UI"
--     lines; keep DP_READERS equal there), compares them with gameplay and
--     shows a short summary.
--   D Setup (denounce_setup): the lowest-ID major civ you could denounce
--     (alive, with a city, not your team, not at war with you, not allied,
--     not a declared friend: S0's B, F and C never qualify), met and its
--     capital revealed (S0 helpers). There is no script setter for a
--     denouncement (UI DiplomacyManager.RequestSession "DENOUNCE"): you
--     denounce it in the diplomacy screen yourself.
-- MP style: runs only in this synced handler, players by ascending ID, no
-- pairs() over state, no random, no local-player call.
-- ---------------------------------------------------------------------------
-- kind: turn (hit: a number >= 0), bool (hit: true), state (hit: the value
-- maps to DIPLO_STATE_DENOUNCED by index or hash, or a string naming it),
-- mods (hit: a modifier whose text mentions a denouncement).
local DpMethod
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

local function DpPrint(msg)
	print("[EFV][Probe] G " .. Str(msg))
end

-- obj[name] when it is a function; else nil and why.
function DpMethod(obj, name)
	if obj == nil then return nil, "object is nil" end
	local ok, f = pcall(function() return obj[name] end)
	if not ok then return nil, "lookup error " .. Str(f) end
	if f == nil then return nil, "is nil" end
	if type(f) ~= "function" then return nil, "is a " .. type(f) end
	return f, nil
end

-- Players[a]:<acc>():<fn>(b): "OK", value | "MISSING", why | "ERROR", why.
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

-- Log text of a value, and whether it says "denounced".
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

-- Game.GetGameDiplomacy():GetDenounceTimeLimit() as text.
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

-- Every reader for (me, b) and (b, me), b in pids. Returns per reader
-- { s = ok | nil | err | mixed | none, hits = "a>b ..." or "-" } and the limit.
local function DpRun(me, pids)
	local states = DpStates()
	local names = {}
	for _, b in ipairs(pids) do names[#names + 1] = PlayerName(b) end
	DpPrint("T" .. Str(Turn()) .. " begin: you " .. PlayerName(me) .. "; met majors (" .. #pids .. "): " ..
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
	local parts = {}
	for i, r in ipairs(DP_READERS) do parts[#parts + 1] = r.short .. " " .. res[i].s .. " [" .. res[i].hits .. "]" end
	DpPrint("summary: " .. table.concat(parts, " | ") .. " | limit " .. limit)
	return res, limit
end

CMD.denounce_probe = function(me, p)
	local pids = SortedIDs(function(i) return i ~= me and IsMajorID(i) and Diplo(me, "HasMet", i) end)
	local res, limit = DpRun(me, pids)
	local st = ScnLoad()
	-- (an empty table does not survive the property round trip: no pids then)
	st.dprobe = { stamp = Num(p.stamp, 0), turn = Turn(), me = me, pids = (#pids > 0) and pids or nil, limit = limit, r = res }
	ScnSave(st)
end

CMD.denounce_setup = function(me, p)
	local st = ScnLoad()
	local myTeam = -1
	pcall(function() myTeam = Players[me]:GetTeam() end)
	local cands = SortedIDs(function(i)
		return i ~= me and IsMajorID(i) and HasCity(i) and Players[i]:GetTeam() ~= myTeam and not AtWar(me, i) and
			not Diplo(me, "HasAllied", i) and not Diplo(me, "HasDeclaredFriendship", i)
	end)
	-- st.dsetup holds no translated text (the synced property must be the
	-- same on every client): the panel names the civ itself.
	local X = cands[1]
	if X == nil then
		st.dsetup = { stamp = Num(p.stamp, 0), x = -1 }
		Focus(st, -1, -1, nil, nil, p.stamp)
		ScnSave(st)
		Check("DENOUNCE_SETUP", "CHECK", "no major civ you could denounce (each one is at war with you, allied, a declared friend " ..
			"or has no city): start a new game")
		return
	end
	MeetPair(me, X)
	local cap = Capital(X)
	local revealed = nil
	if cap ~= nil then revealed = RevealCity(me, cap, nil) end
	local met = Diplo(me, "HasMet", X)
	st.dsetup = { stamp = Num(p.stamp, 0), x = X, met = met and 1 or 0, revealed = Str(revealed) }
	if cap ~= nil then Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp) else Focus(st, -1, -1, nil, nil, p.stamp) end
	ScnSave(st)
	Check("DENOUNCE_SETUP", (met and revealed ~= false) and "INFO" or "CHECK", "denounce " .. PlayerName(X) ..
		" in the diplomacy screen (its leader, Denounce); met=" .. tostring(met) .. ", capital revealed=" .. Str(revealed) ..
		"; not at war with you, not allied, not a declared friend")
end
end -- Denouncement reader spike

-- ===========================================================================
-- Air-unit spike (EFV_Dev 1.0.4.3; FIXPLAN_air_units.md section 7;
-- EFV/TESTING_SPIKES.md). A new Ancient-era game after S0: nobody has
-- Flight, Advanced Flight, Radio or Combined Arms. A script Create ignores
-- tech (SPIKES S10), so no tech is granted; Deploy and Rebase have no
-- PrereqTech (UnitOperations.xml:66,72,93), so whether a plane offers them
-- without Flight is one of the answers.
--   A1 air_city     Fighter VEF-AIR-1 in your capital, VEF-AIR-2 there too
--                   (over the one city-centre slot), VEF-AIR-3 on free land
--                   2-4 tiles away (no base).
--   A2 air_host     a Fighter for B in B's capital through VEF's own restore
--                   path (EFV_Units.Recreate, stand-in record: 1 promotion,
--                   20 damage), as an Expeditionary arrival would make it.
--   A3 air_fuel     one press per step. 1: VEF-AIR-1 at 30 damage, your
--                   Aluminium 0. 2 (two rounds after A1: a unit does not heal
--                   in the round it is created, SPIKES S8 Session E): damage
--                   read, Aluminium +2 per Aluminium unit you own (the upkeep
--                   must not eat the top-up). 3 (next turn): damage read.
--   A4 air_ally     F becomes your ally (Civil Service for both, then the
--                   alliance flag, as T1); your Fighter VEF-AIR-V in F's
--                   capital. F, not B: A2's plane fills B's capital slot.
--   A5 air_carrier  Carrier VEF-CV on free water next to your capital (your
--                   own water first: a send needs your own land or water),
--                   Fighter VEF-AIR-CV created on its tile; VEF's send rule
--                   is asked for B, F and CS. You send the carrier with VEF
--                   1.0.4's normal button, then press A5 again. The next VEF
--                   greys that send out (carrier with planes aboard); the
--                   button stays to show why.
--   A? air_status   where every spike unit is now; also AIR_TURN at each of
--                   your turn starts for AIR_WATCH_TURNS turns.
-- Raw facts: "[EFV][Air] G ..." lines. Unknown readers (plot, district and
-- unit GetAirSlots / GetAirUnits, UnitManager.CanStartOperation /
-- GetOperationTargets in gameplay, GetCombat) are looked up BY NAME and
-- pcall-guarded (MISSING / ERROR, never thrown), so api_audit does not see
-- them. Operation types by hash from GameInfo.UnitOperations, as
-- UnitPanel.lua:546-615 does. The panel's answer: st.air.ans (stamp, ASCII
-- text, no translated names: the property is synced). MP style: the synced
-- handler only, no pairs() over state, no random, no local-player call.
-- Own do-block: the main chunk is at Lua's 200-local limit; EvalAir is
-- reached as EFV_Dev.EvalAir.
-- ---------------------------------------------------------------------------
do
local AIR_UT, CV_UT, AL = "UNIT_FIGHTER", "UNIT_AIRCRAFT_CARRIER", "RESOURCE_ALUMINUM"
local AIR_WATCH_TURNS = 4

local function AirPrint(msg) print("[EFV][Air] G " .. Str(msg)) end

-- obj:name(...) (static: obj.name(...)) looked up by name:
-- "OK", r1, r2 | "MISSING", why | "ERROR", why.
local function AirCall(obj, name, static, ...)
	local f, why = DpMethod(obj, name)
	if f == nil then return "MISSING", name .. " " .. Str(why) end
	local args, n = { ... }, select("#", ...)
	local r
	if static then r = { pcall(f, unpack(args, 1, n)) } else r = { pcall(f, obj, unpack(args, 1, n)) } end
	if not r[1] then return "ERROR", Str(r[2]) end
	return "OK", r[2], r[3]
end

local function AirVal(v)
	if type(v) ~= "table" then return Str(v) end
	local parts = {}
	for _, x in ipairs(v) do
		local okU, s = pcall(function() return x:GetOwner() .. "/" .. x:GetID() end)
		parts[#parts + 1] = okU and s or Str(x)
	end
	return "list#" .. #parts .. (#parts > 0 and ("[" .. table.concat(parts, " ") .. "]") or "")
end

local function AirRes(s, a, b)
	if s ~= "OK" then return s .. " (" .. Str(a) .. ")" end
	return AirVal(a) .. (b ~= nil and (", " .. AirVal(b)) or "")
end

local function DomainOf(u)
	local ok, d = pcall(function() return GameInfo.Units[u:GetType()].Domain end)
	return ok and Str(d) or "?"
end

local function OpHash(t)
	local ok, h = pcall(function() return GameInfo.UnitOperations[t].Hash end)
	return ok and h or nil
end

-- Every air reader at (x, y), logged; a short text for the panel.
local function AirProbePlot(label, x, y)
	local plot = Map.GetPlot(x, y)
	local parts = {}
	pcall(function()
		for _, u in ipairs(Units.GetUnitsInPlot(plot)) do
			parts[#parts + 1] = Str(u:GetOwner()) .. "/" .. Str(u:GetID()) .. " " .. UnitTypeName(u) .. " " .. DomainOf(u)
		end
	end)
	local okC, cnt = pcall(function() return plot:GetUnitCount() end)
	AirPrint(label .. " @" .. x .. "," .. y .. ": GetUnitCount=" .. (okC and Str(cnt) or "ERROR") .. "; GetUnitsInPlot #" .. #parts ..
		" [" .. table.concat(parts, ", ") .. "]; plot:GetAirUnits=" .. AirRes(AirCall(plot, "GetAirUnits")))
	local okD, d = pcall(function() return CityManager.GetDistrictAt(x, y) end)
	local slots = "no district"
	if okD and d ~= nil then
		local s, v = AirCall(d, "GetAirSlots")
		slots = (s == "OK") and Str(v) or s
		AirPrint(label .. " district:GetAirSlots=" .. AirRes(s, v) .. "; district:GetAirUnits=" .. AirRes(AirCall(d, "GetAirUnits")))
	end
	return "plot list " .. #parts .. ", G slots " .. slots
end

-- A unit's facts: position, domain, the plot-list verdict (EFV_UnitMatches:
-- GONE_PLOT = not in Units.GetUnitsInPlot), the operations (UnitPanel
-- pattern, by name) and its own air slots (a carrier).
local function AirProbeUnit(label, u)
	if u == nil then AirPrint(label .. ": no unit"); return end
	local okM, m, why = pcall(EFV_UnitMatches, u, u:GetOwner(), u:GetID(), nil)
	local ops = {}
	for _, op in ipairs({ "DEPLOY", "REBASE" }) do
		ops[#ops + 1] = "Can" .. op .. "=" .. AirRes(AirCall(UnitManager, "CanStartOperation", true, u, OpHash("UNITOPERATION_" .. op), nil, false, false))
	end
	local s, r = AirCall(UnitManager, "GetOperationTargets", true, u, OpHash("UNITOPERATION_REBASE"))
	local txt = AirRes(s, r)
	if s == "OK" and type(r) == "table" then
		local okP, plots = pcall(function() return r[UnitOperationResults.PLOTS] end)
		txt = okP and AirVal(plots) or ("PLOTS unreadable: " .. Str(plots))
	end
	AirPrint(label .. ": " .. DescribeUnit(u) .. " domain=" .. DomainOf(u) .. " EFV_UnitMatches=" ..
		(okM and (m and "ok" or Str(why)) or "ERROR") .. " GetCombat=" .. AirRes(AirCall(u, "GetCombat")) ..
		" GetAirSlots=" .. AirRes(AirCall(u, "GetAirSlots")) .. " GetAirUnits=" .. AirRes(AirCall(u, "GetAirUnits")) ..
		" " .. table.concat(ops, " ") .. " RebaseTargets=" .. txt)
end

local function AirState(st)
	local a = Sub(st, "air")
	if type(a.units) ~= "table" then a.units = {} end
	return a
end

-- Sets (or, u nil, drops) the spike unit with key k.
local function AirSet(a, k, u)
	local list = {}
	for _, e in ipairs(a.units) do if e.k ~= k then list[#list + 1] = e end end
	if u ~= nil then list[#list + 1] = { k = k, o = u:GetOwner(), u = u:GetID(), t = UnitTypeName(u), turn = Turn() } end
	a.units = list
end

local function AirEntry(a, k)
	for _, e in ipairs(a.units or {}) do if e.k == k then return e end end
	return nil
end

-- The live unit of entry e (nil when gone) and a short fact text.
local function AirFact(e)
	if e == nil then return nil, "not made" end
	local u = FindUnit(e.o, e.u)
	if u == nil or UnitTypeName(u) ~= e.t then return nil, "gone" end
	local okM, m, why = pcall(EFV_UnitMatches, u, e.o, e.u, e.t)
	if okM and not m and (why == "GONE_OFFMAP" or why == "GONE_DEAD") then return nil, "gone (" .. why .. ")" end
	local x, y = u:GetX(), u:GetY()
	local where = "land"
	pcall(function()
		local c = CityManager.GetCityAt(x, y)
		if c ~= nil then where = "in city of P" .. c:GetOwner() elseif Map.GetPlot(x, y):IsWater() then where = "on water" end
	end)
	local listed = (not okM) and "?" or ((not m and why == "GONE_PLOT") and "NO" or "yes")
	return u, "P" .. e.o .. " @" .. x .. "," .. y .. " " .. where .. ", dmg " .. UnitDamage(u) .. ", in plot list " .. listed
end

local function AirStatusText(a)
	local parts = {}
	for _, e in ipairs(a.units or {}) do
		local _, t = AirFact(e)
		parts[#parts + 1] = e.k .. " " .. t
	end
	return (#parts > 0) and table.concat(parts, "; ") or "no spike units yet"
end

local function AirAnswer(st, p, id, text)
	local a = AirState(st)
	a.ans = { stamp = Num(p.stamp, 0), text = text }
	a.last = Turn()
	ScnSave(st)
	Check(id, "INFO", text)
end

local function AlIndex()
	local row = GameInfo.Resources[AL]
	return row and row.Index or -1
end

local function AlAmount(pid)
	local ok, v = pcall(function() return Players[pid]:GetResources():GetResourceAmount(AlIndex()) end)
	return ok and (tonumber(v) or -1) or -1
end

local function AlChange(pid, d)
	local ok, err = pcall(function() Players[pid]:GetResources():ChangeResourceAmount(AlIndex(), d) end)
	if not ok then AirPrint("ChangeResourceAmount(" .. AL .. ", " .. d .. ") ERROR " .. Str(err)) end
end

-- Your units whose heal gate is Aluminium (each one also costs 1 a turn).
local function AlUnits(pid)
	local n = 0
	pcall(function()
		for _, u in Players[pid]:GetUnits():Members() do
			if EFV_HealResourceType(UnitTypeName(u)) == AL then n = n + 1 end
		end
	end)
	return n
end

CMD.air_city = function(me, p)
	local st = Session("AIR_A1", me)
	if st == nil then return end
	local cap = Capital(me)
	if cap == nil then Check("AIR_A1", "CHECK", "you have no capital"); return end
	local a = AirState(st)
	local cx, cy = cap:GetX(), cap:GetY()
	local function Make(k, plot)
		local u = NewUnit("air_city", me, AIR_UT, plot, "VEF-" .. k)
		AirSet(a, k, u)
		AirPrint(k .. " Create(" .. AIR_UT .. ") at " .. (plot and (plot:GetX() .. "," .. plot:GetY()) or "no free plot") .. " -> " ..
			(u and ("unit " .. u:GetID() .. " @" .. u:GetX() .. "," .. u:GetY()) or "nil"))
		return u
	end
	local u1 = Make("AIR-1", Map.GetPlot(cx, cy))
	local u2 = Make("AIR-2", Map.GetPlot(cx, cy))
	local u3 = Make("AIR-3", FindPlot(cx, cy, 4, OwnedByAny({ -1, me }), 2))
	local g = AirProbePlot("your capital", cx, cy)
	AirProbeUnit("AIR-1", u1); AirProbeUnit("AIR-2", u2); AirProbeUnit("AIR-3", u3)
	a.a1 = { turn = Turn() }
	Focus(st, cx, cy, me, u1 and u1:GetID() or -1, p.stamp)
	local parts = {}
	for _, k in ipairs({ "AIR-1", "AIR-2", "AIR-3" }) do
		local _, t = AirFact(AirEntry(a, k))
		parts[#parts + 1] = k .. " " .. t
	end
	AirAnswer(st, p, "AIR_A1", "A1: " .. table.concat(parts, "; ") .. "; capital: " .. g)
end

CMD.air_host = function(me, p)
	local st = Session("AIR_A2", me)
	if st == nil then return end
	local B = st.ally
	local capB = Capital(B)
	if capB == nil then Check("AIR_A2", "CHECK", "B has no capital"); return end
	local a = AirState(st)
	local promos = LevelOnePromotions(AIR_UT, 1)
	local stand = { id = "AIR-B", unitType = AIR_UT, veteranName = "VEF-AIR-B", damage = 20, experience = 0,
		level = 1 + #promos, promotions = promos, formation = 0 }
	local store = EFV_Records.Load()
	local okR, u = pcall(EFV_Units.Recreate, store, B, stand, Map.GetPlot(capB:GetX(), capB:GetY()), Turn())
	if not okR then AirPrint("AIR-B Recreate ERROR " .. Str(u)); u = nil end
	EFV_Records.Commit(store)
	AirSet(a, "AIR-B", u)
	AirPrint("AIR-B EFV_Units.Recreate(P" .. B .. ", " .. AIR_UT .. ", " .. table.concat(promos, "+") .. ", 20 damage) at " ..
		capB:GetX() .. "," .. capB:GetY() .. " -> " .. (u and ("unit " .. u:GetID()) or "nil"))
	local g = AirProbePlot("B's capital", capB:GetX(), capB:GetY())
	AirProbeUnit("AIR-B", u)
	Focus(st, capB:GetX(), capB:GetY(), nil, nil, p.stamp)
	local _, t = AirFact(AirEntry(a, "AIR-B"))
	AirAnswer(st, p, "AIR_A2", "A2: B's plane " .. t .. ", promotions " .. (u and PromoCount(u, promos) or 0) .. "/" .. #promos ..
		" (20 dmg wanted); B's capital: " .. g)
end

CMD.air_fuel = function(me, p)
	local st = Session("AIR_A3", me)
	if st == nil then return end
	local a = AirState(st)
	local e = AirEntry(a, "AIR-1")
	local u, fact = AirFact(e)
	if u == nil then AirAnswer(st, p, "AIR_A3", "A3: VEF-AIR-1 " .. fact .. ": press A1 first"); return end
	local t = Turn()
	local f = type(a.a3) == "table" and a.a3 or {}
	local step = tonumber(f.step) or 0
	local text
	if step == 0 or step >= 3 then
		local al0 = AlAmount(me)
		if al0 > 0 then AlChange(me, -al0) end
		pcall(function() u:SetDamage(30) end)
		f = { step = 1, ready = math.max(t + 1, (tonumber(e.turn) or t) + 2) }
		text = "A3 step 1: VEF-AIR-1 damage " .. UnitDamage(u) .. ", your Aluminium " .. al0 .. " -> " .. AlAmount(me) ..
			". End Turn until turn " .. f.ready .. " (a plane can't heal in the turn it was made), then press A3"
	elseif step == 1 and t < (tonumber(f.ready) or 0) then
		text = "A3: End Turn until turn " .. Str(f.ready) .. " (now " .. t .. "), then press A3"
	elseif step == 1 then
		local d1 = UnitDamage(u)
		local n = math.max(1, AlUnits(me))
		local al0 = AlAmount(me)
		AlChange(me, 2 * n)
		f = { step = 2, turn = t, d1 = d1 }
		text = "A3 step 2: VEF-AIR-1 damage " .. d1 .. (d1 >= 30 and " (no heal with 0 Aluminium)" or " (HEALED with 0 Aluminium)") ..
			"; Aluminium " .. al0 .. " -> " .. AlAmount(me) .. " (+2 for each of your " .. n .. " Aluminium units). End Turn once, then press A3"
	elseif t <= (tonumber(f.turn) or t) then
		text = "A3: End Turn first, then press A3"
	else
		local d2 = UnitDamage(u)
		f.step = 3
		text = "A3 step 3: VEF-AIR-1 damage " .. Str(f.d1) .. " -> " .. d2 ..
			(d2 < (tonumber(f.d1) or 0) and " (healed with Aluminium)" or " (NO heal with Aluminium)") .. "; Aluminium now " .. AlAmount(me)
	end
	a.a3 = f
	AirPrint("A3 step " .. Str(f.step) .. ": Aluminium " .. AlAmount(me) .. ", your Aluminium units " .. AlUnits(me))
	AirProbeUnit("AIR-1", u)
	Focus(st, u:GetX(), u:GetY(), me, u:GetID(), p.stamp)
	AirAnswer(st, p, "AIR_A3", text)
end

CMD.air_ally = function(me, p)
	local st = Session("AIR_A4", me)
	if st == nil then return end
	local F = st.friend
	local capF = (F ~= nil) and Capital(F) or nil
	if capF == nil then Check("AIR_A4", "CHECK", "F has no capital"); return end
	local a = AirState(st)
	if not Diplo(me, "HasAllied", F) then
		GrantCivic(me, CIVIC_ALLY)
		GrantCivic(F, CIVIC_ALLY)
		SetDiploPair("air_ally", me, F, "SetHasAllied", true)
	end
	local allied = Diplo(me, "HasAllied", F)
	local fx, fy = capF:GetX(), capF:GetY()
	local u = NewUnit("air_ally", me, AIR_UT, Map.GetPlot(fx, fy), "VEF-AIR-V")
	AirSet(a, "AIR-V", u)
	AirPrint("AIR-V Create(" .. AIR_UT .. ") for you in F's capital " .. fx .. "," .. fy .. " (allied " .. tostring(allied) .. ") -> " ..
		(u and ("unit " .. u:GetID() .. " @" .. u:GetX() .. "," .. u:GetY()) or "nil"))
	local g = AirProbePlot("F's capital", fx, fy)
	AirProbeUnit("AIR-V", u)
	Focus(st, fx, fy, me, u and u:GetID() or -1, p.stamp)
	local _, t = AirFact(AirEntry(a, "AIR-V"))
	AirAnswer(st, p, "AIR_A4", "A4: allied with F " .. tostring(allied) .. "; your plane for F's capital: " ..
		(u and t or "REFUSED (Create returned nil)") .. "; F's capital: " .. g)
end

CMD.air_carrier = function(me, p)
	local st = Session("AIR_A5", me)
	if st == nil then return end
	local a = AirState(st)
	local f = type(a.a5) == "table" and a.a5 or {}
	if tonumber(f.step) == 1 then
		-- second press: after the send
		local cv, cvFact = AirFact(AirEntry(a, "CV"))
		local pl, plFact = AirFact(AirEntry(a, "AIR-CV"))
		local text
		if cv ~= nil then
			text = "A5: VEF-CV is still on the map (" .. cvFact .. "): send it first, then press A5 again; plane VEF-AIR-CV " .. plFact
		else
			local rec = Newest(EFV_Records.Load(), function(r) return r.senderID == me and r.unitType == CV_UT end)
			f.step = 2
			text = "A5 after the send: carrier " .. (rec and ("VEF record " .. rec.id .. " " .. Str(rec.state) .. " to P" .. Str(rec.recipientID))
				or "gone, no VEF record") .. "; plane VEF-AIR-CV " .. plFact
		end
		if pl ~= nil then
			AirProbePlot("AIR-CV's tile", pl:GetX(), pl:GetY())
			AirProbeUnit("AIR-CV", pl)
			Focus(st, pl:GetX(), pl:GetY(), me, pl:GetID(), p.stamp)
		else
			Focus(st, tonumber(f.x) or -1, tonumber(f.y) or -1, nil, nil, p.stamp)
		end
		a.a5 = f
		AirAnswer(st, p, "AIR_A5", text)
		return
	end
	local cap = Capital(me)
	if cap == nil then Check("AIR_A5", "CHECK", "you have no capital"); return end
	local cx, cy = cap:GetX(), cap:GetY()
	local water = nil
	for ring = 1, 3 do
		for _, q in ipairs(Ring(cx, cy, ring)) do
			if water == nil and FreeWater(q) and PlotOwner(q) == me then water = q end
		end
	end
	local own = water ~= nil
	if water == nil then water = FindFreePlot(cx, cy, true) end
	if water == nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		AirAnswer(st, p, "AIR_A5", "A5: no free water within 6 tiles of your capital: skip A5 (next time found the capital on the coast)")
		return
	end
	local wx, wy = water:GetX(), water:GetY()
	local cv = NewUnit("air_carrier", me, CV_UT, water, "VEF-CV")
	if cv ~= nil then FullMoves(cv) end
	local pl = (cv ~= nil) and NewUnit("air_carrier", me, AIR_UT, water, "VEF-AIR-CV") or nil
	AirSet(a, "CV", cv)
	AirSet(a, "AIR-CV", pl)
	AirPrint("CV Create(" .. CV_UT .. ") at " .. wx .. "," .. wy .. " (your water " .. tostring(own) .. ") -> " .. (cv and ("unit " .. cv:GetID()) or "nil") ..
		"; AIR-CV Create(" .. AIR_UT .. ") on its tile -> " .. (pl and ("unit " .. pl:GetID() .. " @" .. pl:GetX() .. "," .. pl:GetY()) or "nil"))
	AirProbePlot("carrier tile", wx, wy)
	AirProbeUnit("CV", cv)
	AirProbeUnit("AIR-CV", pl)
	-- what VEF's own send rule says for the carrier (the picker's rows)
	local store = EFV_Records.Load()
	local picks = {}
	for _, r in ipairs({ { "B", st.ally, FT_EXP }, { "F", st.friend, FT_EXP }, { "CS", st.cs, FT_CS } }) do
		local city = (r[2] ~= nil) and Capital(r[2]) or nil
		local res = "no city"
		if cv ~= nil and city ~= nil then
			local okC, ok, reasons = pcall(EFV_EvaluateSend, me, cv, r[2], city, r[3], store)
			res = (not okC) and "error" or (ok and "ok" or table.concat(reasons or {}, "+"))
		end
		picks[#picks + 1] = r[1] .. " " .. res
	end
	a.a5 = { step = 1, x = wx, y = wy }
	Focus(st, wx, wy, me, cv and cv:GetID() or -1, p.stamp)
	local _, cvFact = AirFact(AirEntry(a, "CV"))
	local _, plFact = AirFact(AirEntry(a, "AIR-CV"))
	AirAnswer(st, p, "AIR_A5", "A5: carrier VEF-CV " .. cvFact .. (own and "" or " (NOT your water: no send possible)") ..
		"; plane VEF-AIR-CV " .. plFact .. "; send rule: " .. table.concat(picks, ", ") .. ". Send VEF-CV now, then press A5 again")
end

-- A9 air_rebase (EFV_Dev 1.0.5.1; FIXPLAN_air_units.md section 11;
-- EFV/TESTING_1.0.5.md step 10). A script Create never puts a plane aboard
-- (SPIKES 8.2), a Rebase by hand does. Press 1: Carrier VEF-CV9 on your own
-- free water within 3 rings of your capital (A5's search), Fighter VEF-AIR-9
-- on free water 2 or 3 tiles from it (never its tile; else free land),
-- VEF's send rule for the carrier (expect no CARRIER_LOADED), the plane
-- selected. You rebase VEF-AIR-9 onto VEF-CV9, then press A9 again: the
-- carrier's tile and both units probed, the send rule again (expect
-- CARRIER_LOADED), the carrier selected.
CMD.air_rebase = function(me, p)
	local st = Session("AIR_A9", me)
	if st == nil then return end
	local a = AirState(st)
	local f = type(a.a9) == "table" and a.a9 or {}
	local function Rule(cv)
		if cv == nil then return "no carrier" end
		local okC, codes = pcall(EFV_UnitSendReasons, cv, me, EFV_Records.Load())
		if not okC then return "error " .. Str(codes) end
		return (#codes == 0) and "ok" or table.concat(codes, "+")
	end
	if tonumber(f.step) == 1 then
		local cv, cvFact = AirFact(AirEntry(a, "CV9"))
		local pl, plFact = AirFact(AirEntry(a, "AIR-9"))
		local same = "no"
		if cv ~= nil then
			AirProbePlot("CV9's tile", cv:GetX(), cv:GetY())
			if pl ~= nil and pl:GetX() == cv:GetX() and pl:GetY() == cv:GetY() then same = "yes" end
		end
		AirProbeUnit("CV9", cv)
		AirProbeUnit("AIR-9", pl)
		if cv ~= nil then Focus(st, cv:GetX(), cv:GetY(), me, cv:GetID(), p.stamp) else Focus(st, -1, -1, nil, nil, p.stamp) end
		AirAnswer(st, p, "AIR_A9", "A9: carrier VEF-CV9 " .. cvFact .. "; plane VEF-AIR-9 " .. plFact ..
			"; plane on the carrier's tile " .. same .. "; carrier send rule now: " .. Rule(cv))
		return
	end
	local cap = Capital(me)
	if cap == nil then Check("AIR_A9", "CHECK", "you have no capital"); return end
	local cx, cy = cap:GetX(), cap:GetY()
	local water = nil
	for ring = 1, 3 do
		for _, q in ipairs(Ring(cx, cy, ring)) do
			if water == nil and FreeWater(q) and PlotOwner(q) == me then water = q end
		end
	end
	if water == nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		AirAnswer(st, p, "AIR_A9", "A9: none of your own free water within 3 tiles of your capital: skip A9 (next time found the capital on the coast)")
		return
	end
	local wx, wy = water:GetX(), water:GetY()
	local cv = NewUnit("air_rebase", me, CV_UT, water, "VEF-CV9")
	if cv ~= nil then FullMoves(cv) end
	local spot, onLand = nil, false
	for ring = 2, 3 do
		for _, q in ipairs(Ring(wx, wy, ring)) do
			if spot == nil and FreeWater(q) then spot = q end
		end
	end
	if spot == nil then
		for ring = 2, 3 do
			for _, q in ipairs(Ring(wx, wy, ring)) do
				if spot == nil and FreeLand(q) then spot, onLand = q, true end
			end
		end
	end
	local pl = (cv ~= nil) and NewUnit("air_rebase", me, AIR_UT, spot, "VEF-AIR-9") or nil
	AirSet(a, "CV9", cv)
	AirSet(a, "AIR-9", pl)
	AirPrint("CV9 Create(" .. CV_UT .. ") at " .. wx .. "," .. wy .. " -> " .. (cv and ("unit " .. cv:GetID()) or "nil") ..
		"; AIR-9 Create(" .. AIR_UT .. ") -> " .. (pl and ("unit " .. pl:GetID() .. " @" .. pl:GetX() .. "," .. pl:GetY()) or "nil") ..
		(onLand and " (on land: no free water 2-3 tiles from the carrier)" or ""))
	AirProbeUnit("CV9", cv)
	AirProbeUnit("AIR-9", pl)
	a.a9 = { step = 1, x = wx, y = wy }
	if pl ~= nil then Focus(st, pl:GetX(), pl:GetY(), me, pl:GetID(), p.stamp) else Focus(st, wx, wy, me, cv and cv:GetID() or -1, p.stamp) end
	local _, cvFact = AirFact(AirEntry(a, "CV9"))
	local _, plFact = AirFact(AirEntry(a, "AIR-9"))
	AirAnswer(st, p, "AIR_A9", "A9: carrier VEF-CV9 " .. cvFact .. "; plane VEF-AIR-9 " .. plFact ..
		(onLand and " (on land)" or "") .. "; carrier send rule now: " .. Rule(cv) ..
		". Rebase VEF-AIR-9 onto VEF-CV9, then press A9 again")
end

CMD.air_status = function(me, p)
	local st = Session("AIR_STATUS", me)
	if st == nil then return end
	local a = AirState(st)
	for _, e in ipairs(a.units) do
		local u = AirFact(e)
		if u ~= nil then AirProbeUnit(e.k, u) end
	end
	Focus(st, -1, -1, nil, nil, p.stamp)
	AirAnswer(st, p, "AIR_STATUS", "Air T" .. Turn() .. ": " .. AirStatusText(a))
end

-- At your turn start, for AIR_WATCH_TURNS turns after the last A button.
function EFV_Dev.EvalAir(st, t)
	local a = st.air
	if type(a) ~= "table" or type(a.units) ~= "table" or #a.units == 0 then return end
	if t > (tonumber(a.last) or -99) + AIR_WATCH_TURNS then return end
	Check("AIR_TURN", "INFO", AirStatusText(a))
end
end -- air-unit spike

-- ===========================================================================
-- Corps spike (EFV_Dev 1.0.4.4; FIXPLAN_corps.md section 5 and its "Designer
-- rulings" of 2026-10-11; EFV/TESTING_SPIKES.md). A new Ancient-era game
-- after S0: nobody has Nationalism or Mobilization yet, so you, B and the
-- city-states are hosts without the civics. GetMilitaryFormation and
-- SetMilitaryFormation are CONFIRMED in gameplay (SESSION_D 8, SESSION_F
-- 4.1, WarMachineScenario.lua:187-191); the downgrade (to STANDARD, or ARMY
-- to CORPS) is not.
--   C1 corps_probe    press per step. 1: your Swordsman VEF-C1, Galley
--                     VEF-C1N (free water near your capital, if any) and
--                     Tank VEF-C1T made and set to ARMY; Builder VEF-C1B and
--                     Battering Ram VEF-C1R made and read. 2: the three ->
--                     CORPS. 3: -> STANDARD. Every step reads formation, ID,
--                     XP, promotions, damage, moves, strength and the upkeep
--                     (your total gold upkeep and Oil upkeep, and
--                     UnitManager.GetUnit(Corps|Army)Maintenance by hash).
--   C2 corps_give     for city-state CS2 (no Nationalism): VEF-C2-A made,
--                     set to CORPS, then 2 promotions, 40 XP and 30 damage by
--                     hand (formation BEFORE the rest); VEF-C2-B through
--                     EFV_Units.Recreate with the same stand-in, then CORPS
--                     (AFTER). For B: VEF-C2-ARMY like C2-B, ARMY.
--   C3 corps_merge    1: you get Nationalism. B lends you two Spearmen (EXP
--                     records): VEF-C3-LENT (0 XP, 20 damage) next to your
--                     VEF-C3-OWN (30 XP, 1 promotion), and VEF-C3-LENT2 (30
--                     XP, 1 promotion) next to your VEF-C3-OWN2 (20 damage).
--                     You merge both pairs. 2 (after End Turn): every C3
--                     record still open ends its service next turn (its unit
--                     is put on your land first, so it goes home, no grace).
--   C4 corps_cs_ai    optional. City-state CS3 gets Nationalism; two of your
--                     Swordsmen as its City-State units (VEF-C4-1 / -2,
--                     service ends in 6 turns) next to its own VEF-C4-N.
--   C5 corps_cs_force three cases at the session's city-state CS, all at
--                     once, at least 4 tiles apart: 1) your tracked VEF-C5-S
--                     -> CORPS, the city-state's VEF-C5-N removed, service
--                     ends next turn; 2) the city-state's VEF-C5-M -> CORPS,
--                     your tracked VEF-C5-A next to it removed; 3) your
--                     tracked VEF-C5-X removed, a city-state Builder
--                     VEF-C5-BLD 2 tiles away, no Corps near.
--   C6 corps_host     hosts without the civics (read first and reported):
--                     EFV_Units.Recreate + SetMilitaryFormation make
--                     VEF-C6-CORPS and VEF-C6-ARMY for you, lent by B (EXP
--                     records, full moves, C's Warrior VEF-C6-FOE next to the
--                     Corps to attack), VEF-C6-B (B's Corps, lent by you) and
--                     VEF-C6-CS (CS2's Army, lent by you).
--   C7 corps_trip     1: your Swordsman VEF-C7 with 2 promotions, 20 XP, 30
--                     damage, ARMY; then VEF's own return path:
--                     EFV_Units.Snapshot, Remove, Recreate (route B for you:
--                     your UI takes the promotions back) and
--                     SetMilitaryFormation(snapshot). Upkeep read at each
--                     stage. 2: read back.
--   C Status          corps_status: every C unit now.
-- At each of your turn starts for C_WATCH turns after the last C button:
-- CORPS_WATCH, the same text as C Status (records included).
-- Raw facts: "[EFV][Corps] G ..." lines. Unverified readers (HasCivic,
-- GetTotalMaintenance, GetUnitResourceDemandPerTurn, UnitManager.Get*
-- Maintenance, CanFormMilitaryFormation, unit GetCombat) are looked up BY
-- NAME and pcall-guarded (MISSING / ERROR, never thrown), so api_audit does
-- not see them. The panel's answer: st.corps.ans (stamp, ASCII text). MP
-- style: the synced handler only, no pairs() over state, no random, no
-- local-player call. Own do-block (Lua's 200-local limit), like the air
-- spike; EvalCorps is reached as EFV_Dev.EvalCorps.
-- ---------------------------------------------------------------------------
do
local SW, SP = "UNIT_SWORDSMAN", "UNIT_SPEARMAN"
local C_WATCH = 6

local function CPrint(msg) print("[EFV][Corps] G " .. Str(msg)) end

-- obj:name(...) (static: obj.name(...)) looked up by name:
-- "OK", r | "MISSING", why | "ERROR", why. CShort: the value or the status.
local function CCall(obj, name, static, ...)
	local f, why = DpMethod(obj, name)
	if f == nil then return "MISSING", name .. " " .. Str(why) end
	local args, n = { ... }, select("#", ...)
	local r
	if static then r = { pcall(f, unpack(args, 1, n)) } else r = { pcall(f, obj, unpack(args, 1, n)) } end
	if not r[1] then return "ERROR", Str(r[2]) end
	return "OK", r[2]
end

local function CShort(s, v) return (s == "OK") and Str(v) or s end

local function FName(f)
	local M = MilitaryFormationTypes or {}
	if f == nil then return "nil" end
	if f == M.STANDARD_FORMATION then return "STANDARD" end
	if f == M.CORPS_FORMATION then return "CORPS" end
	if f == M.ARMY_FORMATION then return "ARMY" end
	return "value " .. Str(f)
end

local function CForm(u)
	local ok, f = pcall(function() return u:GetMilitaryFormation() end)
	return ok and FName(f) or "ERROR"
end

-- SetMilitaryFormation(f) (CONFIRMED for CORPS and ARMY; the downgrade is
-- what C1 asks), logged with the formation before and after.
local function CSetForm(label, u, f)
	if u == nil then CPrint(label .. " SetMilitaryFormation(" .. FName(f) .. "): no unit"); return "no unit" end
	local before = CForm(u)
	local ok, err = pcall(function() u:SetMilitaryFormation(f) end)
	local after = CForm(u)
	CPrint(label .. " SetMilitaryFormation(" .. FName(f) .. ") ok=" .. tostring(ok) .. (ok and "" or (" err=" .. Str(err))) ..
		": " .. before .. " -> " .. after)
	return after
end

-- Formation, strength, XP, promotions, damage, moves and tile of u.
local function CFact(u)
	local xp = XPInfo(u)
	local s, str = CCall(u, "GetCombat")
	local mv, promos = "?", -1
	pcall(function() mv = Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves()) end)
	pcall(function() promos = #PromoRows(u) end)
	return "P" .. u:GetOwner() .. "/" .. u:GetID() .. " " .. CForm(u) .. ", strength " .. CShort(s, str) .. ", xp " .. xp ..
		", promotions " .. promos .. ", dmg " .. UnitDamage(u) .. ", moves " .. mv .. " @" .. u:GetX() .. "," .. u:GetY()
end

-- Nationalism and Mobilization of pid (GetCulture():HasCivic by name).
local function CCivics(pid)
	local out = {}
	for _, c in ipairs({ { "CIVIC_NATIONALISM", "Nationalism" }, { "CIVIC_MOBILIZATION", "Mobilization" } }) do
		local _, row = pcall(function() return GameInfo.Civics[c[1]] end)
		local okC, cul = pcall(function() return Players[pid]:GetCulture() end)
		local s, has = CCall(okC and cul or nil, "HasCivic", false, row and row.Index or -1)
		out[#out + 1] = c[2] .. " " .. ((s == "OK") and (has and "yes" or "no") or s)
	end
	return table.concat(out, ", ")
end

-- pid's total gold upkeep and Oil upkeep per turn (G readers by name).
local function CUpkeep(pid)
	local okT, tr = pcall(function() return Players[pid]:GetTreasury() end)
	local okR, rs = pcall(function() return Players[pid]:GetResources() end)
	local s1, g = CCall(okT and tr or nil, "GetTotalMaintenance")
	local s2, o = CCall(okR and rs or nil, "GetUnitResourceDemandPerTurn", false, "RESOURCE_OIL")
	return "gold upkeep " .. CShort(s1, g) .. ", Oil upkeep " .. CShort(s2, o)
end

-- The per-type readers ReportScreen.lua:319-334 uses in the UI, tried in G.
local function CTypeUpkeep(ut)
	local row = GameInfo.Units[ut]
	local parts = {}
	for _, fn in ipairs({ "GetUnitMaintenance", "GetUnitCorpsMaintenance", "GetUnitArmyMaintenance" }) do
		local s, v = CCall(UnitManager, fn, true, row and row.Hash)
		parts[#parts + 1] = fn .. "=" .. CShort(s, v) .. ((s ~= "OK") and (" (" .. Str(v) .. ")") or "")
	end
	CPrint(ut .. " Maintenance (data) " .. Str(row and row.Maintenance) .. "; " .. table.concat(parts, " "))
end

-- Full moves now: FullMoves (RestoreMovementToFormation, LIKELY), else
-- ChangeMovesRemaining (CONFIRMED, the V2 refill).
local function CFull(u)
	if FullMoves(u) then return end
	pcall(function() u:ChangeMovesRemaining(u:GetMaxMoves() - u:GetMovesRemaining()) end)
end

local function CState(st)
	local c = Sub(st, "corps")
	if type(c.units) ~= "table" then c.units = {} end
	return c
end

-- Sets (u nil: drops) the C unit with key k; rid = its VEF record.
local function CSet(c, k, u, rid)
	local list = {}
	for _, e in ipairs(c.units) do if e.k ~= k then list[#list + 1] = e end end
	if u ~= nil then
		list[#list + 1] = { k = k, o = u:GetOwner(), u = u:GetID(), t = UnitTypeName(u), x = u:GetX(), y = u:GetY(), rid = rid }
	end
	c.units = list
end

-- The live unit of entry e (nil when gone) and its facts, with the record.
local function CFactOf(e, store)
	local u = FindUnit(e.o, e.u)
	local txt
	if u == nil or UnitTypeName(u) ~= e.t then
		u, txt = nil, "gone"
	else
		local okM, m, why = pcall(EFV_UnitMatches, u, e.o, e.u, e.t)
		if okM and not m and (why == "GONE_OFFMAP" or why == "GONE_DEAD") then
			u, txt = nil, "gone (" .. why .. ")"
		else
			txt = CFact(u) .. ((tonumber(e.x) ~= u:GetX() or tonumber(e.y) ~= u:GetY()) and " (moved)" or "")
		end
	end
	if e.rid ~= nil and store ~= nil then
		local rec = EFV_Records.Get(store, e.rid)
		txt = txt .. ", record " .. Str(e.rid) .. " " .. (rec and Str(rec.state) or "closed")
	end
	return u, txt
end

-- Every C unit whose key starts with prefix (nil: all).
local function CList(c, store, prefix)
	local parts = {}
	for _, e in ipairs(c.units) do
		if prefix == nil or string.sub(e.k, 1, #prefix) == prefix then
			local _, t = CFactOf(e, store)
			parts[#parts + 1] = e.k .. " " .. t
		end
	end
	return (#parts > 0) and table.concat(parts, "; ") or "no C units yet"
end

local function CAnswer(st, p, id, text, verdict)
	local c = CState(st)
	c.ans = { stamp = Num(p.stamp, 0), text = text }
	c.last = Turn()
	ScnSave(st)
	Check(id, verdict or "INFO", text)
end

-- A stand-in record for EFV_Units.Recreate (n level-1 promotions).
local function CStand(k, ut, n, xp, dmg)
	local promos = LevelOnePromotions(ut, n)
	return { id = k, unitType = ut, veteranName = "VEF-" .. k, damage = dmg, experience = xp, level = 1 + #promos,
		promotions = promos, formation = 0 }
end

-- VEF's restore path for owner on plot, then formation f (nil: none).
local function CRecreate(store, c, k, owner, stand, plot, f)
	if plot == nil then CPrint(k .. ": no free plot"); CSet(c, k, nil); return nil end
	local ok, u = pcall(EFV_Units.Recreate, store, owner, stand, plot, Turn())
	if not ok then CPrint(k .. " Recreate ERROR " .. Str(u)); u = nil end
	if u ~= nil and f ~= nil then CSetForm(k, u, f) end
	CSet(c, k, u)
	CPrint(k .. " EFV_Units.Recreate(P" .. owner .. ", " .. stand.unitType .. ", " .. #stand.promotions .. " promotions, xp " ..
		stand.experience .. ", dmg " .. stand.damage .. ") then " .. (f and FName(f) or "no formation") .. " -> " .. (u and CFact(u) or "nil"))
	return u
end

-- A deployed record "sender lent u to recipient" (MakeRecord), ending its
-- service in endsIn turns (nil: the full duration). Returns the record ID.
local function CLend(store, c, k, u, force, sender, recipient, endsIn)
	local origin, dest = Capital(sender), Capital(recipient)
	if u == nil or origin == nil or dest == nil then return nil end
	local dur = (force == FT_CS) and EFV_Config.CS_EXPEDITIONARY_DURATION or EFV_Config.EXPEDITIONARY_DURATION
	local basis = (force == FT_CS) and "CITY_STATE" or (EFV_PartnerBasis(sender, recipient) or "FRIEND")
	local rec = MakeRecord(store, u, { force = force, sender = sender, recipient = recipient, basis = basis, origin = origin,
		dest = dest, duration = dur, deployedTurn = endsIn and (Turn() + endsIn - dur) or nil })
	if rec == nil then return nil end
	CSet(c, k, u, rec.id)
	CPrint(k .. " record " .. rec.id .. " " .. Str(force) .. " " .. PlayerName(sender) .. " -> " .. PlayerName(recipient) ..
		", service ends in " .. Str(endsIn or dur) .. " turns")
	return rec.id
end

-- CS2: a second city-state (C2, C6), kept for the session; met and revealed.
local function CCs2(st, me, c)
	if c.cs2 == nil or not Alive(c.cs2) then
		c.cs2 = PickCityState(st, me, { st.cs }) or st.cs
	end
	local city = Capital(c.cs2)
	MeetPair(me, c.cs2)
	if city ~= nil then RevealCity(me, city, nil) end
	return c.cs2, city
end

-- A free land plot within maxR of (x, y), owned by one of owners (-1:
-- unowned), at least minD tiles from every plot in far.
local function CFar(x, y, maxR, owners, far, minD)
	return FindPlot(x, y, maxR, function(q)
		if not OwnedByAny(owners)(q) then return false end
		for _, f in ipairs(far) do
			if Dist(q:GetX(), q:GetY(), f:GetX(), f:GetY()) < minD then return false end
		end
		return true
	end, 1)
end

-- C1: one formation step per press for your Swordsman, Galley and Tank.
CMD.corps_probe = function(me, p)
	local st = Session("CORPS_C1", me)
	if st == nil then return end
	local cap = Capital(me)
	if cap == nil then Check("CORPS_C1", "CHECK", "you have no capital"); return end
	local c = CState(st)
	local f = type(c.c1) == "table" and c.c1 or {}
	local step = tonumber(f.step) or 0
	local M = MilitaryFormationTypes
	local keys = { "C1", "C1N", "C1T" }
	if step == 0 or step >= 3 then
		for _, k in ipairs({ "C1", "C1N", "C1T", "C1B", "C1R" }) do
			local old = nil
			for _, e in ipairs(c.units) do if e.k == k then old = FindUnit(e.o, e.u) end end
			if old ~= nil then pcall(function() Players[me]:GetUnits():Destroy(old) end) end
			CSet(c, k, nil)
		end
		local g0 = CUpkeep(me)
		local cx, cy = cap:GetX(), cap:GetY()
		local made = {}
		for _, d in ipairs({ { "C1", SW, false }, { "C1N", "UNIT_GALLEY", true }, { "C1T", "UNIT_TANK", false },
			{ "C1B", "UNIT_BUILDER", false }, { "C1R", "UNIT_BATTERING_RAM", false } }) do
			local plot = d[3] and FindFreePlot(cx, cy, true) or FindPlot(cx, cy, 4, OwnedByAny({ -1, me }), 1)
			local u = NewUnit("corps_probe", me, d[2], plot, "VEF-" .. d[1])
			CSet(c, d[1], u)
			CTypeUpkeep(d[2])
			made[#made + 1] = d[1] .. " " .. (u and CForm(u) or "not made")
			if u ~= nil then
				local s, v = CCall(UnitManager, "CanFormMilitaryFormation", true, me, u:GetDomain(), M.CORPS_FORMATION, u)
				CPrint(d[1] .. " " .. d[2] .. " made: " .. CFact(u) .. "; CanFormMilitaryFormation(CORPS)=" .. CShort(s, v))
			end
		end
		for _, e in ipairs(c.units) do if e.k == "C1" then local u1 = FindUnit(e.o, e.u); if u1 ~= nil then CFull(u1) end end end
		f = { step = 0, g0 = g0, g1 = CUpkeep(me), made = table.concat(made, ", ") }
	end
	step = (tonumber(f.step) or 0) + 1
	local want = ({ M.ARMY_FORMATION, M.CORPS_FORMATION, M.STANDARD_FORMATION })[step]
	local parts = {}
	local focusU = nil
	for _, k in ipairs(keys) do
		local u = nil
		for _, e in ipairs(c.units) do if e.k == k then u = FindUnit(e.o, e.u) end end
		if u ~= nil then
			CSetForm(k, u, want)
			parts[#parts + 1] = k .. " " .. CFact(u)
			if k == "C1" then focusU = u end
		else
			parts[#parts + 1] = k .. " not on the map"
		end
	end
	local up = CUpkeep(me)
	CPrint("C1 step " .. step .. " (" .. FName(want) .. "): " .. up .. "; before the C1 units " .. Str(f.g0) .. "; plain C1 units " .. Str(f.g1))
	f.step = step
	c.c1 = f
	if focusU ~= nil then Focus(st, focusU:GetX(), focusU:GetY(), me, focusU:GetID(), p.stamp) else Focus(st, -1, -1, nil, nil, p.stamp) end
	local head = "C1 step " .. step .. " of 3 -> " .. FName(want) .. ": "
	if step == 1 then head = head .. "Builder/Ram: " .. Str(f.made) .. "; " end
	CAnswer(st, p, "CORPS_C1", head .. table.concat(parts, "; ") .. ". Upkeep now: " .. up .. " (plain units: " .. Str(f.g1) ..
		")" .. (step < 3 and ". Press C1 again for the next step" or ". Done (C1 again starts over)"))
end

-- C2: formations for hosts without the civic, formation before or after the
-- restore of promotions, XP and damage.
CMD.corps_give = function(me, p)
	local st = Session("CORPS_C2", me)
	if st == nil then return end
	local c = CState(st)
	local B = st.ally
	local cs2, csCity = CCs2(st, me, c)
	local capB = Capital(B)
	if csCity == nil or capB == nil then Check("CORPS_C2", "CHECK", "no city-state city or no capital of B"); return end
	local M = MilitaryFormationTypes
	local store = EFV_Records.Load()
	local promos = LevelOnePromotions(SW, 2)
	-- A: Create, CORPS, then promotions, XP and damage by hand.
	local a = NewUnit("corps_give", cs2, SW, FindPlot(csCity:GetX(), csCity:GetY(), 3, OwnedByAny({ -1, cs2 }), 1), "VEF-C2-A")
	if a ~= nil then
		CSetForm("C2-A", a, M.CORPS_FORMATION)
		for _, nm in ipairs(promos) do SetPromo(a, GameInfo.UnitPromotions[nm].Index) end
		TopUp(a, 40)
		pcall(function() a:SetDamage(30) end)
	end
	CSet(c, "C2-A", a)
	CPrint("C2-A formation BEFORE the restore: " .. (a and CFact(a) or "not made"))
	local b = CRecreate(store, c, "C2-B", cs2, CStand("C2-B", SW, 2, 40, 30),
		FindPlot(csCity:GetX(), csCity:GetY(), 3, OwnedByAny({ -1, cs2 }), 1), M.CORPS_FORMATION)
	local r = CRecreate(store, c, "C2-ARMY", B, CStand("C2-ARMY", SW, 2, 40, 30),
		FindPlot(capB:GetX(), capB:GetY(), 3, OwnedByAny({ -1, B }), 1), M.ARMY_FORMATION)
	EFV_Records.Commit(store)
	Focus(st, csCity:GetX(), csCity:GetY(), nil, nil, p.stamp)
	local function Line(k, u) return k .. " " .. (u and (CFact(u) .. ", promotions " .. PromoCount(u, promos) .. "/" .. #promos) or "not made") end
	CAnswer(st, p, "CORPS_C2", "C2 (wanted: 2 promotions, xp 40, dmg 30): " .. Line("C2-A (CORPS before)", a) .. "; " ..
		Line("C2-B (CORPS after)", b) .. "; " .. Line("C2-ARMY for B", r) .. ". Civics: " .. PlayerName(cs2) .. " " .. CCivics(cs2) ..
		"; B " .. CCivics(B) .. ". End Turn, then C Status")
end

-- C3: a real merge by you (the host) of a unit B lent you.
CMD.corps_merge = function(me, p)
	local st = Session("CORPS_C3", me)
	if st == nil then return end
	local c = CState(st)
	local B = st.ally
	local cap = Capital(me)
	if cap == nil then Check("CORPS_C3", "CHECK", "you have no capital"); return end
	local store = EFV_Records.Load()
	local f = type(c.c3) == "table" and c.c3 or {}
	if tonumber(f.step) == 1 and Turn() > (tonumber(f.turn) or 0) then
		-- step 2: every open C3 record ends its service next turn, on your land
		local parts = {}
		for _, e in ipairs(c.units) do
			local rec = (e.rid ~= nil) and EFV_Records.Get(store, e.rid) or nil
			if rec ~= nil and string.sub(e.k, 1, 2) == "C3" then
				local u = RecUnit(rec)
				if u ~= nil and PlotOwner(Map.GetPlot(u:GetX(), u:GetY())) ~= me then
					local q = FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1)
					if q ~= nil then Place(u, q) end
				end
				rec.deployedTurn = Turn() + 1 - (tonumber(rec.durationTurns) or EFV_Config.EXPEDITIONARY_DURATION)
				EFV_Records.Touch(store)
				parts[#parts + 1] = e.k .. " record " .. rec.id .. " " .. Str(rec.state) .. (u and (" " .. CForm(u)) or " (no unit)")
			end
		end
		EFV_Records.Commit(store)
		f.step = 2
		c.c3 = f
		Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
		CAnswer(st, p, "CORPS_C3", "C3 step 2: " .. ((#parts > 0) and (table.concat(parts, "; ") .. " end their service next turn")
			or "no C3 record is open any more (both lent units absorbed?)") .. ". Now: " .. CList(c, store, "C3") .. ". End Turn, then C Status")
		return
	end
	if tonumber(f.step) == 1 then
		CAnswer(st, p, "CORPS_C3", "C3: merge both pairs now (see the first answer), End Turn, then press C3 again. Now: " .. CList(c, store, "C3"))
		return
	end
	GrantCivic(me, "CIVIC_NATIONALISM")
	local cx, cy = cap:GetX(), cap:GetY()
	local placed = {}
	local function Pair(kLent, kOwn, lentXP, lentPromo, lentDmg, ownXP, ownPromo, ownDmg)
		local q1 = CFar(cx, cy, 4, { -1, me }, placed, 3)
		local lent = NewUnit("corps_merge", me, SP, q1, "VEF-" .. kLent)
		if lent == nil then return nil, nil end
		placed[#placed + 1] = q1
		local q2 = FindPlot(lent:GetX(), lent:GetY(), 1, OwnedByAny({ -1, me }), 1)
		local own = NewUnit("corps_merge", me, SP, q2, "VEF-" .. kOwn)
		if q2 ~= nil then placed[#placed + 1] = q2 end
		for _, d in ipairs({ { lent, lentXP, lentPromo, lentDmg }, { own, ownXP, ownPromo, ownDmg } }) do
			local u = d[1]
			if u ~= nil then
				local pr = d[3] and LevelOnePromotions(SP, 1)[1] or nil
				if pr ~= nil then SetPromo(u, GameInfo.UnitPromotions[pr].Index) end
				TopUp(u, d[2])
				pcall(function() u:SetDamage(d[4]) end)
				CFull(u)
			end
		end
		CLend(store, c, kLent, lent, FT_EXP, B, me, nil)
		CSet(c, kOwn, own)
		CPrint(kLent .. " " .. CFact(lent) .. "; " .. kOwn .. " " .. (own and CFact(own) or "not made"))
		return lent, own
	end
	local l1 = Pair("C3-LENT", "C3-OWN", 0, false, 20, 30, true, 0)
	Pair("C3-LENT2", "C3-OWN2", 30, true, 0, 0, false, 20)
	EFV_Records.Commit(store)
	c.c3 = { step = 1, turn = Turn() }
	c.trace = Turn()        -- merge trace (1.0.4.5) until the next turn
	if l1 ~= nil then Focus(st, l1:GetX(), l1:GetY(), me, l1:GetID(), p.stamp) else Focus(st, cx, cy, nil, nil, p.stamp) end
	CAnswer(st, p, "CORPS_C3", "C3: you have Nationalism (" .. CCivics(me) .. "). Pair 1: select VEF-C3-LENT, Form Corps, click VEF-C3-OWN. " ..
		"Pair 2: select VEF-C3-OWN2, Form Corps, click VEF-C3-LENT2. Then End Turn and press C3 again. Merge trace on until the next turn. Now: " ..
		CList(c, store, "C3"))
end

-- C4 (optional): does the city-state AI merge lent units by itself?
CMD.corps_cs_ai = function(me, p)
	local st = Session("CORPS_C4", me)
	if st == nil then return end
	local c = CState(st)
	local cs3 = PickCityState(st, me, { st.cs, c.cs2 or -1 }) or c.cs2 or st.cs
	local city = Capital(cs3)
	if city == nil then Check("CORPS_C4", "CHECK", "no city-state with a city"); return end
	MeetPair(me, cs3)
	RevealCity(me, city, nil)
	GrantCivic(cs3, "CIVIC_NATIONALISM")
	local store = EFV_Records.Load()
	local placed = {}
	for _, d in ipairs({ { "C4-1", true }, { "C4-2", true }, { "C4-N", false } }) do
		local q = (#placed == 0) and FindPlot(city:GetX(), city:GetY(), 3, OwnedByAny({ -1, cs3 }), 1)
			or FindPlot(placed[1]:GetX(), placed[1]:GetY(), 1, OwnedByAny({ -1, cs3 }), 1)
		local u = NewUnit("corps_cs_ai", cs3, SW, q, "VEF-" .. d[1])
		if u ~= nil then
			placed[#placed + 1] = q
			CFull(u)
			if d[2] then CLend(store, c, d[1], u, FT_CS, me, cs3, 6) else CSet(c, d[1], u) end
		end
	end
	EFV_Records.Commit(store)
	Focus(st, city:GetX(), city:GetY(), nil, nil, p.stamp)
	CAnswer(st, p, "CORPS_C4", "C4: " .. PlayerName(cs3) .. " " .. CCivics(cs3) .. "; " .. CList(c, store, "C4") ..
		". Watch for a Corps star on its units at your next 6 turn starts (CORPS_WATCH)")
end

-- C5: the three city-state cases of FIXPLAN_corps.md Part 1 (b, a, e).
CMD.corps_cs_force = function(me, p)
	local st = Session("CORPS_C5", me)
	if st == nil then return end
	local c = CState(st)
	local cs = st.cs
	local city = Capital(cs)
	if city == nil then Check("CORPS_C5", "CHECK", "the city-state CS has no city"); return end
	MeetPair(me, cs)
	RevealCity(me, city, nil)
	local M = MilitaryFormationTypes
	local store = EFV_Records.Load()
	local cx, cy = city:GetX(), city:GetY()
	local own = { -1, cs }
	local notes = {}
	local function Make(k, ut, plot)
		local u = NewUnit("corps_cs_force", cs, ut, plot, "VEF-" .. k)
		if u == nil then notes[#notes + 1] = k .. " not made (no free land)" end
		return u
	end
	-- case 1: the lent unit leads the Corps; its service ends next turn
	local s1 = Make("C5-S", SW, FindPlot(cx, cy, 2, OwnedByAny(own), 1))
	local far = { s1 and Map.GetPlot(s1:GetX(), s1:GetY()) or city }
	if s1 ~= nil then
		local n = Make("C5-N", SW, FindPlot(s1:GetX(), s1:GetY(), 1, OwnedByAny(own), 1))
		CLend(store, c, "C5-S", s1, FT_CS, me, cs, 1)
		CSetForm("C5-S", s1, M.CORPS_FORMATION)
		if n ~= nil then pcall(function() Players[cs]:GetUnits():Destroy(n) end) end
		Hold(store, s1)
	end
	-- case 2: the lent unit is absorbed into the city-state's Corps
	local m = Make("C5-M", SW, CFar(cx, cy, 10, own, far, 4))
	if m ~= nil then
		far[#far + 1] = Map.GetPlot(m:GetX(), m:GetY())
		local a = Make("C5-A", SW, FindPlot(m:GetX(), m:GetY(), 1, OwnedByAny(own), 1))
		CSetForm("C5-M", m, M.CORPS_FORMATION)
		CSet(c, "C5-M", m)
		Hold(store, m)
		if a ~= nil then
			far[#far + 1] = Map.GetPlot(a:GetX(), a:GetY())
			CLend(store, c, "C5-A", a, FT_CS, me, cs, nil)
			pcall(function() Players[cs]:GetUnits():Destroy(a) end)
		end
	end
	-- case 3: the lent unit disappears with a Builder near, no Corps near
	local x = Make("C5-X", SW, CFar(cx, cy, 12, own, far, 4))
	if x ~= nil then
		local bld = Make("C5-BLD", "UNIT_BUILDER", FindPlot(x:GetX(), x:GetY(), 2, OwnedByAny(own), 2))
		CLend(store, c, "C5-X", x, FT_CS, me, cs, nil)
		if bld ~= nil then
			CSet(c, "C5-BLD", bld)
			Hold(store, bld)
			CPrint("C5-BLD formation " .. CForm(bld) .. " (a civilian: STANDARD or not?)")
		end
		pcall(function() Players[cs]:GetUnits():Destroy(x) end)
	end
	EFV_Records.Commit(store)
	Focus(st, cx, cy, nil, nil, p.stamp)
	CAnswer(st, p, "CORPS_C5", "C5 at " .. PlayerName(cs) .. ": 1) C5-S leads a Corps, its partner removed, service ends next turn; " ..
		"2) C5-M is a Corps, lent C5-A next to it removed; 3) lent C5-X removed, a Builder 2 tiles away" ..
		((#notes > 0) and (" (" .. table.concat(notes, ", ") .. ")") or "") .. ". Now: " .. CList(c, store, "C5") ..
		". End Turn and watch VEF's notifications")
end

-- C6: hosts without Nationalism or Mobilization receive formations.
CMD.corps_host = function(me, p)
	local st = Session("CORPS_C6", me)
	if st == nil then return end
	local c = CState(st)
	local B = st.ally
	local cs2, csCity = CCs2(st, me, c)
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil or csCity == nil then Check("CORPS_C6", "CHECK", "your capital, B's or CS2's city is missing"); return end
	local civics = "you " .. CCivics(me) .. "; B " .. CCivics(B) .. "; " .. PlayerName(cs2) .. " " .. CCivics(cs2)
	CPrint("C6 civics before: " .. civics)
	local M = MilitaryFormationTypes
	local store = EFV_Records.Load()
	local cx, cy = cap:GetX(), cap:GetY()
	local uc = CRecreate(store, c, "C6-CORPS", me, CStand("C6-CORPS", SW, 0, 0, 0), FindPlot(cx, cy, 3, OwnedByAny({ -1, me }), 1), M.CORPS_FORMATION)
	local ua = CRecreate(store, c, "C6-ARMY", me, CStand("C6-ARMY", SW, 0, 0, 0), FindPlot(cx, cy, 3, OwnedByAny({ -1, me }), 1), M.ARMY_FORMATION)
	for _, d in ipairs({ { "C6-CORPS", uc }, { "C6-ARMY", ua } }) do
		if d[2] ~= nil then
			CFull(d[2])
			CLend(store, c, d[1], d[2], FT_EXP, B, me, nil)
		end
	end
	local foe = nil
	if uc ~= nil and st.enemy ~= nil and Alive(st.enemy) then
		foe = NewUnit("corps_host", st.enemy, "UNIT_WARRIOR", FindPlot(uc:GetX(), uc:GetY(), 1, OwnedByAny({ -1, me }), 1), "VEF-C6-FOE")
		if foe ~= nil then Hold(store, foe); CSet(c, "C6-FOE", foe) end
	end
	local ub = CRecreate(store, c, "C6-B", B, CStand("C6-B", SW, 1, 0, 20), FindPlot(capB:GetX(), capB:GetY(), 3, OwnedByAny({ -1, B }), 1), M.CORPS_FORMATION)
	if ub ~= nil then CLend(store, c, "C6-B", ub, FT_EXP, me, B, nil) end
	local us = CRecreate(store, c, "C6-CS", cs2, CStand("C6-CS", SW, 1, 0, 20), FindPlot(csCity:GetX(), csCity:GetY(), 3, OwnedByAny({ -1, cs2 }), 1), M.ARMY_FORMATION)
	if us ~= nil then CLend(store, c, "C6-CS", us, FT_CS, me, cs2, nil) end
	EFV_Records.Commit(store)
	if uc ~= nil then Focus(st, uc:GetX(), uc:GetY(), me, uc:GetID(), p.stamp) else Focus(st, cx, cy, nil, nil, p.stamp) end
	local warn = string.find(civics, "you Nationalism yes", 1, true) and " (YOU ALREADY HAVE NATIONALISM: C6 needs a host without it, run it before C3)" or ""
	CAnswer(st, p, "CORPS_C6", "C6 civics: " .. civics .. warn .. ". " .. CList(c, store, "C6") ..
		". Attack VEF-C6-FOE with VEF-C6-CORPS, move VEF-C6-ARMY; End Turn, then C Status")
end

-- C7: your Army through VEF's own return path (snapshot, remove, recreate).
CMD.corps_trip = function(me, p)
	local st = Session("CORPS_C7", me)
	if st == nil then return end
	local c = CState(st)
	local cap = Capital(me)
	if cap == nil then Check("CORPS_C7", "CHECK", "you have no capital"); return end
	local f = type(c.c7) == "table" and c.c7 or {}
	local store = EFV_Records.Load()
	if tonumber(f.step) == 1 then
		local u = nil
		for _, e in ipairs(c.units) do if e.k == "C7" then u = FindUnit(e.o, e.u) end end
		f.step = 2
		c.c7 = f
		if u == nil then CAnswer(st, p, "CORPS_C7", "C7 read back: VEF-C7 is gone"); return end
		local okF = CForm(u) == "ARMY"
		local pc = PromoCount(u, LevelOnePromotions(SW, 2))
		local xp = XPInfo(u)
		Focus(st, u:GetX(), u:GetY(), me, u:GetID(), p.stamp)
		CAnswer(st, p, "CORPS_C7", "C7 read back: " .. CFact(u) .. "; ARMY " .. (okF and "yes" or "NO") .. ", promotions " .. pc ..
			"/2, xp " .. xp .. " (wanted 20), dmg " .. UnitDamage(u) .. " (wanted 30). " .. CUpkeep(me) .. ". C7 again starts over")
		return
	end
	for _, e in ipairs(c.units) do
		if e.k == "C7" then
			local old = FindUnit(e.o, e.u)
			if old ~= nil then pcall(function() Players[me]:GetUnits():Destroy(old) end) end
		end
	end
	local plot = FindPlot(cap:GetX(), cap:GetY(), 3, OwnedByAny({ -1, me }), 1)
	local u = NewUnit("corps_trip", me, SW, plot, "VEF-C7")
	if u == nil then Check("CORPS_C7", "CHECK", "no free land near your capital"); return end
	local up = { CUpkeep(me) }
	for _, nm in ipairs(LevelOnePromotions(SW, 2)) do SetPromo(u, GameInfo.UnitPromotions[nm].Index) end
	TopUp(u, 20)
	pcall(function() u:SetDamage(30) end)
	CSetForm("C7", u, MilitaryFormationTypes.ARMY_FORMATION)
	up[2] = CUpkeep(me)
	local before = CFact(u)
	local snap = EFV_Units.Snapshot(u)
	local okRm = EFV_Units.Remove(u)
	up[3] = CUpkeep(me)
	local u2 = nil
	if snap ~= nil then
		local stand = { id = "C7", unitType = snap.unitType, veteranName = snap.veteranName, damage = snap.damage,
			experience = snap.experience, xpNext = snap.xpNext, level = snap.level, promotions = snap.promotions, formation = snap.formation }
		local okR, r = pcall(EFV_Units.Recreate, store, me, stand, plot, Turn())
		if okR then u2 = r else CPrint("C7 Recreate ERROR " .. Str(r)) end
		if u2 ~= nil then CSetForm("C7 restored", u2, snap.formation) end
	end
	EFV_Records.Commit(store)
	up[4] = CUpkeep(me)
	CSet(c, "C7", u2)
	CPrint("C7 before: " .. before .. "; snapshot formation " .. FName(snap and snap.formation) .. ", removed " .. tostring(okRm) ..
		"; after: " .. (u2 and CFact(u2) or "not recreated") .. "; upkeep plain / ARMY / removed / restored: " .. table.concat(up, " / "))
	c.c7 = { step = 1, turn = Turn() }
	if u2 ~= nil then Focus(st, u2:GetX(), u2:GetY(), me, u2:GetID(), p.stamp) else Focus(st, -1, -1, nil, nil, p.stamp) end
	CAnswer(st, p, "CORPS_C7", "C7: VEF-C7 " .. before .. " -> snapshot " .. FName(snap and snap.formation) .. ", removed, restored: " ..
		(u2 and CFact(u2) or "NOT recreated") .. ". Upkeep plain: " .. up[1] .. "; as ARMY: " .. up[2] .. "; restored: " .. up[4] ..
		". Your UI now takes the promotions back: wait a second, then press C7 again")
end

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.5 additions (FIXPLAN_corps.md "Rulings 2", R2.7):
--   C8 corps_split   press 1: B's VEF-C8-B (Recreate stand-in, 1 promotion,
--                    15 XP) set to ARMY, then 30 damage; CS2's VEF-C8-CS (no
--                    promotion) set to CORPS, 30 damage. The lent parts are
--                    stand-ins in st.corps.c8.parts: B's Army = host + YOU
--                    (2 promotions, 40 XP) + F (10 XP); CS2's Corps = YOU2
--                    (1 promotion, 20 XP) + F2 (none). Press 2: what the
--                    split will do: B's Army -> STANDARD in place (read back
--                    ID, formation, XP, promotions, damage, moves, strength);
--                    CS2's Corps EFV_Units.Remove; each part through
--                    EFV_Units.Recreate for its sender near its capital, 30
--                    damage. A third press starts over.
--   C9 corps_vol     press 1: Nationalism for you if missing; three pairs on
--                    your land (Volunteer records you -> B, deployed 10 turns
--                    ago): V1 + V2, REG + V3, V4 + REG2. You merge them. Press
--                    2 after End Turn: per pair the survivor, its formation,
--                    XP and promotions, each Volunteer record, FindID /
--                    EFV_UnitGoneReason of the absorbed unit.
--   Merge trace      armed by C3 and C9 press 1 for the rest of that turn
--                    (st.corps.trace = turn): GameEvents.OnUnitMoved about a
--                    C3 / C9 unit logs "[EFV][Corps] G trace ..." with every
--                    C3 / C9 unit's state. Read only. The panel logs the
--                    UI events (UnitFormCorps / UnitFormArmy /
--                    UnitRemovedFromMap) the same way; C10 is UI only.
-- Own do-block (the main chunk's 200-local limit).
-- ---------------------------------------------------------------------------
do
local X = {}                -- the helpers below (one local: the limit)
-- The entry and live unit of C key k (nil, nil when not listed).
function X.CUnitOf(c, k)
	for _, e in ipairs(c.units) do
		if e.k == k then return e, FindUnit(tonumber(e.o) or -1, tonumber(e.u) or -1) end
	end
	return nil, nil
end

-- nil, u when the entry's unit is alive; else "nil" (FindID) or the
-- EFV_UnitGoneReason (GONE_*) and nil.
function X.CGone(e)
	local u = FindUnit(tonumber(e.o) or -1, tonumber(e.u) or -1)
	if u == nil then return "nil", nil end
	local ok, why = pcall(EFV_UnitGoneReason, u, tonumber(e.o), tonumber(e.u))
	if not ok then CPrint("EFV_UnitGoneReason ERROR " .. Str(why)); return nil, u end
	if why ~= nil then return Str(why), nil end
	return nil, u
end

function X.CPromos(u)
	local n = -1
	pcall(function() n = #PromoRows(u) end)
	return n
end

function X.CDestroy(c, k)
	local _, old = X.CUnitOf(c, k)
	if old ~= nil then pcall(function() Players[old:GetOwner()]:GetUnits():Destroy(old) end) end
	CSet(c, k, nil)
end

-- C8: the split of a mixed formation, on stand-ins.
CMD.corps_split = function(me, p)
	local st = Session("CORPS_C8", me)
	if st == nil then return end
	local c = CState(st)
	local B, F = st.ally, st.friend
	local cs2, csCity = CCs2(st, me, c)
	local capB = Capital(B)
	if csCity == nil or capB == nil then Check("CORPS_C8", "CHECK", "no city-state city or no capital of B"); return end
	local M = MilitaryFormationTypes
	local store = EFV_Records.Load()
	local f = type(c.c8) == "table" and c.c8 or {}
	if tonumber(f.step) == 1 then
		-- press 2: B's Army, H = 1: lower in place
		local eB, ub = X.CUnitOf(c, "C8-B")
		local txtB
		if ub == nil then
			txtB = "VEF-C8-B gone"
		else
			local id0, f0 = ub:GetID(), CForm(ub)
			local after = CSetForm("C8-B split", ub, M.STANDARD_FORMATION)
			local u2 = FindUnit(tonumber(eB.o), tonumber(eB.u))
			local live = u2 or ub
			local s, str = CCall(live, "GetCombat")
			local mv = "?"
			pcall(function() mv = Str(live:GetMovesRemaining()) .. "/" .. Str(live:GetMaxMoves()) end)
			txtB = "VEF-C8-B " .. f0 .. " -> " .. after .. ", same ID " .. ((u2 ~= nil and u2:GetID() == id0) and "yes" or "NO") ..
				", xp " .. XPInfo(live) .. ", promotions " .. PromoCount(live, LevelOnePromotions(SW, 1)) .. "/1, dmg " ..
				UnitDamage(live) .. ", moves " .. mv .. ", strength " .. CShort(s, str)
			CPrint("C8 " .. txtB .. "; " .. CFact(live))
		end
		-- CS2's Corps, H = 0: removed
		local eC, uc = X.CUnitOf(c, "C8-CS")
		local txtC
		if uc == nil then
			txtC = "VEF-C8-CS already gone"
		else
			local okRm, rm = pcall(EFV_Units.Remove, uc)
			local gone = X.CGone(eC)
			txtC = "VEF-C8-CS " .. ((gone ~= nil) and "removed" or "NOT removed") .. " (Remove " .. (okRm and Str(rm) or ("ERROR " .. Str(rm))) ..
				", FindID " .. Str(gone or "alive") .. ")"
			CPrint("C8 " .. txtC)
		end
		-- every part home: EFV_Units.Recreate for its sender, 30 damage
		local made, focusU = {}, nil
		for _, pt in ipairs(type(f.parts) == "table" and f.parts or {}) do
			local o = tonumber(pt.o)
			local cap = (o ~= nil) and Capital(o) or nil
			local u = nil
			if cap ~= nil then
				u = CRecreate(store, c, pt.k, o, CStand(pt.k, SW, tonumber(pt.n) or 0, tonumber(pt.xp) or 0, 30),
					FindPlot(cap:GetX(), cap:GetY(), 3, OwnedByAny({ -1, o }), 1), nil)
				if u ~= nil and o ~= me then Hold(store, u) end
			else
				CPrint(Str(pt.k) .. ": no capital of P" .. Str(pt.o))
			end
			if pt.k == "C8-YOU" then focusU = u end
			made[#made + 1] = Str(pt.k) .. " " .. (u and (CFact(u) .. " (of " .. Str(pt.of) .. ", wanted promotions " .. Str(pt.n) ..
				", xp " .. Str(pt.xp) .. ")") or "not made")
		end
		EFV_Records.Commit(store)
		f.step = 2
		c.c8 = f
		if focusU ~= nil then Focus(st, focusU:GetX(), focusU:GetY(), me, focusU:GetID(), p.stamp) else Focus(st, -1, -1, nil, nil, p.stamp) end
		CAnswer(st, p, "CORPS_C8", "C8 split: " .. txtB .. "; " .. txtC .. "; made " .. table.concat(made, "; ") ..
			". Your UI takes your promotions back within a second. End Turn, then C Status (C8 again starts over)")
		return
	end
	-- press 1 (or a new round): the two formations and the stand-in parts
	for _, k in ipairs({ "C8-B", "C8-CS", "C8-YOU", "C8-F", "C8-YOU2", "C8-F2" }) do X.CDestroy(c, k) end
	local ub = CRecreate(store, c, "C8-B", B, CStand("C8-B", SW, 1, 15, 0),
		FindPlot(capB:GetX(), capB:GetY(), 3, OwnedByAny({ -1, B }), 1), M.ARMY_FORMATION)
	if ub ~= nil then pcall(function() ub:SetDamage(30) end); Hold(store, ub) end
	local us = CRecreate(store, c, "C8-CS", cs2, CStand("C8-CS", SW, 0, 0, 0),
		FindPlot(csCity:GetX(), csCity:GetY(), 3, OwnedByAny({ -1, cs2 }), 1), M.CORPS_FORMATION)
	if us ~= nil then pcall(function() us:SetDamage(30) end); Hold(store, us) end
	EFV_Records.Commit(store)
	local fid = (F ~= nil and Alive(F)) and F or B
	local parts = {
		{ k = "C8-YOU", o = me, n = 2, xp = 40, of = "C8-B" }, { k = "C8-F", o = fid, n = 0, xp = 10, of = "C8-B" },
		{ k = "C8-YOU2", o = me, n = 1, xp = 20, of = "C8-CS" }, { k = "C8-F2", o = fid, n = 0, xp = 0, of = "C8-CS" },
	}
	for _, pt in ipairs(parts) do
		CPrint("C8 part " .. pt.k .. " of " .. pt.of .. ": sender P" .. Str(pt.o) .. ", promotions " .. pt.n .. ", xp " .. pt.xp)
	end
	c.c8 = { step = 1, turn = Turn(), parts = parts }
	Focus(st, capB:GetX(), capB:GetY(), nil, nil, p.stamp)
	CAnswer(st, p, "CORPS_C8", "C8 set up: B's VEF-C8-B " .. (ub and CForm(ub) or "NOT made") .. " (host + you + F), " ..
		PlayerName(cs2) .. "'s VEF-C8-CS " .. (us and CForm(us) or "NOT made") .. " (you + F, no host unit)" ..
		((fid ~= F) and " (F missing: B stands in)" or "") .. ". Press C8 again to split. Now: " .. CList(c, store, "C8"))
end

-- C9: your Volunteers merged with each other and with your regular units.
X.C9_PAIRS = {
	-- { key, Volunteer, promotions, xp, damage }; the first one is selected
	{ { "C9-V1", true, 1, 20, 0 }, { "C9-V2", true, 0, 0, 20 } },
	{ { "C9-REG", false, 0, 30, 0 }, { "C9-V3", true, 0, 0, 0 } },
	{ { "C9-V4", true, 0, 30, 0 }, { "C9-REG2", false, 0, 0, 0 } },
}

function X.C9PairText(c, store, i, pair)
	local bits, alive = {}, {}
	for _, d in ipairs(pair) do
		local e = X.CUnitOf(c, d[1])
		local t
		if e == nil then
			t = d[1] .. " not made"
		else
			local gone, u = X.CGone(e)
			if gone == nil then
				alive[#alive + 1] = d[1]
				t = d[1] .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. " " .. CForm(u) .. ", xp " .. XPInfo(u) .. ", promotions " .. X.CPromos(u)
			else
				t = d[1] .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. " FindID " .. gone
			end
			if e.rid ~= nil then
				local rec = EFV_Records.Get(store, e.rid)
				t = t .. ", Volunteer record " .. Str(e.rid) .. " " .. (rec and ("open " .. Str(rec.state)) or "closed")
			end
		end
		bits[#bits + 1] = t
	end
	return "pair " .. i .. " survived: " .. ((#alive > 0) and table.concat(alive, "|") or "none") .. " (" .. table.concat(bits, "; ") .. ")"
end

CMD.corps_vol = function(me, p)
	local st = Session("CORPS_C9", me)
	if st == nil then return end
	local c = CState(st)
	local B = st.ally
	local cap, capB = Capital(me), Capital(B)
	if cap == nil or capB == nil then Check("CORPS_C9", "CHECK", "your capital or B's capital is missing"); return end
	local store = EFV_Records.Load()
	local f = type(c.c9) == "table" and c.c9 or {}
	if tonumber(f.step) == 1 then
		if Turn() <= (tonumber(f.turn) or 0) then
			CAnswer(st, p, "CORPS_C9", "C9: merge the three pairs now (see the first answer), End Turn, then press C9 again. Now: " .. CList(c, store, "C9"))
			return
		end
		local parts = {}
		for i, pair in ipairs(X.C9_PAIRS) do
			local t = X.C9PairText(c, store, i, pair)
			CPrint("C9 " .. t)
			parts[#parts + 1] = t
		end
		f.step = 2
		c.c9 = f
		Focus(st, cap:GetX(), cap:GetY(), nil, nil, p.stamp)
		CAnswer(st, p, "CORPS_C9", "C9: " .. table.concat(parts, "; ") .. ". C9 again starts over")
		return
	end
	-- press 1 (or a new round)
	for _, pair in ipairs(X.C9_PAIRS) do for _, d in ipairs(pair) do X.CDestroy(c, d[1]) end end
	local civ = CCivics(me)
	if not string.find(civ, "Nationalism yes", 1, true) then GrantCivic(me, "CIVIC_NATIONALISM") end
	local cx, cy = cap:GetX(), cap:GetY()
	local placed, notes = {}, {}
	local function Make(d, plot)
		local u = NewUnit("corps_vol", me, SW, plot, "VEF-" .. d[1])
		if u == nil then notes[#notes + 1] = d[1] .. " not made"; return nil end
		placed[#placed + 1] = plot
		for _, nm in ipairs(LevelOnePromotions(SW, d[3])) do SetPromo(u, GameInfo.UnitPromotions[nm].Index) end
		TopUp(u, d[4])
		if d[5] > 0 then pcall(function() u:SetDamage(d[5]) end) end
		CFull(u)
		local rid = nil
		if d[2] then
			local rec = MakeRecord(store, u, { force = FT_VOL, sender = me, recipient = B, basis = st.basis or "FRIEND_OB",
				origin = cap, dest = capB, deployedTurn = Turn() - 10 })
			rid = rec and rec.id or nil
		end
		CSet(c, d[1], u, rid)
		CPrint("C9 " .. d[1] .. (d[2] and (" Volunteer record " .. Str(rid)) or " regular") .. ": " .. CFact(u))
		return u
	end
	local first = nil
	for _, pair in ipairs(X.C9_PAIRS) do
		local q1 = CFar(cx, cy, 5, { me }, placed, 3) or CFar(cx, cy, 6, { -1, me }, placed, 3)
		local a = Make(pair[1], q1)
		if a ~= nil then
			if first == nil then first = a end
			local q2 = FindPlot(a:GetX(), a:GetY(), 1, OwnedByAny({ me }), 1) or FindPlot(a:GetX(), a:GetY(), 1, OwnedByAny({ -1, me }), 1)
			Make(pair[2], q2)
		end
	end
	EFV_Records.Commit(store)
	c.c9 = { step = 1, turn = Turn() }
	c.trace = Turn()
	if first ~= nil then Focus(st, first:GetX(), first:GetY(), me, first:GetID(), p.stamp) else Focus(st, cx, cy, nil, nil, p.stamp) end
	CAnswer(st, p, "CORPS_C9", "C9 (" .. CCivics(me) .. "): pair 1 select VEF-C9-V1, Form Corps, click VEF-C9-V2; pair 2 select VEF-C9-REG, " ..
		"click VEF-C9-V3; pair 3 select VEF-C9-V4, click VEF-C9-REG2. End Turn, then C9 again" ..
		((#notes > 0) and (" (" .. table.concat(notes, ", ") .. ")") or "") .. ". Merge trace on until the next turn. Now: " .. CList(c, store, "C9"))
end

-- Merge trace: GameEvents.OnUnitMoved (CONFIRMED gameplay,
-- PiratesScenario_StartScript.lua:1615) while armed, about a C3 / C9 unit.
function X.CTraced(e) local pre = string.sub(Str(e.k), 1, 2); return pre == "C3" or pre == "C9" end

function EFV_Dev.TraceMoved(pid, uid)
	local st = ScnLoad()
	local c = st.corps
	if type(c) ~= "table" or type(c.units) ~= "table" or tonumber(c.trace) ~= Turn() then return end
	local hit = nil
	for _, e in ipairs(c.units) do
		if X.CTraced(e) and tonumber(e.o) == pid and tonumber(e.u) == uid then hit = e.k end
	end
	if hit == nil then return end
	local parts = {}
	for _, e in ipairs(c.units) do
		if X.CTraced(e) then
			local gone, u = X.CGone(e)
			parts[#parts + 1] = e.k .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. " " ..
				((gone ~= nil) and ("gone (FindID " .. gone .. ")") or ("alive " .. CForm(u) .. " xp " .. XPInfo(u)))
		end
	end
	CPrint("trace OnUnitMoved P" .. Str(pid) .. "/" .. Str(uid) .. " (" .. hit .. "): " .. table.concat(parts, "; "))
end

function X.OnUnitMovedTrace(pid, uid)
	local ok, err = pcall(EFV_Dev.TraceMoved, pid, uid)
	if not ok then CPrint("trace ERROR " .. Str(err)) end
end

if GameEvents.OnUnitMoved ~= nil then
	GameEvents.OnUnitMoved.Add(X.OnUnitMovedTrace)
else
	CPrint("trace MISSING GameEvents.OnUnitMoved")
end
end -- 1.0.4.5 additions

CMD.corps_status = function(me, p)
	local st = Session("CORPS_STATUS", me)
	if st == nil then return end
	local c = CState(st)
	Focus(st, -1, -1, nil, nil, p.stamp)
	CAnswer(st, p, "CORPS_STATUS", "Corps T" .. Turn() .. ": " .. CList(c, EFV_Records.Load(), nil))
end

-- At your turn start, for C_WATCH turns after the last C button.
function EFV_Dev.EvalCorps(st, store, t)
	local c = st.corps
	if type(c) ~= "table" or type(c.units) ~= "table" or #c.units == 0 then return end
	if t > (tonumber(c.last) or -99) + C_WATCH then return end
	Check("CORPS_WATCH", "INFO", CList(c, store, nil))
end
end -- corps spike

-- ===========================================================================
-- VEF 1.0.5 test (EFV_Dev 1.0.5.1; FIXPLAN_proxy_war.md "1.0.5 build plan"
-- B5.2; EFV/TESTING_1.0.5.md). From a NEW game, P1 instead of S0.
--   P1 scn_proxy     B = a major with a city whose capital is a 2-turn trip
--                    from yours (else 3, 4, 1), your declared friend with
--                    open borders from B; E and X = the two lowest-ID other
--                    majors with a city, both at war with B; you at war with
--                    nobody. Three Swordsmen VEF-PROXY-1..3, 2000 gold.
--   P Status         proxy_status: the pair states (G reader A64), the
--                    wars, VEF's send rule to B, B's gold, your records.
--   P2 (panel only)  UI DiplomacyManager.RequestSession(X, you, "DENOUNCE"),
--                    then P Status.
--   P3 proxy_lower   X's (else E's) opinion of you to -30 with the tuner's
--                    AdjustBaseDiplomacy (Debug\Diplomacy.ltp:19-33, 260):
--                    inside the UNFRIENDLY -> DENOUNCED window
--                    (DiplomaticActions.xml:239-242), so its AI denounces you.
--   P4 proxy_hold    your newest outbound record arrives 8 turns from now.
--   P5 proxy_poor    press 1: Modern Anti-Tank VEF-UPKEEP (8 gold upkeep, no
--                    strategic resource); press 2 after its send: it arrives
--                    next turn and B's gold goes to 0.
--   EvalProxy        PROXY_WATCH at your turn start for 12 turns after P1.
-- The answer (st.proxy.ans = { stamp, text }) holds player IDs ("P3"), never
-- translated names: the property is synced; the panel names the civs. MP
-- style: the synced handler only, players by ascending ID, no pairs() over
-- state, no random, no local-player call. Only CMD.* and EFV_Dev.EvalProxy
-- leave the block (Havok register limit: no new main-chunk local).
-- ---------------------------------------------------------------------------
do
local PX = {}                -- the helpers below (one local: the limit)
PX.WATCH = 12
PX.UNIT = "UNIT_SWORDSMAN"
PX.POOR = "UNIT_MODERN_AT"

function PX.Answer(st, p, id, text, verdict)
	if type(st.proxy) ~= "table" then st.proxy = {} end
	st.proxy.ans = { stamp = Num(p.stamp, 0), text = text }
	ScnSave(st)
	Check(id, verdict or "INFO", text)
end

-- "ok" or the codes joined with "+".
function PX.Codes(codes)
	if type(codes) ~= "table" or #codes == 0 then return "ok" end
	return table.concat(codes, "+")
end

-- The pair state by the gameplay reader (A64), without the DIPLO_STATE_ prefix.
function PX.State(a, b)
	local ok, s = pcall(function() return Players[a]:GetAi_Diplomacy():GetDiplomaticState(b) end)
	if not ok or type(s) ~= "string" then return "?" end
	return (string.gsub(s, "^DIPLO_STATE_", ""))
end

function PX.YesNo(b) return b and "yes" or "no" end

function PX.Gold(pid)
	local ok, g = pcall(function() return Players[pid]:GetTreasury():GetGoldBalance() end)
	return (ok and type(g) == "number") and math.floor(g) or -1
end

-- The P Status text (also PROXY_WATCH).
function PX.Status(st, me, store)
	local P = st.proxy
	local b, e, x = P.b, P.e, P.x
	local exp = EFV_SendRecipientReasons(me, b, FT_EXP)
	local vol = EFV_SendRecipientReasons(me, b, FT_VOL)
	local expText = PX.Codes(exp)
	if #exp == 0 then
		local en = {}
		for _, pid in ipairs(EFV_ProxyWarEnemies(me, b)) do en[#en + 1] = "P" .. pid end
		expText = (#en > 0) and ("ok (proxy war against " .. table.concat(en, " ") .. ")") or "ok (shared war)"
	end
	local recs = {}
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.senderID == me then
			recs[#recs + 1] = id .. " " .. Str(rec.state) .. ((rec.state == ST.OUT) and (" arrives T" .. Str(rec.arrivalTurn)) or "")
		end
	end
	return "P T" .. Turn() .. ": you-E " .. PX.State(me, e) .. ", you-X " .. PX.State(me, x) ..
		"; B at war with E " .. PX.YesNo(AtWar(b, e)) .. ", X " .. PX.YesNo(AtWar(b, x)) ..
		"; you at war with E " .. PX.YesNo(AtWar(me, e)) .. ", X " .. PX.YesNo(AtWar(me, x)) ..
		"; Expeditionary to B " .. expText .. ", Volunteers to B " .. PX.Codes(vol) ..
		"; B gold " .. PX.Gold(b) .. "; your records: " .. ((#recs > 0) and table.concat(recs, ", ") or "none")
end

-- The session of P1 (st, or nil after a CHECK).
function PX.Session(id, me, p)
	local st = ScnLoad()
	if type(st.proxy) ~= "table" or st.proxy.b == nil or st.me ~= me then
		PX.Answer(st, p, id, id .. ": press P1 Proxy war setup first (in a new game)", "CHECK")
		return nil
	end
	return st
end

CMD.scn_proxy = function(me, p)
	local st = ScnLoad()
	local cap = Capital(me)
	local refuse = nil
	if st.enemy ~= nil then
		refuse = "S0 ran in this game (you are at war with its enemy C): start a new game and press P1 instead of S0"
	elseif type(st.proxy) == "table" and st.proxy.b ~= nil then
		refuse = "P1 already ran in this game (B=P" .. Str(st.proxy.b) .. ")"
	elseif cap == nil then
		refuse = "you have no city yet: found your capital, End Turn once, then press P1 again"
	end
	local wars = SortedIDs(function(i) return i ~= me and (IsMajorID(i) or IsCityStateID(i)) and AtWar(me, i) end)
	if refuse == nil and #wars > 0 then
		refuse = "you are at war with P" .. table.concat(wars, ", P") .. ": this test needs you at peace with everyone: start a new game"
	end
	local majors = SortedIDs(function(i) return i ~= me and IsMajorID(i) and HasCity(i) end)
	if refuse == nil and #majors < 3 then
		refuse = "needs 3 other civs with a city, found " .. #majors .. ": End Turn once more, then press P1 again"
	end
	if refuse ~= nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		PX.Answer(st, p, "PROXY_P1", "P1: " .. refuse, "CHECK")
		return
	end
	local cx, cy = cap:GetX(), cap:GetY()
	-- B: a 2-turn trip first (a paid send whose refund shows, short enough
	-- for the second Swordsman to arrive before the denouncement runs out)
	local B, band = nil, nil
	for _, want in ipairs({ 2, 3, 4, 1 }) do
		for _, pid in ipairs(majors) do
			local c = Capital(pid)
			local bb = (B == nil and c ~= nil) and EFV_Band(cx, cy, c:GetX(), c:GetY()) or nil
			if bb == want then B, band = pid, bb end
		end
		if B ~= nil then break end
	end
	if B == nil then B, band = majors[1], 1 end
	local others = {}
	for _, pid in ipairs(majors) do if pid ~= B then others[#others + 1] = pid end end
	local E, X = others[1], others[2]
	-- meet, partner, wars, reveal
	local group = { me, B, E, X }
	for i = 1, #group do
		for j = i + 1, #group do MeetPair(group[i], group[j]) end
	end
	local partner, vol = EnsurePartner("scn_proxy", me, B)
	DeclareWar(B, E); DeclareWar(B, X)
	for _, city in ipairs(Cities(B)) do RevealCity(me, city, { -1, me, B }) end
	for _, pid in ipairs({ E, X }) do
		local c = Capital(pid)
		if c ~= nil then RevealCity(me, c, { -1, me, B }) end
	end
	-- gold, three Swordsmen with full moves next to your capital
	pcall(function() Players[me]:GetTreasury():ChangeGoldBalance(2000) end)
	local first, made, full = nil, 0, 0
	for i = 1, 3 do
		local plot = FindPlot(cx, cy, 4, OwnedBy(me), 1) or FindPlot(cx, cy, 4, OwnedByAny({ -1, me }), 1)
		local u = NewUnit("scn_proxy", me, PX.UNIT, plot, "VEF-PROXY-" .. i)
		if u ~= nil then
			made = made + 1
			if FullMoves(u) then full = full + 1 end
			if first == nil then first = u end
		end
	end
	st.me, st.ally = me, B
	st.friend, st.enemy, st.cs = nil, nil, nil
	st.proxy = { b = B, e = E, x = X, turn = Turn(), band = band, fee = EFV_Fee(PX.UNIT, FT_EXP, band) or -1 }
	Focus(st, cx, cy, me, first and first:GetID() or -1, p.stamp)
	local expC = PX.Codes(EFV_SendRecipientReasons(me, B, FT_EXP))
	local volC = PX.Codes(EFV_SendRecipientReasons(me, B, FT_VOL))
	local peace = #SortedIDs(function(i) return i ~= me and (IsMajorID(i) or IsCityStateID(i)) and AtWar(me, i) end) == 0
	local lim = "?"
	pcall(function() lim = Str(GameInfo.GlobalParameters["DIPLOMACY_DENOUNCE_TIME_LIMIT"].Value) end)
	local ok = partner ~= nil and vol ~= nil and AtWar(B, E) and AtWar(B, X) and peace and made == 3 and full == 3 and
		expC == "NO_COMMON_WAR" and volC == "NO_COMMON_WAR"
	PX.Answer(st, p, "PROXY_P1", "P1: B=P" .. B .. " (friend" .. ((vol ~= nil) and ", open borders" or ", NO open borders") ..
		", trip " .. band .. " turns, fee " .. Str(st.proxy.fee) .. "), E=P" .. E .. " and X=P" .. X .. " at war with B" ..
		((AtWar(B, E) and AtWar(B, X)) and "" or " (NOT ALL WARS TOOK)") .. "; you at war with nobody: " .. PX.YesNo(peace) ..
		"; Expeditionary to B " .. expC .. ", Volunteers to B " .. volC .. "; Swordsmen " .. made .. " (full moves " .. full .. ")" ..
		"; denounce limit in the game data " .. lim, ok and "PASS" or "CHECK")
end

CMD.proxy_status = function(me, p)
	local st = PX.Session("P", me, p)
	if st == nil then return end
	Focus(st, -1, -1, nil, nil, p.stamp)
	PX.Answer(st, p, "PROXY_STATUS", PX.Status(st, me, EFV_Records.Load()))
end

CMD.proxy_lower = function(me, p)
	local st = PX.Session("P3", me, p)
	if st == nil then return end
	local t = nil
	for _, pid in ipairs({ st.proxy.x, st.proxy.e }) do
		if t == nil and pid ~= nil and PX.State(me, pid) ~= "DENOUNCED" then t = pid end
	end
	if t == nil then
		PX.Answer(st, p, "PROXY_P3", "P3: X and E are both in a denouncement with you already: nothing to do", "CHECK")
		return
	end
	local function Score()
		local ok, s = pcall(function() return Players[t]:GetAi_Diplomacy():GetDiplomaticScore(me) end)
		return (ok and type(s) == "number") and s or nil
	end
	local before = Score()
	local err = nil
	if before ~= nil and before > -30 then
		local ok, e = pcall(function() Players[t]:GetAi_Diplomacy():AdjustBaseDiplomacy(me, -30 - before) end)
		if not ok then err = Str(e) end
	end
	local after = Score()
	Log("proxy_lower", "P" .. t .. "'s opinion of P" .. me .. ": " .. Str(before) .. " -> " .. Str(after) .. (err and (" ERROR " .. err) or ""))
	Focus(st, -1, -1, nil, nil, p.stamp)
	PX.Answer(st, p, "PROXY_P3", "P3: P" .. t .. "'s opinion of you " .. Str(before) .. " -> " .. Str(after) ..
		(err and (" (AdjustBaseDiplomacy failed: " .. err .. ")") or "") .. "; End Turn until P" .. t .. " denounces you (2 to 4 turns)",
		(after ~= nil and after <= -30) and "INFO" or "CHECK")
end

CMD.proxy_hold = function(me, p)
	local st = PX.Session("P4", me, p)
	if st == nil then return end
	local store = EFV_Records.Load()
	local rec = Newest(store, function(r) return r.senderID == me and r.state == ST.OUT end)
	if rec == nil then
		PX.Answer(st, p, "PROXY_P4", "P4: no unit of yours on its way: send VEF-PROXY-1 first", "CHECK")
		return
	end
	rec.arrivalTurn = Turn() + 8
	EFV_Records.Touch(store)
	EFV_Records.Commit(store)
	Focus(st, -1, -1, nil, nil, p.stamp)
	PX.Answer(st, p, "PROXY_P4", "P4: " .. Str(rec.veteranName or rec.unitType) .. " (record " .. rec.id .. ") now arrives on turn " .. rec.arrivalTurn)
end

CMD.proxy_poor = function(me, p)
	local st = PX.Session("P5", me, p)
	if st == nil then return end
	local P = st.proxy
	local store = EFV_Records.Load()
	if tonumber(P.p5) == 1 then
		local rec = Newest(store, function(r) return r.senderID == me and r.state == ST.OUT and r.unitType == PX.POOR end)
		if rec == nil then
			PX.Answer(st, p, "PROXY_P5", "P5: send VEF-UPKEEP first (Send as Expeditionary to B), then press P5 again", "CHECK")
			return
		end
		rec.arrivalTurn = Turn() + 1
		EFV_Records.Touch(store)
		EFV_Records.Commit(store)
		local g = PX.Gold(P.b)
		pcall(function() local tr = Players[P.b]:GetTreasury(); tr:ChangeGoldBalance(-tr:GetGoldBalance()) end)
		P.poor = { id = rec.id, from = Turn() + 1 }
		P.p5 = 2
		Focus(st, -1, -1, nil, nil, p.stamp)
		PX.Answer(st, p, "PROXY_P5", "P5: VEF-UPKEEP (record " .. rec.id .. ") arrives for B next turn; B's gold now " .. PX.Gold(P.b) .. " (was " .. g .. ")")
		return
	end
	local cap = Capital(me)
	local plot = cap and (FindPlot(cap:GetX(), cap:GetY(), 4, OwnedBy(me), 1) or FindPlot(cap:GetX(), cap:GetY(), 4, OwnedByAny({ -1, me }), 1)) or nil
	local u = NewUnit("proxy_poor", me, PX.POOR, plot, "VEF-UPKEEP")
	if u == nil then
		PX.Answer(st, p, "PROXY_P5", "P5: no Modern Anti-Tank made (no free land of yours next to your capital)", "CHECK")
		return
	end
	FullMoves(u)
	P.p5 = 1
	Focus(st, u:GetX(), u:GetY(), me, u:GetID(), p.stamp)
	PX.Answer(st, p, "PROXY_P5", "P5: VEF-UPKEEP next to your capital: send it to B as Expeditionary, then press P5 again")
end

-- At your turn start, for PX.WATCH turns after P1.
function EFV_Dev.EvalProxy(st, store, t)
	local P = st.proxy
	if type(P) ~= "table" or P.b == nil or t > (tonumber(P.turn) or -99) + PX.WATCH then return end
	local text = PX.Status(st, st.me, store)
	local poor = P.poor
	if type(poor) == "table" and poor.id ~= nil then
		local rec = EFV_Records.Get(store, poor.id)
		local live = "record closed"
		if rec ~= nil then
			local u = RecUnit(rec)
			local okM, m, why = pcall(EFV_UnitMatches, u, rec.onMapPlayerID, rec.onMapUnitID, rec.unitType)
			live = Str(rec.state) .. ", unit " .. ((u == nil) and "none" or ((okM and m) and "on the map" or ("gone " .. Str(why))))
		end
		text = text .. "; VEF-UPKEEP (record " .. poor.id .. "): " .. live .. ", B gold " .. PX.Gold(P.b)
	end
	Check("PROXY_WATCH", "INFO", text)
end
end -- VEF 1.0.5 test

-- ===========================================================================
-- Upgrade spike U1 (EFV_Dev 1.0.5.2; FIXPLAN_upgrade_relink.md U6 and U13;
-- EFV/TESTING_1.0.5.md). Works after P1 (B = st.proxy.b) or after S0
-- (B = st.ally); one button, three presses:
--   press 1  grants what the S5 upgrade pair needs (its tech and civic, its
--            strategic resource for two upgrades, 3000 gold) and makes in
--            your land: VEF-U1-M (1 promotion, XP, 30 damage, 2 extra moves
--            so a move onto rough ground still leaves one) and VEF-U1-S
--            (fresh), both lent to you by B as Expeditionary records (the
--            multiplayer report's case: a human host upgrades a lent unit),
--            a Battering Ram VEF-U1-R exactly 2 tiles from VEF-U1-M and a
--            Builder VEF-U1-B (their formations: Q-F), and logs the highest
--            serial of your units (Q-G). It arms the trace for this turn.
--   press 2  (same turn) both records, both old unit objects (FindID: tile,
--            damage, EFV_UnitGoneReason) and both new units, moves left
--            included (Q-D), XP, promotions and damage against the old ones
--            (Q-E), and the serial check (Q-G).
--   press 3  (a later turn; also once by itself at your next turn start)
--            the records again and "UPG_SPIKE INFO" with Q-A to Q-G.
-- The trace (the press-1 turn only, your units only, information only):
-- GameEvents.OnUnitMoved (the U1 units), GameEvents.UnitCreated,
-- GameEvents.UnitInitialized and Events.UnitUpgraded (gameplay) write one
-- "[EFV][Upg] G <event> ..." line each with both old units' state and both
-- records; st.upg.tr keeps the event order and each old unit's state at the
-- first event about its new unit. It never touches VEF's records. MP style
-- as the P block: synced handler, IDs in the property, no random, keys in
-- a fixed order. Only CMD.upg_spike and EFV_Dev.EvalUpg leave the block
-- (register limit).
-- ===========================================================================
do
local UP = { KEYS = { "M", "S" }, NAMES = { M = "VEF-U1-M", S = "VEF-U1-S" }, busy = 0 }
UP.SLOT = 65536
UP.EXTRA_MOVES = 2
UP.GOLD = 3000

function UP.Print(msg) print("[EFV][Upg] G " .. Str(msg)) end

function UP.Gold(pid)
	local ok, g = pcall(function() return Players[pid]:GetTreasury():GetGoldBalance() end)
	return (ok and type(g) == "number") and math.floor(g) or -1
end

function UP.Promos(u)
	local n = 0
	pcall(function()
		local exp = u:GetExperience()
		for row in GameInfo.UnitPromotions() do
			if exp:HasPromotion(row.Index) then n = n + 1 end
		end
	end)
	return n
end

function UP.Desc(u)
	if u == nil then return "nil" end
	local s = "?"
	pcall(function()
		local id = u:GetID()
		s = "P" .. Str(u:GetOwner()) .. "/" .. Str(id) .. " serial=" .. math.floor(id / UP.SLOT) .. " slot=" .. (id % UP.SLOT) ..
			" type=" .. UnitTypeName(u) .. " at=" .. Str(u:GetX()) .. "," .. Str(u:GetY()) ..
			" moves=" .. Str(u:GetMovesRemaining()) .. "/" .. Str(u:GetMaxMoves())
	end)
	local xp = XPInfo(u)
	return s .. " xp=" .. Str(xp) .. " dmg=" .. Str(UnitDamage(u)) .. " promos=" .. UP.Promos(u)
end

function UP.Form(u)
	if u == nil then return "none" end
	local ok, f = pcall(function() return u:GetMilitaryFormation() end)
	return ok and Str(f) or "unreadable"
end

-- The old unit object of e = { o, u } read raw: "live" (a live unit),
-- "dead" (damage at the maximum), "ghost" (any other stale object) or
-- "none" (FindID nil or another unit in the slot); plus a text.
function UP.Old(e)
	local u = FindUnit(tonumber(e.o) or -1, tonumber(e.u) or -1)
	if u == nil then return "none", "none" end
	local x, y = -1, -1
	pcall(function() x, y = u:GetX(), u:GetY() end)
	local why = EFV_UnitGoneReason(u, e.o, e.u)
	if why == nil then return "live", "live at " .. Str(x) .. "," .. Str(y) end
	local s = (why == "GONE_DEAD") and "dead" or "ghost"
	return s, s .. " (" .. Str(why) .. ") at " .. Str(x) .. "," .. Str(y) .. " dmg " .. Str(UnitDamage(u))
end

-- The property round trip drops empty tables: restore the sub-tables.
function UP.Norm(up)
	for _, key in ipairs({ "k", "nu", "rec", "tr", "p2" }) do
		if type(up[key]) ~= "table" then up[key] = {} end
	end
	local tr = up.tr
	tr.seq = tonumber(tr.seq) or 0
	for _, key in ipairs({ "mv", "mvn", "at" }) do
		if type(tr[key]) ~= "table" then tr[key] = {} end
	end
	return up
end

function UP.RecText(store, up, k)
	local rec = EFV_Records.Get(store, tonumber(up.rec[k]) or -1)
	if rec == nil then return "record " .. Str(up.rec[k]) .. " closed", nil end
	return "record " .. rec.id .. " " .. Str(rec.state) .. " unit=" .. Str(rec.onMapUnitID) .. " type=" .. Str(rec.unitType) ..
		" last=" .. Str(rec.lastX) .. "," .. Str(rec.lastY), rec
end

-- Both old units and both records, for every trace line.
function UP.Both(up)
	local store = EFV_Records.Load()
	local parts = {}
	for _, k in ipairs(UP.KEYS) do
		local e = up.k[k]
		if type(e) == "table" then
			local _, text = UP.Old(e)
			parts[#parts + 1] = UP.NAMES[k] .. " P" .. Str(e.o) .. "/" .. Str(e.u) .. ": " .. text .. ", " .. (UP.RecText(store, up, k))
		end
	end
	return table.concat(parts, "; ")
end

-- The U1 key whose old unit stood on u's tile (a live old unit's own tile,
-- else its last traced tile), for a new unit not matched yet.
function UP.MatchNew(up, u)
	local okP, x, y = pcall(function() return u:GetX(), u:GetY() end)
	if not okP then return nil end
	for _, k in ipairs(UP.KEYS) do
		local e = up.k[k]
		if type(e) == "table" and up.nu[k] == nil then
			local ox, oy = e.x, e.y
			local old = FindUnit(tonumber(e.o) or -1, tonumber(e.u) or -1)
			if old ~= nil then
				local okO, px, py = pcall(function() return old:GetX(), old:GetY() end)
				if okO and type(px) == "number" and px >= 0 and py >= 0 then ox, oy = px, py end
			end
			if ox == x and oy == y then return k end
		end
	end
	return nil
end

-- The trace (information only; see the header).
function UP.Trace(ev, pid, uid, extra)
	if UP.busy > 0 then return end
	local st = ScnLoad()
	local up = st.upg
	if type(up) ~= "table" or up.me ~= pid or tonumber(up.turn) ~= Turn() or (tonumber(up.step) or 0) >= 3 then return end
	UP.Norm(up)
	local u = FindUnit(pid, uid)
	local k, old = nil, false
	for _, kk in ipairs(UP.KEYS) do
		local e = up.k[kk]
		if type(e) == "table" and tonumber(e.u) == uid then k, old = kk, true end
		if tonumber(up.nu[kk]) == uid then k = kk end
	end
	local tr = up.tr
	if ev == "OnUnitMoved" then
		if k == nil then return end
		local key = old and "mv" or "mvn"
		tr[key][k] = (tonumber(tr[key][k]) or 0) + 1
		if old and u ~= nil then
			local okP, x, y = pcall(function() return u:GetX(), u:GetY() end)
			if okP and type(x) == "number" and x >= 0 and y >= 0 then up.k[k].x, up.k[k].y = x, y end
		end
	elseif k == nil and u ~= nil and EFV_UpgradeTargets(up.from, pid)[UnitTypeName(u)] then
		k = UP.MatchNew(up, u)
		if k ~= nil then up.nu[k] = uid end
	end
	tr.seq = tr.seq + 1
	if k ~= nil and not old and ev ~= "OnUnitMoved" then
		if type(tr.at[k]) ~= "table" then
			local _, text = UP.Old(up.k[k])
			tr.at[k] = { old = text }
		end
		local short = (ev == "UnitCreated" and "c") or (ev == "UnitInitialized" and "i") or "g"
		if tr.at[k][short] == nil then tr.at[k][short] = tr.seq end
	end
	local who = (k == nil) and "another unit" or (UP.NAMES[k] .. (old and " (old unit)" or " (new unit)"))
	UP.Print(ev .. " #" .. tr.seq .. " " .. UP.Desc(u) .. Str(extra) .. " = " .. who .. "; " .. UP.Both(up))
	ScnSave(st)
end

function UP.OnMoved(pid, uid)
	local ok, err = pcall(UP.Trace, "OnUnitMoved", pid, uid, "")
	if not ok then UP.Print("trace ERROR " .. Str(err)) end
end
function UP.OnCreated(pid, uid)
	local ok, err = pcall(UP.Trace, "UnitCreated", pid, uid, "")
	if not ok then UP.Print("trace ERROR " .. Str(err)) end
end
function UP.OnInitialized(pid, uid)
	local ok, err = pcall(UP.Trace, "UnitInitialized", pid, uid, "")
	if not ok then UP.Print("trace ERROR " .. Str(err)) end
end
function UP.OnUpgraded(pid, uid, upType)
	local ok, err = pcall(UP.Trace, "Events.UnitUpgraded", pid, uid, " upgradeType=" .. Str(upType))
	if not ok then UP.Print("trace ERROR " .. Str(err)) end
end

function UP.Answer(st, p, id, text, verdict)
	if type(st.upg) ~= "table" then st.upg = {} end
	st.upg.ans = { stamp = Num(p.stamp, 0), text = text }
	ScnSave(st)
	Check(id, verdict or "INFO", text)
end

-- Your units' highest serial (the upper 16 bits of the ID).
function UP.MaxSerial(me)
	local m = -1
	pcall(function()
		for _, u in Players[me]:GetUnits():Members() do
			local s = math.floor(u:GetID() / UP.SLOT)
			if s > m then m = s end
		end
	end)
	return m
end

-- Your free land tiles within 3 of (cx, cy), ring by ring.
function UP.OwnTiles(me, cx, cy)
	local out = {}
	for ring = 1, 3 do
		for _, q in ipairs(Ring(cx, cy, ring)) do
			if FreeLand(q) and NotWonder(q) and PlotOwner(q) == me then out[#out + 1] = q end
		end
	end
	return out
end

-- At turn 2 a capital owns only its ring-1 tiles, and P1's VEF-PROXY
-- Swordsmen (or S0's three Swordsmen) stand there. With fewer than 4 free
-- tiles of yours left, those idle test units are placed on neutral land 3 to
-- 6 tiles from your capital (UnitManager.PlaceUnit, as S9), so both U1
-- units fit inside your borders. Returns how many were moved.
function UP.ClearLand(st, me, cx, cy)
	if #UP.OwnTiles(me, cx, cy) >= 4 then return 0 end
	local setup = {}
	for _, e in ipairs(type(st.setupUnits) == "table" and st.setupUnits or {}) do setup[tonumber(e.u) or -1] = true end
	local idle = {}
	pcall(function()
		for _, u in Players[me]:GetUnits():Members() do
			local okN, n = pcall(function() return u:GetExperience():GetVeteranName() end)
			local proxy = okN and type(n) == "string" and string.sub(n, 1, 10) == "VEF-PROXY-"
			if (proxy or setup[u:GetID()]) and EFV_UnitGoneReason(u, me, u:GetID()) == nil
					and PlotOwner(Map.GetPlot(u:GetX(), u:GetY())) == me then
				idle[#idle + 1] = u
			end
		end
	end)
	table.sort(idle, function(a, b) return a:GetID() < b:GetID() end)
	local n = 0
	for _, u in ipairs(idle) do
		local q = FindPlot(cx, cy, 6, Neutral, 3)
		if q ~= nil and Place(u, q) then n = n + 1 end
	end
	return n
end

-- The target's tech and civic, its strategic resource for n upgrades
-- (GS Units_XP2 ResourceCost; +10 spare, at least 20) and the gold.
function UP.Grant(me, to, n)
	local row = GameInfo.Units[to]
	local notes = {}
	if row.PrereqTech ~= nil then
		local ok = pcall(function() Players[me]:GetTechs():SetTech(GameInfo.Technologies[row.PrereqTech].Index, true) end)
		notes[#notes + 1] = row.PrereqTech .. " granted=" .. tostring(ok)
	end
	if row.PrereqCivic ~= nil then notes[#notes + 1] = row.PrereqCivic .. " granted=" .. tostring(GrantCivic(me, row.PrereqCivic)) end
	if row.StrategicResource ~= nil and GameInfo.Resources[row.StrategicResource] ~= nil then
		local cost = 0
		pcall(function() cost = tonumber(GameInfo.Units_XP2[to].ResourceCost) or 0 end)
		local add = math.max(20, n * cost + 10)
		local idx = GameInfo.Resources[row.StrategicResource].Index
		local have = "?"
		pcall(function()
			Players[me]:GetResources():ChangeResourceAmount(idx, add)
			have = Str(Players[me]:GetResources():GetResourceAmount(idx))
		end)
		notes[#notes + 1] = row.StrategicResource .. " +" .. add .. " (now " .. have .. ", one upgrade needs " .. cost .. ")"
	end
	pcall(function() Players[me]:GetTreasury():ChangeGoldBalance(UP.GOLD) end)
	notes[#notes + 1] = "gold +" .. UP.GOLD .. " (now " .. UP.Gold(me) .. ")"
	return notes
end

function UP.Press1(me, p, st, B)
	local cap, capB = Capital(me), Capital(B)
	local from, to, unique = EV.UpgradePair(me)
	if cap == nil or capB == nil or GameInfo.Units[to] == nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		UP.Answer(st, p, "UPG_U1", "U1: " .. ((GameInfo.Units[to] == nil) and "no upgrade target found" or "your capital or B's capital is missing"), "CHECK")
		return
	end
	local notes = UP.Grant(me, to, 2)
	local cx, cy = cap:GetX(), cap:GetY()
	local moved = UP.ClearLand(st, me, cx, cy)
	if moved > 0 then notes[#notes + 1] = moved .. " idle test Swordsmen moved out of your land" end
	-- VEF-U1-M on your land with a free tile of yours next to it (the move),
	-- VEF-U1-S as far from it as your land allows (at least 2).
	local qm = nil
	for _, q in ipairs(UP.OwnTiles(me, cx, cy)) do
		if qm == nil then
			for _, nb in ipairs(Ring(q:GetX(), q:GetY(), 1)) do
				if FreeLand(nb) and PlotOwner(nb) == me then qm = q end
			end
		end
	end
	local inLand = qm ~= nil
	qm = qm or FindPlot(cx, cy, 4, OwnedByAny({ -1, me }), 1)
	local m = NewUnit("upg_spike", me, from, qm, UP.NAMES.M)
	local qs, best = nil, -1
	if m ~= nil then
		for _, q in ipairs(UP.OwnTiles(me, cx, cy)) do
			local d = Dist(q:GetX(), q:GetY(), m:GetX(), m:GetY())
			if d >= 2 and d > best then qs, best = q, d end
		end
		if qs == nil then
			inLand = false
			qs = FindPlot(cx, cy, 4, function(q) return Has({ -1, me }, PlotOwner(q)) and Dist(q:GetX(), q:GetY(), m:GetX(), m:GetY()) >= 2 end, 1)
		end
	end
	local s = NewUnit("upg_spike", me, from, qs, UP.NAMES.S)
	if m == nil or s == nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		UP.Answer(st, p, "UPG_U1", "U1: could not create two " .. from .. " next to your capital (no free land)", "CHECK")
		return
	end
	-- VEF-U1-M: one level-1 promotion, XP, 30 damage, extra moves.
	for _, pt in ipairs(LevelOnePromotions(from, 1)) do SetPromo(m, GameInfo.UnitPromotions[pt].Index) end
	TopUp(m, 20)
	pcall(function() m:SetDamage(30) end)
	FullMoves(m)
	FullMoves(s)
	pcall(function() m:ChangeMovesRemaining(UP.EXTRA_MOVES) end)
	-- the Ram exactly 2 tiles from VEF-U1-M, the Builder 2 or more from it
	local mx, my = m:GetX(), m:GetY()
	local r = NewUnit("upg_spike", me, "UNIT_BATTERING_RAM", FindPlot(mx, my, 2, OwnedByAny({ -1, me }), 2), "VEF-U1-R")
	local b = NewUnit("upg_spike", me, "UNIT_BUILDER",
		FindPlot(cx, cy, 4, function(q) return Has({ -1, me }, PlotOwner(q)) and Dist(q:GetX(), q:GetY(), mx, my) >= 2 end, 1), "VEF-U1-B")
	local units = { M = m, S = s }
	local store = EFV_Records.Load()
	local recs = {}
	for _, k in ipairs(UP.KEYS) do
		recs[k] = MakeRecord(store, units[k], { force = FT_EXP, sender = B, recipient = me, basis = EFV_PartnerBasis(B, me) or "FRIEND",
			origin = capB, dest = cap, duration = EFV_Config.EXPEDITIONARY_DURATION })
	end
	EFV_Records.Commit(store)
	local smax = UP.MaxSerial(me)
	local up = UP.Norm({ me = me, b = B, turn = Turn(), step = 1, from = from, to = to, unique = unique and 1 or 0, smax = smax })
	for _, k in ipairs(UP.KEYS) do
		local u = units[k]
		local xp = XPInfo(u)
		up.k[k] = { o = me, u = u:GetID(), x = u:GetX(), y = u:GetY(), xp = xp, pr = UP.Promos(u), dmg = UnitDamage(u) }
		up.rec[k] = recs[k] and recs[k].id or -1
	end
	up.ram = { u = r and r:GetID() or -1, f = UP.Form(r) }
	up.bld = { u = b and b:GetID() or -1, f = UP.Form(b) }
	st.upg = up
	Focus(st, mx, my, me, m:GetID(), p.stamp)
	local ok = recs.M ~= nil and recs.S ~= nil and r ~= nil and b ~= nil and inLand
	UP.Print("U1 press 1: VEF-U1-M " .. UP.Desc(m) .. "; VEF-U1-S " .. UP.Desc(s) .. "; VEF-U1-R " .. UP.Desc(r) .. " formation=" .. up.ram.f ..
		"; VEF-U1-B " .. UP.Desc(b) .. " formation=" .. up.bld.f .. "; your highest serial " .. smax)
	UP.Answer(st, p, "UPG_U1", "U1: B=P" .. B .. "; " .. UP.NAMES.M .. " (record " .. Str(up.rec.M) .. ", " .. from .. ", xp " .. Str(up.k.M.xp) ..
		", " .. up.k.M.pr .. " promotion(s), " .. Str(up.k.M.dmg) .. " damage, moves " .. Str(m:GetMovesRemaining()) .. ") at " .. mx .. "," .. my ..
		" and " .. UP.NAMES.S .. " (record " .. Str(up.rec.S) .. ") at " .. s:GetX() .. "," .. s:GetY() .. ", both lent to you by B" ..
		(inLand and "" or " (NOT BOTH IN YOUR LAND: Upgrade needs friendly territory)") ..
		"; Ram formation " .. up.ram.f .. ", Builder formation " .. up.bld.f .. "; upgrade -> " .. to ..
		(unique and " (your unique unit)" or "") .. "; " .. table.concat(notes, ", ") .. "; highest serial " .. smax ..
		". Now: move VEF-U1-M one tile inside your borders, then Upgrade it; Upgrade VEF-U1-S without moving it; then press U1 again",
		ok and "PASS" or "CHECK")
end

-- The new unit of key k: matched by the trace, else the record's unit when
-- it changed, else your newest other unit with the old unit's name.
function UP.NewOf(up, k, rec)
	local e = up.k[k]
	local id = tonumber(up.nu[k])
	if id ~= nil then
		local u = FindUnit(up.me, id)
		if u ~= nil then return u, "trace" end
	end
	if rec ~= nil and rec.onMapUnitID ~= nil and rec.onMapUnitID ~= e.u then
		local u = FindUnit(rec.onMapPlayerID or up.me, rec.onMapUnitID)
		if u ~= nil then return u, "record" end
	end
	local best = nil
	pcall(function()
		for _, u in Players[up.me]:GetUnits():Members() do
			local okN, n = pcall(function() return u:GetExperience():GetVeteranName() end)
			if okN and n == UP.NAMES[k] and u:GetID() ~= e.u and EFV_UnitGoneReason(u, up.me, u:GetID()) == nil
					and (best == nil or u:GetID() > best:GetID()) then
				best = u
			end
		end
	end)
	return best, best and "name" or "none"
end

function UP.Press2(me, p, st, up)
	local store = EFV_Records.Load()
	local parts = {}
	for _, k in ipairs(UP.KEYS) do
		local e = up.k[k]
		local recText, rec = UP.RecText(store, up, k)
		local _, oldText = UP.Old(e)
		local nu, how = UP.NewOf(up, k, rec)
		local line = UP.NAMES[k] .. ": " .. recText
		if nu ~= nil then
			local id = nu:GetID()
			local xp = XPInfo(nu)
			local mv, mx = -1, -1
			pcall(function() mv, mx = nu:GetMovesRemaining(), nu:GetMaxMoves() end)
			up.p2[k] = { u = id, mv = mv, mx = mx, xp = xp, pr = UP.Promos(nu), dmg = UnitDamage(nu), ser = math.floor(id / UP.SLOT),
				t = UnitTypeName(nu) }
			line = line .. ((rec ~= nil and rec.onMapUnitID == id) and " (follows the new unit)" or " (NOT on the new unit)") ..
				"; old P" .. Str(e.o) .. "/" .. Str(e.u) .. " " .. oldText .. "; new (" .. how .. ") " .. UP.Desc(nu) ..
				"; moves left " .. Str(mv) .. "/" .. Str(mx) .. "; serial above " .. Str(up.smax) .. ": " ..
				((up.p2[k].ser > (tonumber(up.smax) or -1)) and "yes" or "no")
		else
			line = line .. "; old P" .. Str(e.o) .. "/" .. Str(e.u) .. " " .. oldText .. "; new unit: none found (not upgraded yet?)"
		end
		parts[#parts + 1] = line
	end
	up.step = 2
	Focus(st, -1, -1, nil, nil, p.stamp)
	UP.Answer(st, p, "UPG_U1", "U1 press 2 (T" .. Turn() .. "): " .. table.concat(parts, " | ") ..
		". Now End Turn, then press U1 a third time")
end

-- Q-A to Q-G and VEF's verdict (press 3 and the turn-start line).
function UP.Verdict(st, store)
	local up = UP.Norm(st.upg)
	local tr = up.tr
	local function Each(fn)
		local out = {}
		for _, k in ipairs(UP.KEYS) do out[#out + 1] = k .. " " .. fn(k) end
		return table.concat(out, ", ")
	end
	local std = "?"
	pcall(function() std = Str(MilitaryFormationTypes.STANDARD_FORMATION) end)
	local q = {}
	q[#q + 1] = "Q-A OnUnitMoved for the old units: " .. Each(function(k) return Str(tonumber(tr.mv[k]) or 0) end) ..
		" (VEF-U1-M moved one tile, VEF-U1-S did not move)"
	q[#q + 1] = "Q-B events about the new units: " .. Each(function(k)
		local a = tr.at[k]
		if type(a) ~= "table" then return "none" end
		return "UnitCreated " .. (a.c and ("#" .. a.c) or "no") .. " UnitInitialized " .. (a.i and ("#" .. a.i) or "no") ..
			" Events.UnitUpgraded " .. (a.g and ("#" .. a.g) or "no")
	end)
	q[#q + 1] = "Q-C old unit at the first of them: " .. Each(function(k)
		local a = tr.at[k]
		return (type(a) == "table") and Str(a.old) or "no event"
	end)
	q[#q + 1] = "Q-D moves left on the new units (press 2): " .. Each(function(k)
		local p2 = up.p2[k]
		return (type(p2) == "table") and (Str(p2.mv) .. "/" .. Str(p2.mx)) or "not read"
	end) .. "; OnUnitMoved for the new units: " .. Each(function(k) return Str(tonumber(tr.mvn[k]) or 0) end)
	q[#q + 1] = "Q-E xp/promotions/damage old -> new: " .. Each(function(k)
		local p2, e = up.p2[k], up.k[k]
		if type(p2) ~= "table" then return "not read" end
		return Str(e.xp) .. "/" .. Str(e.pr) .. "/" .. Str(e.dmg) .. " -> " .. Str(p2.xp) .. "/" .. Str(p2.pr) .. "/" .. Str(p2.dmg)
	end)
	q[#q + 1] = "Q-F formations: Ram " .. Str(up.ram and up.ram.f) .. ", Builder " .. Str(up.bld and up.bld.f) .. " (STANDARD " .. std .. ")"
	q[#q + 1] = "Q-G new serials above " .. Str(up.smax) .. ": " .. Each(function(k)
		local p2 = up.p2[k]
		if type(p2) ~= "table" then return "not read" end
		return Str(p2.ser) .. ((p2.ser > (tonumber(up.smax) or -1)) and " yes" or " no")
	end)
	local v = {}
	for _, k in ipairs(UP.KEYS) do
		local text, rec = UP.RecText(store, up, k)
		local p2 = up.p2[k]
		local follows = rec ~= nil and type(p2) == "table" and rec.onMapUnitID == p2.u
		v[#v + 1] = UP.NAMES[k] .. " " .. text .. (follows and " = the upgraded unit" or "")
	end
	return "U1 T" .. Turn() .. " VEF: " .. table.concat(v, "; ") .. " || " .. table.concat(q, " | ")
end

function UP.Press3(me, p, st, up)
	local text = UP.Verdict(st, EFV_Records.Load())
	up.step = 3
	Focus(st, -1, -1, nil, nil, p.stamp)
	UP.Answer(st, p, "UPG_SPIKE", text)
end

function UP.Press(me, p)
	local st = ScnLoad()
	local B = (type(st.proxy) == "table" and st.proxy.b) or st.ally
	if st.me ~= me or B == nil then
		Focus(st, -1, -1, nil, nil, p.stamp)
		UP.Answer(st, p, "UPG_U1", "U1: press P1 (or S0) first, in a new game", "CHECK")
		return
	end
	if type(st.proxy) ~= "table" then
		st = Session("UPG_U1", me)   -- after S0: renews the common war
		if st == nil then return end
	end
	local up = st.upg
	if type(up) ~= "table" or up.me ~= me or up.k == nil or (tonumber(up.step) or 0) >= 3 then
		UP.Press1(me, p, st, B)
	elseif Turn() == tonumber(up.turn) then
		UP.Press2(me, p, st, UP.Norm(up))
	else
		UP.Press3(me, p, st, UP.Norm(up))
	end
end

CMD.upg_spike = function(me, p)
	UP.busy = UP.busy + 1
	local ok, err = pcall(UP.Press, me, p)
	UP.busy = UP.busy - 1
	if not ok then error(err, 0) end
end

-- At your turn start after press 1, once, while press 3 has not run.
function EFV_Dev.EvalUpg(st, store, t)
	local up = st.upg
	if type(up) ~= "table" or type(up.k) ~= "table" or (tonumber(up.step) or 0) >= 3 or t <= (tonumber(up.turn) or t)
			or up.auto ~= nil then
		return
	end
	up.auto = t
	Check("UPG_SPIKE", "INFO", UP.Verdict(st, store) .. " (at your turn start; press U1 for the same line)")
end

if GameEvents.OnUnitMoved ~= nil then GameEvents.OnUnitMoved.Add(UP.OnMoved) else UP.Print("trace MISSING GameEvents.OnUnitMoved") end
if GameEvents.UnitCreated ~= nil then GameEvents.UnitCreated.Add(UP.OnCreated) else UP.Print("trace MISSING GameEvents.UnitCreated") end
if GameEvents.UnitInitialized ~= nil then GameEvents.UnitInitialized.Add(UP.OnInitialized) else UP.Print("trace MISSING GameEvents.UnitInitialized") end
if Events.UnitUpgraded ~= nil then Events.UnitUpgraded.Add(UP.OnUpgraded) else UP.Print("trace MISSING Events.UnitUpgraded") end
end -- upgrade spike U1

-- ---------------------------------------------------------------------------
-- Evaluation: at your turn start and on "Check now".
-- ---------------------------------------------------------------------------
local function Evaluate(me, manual)
	local st = ScnLoad()
	if st.me == nil or st.me ~= me then
		if manual then Check("CHECK_NOW", "INFO", "no session (press S0 first)") end
		return
	end
	local t = Turn()
	local store = EFV_Records.Load()
	EV.Observe(st, store, me)
	if not manual then
		EV.CheckArrivals(st, store, t)
		EV.CheckHome(st, store, t)
		EV.EvalS2(st, store, t)
		EV.EvalS3(st, store, t)
		EV.EvalS4(st, store, t)
		EV.EvalS5(st, store, t)
		EV.EvalS8(st, store, t)
		EV.EvalS9(st, store, t)
		EV.EvalS10(st, store, t)
		EV.EvalVS(st, t)
		EFV_Dev.EvalAir(st, t)
		EFV_Dev.EvalCorps(st, store, t)
		EFV_Dev.EvalProxy(st, store, t)
		EFV_Dev.EvalUpg(st, store, t)
	end
	EV.EvalS7(st, store, t, manual)
	EV.EvalS11(st, store, t, manual)
	EV.EvalS12(st, store, t, manual)
	EV.EvalS13(st, store, t, manual)
	if not manual then EV.EvalS14(st, store, t, manual) end
	EV.EvalS16(st, store, t, manual)
	EV.EvalS18(st, store, t, manual)
	EV.EvalS19(st, store, t, manual)
	EFV_Records.Commit(store)
	ScnSave(st)
	if manual then Check("CHECK_NOW", "INFO", "evaluated") end
end

CMD.scn_check = function(me, p)
	Evaluate(me, true)
end

local function OnTurnStartComplete(pid)
	local okH, human = pcall(function() return Players[pid]:IsHuman() end)
	if not (okH and human) then return end
	local ok, err = pcall(Evaluate, pid, false)
	if not ok then Log("scn", "ERROR evaluate: " .. Str(err)) end
end

local function OnCombat(aP, aU, dP, dU)
	local ok, err = pcall(EV.OnCombatT31, aP, aU, dP, dU)
	if not ok then Log("scn", "ERROR combat check: " .. Str(err)) end
end

local function OnTurnEnded(turn)
	local ok, err = pcall(EV.DevCleanup, turn)
	if not ok then Log("scn", "ERROR end-of-turn cleanup: " .. Str(err)) end
end

local function OnTurnStarted(pid)
	local ok, err = pcall(EV.OnTurnStartedT31, pid)
	if not ok then Log("scn", "ERROR S10 Barbarian removal: " .. Str(err)) end
end

GameEvents.PlayerTurnStarted.Add(OnTurnStarted)
GameEvents.PlayerTurnStartComplete.Add(OnTurnStartComplete)
GameEvents.OnCombatOccurred.Add(OnCombat)
GameEvents.OnGameTurnEnded.Add(OnTurnEnded)
EFV_Dev.Evaluate = Evaluate
end -- final session

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function EFV_Dev.OnRequest(playerID, params)
	if type(params) ~= "table" then
		Log("dispatch", "non-table params")
		return
	end
	local cmd = params.cmd
	local fn = CMD[cmd]
	if fn == nil then
		Log("dispatch", "unknown cmd " .. Str(cmd))
		return
	end
	local ok, err = pcall(fn, playerID, params)
	if not ok then
		Log(cmd, "ERROR " .. Str(err))
	end
end

EFV_Dev.CMD = CMD

GameEvents.EFV_Dev.Add(EFV_Dev.OnRequest)
Log("init", "EFV_Dev gameplay loaded; registered GameEvents.EFV_Dev; version=" .. EFV_Dev.VERSION
	.. " for EFV " .. EFV_Dev.FOR_EFV .. " EFV=" .. Str(EFV_Config and EFV_Config.VERSION))
if EFV_Config == nil or EFV_Config.VERSION ~= EFV_Dev.FOR_EFV then
	Log("init", "WARNING version mismatch: EFV_Dev " .. EFV_Dev.VERSION .. " is built for EFV " .. EFV_Dev.FOR_EFV ..
		", loaded EFV " .. Str(EFV_Config and EFV_Config.VERSION))
end
