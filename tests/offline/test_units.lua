-- @harness native
-- EFV_Units (spec 13.5, SPIKES S10): snapshot, silent removal, recreation
-- with promotions / XP / damage / veteran name, zero moves, pending exhaust.

local function Veteran(pid, x, y)
	return H.unit(pid, "UNIT_SWORDSMAN", x, y, {
		xp = 30, damage = 25, vet = "Brutus", promotions = { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" },
	})
end

test("Snapshot captures type, XP, next level, promotions, damage, name, position", function()
	H.world{}
	H.loadEFV()
	local u = Veteran(0, 5, 6)
	local s = EFV_Units.Snapshot(u)
	H.eq(s.unitType, "UNIT_SWORDSMAN")
	H.eq(s.experience, 30); H.eq(s.xpNext, 90); H.eq(s.damage, 25)
	H.eq(s.veteranName, "Brutus"); H.eq(s.level, 3); H.eq(s.formation, 0)
	H.eq(s.lastX, 5); H.eq(s.lastY, 6)
	local promos = {}
	for i, p in ipairs(s.promotions) do promos[i] = p end
	table.sort(promos)
	H.deq(promos, { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" })
	H.isnil(EFV_Units.Snapshot(nil))
	H.ok(H.hasLine("[Snapshot]"))
end)

test("Snapshot of an unnamed unit has no veteran name", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Units.Snapshot(H.unit(0, "UNIT_WARRIOR", 1, 1))
	H.ok(s.veteranName == nil or s.veteranName == "", "nil or empty")
	H.deq(s.promotions, {})
end)

test("ApplySnapshot copies fields and sets snapTurn", function()
	H.world{ turn = 12 }
	H.loadEFV()
	local rec = { id = 1 }
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(Veteran(0, 5, 6)), 12)
	H.eq(rec.snapTurn, 12); H.eq(rec.unitType, "UNIT_SWORDSMAN"); H.eq(rec.experience, 30)
	H.eq(#rec.promotions, 2)
end)

test("Remove destroys silently (FLAG_REMOVE_API=DESTROY) and KILL variant", function()
	H.world{}
	H.loadEFV()
	local u = H.unit(0, "UNIT_WARRIOR", 3, 3)
	H.ok(EFV_Units.Remove(u))
	H.ok(not H.unitAlive(u))
	H.eq(FAKE.killLog[#FAKE.killLog].how, "DESTROY")
	EFV_Config.FLAG_REMOVE_API = "KILL"
	local v = H.unit(0, "UNIT_WARRIOR", 3, 4)
	H.ok(EFV_Units.Remove(v))
	H.eq(FAKE.killLog[#FAKE.killLog].how, "KILL")
	H.ok(not EFV_Units.Remove(nil))
end)

test("Recreate restores promotions, XP, damage, name; 0 moves; pending entry", function()
	H.world{ turn = 5 }
	H.loadEFV()
	local rec = { id = 3 }
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(Veteran(0, 5, 6)), 5)
	local store = EFV_Records.Load()
	local u = EFV_Units.Recreate(store, 1, rec, H.plot(20, 20), 5)
	H.notnil(u)
	H.eq(u:GetOwner(), 1); H.eq(u:GetX(), 20); H.eq(u:GetY(), 20)
	H.deq(H.promotionTypes(u), { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" })
	-- Session F T08 (engine model in the fake): promotions are restored first,
	-- the level is not (a created unit stays level 1, threshold 15), XP is
	-- capped by the engine at 15 and FLAG_XP_CLAMP (default on since 0.5.2)
	-- takes it to 14: no free promotion on arrival.
	H.eq(u:GetExperience():GetExperiencePoints(), 14, "XP clamped to next - 1")
	H.eq(u:GetExperience():GetExperienceForNextLevel(), 15, "the level resets (T08)")
	H.ok(u:GetExperience():GetExperiencePoints() <= u:GetExperience():GetExperienceForNextLevel() - 1)
	H.ok(not u:GetExperience():CanPromote(), "no pending promotion")
	H.ok(H.hasLine("clamped=1"), "the clamp is logged")
	H.eq(u:GetDamage(), 25)
	H.eq(u:GetExperience():GetVeteranName(), "Brutus")
	H.eq(u:GetMovesRemaining(), 0, "FinishMoves on creation")
	H.eq(u:GetMilitaryFormation(), 0, "formation never restored (D3)")
	H.len(store.pending, 1)
	H.eq(store.pending[1].p, 1); H.eq(store.pending[1].u, u:GetID()); H.eq(store.pending[1].t, 5)
	H.clean()
end)

test("Recreate with FLAG_XP_CLAMP off (pre-0.5.2): XP stays at the engine cap with a promotion pending", function()
	H.world{ turn = 5 }
	H.loadEFV{ flags = { FLAG_XP_CLAMP = false } }
	local rec = { id = 3 }
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(Veteran(0, 5, 6)), 5)
	local u = EFV_Units.Recreate(EFV_Records.Load(), 1, rec, H.plot(20, 20), 5)
	H.eq(u:GetExperience():GetExperiencePoints(), 15, "engine cap (T08)")
	H.ok(u:GetExperience():CanPromote(), "a free promotion: why the clamp is on")
	H.ok(H.hasLine("xp capped by the engine"))
	H.clean()
end)

test("default config: FLAG_XP_CLAMP and FLAG_UPGRADE_RELINK are on (Session F T08, T30)", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_Config.FLAG_XP_CLAMP, true)
	H.eq(EFV_Config.FLAG_UPGRADE_RELINK, true)
	H.eq(EFV_Config.LEVY_RELINK_MAX_DIST, 2)
end)

test("Recreate with FLAG_CREATE_API=INITUNIT", function()
	H.world{}
	H.loadEFV{ flags = { FLAG_CREATE_API = "INITUNIT" } }
	local rec = { id = 1 }
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(Veteran(0, 5, 6)), 1)
	local u = EFV_Units.Recreate(EFV_Records.Load(), 2, rec, H.plot(9, 9), 1)
	H.notnil(u); H.eq(u:GetOwner(), 2)
	H.eq(#H.promotionTypes(u), 2)
end)

test("Recreate skips unknown promotion types (logged) and still creates the unit", function()
	H.world{}
	H.loadEFV()
	local rec = { id = 1, unitType = "UNIT_SWORDSMAN", damage = 0, experience = 5, xpNext = 30, level = 2,
		promotions = { "PROMOTION_DOES_NOT_EXIST", "PROMOTION_BATTLECRY" }, formation = 0 }
	local u = EFV_Units.Recreate(EFV_Records.Load(), 0, rec, H.plot(9, 9), 1)
	H.notnil(u)
	H.deq(H.promotionTypes(u), { "PROMOTION_BATTLECRY" })
end, { allowErrors = true })

test("ExhaustPending zeroes moves for this player's fresh units only", function()
	H.world{ turn = 5 }
	H.loadEFV()
	local store = EFV_Records.Load()
	local a = H.unit(1, "UNIT_WARRIOR", 1, 1)
	local b = H.unit(2, "UNIT_WARRIOR", 2, 2)
	EFV_Records.AddPending(store, 1, a.id, 5)
	EFV_Records.AddPending(store, 2, b.id, 5)
	EFV_Units.ExhaustPending(store, 1)
	H.eq(a:GetMovesRemaining(), 0)
	H.ne(b:GetMovesRemaining(), 0, "other player untouched")
	H.len(store.pending, 1)
	H.ok(H.hasLine("[Exhaust]"))
end)

test("PlayerTurnStartComplete hook exhausts units created by the pipeline", function()
	H.world{ turn = 5 }
	H.loadEFV()
	local store = EFV_Records.Load()
	local a = H.unit(1, "UNIT_WARRIOR", 1, 1)
	EFV_Records.AddPending(store, 1, a.id, 6)
	EFV_Records.Commit(store)
	FAKE.turn = 6
	a.moves = 2                             -- engine restored moves at turn start
	GameEvents.PlayerTurnStartComplete(1)
	H.eq(a:GetMovesRemaining(), 0)
	H.len(EFV_Records.Load().pending, 0, "entry consumed and committed")
	H.clean()
end)

-- 0.7 (FIXPLAN_0.7 item 9 hardening): the veteran name is set right after
-- Create, before promotions, XP, damage and FinishMoves, so later changes
-- carry it to the UI copy of the unit.
test("Recreate sets the veteran name first (before promotions, XP, damage, moves)", function()
	H.world{ turn = 5 }
	H.loadEFV{ flags = { FLAG_CREATE_API = "INITUNIT" } }
	local calls = {}
	local initUnit = UnitManager.InitUnit
	UnitManager.InitUnit = function(...)
		local u = initUnit(...)
		local exp = u:GetExperience()
		u.exp = setmetatable({}, { __index = function(_, k)
			local f = exp[k]
			if type(f) ~= "function" then return f end
			return function(_, ...) calls[#calls + 1] = k; return f(exp, ...) end
		end })
		local setDamage = u.SetDamage
		u.SetDamage = function(self, d) calls[#calls + 1] = "SetDamage"; return setDamage(self, d) end
		return u
	end
	local finish = UnitManager.FinishMoves
	UnitManager.FinishMoves = function(u) calls[#calls + 1] = "FinishMoves"; return finish(u) end
	local rec = { id = 3 }
	EFV_Units.ApplySnapshot(rec, EFV_Units.Snapshot(Veteran(0, 5, 6)), 5)
	local u = EFV_Units.Recreate(EFV_Records.Load(), 1, rec, H.plot(20, 20), 5)
	H.notnil(u)
	local first = {}
	for i, name in ipairs(calls) do
		if first[name] == nil then first[name] = i end
	end
	H.notnil(first.SetVeteranName, "name set")
	for _, later in ipairs({ "SetPromotion", "ChangeExperience", "SetDamage", "FinishMoves" }) do
		H.notnil(first[later], later .. " called")
		H.ok(first.SetVeteranName < first[later], "SetVeteranName before " .. later)
	end
	H.eq(u:GetExperience():GetVeteranName(), "Brutus")
	H.clean()
end)

test("RestoreXPClamped: target below the threshold kept; above it capped then clamped to next - 1", function()
	H.world{}
	H.loadEFV()
	local u = H.unit(0, "UNIT_WARRIOR", 3, 3)
	local xp, nxt, clamped = EFV_Units.RestoreXPClamped(u, 9)
	H.eq(xp, 9); H.eq(nxt, 15); H.eq(clamped, 0)
	xp, nxt, clamped = EFV_Units.RestoreXPClamped(u, 50)
	H.eq(xp, 14); H.eq(nxt, 15); H.eq(clamped, 1)
	H.eq(u:GetExperience():GetExperiencePoints(), 14)
	EFV_Config.FLAG_XP_CLAMP = false
	xp, nxt, clamped = EFV_Units.RestoreXPClamped(u, 50)
	H.eq(xp, 15, "engine cap only"); H.eq(clamped, 0)
end)
