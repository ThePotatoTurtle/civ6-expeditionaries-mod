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
	for _, pid in ipairs({ 0, 1, 2 }) do H.ok(Players[pid]:GetDiplomacy():IsAtWarWith(3), pid .. " at war with C") end
	H.ok(not Players[4]:GetDiplomacy():IsAtWarWith(3), "the city-state stays at peace (VEF 1.0.2: no shared enemy needed)")
	H.ok(H.hasLine("city-state at war with C=false (not needed since VEF 1.0.2)"))
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

-- ---------------------------------------------------------------------------
-- S16 Break transit (EFV_Dev 1.0.2.2; VEF transit cancel, 2026-09-30)
-- ---------------------------------------------------------------------------
test("1.0.2.2 S16: City-State destination handed to C -> CANCEL_PREP INFO, next turn CANCEL PASS ring 0", function()
	local S = Setup()
	local swords = H.unitsOf(0, "UNIT_SWORDSMAN")
	local u = swords[3]
	local x, y = u.x, u.y
	H.send(0, u, 4, S.c4, "CS_EXPEDITIONARY", 999)
	H.len(H.records(), 1)
	Dev("scn_cancel", { stamp = 16 })
	H.ok(CheckLine("CANCEL_PREP", "INFO"))
	H.ok(H.hasLine("CS_TAKEN origin " .. x .. "," .. y))
	H.eq(CityManager.GetCityAt(S.c4.x, S.c4.y):GetOwner(), 3, "the city-state's city went to C")
	H.eq(H.prop("EFV_DEV_SCN").focus.stamp, 16)
	H.endTurn()
	H.ok(CheckLine("CANCEL", "PASS"))
	H.ok(H.hasLine("ring 0 (expected ring 0) moves=0"))
	H.len(H.records(), 0)
	H.clean()
end)

test("1.0.2.2 S16: major destination -> friendship ended, start tile blocked, CANCEL PASS ring 1", function()
	local S = Setup()
	local u = H.unitsOf(0, "UNIT_SWORDSMAN")[1]
	local x, y = u.x, u.y
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	Dev("scn_cancel")
	H.ok(CheckLine("CANCEL_PREP", "INFO"))
	H.ok(not CheckLine("CANCEL_PREP", "CHECK"), "friendship ended")
	H.ok(not Players[0]:GetDiplomacy():HasDeclaredFriendship(1))
	local w = Named(0, "VEF-BLOCK")
	H.notnil(w, "a Warrior of yours on the start tile")
	H.eq(w.x, x); H.eq(w.y, y)
	H.endTurn()
	H.ok(CheckLine("CANCEL", "PASS"))
	H.ok(H.hasLine("ring 1 (expected ring 1) moves=0"))
	H.ok(H.hasLine("reason=NOT_PARTNER"))
	H.clean()
end)

test("1.0.2.2 S16: nothing on its way -> CANCEL_PREP CHECK", function()
	Setup()
	Dev("scn_cancel")
	H.ok(CheckLine("CANCEL_PREP", "CHECK"))
	H.ok(H.hasLine("send a unit first, then press S16"))
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
-- EFV_Dev 1.0.2.1: T2 adds one line per city-state (VEF 1.0.2: City-State
-- sends need no shared enemy): CSN at peace ALLOWED, CSX at war with you
-- GREY:AT_WAR_WITH_RECIPIENT, CSO (further ones) ALLOWED.
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

test("1.0.2.1 T2 shared enemy: 7 AI civs by ID; FW / FOW open, FN / FON / AN no common enemy, NW absent; city-states need none (gameplay rules)", function()
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
	-- one line per civ and city-state, all PASS, then the summary
	H.len(EligLines("ELIG_T2", "PASS"), 11, "7 civs + 3 city-states + summary")
	H.len(EligLines("ELIG_T2", "FAIL"), 0); H.len(EligLines("ELIG_T2", "CHECK"), 0)
	H.ok(H.hasLine("summary (gameplay rules): T2 Shared enemy, 7 civ(s) + 3 city-state(s): 10 PASS, 0 FAIL, 0 CHECK"))
	-- city-states (VEF 1.0.2): CSN=4 at peace, CSX=5 at war with you, CSO=6
	H.ok(d0:IsAtWarWith(5), "you are at war with CSX")
	for _, pid in ipairs({ 4, 6 }) do
		H.ok(not d0:IsAtWarWith(pid), "not at war with " .. pid)
		H.ok(not EFV_HasCommonWar(0, pid), "no shared enemy with " .. pid)
	end
	local csn = RoleLine("ELIG_T2", "CSN", 4)
	H.ok(Has(csn, "City-State expected ALLOWED actual ALLOWED"), csn)
	H.ok(Has(csn, "real wars: none"), csn)
	H.ok(Has(RoleLine("ELIG_T2", "CSX", 5), "City-State expected GREY:AT_WAR_WITH_RECIPIENT actual GREY:AT_WAR_WITH_RECIPIENT"))
	H.ok(Has(RoleLine("ELIG_T2", "CSO", 6), "City-State expected ALLOWED actual ALLOWED"))
	H.ok(not H.hasLine("City-State expected GREY:NO_COMMON_WAR"), "no City-State line expects a shared enemy")
	local fn = RoleLine("ELIG_T2", "FN", 7)
	H.ok(Has(fn, "Expeditionary expected GREY:NO_COMMON_WAR actual GREY:NO_COMMON_WAR"), fn)
	H.ok(Has(fn, "Volunteers expected GREY:NO_COMMON_WAR+VOL_NEEDS_ACCESS actual GREY:NO_COMMON_WAR+VOL_NEEDS_ACCESS"), fn)
	H.ok(Has(fn, "real wars: none"), "the Free Cities and barbarian wars are not listed")
	H.ok(Has(RoleLine("ELIG_T2", "NW", 9), "Expeditionary expected ABSENT actual ABSENT"))
	H.ok(Has(RoleLine("ELIG_T2", "FOW", 3), "Volunteers expected ALLOWED actual ALLOWED"))
	H.ok(Has(RoleLine("ELIG_T2", "AN", 10), "Expeditionary expected GREY:NO_COMMON_WAR actual GREY:NO_COMMON_WAR"))
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.elig.test, "T2"); H.eq(st.elig.stamp, 31); H.len(st.elig.civs, 10); H.eq(st.elig.pass, 10)
	H.eq(st.elig.n, 10); H.eq(st.elig.ncs, 3)
	H.eq(st.focus.stamp, 31); H.eq(st.focus.u, st.elig.u1)
	H.ok(H.gold(0) >= 2000)
	H.ok(not H.hasLine(": ERROR"))
	-- pressed again: the Swordsmen are replaced, the verdicts stay
	Dev("elig_t2", { stamp = 32 })
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 2)
	H.len(EligLines("ELIG_T2", "PASS"), 22)
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
	H.len(EligLines("ELIG_T2", "PASS"), 6, "E, FW, FOW, CSN, CSX, CSO")
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
	H.ok(H.hasLine("7 civ(s) + 3 city-state(s): 9 PASS, 0 FAIL, 1 CHECK"))
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
	H.len(EligLines("ELIG_T2_UI", "PASS"), 11, "UI rules: 7 civs + 3 city-states + summary")
	H.len(EligLines("ELIG_T2_UI", "FAIL"), 0); H.len(EligLines("ELIG_T2_UI", "CHECK"), 0)
	H.ok(Has(RoleLine("ELIG_T2_UI", "FOW", 3), "UI basis FRIEND, Volunteer basis FRIEND_OB"), "FOW seen by the UI adapters")
	H.ok(Has(RoleLine("ELIG_T2_UI", "AN", 10), "UI basis ALLIANCE"), "AN seen by the UI adapters")
	H.ok(Has(RoleLine("ELIG_T2_UI", "CSN", 4), "City-State expected ALLOWED actual ALLOWED [UI rules]"), "CSN, UI rules")
	H.ok(Has(RoleLine("ELIG_T2_UI", "CSX", 5), "City-State expected GREY:AT_WAR_WITH_RECIPIENT actual GREY:AT_WAR_WITH_RECIPIENT"))
	H.ok(H.hasLine("summary (UI rules): T2, 7 civ(s) + 3 city-state(s): 10 PASS, 0 FAIL, 0 CHECK"))
	local info = panel.Controls.InfoLabel:GetText()
	H.ok(string.find(info, "T2: E=", 1, true) == 1, "role map on the first line: " .. info)
	H.ok(Has(info, "FW=") and Has(info, "AN="), info)
	local rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "T2: gameplay 10/10 PASS, UI 10/10 PASS", 1, true) == 1, "status: " .. rec)
	H.ok(Has(info, "CSN=") and Has(info, "CSX=") and not Has(info, "CSO="), info)
	H.eq(FAKE_UI.selectedUnit and FAKE_UI.selectedUnit.id, H.prop("EFV_DEV_SCN").elig.u1, "the first Swordsman is selected")
end)


-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.3.2: the VEF 1.0.3 session (EFV/TESTING_1.0.3.md): S17
-- tracker labels, S18 / S19 Entrust rules, and the V veteran spike.
-- ---------------------------------------------------------------------------
local function UICheckLines(id, verdict)
	return H.lines("[EFV][CHECK] " .. id .. " " .. verdict)
end

test("1.0.3.2 S17: four records in transit; the tracker reads Inbound / Departed / Outbound / Returning; removed at the end of the turn", function()
	local S = Setup()
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	local b = FAKE_UI.FindButton("S17 Tracker labels")
	H.notnil(b, "S17 button")
	b:Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(p.cmd, "scn_labels")
	Pump({ panel }, 4)
	H.ok(CheckLine("TRACKER_PREP", "INFO"), "four records built")
	H.len(H.records(), 4)
	local byRole = {}
	local store = EFV_Records.Load()
	for _, e in ipairs(H.prop("EFV_DEV_SCN").s17.rows) do byRole[e.role] = EFV_Records.Get(store, e.id) end
	H.eq(byRole.INBOUND.senderID, 2); H.eq(byRole.INBOUND.recipientID, 0); H.eq(byRole.INBOUND.state, "OUTBOUND")
	H.eq(byRole.DEPARTED.senderID, 2); H.eq(byRole.DEPARTED.recipientID, 0); H.eq(byRole.DEPARTED.state, "RETURNING")
	H.eq(byRole.OUTBOUND.senderID, 0); H.eq(byRole.OUTBOUND.recipientID, 2); H.eq(byRole.OUTBOUND.state, "OUTBOUND")
	H.eq(byRole.RETURNING.senderID, 0); H.eq(byRole.RETURNING.state, "RETURNING")
	H.eq(byRole.RETURNING.returnX, S.c0.x, "your unit comes home to your capital")
	H.eq(byRole.DEPARTED.returnX, S.c2.x, "F's unit goes home to F's capital")
	H.len(UICheckLines("TRACKER_LABELS", "PASS"), 5, "four rows and the summary")
	H.len(UICheckLines("TRACKER_LABELS", "FAIL"), 0)
	H.ok(H.hasLine("INBOUND record " .. byRole.INBOUND.id), "one line per row")
	H.ok(H.hasLine("tracker shows 'Inbound' (expected 'Inbound')"))
	H.ok(H.hasLine("tracker shows 'Departed' (expected 'Departed'); tooltip has 'Departed, home in 2 turns'"))
	H.ok(H.hasLine("tracker shows 'Outbound' (expected 'Outbound')"))
	H.ok(H.hasLine("tracker shows 'Returning' (expected 'Returning'); tooltip has 'Returning, arrives in 2 turns'"))
	H.ok(H.hasLine("summary: 4/4 rows as expected"))
	H.ok(H.hasLine("tracker open hook sent ok=true"), "the panel opens the tracker")
	-- the S17 records are not sends: S16 ignores them
	FAKE_UI.AsGameplay(function() Dev("scn_cancel") end)
	H.ok(CheckLine("CANCEL_PREP", "CHECK"), "S16 skips the S17 records")
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	H.len(H.records(), 0, "removed at the end of the turn")
	H.ok(H.hasLine("removed 4 of 4 test record(s)"))
	H.ok(not H.hasLine("[EFV][CHECK] HOME"), "no HOME check for them")
end)

test("1.0.3.2 S17: a label mismatch is a FAIL line", function()
	Setup()
	local panel = PanelUI()
	FAKE_UI.AsGameplay(function() Dev("scn_labels", { stamp = 170 }) end)
	local real = EFV_UI_TrackerRows
	EFV_UI_TrackerRows = function(pid, turn)
		local rows = real(pid, turn)
		for _, r in ipairs(rows) do
			if r.rec.state == "OUTBOUND" and r.rec.recipientID == pid then r.state = "Outbound" end
		end
		return rows
	end
	Pump({ panel }, 3)
	EFV_UI_TrackerRows = real
	H.ok(H.hasLine("tracker shows 'Outbound' (expected 'Inbound')"))
	H.ok(CheckLine("TRACKER_LABELS", "FAIL"))
	H.ok(H.hasLine("summary: 3/4 rows as expected"))
end)

test("1.0.3.2 S18: a city-state's only city, B at peace with it: Entrust offers B (UI), entrusted -> ENTRUST_CS PASS", function()
	Setup()
	Dev("scn_entrust_cs", { stamp = 18 })
	H.ok(CheckLine("ENTRUST_CS", "INFO"))
	local st = H.prop("EFV_DEV_SCN")
	local cs = st.s18.owner
	H.ok(cs ~= 4, "not CS (S16 needs it)")
	H.ok(Players[0]:GetDiplomacy():IsAtWarWith(cs), "you are at war with it")
	H.ok(not Players[1]:GetDiplomacy():IsAtWarWith(cs), "B is not")
	H.len(H.unitsOf(0, "UNIT_TANK"), 3)
	local city = CityManager.GetCityAt(st.s18.cx, st.s18.cy)
	H.eq(CityManager.GetDistrictAt(city.x, city.y):GetDamage(DefenseTypes.DISTRICT_GARRISON), 199, "1 HP left")
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, 0, CityTransferTypes.BY_COMBAT)
	H.kill(cs)
	GameEvents.CityConquered(0, cs, oldID, x, y)
	local panel = PanelUI()
	Pump({ panel }, 3)
	H.ok(CheckLine("ENTRUST_CS_UI", "PASS"), "the Entrust button offers a partner")
	H.ok(H.hasLine("button enabled for"))
	FAKE_UI.AsGameplay(function() H.request(0, { OnStart = "EFV_Entrust", x = x, y = y, recipientID = 1 }) end)
	H.eq(CityManager.GetCityAt(x, y):GetOwner(), 1, "entrusted to B")
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	H.ok(CheckLine("ENTRUST_CS", "PASS"))
	H.ok(H.hasLine("B was at war with it=false"))
end)

test("1.0.3.2 S19: a living major's city (not its last): Entrust greyed (UI), kept -> ENTRUST_MAJOR PASS; a partner getting it -> FAIL", function()
	FreshBoot()
	FAKE.NewPlayer(7, { gold = 1000 })
	H.city(7, 60, 12, { capital = true, name = "LOC_CITY_D" })
	Dev("scn_setup", { stamp = 1 })
	H.ok(CheckLine("SETUP", "PASS"))
	Dev("scn_entrust_major", { stamp = 19 })
	H.ok(CheckLine("ENTRUST_MAJOR", "INFO"))
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.s19.owner, 7, "D = the 4th major")
	H.ok(H.hasLine("new city founded for"), "D had only its capital")
	H.len(FAKE.CitiesOf(7), 2)
	H.ok(Players[0]:GetDiplomacy():IsAtWarWith(7))
	H.ok(not Players[1]:GetDiplomacy():IsAtWarWith(7) and not Players[2]:GetDiplomacy():IsAtWarWith(7), "B and F stay at peace with D")
	local city = CityManager.GetCityAt(st.s19.cx, st.s19.cy)
	H.ok(not (city.x == 60 and city.y == 12), "not D's capital")
	local x, y, oldID = city.x, city.y, city.id
	CityManager.TransferCity(city, 0, CityTransferTypes.BY_COMBAT)
	GameEvents.CityConquered(0, 7, oldID, x, y)
	local panel = PanelUI()
	Pump({ panel }, 3)
	H.ok(CheckLine("ENTRUST_MAJOR_UI", "PASS"), "greyed with ENTRUST_NO_PARTNER")
	H.ok(H.hasLine("greyed (ENTRUST_NO_PARTNER)"))
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	H.ok(CheckLine("ENTRUST_MAJOR", "PASS"))
	-- a second scene whose city a partner gets anyway is reported as a FAIL
	FAKE_UI.AsGameplay(function() Dev("scn_entrust_major", { stamp = 191 }) end)
	local st2 = H.prop("EFV_DEV_SCN").s19
	CityManager.TransferCity(CityManager.GetCityAt(st2.cx, st2.cy), 1, CityTransferTypes.BY_GIFT)
	FAKE_UI.AsGameplay(function() Dev("scn_check") end)
	H.ok(CheckLine("ENTRUST_MAJOR", "FAIL"))
end)

test("1.0.3.2 S19: only 3 AI civs -> CHECK, nothing set up", function()
	Setup()
	Dev("scn_entrust_major")
	H.ok(CheckLine("ENTRUST_MAJOR", "CHECK"))
	H.ok(H.hasLine("needs a 4th AI civ"))
	H.len(H.unitsOf(0, "UNIT_TANK"), 0)
end)

-- The veteran one-turn restore spike. FAKE_UI.promoteEndsTurn = true is the
-- base rule (a promotion ends the unit's turn) that V1 and V2 work around.
local function SpikeBoot(opts)
	opts = opts or {}
	FreshBoot()
	if opts.civType then Players[0].civType = opts.civType end
	local panel = PanelUI()
	FAKE_UI.promoteEndsTurn = opts.endsTurn ~= false
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	local b = FAKE_UI.FindButton("V Veteran spike")
	H.notnil(b, "V button")
	b:Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, "vs_start")
	Pump({ panel }, 40)
	return panel
end

local function Copy(k) return Named(0, "VEF-" .. k) end

test("1.0.3.2 V spike: V0 one promotion in the first turn; V1 and V2 all three; V1 off ends the turn again; V3 logged", function()
	local panel = SpikeBoot()
	H.ok(CheckLine("VSPIKE", "INFO"))
	H.ok(H.hasLine("template UNIT_WARRIOR (scenario template), promotions PROMOTION_BATTLECRY+PROMOTION_TORTOISE+PROMOTION_COMMANDO, XP 90"))
	for _, k in ipairs({ "V0", "V1", "V2", "V3" }) do H.notnil(Copy(k), k) end
	H.ok(not H.hasLine("you play Gran Colombia"))
	-- V0: the limit
	H.ok(CheckLine("VSPIKE_V0", "PASS"), "control: one promotion, then nothing offered")
	H.ok(H.hasLine("the one-per-turn limit is reproduced"))
	H.len(H.promotionTypes(Copy("V0")), 1)
	-- V1: hidden ability, all three, level 4; then off -> one normal promotion ends the turn
	H.ok(CheckLine("VSPIKE_V1", "PASS"))
	H.ok(H.hasLine("3/3 promotions in the first turn, level 4 (want 4)"))
	H.ok(CheckLine("VSPIKE_V1_OFF", "PASS"), "the base rule is back after the ability is removed")
	H.eq(Copy("V1"):GetAbility():GetAbilityCount("EFV_DEV_ABILITY_PROMOTE_KEEP_MOVES"), 0, "ability removed")
	H.len(H.promotionTypes(Copy("V1")), 4, "three wanted + the normal one")
	H.eq(Copy("V1"):GetMovesRemaining(), 0)
	-- V2: moves back after each promotion
	H.ok(CheckLine("VSPIKE_V2", "PASS"))
	H.len(H.promotionTypes(Copy("V2")), 3)
	H.ok(H.hasLine("V2 moves restored with ChangeMovesRemaining ok=true"))
	-- V3: the fake keeps a script-made unit at level 1 (Session F T08): CHECK with the numbers
	H.ok(CheckLine("VSPIKE_V3", "CHECK"))
	H.ok(H.hasLine("V3 level-adjust ability + SetPromotion + XP: level 1 (want 4)"))
	H.eq(Copy("V3"):GetAbility():GetAbilityCount("EFV_DEV_ABILITY_VET_LEVEL"), 1)
	H.len(H.promotionTypes(Copy("V3")), 3)
	H.ok(#H.lines("[EFV][CHECK] VSPIKE_UI INFO") > 5, "UI state lines")
	H.ok(H.hasLine("V1 created, keep-moves ability +1 ok=true"), "gameplay lines")
	-- later turns: V0 takes one more promotion per turn; state lines at each turn start
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	Pump({ panel }, 20)
	H.len(H.promotionTypes(Copy("V0")), 2, "turn 2: the second")
	H.ok(H.hasLine("V0 turn start |"), "gameplay turn-start line")
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	Pump({ panel }, 20)
	H.len(H.promotionTypes(Copy("V0")), 3)
	H.ok(H.hasLine("all 3 promotions back by turn"), "V0 done in 3 turns")
	H.clean()
end)

test("1.0.3.2 V spike: promotions keep the moves (Gran Colombia): warning, V0 takes a second one in the first turn -> CHECK", function()
	SpikeBoot({ endsTurn = false, civType = "CIVILIZATION_GRAN_COLOMBIA" })
	H.ok(CheckLine("VSPIKE", "CHECK"), "Gran Colombia warning")
	H.ok(H.hasLine("you play Gran Colombia"))
	H.ok(CheckLine("VSPIKE_V0", "CHECK"))
	H.ok(H.hasLine("a 2nd promotion landed in the first turn"))
	H.ok(not CheckLine("VSPIKE_V0", "PASS"))
	H.ok(CheckLine("VSPIKE_V1_OFF", "CHECK"), "the rule off: the extra promotion keeps the moves")
end)

test("1.0.3.2 V spike: the abilities missing from the database -> V1 stops at one promotion, logged NOT GRANTED", function()
	FAKE.abilityTypes = {}
	SpikeBoot()
	H.ok(H.hasLine("NOT GRANTED"))
	H.ok(CheckLine("VSPIKE_V1", "CHECK"))
	H.ok(H.hasLine("stopped at 1/3 in the first turn"))
	H.ok(CheckLine("VSPIKE_V2", "PASS"), "V2 needs no database change")
end)

test("1.0.3.2 V spike: your selected veteran is the template (its type, promotions and XP); a second press replaces the copies", function()
	FreshBoot()
	local v = H.unit(0, "UNIT_SWORDSMAN", 11, 10, { promotions = { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" }, xp = 50 })
	Dev("vs_start", With({ stamp = 5 }, Sel(v)))
	H.ok(H.hasLine("template UNIT_SWORDSMAN (your selected unit " .. v.id .. "), promotions PROMOTION_BATTLECRY+PROMOTION_TORTOISE, XP 50"))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 5, "the veteran and four copies")
	for _, k in ipairs({ "V0", "V1", "V2" }) do
		local c = Copy(k)
		H.eq(c.xp, 15, k .. ": XP to the first threshold")
		H.eq(c:GetMovesRemaining(), c:GetMaxMoves(), k .. ": full moves")
	end
	H.eq(Copy("V1"):GetAbility():GetAbilityCount("EFV_DEV_ABILITY_PROMOTE_KEEP_MOVES"), 1)
	Dev("vs_start", With({ stamp = 6 }, Sel(v)))
	H.len(H.unitsOf(0, "UNIT_SWORDSMAN"), 5, "the previous copies were removed")
	Dev("vs_sync", { k = "V2", have = 0 })
	H.ok(H.hasLine("V2: nothing new"), "vs_sync is derived from the unit: nothing landed, nothing changes")
end)

test("1.0.3.2 panel: the new session buttons exist", function()
	FreshBoot()
	PanelUI()
	for _, label in ipairs({ "S17 Tracker labels", "S18 Entrust city-state", "S19 Entrust major", "V Veteran spike" }) do
		H.notnil(FAKE_UI.FindButton(label), label)
	end
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.1: the VEF 1.0.4 session (EFV/TESTING_1.0.4.md): S20 war
-- sends lent units home, S21 veteran home with three promotions.
-- ---------------------------------------------------------------------------
test("1.0.4.1 S20: VEF-LENT at B's capital, VEF-BORROWED at yours, friendship ended, war with B; next turn both go home", function()
	local S = Setup()
	Dev("scn_war_home", { stamp = 20 })
	H.ok(CheckLine("WAR_HOME", "INFO"))
	local lent, borrowed = Named(1, "VEF-LENT"), Named(0, "VEF-BORROWED")
	H.notnil(lent, "your Swordsman, controlled by B"); H.notnil(borrowed, "B's Swordsman, controlled by you")
	H.eq(Map.GetPlot(lent.x, lent.y):GetOwner(), 1, "on B's land"); H.ok(H.dist(lent, S.c1) <= 2, "next to B's capital")
	H.eq(Map.GetPlot(borrowed.x, borrowed.y):GetOwner(), 0, "on your land"); H.ok(H.dist(borrowed, S.c0) <= 2)
	H.eq(lent:GetMovesRemaining(), 0, "held until the next turn start")
	local d0 = Players[0]:GetDiplomacy()
	H.ok(not d0:HasDeclaredFriendship(1), "friendship ended")
	H.ok(d0:IsAtWarWith(1), "at war with B")
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.focus.stamp, 20); H.eq(st.focus.x, lent.x); H.eq(st.focus.y, lent.y)
	local recL = Recs(function(r) return r.senderID == 0 end)[1]
	local recB = Recs(function(r) return r.senderID == 1 end)[1]
	H.notnil(recL); H.notnil(recB)
	for _, r in ipairs({ recL, recB }) do
		H.eq(r.forceType, "EXPEDITIONARY"); H.eq(r.state, "DEPLOYED"); H.eq(r.durationTurns, EFV_Config.EXPEDITIONARY_DURATION)
	end
	H.eq(recL.onMapPlayerID, 1); H.eq(recL.onMapUnitID, lent.id); H.eq(recL.recipientID, 1)
	H.eq(recB.onMapPlayerID, 0); H.eq(recB.onMapUnitID, borrowed.id); H.eq(recB.recipientID, 0)
	H.endTurn()
	for _, id in ipairs({ recL.id, recB.id }) do
		local r = EFV_Records.Get(EFV_Records.Load(), id)
		H.notnil(r, "record kept for the trip home")
		H.eq(r.state, "RETURNING"); H.eq(r.returnReason, "WAR")
		H.ok(H.hasLine("[War] sent home id=" .. id))
	end
	H.ok(not H.unitAlive(lent), "VEF-LENT gone from B's land"); H.ok(not H.unitAlive(borrowed), "VEF-BORROWED gone from yours")
	H.isnil(Named(0, "VEF-LENT"), "not switched to you in place")
	H.len(H.notifs(0, "EFV_NOTIF_RETURNING"), 1, "you: Unit Coming Home (VEF-LENT)")
	H.len(H.notifs(0, "EFV_NOTIF_REVERTED"), 1, "you: Lent Unit Gone Home (VEF-BORROWED)")
	Dev("scn_war_home")
	H.ok(CheckLine("WAR_HOME", "CHECK"), "a second press: already at war")
	H.ok(H.hasLine("you are already at war with B"))
	H.len(H.records(), 2, "nothing new")
	H.clean()
end)

test("1.0.4.1 S21: a 3-promotion Swordsman comes home from F; all three promotions in the arrival turn, level 4, XP 100/150, 0 moves", function()
	local S = Setup({ routeB = true })
	Dev("scn_vet_home", { stamp = 21 })
	H.ok(CheckLine("VET_HOME", "INFO"))
	local r = H.records()[1]
	H.eq(r.state, "RETURNING"); H.eq(r.forceType, "EXPEDITIONARY"); H.eq(r.senderID, 0); H.eq(r.recipientID, 2)
	H.eq(r.arrivalTurn, FAKE.turn + 1); H.eq(r.returnX, S.c0.x); H.eq(r.returnY, S.c0.y)
	H.eq(r.unitType, "UNIT_SWORDSMAN"); H.eq(r.veteranName, "VEF-VETERAN")
	H.eq(r.level, 4); H.eq(r.experience, 100); H.eq(r.xpNext, 150); H.eq(r.damage, 0)
	H.deq(r.promotions, { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE", "PROMOTION_COMMANDO" })
	H.eq(H.prop("EFV_DEV_SCN").focus.stamp, 21)
	H.endTurn()
	local t1 = FAKE.turn
	H.len(H.records(), 0, "arrived")
	local u = Named(0, "VEF-VETERAN")
	H.notnil(u, "home")
	H.ok(H.dist(u, S.c0) <= 5, "next to your capital")
	include("fake_ui")
	FAKE_UI.Enable()
	FAKE_UI.promoteEndsTurn = true
	local vet = FAKE_UI.LoadContext("EFV/UI/EFV_VetRestore.lua")
	Pump({ vet }, 16)
	H.eq(FAKE.turn, t1, "still the arrival turn")
	H.deq(H.promotionTypes(u), { "PROMOTION_BATTLECRY", "PROMOTION_COMMANDO", "PROMOTION_TORTOISE" }, "all three back")
	H.eq(u:GetExperience():GetLevel(), 4, "level kept")
	H.eq(u:GetExperience():GetExperiencePoints(), 100); H.eq(u:GetExperience():GetExperienceForNextLevel(), 150)
	H.eq(u:GetMovesRemaining(), 0, "0 moves on the arrival turn")
	H.ok(#H.lines("[Vet] refill id=") == 2, "a refill after each promotion but the last")
	FAKE_UI.AsGameplay(function() H.endTurn() end)
	H.eq(u:GetMovesRemaining(), u:GetMaxMoves(), "next turn: full moves")
	H.clean()
end)

test("1.0.4.1 panel: S20 and S21 send their scenario requests; the header names TESTING_1.0.4.md", function()
	Setup()
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	for _, def in ipairs({ { "S20 War sends home", "scn_war_home" }, { "S21 Veteran home", "scn_vet_home" } }) do
		local b = FAKE_UI.FindButton(def[1])
		H.notnil(b, def[1])
		b:Click()
		local p = FAKE_UI.requests[#FAKE_UI.requests].params
		H.eq(p.cmd, def[2]); H.notnil(p.stamp, "stamped like every scenario button")
	end
	H.ok(string.find(__py_read("EFV_Dev/UI/EFV_Dev_Panel.lua"), "Test sessions (EFV/TESTING_1.0.4.md", 1, true) ~= nil)
end)

test("1.0.4.1 panel title: dev tools and loaded VEF version; a VEF build other than FOR_EFV is named as wrong", function()
	FreshBoot()
	local src = __py_read("EFV_Dev/UI/EFV_Dev_Panel.lua")
	H.ok(string.find(src, 'local DEV_VERSION = "' .. EFV_Dev.VERSION .. '"', 1, true) ~= nil, "panel DEV_VERSION = EFV_Dev.VERSION")
	H.ok(string.find(src, 'local DEV_FOR_EFV = "' .. EFV_Dev.FOR_EFV .. '"', 1, true) ~= nil, "panel DEV_FOR_EFV = EFV_Dev.FOR_EFV")
	local panel = PanelUI()
	H.eq(panel.Controls.TitleLabel:GetText(), "VEF Dev " .. EFV_Dev.VERSION .. " | VEF " .. EFV_Config.VERSION .. "  (Ctrl+Shift+D)")
	local real = EFV_Config.VERSION
	EFV_Config.VERSION = "1.0.3"
	local old = FAKE_UI.LoadContext("EFV_Dev/UI/EFV_Dev_Panel.lua")
	EFV_Config.VERSION = real
	local t = old.Controls.TitleLabel:GetText()
	H.ok(string.find(t, "WRONG VEF", 1, true) ~= nil, "mismatch shown: " .. tostring(t))
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.2: the denouncement reader spike (FIXPLAN_proxy_war.md,
-- EFV/TESTING_DENOUNCE_SPIKE.md). Since 1.0.5 the fake engine mirrors the
-- in-game result (SPIKES 8.1): G has GetAi_Diplomacy():GetDiplomaticState
-- (a StateType string) and no GetDiplomaticAI; UI has GetDiplomaticAI,
-- GetDenounceTurn and GetDenounceTimeLimit and no GetAi_Diplomacy. A missing
-- reader is logged as MISSING and never fails.
-- ---------------------------------------------------------------------------
test("1.0.4.2 D probe (gameplay): every reader by name for each met major, both ways; missing -> MISSING, a throwing one -> ERROR; answer saved", function()
	FreshBoot()
	Dev("meet", { target = 1 })
	Dev("meet", { target = 3 })
	local d0 = Players[0]:GetDiplomacy()
	d0.GetDenounceTurn = function(_, b) if b == 3 then return 7 end return -1 end
	d0.IsDenouncing = function() error("boom") end
	H.markBody()
	Dev("denounce_probe", { stamp = 41 })
	H.ok(H.hasLine("[EFV][Probe] G GetDenounceTimeLimit()=MISSING"), "GetDenounceTimeLimit is nil in G (SPIKES 8.1)")
	H.ok(H.hasLine("[EFV][Probe] G GetDenounceTurn(0->3)=7"))
	H.ok(H.hasLine("[EFV][Probe] G GetDenounceTurn(3->0)=MISSING"))
	H.ok(H.hasLine("[EFV][Probe] G IsDenouncing(0->1)=ERROR"))
	H.ok(H.hasLine("[EFV][Probe] G HasDenounced(0->1)=MISSING"))
	H.ok(H.hasLine("[EFV][Probe] G AiDiplo:GetDiplomaticState(1->0)=DIPLO_STATE_NEUTRAL (string"), "the G reader (A64)")
	H.ok(H.hasLine("[EFV][Probe] G DiploAI:GetDiplomaticStateIndex(0->1)=MISSING"), "GetDiplomaticAI is nil in G")
	H.ok(H.hasLine("[EFV][Probe] G has GetDiplomacy():GetDenounceTurn = yes"))
	H.ok(not H.hasLine("(0->2)"), "P2 not met: not probed")
	H.len(H.lines("->"), 7 * 2 * 2, "7 readers x 2 met majors x 2 directions")
	local dp = H.prop("EFV_DEV_SCN").dprobe
	H.eq(dp.stamp, 41); H.deq(dp.pids, { 1, 3 })
	H.eq(dp.r[1].s, "mixed"); H.eq(dp.r[1].hits, "0>3=7")
	H.eq(dp.r[2].s, "mixed"); H.eq(dp.r[3].s, "nil"); H.eq(dp.r[4].s, "ok"); H.eq(dp.r[4].hits, "-"); H.eq(dp.r[5].s, "nil")
	H.ok(H.hasLine("[EFV][Probe] G summary: Turn mixed [0>3=7] | IsDen mixed [-] | HasDen nil [-]"))
	H.ok(not H.hasLine("denounce_probe: ERROR"))
	H.clean()
end)

test("1.0.4.2 panel: D Setup names and targets a civ to denounce; D Denounce probe runs the UI readers and shows G and UI", function()
	FreshBoot()
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	FAKE_UI.FindButton("D Setup"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, "denounce_setup")
	Pump({ panel }, 4)
	H.ok(CheckLine("DENOUNCE_SETUP", "INFO"))
	H.ok(Players[0]:GetDiplomacy():HasMet(1), "met")
	H.eq(H.prop("EFV_DEV_SCN").dsetup.x, 1, "lowest-ID major you could denounce")
	H.ok(Has(panel.Controls.RecordLabel:GetText(), "D Setup: denounce P1"), panel.Controls.RecordLabel:GetText())
	H.ok(Has(panel.Controls.TargetLabel:GetText(), "P1"), "Target set to it")
	local b = FAKE_UI.FindButton("D Denounce probe")
	H.notnil(b)
	b:Click()
	local p = FAKE_UI.requests[#FAKE_UI.requests].params
	H.eq(p.cmd, "denounce_probe"); H.notnil(p.stamp)
	Pump({ panel }, 4)
	H.ok(H.hasLine("[EFV][Probe] G GetDenounceTurn(0->1)=MISSING"))
	H.ok(H.hasLine("[EFV][Probe] UI GetDenounceTurn(0->1)=-1"), "UI only (SPIKES 8.1)")
	H.ok(H.hasLine("[EFV][Probe] UI DiploAI:GetDiplomaticStateIndex(1->0)=3"))
	H.ok(H.hasLine("[EFV][Probe] UI AiDiplo:GetDiplomaticState(1->0)=MISSING"), "GetAi_Diplomacy is nil in UI")
	-- As in game: each of Turn, AiState, StateIdx, AiMods, AIMods exists in one context only.
	H.len(H.lines("-> same"), 2, "IsDen and HasDen: nil in both")
	H.len(H.lines("-> DIFFERENT"), 5)
	local rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "Denounce probe T", 1, true) == 1, rec)
	H.ok(Has(rec, "5 reader(s) differ") and Has(rec, "G: Turn nil -") and Has(rec, "UI: Turn ok -") and Has(rec, "StateIdx ok -"), rec)
end)

test("1.0.4.2 D Setup: nobody you could denounce (friend, war) -> CHECK, nothing met", function()
	FreshBoot()
	for _, pid in ipairs({ 1, 2 }) do Dev("friend", { target = pid }) end
	Dev("war", { target = 3 })
	Dev("denounce_setup", { stamp = 5 })
	H.ok(CheckLine("DENOUNCE_SETUP", "CHECK"))
	H.eq(H.prop("EFV_DEV_SCN").dsetup.x, -1)
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.3: the air-unit spike (FIXPLAN_air_units.md section 7,
-- EFV/TESTING_SPIKES.md). The fake engine has no air readers (plot /
-- district / unit GetAirSlots / GetAirUnits, CanStartOperation and
-- GetOperationTargets in gameplay): the handlers log them as MISSING and
-- still answer.
-- ---------------------------------------------------------------------------
local function AirAns() return H.prop("EFV_DEV_SCN").air.ans end

test("1.0.4.3 air spike (gameplay): A1-A5 and A Status answer with missing air readers; planes made, B's keeps promotion and damage", function()
	local S = Setup()
	H.markBody()
	Dev("air_city", { stamp = 31 })
	H.ok(CheckLine("AIR_A1", "INFO")); H.eq(AirAns().stamp, 31)
	local air = H.unitsOf(0, "UNIT_FIGHTER")
	H.len(air, 3, "AIR-1 and AIR-2 in the capital, AIR-3 off base")
	H.ok(Named(0, "VEF-AIR-1").x == S.c0.x and Named(0, "VEF-AIR-1").y == S.c0.y, "AIR-1 in your capital")
	H.ok(H.hasLine("[EFV][Air] G your capital @10,10: GetUnitCount="))
	H.ok(H.hasLine("plot:GetAirUnits=MISSING"))
	H.ok(H.hasLine("AIR-1: ") and H.hasLine("domain=DOMAIN_AIR"))
	H.ok(H.hasLine("CanDEPLOY=MISSING"))
	H.ok(string.find(AirAns().text, "A1: AIR-1 P0 @10,10 in city of P0", 1, true) == 1, AirAns().text)
	Dev("air_host", { stamp = 32 })
	H.ok(CheckLine("AIR_A2", "INFO"))
	local b = Named(1, "VEF-AIR-B")
	H.notnil(b, "B's plane made through EFV_Units.Recreate")
	H.eq(b.x, S.c1.x); H.eq(b.y, S.c1.y); H.eq(b:GetDamage(), 20); H.eq(#H.promotionTypes(b), 1)
	H.ok(Has(AirAns().text, "promotions 1/1"), AirAns().text)
	Dev("air_fuel", { stamp = 33 })
	H.ok(Has(AirAns().text, "A3 step 1: VEF-AIR-1 damage 30"), AirAns().text)
	H.eq(H.res(0, "RESOURCE_ALUMINUM"), 0)
	Dev("air_fuel", { stamp = 34 })
	H.ok(Has(AirAns().text, "End Turn until turn " .. (FAKE.turn + 2)), "a plane does not heal in its first round: " .. AirAns().text)
	H.endTurn(); H.endTurn()
	H.ok(CheckLine("AIR_TURN", "INFO"), "positions at the turn start")
	Dev("air_fuel", { stamp = 35 })
	H.ok(Has(AirAns().text, "A3 step 2"), AirAns().text)
	H.ok(H.res(0, "RESOURCE_ALUMINUM") >= 2, "top-up: 2 per Aluminium unit")
	H.endTurn()
	Dev("air_fuel", { stamp = 36 })
	H.ok(Has(AirAns().text, "A3 step 3"), AirAns().text)
	Dev("air_ally", { stamp = 37 })
	H.ok(CheckLine("AIR_A4", "INFO"))
	H.ok(Players[0]:GetDiplomacy():HasAllied(2), "F is your ally")
	H.notnil(Named(0, "VEF-AIR-V"), "your plane in F's capital")
	Dev("air_carrier", { stamp = 38 })
	H.ok(Has(AirAns().text, "no free water"), "no sea next to the fake capital: " .. AirAns().text)
	Dev("air_status", { stamp = 39 })
	H.ok(string.find(AirAns().text, "Air T", 1, true) == 1 and Has(AirAns().text, "AIR-B P1"), AirAns().text)
	H.ok(not H.hasLine("ERROR"), "no handler error")
	H.clean()
end)

test("1.0.4.3 A5: carrier and plane on your water, VEF's send rule asked; second press before and after the carrier left", function()
	local S = Setup()
	for _, xy in ipairs({ { 9, 10 }, { 8, 10 }, { 8, 11 }, { 9, 11 }, { 7, 10 }, { 7, 11 } }) do H.terrain(xy[1], xy[2], "COAST") end
	H.markBody()
	Dev("air_carrier", { stamp = 51 })
	H.ok(CheckLine("AIR_A5", "INFO"))
	local cv, pl = Named(0, "VEF-CV"), Named(0, "VEF-AIR-CV")
	H.notnil(cv); H.notnil(pl)
	H.ok(cv.x == pl.x and cv.y == pl.y, "plane created on the carrier's tile")
	H.ok(Has(AirAns().text, "send rule: B "), AirAns().text)
	Dev("air_carrier", { stamp = 52 })
	H.ok(Has(AirAns().text, "still on the map"), AirAns().text)
	Dev("kill", Sel(cv))
	Dev("air_carrier", { stamp = 53 })
	H.ok(Has(AirAns().text, "A5 after the send: carrier gone, no VEF record; plane VEF-AIR-CV P0"), AirAns().text)
	H.ok(not H.hasLine("ERROR"))
	H.clean()
end)

test("1.0.4.3 air spike without S0: CHECK, nothing made", function()
	FreshBoot()
	Dev("air_city", { stamp = 3 })
	H.ok(CheckLine("AIR_A1", "CHECK"))
	H.len(H.unitsOf(0, "UNIT_FIGHTER"), 0)
end)

test("1.0.4.3 panel: the A buttons send their requests; the status line shows gameplay's answer and the UI's view", function()
	FreshBoot()
	Dev("scn_setup", { stamp = 1 })
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	local want = { { "A1 Plane in your city", "air_city", "A1: AIR-1" }, { "A2 Plane for B", "air_host", "A2: B's plane" },
		{ "A3 Fuel (press per step)", "air_fuel", "A3 step 1" }, { "A4 Plane with ally F", "air_ally", "A4: allied" },
		{ "A5 Loaded carrier (again after the send)", "air_carrier", "A5: " }, { "A Status", "air_status", "Air T" } }
	for _, w in ipairs(want) do
		local b = FAKE_UI.FindButton(w[1])
		H.notnil(b, w[1])
		b:Click()
		H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, w[2])
		Pump({ panel }, 4)
		local rec = panel.Controls.RecordLabel:GetText()
		H.ok(string.find(rec, w[3], 1, true) == 1 and Has(rec, "[NEWLINE]UI: "), rec)
	end
	H.ok(H.hasLine("[EFV][Air] UI summary air_city: AIR-1 based no"), "no air readers in the fake UI")
	H.ok(not H.hasLine("air spike error"))
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.4: the Corps spike (FIXPLAN_corps.md section 5 and its
-- designer rulings, EFV/TESTING_SPIKES.md). The fake engine has no civic,
-- upkeep-per-type or CanFormMilitaryFormation-by-name readers: they are
-- logged as MISSING and the buttons still answer.
-- ---------------------------------------------------------------------------
local function CorpsAns() return H.prop("EFV_DEV_SCN").corps.ans end
local function Form(name) return MilitaryFormationTypes[name .. "_FORMATION"] end

test("1.0.4.4 corps spike C1: three presses set your Swordsman to ARMY, CORPS, STANDARD; upkeep read; Builder and Ram read", function()
	local S = Setup()
	H.markBody()
	Dev("corps_probe", { stamp = 61 })
	H.ok(CheckLine("CORPS_C1", "INFO")); H.eq(CorpsAns().stamp, 61)
	local u = Named(0, "VEF-C1")
	H.notnil(u, "Swordsman made"); H.notnil(Named(0, "VEF-C1T"), "Tank made"); H.notnil(Named(0, "VEF-C1B"), "Builder made")
	H.eq(u:GetMilitaryFormation(), Form("ARMY"))
	H.ok(Has(CorpsAns().text, "C1 step 1 of 3 -> ARMY"), CorpsAns().text)
	H.ok(H.hasLine("[EFV][Corps] G UNIT_TANK Maintenance (data)"), "per-type upkeep readers tried")
	Dev("corps_probe", { stamp = 62 })
	H.eq(u:GetMilitaryFormation(), Form("CORPS"))
	Dev("corps_probe", { stamp = 63 })
	H.eq(u:GetMilitaryFormation(), Form("STANDARD"))
	H.ok(Has(CorpsAns().text, "Done"), CorpsAns().text)
	Dev("corps_probe", { stamp = 64 })
	H.len(H.unitsOf(0, "UNIT_TANK"), 1, "a new round replaces the C1 units")
	H.ok(not H.hasLine("ERROR"), "no handler error")
	H.clean()
end)

test("1.0.4.4 corps spike C2, C5, C6, C7 and C Status: formations for hosts without the civic, records, round trip", function()
	local S = Setup()
	H.markBody()
	Dev("corps_give", { stamp = 71 })
	H.ok(CheckLine("CORPS_C2", "INFO"), "C2 answers")
	local a, b, r = Named(5, "VEF-C2-A") or Named(6, "VEF-C2-A"), Named(5, "VEF-C2-B") or Named(6, "VEF-C2-B"), Named(1, "VEF-C2-ARMY")
	H.notnil(a, "C2-A for a second city-state"); H.notnil(b); H.notnil(r)
	H.eq(a:GetMilitaryFormation(), Form("CORPS")); H.eq(b:GetMilitaryFormation(), Form("CORPS")); H.eq(r:GetMilitaryFormation(), Form("ARMY"))
	H.eq(#H.promotionTypes(b), 2); H.eq(b:GetDamage(), 30)
	H.ok(Has(CorpsAns().text, "Nationalism MISSING"), "civics read by name: " .. CorpsAns().text)
	Dev("corps_cs_force", { stamp = 72 })
	H.ok(CheckLine("CORPS_C5", "INFO"))
	local s1 = Named(4, "VEF-C5-S")
	H.notnil(s1, "case 1 at CS"); H.eq(s1:GetMilitaryFormation(), Form("CORPS"))
	H.notnil(EFV_Records.FindByUnit(EFV_Records.Load(), 4, s1:GetID()), "C5-S is a tracked City-State unit")
	Dev("corps_host", { stamp = 73 })
	H.ok(CheckLine("CORPS_C6", "INFO"))
	local uc, ua = Named(0, "VEF-C6-CORPS"), Named(0, "VEF-C6-ARMY")
	H.notnil(uc); H.notnil(ua)
	H.eq(uc:GetMilitaryFormation(), Form("CORPS")); H.eq(ua:GetMilitaryFormation(), Form("ARMY"))
	H.eq(uc:GetMovesRemaining(), uc:GetMaxMoves(), "full moves to move and attack this turn")
	local rec = EFV_Records.FindByUnit(EFV_Records.Load(), 0, uc:GetID())
	H.notnil(rec, "lent by B"); H.eq(rec.senderID, 1)
	H.notnil(Named(3, "VEF-C6-FOE"), "C's Warrior to attack")
	H.eq(Named(1, "VEF-C6-B"):GetMilitaryFormation(), Form("CORPS"))
	Dev("corps_trip", { stamp = 74 })
	H.ok(CheckLine("CORPS_C7", "INFO"))
	local u7 = Named(0, "VEF-C7")
	H.notnil(u7, "recreated through VEF's own path")
	H.eq(u7:GetMilitaryFormation(), Form("ARMY")); H.eq(u7:GetDamage(), 30)
	H.ok(Has(CorpsAns().text, "snapshot ARMY, removed, restored"), CorpsAns().text)
	Dev("corps_trip", { stamp = 75 })
	H.ok(Has(CorpsAns().text, "C7 read back: ") and Has(CorpsAns().text, "ARMY yes"), CorpsAns().text)
	Dev("corps_status", { stamp = 76 })
	H.ok(string.find(CorpsAns().text, "Corps T", 1, true) == 1 and Has(CorpsAns().text, "C6-CORPS P0/"), CorpsAns().text)
	H.endTurn()
	H.ok(CheckLine("CORPS_WATCH", "INFO"), "watch line at the turn start")
	H.ok(H.hasLine("C5-S gone, record") or H.hasLine("C5-S P4/"), "case 1 reported")
	H.ok(not H.hasLine("[EFV][Corps] G C7 Recreate ERROR"))
	H.clean()
end)

test("1.0.4.4 corps spike C3: Nationalism for you, two lent pairs; second press asks to merge; after End Turn the open records expire", function()
	local S = Setup()
	H.markBody()
	Dev("corps_merge", { stamp = 81 })
	H.ok(CheckLine("CORPS_C3", "INFO"))
	local lent, own = Named(0, "VEF-C3-LENT"), Named(0, "VEF-C3-OWN")
	H.notnil(lent); H.notnil(own)
	H.eq(H.dist(lent, own), 1, "the pair stands side by side")
	local rec = EFV_Records.FindByUnit(EFV_Records.Load(), 0, lent:GetID())
	H.notnil(rec, "LENT is B's Expeditionary unit"); H.eq(rec.senderID, 1)
	H.eq(lent:GetDamage(), 20); H.eq(#H.promotionTypes(own), 1)
	H.ok(Has(CorpsAns().text, "select VEF-C3-LENT, Form Corps, click VEF-C3-OWN"), CorpsAns().text)
	Dev("corps_merge", { stamp = 82 })
	H.ok(Has(CorpsAns().text, "merge both pairs now"), CorpsAns().text)
	H.endTurn()
	Dev("corps_merge", { stamp = 83 })
	H.ok(Has(CorpsAns().text, "C3 step 2: C3-LENT record"), CorpsAns().text)
	H.eq(EFV_Records.Get(EFV_Records.Load(), rec.id).deployedTurn, FAKE.turn + 1 - EFV_Config.EXPEDITIONARY_DURATION)
	H.clean()
end)

test("1.0.4.4 corps spike without S0: CHECK, nothing made", function()
	FreshBoot()
	Dev("corps_probe", { stamp = 3 })
	H.ok(CheckLine("CORPS_C1", "CHECK"))
	H.eq(Named(0, "VEF-C1"), nil)
end)

test("1.0.4.4 panel: the C buttons send their requests and show the answer with the UI's view; Form Corps mode is logged", function()
	FreshBoot()
	Dev("scn_setup", { stamp = 1 })
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	local want = { { "C1 Formation probe (press per step)", "corps_probe", "C1 step 1" }, { "C2 Formations for B and a city-state", "corps_give", "C2 " },
		{ "C6 Host without the civic", "corps_host", "C6 civics" }, { "C Status", "corps_status", "Corps T" } }
	for _, w in ipairs(want) do
		local b = FAKE_UI.FindButton(w[1])
		H.notnil(b, w[1])
		b:Click()
		H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, w[2])
		Pump({ panel }, 4)
		local rec = panel.Controls.RecordLabel:GetText()
		H.ok(string.find(rec, w[3], 1, true) == 1 and Has(rec, "[NEWLINE]UI: "), rec)
	end
	for _, l in ipairs({ "C3 Merge as host (again after End Turn)", "C4 City-state merges (optional)", "C5 Forced city-state merges",
		"C7 Formation round trip (press twice)" }) do H.notnil(FAKE_UI.FindButton(l), l) end
	H.ok(H.hasLine("[EFV][Corps] UI summary corps_host: C6-CORPS CORPS strength"), "UI reads the formation")
	-- Form Corps mode entered with the lent unit selected (the merge-confirm hook)
	Dev("corps_merge", { stamp = 90 })
	local lent, own = Named(0, "VEF-C3-LENT"), Named(0, "VEF-C3-OWN")
	InterfaceModeTypes.FORM_CORPS, InterfaceModeTypes.FORM_ARMY = 50, 51
	UnitCommandTypes.FORM_CORPS, UnitCommandResults.UNITS = "FORM_CORPS", "UNITS"
	UnitManager.GetCommandTargets = function(u, cmd)
		if cmd == "FORM_CORPS" and u == lent then return { UNITS = { { player = 0, id = own:GetID() } } } end
		return {}
	end
	FAKE_UI.selectedUnit = lent
	Events.InterfaceModeChanged(0, 50)
	H.ok(H.hasLine("[EFV][Corps] UI FORM_CORPS mode: selected VEF-C3-LENT P0/" .. lent:GetID() .. " (lent: record "), "the lent unit is named")
	H.ok(H.hasLine("can merge with: VEF-C3-OWN P0/" .. own:GetID() .. " (not lent)"), "the target is named")
	H.ok(string.find(panel.Controls.RecordLabel:GetText(), "FORM_CORPS mode: selected VEF-C3-LENT", 1, true) == 1)
	H.ok(not H.hasLine("corps spike error"))
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.4.5: C8 split, C9 Volunteer merges, C10 merge guard and the
-- passive merge trace (FIXPLAN_corps.md "Rulings 2", R2.7).
-- ---------------------------------------------------------------------------
local function NamedAny(name)
	for pid = 0, 10 do
		local u = Named(pid, name)
		if u ~= nil then return u end
	end
	return nil
end

test("1.0.4.5 corps spike C8: press 1 builds B's Army and CS2's Corps; press 2 lowers B's in place, removes CS2's, four parts home", function()
	local S = Setup()
	H.markBody()
	Dev("corps_split", { stamp = 101 })
	H.ok(CheckLine("CORPS_C8", "INFO"))
	local b, cs = Named(1, "VEF-C8-B"), NamedAny("VEF-C8-CS")
	H.notnil(b, "B's Army"); H.notnil(cs, "CS2's Corps")
	H.eq(b:GetMilitaryFormation(), Form("ARMY")); H.eq(b:GetDamage(), 30); H.eq(#H.promotionTypes(b), 1)
	H.eq(cs:GetMilitaryFormation(), Form("CORPS")); H.eq(cs:GetDamage(), 30)
	H.ok(Has(CorpsAns().text, "C8 set up: B's VEF-C8-B ARMY (host + you + F)") and Has(CorpsAns().text, "Press C8 again"), CorpsAns().text)
	local id = b:GetID()
	Dev("corps_split", { stamp = 102 })
	H.eq(CorpsAns().stamp, 102)
	H.ok(Has(CorpsAns().text, "C8 split: VEF-C8-B ARMY -> STANDARD, same ID yes") and Has(CorpsAns().text, "promotions 1/1, dmg 30"), CorpsAns().text)
	H.ok(Has(CorpsAns().text, "VEF-C8-CS removed"), CorpsAns().text)
	H.eq(Named(1, "VEF-C8-B"):GetID(), id); H.eq(b:GetMilitaryFormation(), Form("STANDARD"))
	H.eq(NamedAny("VEF-C8-CS"), nil, "CS2's Corps removed")
	for _, d in ipairs({ { 0, "VEF-C8-YOU" }, { 2, "VEF-C8-F" }, { 0, "VEF-C8-YOU2" }, { 2, "VEF-C8-F2" } }) do
		local u = Named(d[1], d[2])
		H.notnil(u, d[2] .. " home to its sender"); H.eq(u:GetDamage(), 30, d[2])
	end
	H.eq(#H.promotionTypes(Named(2, "VEF-C8-F")), 0)
	Dev("corps_split", { stamp = 103 })
	H.ok(Has(CorpsAns().text, "C8 set up"), "a third press starts over")
	H.eq(Named(0, "VEF-C8-YOU"), nil, "the old parts are gone")
	H.ok(not H.hasLine("ERROR"), "no handler error")
end)

test("1.0.4.5 corps spike C8 and C9 without S0: CHECK, nothing made", function()
	FreshBoot()
	Dev("corps_split", { stamp = 3 })
	H.ok(CheckLine("CORPS_C8", "CHECK"))
	Dev("corps_vol", { stamp = 4 })
	H.ok(CheckLine("CORPS_C9", "CHECK"))
	H.eq(NamedAny("VEF-C8-B"), nil); H.eq(Named(0, "VEF-C9-V1"), nil)
end)

test("1.0.4.5 corps spike C9: three pairs with Volunteer records; wait message; after End Turn each pair's survivor; the merge trace", function()
	local S = Setup()
	H.markBody()
	Dev("corps_vol", { stamp = 111 })
	H.ok(CheckLine("CORPS_C9", "INFO"))
	H.ok(Has(CorpsAns().text, "pair 1 select VEF-C9-V1, Form Corps, click VEF-C9-V2") and Has(CorpsAns().text, "Merge trace on"), CorpsAns().text)
	local store = EFV_Records.Load()
	local u = {}
	for _, k in ipairs({ "V1", "V2", "REG", "V3", "V4", "REG2" }) do
		u[k] = Named(0, "VEF-C9-" .. k)
		H.notnil(u[k], k)
		local rec = EFV_Records.FindByUnit(store, 0, u[k]:GetID())
		if string.sub(k, 1, 1) == "V" then
			H.notnil(rec, k .. " is a Volunteer"); H.eq(rec.forceType, EFV_Config.FT_VOL); H.eq(rec.recipientID, 1)
			H.eq(rec.deployedTurn, FAKE.turn - 10)
		else
			H.eq(rec, nil, k .. " is a regular unit")
		end
	end
	H.eq(H.dist(u.V1, u.V2), 1); H.eq(H.dist(u.REG, u.V3), 1); H.eq(H.dist(u.V4, u.REG2), 1)
	H.ok(H.dist(u.V1, u.REG) >= 3 and H.dist(u.REG, u.V4) >= 3, "pairs at least 3 tiles apart")
	H.eq(#H.promotionTypes(u.V1), 1); H.eq(u.V2:GetDamage(), 20)
	-- merge trace: armed this turn, only for C3 / C9 units
	local n0 = #H.lines("[EFV][Corps] G trace OnUnitMoved", true)
	GameEvents.OnUnitMoved(0, u.V1:GetID())
	H.ok(H.hasLine("[EFV][Corps] G trace OnUnitMoved P0/" .. u.V1:GetID() .. " (C9-V1): C9-V1 P0/" .. u.V1:GetID() .. " alive STANDARD xp "),
		"trace line with every C9 unit")
	GameEvents.OnUnitMoved(1, 999999)
	H.eq(#H.lines("[EFV][Corps] G trace OnUnitMoved", true), n0 + 1, "other units are not traced")
	Dev("corps_vol", { stamp = 112 })
	H.ok(Has(CorpsAns().text, "merge the three pairs now"), CorpsAns().text)
	-- "merges": pair 1 V1 survives, pair 2 REG survives, pair 3 V4 survives
	for _, d in ipairs({ { "V1", "V2" }, { "REG", "V3" }, { "V4", "REG2" } }) do
		u[d[1]]:SetMilitaryFormation(Form("CORPS"))
		Players[0]:GetUnits():Destroy(u[d[2]])
	end
	H.endTurn()
	local n1 = #H.lines("[EFV][Corps] G trace OnUnitMoved", true)
	GameEvents.OnUnitMoved(0, u.V1:GetID())
	H.eq(#H.lines("[EFV][Corps] G trace OnUnitMoved", true), n1, "the trace is off after the turn start")
	Dev("corps_vol", { stamp = 113 })
	local t = CorpsAns().text
	H.ok(Has(t, "pair 1 survived: C9-V1 (C9-V1 P0/" .. u.V1:GetID() .. " CORPS"), t)
	H.ok(Has(t, "C9-V2 P0/" .. u.V2:GetID() .. " FindID nil"), t)
	H.ok(Has(t, "pair 2 survived: C9-REG (") and Has(t, "pair 3 survived: C9-V4 ("), t)
	H.ok(Has(t, "Volunteer record "), t)
	H.ok(not H.hasLine("ERROR"), "no handler error")
end)

test("1.0.4.5 panel: C8 / C9 buttons; C10 cycles off -> ask -> block -> off; popup and Cancel; the blocked click; UI trace", function()
	FreshBoot()
	Dev("scn_setup", { stamp = 1 })
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	for _, w in ipairs({ { "C8 Split a mixed Army (press twice)", "corps_split", "C8 set up" },
		{ "C9 Volunteer merges (again after End Turn)", "corps_vol", "C9 (" } }) do
		local b = FAKE_UI.FindButton(w[1])
		H.notnil(b, w[1])
		b:Click()
		H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, w[2])
		Pump({ panel }, 4)
		local rec = panel.Controls.RecordLabel:GetText()
		H.ok(string.find(rec, w[3], 1, true) == 1 and Has(rec, "[NEWLINE]UI: "), rec)
	end
	H.ok(H.hasLine("[EFV][Corps] UI summary corps_split: C8-B "), "UI reads the C8 units")
	-- C10 mode cycling (UI only: no request)
	local nReq = #FAKE_UI.requests
	local g = FAKE_UI.FindButton("C10 Merge guard off/ask/block")
	H.notnil(g)
	g:Click()
	H.ok(string.find(panel.Controls.RecordLabel:GetText(), "C10 merge guard: ask", 1, true) == 1, panel.Controls.RecordLabel:GetText())
	H.eq(#FAKE_UI.requests, nReq, "C10 sends nothing")
	-- ask: Form Corps with B's lent unit selected
	Dev("corps_merge", { stamp = 90 })
	local lent, own = Named(0, "VEF-C3-LENT"), Named(0, "VEF-C3-OWN")
	InterfaceModeTypes.FORM_CORPS, InterfaceModeTypes.FORM_ARMY = 50, 51
	UnitCommandTypes.FORM_CORPS, UnitCommandResults.UNITS = "FORM_CORPS", "UNITS"
	UnitManager.GetCommandTargets = function(u, cmd)
		if cmd == "FORM_CORPS" and (u == lent or u == own) then return { UNITS = { { player = 0, id = ((u == lent) and own or lent):GetID() } } } end
		return {}
	end
	local mode = 50
	UI.GetInterfaceMode = function() return mode end
	UI.SetInterfaceMode = function(m) mode = m end
	FAKE_UI.selectedUnit = lent
	FAKE_UI.popups = {}
	Events.InterfaceModeChanged(0, 50)
	local pop = FAKE_UI.popups[1]
	H.notnil(pop, "guard popup opened")
	H.eq(pop.id, "EFV_DevMergeGuard")
	H.ok(Has(pop.texts[1], "VEF-C3-LENT P0/" .. lent:GetID() .. " (lent by P1"), pop.texts[1])
	H.ok(not Has(pop.texts[1], "VEF-C3-OWN P0"), "the host's own unit is not listed")
	pop.cancel()
	H.eq(mode, InterfaceModeTypes.SELECTION, "Cancel leaves the mode")
	H.ok(H.hasLine("[EFV][Corps] UI guard FORM_CORPS Cancel: SetInterfaceMode(SELECTION) ok=true, mode now SELECTION"))
	-- block: the click on a VEF unit's plot is swallowed, another plot passes
	g:Click()
	H.ok(string.find(panel.Controls.RecordLabel:GetText(), "C10 merge guard: block", 1, true) == 1)
	MouseEvents = { LButtonUp = 9 }
	mode = 50
	local cursor = Map.GetPlot(lent:GetX(), lent:GetY()):GetIndex()
	UI.GetCursorPlotID = function() return cursor end
	local click = { GetMessageType = function() return MouseEvents.LButtonUp end }
	H.eq(panel.ContextPtr.inputHandler(click), true, "click on the lent unit swallowed")
	H.ok(H.hasLine("[EFV][Corps] UI guard click blocked at " .. lent:GetX() .. "," .. lent:GetY()))
	H.ok(Has(panel.Controls.RecordLabel:GetText(), "C10: click blocked at"), panel.Controls.RecordLabel:GetText())
	cursor = Map.GetPlot(own:GetX(), own:GetY()):GetIndex()
	H.eq(panel.ContextPtr.inputHandler(click), false, "a click on your own unit passes")
	mode = InterfaceModeTypes.SELECTION
	cursor = Map.GetPlot(lent:GetX(), lent:GetY()):GetIndex()
	H.eq(panel.ContextPtr.inputHandler(click), false, "outside Form Corps every click passes")
	-- off: nothing swallowed, no popup
	g:Click()
	H.ok(string.find(panel.Controls.RecordLabel:GetText(), "C10 merge guard: off", 1, true) == 1)
	mode = 50
	H.eq(panel.ContextPtr.inputHandler(click), false, "guard off: nothing swallowed")
	FAKE_UI.popups = {}
	Events.InterfaceModeChanged(0, 50)
	H.eq(#FAKE_UI.popups, 0, "guard off: no popup")
	-- UI merge trace (C3 armed it this turn)
	Events.UnitFormCorps(0, own:GetID())
	H.ok(H.hasLine("[EFV][Corps] UI trace UnitFormCorps P0/" .. own:GetID() .. " (C3-OWN): "), "UI trace line")
	H.ok(H.hasLine("C3-LENT P0/" .. lent:GetID() .. " alive STANDARD xp "), "every C3 unit listed")
	H.ok(not H.hasLine("corps spike error") and not H.hasLine("merge guard input error") and not H.hasLine("guard ERROR"))
	MouseEvents = nil
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.5.1: the VEF 1.0.5 test (FIXPLAN_proxy_war.md B5,
-- EFV/TESTING_1.0.5.md). FreshBoot: B = P1 (capital a 2-turn trip from
-- yours), E = P2, X = P3.
-- ---------------------------------------------------------------------------
local function ProxyAns() return H.prop("EFV_DEV_SCN").proxy.ans end

local function ProxyBoot(opts)
	local S = FreshBoot(opts)
	Dev("scn_proxy", { stamp = 1 })
	H.ok(CheckLine("PROXY_P1", "PASS"), "P1 passes")
	H.markBody()
	return S
end

test("1.0.5.1 P1: roles (B band 2, E and X at war with B), friend + open borders, three Swordsmen, no S0 war, answer text", function()
	local S = FreshBoot()
	Dev("scn_proxy", { stamp = 7 })
	H.ok(CheckLine("PROXY_P1", "PASS"))
	local st = H.prop("EFV_DEV_SCN")
	H.eq(st.proxy.b, 1); H.eq(st.proxy.e, 2); H.eq(st.proxy.x, 3); H.eq(st.proxy.band, 2)
	H.eq(st.proxy.fee, EFV_Fee("UNIT_SWORDSMAN", "EXPEDITIONARY", 2))
	H.eq(st.me, 0); H.eq(st.ally, 1); H.isnil(st.enemy); H.isnil(st.friend); H.isnil(st.cs)
	H.ok(Players[1]:GetDiplomacy():IsAtWarWith(2) and Players[1]:GetDiplomacy():IsAtWarWith(3), "B at war with E and X")
	for _, pid in ipairs({ 1, 2, 3, 4 }) do H.ok(not FAKE.PairGet(FAKE.diplo.war, 0, pid), "you at peace with P" .. pid) end
	H.eq(EFV_PartnerBasis(0, 1), "FRIEND"); H.eq(EFV_VolunteerBasis(0, 1), "FRIEND_OB")
	for i = 1, 3 do
		local u = Named(0, "VEF-PROXY-" .. i)
		H.notnil(u, "VEF-PROXY-" .. i)
		H.eq(u:GetMovesRemaining(), u:GetMaxMoves(), "full moves")
		H.eq(Map.GetPlot(u:GetX(), u:GetY()):GetOwner(), 0, "on your land")
	end
	local lim = GameInfo.GlobalParameters["DIPLOMACY_DENOUNCE_TIME_LIMIT"].Value
	local t = ProxyAns().text
	H.eq(ProxyAns().stamp, 7)
	H.ok(string.find(t, "P1: B=P1 (friend, open borders, trip 2 turns, fee " .. st.proxy.fee .. "), E=P2 and X=P3 at war with B; you at war with nobody: yes; Expeditionary to B NO_COMMON_WAR, Volunteers to B NO_COMMON_WAR", 1, true) == 1, t)
	H.ok(Has(t, "denounce limit in the game data " .. tostring(lim)), t)
	H.eq(st.focus.u, Named(0, "VEF-PROXY-1"):GetID(), "VEF-PROXY-1 selected")
	H.clean()
end)

test("1.0.5.1 P1 refusals: after S0, at war with someone, too few civs, twice -> CHECK, nothing made", function()
	Setup()
	Dev("scn_proxy", { stamp = 2 })
	H.ok(CheckLine("PROXY_P1", "CHECK")); H.ok(Has(ProxyAns().text, "S0 ran in this game"))
	H.isnil(Named(0, "VEF-PROXY-1"))
	for k in pairs(FAKE.props) do FAKE.props[k] = nil end   -- a new game
	for k in pairs(FAKE.diplo) do FAKE.diplo[k] = {} end
	FreshBoot()
	H.war(0, 4)
	Dev("scn_proxy", { stamp = 3 })
	H.ok(CheckLine("PROXY_P1", "CHECK")); H.ok(Has(ProxyAns().text, "you are at war with P4"), ProxyAns().text)
	H.isnil(Named(0, "VEF-PROXY-1"))
	for k in pairs(FAKE.props) do FAKE.props[k] = nil end
	for k in pairs(FAKE.diplo) do FAKE.diplo[k] = {} end
	FreshBoot()
	H.kill(3)
	Dev("scn_proxy", { stamp = 4 })
	H.ok(CheckLine("PROXY_P1", "CHECK")); H.ok(Has(ProxyAns().text, "needs 3 other civs"), ProxyAns().text)
	H.isnil(H.prop("EFV_DEV_SCN").proxy.b)
	for k in pairs(FAKE.props) do FAKE.props[k] = nil end
	for k in pairs(FAKE.diplo) do FAKE.diplo[k] = {} end
	ProxyBoot()
	Dev("scn_proxy", { stamp = 5 })
	H.ok(Has(ProxyAns().text, "P1 already ran"), ProxyAns().text)
	local n = 0
	for _, u in ipairs(H.unitsOf(0, "UNIT_SWORDSMAN")) do if u.vetName == "VEF-PROXY-1" then n = n + 1 end end
	H.eq(n, 1, "no second set")
end)

test("1.0.5.1 P1 band preference: a band-2 capital wins over a lower-ID band-1 one", function()
	H.world({ turn = 2 })
	FAKE.NewPlayer(5, { gold = 1000 })
	H.city(0, 10, 10, { capital = true })
	H.city(1, 14, 10, { capital = true })
	H.city(2, 40, 30, { capital = true })
	H.city(3, 70, 40, { capital = true })
	H.city(5, 22, 10, { capital = true })
	H.loadEFV()
	FAKE.dofile("EFV_Dev/Scripts/EFV_Dev_Gameplay.lua")
	H.eq(EFV_Band(10, 10, 14, 10), 1); H.eq(EFV_Band(10, 10, 22, 10), 2)
	Dev("scn_proxy", { stamp = 1 })
	local P = H.prop("EFV_DEV_SCN").proxy
	H.eq(P.b, 5); H.eq(P.band, 2); H.eq(P.e, 1); H.eq(P.x, 2)
end)

test("1.0.5.1 P Status and PROXY_WATCH: states, wars, the send rule (proxy war after a denouncement), 12 turns of watch lines", function()
	ProxyBoot()
	Dev("proxy_status", { stamp = 9 })
	H.ok(string.find(ProxyAns().text, "P T2: you-E NEUTRAL, you-X NEUTRAL; B at war with E yes, X yes; you at war with E no, X no; Expeditionary to B NO_COMMON_WAR, Volunteers to B NO_COMMON_WAR; B gold 1000; your records: none", 1, true) == 1, ProxyAns().text)
	H.denounce(0, 2)
	Dev("proxy_status", { stamp = 10 })
	H.ok(Has(ProxyAns().text, "you-E DENOUNCED") and Has(ProxyAns().text, "Expeditionary to B ok (proxy war against P2), Volunteers to B NO_COMMON_WAR"), ProxyAns().text)
	H.turns(14)
	H.len(H.lines("[EFV][CHECK] PROXY_WATCH INFO"), 12, "turns 3 to 14")
	H.ok(not H.hasLine("ERROR evaluate"))
end)

test("1.0.5.1 P3: the target is X, else E (when X denounced you); opinion pushed to -30", function()
	ProxyBoot()
	Dev("proxy_lower", { stamp = 11 })
	H.eq(FAKE.diplo.score[3][0], -30)
	H.ok(Has(ProxyAns().text, "P3: P3's opinion of you 0 -> -30; End Turn until P3 denounces you"), ProxyAns().text)
	H.denounce(3, 0)
	Dev("proxy_lower", { stamp = 12 })
	H.eq(FAKE.diplo.score[2][0], -30, "E now")
	H.ok(Has(ProxyAns().text, "P3: P2's opinion"), ProxyAns().text)
	H.denounce(2, 0)
	Dev("proxy_lower", { stamp = 13 })
	H.ok(CheckLine("PROXY_P3", "CHECK"))
end)

test("1.0.5.1 P4: the newest outbound record arrives 8 turns from now", function()
	local S = ProxyBoot()
	Dev("proxy_hold", { stamp = 14 })
	H.ok(CheckLine("PROXY_P4", "CHECK"), "nothing on its way yet")
	H.denounce(0, 2)
	H.send(0, Named(0, "VEF-PROXY-1"), 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.records()[1]
	H.eq(r.state, "OUTBOUND")
	Dev("proxy_hold", { stamp = 15 })
	r = H.records()[1]
	H.eq(r.arrivalTurn, FAKE.turn + 8)
	H.eq(ProxyAns().text, "P4: VEF-PROXY-1 (record " .. r.id .. ") now arrives on turn " .. (FAKE.turn + 8))
	H.clean()
end)

test("1.0.5.1 P5: press 1 makes VEF-UPKEEP; press 2 without the send -> CHECK; after the send it arrives next turn and B's gold is 0", function()
	local S = ProxyBoot()
	Dev("proxy_poor", { stamp = 16 })
	local u = Named(0, "VEF-UPKEEP")
	H.notnil(u); H.eq(GameInfo.Units[u:GetType()].UnitType, "UNIT_MODERN_AT")
	H.eq(u:GetMovesRemaining(), u:GetMaxMoves())
	H.ok(Has(ProxyAns().text, "send it to B as Expeditionary, then press P5 again"))
	Dev("proxy_poor", { stamp = 17 })
	H.ok(CheckLine("PROXY_P5", "CHECK")); H.ok(Has(ProxyAns().text, "send VEF-UPKEEP first"))
	H.denounce(0, 2)
	H.send(0, u, 1, S.c1, "EXPEDITIONARY", 999)
	local r = H.records()[1]
	Dev("proxy_poor", { stamp = 18 })
	H.eq(H.records()[1].arrivalTurn, FAKE.turn + 1)
	H.eq(H.gold(1), 0)
	H.eq(ProxyAns().text, "P5: VEF-UPKEEP (record " .. r.id .. ") arrives for B next turn; B's gold now 0 (was 1000)")
	H.endTurn()
	H.eq(H.records()[1].state, "DEPLOYED")
	H.ok(H.hasLine("VEF-UPKEEP (record " .. r.id .. "): DEPLOYED, unit on the map, B gold"), "PROXY_WATCH follows it")
end)

test("1.0.5.1 A9: carrier and plane apart (send rule without CARRIER_LOADED); plane moved aboard -> CARRIER_LOADED", function()
	ProxyBoot()
	for _, xy in ipairs({ { 9, 10 }, { 8, 10 }, { 8, 11 }, { 9, 11 }, { 7, 10 }, { 7, 11 }, { 6, 10 }, { 6, 11 } }) do H.terrain(xy[1], xy[2], "COAST") end
	Dev("air_rebase", { stamp = 19 })
	H.ok(CheckLine("AIR_A9", "INFO"))
	local cv, pl = Named(0, "VEF-CV9"), Named(0, "VEF-AIR-9")
	H.notnil(cv); H.notnil(pl)
	H.ok(not (cv.x == pl.x and cv.y == pl.y), "not on the carrier's tile")
	H.ok(H.dist(cv, pl) >= 2 and H.dist(cv, pl) <= 3)
	local t = AirAns().text
	H.ok(Has(t, "carrier send rule now:") and not Has(t, "CARRIER_LOADED") and Has(t, "Rebase VEF-AIR-9 onto VEF-CV9"), t)
	H.moveUnit(pl, cv.x, cv.y)
	Dev("air_rebase", { stamp = 20 })
	t = AirAns().text
	H.ok(Has(t, "plane on the carrier's tile yes") and Has(t, "CARRIER_LOADED"), t)
	H.eq(H.prop("EFV_DEV_SCN").focus.u, cv:GetID(), "carrier selected")
	H.ok(not H.hasLine("ERROR"))
end)

test("1.0.5.1 modinfo: Data/EFV_Dev_Denounce.xml in an UpdateDatabase action and in Files, value 3", function()
	local mi = __py_read("EFV_Dev/EFV_Dev.modinfo")
	H.ok(Has(mi, '<UpdateDatabase id="EFV_DEV_Denounce" criteria="EFV_DEV_XP2">'))
	local _, n = string.gsub(mi, "<File>Data/EFV_Dev_Denounce.xml</File>", "")
	H.eq(n, 2, "action and Files")
	H.ok(Has(mi, "Requires Volunteers &amp; Expeditionary Forces (VEF) 1.0.5."))
	local x = __py_read("EFV_Dev/Data/EFV_Dev_Denounce.xml")
	H.ok(Has(x, '<Replace Name="DIPLOMACY_DENOUNCE_TIME_LIMIT" Value="3"/>'), x)
end)

test("1.0.5.1 panel: the P buttons and A9 send their commands; P2's three verdicts; the session line names B, E and X", function()
	FreshBoot()
	local panel = PanelUI()
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	FAKE_UI.FindButton("P1 Proxy war setup"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, "scn_proxy")
	Pump({ panel }, 4)
	local rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "P1: B=P1", 1, true) == 1 and Has(rec, "[NEWLINE]UI: B=") and Has(rec, "denounce limit "), rec)
	H.ok(Has(rec, "E: never denounced"), rec)
	FAKE_UI.FindButton("P Status"):Click()
	H.ok(Has(panel.Controls.InfoLabel:GetText(), "Proxy test: B="), panel.Controls.InfoLabel:GetText())
	for _, w in ipairs({ { "P Status", "proxy_status" }, { "P3 X dislikes you (if P2 fails)", "proxy_lower" },
			{ "P4 Hold the unit on its way", "proxy_hold" }, { "P5 Poor host (press twice)", "proxy_poor" },
			{ "A9 Carrier for a rebase (press twice)", "air_rebase" } }) do
		FAKE_UI.FindButton(w[1]):Click()
		H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, w[2], w[1])
		Pump({ panel }, 4)
	end
	local verdicts = { INITIATOR = "P2: X denounced you on turn 2", LOCAL = "P2: WRONG WAY: the game made you denounce X",
		IGNORE = "P2: nothing happened: press P3" }
	for _, mode in ipairs({ "IGNORE", "LOCAL", "INITIATOR" }) do
		FAKE.diplo.denounced, FAKE.diplo.denounceTurn = {}, {}
		FAKE.requestSessionMode = mode
		FAKE.diploSessions = {}
		FAKE_UI.requests = {}
		FAKE_UI.FindButton("P2 X denounces you"):Click()
		H.len(FAKE_UI.requests, 0, "P2 sends no request at once")
		H.eq(FAKE.diploSessions[1].a, 3); H.eq(FAKE.diploSessions[1].b, 0); H.eq(FAKE.diploSessions[1].kind, "DENOUNCE")
		Pump({ panel }, 8)
		rec = panel.Controls.RecordLabel:GetText()
		H.ok(string.find(rec, verdicts[mode], 1, true) == 1, mode .. ": " .. rec)
	end
	H.ok(Has(rec, "X: denounced you on T2"), rec)
	H.ok(not H.hasLine("proxy test error"))
end)

-- ---------------------------------------------------------------------------
-- EFV_Dev 1.0.5.2: the upgrade spike U1 (FIXPLAN_upgrade_relink.md U6,
-- EFV/TESTING_1.0.5.md). After P1 (B = st.proxy.b) or S0 (B = st.ally).
-- ---------------------------------------------------------------------------
local function UpgAns() return H.prop("EFV_DEV_SCN").upg.ans end

-- A free tile of pid's land next to u (the designer's one-tile move).
local function OwnFreeNeighbor(u, pid)
	for _, p in ipairs(Map.GetNeighborPlots(u.x, u.y, 1)) do
		if H.dist(p, u) == 1 and p.owner == pid and not p:IsWater() and not p:IsImpassable() and p:GetUnitCount() == 0
				and CityManager.GetCityAt(p.x, p.y) == nil then
			return p
		end
	end
	return nil
end

local function U1Press1()
	Dev("upg_spike", { stamp = 30 })
	H.ok(CheckLine("UPG_U1", "PASS"), "press 1 passes")
	return Named(0, "VEF-U1-M"), Named(0, "VEF-U1-S")
end

test("1.0.5.2 U1 after P1: press 1 lends you two Warriors from B in your land, Ram 2 tiles away, grants, answer", function()
	ProxyBoot()
	FAKE.supportFormation = -1
	local gold = H.gold(0)
	local m, s = U1Press1()
	local up = H.prop("EFV_DEV_SCN").upg
	H.eq(up.b, 1, "B from P1"); H.eq(up.step, 1); H.eq(up.from, "UNIT_WARRIOR"); H.eq(up.to, "UNIT_SWORDSMAN")
	H.notnil(m); H.notnil(s)
	H.eq(m.typeName, "UNIT_WARRIOR"); H.eq(s.typeName, "UNIT_WARRIOR")
	for _, u in ipairs({ m, s }) do H.eq(Map.GetPlot(u.x, u.y):GetOwner(), 0, "in your land") end
	H.ok(H.dist(m, s) >= 2, "at least 2 tiles apart")
	H.eq(#H.promotionTypes(m), 1, "one promotion"); H.eq(m.damage, 30); H.eq(m.moves, m.maxMoves + 2, "2 extra moves")
	H.eq(#H.promotionTypes(s), 0); H.eq(s.damage, 0); H.eq(s.moves, s.maxMoves)
	H.notnil(OwnFreeNeighbor(m, 0), "a free tile of yours next to VEF-U1-M")
	local r, b = Named(0, "VEF-U1-R"), Named(0, "VEF-U1-B")
	H.eq(r.typeName, "UNIT_BATTERING_RAM"); H.eq(b.typeName, "UNIT_BUILDER")
	H.eq(H.dist(r, m), 2, "Ram exactly 2 tiles from VEF-U1-M")
	H.eq(up.ram.f, "-1"); H.eq(up.bld.f, "0")
	local recs = H.records()
	H.len(recs, 2)
	for i, u in ipairs({ m, s }) do
		local rec = recs[i]
		H.eq(rec.forceType, "EXPEDITIONARY"); H.eq(rec.senderID, 1); H.eq(rec.recipientID, 0)
		H.eq(rec.onMapPlayerID, 0); H.eq(rec.onMapUnitID, u.id); H.eq(rec.state, "DEPLOYED")
	end
	H.eq(H.records()[1].experience, m.xp, "the record has VEF-U1-M's XP")
	H.eq(H.gold(0), gold + 3000)
	H.ok(H.res(0, "RESOURCE_IRON") >= 40, "Iron for two Swordsman upgrades")
	local t = UpgAns().text
	H.ok(string.find(t, "U1: B=P1; VEF-U1-M (record 1, UNIT_WARRIOR, xp ", 1, true) == 1, t)
	H.ok(Has(t, "both lent to you by B") and not Has(t, "NOT BOTH") and Has(t, "Ram formation -1, Builder formation 0"), t)
	H.ok(Has(t, "RESOURCE_IRON +50") and Has(t, "one upgrade needs 20"), t)
	H.ok(Has(t, "move VEF-U1-M one tile inside your borders, then Upgrade it; Upgrade VEF-U1-S without moving it; then press U1 again"), t)
	H.ok(H.hasLine("[EFV][Upg] G U1 press 1: VEF-U1-M P0/" .. m.id), "press 1 line")
	H.eq(H.prop("EFV_DEV_SCN").focus.u, m.id, "VEF-U1-M selected")
	H.clean()
end)

test("1.0.5.2 U1: move then upgrade, upgrade in place; trace, press 2 (moves left), turn-start line, press 3 answers", function()
	ProxyBoot({ flags = { FLAG_UPGRADE_CREATE_HOOK = true } })   -- F2 ships off (spike U6); this test covers it on
	FAKE.supportFormation = -1
	FAKE.upgradeEvents = "ghost"
	FAKE.upgradeGhostOffMap = true   -- the old object goes off the map (final session L479)
	local m, s = U1Press1()
	local mOld, sOld = m.id, s.id
	local to = OwnFreeNeighbor(m, 0)
	H.move(m, to.x, to.y)
	H.ok(H.hasLine("[EFV][Upg] G OnUnitMoved #1 P0/" .. mOld), "the move is traced")
	H.ok(H.hasLine("= VEF-U1-M (old unit); VEF-U1-M P0/" .. mOld .. ": live at " .. to.x .. "," .. to.y), "old unit live on its new tile")
	local nm = H.upgrade(m, "UNIT_SWORDSMAN")
	local ns = H.upgrade(s, "UNIT_SWORDSMAN")
	H.ok(H.hasLine("[EFV][Upg] G UnitCreated #2 P0/" .. nm.id), "UnitCreated traced")
	H.ok(H.hasLine("= VEF-U1-M (new unit)"), "matched by tile")
	H.ok(H.hasLine("[EFV][Upg] G UnitInitialized #5 P0/" .. ns.id), "UnitInitialized of the second upgrade")
	Dev("upg_spike", { stamp = 31 })
	local t = UpgAns().text
	H.ok(string.find(t, "U1 press 2 (T2): VEF-U1-M: record 1 DEPLOYED", 1, true) == 1, t)
	H.ok(Has(t, "; new (trace) P0/" .. nm.id) and Has(t, "moves left 0/2"), t)
	H.ok(Has(t, "old P0/" .. mOld .. " ghost (GONE_OFFMAP) at -9999,-9999 dmg 30"), t)
	H.ok(Has(t, "VEF-U1-M: record 1 DEPLOYED unit=" .. nm.id .. " type=UNIT_SWORDSMAN last=" .. to.x .. "," .. to.y .. " (follows the new unit)"), t)
	H.ok(Has(t, "VEF-U1-S: record 2 DEPLOYED unit=" .. ns.id .. " type=UNIT_SWORDSMAN"), t)
	H.ok(Has(t, "Now End Turn, then press U1 a third time"), t)
	H.eq(H.prop("EFV_DEV_SCN").upg.step, 2)
	H.endTurn()
	H.ok(CheckLine("UPG_SPIKE", "INFO"), "turn-start line")
	H.ok(H.hasLine("(at your turn start; press U1 for the same line)"))
	Dev("upg_spike", { stamp = 32 })
	t = UpgAns().text
	H.ok(Has(t, "Q-A OnUnitMoved for the old units: M 1, S 0"), t)
	H.ok(Has(t, "Q-B events about the new units: M UnitCreated #2 UnitInitialized #3 Events.UnitUpgraded no, S UnitCreated #4 UnitInitialized #5"), t)
	H.ok(Has(t, "Q-C old unit at the first of them: M ghost (GONE_OFFMAP) at -9999,-9999 dmg 30, S ghost (GONE_OFFMAP) at -9999,-9999 dmg 0"), t)
	H.ok(string.find(t, "U1 T3 VEF: VEF-U1-M record 1 DEPLOYED unit=" .. nm.id .. " type=UNIT_SWORDSMAN", 1, true) == 1, t)
	H.ok(Has(t, "= the upgraded unit; VEF-U1-S record 2 DEPLOYED unit=" .. ns.id), t)
	H.len(H.notifs(0, "EFV_NOTIF_MERGED"), 0, "no merge misread from the Ram")
	H.ok(Has(t, "Q-D moves left on the new units (press 2): M 0/2, S 0/2; OnUnitMoved for the new units: M 0, S 0"), t)
	H.ok(Has(t, "Q-E xp/promotions/damage old -> new: M " .. nm.xp .. "/1/30 -> " .. nm.xp .. "/1/30, S 0/0/0 -> 0/0/0"), t)
	H.ok(Has(t, "Q-F formations: Ram -1, Builder 0 (STANDARD 0)"), t)
	H.ok(Has(t, "Q-G new serials above 2: M 2 no, S 2 no"), t)
	H.eq(H.prop("EFV_DEV_SCN").upg.step, 3)
	H.ok(not H.hasLine("[EFV][Upg] G OnUnitMoved #6"), "no trace after the press-1 turn")
	H.clean()
end)

test("1.0.5.2 U1 after S0: B is S0's B; without a session -> CHECK, nothing made", function()
	FreshBoot()
	Dev("upg_spike", { stamp = 40 })
	H.ok(CheckLine("UPG_U1", "CHECK")); H.ok(Has(UpgAns().text, "press P1 (or S0) first"))
	H.isnil(Named(0, "VEF-U1-M"))
	H.len(H.records(), 0)
	Dev("scn_setup", { stamp = 41 })
	H.markBody()
	local m = U1Press1()
	H.notnil(m)
	H.eq(H.prop("EFV_DEV_SCN").upg.b, H.prop("EFV_DEV_SCN").ally, "B = S0's B")
	H.eq(H.records()[1].senderID, 1)
	H.clean()
end)

test("1.0.5.2 panel: U1 sends upg_spike; the answer, the UI's Upgrade check and the UI Events.UnitUpgraded trace", function()
	FreshBoot()
	Dev("scn_proxy", { stamp = 1 })
	local panel = PanelUI()
	UnitCommandTypes.UPGRADE, UnitCommandResults.UNIT_TYPE = "UPGRADE", "UNIT_TYPE"
	local base = UnitManager.CanStartCommand
	UnitManager.CanStartCommand = function(u, cmd, bTest, bResults)
		if cmd == "UPGRADE" then return u.moves > 0, { UNIT_TYPE = GameInfo.Units["UNIT_SWORDSMAN"].Index } end
		return base(u, cmd, bTest, bResults)
	end
	FAKE_UI.KeyTo(panel, Keys.D, { ctrl = true, shift = true })
	FAKE_UI.FindButton("U1 Upgrade spike (press 1, 2, 3)"):Click()
	H.eq(FAKE_UI.requests[#FAKE_UI.requests].params.cmd, "upg_spike")
	Pump({ panel }, 4)
	local rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "U1: B=P1", 1, true) == 1, rec)
	H.ok(Has(rec, "[NEWLINE]UI: Upgrade VEF-U1-M yes -> UNIT_SWORDSMAN, VEF-U1-S yes -> UNIT_SWORDSMAN"), rec)
	H.ok(H.hasLine("[EFV][Upg] UI press 1 Upgrade button: VEF-U1-M yes"))
	local m = Named(0, "VEF-U1-M")
	local nm = H.upgrade(m, "UNIT_SWORDSMAN")
	Events.UnitUpgraded(0, nm.id, nm.typeIndex)
	H.ok(H.hasLine("[EFV][Upg] UI Events.UnitUpgraded P0/" .. nm.id .. " upgradeType=" .. nm.typeIndex .. " P0/" .. nm.id), "UI trace")
	H.ok(H.hasLine("[EFV][Upg] G Events.UnitUpgraded #1 P0/" .. nm.id), "gameplay trace of the same event")
	FAKE_UI.FindButton("U1 Upgrade spike (press 1, 2, 3)"):Click()
	Pump({ panel }, 4)
	rec = panel.Controls.RecordLabel:GetText()
	H.ok(string.find(rec, "U1 press 2 (T2)", 1, true) == 1 and not Has(rec, "UI: Upgrade"), rec)
	H.ok(not H.hasLine("upgrade spike error"))
end)

test("1.0.5.2 U1 at turn 2 (capital owns only ring 1, P1's Swordsmen on it): they move to neutral land, both U1 units fit in your land", function()
	local S = FreshBoot()
	for _, p in ipairs(Map.GetNeighborPlots(S.c0.x, S.c0.y, 2)) do
		if H.dist(p, S.c0) == 2 then p.owner = -1 end
	end
	Dev("scn_proxy", { stamp = 1 })
	H.ok(CheckLine("PROXY_P1", "PASS"))
	H.markBody()
	local m, s = U1Press1()
	for _, u in ipairs({ m, s }) do H.eq(Map.GetPlot(u.x, u.y):GetOwner(), 0, "in your land") end
	H.notnil(OwnFreeNeighbor(m, 0), "a free tile of yours next to VEF-U1-M")
	H.ok(Has(UpgAns().text, "idle test Swordsmen moved out of your land"), UpgAns().text)
	for i = 1, 3 do
		local u = Named(0, "VEF-PROXY-" .. i)
		H.ok(H.dist(u, S.c0) >= 3, "VEF-PROXY-" .. i .. " placed away")
	end
	H.clean()
end)
