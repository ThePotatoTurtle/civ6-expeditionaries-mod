-- @harness native
-- EFV_Records against the shared fake engine (WP1.2's own test_records.lua
-- covers the module in depth with its own fake): Init/Load/Commit through
-- real Game properties with copy semantics, SPIKES S3 storage rules on
-- realistic records, the string serializer and a simulated save/load.

local function SampleFields(extra)
	local f = {
		forceType = "EXPEDITIONARY", state = "OUTBOUND", senderID = 0, recipientID = 1,
		accessBasis = "ALLIANCE", originCityID = 65536, originX = 10, originY = 10,
		destCityID = 65538, destX = 22, destY = 10, rerouted = 0,
		unitType = "UNIT_SWORDSMAN", veteranName = "Brutus", damage = 0, experience = 12, xpNext = 45,
		level = 2, formation = 0, promotions = { "PROMOTION_BATTLECRY" },
		sentTurn = 1, arrivalTurn = 3, transitTurns = 2, band = 2, distance = 12,
		durationTurns = 20, spawnFailCount = 0, feePaid = 108, maintGoldPaid = 0, snapTurn = 1,
	}
	for k, v in pairs(extra or {}) do f[k] = v end
	return f
end

test("Init seeds every property once (PLAN 1.7) and is idempotent", function()
	H.world{ turn = 7 }
	H.loadEFV()   -- EFV_Gameplay.lua calls EFV_Records.Init()
	local P = EFV_Config.PROP
	H.eq(H.prop(P.INIT), 1); H.eq(H.prop(P.SCHEMA), EFV_Config.SCHEMA_VERSION)
	H.eq(H.prop(P.NEXT_ID), 1); H.eq(H.prop(P.LAST_TURN), 6)
	-- Empty tables do not survive the property round trip (Session B; the fake
	-- engine drops them), so an empty store reads back as nil.
	H.ok(H.prop(P.RECORD_IDS) == nil or #H.prop(P.RECORD_IDS) == 0)
	H.ok(H.prop(P.RECORDS) == nil or next(H.prop(P.RECORDS)) == nil)
	FAKE.turn = 30
	EFV_Records.Init()
	H.eq(H.prop(P.LAST_TURN), 6, "second Init does not reseed")
	H.clean()
end)

test("New / Commit / Load round trip through Game properties", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	local a = EFV_Records.New(s, SampleFields())
	local b = EFV_Records.New(s, SampleFields({ recipientID = 2 }))
	H.eq(a.id, 1); H.eq(b.id, 2)
	EFV_Records.Commit(s)
	local s2 = EFV_Records.Load()
	H.deq(s2.ids, { 1, 2 })
	H.eq(s2.nextID, 3)
	local r = EFV_Records.Get(s2, 1)
	for k, v in pairs(SampleFields()) do H.deq(r[k], v, "field " .. k) end
	H.eq(EFV_Records.Get(s2, 2).recipientID, 2)
	H.clean()
end)

test("records respect SPIKES S3 storage rules (no booleans, key 0, holes)", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	for i = 1, 5 do EFV_Records.New(s, SampleFields()) end
	EFV_Records.Delete(s, 2)
	EFV_Records.Delete(s, 4)
	EFV_Records.AddPending(s, 1, 131080, 3)
	EFV_Records.AddPending(s, 0, 131081, 3)
	EFV_Records.TakePending(s, 1)
	EFV_Records.Commit(s)
	H.deq(H.prop(EFV_Config.PROP.RECORD_IDS), { 1, 3, 5 }, "dense, ascending")
	H.len(FAKE.propViolations, 0)
	H.clean()
end)

test("in-place edits persist only after Touch + Commit; Rev bumps only on writes", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	local r = EFV_Records.New(s, SampleFields())
	EFV_Records.Commit(s)
	local rev = H.prop(EFV_Config.PROP.REV)
	EFV_Records.Commit(s)
	H.eq(H.prop(EFV_Config.PROP.REV), rev, "empty commit writes nothing")
	r.state = "DEPLOYED"
	H.eq(EFV_Records.Load().recs.r1.state, "OUTBOUND", "not written yet")
	EFV_Records.Touch(s)
	EFV_Records.Commit(s)
	H.eq(EFV_Records.Load().recs.r1.state, "DEPLOYED")
	H.eq(H.prop(EFV_Config.PROP.REV), rev + 1)
end)

test("IDs returns a copy; Delete during iteration is safe", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	for i = 1, 4 do EFV_Records.New(s, SampleFields()) end
	local seen = {}
	for _, id in ipairs(EFV_Records.IDs(s)) do
		seen[#seen + 1] = id
		if id % 2 == 0 then H.ok(EFV_Records.Delete(s, id)) end
	end
	H.deq(seen, { 1, 2, 3, 4 })
	H.deq(EFV_Records.IDs(s), { 1, 3 })
	H.ok(not EFV_Records.Delete(s, 99))
	local r5 = EFV_Records.New(s, SampleFields())
	H.eq(r5.id, 5, "IDs never reused")
end)

test("FindByUnit and pending exhaust list", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	EFV_Records.New(s, SampleFields({ state = "DEPLOYED", onMapPlayerID = 1, onMapUnitID = 555 }))
	H.eq(EFV_Records.FindByUnit(s, 1, 555).id, 1)
	H.isnil(EFV_Records.FindByUnit(s, 0, 555))
	EFV_Records.AddPending(s, 1, 10, 4)
	EFV_Records.AddPending(s, 2, 11, 4)
	EFV_Records.AddPending(s, 1, 12, 4)
	local taken = EFV_Records.TakePending(s, 1)
	H.len(taken, 2); H.eq(taken[1].u, 10); H.eq(taken[2].u, 12)
	H.len(s.pending, 1); H.eq(s.pending[1].p, 2)
end)

test("Encode / Decode round trip, deterministic, versioned", function()
	H.world{}
	H.loadEFV()
	local v = { ids = { 1, 3 }, recs = { r1 = SampleFields(), r3 = SampleFields({ veteranName = "A \"quoted\" name\n;=,{}" }) },
		neg = -12.5, big = 123456789 }
	local e = EFV_Records.Encode(v)
	H.eq(type(e), "string")
	H.eq(string.sub(e, 1, 5), "EFV1:")
	H.deq(EFV_Records.Decode(e), v)
	local w = { recs = { r3 = v.recs.r3, r1 = v.recs.r1 }, big = 123456789, ids = { 1, 3 }, neg = -12.5 }
	H.eq(EFV_Records.Encode(w), e, "independent of insertion order")
	H.isnil(EFV_Records.Decode("garbage"))
	H.isnil(EFV_Records.Decode("EFV1:{unterminated"))
end, { allowErrors = true })

test("FLAG_PERSIST_AS_STRING: properties hold strings, Load decodes", function()
	H.world{}
	H.loadEFV{ flags = { FLAG_PERSIST_AS_STRING = true } }
	local s = EFV_Records.Load()
	EFV_Records.New(s, SampleFields())
	EFV_Records.Commit(s)
	H.eq(type(H.prop(EFV_Config.PROP.RECORDS)), "string")
	H.eq(type(H.prop(EFV_Config.PROP.RECORD_IDS)), "string")
	local s2 = EFV_Records.Load()
	H.eq(s2.recs.r1.unitType, "UNIT_SWORDSMAN")
	H.deq(s2.recs.r1.promotions, { "PROMOTION_BATTLECRY" })
end)

test("simulated save/load: store survives a fresh EFV state, hooks re-registered once", function()
	H.world{}
	H.loadEFV()
	local s = EFV_Records.Load()
	EFV_Records.New(s, SampleFields())
	EFV_Records.Commit(s)
	EFV_Records.Dump(EFV_Records.Load())
	local before = H.lines("[Dump]")
	H.reloadEFV()
	H.eq(#GameEvents.OnGameTurnStarted.handlers, 1, "registered once after load")
	H.eq(#GameEvents.EFV_Send.handlers, 1)
	H.markBody()
	EFV_Records.Dump(EFV_Records.Load())
	local after = H.lines("[Dump]")
	H.ok(#before > 0, "Dump logs [Dump] lines")
	H.deq(after, before, "dump identical before/after load (P1.4)")
	H.eq(H.prop(EFV_Config.PROP.NEXT_ID), 2)
end)
