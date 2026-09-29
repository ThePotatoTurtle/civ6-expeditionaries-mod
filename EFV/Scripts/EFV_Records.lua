-- ===========================================================================
-- EFV_Records.lua
-- Module:   EFV_Records (global table)
-- Context:  gameplay, include("EFV_Records"). The UI includes this file only
--           for EFV_Records.Decode (INTERFACES Scaffold note 12).
-- Owner:    WP1.2 (implemented).
--
-- Responsibility (PLAN 1.3, 1.4, 2.4): the record store and its persistence
-- in Game properties (SPIKES S3): first-init guard and schema migrations,
-- load into an in-memory store, commit of dirty keys, record CRUD with the
-- deterministic ID order (EFV_RecordIDs), the pending-exhaust list, the
-- string serializer fallback (FLAG_PERSIST_AS_STRING) and a debug dump.
--
-- Storage rules (SPIKES S3): string keys or dense arrays only; no key 0; no
-- holes; numbers/strings only inside records (booleans stored as 0/1);
-- promotions as type strings; SetProperty again after every change. Only
-- gameplay writes; the UI reads through EFV_UIShared.
--
-- Store shape (INTERFACES "Store"):
--   { nextID, ids, recs, pending, entrust, vet, lastTurn, rev, dirty = {} }
--   vet (0.7, INTERFACES note 33): dense array of veteran route B jobs
--   (EFV_Veteran), sorted by (t, p, u); AddVetJob / FindVetJob / RemoveVetJob.
--   dirty is keyed by property name (EFV_Config.PROP values), value true.
--   A store whose Load failed carries broken = true; Commit refuses to write
--   it (a partial store must never overwrite the saved one).
--
-- Property round trip (Session B T08/T10): an empty string, and very likely an
-- empty table, stored inside a Game property comes back as nil (and a
-- top-level empty table property may read back as nil). Load therefore
-- normalises every record (NormalizeRecord: promotions = {}, 0/1 and counter
-- fields default to 0, "" names -> nil) and every Entrust snapshot
-- (recipients = {}, partners = {}); all other optional record fields are read nil-safe by
-- their users. Init treats a missing table-valued key as normal.
--
-- Load/commit semantics (INTERFACES Scaffold notes 2, 3, 16):
--   * Load once per handler invocation; never cache the store across
--     handlers. Load deep-copies what GetProperty returns (GetProperty may
--     return a live reference, T03), so an aborted handler that never
--     commits leaves the saved state untouched.
--   * Commit writes only the dirty keys, then bumps EFV_Rev if anything was
--     written. Handlers commit, then EFV_Notify.Flush().
--
-- Determinism (PLAN 1.6): no pairs() here; every table walk goes through
-- EFV_SortedKeys (the one sanctioned pairs()). Records are iterated in the
-- order of store.ids, which is ascending by construction (monotonic IDs).
--
-- String fallback format (spec S3 fallback, PLAN 1.3), prefix "EFV1:":
--   number   n<digits>;        integers as "%.0f", other finite as "%.17g"
--   string   s<len>:<bytes>    length-prefixed, binary safe, no escaping
--   boolean  T | F             (tolerated; records store 0/1)
--   table    { key value ... } keys (number or string) in EFV_SortedKeys order
-- Deterministic: equal values always encode to the same string.
-- ===========================================================================

if EFV_Records ~= nil and EFV_Records.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")

EFV_Records = {}

local ENCODE_PREFIX = "EFV1:"
local MAX_DEPTH     = 16            -- nesting guard for copy / encode / decode
local MAX_EXACT_INT = 9007199254740992  -- 2^53

-- Property keys written by Commit, in this fixed order, with the store field
-- that holds each value.
local COMMIT_ORDER = {
	{ key = "NEXT_ID",    field = "nextID"   },
	{ key = "RECORD_IDS", field = "ids"      },
	{ key = "RECORDS",    field = "recs"     },
	{ key = "PENDING",    field = "pending"  },
	{ key = "ENTRUST",    field = "entrust"  },
	{ key = "VET",        field = "vet"      },
	{ key = "LAST_TURN",  field = "lastTurn" },
}

-- Schema migrations: MIGRATIONS[n] upgrades schema n to n + 1. It receives
-- nothing and works directly on the properties (read, transform, write). Empty
-- while EFV_Config.SCHEMA_VERSION is 1.
local MIGRATIONS = {}

-- Record states in which onMapPlayerID / onMapUnitID are meaningful.
local ON_MAP_STATES = {}
ON_MAP_STATES[EFV_Config.ST_DEPLOYED] = true
ON_MAP_STATES[EFV_Config.ST_GRACE]    = true
ON_MAP_STATES[EFV_Config.ST_MUTINY]   = true

-- ===========================================================================
-- Local helpers
-- ===========================================================================

local function Prop(name)
	return EFV_Config.PROP[name]
end

local function RecKey(id)
	return "r" .. tostring(id)
end

local function CurrentTurn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

-- Sorted keys of t. Wraps EFV_SortedKeys so that an error (mixed key types)
-- surfaces as a Lua error with context for the caller's pcall.
local function Keys(t)
	local keys = EFV_SortedKeys(t)
	if type(keys) ~= "table" then
		error("EFV_SortedKeys returned " .. type(keys))
	end
	return keys
end

-- Deep copy of plain data (tables, numbers, strings, booleans).
local function DeepCopy(v, depth)
	if type(v) ~= "table" then
		return v
	end
	depth = depth or 0
	if depth > MAX_DEPTH then
		error("DeepCopy: nesting deeper than " .. MAX_DEPTH)
	end
	local t = {}
	for _, k in ipairs(Keys(v)) do
		t[k] = DeepCopy(v[k], depth + 1)
	end
	return t
end

-- Enforces the storage rules in place before a write (SPIKES S3): booleans
-- become 0/1; functions, userdata and threads are dropped (logged). Returns
-- the number of values changed.
local function Sanitize(t, path, depth)
	if type(t) ~= "table" then
		return 0
	end
	depth = depth or 0
	if depth > MAX_DEPTH then
		error("Sanitize: nesting deeper than " .. MAX_DEPTH .. " at " .. path)
	end
	local changed = 0
	for _, k in ipairs(Keys(t)) do
		local v = t[k]
		local tv = type(v)
		if tv == "boolean" then
			t[k] = v and 1 or 0
			changed = changed + 1
			EFV_Log(3, "Store", "sanitize %s.%s boolean -> %d", path, tostring(k), t[k])
		elseif tv == "function" or tv == "userdata" or tv == "thread" then
			t[k] = nil
			changed = changed + 1
			EFV_Log(1, "Store", "sanitize dropped %s.%s type=%s (not storable)", path, tostring(k), tv)
		elseif tv == "table" then
			changed = changed + Sanitize(v, path .. "." .. tostring(k), depth + 1)
		end
	end
	return changed
end

-- Dense array of numbers from an array-like value (ipairs; non-numbers are
-- skipped).
local function NumberArray(v)
	local out = {}
	if type(v) ~= "table" then
		return out
	end
	for _, x in ipairs(v) do
		if type(x) == "number" then
			out[#out + 1] = x
		end
	end
	return out
end

-- Raw property read; decodes an "EFV1:" string whatever the flag says, so a
-- save written with the other FLAG_PERSIST_AS_STRING setting still loads.
local function ReadProp(key)
	local ok, v = pcall(function() return Game:GetProperty(key) end)
	if not ok then
		EFV_Log(1, "Store", "GetProperty(%s) failed: %s", tostring(key), tostring(v))
		return nil
	end
	if type(v) == "string" and string.sub(v, 1, #ENCODE_PREFIX) == ENCODE_PREFIX then
		local decoded = EFV_Records.Decode(v)
		if decoded == nil then
			error("undecodable property " .. tostring(key))
		end
		return decoded, true
	end
	return v, false
end

-- Table-valued property as a fresh table ({} when missing).
local function ReadTableProp(key)
	local v, decoded = ReadProp(key)
	if v == nil then
		return {}
	end
	if type(v) ~= "table" then
		EFV_Log(1, "Store", "property %s has type %s, expected table; using {}", key, type(v))
		return {}
	end
	if decoded then
		return v  -- Decode already built fresh tables
	end
	return DeepCopy(v)
end

local function ReadNumberProp(key, default)
	local v = ReadProp(key)
	if type(v) == "number" then
		return v
	end
	if v ~= nil then
		EFV_Log(1, "Store", "property %s has type %s, expected number; using %s", key, type(v), tostring(default))
	end
	return default
end

-- Writes one property; table values are encoded when FLAG_PERSIST_AS_STRING.
-- Returns true on success. Gameplay only (the UI includes this file for
-- Decode and never reaches a write).
-- EFV:G-ONLY begin
local function WriteProp(key, value)
	if type(value) == "table" and EFV_Config.FLAG_PERSIST_AS_STRING then
		local s = EFV_Records.Encode(value)
		if s == nil then
			EFV_Log(1, "Store", "not writing %s: encode failed", key)
			return false
		end
		value = s
	end
	local ok, err = pcall(function() Game:SetProperty(key, value) end)
	if not ok then
		EFV_Log(1, "Store", "SetProperty(%s) failed: %s", key, tostring(err))
		return false
	end
	return true
end
-- EFV:G-ONLY end

local function EmptyStore()
	return {
		nextID   = 1,
		ids      = {},
		recs     = {},
		pending  = {},
		entrust  = {},
		vet      = {},
		lastTurn = -1,
		rev      = 0,
		dirty    = {},
	}
end

-- Nil-safe defaults for fields the property round trip may drop (see header).
-- Pure normalisation: does not mark the store dirty.
local function NormalizeRecord(rec)
	if type(rec.promotions) ~= "table" then
		rec.promotions = {}
	end
	if rec.lapsed == nil then
		rec.lapsed = 0
	end
	if rec.rerouted == nil then
		rec.rerouted = 0
	end
	if rec.spawnFailCount == nil then
		rec.spawnFailCount = 0
	end
	if rec.maintGoldPaid == nil then
		rec.maintGoldPaid = 0
	end
	if rec.veteranName == "" then
		rec.veteranName = nil
	end
end

local function NormalizeEntrust(entrust)
	for _, k in ipairs(Keys(entrust)) do
		local snap = entrust[k]
		if type(snap) == "table" and type(snap.recipients) ~= "table" then
			snap.recipients = {}
		end
		if type(snap) == "table" and type(snap.partners) ~= "table" then
			snap.partners = {}
		end
	end
end

-- Veteran jobs (0.7): keeps well-formed jobs only and fills the fields the
-- property round trip may drop (want = {} comes back nil, Session B).
-- Returns the cleaned array and the number of jobs dropped.
local function NormalizeVetJobs(list)
	local out, dropped = {}, 0
	for _, job in ipairs(list) do
		if type(job) == "table" and type(job.p) == "number" and type(job.u) == "number"
			and type(job.t) == "number" then
			local want = {}
			if type(job.want) == "table" then
				for _, name in ipairs(job.want) do
					if type(name) == "string" then
						want[#want + 1] = name
					end
				end
			end
			job.want = want
			job.got = tonumber(job.got) or 0
			job.n = tonumber(job.n) or 0
			job.xp = tonumber(job.xp) or 0
			job.dmg = tonumber(job.dmg) or 0
			out[#out + 1] = job
		else
			dropped = dropped + 1
		end
	end
	return out, dropped
end

-- (t, p, u) order of veteran jobs.
local function VetLess(a, b)
	if a.t ~= b.t then
		return a.t < b.t
	end
	if a.p ~= b.p then
		return a.p < b.p
	end
	return a.u < b.u
end

local function MarkDirty(store, name)
	if store.dirty == nil then
		store.dirty = {}
	end
	store.dirty[Prop(name)] = true
end

-- ===========================================================================
-- Public API
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- EFV_Records.Init()
-- PLAN 1.7 step 3. Seeds every missing key (EFV_NextID = 1, EFV_RecordIDs =
-- {}, EFV_Records = {}, EFV_PendingExhaust = {}, EFV_Entrust = {}, EFV_VetJobs =
-- {} (0.7), EFV_Schema
-- = EFV_Config.SCHEMA_VERSION, EFV_LastTurn = Game.GetCurrentGameTurn() - 1,
-- EFV_Rev = 0) and sets EFV_Init = 1 last. When EFV_Init is already set, runs
-- the schema migrations while EFV_Schema < EFV_Config.SCHEMA_VERSION. Caches
-- nothing in globals. Called once at gameplay script load (every new game and
-- every load); idempotent.
-- Params:  none.
-- Returns: nil.
-- PLAN 1.3, 1.7, 2.4; SPIKES S3 (WarMachine init guard). APIs: A06, A04.
-- ---------------------------------------------------------------------------
function EFV_Records.Init()
	local P = EFV_Config.PROP
	local initRaw = ReadProp(P.INIT)
	local fresh = (initRaw == nil)

	-- Seed only missing keys ("seed counters only if nil", SPIKES S3).
	local seeded = {}        -- scalar keys (a missing one is an error)
	local seededTables = {}  -- table keys (missing when empty; normal)
	-- isTable: an empty table property may not survive the save round trip
	-- (Session B), so re-seeding it on load is normal and logged at level 3.
	local seeds = {
		{ key = P.NEXT_ID,    make = function() return 1 end },
		{ key = P.RECORD_IDS, make = function() return {} end, isTable = true },
		{ key = P.RECORDS,    make = function() return {} end, isTable = true },
		{ key = P.PENDING,    make = function() return {} end, isTable = true },
		{ key = P.ENTRUST,    make = function() return {} end, isTable = true },
		{ key = P.VET,        make = function() return {} end, isTable = true },
		{ key = P.LAST_TURN,  make = function() return CurrentTurn() - 1 end },
		{ key = P.REV,        make = function() return 0 end },
	}
	if fresh then
		table.insert(seeds, 1, { key = P.SCHEMA, make = function() return EFV_Config.SCHEMA_VERSION end })
	end
	for _, s in ipairs(seeds) do
		local okR, cur = pcall(ReadProp, s.key)
		if okR and cur == nil then
			if WriteProp(s.key, s.make()) then
				if s.isTable then
					seededTables[#seededTables + 1] = s.key
				else
					seeded[#seeded + 1] = s.key
				end
			end
		elseif not okR then
			EFV_Log(1, "Init", "cannot read %s (%s); left unchanged", s.key, tostring(cur))
		end
	end

	if fresh then
		WriteProp(P.INIT, 1)
		EFV_Log(2, "Init", "store seeded schema=%d lastTurn=%d", EFV_Config.SCHEMA_VERSION, CurrentTurn() - 1)
		return nil
	end
	if #seeded > 0 then
		EFV_Log(1, "Init", "store had missing keys, seeded: %s", table.concat(seeded, ","))
	end
	if #seededTables > 0 then
		EFV_Log(3, "Init", "empty table keys re-seeded: %s", table.concat(seededTables, ","))
	end

	-- Schema migrations.
	local schema = ReadNumberProp(P.SCHEMA, 1)
	if schema > EFV_Config.SCHEMA_VERSION then
		EFV_Log(1, "Init", "save schema=%d is newer than this mod (schema=%d); loading as is",
			schema, EFV_Config.SCHEMA_VERSION)
	end
	while schema < EFV_Config.SCHEMA_VERSION do
		local migrate = MIGRATIONS[schema]
		if migrate == nil then
			EFV_Log(1, "Init", "no migration from schema=%d to %d; stopped", schema, schema + 1)
			break
		end
		local ok, err = pcall(migrate)
		if not ok then
			EFV_Log(1, "Init", "migration schema=%d failed: %s", schema, tostring(err))
			break
		end
		schema = schema + 1
		WriteProp(P.SCHEMA, schema)
		EFV_Log(2, "Init", "migrated store to schema=%d", schema)
	end
	EFV_Log(2, "Init", "store ok schema=%d", schema)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Load() -> store
-- Reads all keys of PLAN 1.3 (decoding "EFV1:" strings) into a fresh store
-- (deep copies). Missing keys become empty tables / defaults. Consistency
-- repair (logged as errors, persisted on the next commit): store.ids is
-- rebuilt from the record keys when they disagree (records are the source of
-- truth; IDs are ascending), rec.id is set from its key, nextID is raised
-- above the highest ID, malformed pending entries are dropped.
-- On an unexpected failure returns an empty store with broken = true, which
-- Commit refuses to write.
-- Call once per handler invocation; never cache the store across handlers.
-- Params:  none.
-- Returns: store table (never nil):
--   { nextID = n, ids = {id...}, recs = { ["r"..id] = rec }, pending = {
--     {p=,u=,t=}... }, entrust = { ["p"..plotIndex] = snap }, vet = { job
--     ... } (0.7; malformed jobs dropped, a missing want -> {}), lastTurn = n,
--     rev = n, dirty = {} }
-- PLAN 2.4. APIs: A06.
-- ---------------------------------------------------------------------------
function EFV_Records.Load()
	local P = EFV_Config.PROP
	local ok, result = pcall(function()
		local store = EmptyStore()
		store.recs     = ReadTableProp(P.RECORDS)
		store.pending  = ReadTableProp(P.PENDING)
		store.entrust  = ReadTableProp(P.ENTRUST)
		store.vet      = ReadTableProp(P.VET)
		store.nextID   = ReadNumberProp(P.NEXT_ID, 1)
		store.lastTurn = ReadNumberProp(P.LAST_TURN, -1)
		store.rev      = ReadNumberProp(P.REV, 0)
		local storedIDs = NumberArray(ReadTableProp(P.RECORD_IDS))

		-- IDs derived from the record keys ("r"..id), ascending.
		local ids = {}
		local maxID = 0
		for _, k in ipairs(Keys(store.recs)) do
			local id = nil
			if type(k) == "string" then
				id = tonumber(string.match(k, "^r(%d+)$"))
			end
			local rec = store.recs[k]
			if id == nil or type(rec) ~= "table" then
				EFV_Log(1, "Store", "load: dropped malformed record key=%s", tostring(k))
				store.recs[k] = nil
				MarkDirty(store, "RECORDS")
			else
				if rec.id ~= id then
					EFV_Log(1, "Store", "load: record key=%s had id=%s; fixed", k, tostring(rec.id))
					rec.id = id
					MarkDirty(store, "RECORDS")
				end
				NormalizeRecord(rec)
				ids[#ids + 1] = id
			end
		end
		table.sort(ids)
		if #ids > 0 then
			maxID = ids[#ids]
		end

		local same = (#ids == #storedIDs)
		if same then
			for i = 1, #ids do
				if ids[i] ~= storedIDs[i] then
					same = false
					break
				end
			end
		end
		if not same then
			EFV_Log(1, "Store", "load: EFV_RecordIDs (%d ids) disagrees with EFV_Records (%d records); rebuilt from records",
				#storedIDs, #ids)
			MarkDirty(store, "RECORD_IDS")
		end
		store.ids = ids

		if store.nextID <= maxID then
			EFV_Log(1, "Store", "load: nextID=%d <= max id=%d; raised", store.nextID, maxID)
			store.nextID = maxID + 1
			MarkDirty(store, "NEXT_ID")
		end

		-- Pending: keep dense, well-formed entries only.
		local pending = {}
		for _, e in ipairs(store.pending) do
			if type(e) == "table" and type(e.p) == "number" and type(e.u) == "number" then
				pending[#pending + 1] = e
			else
				EFV_Log(1, "Store", "load: dropped malformed pending entry")
				MarkDirty(store, "PENDING")
			end
		end
		store.pending = pending
		NormalizeEntrust(store.entrust)
		local vet, droppedVet = NormalizeVetJobs(store.vet)
		store.vet = vet
		if droppedVet > 0 then
			EFV_Log(1, "Store", "load: dropped %d malformed veteran job(s)", droppedVet)
			MarkDirty(store, "VET")
		end

		store.dirty = store.dirty or {}
		return store
	end)
	if ok then
		EFV_Log(3, "Store", "load rev=%d records=%d nextID=%d lastTurn=%d pending=%d vet=%d",
			result.rev, #result.ids, result.nextID, result.lastTurn, #result.pending, #result.vet)
		return result
	end
	EFV_Log(1, "Store", "load failed: %s; returning a broken empty store (commit disabled)", tostring(result))
	local store = EmptyStore()
	store.broken = true
	return store
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Commit(store)
-- Writes every property named in store.dirty with Game:SetProperty, in a
-- fixed order (table values always re-set; encoded with Encode when
-- FLAG_PERSIST_AS_STRING; records, pending and entrust sanitized first:
-- booleans -> 0/1, non-storable values dropped). If anything was written,
-- sets EFV_Rev = store.rev + 1 and store.rev to that value. Then clears
-- store.dirty. Refuses a store with broken = true. Unknown dirty keys are
-- logged and ignored. Scalar keys: nextID -> EFV_NextID, lastTurn ->
-- EFV_LastTurn (callers set store.dirty[EFV_Config.PROP.LAST_TURN]).
-- Params:  store.
-- Returns: nil.
-- PLAN 1.3, 2.4. APIs: A06.
-- ---------------------------------------------------------------------------
function EFV_Records.Commit(store)
	if type(store) ~= "table" then
		EFV_Log(1, "Store", "commit: no store")
		return nil
	end
	if store.broken then
		EFV_Log(1, "Store", "commit refused: store is broken (load failed)")
		store.dirty = {}
		return nil
	end
	local dirty = store.dirty or {}
	local known = {}
	local written = {}
	for _, entry in ipairs(COMMIT_ORDER) do
		local key = Prop(entry.key)
		known[key] = true
		if dirty[key] then
			local value = store[entry.field]
			local okS, errS = true, nil
			if type(value) == "table" and entry.field ~= "ids" then
				okS, errS = pcall(Sanitize, value, entry.field, 0)
			end
			if not okS then
				EFV_Log(1, "Store", "commit: sanitize %s failed: %s; not written", key, tostring(errS))
			elseif value == nil then
				EFV_Log(1, "Store", "commit: store.%s is nil; %s not written", entry.field, key)
			elseif WriteProp(key, value) then
				written[#written + 1] = key
			end
		end
	end
	-- Unknown dirty keys (typo in a caller) are reported, never written.
	local okK, dirtyKeys = pcall(Keys, dirty)
	if okK then
		for _, k in ipairs(dirtyKeys) do
			if not known[k] then
				EFV_Log(1, "Store", "commit: unknown dirty key %s ignored", tostring(k))
			end
		end
	end
	if #written > 0 then
		local newRev = (store.rev or 0) + 1
		if WriteProp(Prop("REV"), newRev) then
			store.rev = newRev
		end
		EFV_Log(3, "Store", "commit rev=%d keys=%s", store.rev, table.concat(written, ","))
	end
	store.dirty = {}
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.New(store, fields) -> rec
-- Creates a record: rec = deep copy of fields (booleans -> 0/1), rec.id =
-- store.nextID; store.nextID + 1; appends id to store.ids (ascending by
-- construction); stores under recs["r"..id]; marks EFV_NextID,
-- EFV_RecordIDs, EFV_Records dirty. fields must follow the record schema
-- (PLAN 1.4, INTERFACES); fields.id is ignored.
-- Params:  store, fields table (nil = empty record).
-- Returns: rec (the stored table; mutate it, then EFV_Records.Touch), or nil
--          when store is missing or fields cannot be copied.
-- PLAN 2.4; spec 13.3. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.New(store, fields)
	if type(store) ~= "table" then
		EFV_Log(1, "Store", "New: no store")
		return nil
	end
	local ok, rec = pcall(DeepCopy, fields or {}, 0)
	if not ok or type(rec) ~= "table" then
		EFV_Log(1, "Store", "New: cannot copy fields: %s", tostring(rec))
		return nil
	end
	pcall(Sanitize, rec, "new", 0)

	local id = store.nextID or 1
	local last = store.ids[#store.ids]
	if last ~= nil and id <= last then
		EFV_Log(1, "Store", "New: nextID=%d <= last id=%d; raised", id, last)
		id = last + 1
	end
	while store.recs[RecKey(id)] ~= nil do
		EFV_Log(1, "Store", "New: id=%d already used; skipped", id)
		id = id + 1
	end
	rec.id = id
	store.nextID = id + 1
	store.ids[#store.ids + 1] = id
	store.recs[RecKey(id)] = rec
	MarkDirty(store, "NEXT_ID")
	MarkDirty(store, "RECORD_IDS")
	MarkDirty(store, "RECORDS")
	EFV_Log(3, "Store", "new id=%d forceType=%s state=%s", id, tostring(rec.forceType), tostring(rec.state))
	return rec
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Get(store, id) -> rec
-- Params:  store, id number.
-- Returns: store.recs["r"..id] or nil.
-- PLAN 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.Get(store, id)
	if type(store) ~= "table" or type(store.recs) ~= "table" or id == nil then
		return nil
	end
	return store.recs[RecKey(id)]
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Delete(store, id) -> deleted
-- Removes recs["r"..id] and the id from store.ids (dense rebuild preserving
-- order); marks EFV_RecordIDs and EFV_Records dirty. Safe during iteration
-- over a copy from EFV_Records.IDs.
-- Params:  store, id number.
-- Returns: true if a record was deleted, false otherwise.
-- PLAN 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.Delete(store, id)
	if type(store) ~= "table" or id == nil then
		return false
	end
	local key = RecKey(id)
	local existed = (store.recs[key] ~= nil)
	local ids = {}
	local inIDs = false
	for _, x in ipairs(store.ids) do
		if x == id then
			inIDs = true
		else
			ids[#ids + 1] = x
		end
	end
	if not existed and not inIDs then
		return false
	end
	store.recs[key] = nil
	store.ids = ids
	MarkDirty(store, "RECORD_IDS")
	MarkDirty(store, "RECORDS")
	EFV_Log(3, "Store", "delete id=%s", tostring(id))
	return existed
end

-- ---------------------------------------------------------------------------
-- EFV_Records.IDs(store) -> ids
-- A COPY of store.ids (ascending), the only iteration order for records:
--   for _, id in ipairs(EFV_Records.IDs(store)) do ... end
-- (PLAN 1.6 writes EFV_Store.IDs; that is this function.)
-- Params:  store.
-- Returns: dense array of numbers.
-- PLAN 1.6, 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.IDs(store)
	local out = {}
	if type(store) ~= "table" or type(store.ids) ~= "table" then
		return out
	end
	for i, id in ipairs(store.ids) do
		out[i] = id
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Touch(store)
-- Marks EFV_Records dirty. Call after mutating fields of a record in place.
-- Params:  store.
-- Returns: nil.
-- PLAN 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.Touch(store)
	if type(store) == "table" then
		MarkDirty(store, "RECORDS")
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.MarkDirty(store, propKey)   (ADDED helper, not in PLAN 2.4)
-- store.dirty[propKey] = true for any EFV_Config.PROP value, e.g.
-- EFV_Records.MarkDirty(store, EFV_Config.PROP.ENTRUST) after editing
-- store.entrust, or PROP.LAST_TURN after setting store.lastTurn. Same effect
-- as writing store.dirty directly.
-- Params:  store, propKey string.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Records.MarkDirty(store, propKey)
	if type(store) ~= "table" or propKey == nil then
		return nil
	end
	if store.dirty == nil then
		store.dirty = {}
	end
	store.dirty[propKey] = true
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.FindByUnit(store, pid, uid) -> rec
-- Scan in store.ids order for a record in DEPLOYED / GRACE / MUTINY with
-- onMapPlayerID == pid and onMapUnitID == uid (first match).
-- Params:  store, pid player ID, uid unit ID.
-- Returns: rec or nil.
-- PLAN 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.FindByUnit(store, pid, uid)
	if type(store) ~= "table" or pid == nil or uid == nil then
		return nil
	end
	for _, id in ipairs(store.ids) do
		local rec = store.recs[RecKey(id)]
		if rec ~= nil and ON_MAP_STATES[rec.state]
			and rec.onMapPlayerID == pid and rec.onMapUnitID == uid then
			return rec
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.AddPending(store, pid, uid, turn)
-- Appends {p = pid, u = uid, t = turn} to store.pending (units whose moves
-- must be zeroed at PlayerTurnStartComplete(pid), SPIKES S10); marks
-- EFV_PendingExhaust dirty. A duplicate (same p and u) only updates t.
-- Params:  store, pid player ID, uid unit ID, turn number.
-- Returns: nil.
-- PLAN 1.3, 2.4, 2.5. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.AddPending(store, pid, uid, turn)
	if type(store) ~= "table" or type(pid) ~= "number" or type(uid) ~= "number" then
		EFV_Log(1, "Store", "AddPending: bad args pid=%s uid=%s", tostring(pid), tostring(uid))
		return nil
	end
	local t = turn
	if type(t) ~= "number" then
		t = CurrentTurn()
	end
	for _, e in ipairs(store.pending) do
		if e.p == pid and e.u == uid then
			e.t = t
			MarkDirty(store, "PENDING")
			return nil
		end
	end
	store.pending[#store.pending + 1] = { p = pid, u = uid, t = t }
	MarkDirty(store, "PENDING")
	EFV_Log(3, "Store", "pending add p=%d u=%d t=%d", pid, uid, t)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.TakePending(store, pid) -> entries
-- Removes and returns all pending entries of pid (dense array rebuild of the
-- rest, order preserved); marks EFV_PendingExhaust dirty if any were taken.
-- Params:  store, pid player ID.
-- Returns: dense array of {p=, u=, t=} in insertion order.
-- PLAN 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.TakePending(store, pid)
	local taken = {}
	if type(store) ~= "table" or type(store.pending) ~= "table" then
		return taken
	end
	local rest = {}
	for _, e in ipairs(store.pending) do
		if e.p == pid then
			taken[#taken + 1] = e
		else
			rest[#rest + 1] = e
		end
	end
	if #taken > 0 then
		store.pending = rest
		MarkDirty(store, "PENDING")
	end
	return taken
end

-- ---------------------------------------------------------------------------
-- EFV_Records.FindVetJob(store, pid, uid) -> job, index   (0.7, note 33)
-- The veteran route B job of unit (pid, uid), or nil.
-- Params:  store, pid owner player ID, uid unit ID.
-- Returns: job table and its index in store.vet, or nil.
-- ---------------------------------------------------------------------------
function EFV_Records.FindVetJob(store, pid, uid)
	if type(store) ~= "table" or type(store.vet) ~= "table" then
		return nil
	end
	for i, job in ipairs(store.vet) do
		if job.p == pid and job.u == uid then
			return job, i
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Records.AddVetJob(store, job) -> job   (0.7, note 33)
-- Adds a veteran job (EFV_Veteran shape) keeping store.vet sorted by
-- (t, p, u); an existing job of the same (p, u) is replaced. Marks
-- EFV_VetJobs dirty.
-- Params:  store, job table (p, u, t numbers required).
-- Returns: the stored job, or nil on bad arguments (logged).
-- ---------------------------------------------------------------------------
function EFV_Records.AddVetJob(store, job)
	if type(store) ~= "table" or type(job) ~= "table" or type(job.p) ~= "number"
		or type(job.u) ~= "number" or type(job.t) ~= "number" then
		EFV_Log(1, "Store", "AddVetJob: bad args")
		return nil
	end
	if type(store.vet) ~= "table" then
		store.vet = {}
	end
	local out = {}
	for _, j in ipairs(store.vet) do
		if not (j.p == job.p and j.u == job.u) then
			out[#out + 1] = j
		end
	end
	local pos = #out + 1
	for i, j in ipairs(out) do
		if VetLess(job, j) then
			pos = i
			break
		end
	end
	table.insert(out, pos, job)
	store.vet = out
	MarkDirty(store, "VET")
	return job
end

-- ---------------------------------------------------------------------------
-- EFV_Records.RemoveVetJob(store, pid, uid) -> removed   (0.7, note 33)
-- Removes the job of (pid, uid) (dense rebuild, order kept); marks
-- EFV_VetJobs dirty when one was removed.
-- Returns: true if a job was removed.
-- ---------------------------------------------------------------------------
function EFV_Records.RemoveVetJob(store, pid, uid)
	if type(store) ~= "table" or type(store.vet) ~= "table" then
		return false
	end
	local out, removed = {}, false
	for _, j in ipairs(store.vet) do
		if j.p == pid and j.u == uid then
			removed = true
		else
			out[#out + 1] = j
		end
	end
	if removed then
		store.vet = out
		MarkDirty(store, "VET")
	end
	return removed
end

-- ===========================================================================
-- Serializer (spec S3 fallback). Encode is gameplay-side; Decode is pure
-- string code and safe in the UI.
-- ===========================================================================

local function EncodeNumber(v)
	if v ~= v or v == math.huge or v == -math.huge then
		error("cannot encode non-finite number")
	end
	if v == math.floor(v) and v >= -MAX_EXACT_INT and v <= MAX_EXACT_INT then
		return string.format("%.0f", v)
	end
	return string.format("%.17g", v)
end

local function EncodeValue(v, out, depth)
	local tv = type(v)
	if tv == "number" then
		out[#out + 1] = "n" .. EncodeNumber(v) .. ";"
	elseif tv == "string" then
		out[#out + 1] = "s" .. tostring(#v) .. ":" .. v
	elseif tv == "boolean" then
		out[#out + 1] = v and "T" or "F"
	elseif tv == "table" then
		if depth > MAX_DEPTH then
			error("nesting deeper than " .. MAX_DEPTH)
		end
		out[#out + 1] = "{"
		for _, k in ipairs(Keys(v)) do
			local tk = type(k)
			if tk ~= "number" and tk ~= "string" then
				error("unsupported key type " .. tk)
			end
			EncodeValue(k, out, depth + 1)
			EncodeValue(v[k], out, depth + 1)
		end
		out[#out + 1] = "}"
	else
		error("unsupported value type " .. tv)
	end
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Encode(v) -> s
-- SPIKES S3 fallback serializer: deterministic text for a value made of
-- tables (sorted keys), numbers, strings and booleans; prefix "EFV1:".
-- Integers are exact up to 2^53; other numbers use "%.17g" (round-trips).
-- Params:  v value.
-- Returns: string, or nil (logged) for unsupported content (functions,
--          userdata, NaN/inf, mixed key types, nesting > 16).
-- PLAN 1.3, 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.Encode(v)
	local out = {}
	local ok, err = pcall(EncodeValue, v, out, 0)
	if not ok then
		EFV_Log(1, "Store", "encode failed: %s", tostring(err))
		return nil
	end
	return ENCODE_PREFIX .. table.concat(out)
end

-- Returns value, nextPos. Errors on malformed input.
local function DecodeValue(s, pos, depth)
	local c = string.sub(s, pos, pos)
	if c == "n" then
		local e = string.find(s, ";", pos + 1, true)
		if e == nil then
			error("unterminated number at " .. pos)
		end
		local num = tonumber(string.sub(s, pos + 1, e - 1))
		if num == nil then
			error("bad number at " .. pos)
		end
		return num, e + 1
	elseif c == "s" then
		local colon = string.find(s, ":", pos + 1, true)
		if colon == nil then
			error("unterminated string length at " .. pos)
		end
		local lenStr = string.sub(s, pos + 1, colon - 1)
		if string.match(lenStr, "^%d+$") == nil then
			error("bad string length at " .. pos)
		end
		local len = tonumber(lenStr)
		local stop = colon + len
		if stop > #s then
			error("string runs past end at " .. pos)
		end
		return string.sub(s, colon + 1, stop), stop + 1
	elseif c == "T" then
		return true, pos + 1
	elseif c == "F" then
		return false, pos + 1
	elseif c == "{" then
		if depth > MAX_DEPTH then
			error("nesting deeper than " .. MAX_DEPTH)
		end
		local t = {}
		pos = pos + 1
		while true do
			local d = string.sub(s, pos, pos)
			if d == "}" then
				return t, pos + 1
			end
			if d == "" then
				error("unterminated table")
			end
			local k
			k, pos = DecodeValue(s, pos, depth + 1)
			if type(k) ~= "number" and type(k) ~= "string" then
				error("bad key type " .. type(k) .. " at " .. pos)
			end
			if k ~= k then
				error("NaN key at " .. pos)
			end
			if t[k] ~= nil then
				error("duplicate key " .. tostring(k))
			end
			local v
			v, pos = DecodeValue(s, pos, depth + 1)
			t[k] = v
		end
	end
	error("unexpected '" .. c .. "' at " .. pos)
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Decode(s) -> v
-- Inverse of Encode. Also used by the UI (EFV_UI_ReadStore) when
-- FLAG_PERSIST_AS_STRING. Uses only string functions and EFV_Log.
-- Params:  s string.
-- Returns: value, or nil on malformed input (logged; a non-string or a string
--          without the "EFV1:" prefix returns nil quietly at log level 3).
-- PLAN 1.3, 2.4. APIs: none.
-- ---------------------------------------------------------------------------
function EFV_Records.Decode(s)
	if type(s) ~= "string" or string.sub(s, 1, #ENCODE_PREFIX) ~= ENCODE_PREFIX then
		EFV_Log(3, "Store", "decode: not an %s string (%s)", ENCODE_PREFIX, type(s))
		return nil
	end
	local ok, v, nextPos = pcall(DecodeValue, s, #ENCODE_PREFIX + 1, 0)
	if not ok then
		EFV_Log(1, "Store", "decode failed: %s", tostring(v))
		return nil
	end
	if nextPos ~= #s + 1 then
		EFV_Log(1, "Store", "decode failed: trailing data at %d of %d", nextPos, #s)
		return nil
	end
	return v
end

-- ===========================================================================
-- Dump
-- ===========================================================================

-- Readable, deterministic text of a value (sorted keys).
local function ToText(v, depth)
	local tv = type(v)
	if tv == "string" then
		return string.format("%q", v)
	elseif tv ~= "table" then
		return tostring(v)
	end
	if depth > MAX_DEPTH then
		return "{...}"
	end
	local keys = Keys(v)
	-- Dense 1..n arrays print as {a,b,c}.
	local isArray = true
	for i, k in ipairs(keys) do
		if k ~= i then
			isArray = false
			break
		end
	end
	local parts = {}
	for _, k in ipairs(keys) do
		local vs = ToText(v[k], depth + 1)
		if isArray then
			parts[#parts + 1] = vs
		else
			parts[#parts + 1] = tostring(k) .. "=" .. vs
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function SafeText(v)
	local ok, s = pcall(ToText, v, 0)
	if ok then
		return s
	end
	return "<unprintable: " .. tostring(s) .. ">"
end

-- ---------------------------------------------------------------------------
-- EFV_Records.Dump(store)
-- Sorted-key text dump of the whole store to Lua.log, tag "Dump", at log
-- level 2 (save/load test P1.4, dev command "dump"). Lines:
--   begin rev= nextID= lastTurn= records= pending= entrust= [broken=1]
--   ids={...}
--   r<id> {field=value,...}        one line per record, in ids order
--   pending {...}
--   vet {...}                      one line per veteran job (0.7)
--   entrust p<idx> {...}           one line per snapshot, sorted keys
--   end
-- Two dumps of equal stores produce identical text.
-- Params:  store (nil -> dumps a fresh EFV_Records.Load()).
-- Returns: nil.
-- PLAN 2.4, 5.0. APIs: A56.
-- ---------------------------------------------------------------------------
function EFV_Records.Dump(store)
	if store == nil then
		store = EFV_Records.Load()
	end
	local ok, err = pcall(function()
		local entrustKeys = Keys(store.entrust or {})
		EFV_Log(2, "Dump", "begin rev=%s nextID=%s lastTurn=%s records=%d pending=%d entrust=%d%s",
			tostring(store.rev), tostring(store.nextID), tostring(store.lastTurn),
			#(store.ids or {}), #(store.pending or {}), #entrustKeys,
			store.broken and " broken=1" or "")
		EFV_Log(2, "Dump", "ids=%s", SafeText(store.ids or {}))
		for _, id in ipairs(store.ids or {}) do
			EFV_Log(2, "Dump", "r%s %s", tostring(id), SafeText(store.recs[RecKey(id)]))
		end
		EFV_Log(2, "Dump", "pending %s", SafeText(store.pending or {}))
		for _, job in ipairs(store.vet or {}) do
			EFV_Log(2, "Dump", "vet %s", SafeText(job))
		end
		for _, k in ipairs(entrustKeys) do
			EFV_Log(2, "Dump", "entrust %s %s", tostring(k), SafeText(store.entrust[k]))
		end
		EFV_Log(2, "Dump", "end")
	end)
	if not ok then
		EFV_Log(1, "Dump", "dump failed: %s", tostring(err))
	end
	return nil
end

EFV_Records.LOADED = 1
