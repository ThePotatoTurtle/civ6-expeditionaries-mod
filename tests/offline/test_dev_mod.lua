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
local function FreshBoot(opts)
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
	H.loadEFV(opts)
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	return S
end

local function Setup(opts)
	local S = FreshBoot(opts)
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

-- Re-test 0.7 step 4 (S2 + S4 in one turn, then End Turn): the paused lapse
-- started at grace 5, but the Volunteer then left B's land during the
-- player's turn (50,33 -> 50,34 -> 50,35 -> 51,36), so the countdown ran
-- 5 -> 4 as designed (pause = on B's or your land only). S4 ends only the
-- declared friendship; B's open-borders deal from S0 stays.
local function S2S4(S)
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER", 999)
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 11), 4, S.c4, "CS_EXPEDITIONARY", 999)
	Arrive()
	Dev("scn_expire_cs")
	Dev("scn_lapse")
	H.ok(EFV_HasOpenBordersFrom(0, 1), "S4 leaves B's open borders alone")
	H.endTurn()
	local vol
	for _, r in ipairs(H.records()) do if r.forceType == "VOLUNTEER" then vol = r end end
	return vol
end

test("0.7.2 S4 (re-test step 4): S2 + S4 in one turn, End Turn: paused at grace 5, the Volunteer is held, next turn still 5", function()
	local S = Setup()
	local vol = S2S4(S)
	H.ok(CheckLine("EXPIRE", "PASS"))
	H.ok(CheckLine("LAPSE", "PASS"))
	H.eq(vol.graceTurnsLeft, 5); H.eq(vol.lapsePaused, 1)
	local u = Players[0]:GetUnits():FindID(vol.onMapUnitID)
	H.eq(u:GetMovesRemaining(), 0, "held for this turn")
	H.ok(H.hasLine("is held on"))
	H.endTurn()
	H.ok(CheckLine("LAPSE_PAUSE", "PASS"))
	H.eq(EFV_Records.Get(EFV_Records.Load(), vol.id).graceTurnsLeft, 5, "countdown did not move")
	H.clean()
end)

test("0.7.2 S4: the Volunteer moved off B's land before the turn start -> grace 5 -> 4 (correct), LAPSE_PAUSE says not verified", function()
	local S = Setup()
	local vol = S2S4(S)
	local u = Players[0]:GetUnits():FindID(vol.onMapUnitID)
	local off = nil
	local best = 99
	for i = 0, Map.GetPlotCount() - 1 do
		local p = Map.GetPlotByIndex(i)
		local d = H.dist(p, u)
		if d < best and p:GetOwner() < 0 and not p:IsWater() and p:GetUnitCount() == 0 then off, best = p, d end
	end
	H.notnil(off, "a neutral tile near B's land")
	H.moveUnit(u, off:GetX(), off:GetY())   -- the re-test: walked off during the player's turn
	H.endTurn()
	local r = EFV_Records.Get(EFV_Records.Load(), vol.id)
	H.eq(r.graceTurnsLeft, 4, "off valid land the countdown runs")
	H.isnil(r.lapsePaused)
	H.ok(H.hasLine("[Lapse] resumed id=" .. vol.id))
	H.ok(CheckLine("LAPSE_PAUSE", "CHECK"))
	H.ok(H.hasLine("not verified: Volunteer record " .. vol.id .. " left the valid land"))
	H.ok(H.hasLine("grace 5 -> 4 (correct off valid land)"))
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
	H.len(H.unitsOf(0, "UNIT_SPEARMAN"), 1)
	local u = H.unitsOf(0, "UNIT_SPEARMAN")[1]
	H.eq(u.vetName or "", "", "0.7 (item 9): no custom name, the unit panel and the tracker both say Spearman")
	H.ok(H.hasLine("the UNIT_SPEARMAN in mutiny (the camera selects it)"))
	local barb = H.unitsOf(63, "UNIT_WARRIOR")
	H.len(barb, 2)
	H.combat(u, barb[1], 30, 25)
	H.ok(CheckLine("T31_EVENT", "PASS"))
	H.endTurn({ heal = 10 })
	H.ok(CheckLine("T31", "PASS"))
	H.ok(H.hasLine("damage 45"))
	H.len(H.records(), 0, "record closed")
	H.clean()
end)

test("final S10 (0.7 item 10): the test units are removed at OnGameTurnEnded, never at your PlayerTurnStartComplete", function()
	Setup()
	Dev("scn_t31")
	local u = H.unitsOf(0, "UNIT_SPEARMAN")[1]
	H.combat(u, H.unitsOf(63, "UNIT_WARRIOR")[1], 30, 25)
	local removedAt = {}
	local hook = nil
	GameEvents.PlayerTurnStartComplete.Add(function(pid) hook = nil end)
	GameEvents.PlayerTurnStarted.Add(function(pid) hook = "PTS" .. pid end)
	local realRemove = FAKE.RemoveUnit
	FAKE.RemoveUnit = function(unit, why)
		removedAt[#removedAt + 1] = { owner = unit.owner, hook = hook, turn = FAKE.turn }
		return realRemove(unit, why)
	end
	local t0 = FAKE.turn
	H.endTurn()
	H.ok(CheckLine("T31", "PASS"))
	H.ok(H.unitAlive(u), "the Spearman is still there after the verdict (removing it at PTSC broke SelectedUnit.lua:195)")
	-- 0.7.2: the Barbarians went at the first AI PlayerTurnStarted after the
	-- fight (turn t0, before their own turn); nothing of yours was removed.
	H.len(H.unitsOf(63, "UNIT_WARRIOR"), 0, "Barbarians removed before their turn")
	H.len(removedAt, 2)
	for _, r in ipairs(removedAt) do
		H.eq(r.owner, 63, "only Barbarians"); H.eq(r.turn, t0, "in the fight's round, not at your next turn start")
	end
	H.ok(H.hasLine("removed when you end this turn"))
	H.endTurn()
	FAKE.RemoveUnit = realRemove
	H.ok(not H.unitAlive(u), "removed at the end of that turn")
	H.ok(H.hasLine("removed 1 of 1 test unit(s)"))
	H.isnil(H.prop("EFV_DEV_SCN").cleanup, "list cleared")
	H.clean()
end)

-- Re-test 0.7 step 6: after the player's attack (0 -> 27) both Barbarians
-- attacked in their turn (27 -> 57 -> 88) and the mutiny's 20 at the next
-- turn start killed the Spearman before the check ("the unit or its record
-- is gone"). 0.7.2 removes them before their turn.
test("0.7.2 S10: the Barbarians cannot attack after your fight; the Spearman lives to the T31 PASS", function()
	Setup()
	Dev("scn_t31")
	local u = H.unitsOf(0, "UNIT_SPEARMAN")[1]
	H.combat(u, H.unitsOf(63, "UNIT_WARRIOR")[1], 30, 27)
	H.ok(CheckLine("T31_EVENT", "PASS"))
	local barbAttacks = 0
	H.endTurn({ heal = 10, act = function(p)
		if p ~= 63 then return end
		for _, b in ipairs(H.unitsOf(63, "UNIT_WARRIOR")) do
			barbAttacks = barbAttacks + 1
			H.combat(b, u, 31, 5)
		end
	end })
	H.eq(barbAttacks, 0, "no Barbarian left to attack")
	H.ok(H.hasLine("Barbarian Warrior(s) removed after the fight"))
	H.ok(H.unitAlive(u))
	H.ok(CheckLine("T31", "PASS"))
	H.ok(H.hasLine("damage 47"), "27 + 20")
	H.ok(not H.hasLine("the unit or its record is gone"))
	H.clean()
end)

test("0.7.2 S10: no fight yet -> the Barbarians stay (you can still attack next turn)", function()
	Setup()
	Dev("scn_t31")
	H.endTurn()
	H.len(H.unitsOf(63, "UNIT_WARRIOR"), 2)
	H.ok(H.hasLine("no fight with the Spearman in mutiny yet"))
	H.ok(not H.hasLine("Barbarian Warrior(s) removed"))
	H.clean()
end)

test("final S10: damage applied after the combat event -> T31_EVENT CHECK", function()
	Setup()
	FAKE.combatDamageBeforeEvent = false
	Dev("scn_t31")
	local u = H.unitsOf(0, "UNIT_SPEARMAN")[1]
	H.combat(u, H.unitsOf(63, "UNIT_WARRIOR")[1], 30, 25)
	H.ok(CheckLine("T31_EVENT", "CHECK"))
end)

-- S14 (EFV_Dev 0.7.2-dev.1): the 0.7.1 report "the Volunteer Swordsman in
-- mutiny turned into a Warrior when a Barbarian Warrior came". Two copies of
-- the situation; the verdict checks the tile and every record after the deaths.
local function S14Copies()
	local st = H.prop("EFV_DEV_SCN")
	H.notnil(st.s14, "S14 state")
	local out = {}
	for _, cp in ipairs(st.s14.c) do
		out[#out + 1] = { cp = cp, u = FAKE.units[cp.uid], b = { FAKE.units[cp.b[1]], FAKE.units[cp.b[2]] } }
	end
	return out, st.s14
end

test("0.7.2 S14: two Volunteer Swordsmen in MUTINY at 80 next to Barbarians; killed in the round -> MUT_DEATH PASS each", function()
	local S = Setup()
	Dev("scn_mutdeath", { stamp = 14 })
	local copies, s14 = S14Copies()
	H.len(copies, 2, "two copies")
	for i, c in ipairs(copies) do
		H.eq(c.u.typeName, "UNIT_SWORDSMAN"); H.eq(c.u.owner, 0); H.eq(c.u.damage, 80)
		H.ok(Map.GetPlot(c.u.x, c.u.y):GetOwner() < 0, "neutral tile")
		local r = EFV_Records.Get(EFV_Records.Load(), c.cp.id)
		H.eq(r.forceType, "VOLUNTEER"); H.eq(r.state, "MUTINY"); H.eq(r.lapsed, 1); H.eq(r.recipientID, H.prop("EFV_DEV_SCN").friend, "F")
		H.eq(r.lastDamage, 80)
		H.eq(c.b[1].owner, 63); H.eq(c.b[2].owner, 63)
		H.eq(H.dist(c.b[1], c.u), 1); H.eq(H.dist(c.b[2], c.u), 1)
	end
	H.ok(H.dist(copies[1].u, copies[2].u) >= 4, "copies apart")
	H.notnil(FAKE.units[s14.w], "an enemy Warrior of C nearby")
	H.eq(FAKE.units[s14.w].owner, H.prop("EFV_DEV_SCN").enemy, "C")
	H.eq(copies[1].u.moves, 0, "copy 1 needs no orders"); H.ok(copies[2].u.moves > 0, "copy 2 can attack")
	H.ok(H.hasLine("attack a Barbarian with the selected one (copy 2)"))
	-- Copy 2: you attack a Barbarian and die (20 HP left).
	H.combat(copies[2].u, copies[2].b[1], 10, 20)
	FAKE.CombatKill(copies[2].u)
	-- Copy 1: a Barbarian attacks in its turn, kills it and advances.
	H.endTurn({ act = function(pid)
		if pid ~= 63 then return end
		local b, u = copies[1].b[1], copies[1].u
		H.combat(b, u, 20, 5)
		FAKE.CombatKill(u)
		H.moveUnit(b, copies[1].cp.x, copies[1].cp.y)
	end })
	H.ok(CheckLine("MUT_DEATH", "PASS"))
	H.len(H.lines("[EFV][CHECK] MUT_DEATH PASS"), 2, "one verdict per copy")
	H.ok(not H.hasLine("[EFV][CHECK] MUT_DEATH FAIL"))
	H.ok(H.hasLine("on the tile now: P63/"), "the Barbarian that advanced is named")
	for _, c in ipairs(copies) do H.isnil(EFV_Records.Get(EFV_Records.Load(), c.cp.id)) end
	H.ok(H.hasLine("test unit(s) are removed when you end this turn"))
	H.clean()
end)

test("0.7.2 S14: a unit of yours on the dead Swordsman's tile (the reported glitch) -> MUT_DEATH FAIL naming it", function()
	local S = Setup()
	Dev("scn_mutdeath")
	local copies = S14Copies()
	local u = copies[1].u
	FAKE.CombatKill(u)
	H.unit(0, "UNIT_WARRIOR", copies[1].cp.x, copies[1].cp.y)
	H.endTurn()
	H.ok(CheckLine("MUT_DEATH", "FAIL"))
	H.ok(H.hasLine("a unit of yours stands there: P0/"))
	H.ok(H.hasLine("UNIT_WARRIOR"))
end)

test("0.7.2 S14: not killed in the round -> the mutiny's 20 at the turn start ends it; still PASS", function()
	local S = Setup()
	Dev("scn_mutdeath")
	H.endTurn()
	H.len(H.lines("[EFV][CHECK] MUT_DEATH PASS"), 2)
	H.ok(H.hasLine("[Mutiny] death id="), "EFV's own mutiny death")
	H.clean()
end)

test("final S11: C has only its capital -> a new small city is founded for C, weakened, Tanks next to it", function()
	local S = Setup()
	Dev("scn_lapse")                     -- S4 left the friendship off: S11 renews it
	Dev("scn_entrust")
	H.ok(CheckLine("ENTRUST", "INFO"))
	H.ok(H.hasLine("new city founded for"))
	local s11 = H.prop("EFV_DEV_SCN").s11
	local city = CityManager.GetCityAt(s11.cx, s11.cy)
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
	local s11 = H.prop("EFV_DEV_SCN").s11
	H.eq(s11.cx, c3b.x); H.eq(s11.cy, c3b.y)
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
	for _, label in ipairs({ "S1 Arrive next turn", "S2 Expire CS unit (off its land)", "S3 Grace/mutiny step", "S4 Lapse on/off",
		"S5 Upgrade test", "S6 Veteran copies", "S7 Killed unit", "S8 Relink guard", "S9 Crowded arrival", "S10 Mutiny combat",
		"S11 Entrust city", "S12 Veteran return", "S13 Unit in B's land", "S14 Mutiny death", "S15 Receive forces", "Go to scenario", "Check now",
		"Shot 1 Send picker", "Shot 2 Arrival", "Shot 3 Tracker", "Shot 4 Entrust", "Shot 5 Mutiny" }) do
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

-- ---------------------------------------------------------------------------
-- 0.7 re-test scenarios (EFV/TESTING_RETEST_0.7.md; FIXPLAN_0.7 WP5):
-- S2 off the city-state's land, S9 ruling, S12 veteran return (route B, UI
-- checks), S13 unit in B's land, LAPSE_TEXT.
-- ---------------------------------------------------------------------------
local function IsNeutral(u) return Map.GetPlot(u:GetX(), u:GetY()):GetOwner() < 0 end

test("0.7 S2: the City-State unit is moved onto neutral land and comes home at once, without grace", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 4, S.c4, "CS_EXPEDITIONARY", 999)
	Arrive()
	local r = H.records()[1]
	Dev("scn_expire_cs")
	local u = Players[4]:GetUnits():FindID(r.onMapUnitID)
	H.ok(IsNeutral(u), "moved off the city-state's land")
	H.ok(H.dist(u, S.c4) <= 7)
	H.ok(H.hasLine("stands on neutral land"))
	H.clearNotifs()
	H.endTurn()
	H.ok(CheckLine("EXPIRE", "PASS"))
	H.ok(H.hasLine("going home without grace"))
	H.eq(H.records()[1].state, "RETURNING")
	H.len(H.notifs(0, EFV_Config.NOTIF.GRACE), 0, "no grace notification")
	H.clean()
end)

test("0.7 S9: one free ring-2 tile left -> placed there, PASS (ruling: crowded arrival accepted)", function()
	local S = Setup()
	Dev("scn_place")
	H.ok(H.hasLine("Warriors fill the free land tiles of rings 1-2"))
	H.ok(H.hasLine("expected ring"), "DryRun logged as info")
	local st = H.prop("EFV_DEV_SCN")
	local freed = nil
	for _, id in ipairs(st.s9.fill) do
		local w = FAKE.units[id]
		if freed == nil and w ~= nil and H.dist(w, S.c1) == 2 then freed = { x = w.x, y = w.y }; H.killUnit(w) end
	end
	H.notnil(freed, "a ring-2 filler removed")
	H.endTurn()
	H.ok(CheckLine("CROWDED", "PASS"))
	H.ok(H.hasLine("placed at ring 2 plot=" .. freed.x .. "," .. freed.y))
	H.ok(H.hasLine("the nearest ring with a free valid tile"))
	H.clean()
end)

test("0.7 S9: an inner valid tile skipped -> CHECK", function()
	local S = Setup()
	Dev("scn_place")
	local st = H.prop("EFV_DEV_SCN")
	-- After the arrival (turn start pipeline), before the check at the human's
	-- PlayerTurnStartComplete: a ring-1 tile becomes free.
	GameEvents.PlayerTurnStarted.Add(function(pid)
		if pid ~= 0 then return end
		for _, id in ipairs(st.s9.fill) do
			local w = FAKE.units[id]
			if w ~= nil and H.dist(w, S.c1) == 1 then H.killUnit(w); return end
		end
	end)
	H.endTurn()
	H.ok(CheckLine("CROWDED", "CHECK"))
	H.ok(H.hasLine("ring 1 still has a valid free tile"))
end)

-- Pumps UI contexts (FAKE_UI) and delivers their requests to gameplay like
-- EXECUTE_SCRIPT (the test_070_vet pattern).
local function Pump(envs, n)
	for _ = 1, n do
		for _, env in ipairs(envs) do FAKE_UI.Update(env, 0.3) end
		local reqs = FAKE_UI.requests
		FAKE_UI.requests = {}
		for _, r in ipairs(reqs) do
			FAKE_UI.AsGameplay(function() H.request(r.pid, r.params) end)
		end
	end
end

local function PanelUI()
	include("fake_ui")
	FAKE_UI.Enable()
	return FAKE_UI.LoadContext("EFV_Dev/UI/EFV_Dev_Panel.lua")
end

test("0.7 S12: veteran return, route B end to end: level 3, two promotions, 50/90 XP, 30 damage (VET_RESTORE, VET_RESTORE_LEVEL)", function()
	local S = Setup({ routeB = true })
	Dev("scn_vetret", { stamp = 12 })
	H.ok(CheckLine("VET_RESTORE", "INFO"))
	local r = H.records()[1]
	H.eq(r.state, "RETURNING"); H.eq(r.forceType, "VOLUNTEER"); H.eq(r.recipientID, 1); H.eq(r.arrivalTurn, FAKE.turn + 1)
	H.eq(r.level, 3); H.eq(r.experience, 50); H.eq(r.xpNext, 90); H.eq(r.damage, 30); H.eq(r.veteranName, "VEF-VET")
	H.len(r.promotions, 2)
	for _, name in ipairs(r.promotions) do
		local row = GameInfo.UnitPromotions[name]
		H.eq(row.PromotionClass, GameInfo.Units["UNIT_WARRIOR"].PromotionClass); H.eq(row.Level, 1)
	end
	H.endTurn()
	H.len(H.records(), 0, "arrived")
	H.ok(H.hasLine("is home (unit"), "the job is named at the turn start")
	local st = H.prop("EFV_DEV_SCN")
	H.notnil(st.s12.uid)
	local u = FAKE.units[st.s12.uid]
	H.eq(u.vetName, "VEF-VET")
	H.ok(H.dist(u, S.c0) <= 5, "next to your capital")
	H.ok(not H.hasLine("[EFV][CHECK] VET_RESTORE PASS"), "no verdict while the job is open")
	include("fake_ui")
	FAKE_UI.Enable()
	local vet = FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")
	local panel = FAKE_UI.LoadContext("EFV_Dev/UI/EFV_Dev_Panel.lua")
	Pump({ vet, panel }, 12)
	H.eq(u:GetExperience():GetLevel(), 3)
	H.ok(CheckLine("VET_RESTORE_LEVEL", "PASS"), "UI level check")
	H.ok(H.hasLine("level 3 (expected 3), XP 50/90, damage 30, in the arrival turn"),
		"0.7.2 (re-test step 5): one End Turn is enough, the level is back in the arrival turn")
	H.eq(u:GetMovesRemaining(), 0, "0.7.2: exhausted once the level is back")
	H.ok(H.hasLine("unit panel name"), "the UI-side name is logged (item 9 evidence)")
	H.ok(CheckLine("VET_RESTORE", "PASS"), "gameplay verdict after the panel's Check now")
	H.ok(H.hasLine("XP 50/90 (expected 50/90), promotions 2/2, damage 30"))
	H.len(H.lines("[EFV][CHECK] VET_RESTORE_LEVEL"), 1, "once")
	H.clean()
end)

test("0.7 S12: route B off -> the clamp path is reported as CHECK", function()
	Setup()
	Dev("scn_vetret")
	H.endTurn()
	H.ok(CheckLine("VET_RESTORE", "CHECK"), "no job: verdict at once from the named unit")
	H.ok(H.hasLine("expected 50/90"))
end)

test("0.7 S13: a Spearman in B's land: B's rows open, others WRONG_TERRITORY; sent to B -> FROM_LAND PASS", function()
	local S = Setup()
	Dev("scn_inland", { stamp = 13 })
	local sp = H.unitsOf(0, "UNIT_SPEARMAN")
	H.len(sp, 1)
	local u = sp[1]
	H.eq(u.vetName or "", "", "no custom name")
	H.eq(Map.GetPlot(u.x, u.y):GetOwner(), 1, "on B's land")
	H.ok(H.dist(u, S.c1) <= 3)
	H.eq(u:GetMovesRemaining(), u:GetMaxMoves(), "full moves")
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.o, 0); H.eq(st.focus.u, u.id, "the camera selects it"); H.eq(st.focus.stamp, 13)
	H.ok(CheckLine("FROM_LAND_RULES", "PASS"))
	H.ok(H.hasLine("other row(s) WRONG_TERRITORY"))
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.records()[1]
	H.notnil(r, "the send from B's land is accepted")
	H.eq(r.recipientID, 1)
	H.endTurn()
	H.ok(CheckLine("FROM_LAND", "PASS"))
	H.clean()
end)

test("0.7 S13: not sent -> FROM_LAND CHECK at the next turn start", function()
	Setup()
	Dev("scn_inland")
	H.endTurn()
	H.ok(CheckLine("FROM_LAND", "CHECK"))
end)

test("0.7 LAPSE_TEXT: the panel reads the paused lapse text from the tracker's state function", function()
	local S = Setup()
	H.send(0, H.unit(0, "UNIT_SWORDSMAN", 11, 10), 1, S.c1, "VOLUNTEER", 999)
	Arrive()
	Dev("scn_lapse")
	H.endTurn()
	H.ok(CheckLine("LAPSE", "PASS"))
	local panel = PanelUI()
	Pump({ panel }, 3)
	H.ok(CheckLine("LAPSE_TEXT", "PASS"))
	H.ok(H.hasLine("'Lapse: Grace 5 (paused)'"))
	Pump({ panel }, 3)
	H.len(H.lines("[EFV][CHECK] LAPSE_TEXT"), 1, "once per record")
end)

-- ---------------------------------------------------------------------------
-- Workshop Shot buttons (WP6; workshop/SCREENSHOTS.md Part B). Gameplay:
-- each Shot runs from a fresh game (S0 inside), removes the previous shot's
-- records and units, and writes st.focus for the panel.
-- ---------------------------------------------------------------------------
local function Recs(pred)
	local out = {}
	for _, r in ipairs(H.records()) do if pred == nil or pred(r) then out[#out + 1] = r end end
	return out
end

test("shot1: from a fresh game (S0 inside): Legion 'Legio VEF' next to your capital, Volunteer picker: B open, F and D greyed", function()
	local S = FreshBoot()
	FAKE.NewPlayer(7, { gold = 0 })
	local c7 = H.city(7, 60, 10, { capital = true, name = "LOC_CITY_D" })
	Dev("shot1", { stamp = 21 })
	H.ok(CheckLine("SETUP", "PASS"), "S0 ran inside the Shot")
	H.ok(CheckLine("SHOT1", "PASS"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 0, "S0's three Swordsmen were removed")
	local legions = H.unitsOf(0, "UNIT_ROMAN_LEGION")
	H.len(legions, 1, "only Legio VEF")
	local u = legions[1]
	H.eq(u.vetName, "Legio VEF")
	H.ok(H.dist(u, S.c0) <= 2); H.eq(Map.GetPlot(u.x, u.y):GetOwner(), 0)
	H.eq(u:GetMovesRemaining(), u:GetMaxMoves())
	H.ok(#FAKE.CitiesOf(2) >= 2, "F got a second city (B already has two)")
	H.len(FAKE.CitiesOf(1), 2)
	H.ok(PlayersVisibility[0]:IsRevealed(c7.x, c7.y), "D's capital revealed")
	H.ok(Players[0]:GetDiplomacy():HasMet(7), "D met")
	H.ok(Players[7]:GetDiplomacy():IsAtWarWith(3), "D at war with C")
	H.notnil(EFV_VolunteerBasis(0, 1), "B is the Volunteer partner")
	H.isnil(EFV_VolunteerBasis(0, 2)); H.isnil(EFV_VolunteerBasis(0, 7))
	local rows = EFV_DestinationRows(0, u, "VOLUNTEER", EFV_Records.Load())
	local by = {}
	for _, r in ipairs(rows) do by[r.recipientID] = by[r.recipientID] or {}; table.insert(by[r.recipientID], r) end
	H.len(by[1], 2, "B's two cities")
	for _, r in ipairs(by[1]) do H.ok(r.ok, "B's rows open") end
	for _, pid in ipairs({ 2, 7 }) do
		H.notnil(by[pid], "a row for " .. pid)
		for _, r in ipairs(by[pid]) do
			H.ok(not r.ok); H.deq(r.reasons, { "VOL_NEEDS_ACCESS" }, "greyed only for the missing open borders")
		end
	end
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.open, "PICKER"); H.eq(st.focus.ft, "VOLUNTEER"); H.eq(st.focus.u, u.id); H.eq(st.focus.o, 0)
	H.eq(st.focus.stamp, 21); H.eq(st.focus.zoom, 0.5)
	H.ok(H.gold(0) >= 2000)
	-- again: the old Legio VEF is replaced, no second city founded twice
	Dev("shot1", { stamp = 22 })
	H.len(H.unitsOf(0, "UNIT_ROMAN_LEGION"), 1)
	H.ok(not H.unitAlive(u), "previous shot's unit removed")
	H.len(H.lines("[EFV][CHECK] SETUP"), 1, "S0 only once")
	H.clean()
end)

test("shot2: Expeditionary (B's colours) and Volunteers (yours) next to B's capital, DEPLOYED, two Unit Arrived", function()
	local S = FreshBoot()
	Dev("shot2", { stamp = 31 })
	H.ok(CheckLine("SHOT2", "PASS"))
	local exp = Recs(function(r) return r.forceType == "EXPEDITIONARY" end)
	local vol = Recs(function(r) return r.forceType == "VOLUNTEER" end)
	H.len(exp, 1); H.len(vol, 1)
	H.eq(exp[1].state, "DEPLOYED"); H.eq(vol[1].state, "DEPLOYED")
	H.eq(exp[1].onMapPlayerID, 1, "B owns the Expeditionary unit"); H.eq(vol[1].onMapPlayerID, 0, "you own the Volunteers")
	H.eq(exp[1].deployedTurn, FAKE.turn)
	local e = FAKE.units[exp[1].onMapUnitID]
	local v = FAKE.units[vol[1].onMapUnitID]
	H.eq(Map.GetPlot(e.x, e.y):GetOwner(), 1); H.eq(Map.GetPlot(v.x, v.y):GetOwner(), 1)
	H.eq(exp[1].unitType, "UNIT_ROMAN_LEGION"); H.eq(vol[1].unitType, "UNIT_ROMAN_LEGION")
	H.ok(H.dist(e, S.c1) <= 2 and H.dist(e, v) <= 3)
	H.len(H.notifs(0, EFV_Config.NOTIF.ARRIVED), 2)
	local st = H.prop("EFV_DEV_SCN")
	H.isnil(st.focus.open); H.eq(st.focus.zoom, 0.25); H.eq(st.focus.stamp, 31)
	Dev("shot2", { stamp = 32 })
	H.len(H.records(), 2, "the previous shot's records were removed first")
	H.ok(not H.unitAlive(e) and not H.unitAlive(v))
	H.clean()
end)

test("shot3: six records (Grace, Deployed x3, Returning, Outbound), one Grace notification, focus TRACKER", function()
	FreshBoot()
	Dev("shot2")
	Dev("shot3", { stamp = 41 })
	H.ok(CheckLine("SHOT3", "PASS"))
	local rs = H.records()
	H.len(rs, 6, "shot 2's records removed")
	local by = {}
	for _, r in ipairs(rs) do by[r.state] = (by[r.state] or 0) + 1 end
	H.eq(by.GRACE, 1); H.eq(by.DEPLOYED, 3); H.eq(by.RETURNING, 1); H.eq(by.OUTBOUND, 1)
	local grace = Recs(function(r) return r.state == "GRACE" end)[1]
	H.eq(grace.graceTurnsLeft, 3); H.eq(grace.recipientID, 1); H.eq(grace.unitType, "UNIT_ROMAN_LEGION")
	local gu = FAKE.units[grace.onMapUnitID]
	H.ok(IsNeutral(gu), "grace unit on neutral land")
	local ret = Recs(function(r) return r.state == "RETURNING" end)[1]
	H.eq(ret.forceType, "CS_EXPEDITIONARY"); H.eq(ret.arrivalTurn, FAKE.turn + 2); H.isnil(ret.onMapUnitID)
	local out = Recs(function(r) return r.state == "OUTBOUND" end)[1]
	H.eq(out.arrivalTurn, FAKE.turn + 3); H.eq(out.unitType, "UNIT_HORSEMAN")
	local recv = Recs(function(r) return r.senderID == 1 and r.recipientID == 0 end)
	H.len(recv, 1, "one received from B")
	H.eq(recv[1].unitType, "UNIT_SWORDSMAN", "B's own unit, not a Legion")
	H.len(H.notifs(0, EFV_Config.NOTIF.GRACE), 1)
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.open, "TRACKER"); H.eq(st.focus.x, gu.x); H.eq(st.focus.y, gu.y)
	H.clean()
end)

test("shot4: C's city weakened with 3 Tanks next to it, focus CAPTURE with the target city; previous shot cleared", function()
	FreshBoot()
	Dev("shot3")
	Dev("shot4", { stamp = 51 })
	H.ok(CheckLine("SHOT4", "PASS"))
	H.len(H.records(), 0, "shot 3's records removed")
	H.len(H.unitsOf(0, "UNIT_HORSEMAN"), 0); H.len(H.unitsOf(2, "UNIT_ARCHER"), 0)
	local tanks = H.unitsOf(0, "UNIT_TANK")
	H.len(tanks, 3)
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.open, "CAPTURE"); H.eq(st.focus.u, tanks[1].id)
	local city = CityManager.GetCityAt(st.focus.tx, st.focus.ty)
	H.notnil(city); H.eq(city:GetOwner(), 3)
	H.eq(CityManager.GetDistrictAt(city.x, city.y):GetDamage(DefenseTypes.DISTRICT_GARRISON), 199, "1 HP")
	Dev("shot4", { stamp = 52 })
	H.len(H.unitsOf(0, "UNIT_TANK"), 3, "old Tanks removed, three new ones")
	H.clean()
end)

test("shot5: B's Legion of yours in MUTINY with 40 damage on neutral land, Mutiny notification, close zoom", function()
	FreshBoot()
	Dev("shot4")
	Dev("shot5", { stamp = 61 })
	H.ok(CheckLine("SHOT5", "PASS"))
	H.len(H.unitsOf(0, "UNIT_TANK"), 0, "shot 4's Tanks removed")
	local rs = H.records()
	H.len(rs, 1)
	local r = rs[1]
	H.eq(r.state, "MUTINY"); H.eq(r.lastDamage, 40); H.eq(r.onMapPlayerID, 1); H.eq(r.unitType, "UNIT_ROMAN_LEGION")
	local u = FAKE.units[r.onMapUnitID]
	H.eq(u.damage, 40); H.ok(IsNeutral(u))
	H.len(H.notifs(0, EFV_Config.NOTIF.MUTINY), 1)
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.zoom, 0.25); H.isnil(st.focus.open)
	-- the next turn start keeps the mutiny going (+20)
	H.endTurn()
	H.eq(H.records()[1].state, "MUTINY")
	H.eq(u.damage, 60)
	H.clean()
end)

test("S15 receive: B sends you a deployed Expeditionary (yours) and Volunteers (B's) next to your capital, focus TRACKER", function()
	local S = FreshBoot()
	Dev("shot5")
	Dev("scn_receive", { stamp = 71 })
	H.ok(CheckLine("RECEIVE", "PASS"))
	local rs = H.records()
	H.len(rs, 2, "shot 5's record removed")
	local exp = Recs(function(r) return r.forceType == "EXPEDITIONARY" end)[1]
	local vol = Recs(function(r) return r.forceType == "VOLUNTEER" end)[1]
	H.notnil(exp); H.notnil(vol)
	for _, r in ipairs({ exp, vol }) do
		H.eq(r.state, "DEPLOYED"); H.eq(r.senderID, 1); H.eq(r.recipientID, 0)
		H.eq(r.deployedTurn, FAKE.turn); H.eq(r.destX, S.c0.x); H.eq(r.destY, S.c0.y)
		H.eq(Map.GetPlot(r.lastX, r.lastY):GetOwner(), 0, "in your land")
	end
	H.eq(exp.onMapPlayerID, 0, "you control the Expeditionary unit"); H.eq(exp.durationTurns, EFV_Config.EXPEDITIONARY_DURATION)
	H.eq(vol.onMapPlayerID, 1, "B controls its Volunteers")
	H.notnil(EFV_VolunteerBasis(1, 0), "B has a Volunteer basis toward you")
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.open, "TRACKER"); H.eq(st.focus.x, S.c0.x); H.eq(st.focus.stamp, 71)
	Dev("scn_receive")
	H.len(H.records(), 2, "a second press replaces the scene")
	H.clean()
end)

test("shot panel: deselect, VEF notifications dismissed, stamped request; picker opened, panel and DEV button hidden, zoom set", function()
	local S = BootUI()
	Events.LoadGameViewStateDone()
	local sel = H.unit(0, "UNIT_SWORDSMAN", 11, 10)
	FAKE_UI.selectedUnit = sel
	NotificationManager.SendNotification(0, GameInfo.Types[EFV_Config.NOTIF.GRACE].Hash, {})
	NotificationManager.SendNotification(0, GameInfo.Types[EFV_Config.NOTIF.ARRIVED].Hash, {})
	FAKE_UI.Key(Keys.D, { ctrl = true, shift = true })
	FAKE_UI.FindButton("Shot 1 Send picker"):Click()
	H.isnil(FAKE_UI.selectedUnit, "UI.DeselectAllUnits before the request")
	H.len(NotificationManager.GetList(0), 0, "VEF notifications dismissed")
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(p.cmd, "shot1"); H.ok(p.stamp > 0)
	local opened, zoom = nil, nil
	LuaEvents.EFV_OpenDestinationPicker.Add(function(pid, uid, ft) opened = { pid, uid, ft } end)
	UI.SetMapZoom = function(z) zoom = z end
	UI.GetMapZoom = function() return 0.7 end
	Game:SetProperty("EFV_DEV_SCN", { me = 0, ally = 1, friend = 2, enemy = 3, cs = 4,
		focus = { x = S.c0.x, y = S.c0.y, o = 0, u = sel.id, stamp = p.stamp, open = "PICKER", ft = "EXPEDITIONARY", zoom = 0.5 } })
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.eq(zoom, 0.5, "UI.SetMapZoom")
	H.ok(Controls.Main:IsHidden(), "the panel closes itself")
	local launch = nil
	for _, b in ipairs(FAKE_UI.builtInstances or {}) do if b.name == "DevLaunchBarItem" then launch = b.inst end end
	H.notnil(launch)
	H.ok(launch.LaunchItemButton:IsHidden(), "DEV button hidden")
	H.eq(FAKE_UI.selectedUnit, sel, "LookAt selected the unit")
	H.isnil(opened, "the picker waits one tick")
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.deq(opened, { 0, sel.id, "EXPEDITIONARY" })
	H.ok(CheckLine("SHOT1", "INFO"))
	FAKE_UI.Key(Keys.D, { ctrl = true, shift = true })
	H.ok(not launch.LaunchItemButton:IsHidden(), "Ctrl+Shift+D shows the DEV button again")
end)

test("shot panel: Shot 3 sends the tracker hook; Shot 4 attacks, waits for the capture screen, expands Entrust", function()
	local S = BootUI()
	local tank = H.unit(0, "UNIT_TANK", 12, 10)
	local tracker, expand, attack = 0, 0, nil
	LuaEvents.EFV_TrackerOpen.Add(function() tracker = tracker + 1 end)
	LuaEvents.EFV_EntrustExpand.Add(function() expand = expand + 1 end)
	FAKE_UI.FindButton("Shot 3 Tracker"):Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	Game:SetProperty("EFV_DEV_SCN", { me = 0, ally = 1, focus = { x = 30, y = 5, o = -1, u = -1, stamp = p.stamp, open = "TRACKER" } })
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.eq(tracker, 1, "LuaEvents.EFV_TrackerOpen")
	-- Shot 4
	UnitOperationTypes.MOVE_TO, UnitOperationTypes.PARAM_MODIFIERS = "MOVE_TO", "PARAM_MODIFIERS"
	UnitOperationMoveModifiers = { ATTACK = 1, MOVE_IGNORE_UNEXPLORED_DESTINATION = 2 }
	UnitManager.CanStartOperation = function(u, op, _, t) return u == tank and op == "MOVE_TO" end
	UnitManager.RequestOperation = function(u, op, t)
		attack = { uid = u.id, op = op, x = t.PARAM_X, y = t.PARAM_Y, mods = t.PARAM_MODIFIERS }
	end
	local raze = ContextPtr:LookUpControl("/InGame/RazeCity")
	raze:SetHide(true)
	FAKE_UI.FindButton("Shot 4 Entrust"):Click()
	p = FAKE_UI.requests[#FAKE_UI.requests].params
	Game:SetProperty("EFV_DEV_SCN", { me = 0, ally = 1, focus = { x = S.c3.x, y = S.c3.y, o = 0, u = tank.id, stamp = p.stamp,
		open = "CAPTURE", tx = S.c3.x, ty = S.c3.y } })
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.notnil(attack, "attack requested")
	H.eq(attack.uid, tank.id); H.eq(attack.op, "MOVE_TO"); H.eq(attack.x, S.c3.x); H.eq(attack.y, S.c3.y); H.eq(attack.mods, 3)
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.eq(expand, 0, "waits while the capture screen is hidden")
	raze:SetHide(false)
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.eq(expand, 1, "LuaEvents.EFV_EntrustExpand once the capture screen shows")
	FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5)
	H.eq(expand, 1)
end)

test("shot panel: no zoom call and no attack call in the engine -> logged, the shot still completes", function()
	BootUI()
	UI.SetMapZoom = nil
	local tank = H.unit(0, "UNIT_TANK", 12, 10)
	local expand = 0
	LuaEvents.EFV_EntrustExpand.Add(function() expand = expand + 1 end)
	FAKE_UI.FindButton("Shot 4 Entrust"):Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	Game:SetProperty("EFV_DEV_SCN", { me = 0, ally = 1, focus = { x = 12, y = 10, o = 0, u = tank.id, stamp = p.stamp,
		open = "CAPTURE", tx = 22, ty = 10, zoom = 0.5 } })
	ContextPtr:LookUpControl("/InGame/RazeCity"):SetHide(true)
	for _ = 1, 40 do FAKE_UI.Update({ ContextPtr = ContextPtr }, 0.5) end
	H.ok(H.hasLine("(use the mouse wheel)"), "zoom fallback logged")
	H.ok(H.hasLine("click the city with the selected Tank"), "attack fallback")
	H.ok(H.hasLine("click Entrust... once"), "capture screen timeout")
	H.eq(expand, 1, "the expand hook is still sent once (a no-op without a capture popup)")
end)

-- ---------------------------------------------------------------------------
-- Eligibility tests T1 / T2 (EFV_Dev 1.0.1.3, VEF 1.0.1 common-war fix):
-- a fresh game with up to 7 AI majors; roles by ascending ID; one
-- ELIG_Tn line per civ (gameplay rules) and ELIG_Tn_UI lines from the panel.
-- ---------------------------------------------------------------------------
local ELIG_EXTRA = { { 7, 60, 10 }, { 8, 50, 45 }, { 9, 25, 45 }, { 10, 75, 15 } }

-- FreshBoot (AI majors 1, 2, 3; city-states 4, 5, 6) plus `extra` more
-- majors 7.. with a capital each.
local function EligBoot(extra)
	local S = FreshBoot()
	for i = 1, extra or 0 do
		local e = ELIG_EXTRA[i]
		FAKE.NewPlayer(e[1], { gold = 1000 })
		S["c" .. e[1]] = H.city(e[1], e[2], e[3], { capital = true, name = "LOC_CITY_X" .. e[1] })
	end
	return S
end

local function EligLines(id, verdict)
	return H.lines("[EFV][CHECK] " .. id .. " " .. verdict .. " ")
end

local function RoleLine(id, role, pid)
	for _, l in ipairs(H.lines("[EFV][CHECK] " .. id .. " ")) do
		if string.find(l, " " .. role .. "=P" .. pid .. " ", 1, true) then return l end
	end
	return nil
end

local function Has(line, text) return line ~= nil and string.find(line, text, 1, true) ~= nil end

test("1.0.1.3 T2 shared enemy: 7 AI civs by ID; FW / FOW open, FN / FON / AN no common enemy, NW absent (gameplay rules)", function()
	local S = EligBoot(4)
	Dev("elig_t2", { stamp = 31 })
	local d0 = Players[0]:GetDiplomacy()
	-- roles: E=1, FW=2, FOW=3, FN=7, FON=8, NW=9, AN=10
	H.ok(d0:IsAtWarWith(1), "you are at war with E")
	for _, pid in ipairs({ 2, 3, 9 }) do H.ok(Players[pid]:GetDiplomacy():IsAtWarWith(1), pid .. " at war with E") end
	for _, pid in ipairs({ 7, 8, 10 }) do
		for _, e in ipairs({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) do
			H.ok(not Players[pid]:GetDiplomacy():IsAtWarWith(e), pid .. " must not be at war with " .. e)
		end
	end
	for _, pid in ipairs({ 2, 3, 7, 8 }) do H.ok(d0:HasDeclaredFriendship(pid), "friend " .. pid) end
	H.ok(not d0:HasDeclaredFriendship(9), "NW met only")
	H.ok(d0:HasAllied(10) and Players[10]:GetDiplomacy():HasAllied(0), "AN allied both ways")
	H.ok(EFV_HasOpenBordersFrom(0, 3) and EFV_HasOpenBordersFrom(0, 8), "FOW and FON grant you open borders")
	H.ok(not EFV_HasOpenBordersFrom(0, 2) and not EFV_HasOpenBordersFrom(0, 7), "FW and FN do not")
	-- everybody met everybody (majors and city-states)
	local ids = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
	for _, a in ipairs(ids) do
		for _, b in ipairs(ids) do H.ok(Players[a]:GetDiplomacy():HasMet(b), a .. " met " .. b) end
	end
	-- two Swordsmen with full moves next to your capital
	local swords = H.unitsOf(0, "UNIT_SWORDSMAN")
	H.len(swords, 2)
	for _, u in ipairs(swords) do
		H.eq(u:GetMovesRemaining(), u:GetMaxMoves()); H.ok(H.dist(u, S.c0) <= 4)
	end
	-- one line per civ, all PASS, then the summary
	H.len(EligLines("ELIG_T2", "PASS"), 8, "7 civs + summary")
	H.len(EligLines("ELIG_T2", "FAIL"), 0); H.len(EligLines("ELIG_T2", "CHECK"), 0)
	H.ok(H.hasLine("summary (gameplay rules): T2 Shared enemy, 7 civ(s): 7 PASS, 0 FAIL, 0 CHECK"))
	local fn = RoleLine("ELIG_T2", "FN", 7)
	H.ok(Has(fn, "Expeditionary expected GREY:NO_COMMON_WAR actual GREY:NO_COMMON_WAR"), fn)
	H.ok(Has(fn, "Volunteers expected GREY:NO_COMMON_WAR+VOL_NEEDS_ACCESS actual GREY:NO_COMMON_WAR+VOL_NEEDS_ACCESS"), fn)
	H.ok(Has(fn, "real wars: none"), "the Free Cities and barbarian wars are not listed")
	H.ok(Has(RoleLine("ELIG_T2", "NW", 9), "Expeditionary expected ABSENT actual ABSENT"))
	H.ok(Has(RoleLine("ELIG_T2", "FOW", 3), "Volunteers expected ALLOWED actual ALLOWED"))
	H.ok(Has(RoleLine("ELIG_T2", "AN", 10), "Expeditionary expected GREY:NO_COMMON_WAR actual GREY:NO_COMMON_WAR"))
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.elig.test, "T2"); H.eq(st.elig.stamp, 31); H.len(st.elig.civs, 7); H.eq(st.elig.pass, 7)
	H.eq(st.focus.stamp, 31); H.eq(st.focus.u, st.elig.u1)
	H.ok(H.gold(0) >= 2000)
	H.ok(not H.hasLine(": ERROR"))
	-- pressed again: the Swordsmen are replaced, the verdicts stay
	Dev("elig_t2", { stamp = 32 })
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 2)
	H.len(EligLines("ELIG_T2", "PASS"), 16)
	H.clean()
end)

test("1.0.1.3 T1 Volunteer partners: A and FO allowed, F greyed for open borders, N absent; extra civs met only", function()
	EligBoot(4)
	Dev("elig_t1", { stamp = 41 })
	-- roles: E=1, A=2, F=3, FO=7, N=8; 9 and 10 OTHER
	H.len(EligLines("ELIG_T1", "PASS"), 8, "7 civs + summary")
	H.len(EligLines("ELIG_T1", "FAIL"), 0); H.len(EligLines("ELIG_T1", "CHECK"), 0)
	for _, pid in ipairs({ 2, 3, 7, 8 }) do H.ok(Players[pid]:GetDiplomacy():IsAtWarWith(1), pid .. " at war with E") end
	H.ok(Players[0]:GetDiplomacy():HasAllied(2))
	local f = RoleLine("ELIG_T1", "F", 3)
	H.ok(Has(f, "Expeditionary expected ALLOWED actual ALLOWED | Volunteers expected GREY:VOL_NEEDS_ACCESS actual GREY:VOL_NEEDS_ACCESS"), f)
	H.ok(Has(RoleLine("ELIG_T1", "A", 2), "Volunteers expected ALLOWED actual ALLOWED"))
	H.ok(Has(RoleLine("ELIG_T1", "N", 8), "Volunteers expected ABSENT actual ABSENT"))
	H.notnil(RoleLine("ELIG_T1", "OTHER", 9)); H.notnil(RoleLine("ELIG_T1", "OTHER", 10))
	H.ok(H.hasLine("roles E=P1 "), "role map in the summary")
	H.clean()
end)

test("1.0.1.3 T2 with 3 AI civs: FN, FON, NW, AN skipped and named; summary CHECK", function()
	EligBoot(0)
	Dev("elig_t2", { stamp = 51 })
	H.len(EligLines("ELIG_T2", "PASS"), 3, "E, FW, FOW")
	H.ok(H.hasLine("roles FN, FON, NW, AN skipped"))
	H.len(EligLines("ELIG_T2", "CHECK"), 1, "the summary")
	H.eq(H.prop("EFV_DEV_SCN").elig.skipped, "FN,FON,NW,AN")
	H.clean()
end)

test("1.0.1.3 T2: the engine pulls the ally into your war -> AN is CHECK with an engine-effect note, not FAIL", function()
	EligBoot(4)
	-- engine model for this test: an alliance joins the ally to its partner's wars
	local d0 = Players[0]:GetDiplomacy()
	local setAllied = d0.SetHasAllied
	d0.SetHasAllied = function(self, b, v)
		setAllied(self, b, v)
		if v then
			for _, e in ipairs({ 1, 2, 3, 7, 8, 9 }) do
				if d0:IsAtWarWith(e) then FAKE.SetWar(b, e, true) end
			end
		end
	end
	Dev("elig_t2", { stamp = 61 })
	local an = RoleLine("ELIG_T2", "AN", 10)
	H.ok(Has(an, "[EFV][CHECK] ELIG_T2 CHECK"), an)
	H.ok(Has(an, "ENGINE EFFECT, not a VEF failure"), an)
	H.len(EligLines("ELIG_T2", "FAIL"), 0)
	H.ok(H.hasLine("7 civ(s): 6 PASS, 0 FAIL, 1 CHECK"))
	H.clean()
end)

test("1.0.1.3 T1: no capital yet -> CHECK with what to do, nothing set up", function()
	H.world({ turn = 1 })
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.markBody()
	Dev("elig_t1", { stamp = 71 })
	H.ok(H.hasLine("[EFV][CHECK] ELIG_T1 CHECK"))
	H.ok(H.hasLine("found your capital"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 0)
	H.notnil(H.prop("EFV_DEV_SCN").elig.err)
end)

test("1.0.1.3 T2 panel: button sends the stamped request; UI rules give the same verdicts; role map and status shown", function()
	EligBoot(4)
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	H.notnil(FAKE_UI.FindButton("T1 Volunteer partners"), "T1 button")
	local b = FAKE_UI.FindButton("T2 Shared enemy")
	H.notnil(b, "T2 button")
	b:Click()
	Pump({ panel }, 8)
	H.ok(CheckLine("ELIG_T2", "PASS"), "gameplay lines")
	H.len(EligLines("ELIG_T2_UI", "PASS"), 8, "UI rules: 7 civs + summary")
	H.len(EligLines("ELIG_T2_UI", "FAIL"), 0); H.len(EligLines("ELIG_T2_UI", "CHECK"), 0)
	H.ok(Has(RoleLine("ELIG_T2_UI", "FOW", 3), "UI basis FRIEND, Volunteer basis FRIEND_OB"), "FOW seen by the UI adapters")
	H.ok(Has(RoleLine("ELIG_T2_UI", "AN", 10), "UI basis ALLIANCE"), "AN seen by the UI adapters")
	local info = panel.Controls.InfoLabel:GetText()
	H.ok(string.find(info, "T2: E=", 1, true) == 1, "role map on the first line: " .. info)
	H.ok(Has(info, "FW=") and Has(info, "AN="), info)
	local rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "T2: gameplay 7/7 PASS, UI 7/7 PASS", 1, true) == 1, "status: " .. rec)
	H.eq(FAKE_UI.selectedUnit and FAKE_UI.selectedUnit.id, H.prop("EFV_DEV_SCN").elig.u1, "the first Swordsman is selected")
end)
