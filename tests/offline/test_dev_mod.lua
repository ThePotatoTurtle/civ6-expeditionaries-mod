-- @harness native
-- EFV_Dev (T3) gameplay commands, run offline: EFV + EFV_Dev_Gameplay.lua in
-- the fake engine, requests fired as GameEvents.EFV_Dev(playerID, params)
-- exactly like the panel's EXECUTE_SCRIPT requests.

local function Boot()
	local S = H.baseScenario()
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	return S
end

local function Dev(cmd, p)
	p = p or {}
	p.OnStart = "EFV_Dev"
	p.cmd = cmd
	if p.target == nil then p.target = 1 end
	for _, k in ipairs({ "unitOwner", "unitID", "cityOwner", "cityID", "x", "y" }) do
		if p[k] == nil then p[k] = -1 end
	end
	H.request(0, p)
end

local function Sel(u) return { unitOwner = u:GetOwner(), unitID = u:GetID(), x = u:GetX(), y = u:GetY() } end
local function With(a, b) for k, v in pairs(b) do a[k] = v end return a end

test("version: EFV_Config.VERSION logged at load by EFV and EFV_Dev; EFV_Dev built for it; both modinfo names", function()
	H.baseScenario()
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	local v = EFV_Config.VERSION
	H.eq(type(v), "string")
	H.ok(#H.lines("[Init] EFV_Gameplay loading version=" .. v, true) == 1, "EFV load line")
	H.eq(EFV_Dev.FOR_EFV, v, "EFV_Dev.FOR_EFV: the EFV build the dev tools are made for")
	local dv = EFV_Dev.VERSION
	H.eq(string.sub(dv, 1, #v), v, "EFV_Dev.VERSION starts with the EFV version (own bumps as suffix)")
	H.ok(#H.lines("version=" .. dv .. " for EFV " .. v .. " EFV=" .. v, true) == 1, "EFV_Dev load line")
	H.ok(not H.hasLine("version mismatch"))
	H.ok(string.find(__py_read("EFV/EFV.modinfo"), "Expeditionary Forces v" .. v .. "</en_US>", 1, true) ~= nil, "EFV.modinfo title")
	H.ok(string.find(__py_read("EFV_Dev/EFV_Dev.modinfo"), "(testing only) v" .. dv .. "</Name>", 1, true) ~= nil, "EFV_Dev.modinfo name")
end)

test("dev: registers GameEvents.EFV_Dev; unknown command is logged", function()
	Boot()
	H.eq(#GameEvents.EFV_Dev.handlers, 1)
	Dev("nope")
	H.ok(H.hasLine("unknown cmd nope"))
end)

test("dev: spawn N units of Type for Target near the selected plot", function()
	Boot()
	Dev("spawn", { type = "UNIT_SWORDSMAN", amount = 2, target = 1, x = 22, y = 12 })
	H.len(H.unitsOf(1, "UNIT_SWORDSMAN"), 2)
	Dev("spawn", { type = "UNIT_GALLEY", target = 0, x = 11, y = 10 })
	H.len(H.unitsOf(0, "UNIT_GALLEY"), 0, "no water nearby: nothing created")
	H.ok(H.hasLine("no free plot"))
end)

test("dev: fill rings around a city (P1.6 setup)", function()
	local S = Boot()
	Dev("fill", { cityOwner = 1, cityID = S.c1b.id, amount = 5, target = 1 })
	H.isnil((EFV_SpawnCandidates(S.c1b.x, S.c1b.y, "LAND", 1, nil)), "no spawn tile left")
end)

test("dev: damage / heal / xp / promote / finish / corps / kill on the selected unit", function()
	Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Dev("damage", With({ amount = 35 }, Sel(u)))
	H.eq(u:GetDamage(), 35)
	Dev("heal", Sel(u))
	H.eq(u:GetDamage(), 0)
	Dev("xp", With({ amount = 20 }, Sel(u)))
	H.eq(u.xp, 15, "ChangeExperience stops at the next-level threshold (Session B / F T08)")
	Dev("promote", With({ type = "PROMOTION_TORTOISE" }, Sel(u)))
	H.deq(H.promotionTypes(u), { "PROMOTION_TORTOISE" })
	Dev("promote", Sel(u))
	H.eq(#H.promotionTypes(u), 2, "first missing promotion of the unit's class")
	Dev("finish", Sel(u))
	H.eq(u:GetMovesRemaining(), 0)
	Dev("corps", Sel(u))
	H.eq(u:GetMilitaryFormation(), MilitaryFormationTypes.CORPS_FORMATION)
	Dev("corps", With({ amount = 0 }, Sel(u)))
	H.eq(u:GetMilitaryFormation(), 0)
	Dev("unit", Sel(u))
	H.ok(H.hasLine("record=none"))
	Dev("kill", Sel(u))
	H.ok(not H.unitAlive(u))
end)

test("dev: gold / setgold / res / setres", function()
	Boot()
	Dev("gold", { amount = 250 })
	H.eq(H.gold(0), 1250)
	Dev("setgold", { amount = 10 })
	H.eq(H.gold(0), 10)
	Dev("gold", { amount = 5, who = 1 })
	H.eq(H.gold(1), 1005)
	Dev("res", { type = "RESOURCE_OIL", amount = 7 })
	H.eq(H.res(0, "RESOURCE_OIL"), 7)
	Dev("setres", { type = "RESOURCE_OIL", amount = 2 })
	H.eq(H.res(0, "RESOURCE_OIL"), 2)
end)

test("dev: ally / friend / war / meet / diplo; peace reports manual fallback", function()
	Boot()
	Dev("ally", { target = 2 })
	H.ok(Players[0]:GetDiplomacy():HasAllied(2) and Players[2]:GetDiplomacy():HasAllied(0))
	Dev("ally", { target = 2, amount = 0 })
	H.ok(not Players[0]:GetDiplomacy():HasAllied(2))
	Dev("friend", { target = 3, a = 1 })
	H.ok(Players[1]:GetDiplomacy():HasDeclaredFriendship(3), "extra a=<pid> sets another pair")
	Dev("war", { target = 2 })
	H.ok(Players[0]:GetDiplomacy():IsAtWarWith(2))
	Dev("peace", { target = 2 })
	H.ok(H.hasLine("make peace manually"), "no scripted peace API (PLAN 5.0)")
	Dev("diplo")
	H.ok(H.hasLine("[Dev] diplo: P0"))
end)

test("dev: shift / expire / setfield drive EFV records through Game properties", function()
	local S = Boot()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1)
	local r = H.record()
	H.eq(r.arrivalTurn, 3)
	Dev("shift", { amount = 1 })                       -- only record: arrival 3 -> 2
	H.eq(H.record().arrivalTurn, 2)
	H.endTurn()
	r = H.record()
	H.eq(r.state, "DEPLOYED", "arrived one turn early")
	local sel = { unitOwner = 1, unitID = r.onMapUnitID }
	Dev("shift", With({ amount = 17 }, sel))           -- P1.3: 17 turns
	H.eq(H.record().deployedTurn, r.deployedTurn - 17)
	Dev("expire", sel)
	H.endTurn()
	H.eq(H.record().state, "RETURNING", "expired at the next turn start")
	Dev("setfield", { rec = r.id, field = "spawnFailCount", value = "3" })
	H.eq(H.record().spawnFailCount, 3)
	Dev("records")
	H.ok(H.hasLine("[Dev] records: id=" .. r.id))
	Dev("dump")
	H.ok(H.hasLine("[Dump]"))
	Dev("state")
	H.ok(H.hasLine("EFV_NextID=2"))
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- Panel (UI context) smoke test with lib/fake_ui.lua
-- ---------------------------------------------------------------------------
local function BootUI()
	local S = H.baseScenario()
	include("fake_ui")
	FAKE_UI.Enable()
	include("EFV_Config")
	EFV_Config.LOG_LEVEL = 3
	FAKE.dofile("EFV_Dev/UI/EFV_Dev_Panel.lua")
	H.markBody()
	return S
end

test("dev panel: loads hidden-safe, Ctrl+Shift+D toggles, EFV UI API available", function()
	BootUI()
	H.ok(not ContextPtr:IsHidden(), "Initialize un-hides the context (note 19)")
	H.ok(Controls.Main:IsHidden(), "panel starts closed")
	H.ok(FAKE_UI.Key(Keys.D, { ctrl = true, shift = true }), "hotkey consumed")
	H.ok(not Controls.Main:IsHidden(), "open")
	H.ok(not FAKE_UI.Key(Keys.D, {}), "plain D not consumed")
	H.ok(FAKE_UI.Key(Keys.VK_ESCAPE), "Esc closes")
	H.ok(Controls.Main:IsHidden())
	H.ok(not FAKE_UI.Key(Keys.VK_ESCAPE), "Esc ignored while closed")
	H.len(H.lines("EFV_UIShared loaded=true", true), 1, "panel ready line")
	H.clean()
end)

test("dev panel: buttons send flat EFV_Dev requests with selection and fields", function()
	BootUI()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	FAKE_UI.selectedUnit = u
	FAKE_UI.Key(Keys.D, { ctrl = true, shift = true })
	Controls.AmountEdit:SetText("35")
	Controls.ExtraEdit:SetText("rec=4; field = graceTurnsLeft ;value=1")
	local b = FAKE_UI.FindButton("Damage = Amount")
	H.notnil(b, "button built")
	b:Click()
	local req = FAKE_UI.requests[#FAKE_UI.requests]
	H.eq(req.op, PlayerOperations.EXECUTE_SCRIPT)
	local p = req.params
	H.eq(p.OnStart, "EFV_Dev"); H.eq(p.cmd, "damage"); H.eq(p.unitID, u.id); H.eq(p.unitOwner, 0)
	H.eq(p.amount, 35); H.eq(p.rec, 4); H.eq(p.field, "graceTurnsLeft"); H.eq(p.value, 1)
	H.eq(p.x, 11); H.eq(p.y, 10); H.eq(p.target, 1, "default target = first other major")
	for k, v in pairs(p) do
		H.ok(type(v) == "number" or type(v) == "string", "flat param " .. k)
	end
end)

test("dev panel: forged EFV_Send targets the target player's nearest city", function()
	local S = BootUI()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	FAKE_UI.selectedUnit = u
	FAKE_UI.Key(Keys.D, { ctrl = true, shift = true })
	Controls.TypeEdit:SetText("EXPEDITIONARY")
	Controls.AmountEdit:SetText("100")
	FAKE_UI.FindButton("EFV_Send sel. unit"):Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(p.OnStart, "EFV_Send"); H.eq(p.unitID, u.id); H.eq(p.recipientID, 1)
	H.eq(p.destX, S.c1b.x, "nearest of B's cities to the unit"); H.eq(p.destY, S.c1b.y)
	H.eq(p.forceType, "EXPEDITIONARY"); H.eq(p.expectedFee, 100)
	FAKE_UI.selectedCity = S.c1
	FAKE_UI.FindButton("EFV_Send sel. unit"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.destX, S.c1.x, "selected target city wins")
	FAKE_UI.FindButton("EFV_Recall sel. unit"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.OnStart, "EFV_Recall")
	FAKE_UI.FindButton("EFV_Entrust sel. city"):Click()
	local e = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(e.OnStart, "EFV_Entrust"); H.eq(e.x, S.c1.x); H.eq(e.recipientID, 1)
end)

test("dev: extra rec=<id> targets the record's (AI-owned) unit; place moves it (Phase 2 tests)", function()
	local S = Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.records()[1]
	H.turns(r.arrivalTurn - FAKE.turn)
	r = H.records()[1]
	H.eq(r.state, "DEPLOYED")
	local nu = Players[1]:GetUnits():FindID(r.onMapUnitID)
	local p = H.neutralPlot(30, 5)
	Dev("place", { rec = r.id, tx = p:GetX(), ty = p:GetY() })
	H.eq(nu:GetX(), p:GetX()); H.eq(nu:GetY(), p:GetY())
	Dev("damage", { rec = r.id, amount = 30 })
	H.eq(nu:GetDamage(), 30)
	Dev("place", { rec = r.id })
	H.ok(H.hasLine("need extra tx"))
	-- A reused slot is not the record's unit (Session C identity check).
	H.killUnit(nu)
	local other = H.unitInSlot(nu, 1, "UNIT_SWORDSMAN", 22, 12)
	Dev("damage", { rec = r.id, amount = 50 })
	H.eq(other:GetDamage(), 0, "the other unit is untouched")
	H.ok(H.hasLine("no unit selected"))
end)

-- ---------------------------------------------------------------------------
-- Final session scenarios (EFV/TESTING_FINAL.md): each button builds its
-- situation, the next turn start (or "Check now") prints one
-- "[EFV][CHECK] <ID> <verdict>" line. Since EFV_Dev 0.6.1-dev.1 the session
-- starts from a BRAND-NEW game (an old save would bring back its own mod
-- set), so every scenario test starts from FreshBoot + S0.
-- ---------------------------------------------------------------------------
local function CheckLine(id, verdict)
	return H.hasLine("[EFV][CHECK] " .. id .. " " .. verdict)
end

local function SecondCityState(id, x, y)
	FAKE.NewPlayer(id, { kind = "CITY_STATE", gold = 0 })
	return H.city(id, x, y, { capital = true, name = "LOC_CITY_CS" .. id })
end

-- A new game after the first End Turn: the cities of H.baseScenario (every
-- civ has founded its capital) plus city-states 5 and 6, but nobody has met
-- anybody, there is no war, friendship, alliance or open borders, and
-- player 0 has revealed only the land around its own cities.
local function FreshBoot()
	H.world({ turn = 2 })
	local S = {}
	S.c0 = H.city(0, 10, 10, { capital = true, name = "LOC_CITY_A" })
	S.c0b = H.city(0, 14, 20, { name = "LOC_CITY_A2" })
	S.c1 = H.city(1, 22, 10, { capital = true, name = "LOC_CITY_B" })
	S.c1b = H.city(1, 18, 13, { name = "LOC_CITY_B2" })
	S.c2 = H.city(2, 40, 30, { capital = true, name = "LOC_CITY_F" })
	S.c3 = H.city(3, 70, 40, { capital = true, name = "LOC_CITY_C" })
	S.c4 = H.city(4, 30, 20, { capital = true, name = "LOC_CITY_CS" })
	S.c5 = SecondCityState(5, 40, 12)
	S.c6 = SecondCityState(6, 60, 22)
	FAKE.unrevealed[0] = {}
	for i = 0, Map.GetPlotCount() - 1 do
		local p = Map.GetPlotByIndex(i)
		if H.dist(p, S.c0) > 3 and H.dist(p, S.c0b) > 3 then FAKE.unrevealed[0][i] = true end
	end
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	return S
end

local function Setup()
	local S = FreshBoot()
	Dev("scn_setup", { stamp = 1 })
	H.ok(CheckLine("SETUP", "PASS"), "S0 setup passes")
	return S
end

local function Named(pid, name)
	for _, u in ipairs(H.unitsOf(pid)) do
		if u.vetName == name then return u end
	end
	return nil
end

local function Arrive()
	Dev("scn_arrive")
	H.endTurn()
end

local function Revealed(pid, c) return PlayersVisibility[pid]:IsRevealed(c.x, c.y) end

test("final S0: from a brand-new game (nobody met, nothing revealed) the three sends are possible", function()
	local S = FreshBoot()
	local d0 = Players[0]:GetDiplomacy()
	H.ok(not d0:HasMet(1) and not d0:HasMet(4), "fresh game: nobody met")
	H.ok(not Revealed(0, S.c1) and not Revealed(0, S.c4), "fresh game: B's and the city-state's cities not revealed")
	local probe = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	local ok, reasons = EFV_EvaluateSend(0, probe, 1, S.c1, "EXPEDITIONARY", EFV_Records.Load())
	H.ok(not ok, "the picker refuses B before S0")
	H.contains(reasons, "NOT_REVEALED"); H.contains(reasons, "NOT_PARTNER"); H.contains(reasons, "NO_COMMON_WAR")
	H.killUnit(probe)
	Dev("scn_setup", { stamp = 1 })
	H.ok(CheckLine("SETUP", "PASS"), "S0 passes")
	H.ok(H.hasLine("picker: Expeditionary ok, Volunteers ok, City-State ok"), "VEF's own send rule accepts all three")
	for _, pid in ipairs({ 1, 2, 3, 4 }) do H.ok(d0:HasMet(pid), "met " .. pid) end
	H.ok(Players[1]:GetDiplomacy():HasMet(3), "B met C (for its war declaration)")
	for _, c in ipairs({ S.c1, S.c1b, S.c2, S.c3, S.c4 }) do H.ok(Revealed(0, c), "city revealed " .. c.name) end
	H.ok(PlayersVisibility[0]:IsRevealed(S.c1.x + 3, S.c1.y), "tiles around the city revealed too")
	H.ok(not Revealed(0, S.c5), "other city-states untouched")
	for _, pid in ipairs({ 0, 1, 2, 4 }) do H.ok(Players[pid]:GetDiplomacy():IsAtWarWith(3), pid .. " at war with C") end
	H.ok(d0:HasDeclaredFriendship(1) and Players[1]:GetDiplomacy():HasDeclaredFriendship(0), "B: declared friendship both ways")
	H.ok(d0:HasDeclaredFriendship(2), "F: friend")
	H.ok(not d0:HasAllied(1), "no alliance (none at turn 1; SetHasAllied(false) is a no-op in game)")
	H.ok(EFV_HasOpenBordersFrom(0, 1), "B grants you open borders (scripted deal, seen by VEF's deal scan)")
	H.ok(not EFV_HasOpenBordersFrom(1, 0), "one way only")
	H.eq(EFV_PartnerBasis(0, 1), "FRIEND"); H.eq(EFV_VolunteerBasis(0, 1), "FRIEND_OB")
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.me, 0); H.eq(st.ally, 1); H.eq(st.friend, 2); H.eq(st.enemy, 3); H.eq(st.cs, 4)
	H.eq(st.partner, "FRIEND"); H.eq(st.basis, "FRIEND_OB")
	H.eq(st.focus.stamp, 1, "the panel matches its request by stamp")
	local swords = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(swords, 3)
	for _, u in ipairs(swords) do
		H.eq(u:GetMovesRemaining(), u:GetMaxMoves(), "full moves")
		H.ok(H.dist(u, S.c0) <= 4, "next to your capital")
	end
	H.eq(H.gold(0), 3000)
	H.eq(H.res(0, "RESOURCE_IRON"), 10)
	-- the real sends then work
	H.send(0, swords[1], 1, S.c1, "EXPEDITIONARY", 999)
	H.send(0, swords[2], 1, S.c1, "VOLUNTEER", 999)
	H.send(0, swords[3], 4, S.c4, "CS_EXPEDITIONARY", 999)
	H.len(H.records(), 3, "three sends accepted")
	Dev("scn_arrive", { unitOwner = -1 })
	H.ok(CheckLine("FAST_TRAVEL", "INFO"))
	H.clean()
end)

test("final S0: no capital yet, or the AI has not founded its cities: CHECK with what to do, nothing changed", function()
	H.world({ turn = 1 })
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	Dev("scn_setup")
	H.ok(CheckLine("SETUP", "CHECK"))
	H.ok(H.hasLine("found your capital with the Settler"))
	H.city(0, 10, 10, { capital = true })
	H.city(1, 22, 10, { capital = true })
	Dev("scn_setup")
	H.ok(H.hasLine("End Turn once more"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 0, "nothing created")
	H.ok(not Players[0]:GetDiplomacy():HasMet(1), "nobody met")
	H.isnil(H.prop("EFV_DEV_SCN"), "no session stored")
end)

test("final S0: no reveal call -> a Scout next to each city reveals it", function()
	FAKE.revealUnavailable = true
	FAKE.unitSight = true
	local S = FreshBoot()
	Dev("scn_setup")
	H.ok(CheckLine("SETUP", "PASS"))
	H.ok(H.hasLine("Scout(s)"))
	H.ok(Revealed(0, S.c1) and Revealed(0, S.c4))
	local scouts = H.unitsOf(0, "UNIT_SCOUT")
	H.ok(#scouts >= 3, "a Scout next to the cities that were not revealed")
	for _, u in ipairs(scouts) do H.eq(u.vetName, "VEF-SCOUT") end
end)

test("final S0: the scripted open-borders deal fails -> alliance flag as the last resort", function()
	FAKE.refuseScriptedDeals = true
	FreshBoot()
	Dev("scn_setup")
	H.ok(CheckLine("SETUP", "PASS"))
	H.ok(Players[0]:GetDiplomacy():HasAllied(1))
	H.eq(H.prop("EFV_DEV_SCN").basis, "ALLIANCE")
end)

test("final S0: B makes peace with C later -> the next scenario button renews the common war", function()
	Setup()
	H.peace(1, 3)
	H.ok(not Players[1]:GetDiplomacy():IsAtWarWith(3))
	Dev("scn_arrive")
	H.ok(Players[1]:GetDiplomacy():IsAtWarWith(3), "B at war with C again")
	H.ok(EFV_HasCommonWar(0, 1))
end)

test("final S0: other buttons ask for S0 first", function()
	Boot()
	Dev("scn_grace")
	H.ok(CheckLine("GRACE", "CHECK"))
	H.ok(H.hasLine("press S0 Setup session first"))
end)

test("final S1 + S2: City-State unit arrives (ARRIVE), expires on valid land (EXPIRE) and comes home (HOME)", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 4, S.c4, "CS_EXPEDITIONARY", 999)
	Arrive()
	H.ok(CheckLine("ARRIVE", "PASS"), "arrival placement")
	Dev("scn_expire_cs")
	H.endTurn()
	H.ok(CheckLine("EXPIRE", "PASS"))
	Arrive()
	H.ok(CheckLine("HOME", "PASS"), "the returned unit is found next to its city")
	H.len(H.records(), 0)
	H.clean()
end)

test("final S3: grace, mutiny (20 damage), mutiny return and home with the damage kept", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "EXPEDITIONARY", 999)
	Arrive()
	Dev("scn_grace")
	H.endTurn()
	H.ok(CheckLine("GRACE", "PASS"), "grace with 5 turns")
	Dev("scn_grace")
	H.endTurn()
	H.ok(CheckLine("MUTINY", "PASS"), "mutiny with 20 damage")
	Dev("scn_grace")
	H.endTurn()
	H.ok(CheckLine("MUTINY_RETURN", "PASS"))
	Arrive()
	H.ok(CheckLine("HOME", "PASS"))
	H.ok(H.hasLine("damage=20"), "damage kept")
	H.clean()
end)

test("final S3: the AI cannot walk the unit back before the pipeline (pending FinishMoves)", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "EXPEDITIONARY", 999)
	Arrive()
	Dev("scn_grace")
	local r = H.records()[1]
	local u = Players[1]:GetUnits():FindID(r.onMapUnitID)
	H.endTurn({ act = function(p)
		if p == 1 then H.eq(u:GetMovesRemaining(), 0, "held by EFV's pending exhaust") end
	end })
	H.ok(CheckLine("GRACE", "PASS"))
end)

test("final S4: Volunteer lapse paused on valid land, countdown holds, recall seen, friendship restored", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER", 999)
	Arrive()
	Dev("scn_lapse")
	H.ok(not Players[0]:GetDiplomacy():HasDeclaredFriendship(1), "friendship ended")
	H.isnil(EFV_VolunteerBasis(0, 1), "no Volunteer basis")
	H.endTurn()
	H.ok(CheckLine("LAPSE", "PASS"), "paused lapse")
	H.endTurn()
	H.ok(CheckLine("LAPSE_PAUSE", "PASS"), "countdown did not move")
	local r = H.records()[1]
	H.request(0, { OnStart = "EFV_Recall", unitID = r.onMapUnitID })
	Dev("scn_arrive")
	H.ok(CheckLine("RECALL", "PASS"))
	Dev("scn_lapse")
	H.ok(Players[0]:GetDiplomacy():HasDeclaredFriendship(1), "friendship restored")
	H.eq(EFV_VolunteerBasis(0, 1), "FRIEND_OB")
	H.endTurn()
	H.ok(CheckLine("LAPSE_RESTORE", "PASS"))
	H.ok(CheckLine("HOME", "PASS"))
	H.clean()
end)

test("final S5: upgrade relink, normal upgrade (no unique unit for the civ)", function()
	Setup()
	Dev("scn_upgrade", { stamp = 7 })
	H.ok(CheckLine("UPGRADE", "INFO"))
	local u = Named(0, "VEF-UPGRADE")
	H.notnil(u, "unit created")
	H.eq(u.typeName, "UNIT_WARRIOR")
	H.upgrade(u, "UNIT_SWORDSMAN")
	H.endTurn()
	H.ok(CheckLine("UPGRADE", "PASS"))
	H.clean()
end)

test("final S5: upgrade relink into the civilization's unique unit (Macedon: Warrior -> Hypaspist)", function()
	Setup()
	Players[0].civType = "CIVILIZATION_MACEDON"
	Dev("scn_upgrade")
	H.ok(H.hasLine("UNIT_MACEDONIAN_HYPASPIST (your unique unit)"))
	local u = Named(0, "VEF-UPGRADE")
	H.upgrade(u, "UNIT_MACEDONIAN_HYPASPIST")
	H.endTurn()
	H.ok(CheckLine("UPGRADE", "PASS"))
	H.ok(H.hasLine("-> UNIT_MACEDONIAN_HYPASPIST"))
	H.clean()
end)

test("final S5: no click -> reminder, then CHECK", function()
	Setup()
	Dev("scn_upgrade")
	H.endTurn()
	H.ok(H.hasLine("click Upgrade"))
	H.turns(2)
	H.ok(CheckLine("UPGRADE", "CHECK"))
end)

test("final S6: veteran copies A / B / C with gameplay verdicts (fake engine: a created unit stays level 1)", function()
	Boot()
	local v = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" }, xp = 50 })
	Dev("scn_vet", With({ stamp = 9 }, Sel(v)))
	for _, n in ipairs({ "VEF-A", "VEF-B", "VEF-C" }) do H.notnil(Named(0, n), n) end
	H.ok(H.hasLine("[EFV][CHECK] VET_A "), "route A verdict")
	H.ok(H.hasLine("[EFV][CHECK] VET_C CHECK"), "route C: the known level reset")
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.vet.stamp, 9)
	H.eq(#st.vet.promos, 2)
	local b = Named(0, "VEF-B")
	H.eq(b.xp, b:GetExperience():GetExperienceForNextLevel(), "B waits at the threshold for the PROMOTE command")
	b.promotions[GameInfo.UnitPromotions[st.vet.promos[1]].Index] = true   -- the panel's PROMOTE lands
	Dev("scn_vetb", { i = 2 })
	b.promotions[GameInfo.UnitPromotions[st.vet.promos[2]].Index] = true
	Dev("scn_vetdone")
	H.ok(H.hasLine("[EFV][CHECK] VET_B "), "route B verdict")
	H.clean()
end)

test("final S6: a unit without promotions gets XP to the threshold and a hint", function()
	Boot()
	local u = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	Dev("scn_vet", Sel(u))
	H.eq(u.xp, 15)
	H.ok(H.hasLine("Promote it in its unit panel"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 1, "no copies yet")
end)

test("final S7: a City-State unit killed before its host's last city falls is not sent home", function()
	local S = Setup()
	local c5 = S.c5
	Dev("scn_kill")
	H.ok(CheckLine("KILLED", "INFO"))
	H.ok(Players[0]:GetDiplomacy():IsAtWarWith(5), "you are at war with the city-state")
	local w = Named(5, "VEF-KILL")
	H.notnil(w, "the tracked Warrior")
	H.eq(w.damage, 60)
	H.eq(CityManager.GetDistrictAt(c5.x, c5.y):GetDamage(DefenseTypes.DISTRICT_GARRISON), 199, "the city is left at 1 HP")
	H.ok(Revealed(0, c5), "the city-state's city is revealed")
	local tank = H.unitsOf(0, "UNIT_TANK")[1]
	H.len(H.unitsOf(0, "UNIT_TANK"), 3)
	H.combat(tank, w, 100)
	H.kill(5)
	GameEvents.CityConquered(0, 5, c5.id, c5.x, c5.y)
	CityManager.TransferCity(c5, 0, CityTransferTypes.BY_COMBAT)
	H.endTurn()
	H.ok(CheckLine("KILLED", "PASS"))
	H.ok(not H.hasLine("reason=RECIPIENT_GONE"), "never returned")
	H.clean()
end)

test("final S8: relink guard: two identical city-state Warriors are not adopted", function()
	Setup()
	Dev("scn_guard")
	H.ok(CheckLine("GUARD", "INFO"))
	H.endTurn()
	H.ok(H.hasLine("[Levy] ambiguous"), "EFV saw two candidates")
	H.ok(CheckLine("GUARD", "PASS"))
	H.len(H.records(), 0)
	H.clean()
end)

test("final S9: crowded arrival picks ring 3 to 5, never a city or closed land", function()
	Setup()
	Dev("scn_place")
	H.ok(CheckLine("CROWDED", "INFO"))
	H.endTurn()
	H.ok(CheckLine("CROWDED", "PASS"))
	H.ok(H.hasLine("placed at ring 3"))
	H.len(H.unitsOf(1, "UNIT_WARRIOR"), 0, "fillers removed")
	H.clean()
end)

test("final S10: combat during mutiny: damage seen at the event, kept through the heal, +20 next turn", function()
	Setup()
	Dev("scn_t31")
	local u = Named(0, "VEF-T31")
	H.notnil(u)
	local barb = H.unitsOf(63, "UNIT_WARRIOR")
	H.len(barb, 2)
	H.combat(u, barb[1], 30, 25)
	H.ok(CheckLine("T31_EVENT", "PASS"))
	H.endTurn({ heal = 10 })
	H.ok(CheckLine("T31", "PASS"))
	H.ok(H.hasLine("damage 45"))
	H.len(H.records(), 0, "cleaned up")
	H.clean()
end)

test("final S10: damage applied after the combat event -> T31_EVENT CHECK", function()
	Setup()
	FAKE.combatDamageBeforeEvent = false
	Dev("scn_t31")
	local u = Named(0, "VEF-T31")
	H.combat(u, H.unitsOf(63, "UNIT_WARRIOR")[1], 30, 25)
	H.ok(CheckLine("T31_EVENT", "CHECK"))
end)

test("final S11: C has only its capital -> a new small city is founded for C, weakened, Tanks next to it", function()
	local S = Setup()
	Dev("scn_lapse")                     -- S4 left the friendship off: S11 renews it
	Dev("scn_entrust")
	H.ok(CheckLine("ENTRUST", "INFO"))
	H.ok(H.hasLine("new city founded for"))
	local s12 = H.prop("EFV_DEV_SCN").s12
	local city = CityManager.GetCityAt(s12.cx, s12.cy)
	H.notnil(city)
	H.eq(city:GetOwner(), 3); H.ne(city.id, S.c3.id, "not C's capital (taking it would eliminate C)")
	local d = H.dist(city, S.c0)
	H.ok(d >= 5 and d <= 10, "5-10 tiles from your capital")
	H.eq(CityManager.GetDistrictAt(city.x, city.y):GetDamage(DefenseTypes.DISTRICT_GARRISON), 199, "1 HP left")
	H.ok(Revealed(0, city))
	H.len(H.unitsOf(0, "UNIT_TANK"), 3)
	for _, t in ipairs(H.unitsOf(0, "UNIT_TANK")) do H.ok(H.dist(t, city) <= 4) end
	H.eq(EFV_PartnerBasis(0, 1), "FRIEND", "partner basis renewed")
	local rec = EFV_EntrustCandidates(0, 3)
	H.contains(rec, 1, "B qualifies as Entrust recipient")
	CityManager.TransferCity(city, 1, CityTransferTypes.BY_GIFT)
	Dev("scn_check")
	H.ok(CheckLine("ENTRUST", "PASS"))
	H.clean()
end)

test("final S11: C already has a second city -> that one (nearest non-capital), no new city", function()
	Setup()
	local c3b = H.city(3, 30, 40, { name = "LOC_CITY_C2" })
	Dev("scn_entrust")
	local s12 = H.prop("EFV_DEV_SCN").s12
	H.eq(s12.cx, c3b.x); H.eq(s12.cy, c3b.y)
	H.ok(not H.hasLine("new city founded"))
	H.len(FAKE.CitiesOf(3), 2)
end)

test("final panel: scenario buttons send stamped requests; Go to scenario looks at the focus", function()
	local S = BootUI()
	FAKE_UI.Key(Keys.D, { ctrl = true, shift = true })
	FAKE_UI.FindButton("S0 Setup session"):Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(p.cmd, "scn_setup")
	H.ok(type(p.stamp) == "number" and p.stamp > 0, "stamp")
	for _, label in ipairs({ "S1 Arrive next turn", "S2 Expire CS unit", "S3 Grace/mutiny step", "S4 Lapse on/off", "S5 Upgrade test",
		"S6 Veteran copies", "S7 Killed unit", "S8 Relink guard", "S9 Crowded arrival", "S10 Mutiny combat", "S11 Entrust city",
		"Go to scenario", "Check now" }) do
		H.notnil(FAKE_UI.FindButton(label), label)
	end
	H.ok(string.find(Controls.InfoLabel:GetText(), "start a NEW game, then press S0", 1, true) ~= nil, "no session yet")
	H.eq(p.target, 1)
	Game:SetProperty("EFV_DEV_SCN", { me = 0, ally = 2, friend = 1, enemy = 3, cs = 4,
		focus = { x = S.c1.x, y = S.c1.y, o = -1, u = -1, stamp = p.stamp } })
	local looked = nil
	UI.LookAtPlot = function(x, y) looked = { x, y } end
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.deq(looked, { S.c1.x, S.c1.y }, "camera moved after the scenario answered")
	H.ok(string.find(Controls.InfoLabel:GetText(), "Session: B=", 1, true) ~= nil, "the info line names B, F, C and CS")
	FAKE_UI.FindButton("Check now"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.target, 2, "after S0 the Target is B")
	looked = nil
	FAKE_UI.FindButton("Go to scenario"):Click()
	H.deq(looked, { S.c1.x, S.c1.y })
end)
