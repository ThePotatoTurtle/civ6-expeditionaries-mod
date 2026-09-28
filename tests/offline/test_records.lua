-- ===========================================================================
-- tests/offline/test_records.lua  (WP1.2)
-- Offline unit tests for EFV_Records (store, CRUD, commit, serializer, dump)
-- and EFV_Notify (queue, flush, human-only, D9 re-send coalescing), run under
-- Lua 5.1 (lupa.lua51) with a minimal fake engine.
--
-- Run: python tests/offline/run_records_test.py
-- The runner sets the global EFV_ROOT (project dir, forward slashes) and
-- reads the last line "RESULT passed=<n> failed=<m>".
-- ===========================================================================

assert(EFV_ROOT ~= nil, "EFV_ROOT must be set by the runner")

-- ---------------------------------------------------------------------------
-- Fake engine
-- ---------------------------------------------------------------------------
local LOG = {}
local REAL_PRINT = print
print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	LOG[#LOG + 1] = table.concat(parts, "\t")
end

local function sortedKeysForTest(t)
	local keys = {}
	if t == nil then
		return keys
	end
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

local function deepcopy(v)
	if type(v) ~= "table" then
		return v
	end
	local t = {}
	for k, x in pairs(v) do
		t[k] = deepcopy(x)
	end
	return t
end

-- Property store. COPY_SEMANTICS = true: Set/Get deep-copy (engine
-- serialises); false: the live table reference is kept and returned
-- (worst case for aliasing, T03 unknown).
local PROPS = {}
local SET_CALLS = 0
local COPY_SEMANTICS = true
local GET_OVERRIDE = nil   -- function(key) -> value, or nil

local TURN = 10

Game = {}
function Game.GetCurrentGameTurn() return TURN end
function Game:SetProperty(k, v)
	SET_CALLS = SET_CALLS + 1
	if COPY_SEMANTICS then
		PROPS[k] = deepcopy(v)
	else
		PROPS[k] = v
	end
end
function Game:GetProperty(k)
	if GET_OVERRIDE ~= nil then
		local v = GET_OVERRIDE(k)
		if v ~= nil then
			return v
		end
	end
	if COPY_SEMANTICS then
		return deepcopy(PROPS[k])
	end
	return PROPS[k]
end

local function MakePlayer(human)
	return { IsHuman = function(self) return human end }
end
Players = {}
Players[0] = MakePlayer(true)
Players[1] = MakePlayer(false)
Players[2] = MakePlayer(true)

ParameterTypes = { MESSAGE = "MESSAGE", SUMMARY = "SUMMARY", LOCATION = "LOCATION" }

GameInfo = { Types = {} }
local TYPE_NAMES = {
	"EFV_NOTIF_DEPARTED", "EFV_NOTIF_ARRIVED", "EFV_NOTIF_GRACE", "EFV_NOTIF_MUTINY",
	"EFV_NOTIF_MUTINY_DEATH", "EFV_NOTIF_REQUEST_FAILED",
}
for i, n in ipairs(TYPE_NAMES) do
	GameInfo.Types[n] = { Type = n, Hash = 1000 + i }
end

local SENT = {}
NotificationManager = {}
function NotificationManager.SendNotification(pid, hash, data)
	SENT[#SENT + 1] = { pid = pid, hash = hash, data = data }
end

Locale = {}
function Locale.Lookup(key, ...)
	local args = { ... }
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(args[i])
	end
	return key .. "(" .. table.concat(parts, ",") .. ")"
end

function include(name)
	local f = assert(loadfile(EFV_ROOT .. "/EFV/Scripts/" .. name .. ".lua"))
	f()
end

-- ---------------------------------------------------------------------------
-- Load modules
-- ---------------------------------------------------------------------------
include("EFV_Config")
include("EFV_Util")
-- WP1.1 may not have landed yet: substitute EFV_SortedKeys if it is a stub.
local probe = EFV_SortedKeys({ b = 1, a = 2 })
local SORTEDKEYS_STUBBED = false
if type(probe) ~= "table" or probe[1] ~= "a" or probe[2] ~= "b" then
	EFV_SortedKeys = sortedKeysForTest
	SORTEDKEYS_STUBBED = true
end
include("EFV_Records")
include("EFV_Notify")
EFV_Config.LOG_LEVEL = 2

-- ---------------------------------------------------------------------------
-- Mini test framework
-- ---------------------------------------------------------------------------
local passed, failed = 0, 0
local function check(cond, msg)
	if not cond then
		error(msg or "check failed", 2)
	end
end
local function eq(a, b, msg)
	if a ~= b then
		error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
	end
end
local function deepeq(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b or (a ~= a and b ~= b)
	end
	for k, v in pairs(a) do
		if not deepeq(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end
local function logHas(pattern)
	for _, l in ipairs(LOG) do
		if string.find(l, pattern) then
			return true
		end
	end
	return false
end
local function reset(copySemantics)
	PROPS = {}
	SET_CALLS = 0
	COPY_SEMANTICS = (copySemantics ~= false)
	GET_OVERRIDE = nil
	EFV_Config.FLAG_PERSIST_AS_STRING = false
	LOG = {}
	SENT = {}
	EFV_Notify.Discard()
	LOG = {}
	TURN = 10
end
local function test(name, fn)
	reset(true)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		REAL_PRINT("PASS " .. name)
	else
		failed = failed + 1
		REAL_PRINT("FAIL " .. name .. ": " .. tostring(err))
		for _, l in ipairs(LOG) do
			REAL_PRINT("   log| " .. l)
		end
	end
end

local P = EFV_Config.PROP

-- ===========================================================================
-- Serializer
-- ===========================================================================
test("encode/decode round trip", function()
	local v = {
		recs = { r1 = { id = 1, state = "DEPLOYED", promotions = { "PROMOTION_BATTLECRY", "PROMOTION_TORTOISE" },
			damage = 0, lapsed = 0, veteranName = "" }, r12 = { id = 12, x = -3 } },
		ids = { 1, 12 },
		big = 2 ^ 40, neg = -17, frac = 0.1, third = 1 / 3, tiny = 1e-300, negzero = 0,
		s = "a:b}{n1;s3:\0\n\"", empty = {}, flagT = true, flagF = false,
	}
	local s = EFV_Records.Encode(v)
	check(type(s) == "string", "encode returned string")
	eq(string.sub(s, 1, 5), "EFV1:", "prefix")
	local d = EFV_Records.Decode(s)
	check(deepeq(d, v), "decoded equals original")
	eq(d.third, 1 / 3, "float exact")
	eq(d.big, 2 ^ 40, "big int exact")
	eq(EFV_Records.Encode(d), s, "re-encode identical")
end)

test("encode is deterministic across insertion order", function()
	local a, b = {}, {}
	local names = { "zeta", "alpha", "mid", "r10", "r2", "r1" }
	for i = 1, #names do a[names[i]] = i end
	for i = #names, 1, -1 do b[names[i]] = i end
	eq(EFV_Records.Encode(a), EFV_Records.Encode(b), "same encoding")
	local arr = { 5, 4, 3 }
	eq(EFV_Records.Encode(arr), "EFV1:{n1;n5;n2;n4;n3;n3;}", "array format")
	eq(EFV_Records.Encode("hi"), "EFV1:s2:hi", "string format")
	eq(EFV_Records.Encode(7), "EFV1:n7;", "number format")
	eq(EFV_Records.Encode({}), "EFV1:{}", "empty table")
end)

test("decode rejects malformed input", function()
	local bad = { "", "EFV1:", "EFV1:n12", "EFV1:nabc;", "EFV1:s5:abc", "EFV1:s-1:", "EFV1:{n1;",
		"EFV1:n1;x", "XYZ", "EFV2:n1;", "EFV1:{n1;n2;n1;n3;}", "EFV1:{T n1;}", "EFV1:?" }
	for _, s in ipairs(bad) do
		check(EFV_Records.Decode(s) == nil, "should reject " .. string.format("%q", s))
	end
	check(EFV_Records.Decode(nil) == nil, "nil")
	check(EFV_Records.Decode(12) == nil, "number")
	check(EFV_Records.Decode("EFV1:{}") ~= nil, "empty table ok")
	check(EFV_Records.Decode("EFV1:F") == false, "false ok")
end)

test("encode rejects unsupported values", function()
	check(EFV_Records.Encode({ f = function() end }) == nil, "function")
	check(EFV_Records.Encode(0 / 0) == nil, "NaN")
	check(EFV_Records.Encode(math.huge) == nil, "inf")
	-- Mixed key types: allowed if EFV_SortedKeys orders them (WP1.1 KeyLess),
	-- rejected if it throws. Either way never a nondeterministic string.
	local mixed = { [1] = "a", b = "c" }
	local ms = EFV_Records.Encode(mixed)
	check(ms == nil or deepeq(EFV_Records.Decode(ms), mixed), "mixed keys round trip or reject")
	local deep = {}
	local cur = deep
	for i = 1, 20 do cur.x = {}; cur = cur.x end
	check(EFV_Records.Encode(deep) == nil, "too deep")
	check(logHas("%[Store%] ERROR encode failed"), "logged")
end)

-- ===========================================================================
-- Init
-- ===========================================================================
test("init seeds a fresh game and is idempotent", function()
	TURN = 1
	EFV_Records.Init()
	eq(PROPS[P.INIT], 1, "init")
	eq(PROPS[P.SCHEMA], EFV_Config.SCHEMA_VERSION, "schema")
	eq(PROPS[P.NEXT_ID], 1, "nextID")
	eq(PROPS[P.LAST_TURN], 0, "lastTurn = turn - 1")
	eq(PROPS[P.REV], 0, "rev")
	check(deepeq(PROPS[P.RECORD_IDS], {}) and deepeq(PROPS[P.RECORDS], {}), "empty tables")
	check(deepeq(PROPS[P.PENDING], {}) and deepeq(PROPS[P.ENTRUST], {}), "empty tables 2")
	local calls = SET_CALLS
	TURN = 5
	EFV_Records.Init()
	eq(SET_CALLS, calls, "second init writes nothing")
	eq(PROPS[P.LAST_TURN], 0, "lastTurn unchanged on reload")
	-- A missing table key is normal after a save round trip (empty tables are
	-- dropped, Session B): re-seeded and logged at level 3, not as an error.
	local lvl = EFV_Config.LOG_LEVEL
	EFV_Config.LOG_LEVEL = 3
	PROPS[P.PENDING] = nil
	EFV_Records.Init()
	EFV_Config.LOG_LEVEL = lvl
	check(deepeq(PROPS[P.PENDING], {}), "missing key re-seeded")
	check(logHas("empty table keys re%-seeded: EFV_PendingExhaust"), "logged reseed")
	check(not logHas("missing keys, seeded: EFV_PendingExhaust"), "not an error")
end)

-- ===========================================================================
-- Store CRUD + commit
-- ===========================================================================
test("new/commit/load round trip and rev", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	eq(#s.ids, 0, "empty")
	eq(s.rev, 0, "rev 0")
	local r1 = EFV_Records.New(s, { forceType = "EXPEDITIONARY", state = "OUTBOUND", senderID = 0, recipientID = 1,
		promotions = { "P1" }, rerouted = false, id = 99 })
	local r2 = EFV_Records.New(s, { forceType = "VOLUNTEER", state = "DEPLOYED", senderID = 0, recipientID = 2,
		onMapPlayerID = 2, onMapUnitID = 65536 })
	local r3 = EFV_Records.New(s, { forceType = "EXPEDITIONARY", state = "RETURNING", onMapPlayerID = 2, onMapUnitID = 7 })
	eq(r1.id, 1, "id1"); eq(r2.id, 2, "id2"); eq(r3.id, 3, "id3")
	eq(r1.rerouted, 0, "boolean stored as 0")
	eq(s.nextID, 4, "nextID")
	check(s.dirty[P.NEXT_ID] and s.dirty[P.RECORD_IDS] and s.dirty[P.RECORDS], "dirty")
	EFV_Records.Commit(s)
	eq(s.rev, 1, "rev bumped")
	eq(PROPS[P.REV], 1, "rev written")
	check(next(s.dirty) == nil, "dirty cleared")
	check(deepeq(PROPS[P.RECORD_IDS], { 1, 2, 3 }), "ids persisted")
	local calls = SET_CALLS
	EFV_Records.Commit(s)
	eq(SET_CALLS, calls, "clean commit writes nothing")
	eq(PROPS[P.REV], 1, "rev unchanged on clean commit")

	local s2 = EFV_Records.Load()
	check(deepeq(s2.ids, { 1, 2, 3 }), "ids loaded")
	eq(s2.nextID, 4, "nextID loaded")
	eq(s2.rev, 1, "rev loaded")
	eq(EFV_Records.Get(s2, 1).promotions[1], "P1", "nested field")
	eq(EFV_Records.Get(s2, 2).recipientID, 2, "field")
	check(EFV_Records.Get(s2, 4) == nil, "missing")
	-- FindByUnit: only on-map states.
	eq(EFV_Records.FindByUnit(s2, 2, 65536).id, 2, "find deployed")
	check(EFV_Records.FindByUnit(s2, 2, 7) == nil, "RETURNING not matched")
	check(EFV_Records.FindByUnit(s2, 1, 65536) == nil, "wrong player")
end)

test("delete keeps order, IDs is a copy, IDs never reused", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	for i = 1, 5 do EFV_Records.New(s, { state = "OUTBOUND", n = i }) end
	EFV_Records.Commit(s)
	s = EFV_Records.Load()
	local visited = {}
	for _, id in ipairs(EFV_Records.IDs(s)) do
		visited[#visited + 1] = id
		if id % 2 == 0 then
			eq(EFV_Records.Delete(s, id), true, "delete " .. id)
		end
	end
	check(deepeq(visited, { 1, 2, 3, 4, 5 }), "iteration over copy unaffected")
	check(deepeq(s.ids, { 1, 3, 5 }), "order preserved")
	eq(EFV_Records.Delete(s, 2), false, "double delete")
	eq(EFV_Records.Delete(s, 42), false, "unknown")
	local copy = EFV_Records.IDs(s)
	copy[1] = 999
	eq(s.ids[1], 1, "IDs returns a copy")
	local r = EFV_Records.New(s, { state = "OUTBOUND" })
	eq(r.id, 6, "monotonic id after delete")
	EFV_Records.Commit(s)
	local s2 = EFV_Records.Load()
	check(deepeq(s2.ids, { 1, 3, 5, 6 }), "persisted ids")
	check(EFV_Records.Get(s2, 2) == nil, "deleted rec gone")
	eq(s2.nextID, 7, "nextID")
end)

test("touch marks records dirty; in-place edits persist only after commit", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	EFV_Records.New(s, { state = "OUTBOUND", damage = 0 })
	EFV_Records.Commit(s)
	local a = EFV_Records.Load()
	EFV_Records.Get(a, 1).damage = 40
	-- no commit: a fresh load must not see it (deep copy even with live references)
	eq(EFV_Records.Get(EFV_Records.Load(), 1).damage, 0, "uncommitted edit invisible")
	EFV_Records.Touch(a)
	check(a.dirty[P.RECORDS], "touch dirty")
	EFV_Records.Commit(a)
	eq(EFV_Records.Get(EFV_Records.Load(), 1).damage, 40, "committed edit visible")
end)

test("load isolates the store under live-reference GetProperty", function()
	reset(false) -- engine keeps and returns live tables
	EFV_Records.Init()
	local s = EFV_Records.Load()
	EFV_Records.New(s, { state = "OUTBOUND", damage = 0, promotions = { "A" } })
	EFV_Records.Commit(s)
	local a = EFV_Records.Load()
	local rec = EFV_Records.Get(a, 1)
	rec.damage = 99
	rec.promotions[2] = "B"
	EFV_Records.New(a, { state = "OUTBOUND" })
	-- aborted handler: no commit
	local b = EFV_Records.Load()
	eq(EFV_Records.Get(b, 1).damage, 0, "damage untouched")
	eq(#EFV_Records.Get(b, 1).promotions, 1, "promotions untouched")
	eq(#b.ids, 1, "no new record")
	eq(b.nextID, 2, "nextID untouched")
end)

test("pending add/take keeps order and dedups", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	EFV_Records.AddPending(s, 1, 100, 10)
	EFV_Records.AddPending(s, 2, 200, 10)
	EFV_Records.AddPending(s, 1, 101, 10)
	EFV_Records.AddPending(s, 1, 100, 11) -- duplicate: updates t
	eq(#s.pending, 3, "dedup")
	check(s.dirty[P.PENDING], "dirty")
	EFV_Records.Commit(s)
	s = EFV_Records.Load()
	local none = EFV_Records.TakePending(s, 5)
	eq(#none, 0, "none for 5")
	check(s.dirty[P.PENDING] == nil, "not dirty when nothing taken")
	local t = EFV_Records.TakePending(s, 1)
	eq(#t, 2, "two for 1"); eq(t[1].u, 100, "order 1"); eq(t[1].t, 11, "updated t"); eq(t[2].u, 101, "order 2")
	eq(#s.pending, 1, "rest"); eq(s.pending[1].p, 2, "rest is p2")
	check(s.dirty[P.PENDING], "dirty after take")
	EFV_Records.Commit(s)
	eq(#EFV_Records.Load().pending, 1, "persisted")
end)

test("entrust and lastTurn persist via dirty flags", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	s.entrust["p1234"] = { capturerID = 0, oldOwnerID = 3, turn = 10, recipients = { 1, 2 } }
	EFV_Records.MarkDirty(s, P.ENTRUST)
	s.lastTurn = 10
	s.dirty[P.LAST_TURN] = true
	s.dirty["EFV_Typo"] = true
	EFV_Records.Commit(s)
	check(logHas("unknown dirty key EFV_Typo"), "unknown key logged")
	check(PROPS["EFV_Typo"] == nil, "unknown key not written")
	local s2 = EFV_Records.Load()
	eq(s2.lastTurn, 10, "lastTurn")
	eq(s2.entrust["p1234"].recipients[2], 2, "entrust")
end)

test("load repairs inconsistent ids and nextID", function()
	EFV_Records.Init()
	PROPS[P.RECORDS] = { r2 = { id = 2, state = "OUTBOUND" }, r10 = { state = "DEPLOYED" }, bogus = 5 }
	PROPS[P.RECORD_IDS] = { 2, 3 }
	PROPS[P.NEXT_ID] = 4
	local s = EFV_Records.Load()
	check(deepeq(s.ids, { 2, 10 }), "ids rebuilt numerically from records")
	eq(EFV_Records.Get(s, 10).id, 10, "rec.id fixed")
	eq(s.nextID, 11, "nextID raised")
	check(s.dirty[P.RECORD_IDS] and s.dirty[P.NEXT_ID] and s.dirty[P.RECORDS], "repair marked dirty")
	check(logHas("disagrees with EFV_Records"), "logged")
	EFV_Records.Commit(s)
	check(deepeq(PROPS[P.RECORD_IDS], { 2, 10 }), "repair persisted")
	eq(EFV_Records.New(s, {}).id, 11, "new after repair")
end)

test("string persistence mode round trip and cross-mode load", function()
	EFV_Config.FLAG_PERSIST_AS_STRING = true
	EFV_Records.Init()
	eq(type(PROPS[P.RECORDS]), "string", "records encoded at init")
	eq(type(PROPS[P.NEXT_ID]), "number", "scalars stay numbers")
	local s = EFV_Records.Load()
	EFV_Records.New(s, { state = "OUTBOUND", promotions = { "X", "Y" }, veteranName = "Bob:{}" })
	EFV_Records.AddPending(s, 0, 5, 10)
	EFV_Records.Commit(s)
	eq(string.sub(PROPS[P.RECORDS], 1, 5), "EFV1:", "records encoded")
	eq(string.sub(PROPS[P.RECORD_IDS], 1, 5), "EFV1:", "ids encoded")
	eq(string.sub(PROPS[P.PENDING], 1, 5), "EFV1:", "pending encoded")
	local s2 = EFV_Records.Load()
	eq(EFV_Records.Get(s2, 1).veteranName, "Bob:{}", "string field")
	eq(EFV_Records.Get(s2, 1).promotions[2], "Y", "array field")
	-- UI path: decode the raw property directly
	local recs = EFV_Records.Decode(Game:GetProperty(P.RECORDS))
	eq(recs.r1.state, "OUTBOUND", "UI decode")
	-- flag switched off later: encoded save still loads
	EFV_Config.FLAG_PERSIST_AS_STRING = false
	local s3 = EFV_Records.Load()
	eq(#s3.ids, 1, "cross-mode load")
	EFV_Records.Touch(s3)
	EFV_Records.Commit(s3)
	eq(type(PROPS[P.RECORDS]), "table", "rewritten as table")
end)

test("broken load disables commit", function()
	EFV_Records.Init()
	local s0 = EFV_Records.Load()
	EFV_Records.New(s0, { state = "OUTBOUND" })
	EFV_Records.Commit(s0)
	GET_OVERRIDE = function(k)
		if k == P.RECORDS then return "EFV1:{s2:r1;" end
		return nil
	end
	local s = EFV_Records.Load()
	check(s.broken == true, "broken flag")
	eq(#s.ids, 0, "empty")
	EFV_Records.New(s, { state = "OUTBOUND" })
	local calls = SET_CALLS
	EFV_Records.Commit(s)
	eq(SET_CALLS, calls, "nothing written")
	check(logHas("commit refused"), "logged")
	GET_OVERRIDE = nil
	eq(#EFV_Records.Load().ids, 1, "saved data intact")
end)

test("dump is deterministic and complete", function()
	EFV_Records.Init()
	local s = EFV_Records.Load()
	EFV_Records.New(s, { state = "DEPLOYED", zeta = 1, alpha = "a", promotions = { "P1", "P2" } })
	EFV_Records.New(s, { state = "OUTBOUND" })
	s.entrust["p7"] = { capturerID = 0, recipients = { 1 } }
	EFV_Records.MarkDirty(s, P.ENTRUST)
	EFV_Records.Commit(s)
	LOG = {}
	EFV_Records.Dump(EFV_Records.Load())
	local first = table.concat(LOG, "\n")
	LOG = {}
	EFV_Records.Dump(nil)
	local second = table.concat(LOG, "\n")
	eq(first, second, "identical dumps")
	-- Load normalises records (WP1.7: nil-safe defaults for fields the
	-- property round trip may drop).
	check(string.find(first, "[Dump] r1 {alpha=\"a\",id=1,lapsed=0,maintGoldPaid=0,promotions={\"P1\",\"P2\"},rerouted=0,spawnFailCount=0,state=\"DEPLOYED\",zeta=1}", 1, true),
		"record line: " .. first)
	check(string.find(first, "[Dump] ids={1,2}", 1, true), "ids line")
	-- Phase 6: Load also normalises the snapshot's partners list (= {}).
	check(string.find(first, "[Dump] entrust p7 {capturerID=0,partners={},recipients={1}}", 1, true), "entrust line: " .. first)
	check(string.find(first, "[Dump] end", 1, true), "end line")
end)

-- ===========================================================================
-- Notify
-- ===========================================================================
local N = EFV_Config.NOTIF

test("notify: human-only, FIFO, data fields", function()
	EFV_Notify.Queue(0, N.DEPARTED, "LOC_EFV_NOTIF_DEPARTED", { "Swordsman", 3 }, 5, 6, { recordID = 1 })
	EFV_Notify.Queue(1, N.ARRIVED, "LOC_EFV_NOTIF_ARRIVED", {}, 5, 6)          -- AI: skipped
	EFV_Notify.Queue(nil, N.ARRIVED, "LOC_EFV_NOTIF_ARRIVED", {})               -- invalid: skipped
	EFV_Notify.Queue(63, N.ARRIVED, "LOC_EFV_NOTIF_ARRIVED", {})                -- no such player: skipped
	EFV_Notify.Queue(2, N.REQUEST_FAILED, nil, { "why" })                        -- default key base
	EFV_Notify.Queue(0, N.GRACE, "LOC_EFV_NOTIF_GRACE", { "U", 4 }, 1, 2, { recordID = 7, kind = "GRACE" })
	eq(EFV_Notify.Count(), 3, "queued humans only")
	check(#SENT == 0, "nothing sent before flush")
	EFV_Notify.Flush()
	eq(#SENT, 3, "sent")
	eq(EFV_Notify.Count(), 0, "queue cleared")
	local a = SENT[1]
	eq(a.pid, 0, "fifo 1"); eq(a.hash, GameInfo.Types[N.DEPARTED].Hash, "hash")
	eq(a.data.MESSAGE, "LOC_EFV_NOTIF_DEPARTED_MESSAGE(Swordsman,3)", "message")
	eq(a.data.SUMMARY, "LOC_EFV_NOTIF_DEPARTED_SUMMARY(Swordsman,3)", "summary")
	eq(a.data.LOCATION.x, 5, "loc x"); eq(a.data.LOCATION.y, 6, "loc y")
	eq(a.data.AlwaysUnique, true, "unique")
	check(a.data.AlwaysAutoActivate == nil, "no auto-activate for DEPARTED")
	eq(a.data.EFV_RecordID, 1, "record id"); eq(a.data.EFV_Kind, N.DEPARTED, "kind defaults to type")
	eq(a.data.EFV_Turn, 10, "turn")
	local b = SENT[2]
	eq(b.pid, 2, "fifo 2"); eq(b.data.MESSAGE, "LOC_EFV_NOTIF_REQUEST_FAILED_MESSAGE(why)", "default key")
	check(b.data.LOCATION == nil, "no location"); check(b.data.EFV_RecordID == nil, "no extra")
	local c = SENT[3]
	eq(c.data.AlwaysAutoActivate, true, "grace auto-activates"); eq(c.data.EFV_Kind, "GRACE", "kind")
	EFV_Notify.Flush()
	eq(#SENT, 3, "second flush sends nothing")
end)

test("notify: D9 re-send coalesces within a batch, repeats across turns", function()
	check(EFV_Notify.IsResendType(N.GRACE) and EFV_Notify.IsResendType(N.MUTINY), "resend types")
	check(not EFV_Notify.IsResendType(N.ARRIVED), "not resend")
	EFV_Notify.Queue(0, N.GRACE, "LOC_EFV_NOTIF_GRACE", { 5 }, 1, 1, { recordID = 3 })
	EFV_Notify.Queue(0, N.DEPARTED, "LOC_EFV_NOTIF_DEPARTED", {}, nil, nil, { recordID = 4 })
	EFV_Notify.Queue(0, N.GRACE, "LOC_EFV_NOTIF_GRACE", { 4 }, 1, 1, { recordID = 3 }) -- replaces #1
	EFV_Notify.Queue(0, N.GRACE, "LOC_EFV_NOTIF_GRACE", { 4 }, 1, 1, { recordID = 9 }) -- other record
	EFV_Notify.Queue(0, N.REQUEST_FAILED, nil, { "a" })
	EFV_Notify.Queue(0, N.REQUEST_FAILED, nil, { "b" })                               -- no record: kept
	eq(EFV_Notify.Count(), 5, "coalesced")
	EFV_Notify.Flush()
	eq(SENT[1].data.MESSAGE, "LOC_EFV_NOTIF_GRACE_MESSAGE(4)", "replacement keeps first position")
	eq(SENT[2].data.EFV_RecordID, 4, "then departed")
	eq(SENT[3].data.EFV_RecordID, 9, "then other record")
	-- next turn: sent again with a newer turn stamp
	TURN = 11
	SENT = {}
	EFV_Notify.Queue(0, N.GRACE, "LOC_EFV_NOTIF_GRACE", { 3 }, 1, 1, { recordID = 3 })
	EFV_Notify.Flush()
	eq(#SENT, 1, "re-sent"); eq(SENT[1].data.EFV_Turn, 11, "turn stamp")
end)

test("notify: unknown type skipped, others still sent; QueueForRecord", function()
	eq(EFV_Notify.NOTIF_LAPSE_CANCELLED, "EFV_NOTIF_LAPSE_CANCELLED", "lapse-cancelled name")
	local rec = { id = 5, senderID = 0, recipientID = 2, lastX = 8, lastY = 9 }
	EFV_Notify.QueueForRecord(rec, EFV_Notify.NOTIF_LAPSE_CANCELLED, { "Rome" })  -- no Types row yet
	EFV_Notify.QueueForRecord(rec, N.MUTINY, { "U" })
	EFV_Notify.QueueForRecord({ id = 6, senderID = 0, recipientID = 1 }, N.ARRIVED, {})   -- AI recipient
	EFV_Notify.QueueForRecord({ id = 7, senderID = 0, recipientID = 0 }, N.ARRIVED, {}, { noLocation = true })
	EFV_Notify.QueueForRecord(rec, N.ARRIVED, {}, { sender = false })
	eq(EFV_Notify.Count(), 7, "queued")
	EFV_Notify.Flush()
	check(logHas("unknown notification type EFV_NOTIF_LAPSE_CANCELLED"), "unknown logged")
	eq(#SENT, 5, "5 sent (2 unknown skipped)")
	eq(SENT[1].pid, 0, "mutiny sender first"); eq(SENT[2].pid, 2, "mutiny recipient")
	eq(SENT[1].data.AlwaysAutoActivate, true, "mutiny auto")
	eq(SENT[1].data.LOCATION.x, 8, "location from record")
	eq(SENT[1].data.MESSAGE, "LOC_EFV_NOTIF_MUTINY_MESSAGE(U)", "key base from type")
	eq(SENT[3].pid, 0, "AI recipient skipped"); eq(SENT[3].data.EFV_RecordID, 6, "rec 6")
	eq(SENT[4].data.EFV_RecordID, 7, "same player once"); check(SENT[4].data.LOCATION == nil, "noLocation")
	eq(SENT[5].pid, 2, "recipient only")
end)

test("notify: flush survives a throwing SendNotification", function()
	local real = NotificationManager.SendNotification
	local n = 0
	NotificationManager.SendNotification = function(pid, hash, data)
		n = n + 1
		if n == 1 then error("boom") end
		real(pid, hash, data)
	end
	EFV_Notify.Queue(0, N.ARRIVED, nil, {})
	EFV_Notify.Queue(0, N.DEPARTED, nil, {})
	EFV_Notify.Flush()
	NotificationManager.SendNotification = real
	eq(#SENT, 1, "second still sent")
	eq(EFV_Notify.Count(), 0, "cleared")
	check(logHas("send failed pid=0 type=EFV_NOTIF_ARRIVED"), "logged")
end)

-- ---------------------------------------------------------------------------
print = REAL_PRINT
if SORTEDKEYS_STUBBED then
	print("NOTE EFV_SortedKeys is still a stub (WP1.1); tests used a local substitute")
end
print(string.format("RESULT passed=%d failed=%d", passed, failed))
