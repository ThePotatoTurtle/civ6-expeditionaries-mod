-- ===========================================================================
-- fake_engine.lua  (T2 offline harness, PLAN 6.5)
-- A small, deterministic imitation of the Civ VI gameplay Lua API used by
-- EFV (PLAN Appendix A), for lupa's Lua 5.1 runtime. Loaded fresh for every
-- test by tests/offline/run_tests.py, before lib/harness.lua.
--
-- Globals provided: Game, Players, PlayerManager, PlayerConfigurations, Map,
-- Units, UnitManager, CityManager, GameInfo, GameConfiguration, GameEvents,
-- Events, LuaEvents, NotificationManager, Locale, DealManager, include, and
-- the enum tables used by EFV (DirectionTypes, MapLayers, DomainTypes,
-- MilitaryFormationTypes, WarTypes, CityTransferTypes, ParameterTypes, ...).
--
-- All mutable state lives in the global table FAKE so tests can inspect it.
-- Python injects: __py_read(path) -> text|nil, __py_find(name) -> relpath|nil,
-- __py_echo(line) (verbose mode), FAKE_GAMEINFO (DB rows), FAKE_TEXT
-- (LOC key -> text), FAKE_EXTRA_TYPES (extra Types rows).
--
-- In-game facts mirrored here (WP1.7, SESSION_A/B reports):
--   * gameplay-context availability (Session A T09): Player:IsFreeCities,
--     Unit:IsCannotAttack, Diplomacy:HasOpenBordersFrom, Exp:GetLevel and
--     Exp:GetPromotions are nil in G and exist only while FAKE.context == "UI";
--   * open borders are read in G through DealManager.GetPlayerDeals (an
--     OPEN_BORDERS agreement item per H.openBorders pair; nil when no deal).
--     Items carry their giver (GetFromPlayerID), GetEnactedTurn and
--     GetDuration (Session D T09/T19: CONFIRMED-INGAME for presence, absence
--     and the expiry turn; the one-way direction is Session F T27);
--   * open-borders expiry (Session D 2.3): an agreement enacted on turn E0
--     with duration D ends on turn E0 + D. On that turn the deal is still
--     listed at OnGameTurnStarted; at the turn start of each receiving
--     player (between its PlayerTurnStarted and PlayerTurnStartComplete,
--     FAKE.ExpireOpenBorders called by the harness) the agreement is removed
--     and that player's units inside the grantor's borders are moved to the
--     nearest land tile outside them (same unit ID, damage, XP; neutral land
--     1-3 tiles away in game), never home;
--   * the Game property round trip drops empty strings and empty tables
--     (Session B T08/T10), when FAKE.dropEmpty (default true);
--   * stale unit objects (Session F 1.3, 0.5.2): FindID (and Members) still
--     return a unit killed in combat for the rest of the frame (damage 100,
--     FAKE.CombatKill / H.combat), an upgraded unit's old object for the rest
--     of the turn (FAKE.UpgradeUnit: the new unit gets a NEW ID on the same
--     plot, T30) and a levied unit's old object at -9999,-9999 until the next
--     turn start (FAKE.LevyTransfer: new IDs, originalOwner kept, tile kept
--     or shifted, T28). These "ghosts" live in FAKE.ghosts, never heal and
--     expire through FAKE.ExpireGhosts (called by the harness turn loop).
--     Whether the engine still lists them in Units.GetUnitsInPlot is
--     unmeasured: FAKE.ghostsInPlot (default true = worst case);
--   * T08 (Session F): a unit created by script is level 1 whatever
--     promotions SetPromotion gives it, and ChangeExperience never raises XP
--     above the current next-level threshold (a pending promotion);
--   * every script write of unit damage is recorded in FAKE.damageWrites
--     ({ id, owner, from, to, turn, ghost }; the harness heal writes
--     directly and is not recorded).
--
-- Hex layout: Civ VI "odd-r" offset coordinates, y = 0 at the south edge,
-- odd rows shifted half a hex east. Directions (DirectionTypes) 0..5 =
-- NE, E, SE, SW, W, NW. X wraps when FAKE.map.wrapX (default true).
-- ===========================================================================

FAKE = {
	turn = 1,
	log = {},                -- every print() line, in order
	echo = false,            -- set by the runner (-v): mirror print to stdout
	props = {},              -- Game properties (deep-copied in/out)
	propViolations = {},     -- SPIKES S3 storage-rule violations seen by SetProperty
	propWrites = {},         -- key -> number of SetProperty calls
	rngSeed = 20260928,
	rngCalls = {},           -- { n, label, result }
	forbidden = {},          -- MP-unsafe calls seen in gameplay (math.random, Game.GetLocalPlayer)
	handlerErrors = {},      -- errors raised by event handlers
	map = nil,
	players = {},            -- id -> player object
	units = {},              -- id -> unit object (alive)
	nextUnitID = 131072,     -- engine-like large IDs
	cities = {},             -- key "p..id" is not used; cities[cityObj] list below
	cityList = {},           -- array of alive city objects
	nextCityID = 65536,
	notifications = {},      -- { pid, typeName, hash, data, id, dismissed }
	nextNotifID = 1,
	freeCitiesID = 62,
	barbarianID = 63,
	gameSpeed = "GAMESPEED_STANDARD",
	context = "G",           -- "G" gameplay (UI == nil) or "UI"
	killLog = {},            -- units removed: { id, owner, how = "DESTROY"|"KILL"|"DEATH" }
	dropEmpty = true,        -- Game property round trip drops "" and {} (Session B)
	closedBorders = true,    -- Create/InitUnit return nil on a plot the owner may not enter (Session D 3)
	createNil = nil,         -- test hook fn(pid, x, y) -> true: Create/InitUnit return nil there
	createRefused = {},      -- { pid, x, y, why } for every refused Create/InitUnit
	ghosts = {},             -- id -> stale unit object FindID still returns (Session F 1.3)
	ghostsInPlot = true,     -- ghosts on a plot still listed by Units.GetUnitsInPlot (unmeasured: worst case)
	combatDamageBeforeEvent = true, -- H.combat applies damage before GameEvents.OnCombatOccurred (T31 open)
	damageWrites = {},       -- { id, owner, from, to, turn, ghost } for every Unit:SetDamage / ChangeDamage
}

-- ---------------------------------------------------------------------------
-- Output capture
-- ---------------------------------------------------------------------------
local rawprint = print
function print(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, "\t")
	FAKE.log[#FAKE.log + 1] = line
	if FAKE.echo and __py_echo ~= nil then
		__py_echo(line)
	end
end

-- MP-unsafe calls are recorded (PLAN 6.3 forbidden patterns), not blocked.
local realRandom = math.random
math.random = function(...)
	FAKE.forbidden[#FAKE.forbidden + 1] = "math.random"
	return realRandom(...)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function DeepCopy(v, seen)
	if type(v) ~= "table" then
		return v
	end
	seen = seen or {}
	if seen[v] then
		return seen[v]
	end
	local c = {}
	seen[v] = c
	for k, x in pairs(v) do
		c[DeepCopy(k, seen)] = DeepCopy(x, seen)
	end
	return c
end
FAKE.DeepCopy = DeepCopy

local function SortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)
	return keys
end
FAKE.SortedKeys = SortedKeys

-- SPIKES S3 storage rules: string keys or dense 1..n arrays, no key 0, no
-- holes, only numbers / strings / tables inside (booleans reported too,
-- PLAN 1.3 stores them as 0/1).
local function ValidateStored(v, path, out)
	local tv = type(v)
	if tv == "number" or tv == "string" or tv == "nil" then
		return
	end
	if tv == "boolean" then
		out[#out + 1] = path .. ": boolean value (store 0/1)"
		return
	end
	if tv ~= "table" then
		out[#out + 1] = path .. ": unsupported type " .. tv
		return
	end
	local nStr, nNum, maxN, count = 0, 0, 0, 0
	for k, x in pairs(v) do
		count = count + 1
		if type(k) == "string" then
			nStr = nStr + 1
		elseif type(k) == "number" then
			if k == 0 then
				out[#out + 1] = path .. ": key 0"
			elseif k ~= math.floor(k) or k < 0 then
				out[#out + 1] = path .. ": non-integer or negative key " .. tostring(k)
			else
				nNum = nNum + 1
				if k > maxN then
					maxN = k
				end
			end
		else
			out[#out + 1] = path .. ": key of type " .. type(k)
		end
		ValidateStored(x, path .. "." .. tostring(k), out)
	end
	if nStr > 0 and nNum > 0 then
		out[#out + 1] = path .. ": mixed string and number keys"
	end
	if nNum > 0 and maxN ~= nNum then
		out[#out + 1] = path .. ": array with holes (max " .. maxN .. ", count " .. nNum .. ")"
	end
end
FAKE.ValidateStored = ValidateStored

-- Session B T08/T10: an empty string (and, per the integration notes, an
-- empty table) inside a Game property comes back as nil.
local function StripEmpty(v)
	if type(v) == "string" and v == "" then
		return nil
	end
	if type(v) ~= "table" then
		return v
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	for _, k in ipairs(keys) do
		v[k] = StripEmpty(v[k])
	end
	if next(v) == nil then
		return nil
	end
	return v
end
FAKE.StripEmpty = StripEmpty

local function NewPropertyHolder(label, store)
	return {
		SetProperty = function(self, k, v)
			local issues = {}
			ValidateStored(v, label .. "[" .. tostring(k) .. "]", issues)
			for _, s in ipairs(issues) do
				FAKE.propViolations[#FAKE.propViolations + 1] = s
			end
			if store == FAKE.props then
				FAKE.propWrites[k] = (FAKE.propWrites[k] or 0) + 1
			end
			local copy = DeepCopy(v)
			if FAKE.dropEmpty and label == "Game" then
				copy = StripEmpty(copy)
			end
			store[k] = copy
		end,
		GetProperty = function(self, k)
			return DeepCopy(store[k])
		end,
	}
end

-- ---------------------------------------------------------------------------
-- Enums (values are arbitrary but stable)
-- ---------------------------------------------------------------------------
DirectionTypes = {
	DIRECTION_NORTHEAST = 0, DIRECTION_EAST = 1, DIRECTION_SOUTHEAST = 2,
	DIRECTION_SOUTHWEST = 3, DIRECTION_WEST = 4, DIRECTION_NORTHWEST = 5,
	NUM_DIRECTION_TYPES = 6, NO_DIRECTION = -1,
}
MapLayers = { ANY = -1, DEFAULT = 0, TRADE = 1, SPY = 2, RELIGIOUS = 3 }
DomainTypes = { DOMAIN_SEA = 0, DOMAIN_AIR = 1, DOMAIN_LAND = 2, DOMAIN_SPACE = 3 }
MilitaryFormationTypes = {
	STANDARD_FORMATION = 0, CORPS_FORMATION = 1, ARMY_FORMATION = 2,
	STANDARD_MILITARY_FORMATION = 0, CORPS_MILITARY_FORMATION = 1, ARMY_MILITARY_FORMATION = 2,
}
WarTypes = { SURPRISE_WAR = 0, FORMAL_WAR = 1 }
CityTransferTypes = { BY_GIFT = 0, BY_COMBAT = 1, BY_SETTLEMENT = 2, BY_REVOLT = 3, BY_TRADE = 4 }
ParameterTypes = { MESSAGE = "MESSAGE", SUMMARY = "SUMMARY", LOCATION = "LOCATION", PLAYER_ID = "PLAYER_ID" }
PlayerOperations = { EXECUTE_SCRIPT = 1 }
UnitOperationTypes = { PARAM_FLAGS = "PARAM_FLAGS", PARAM_X = "PARAM_X", PARAM_Y = "PARAM_Y" }
YieldTypes = { FOOD = 0, PRODUCTION = 1, GOLD = 2, SCIENCE = 3, CULTURE = 4, FAITH = 5 }
DealItemTypes = { AGREEMENTS = 1 }
DealAgreementTypes = { OPEN_BORDERS = 1, MAKE_PEACE = 2 }

-- ---------------------------------------------------------------------------
-- Event registries: GameEvents.X.Add(fn) / .Remove(fn) / GameEvents.X(...)
-- ---------------------------------------------------------------------------
local function NewEvent(fullName)
	local ev = { name = fullName, handlers = {} }
	ev.Add = function(fn)
		ev.handlers[#ev.handlers + 1] = fn
	end
	ev.Remove = function(fn)
		for i = #ev.handlers, 1, -1 do
			if ev.handlers[i] == fn then
				table.remove(ev.handlers, i)
			end
		end
	end
	ev.Count = function()
		return #ev.handlers
	end
	return setmetatable(ev, {
		__call = function(self, ...)
			local list = {}
			for i, fn in ipairs(self.handlers) do
				list[i] = fn
			end
			for _, fn in ipairs(list) do
				local ok, err = pcall(fn, ...)
				if not ok then
					FAKE.handlerErrors[#FAKE.handlerErrors + 1] = fullName .. ": " .. tostring(err)
					print("Runtime Error: " .. fullName .. " handler: " .. tostring(err))
				end
			end
		end,
	})
end

local function NewEventNamespace(ns)
	return setmetatable({}, {
		__index = function(t, name)
			local ev = NewEvent(ns .. "." .. tostring(name))
			rawset(t, name, ev)
			return ev
		end,
	})
end
GameEvents = NewEventNamespace("GameEvents")
Events = NewEventNamespace("Events")
LuaEvents = NewEventNamespace("LuaEvents")

-- ---------------------------------------------------------------------------
-- GameInfo (rows from the cached gameplay DB, injected as FAKE_GAMEINFO)
-- GameInfo.T[key] accepts the primary-key string, the 0-based Index or the
-- Hash; GameInfo.T() iterates rows in Index order.
-- ---------------------------------------------------------------------------
local function HashString(s)
	-- FNV-1a 32-bit, returned as a signed int like the engine's hashes.
	local h = 2166136261
	for i = 1, string.len(s) do
		h = h - (h % 1) -- keep integer
		local b = string.byte(s, i)
		-- xor via arithmetic (Lua 5.1 has no bit ops)
		local x, y, r, m = h, b, 0, 1
		for _ = 1, 32 do
			local xa, ya = x % 2, y % 2
			if xa ~= ya then
				r = r + m
			end
			x = (x - xa) / 2
			y = (y - ya) / 2
			m = m * 2
		end
		h = (r * 16777619) % 4294967296
	end
	if h >= 2147483648 then
		h = h - 4294967296
	end
	return h
end
FAKE.HashString = HashString

GameInfo = {}
local typeHash = {}

local function BuildTable(name, spec)
	local byKey, byIndex, byHash, rows = {}, {}, {}, {}
	for i, src in ipairs(spec.rows) do
		local row = {}
		for k, v in pairs(src) do
			row[k] = v
		end
		row.Index = i - 1
		local pk = spec.pk and row[spec.pk] or nil
		if pk ~= nil and row.Hash == nil then
			row.Hash = typeHash[pk] or HashString(pk)
		end
		rows[#rows + 1] = row
		byIndex[row.Index] = row
		if pk ~= nil then
			byKey[pk] = row
		end
		if row.Hash ~= nil then
			byHash[row.Hash] = row
		end
	end
	local t = { __rows = rows }
	setmetatable(t, {
		__index = function(_, k)
			if type(k) == "string" then
				return byKey[k]
			elseif type(k) == "number" then
				return byIndex[k] or byHash[k]
			end
			return nil
		end,
		__call = function()
			local i = 0
			return function()
				i = i + 1
				return rows[i]
			end
		end,
	})
	GameInfo[name] = t
end

function FAKE.LoadGameInfo(data, extraTypes)
	-- Types first so other tables can reuse the engine hashes.
	if data.Types ~= nil then
		local seen = {}
		for _, r in ipairs(data.Types.rows) do
			typeHash[r.Type] = r.Hash
			seen[r.Type] = true
		end
		for _, tn in ipairs(extraTypes or {}) do
			if not seen[tn] then
				local h = HashString(tn)
				data.Types.rows[#data.Types.rows + 1] = { Type = tn, Hash = h, Kind = "KIND_NOTIFICATION" }
				typeHash[tn] = h
				seen[tn] = true
			end
		end
	end
	for _, name in ipairs(SortedKeys(data)) do
		BuildTable(name, data[name])
	end
end

-- ---------------------------------------------------------------------------
-- Game
-- ---------------------------------------------------------------------------
Game = NewPropertyHolder("Game", FAKE.props)
Game.GetCurrentGameTurn = function()
	return FAKE.turn
end
Game.GetRandNum = function(n, label)
	FAKE.rngSeed = (FAKE.rngSeed * 1103515245 + 12345) % 2147483648
	local r = 0
	if type(n) == "number" and n > 0 then
		r = FAKE.rngSeed % n
	end
	FAKE.rngCalls[#FAKE.rngCalls + 1] = { n = n, label = label, result = r }
	return r
end
Game.GetLocalPlayer = function()
	if FAKE.context == "G" then
		FAKE.forbidden[#FAKE.forbidden + 1] = "Game.GetLocalPlayer"
	end
	return FAKE.localPlayer or 0
end

GameConfiguration = {
	GetGameSpeedType = function()
		local row = GameInfo.GameSpeeds[FAKE.gameSpeed]
		return row and row.Hash or nil
	end,
	GetValue = function(k)
		if k == "GAMESPEED_TYPE" then
			local row = GameInfo.GameSpeeds[FAKE.gameSpeed]
			return row and row.Hash or nil
		end
		return nil
	end,
	GetMapSize = function()
		return FAKE.map and FAKE.map.sizeHash or nil
	end,
}

-- ---------------------------------------------------------------------------
-- Map and plots
-- ---------------------------------------------------------------------------
local Plot = {}
Plot.__index = Plot

local WATER = { OCEAN = true, COAST = true, LAKE = true }

function Plot:GetX() return self.x end
function Plot:GetY() return self.y end
function Plot:GetIndex() return self.index end
function Plot:IsWater() return WATER[self.terrain] == true end
function Plot:IsLake() return self.terrain == "LAKE" end
function Plot:IsMountain() return self.terrain == "MOUNTAIN" end
function Plot:IsImpassable() return self.terrain == "MOUNTAIN" or self.impassable == true end
function Plot:IsNaturalWonder() return self.wonder == true end
function Plot:GetOwner() return self.owner or -1 end
function Plot:IsOwned() return (self.owner or -1) >= 0 end
function Plot:IsCity() return CityManager.GetCityAt(self.x, self.y) ~= nil end
function Plot:GetTerrainType() return self.terrain end
function Plot:GetUnitCount()
	local n = 0
	for _, u in pairs(FAKE.units) do
		if u.x == self.x and u.y == self.y then
			n = n + 1
		end
	end
	return n
end
function Plot:GetArea()
	local m = FAKE.map
	if m.areaDirty then
		FAKE.ComputeAreas()
	end
	local id = m.areaOf[self.index]
	local size = m.areaSize[id] or 1
	return {
		GetID = function() return id end,
		GetPlotCount = function() return size end,
		IsWater = function() return WATER[self.terrain] == true end,
	}
end

local function NormX(x)
	local m = FAKE.map
	if m.wrapX then
		return x % m.w
	end
	return x
end

local function ToAxial(x, y)
	-- odd-r offset -> axial (q, r)
	local q = x - (y - (y % 2)) / 2
	return q, y
end

local function RawDistance(x1, y1, x2, y2)
	local q1, r1 = ToAxial(x1, y1)
	local q2, r2 = ToAxial(x2, y2)
	local dq, dr = q2 - q1, r2 - r1
	return (math.abs(dq) + math.abs(dr) + math.abs(dq + dr)) / 2
end

local ADJ_EVEN = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, -1 }, { -1, 0 }, { -1, 1 } }
local ADJ_ODD  = { { 1, 1 }, { 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, 0 }, { 0, 1 } }

Map = {}
function Map.GetGridSize()
	return FAKE.map.w, FAKE.map.h
end
function Map.GetPlotCount()
	return FAKE.map.w * FAKE.map.h
end
function Map.IsWrapX()
	return FAKE.map.wrapX
end
function Map.GetPlot(x, y)
	local m = FAKE.map
	if type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	if y < 0 or y >= m.h then
		return nil
	end
	x = NormX(x)
	if x < 0 or x >= m.w then
		return nil
	end
	return m.plots[y * m.w + x]
end
function Map.GetPlotByIndex(i)
	return FAKE.map.plots[i]
end
function Map.GetPlotDistance(x1, y1, x2, y2)
	local m = FAKE.map
	local d = RawDistance(x1, y1, x2, y2)
	if m.wrapX then
		local d2 = RawDistance(x1, y1, x2 + m.w, y2)
		local d3 = RawDistance(x1, y1, x2 - m.w, y2)
		if d2 < d then d = d2 end
		if d3 < d then d = d3 end
	end
	return d
end
function Map.GetAdjacentPlot(x, y, dir)
	if dir == nil or dir < 0 or dir > 5 then
		return nil
	end
	local off = (y % 2 == 0) and ADJ_EVEN[dir + 1] or ADJ_ODD[dir + 1]
	return Map.GetPlot(x + off[1], y + off[2])
end
-- All plots within range r, centre included, in DESCENDING index order so
-- callers that forget to sort by GetIndex() are caught by the tests.
function Map.GetNeighborPlots(x, y, r)
	local out = {}
	local m = FAKE.map
	for yy = y - r, y + r do
		for xx = x - r - 1, x + r + 1 do
			local p = Map.GetPlot(xx, yy)
			if p ~= nil and Map.GetPlotDistance(x, y, p.x, p.y) <= r then
				out[#out + 1] = p
			end
		end
	end
	-- dedupe (wrap can revisit) and sort descending
	local seen, res = {}, {}
	for _, p in ipairs(out) do
		if not seen[p.index] then
			seen[p.index] = true
			res[#res + 1] = p
		end
	end
	table.sort(res, function(a, b) return a.index > b.index end)
	return res
end

function FAKE.ComputeAreas()
	local m = FAKE.map
	m.areaOf, m.areaSize = {}, {}
	local nextID = 1
	for i = 0, m.w * m.h - 1 do
		if m.areaOf[i] == nil then
			local p0 = m.plots[i]
			local water = WATER[p0.terrain] == true
			local stack, count = { p0 }, 0
			m.areaOf[i] = nextID
			while #stack > 0 do
				local p = table.remove(stack)
				count = count + 1
				for dir = 0, 5 do
					local q = Map.GetAdjacentPlot(p.x, p.y, dir)
					if q ~= nil and m.areaOf[q.index] == nil and (WATER[q.terrain] == true) == water then
						m.areaOf[q.index] = nextID
						stack[#stack + 1] = q
					end
				end
			end
			m.areaSize[nextID] = count
			nextID = nextID + 1
		end
	end
	m.areaDirty = false
end

function FAKE.NewMap(w, h, wrapX, terrain)
	local m = { w = w, h = h, wrapX = (wrapX ~= false), plots = {}, areaDirty = true, areaOf = {}, areaSize = {} }
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local idx = y * w + x
			m.plots[idx] = setmetatable({ x = x, y = y, index = idx, terrain = terrain or "LAND", owner = -1 }, Plot)
		end
	end
	FAKE.map = m
	return m
end

-- ---------------------------------------------------------------------------
-- Units
-- ---------------------------------------------------------------------------
local Unit = {}
local UnitUI = {}   -- UI-only unit methods (nil in G, Session A T09)
Unit.__index = function(t, k)
	local v = Unit[k]
	if v == nil and FAKE.context == "UI" then
		return UnitUI[k]
	end
	return v
end
local Exp = {}
local ExpUI = {}    -- UI-only experience methods (nil in G, Session A T09)
Exp.__index = function(t, k)
	local v = Exp[k]
	if v == nil and FAKE.context == "UI" then
		return ExpUI[k]
	end
	return v
end
local function ExpLevel(exp)
	if exp.unit.level ~= nil then
		return exp.unit.level   -- script-created unit: level 1 (Session F T08)
	end
	local n = 0
	for _ in pairs(exp.unit.promotions) do n = n + 1 end
	return n + 1
end

function Exp:GetExperiencePoints() return self.unit.xp end
function Exp:GetExperienceForNextLevel()
	local L = ExpLevel(self)
	return 15 * L * (L + 1) / 2
end
function Exp:ChangeExperience(d)
	-- Session B / F T08: capped at the next-level threshold (promotion pending).
	local v = math.max(0, self.unit.xp + (d or 0))
	local cap = self:GetExperienceForNextLevel()
	if (d or 0) > 0 and v > cap then
		v = math.max(self.unit.xp, cap)
	end
	self.unit.xp = v
end
function Exp:SetExperience(v) self.unit.xp = v end
function Exp:HasPromotion(idx) return self.unit.promotions[idx] == true end
function Exp:SetPromotion(idx)
	if GameInfo.UnitPromotions[idx] == nil then
		error("SetPromotion: unknown promotion index " .. tostring(idx))
	end
	self.unit.promotions[idx] = true
end
function ExpUI.GetLevel(self)
	return ExpLevel(self)
end
function ExpUI.GetPromotions(self)
	local out = {}
	for _, k in ipairs(SortedKeys(self.unit.promotions)) do out[#out + 1] = k end
	return out
end
function Exp:GetVeteranName() return self.unit.vetName or "" end
function Exp:SetVeteranName(s) self.unit.vetName = s end
function Exp:CanPromote() return self.unit.xp >= self:GetExperienceForNextLevel() end

function Unit:GetID() return self.id end
function Unit:GetOwner() return self.owner end
function Unit:GetOriginalOwner() return self.originalOwner end
function Unit:GetX() return self.x end
function Unit:GetY() return self.y end
function Unit:GetType() return self.typeIndex end
function Unit:GetUnitType() return self.typeIndex end
function Unit:GetName() return GameInfo.Units[self.typeIndex].Name end
function Unit:GetDomain()
	local d = GameInfo.Units[self.typeIndex].Domain
	return DomainTypes[d] or DomainTypes.DOMAIN_LAND
end
function Unit:GetCombat() return GameInfo.Units[self.typeIndex].Combat or 0 end
function Unit:GetDamage() return self.damage end
function Unit:GetMaxDamage() return 100 end
function Unit:SetDamage(d)
	FAKE.damageWrites[#FAKE.damageWrites + 1] = { id = self.id, owner = self.owner, from = self.damage,
		to = math.max(0, math.min(100, d)), turn = FAKE.turn, ghost = self.ghost }
	self.damage = math.max(0, math.min(100, d))
	if self.damage >= 100 then
		FAKE.RemoveUnit(self, "DEATH")
	end
end
function Unit:ChangeDamage(d) self:SetDamage(self.damage + d) end
function Unit:GetExperience()
	if self.exp == nil then
		self.exp = setmetatable({ unit = self }, Exp)
	end
	return self.exp
end
function Unit:GetMovesRemaining() return self.moves end
function Unit:GetMaxMoves() return self.maxMoves end
function Unit:GetAttacksRemaining() return self.attacks end
function UnitUI.IsCannotAttack(self) return (self:GetCombat() or 0) == 0 end
function Unit:GetMilitaryFormation() return self.formation end
function Unit:SetMilitaryFormation(f) self.formation = f end
function Unit:IsEmbarked() return self.embarked == true end
function Unit:IsDead() return self.dead == true end
function Unit:IsDelayedDeath() return false end
function Unit:GetPlotId() return Map.GetPlot(self.x, self.y):GetIndex() end
function Unit:SetProperty(k, v) self.props = self.props or {}; self.props[k] = DeepCopy(v) end
function Unit:GetProperty(k) return self.props and DeepCopy(self.props[k]) or nil end

function FAKE.NewUnit(ownerID, typeName, x, y)
	local row = GameInfo.Units[typeName]
	if row == nil then
		error("FAKE.NewUnit: unknown unit type " .. tostring(typeName))
	end
	local id = FAKE.nextUnitID
	FAKE.nextUnitID = FAKE.nextUnitID + 1
	local u = setmetatable({
		id = id, owner = ownerID, originalOwner = ownerID,
		typeIndex = row.Index, typeName = row.UnitType,
		x = x, y = y, damage = 0, xp = 0, promotions = {}, vetName = "",
		moves = row.BaseMoves or 2, maxMoves = row.BaseMoves or 2,
		attacks = 1, formation = 0, embarked = false, createdTurn = FAKE.turn,
	}, Unit)
	FAKE.units[id] = u
	return u
end

function FAKE.RemoveUnit(u, how)
	if u == nil or FAKE.units[u.id] == nil then
		return false
	end
	FAKE.units[u.id] = nil
	u.dead = true
	FAKE.killLog[#FAKE.killLog + 1] = { id = u.id, owner = u.owner, how = how, turn = FAKE.turn }
	return true
end

-- Session F 1.3: a removed unit whose object the engine still returns.
-- expires = "frame" (killed in combat: until the next hook), "turnEnd"
-- (upgraded: until OnGameTurnEnded) or "turnStart" (levied away: until the
-- next OnGameTurnStarted).
function FAKE.MakeGhost(u, expires, how)
	if u == nil or FAKE.units[u.id] == nil then
		return false
	end
	FAKE.RemoveUnit(u, how)
	u.dead = nil
	u.ghost = expires
	FAKE.ghosts[u.id] = u
	return true
end

local GHOST_RANK = { frame = 1, turnEnd = 2, turnStart = 3, manual = 99 }   -- manual: tests drop it themselves (worst-case lifetime)
-- Drops the ghosts whose lifetime ends at `point` ("frame" < "turnEnd" <
-- "turnStart": a later point also ends the shorter lifetimes).
function FAKE.ExpireGhosts(point)
	local r = GHOST_RANK[point] or 3
	for id, g in pairs(FAKE.ghosts) do
		if (GHOST_RANK[g.ghost] or 1) <= r then
			FAKE.ghosts[id] = nil
			g.dead = true
		end
	end
end

local function UnitsOf(pid)
	local list = {}
	for _, u in pairs(FAKE.units) do
		if u.owner == pid then
			list[#list + 1] = u
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end
FAKE.UnitsOf = UnitsOf

-- PlayerUnits:Members(): the live units plus the owner's ghosts (Session F:
-- a levied unit's old object is still listed at -9999,-9999, T28).
local function MembersOf(pid)
	local list = UnitsOf(pid)
	for _, g in pairs(FAKE.ghosts) do
		if g.owner == pid then
			list[#list + 1] = g
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end
FAKE.MembersOf = MembersOf

-- Copies the unit state a re-created unit keeps (upgrade, levy).
local function CopyUnitState(from, to)
	to.damage, to.xp, to.vetName = from.damage, from.xp, from.vetName
	to.formation = from.formation
	to.originalOwner = from.originalOwner
	to.level = from.level
	for k, v in pairs(from.promotions) do to.promotions[k] = v end
end

-- Session F T30: an upgrade creates a NEW unit (new ID) of newType on the
-- same plot, keeping damage, XP, promotions, name and formation, with 0
-- moves; the old object stays findable (old type, same plot) until
-- OnGameTurnEnded. Returns the new unit.
function FAKE.UpgradeUnit(u, newType)
	local nu = FAKE.NewUnit(u.owner, newType, u.x, u.y)
	CopyUnitState(u, nu)
	nu.moves = 0
	FAKE.MakeGhost(u, "turnEnd", "UPGRADE")
	return nu
end

-- Session F T28: every unit of `from` whose original owner is `orig` is
-- re-created for `to` with a NEW ID (originalOwner kept, formation, damage,
-- XP and promotions kept), on the same tile or shifted (shift(u) -> x, y);
-- the old object goes to -9999,-9999 and stays in `from`'s list until the
-- next turn start. Returns the new units in old-ID order.
function FAKE.LevyTransfer(from, to, orig, shift)
	local out = {}
	for _, u in ipairs(UnitsOf(from)) do
		if u.originalOwner == orig then
			local x, y = u.x, u.y
			if shift ~= nil then
				x, y = shift(u)
			end
			local nu = FAKE.NewUnit(to, u.typeName, x, y)
			CopyUnitState(u, nu)
			nu.originalOwner = orig
			FAKE.MakeGhost(u, "turnStart", "LEVY")
			u.x, u.y = -9999, -9999
			out[#out + 1] = nu
		end
	end
	return out
end

-- Session F T20: a unit killed in combat; its object stays findable for the
-- rest of the frame with damage 100 on its plot.
function FAKE.CombatKill(u)
	if u == nil or FAKE.units[u.id] == nil then
		return false
	end
	u.damage = 100
	return FAKE.MakeGhost(u, "frame", "COMBAT")
end

Units = {}
function Units.GetUnitsInPlot(p)
	if type(p) == "number" then
		p = Map.GetPlotByIndex(p)
	end
	local out = {}
	if p == nil then return out end
	for _, u in pairs(FAKE.units) do
		if u.x == p.x and u.y == p.y then
			out[#out + 1] = u
		end
	end
	if FAKE.ghostsInPlot then
		for _, g in pairs(FAKE.ghosts) do
			if g.x == p.x and g.y == p.y then
				out[#out + 1] = g
			end
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end
function Units.GetUnitsInPlotLayerID(a, b, c)
	if type(a) == "table" then
		return Units.GetUnitsInPlot(a)
	end
	return Units.GetUnitsInPlot(Map.GetPlot(a, b))
end

-- Engine slot semantics (Session C, SESSION_C_REPORT 6): a unit ID is
-- slot (low 16 bits) + serial (upper bits), and FindID / GetUnit resolve only
-- the SLOT. Once the original unit is gone, a newer unit of the same owner in
-- the same slot is returned. FAKE.NewUnitInSlot builds such a unit.
local SLOT = 65536
function FAKE.FindUnitBySlot(pid, uid)
	local u = FAKE.units[uid]
	if u ~= nil and u.owner == pid then
		return u
	end
	-- Session F 1.3: a stale object with exactly this ID is still returned.
	local g = FAKE.ghosts[uid]
	if g ~= nil and g.owner == pid then
		return g
	end
	if type(uid) ~= "number" then
		return nil
	end
	local slot = uid % SLOT
	for _, v in pairs(FAKE.units) do
		if v.owner == pid and v.id % SLOT == slot then
			return v
		end
	end
	return nil
end

-- A new unit whose ID has the same slot as oldID and a new serial.
function FAKE.NewUnitInSlot(oldID, ownerID, typeName, x, y)
	local u = FAKE.NewUnit(ownerID, typeName, x, y)
	FAKE.units[u.id] = nil
	local serial = math.floor(math.max(FAKE.nextUnitID, oldID) / SLOT) + 1
	local id = serial * SLOT + (oldID % SLOT)
	while FAKE.units[id] ~= nil do
		id = id + SLOT
	end
	u.id = id
	FAKE.units[id] = u
	return u
end

-- Engine rule (Session D 3, Session E 6): a script Create on a free plot
-- returns nil when the plot owner's borders are closed to the new owner.
-- Open: owner -1 / self / teammate / at war / city-state / allied / open
-- borders granted by the owner. The Early Empire exception is not modelled.
-- Returns nil (allowed) or a reason string.
function FAKE.CreateRefusal(pid, x, y)
	if FAKE.createNil ~= nil and FAKE.createNil(pid, x, y) then
		return "TEST_HOOK"
	end
	if not FAKE.closedBorders then
		return nil
	end
	local plot = Map.GetPlot(x, y)
	local o = plot and plot:GetOwner() or -1
	if o < 0 or o == pid or Players[o] == nil or Players[pid] == nil then
		return nil
	end
	if Players[o].team == Players[pid].team then return nil end
	if FAKE.PairGet(FAKE.diplo.war, pid, o) then return nil end
	if Players[o].kind == "CITY_STATE" then return nil end
	if FAKE.PairGet(FAKE.diplo.allied, pid, o) then return nil end
	if FAKE.PairGet(FAKE.diplo.ob, pid, o) then return nil end
	return "CLOSED_BORDERS"
end

-- Script creation (Create / InitUnit): nil when refused; the unit is marked
-- so the end-of-round heal skips it in its creation round (Session E 3.5).
function FAKE.ScriptCreate(pid, typeName, x, y)
	local why = FAKE.CreateRefusal(pid, x, y)
	if why ~= nil then
		FAKE.createRefused[#FAKE.createRefused + 1] = { pid = pid, x = x, y = y, why = why }
		return nil
	end
	local u = FAKE.NewUnit(pid, typeName, x, y)
	u.scriptCreated = true
	u.level = 1   -- Session F T08: SetPromotion never raises a created unit's level
	return u
end

UnitManager = {}
function UnitManager.GetUnit(pid, uid)
	return FAKE.FindUnitBySlot(pid, uid)
end
function UnitManager.InitUnit(pid, typeName, x, y)
	if Players[pid] == nil then return nil end
	return FAKE.ScriptCreate(pid, typeName, x, y)
end
function UnitManager.Kill(u, bDelay)
	return FAKE.RemoveUnit(u, "KILL")
end
function UnitManager.PlaceUnit(u, x, y)   -- AustraliaScenario.lua:854 (gameplay)
	if u ~= nil then
		u.x, u.y = x, y
	end
end
function UnitManager.FinishMoves(u)
	if u ~= nil then
		u.moves = 0
	end
end
function UnitManager.CanFormMilitaryFormation() return false end

-- ---------------------------------------------------------------------------
-- Cities
-- ---------------------------------------------------------------------------
local City = {}
City.__index = City
function City:GetID() return self.id end
function City:GetOwner() return self.owner end
function City:GetOriginalOwner() return self.originalOwner end
function City:GetX() return self.x end
function City:GetY() return self.y end
function City:GetName() return self.name end
function City:GetPlot() return Map.GetPlot(self.x, self.y) end
function City:IsCapital() return self.capital == true end
function City:GetPopulation() return self.population or 1 end

function FAKE.NewCity(pid, x, y, opts)
	opts = opts or {}
	local id = FAKE.nextCityID
	FAKE.nextCityID = FAKE.nextCityID + 1
	local c = setmetatable({
		id = id, owner = pid, originalOwner = pid, x = x, y = y,
		name = opts.name or ("LOC_CITY_NAME_FAKE_" .. id), capital = opts.capital, plots = {},
	}, City)
	FAKE.cityList[#FAKE.cityList + 1] = c
	local radius = opts.radius or 2
	for _, p in ipairs(Map.GetNeighborPlots(x, y, radius)) do
		if p.owner == -1 or p.owner == nil or (p.x == x and p.y == y) then
			p.owner = pid
			c.plots[#c.plots + 1] = p.index
		end
	end
	return c
end

function FAKE.CitiesOf(pid)
	local list = {}
	for _, c in ipairs(FAKE.cityList) do
		if c.owner == pid and not c.destroyed then
			list[#list + 1] = c
		end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

CityManager = {}
function CityManager.GetCityAt(x, y)
	if type(x) == "number" and FAKE.map ~= nil and FAKE.map.wrapX then
		x = x % FAKE.map.w
	end
	for _, c in ipairs(FAKE.cityList) do
		if not c.destroyed and c.x == x and c.y == y then
			return c
		end
	end
	return nil
end
function CityManager.GetCity(pid, cid)
	for _, c in ipairs(FAKE.cityList) do
		if not c.destroyed and c.owner == pid and c.id == cid then
			return c
		end
	end
	return nil
end
-- Gift/capture: the city gets a NEW ID (as observed by Annex CS Remastered).
function CityManager.TransferCity(c, newOwner, how)
	if c == nil or Players[newOwner] == nil then
		return false
	end
	local old = c.owner
	c.destroyed = true
	local n = setmetatable({
		id = FAKE.nextCityID, owner = newOwner, originalOwner = c.originalOwner, x = c.x, y = c.y,
		name = c.name, capital = false, plots = c.plots,
	}, City)
	FAKE.nextCityID = FAKE.nextCityID + 1
	FAKE.cityList[#FAKE.cityList + 1] = n
	for _, idx in ipairs(c.plots) do
		local p = FAKE.map.plots[idx]
		if p.owner == old then
			p.owner = newOwner
		end
	end
	FAKE.transfers = FAKE.transfers or {}
	FAKE.transfers[#FAKE.transfers + 1] = { from = old, to = newOwner, how = how, x = c.x, y = c.y }
	return true
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------
FAKE.diplo = { war = {}, allied = {}, friend = {}, ob = {}, met = {} }

local function PairGet(t, a, b)
	return t[a] ~= nil and t[a][b] == true
end
local function PairSet(t, a, b, v)
	t[a] = t[a] or {}
	t[a][b] = v and true or nil
end
FAKE.PairGet, FAKE.PairSet = PairGet, PairSet

local function NewDiplomacy(pid)
	local d = {}
	function d:IsAtWarWith(b)
		if b == pid then return false end
		return PairGet(FAKE.diplo.war, pid, b)
	end
	function d:HasAllied(b) return PairGet(FAKE.diplo.allied, pid, b) end
	function d:HasDeclaredFriendship(b) return PairGet(FAKE.diplo.friend, pid, b) end
	-- UI only (Session A T09: nil in G); G reads open borders via deals.
	local ui = {}
	function ui.HasOpenBordersFrom(self, b) return PairGet(FAKE.diplo.ob, pid, b) end
	setmetatable(d, { __index = function(t, k)
		if FAKE.context == "UI" then
			return ui[k]
		end
		return nil
	end })
	function d:HasMet(b)
		if b == pid then return true end
		return PairGet(FAKE.diplo.met, pid, b)
	end
	function d:DeclareWarOn(b, warType, force)
		FAKE.SetWar(pid, b, true)
	end
	function d:SetHasAllied(b, v) PairSet(FAKE.diplo.allied, pid, b, v) end
	function d:SetHasDeclaredFriendship(b, v) PairSet(FAKE.diplo.friend, pid, b, v) end
	function d:SetHasMet(b) PairSet(FAKE.diplo.met, pid, b, true); PairSet(FAKE.diplo.met, b, pid, true) end
	return d
end

-- War is symmetric; it ends alliance, friendship and open borders both ways.
function FAKE.SetWar(a, b, v)
	PairSet(FAKE.diplo.war, a, b, v)
	PairSet(FAKE.diplo.war, b, a, v)
	PairSet(FAKE.diplo.met, a, b, true)
	PairSet(FAKE.diplo.met, b, a, true)
	if v then
		PairSet(FAKE.diplo.allied, a, b, false); PairSet(FAKE.diplo.allied, b, a, false)
		PairSet(FAKE.diplo.friend, a, b, false); PairSet(FAKE.diplo.friend, b, a, false)
		PairSet(FAKE.diplo.ob, a, b, false); PairSet(FAKE.diplo.ob, b, a, false)
	end
end

local Player = {}
local PlayerUI = {}  -- UI-only player methods (nil in G, Session A T09)
Player.__index = function(t, k)
	local v = Player[k]
	if v == nil and FAKE.context == "UI" then
		return PlayerUI[k]
	end
	return v
end
function Player:GetID() return self.id end
function Player:IsAlive() return self.alive == true end
function Player:IsHuman() return self.human == true end
function Player:IsMajor() return self.kind == "MAJOR" end
function Player:IsBarbarian() return self.kind == "BARBARIAN" end
function PlayerUI.IsFreeCities(self) return self.kind == "FREE_CITIES" end
function Player:GetTeam() return self.team end
function Player:GetDiplomacy() return self.diplomacy end
function Player:GetTreasury() return self.treasury end
function Player:GetResources() return self.resources end
function Player:GetUnits() return self.unitsColl end
function Player:GetCities() return self.citiesColl end
function Player:GetProperty(k) return DeepCopy(self.props[k]) end
function Player:SetProperty(k, v) self.props[k] = DeepCopy(v) end
-- City-state influence: p.suzerain (set by tests, default -1). GetLevyTurnCounter
-- is nil in G (Session A T09), so it exists only in the UI context here.
function Player:GetInfluence()
	local me = self
	local inf = { GetSuzerain = function() return me.suzerain or -1 end }
	if FAKE.context == "UI" then
		inf.GetLevyTurnCounter = function() return me.levyTurn or -1 end
	end
	return inf
end
function Player:GetDiplomaticAI()
	local me = self.id
	return {
		GetDiplomaticStateIndex = function(_, other)
			local name = "DIPLO_STATE_NEUTRAL"
			if PairGet(FAKE.diplo.war, me, other) then name = "DIPLO_STATE_WAR"
			elseif PairGet(FAKE.diplo.allied, me, other) then name = "DIPLO_STATE_ALLIED"
			elseif PairGet(FAKE.diplo.friend, me, other) then name = "DIPLO_STATE_DECLARED_FRIEND" end
			local row = GameInfo.DiplomaticStates and GameInfo.DiplomaticStates[name]
			return row and row.Index or -1
		end,
	}
end

Players = {}

function FAKE.NewPlayer(id, opts)
	opts = opts or {}
	local p = setmetatable({
		id = id, alive = opts.alive ~= false, human = opts.human == true,
		kind = opts.kind or "MAJOR", team = opts.team or id, props = {},
		civ = opts.civ or ("LOC_CIVILIZATION_FAKE_" .. id .. "_NAME"),
		civType = opts.civType, leaderType = opts.leaderType,
	}, Player)
	p.diplomacy = NewDiplomacy(id)
	local gold = opts.gold or 0
	p.treasury = {
		GetGoldBalance = function() return gold end,
		ChangeGoldBalance = function(_, n) gold = gold + n end,
		SetGoldBalance = function(_, n) gold = n end,
		GetGoldYield = function() return 0 end,
	}
	local res = {}
	p.resources = {
		GetResourceAmount = function(_, idx) return res[idx] or 0 end,
		ChangeResourceAmount = function(_, idx, d) res[idx] = (res[idx] or 0) + d end,
		GetResourceStockpileCap = function() return 50 end,
	}
	p.unitsColl = {
		FindID = function(_, uid)
			return FAKE.FindUnitBySlot(id, uid)   -- slot semantics (Session C)
		end,
		Members = function()
			return ipairs(MembersOf(id))   -- ghosts included (Session F T28)
		end,
		GetCount = function() return #UnitsOf(id) end,
		Create = function(_, typeIndex, x, y)
			local row = GameInfo.Units[typeIndex]
			if row == nil then return nil end
			return FAKE.ScriptCreate(id, row.UnitType, x, y)
		end,
		Destroy = function(_, u)
			if u == nil or u.owner ~= id then return false end
			return FAKE.RemoveUnit(u, "DESTROY")
		end,
	}
	p.citiesColl = {
		FindID = function(_, cid) return CityManager.GetCity(id, cid) end,
		Members = function() return ipairs(FAKE.CitiesOf(id)) end,
		GetCount = function() return #FAKE.CitiesOf(id) end,
		GetCapitalCity = function()
			local list = FAKE.CitiesOf(id)
			for _, c in ipairs(list) do
				if c.capital then return c end
			end
			return nil
		end,
		-- UI-only in game (RazeCity); tests set FAKE.capturedCity[pid].
		GetNextCapturedCity = function() return FAKE.capturedCity and FAKE.capturedCity[id] or nil end,
	}
	Players[id] = p
	FAKE.players[id] = p
	return p
end

PlayerManager = {}
-- Returned in DESCENDING order on purpose: EFV must sort (PLAN 1.6).
function PlayerManager.GetAliveIDs()
	local ids = {}
	for id, p in pairs(FAKE.players) do
		if p.alive then ids[#ids + 1] = id end
	end
	table.sort(ids, function(a, b) return a > b end)
	return ids
end
function PlayerManager.GetAliveMajors()
	local out = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		if FAKE.players[id].kind == "MAJOR" then out[#out + 1] = FAKE.players[id] end
	end
	return out
end
function PlayerManager.GetAliveMinors()
	local out = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		if FAKE.players[id].kind == "CITY_STATE" then out[#out + 1] = FAKE.players[id] end
	end
	return out
end
function PlayerManager.GetFreeCitiesPlayerID() return FAKE.freeCitiesID end
function PlayerManager.GetAliveMajorsCount() return #PlayerManager.GetAliveMajors() end
function PlayerManager.IsValid(id) return FAKE.players[id] ~= nil end

PlayerConfigurations = setmetatable({}, {
	__index = function(_, id)
		local p = FAKE.players[id]
		if p == nil then return nil end
		return {
			GetCivilizationShortDescription = function() return p.civ end,
			GetCivilizationTypeName = function() return p.civType or ("CIVILIZATION_FAKE_" .. id) end,
			GetLeaderTypeName = function() return p.leaderType or ("LEADER_FAKE_" .. id) end,
			GetPlayerName = function() return "Player " .. id end,
			IsHuman = function() return p.human end,
		}
	end,
})

-- ---------------------------------------------------------------------------
-- Notifications, text, deals
-- ---------------------------------------------------------------------------
NotificationManager = {}
function NotificationManager.SendNotification(pid, hash, data)
	local row = GameInfo.Types[hash]
	if row == nil then
		error("SendNotification: unknown notification type hash " .. tostring(hash))
	end
	local n = { pid = pid, typeName = row.Type, hash = hash, data = DeepCopy(data or {}), id = FAKE.nextNotifID, turn = FAKE.turn }
	FAKE.nextNotifID = FAKE.nextNotifID + 1
	FAKE.notifications[#FAKE.notifications + 1] = n
	return n.id
end
function NotificationManager.GetList(pid)
	local out = {}
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and not n.dismissed then out[#out + 1] = n.id end
	end
	return out
end
function NotificationManager.Find(pid, id)
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and n.id == id and not n.dismissed then
			return {
				GetType = function() return n.hash end,
				GetValue = function(_, k) return n.data[k] end,
				GetMessage = function() return n.data[ParameterTypes.MESSAGE] end,
				GetSummary = function() return n.data[ParameterTypes.SUMMARY] end,
				GetID = function() return n.id end,
			}
		end
	end
	return nil
end
function NotificationManager.Dismiss(pid, id)
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and n.id == id then n.dismissed = true end
	end
end

Locale = {}
-- Renders "{n_Name}" and the Civ VI plural form "{n_Name : plural 1?one; other?many;}"
-- (WP7.3: plural forms are rendered like the game, so "1 turn" / "2 turns").
-- Text audit (WP7.3): a mod key (LOC_EFV_*) whose placeholder {n_...} gets no
-- argument n is recorded in FAKE.handlerErrors, which fails the running test
-- (run_tests.py). Every Lookup made by any test is therefore an arg-count check,
-- including the notification texts built from argument arrays in EFV_Notify.
FAKE.textArgErrors = {}
local function PluralForm(spec, v)
	local num = tonumber(v)
	local forms, other = {}, nil
	for sel, word in string.gmatch(spec, "([%w]+)%?([^;]*);") do
		forms[sel] = word
		if sel == "other" then other = word end
	end
	if num ~= nil and forms[tostring(num)] ~= nil then return forms[tostring(num)] end
	return other or ""
end
function Locale.Lookup(key, ...)
	if key == nil then return "" end
	local text = (FAKE_TEXT ~= nil and FAKE_TEXT[key]) or nil
	local n = select("#", ...)
	if text == nil then
		if n == 0 then return tostring(key) end
		local parts = {}
		for i = 1, n do parts[i] = tostring((select(i, ...))) end
		return tostring(key) .. "(" .. table.concat(parts, ",") .. ")"
	end
	local args = { ... }
	text = string.gsub(text, "{(%d+)_([^}]*)}", function(num, rest)
		local v = args[tonumber(num)]
		if v == nil then
			if string.sub(tostring(key), 1, 8) == "LOC_EFV_" then
				local msg = "text-args: " .. tostring(key) .. " uses {" .. num .. "_...} but got " .. n .. " argument(s)"
				FAKE.textArgErrors[#FAKE.textArgErrors + 1] = msg
				FAKE.handlerErrors[#FAKE.handlerErrors + 1] = msg
			end
			return "{" .. num .. "}"
		end
		local spec = string.match(rest, "^[^:]*:%s*plural%s+(.*)$")
		if spec ~= nil then return PluralForm(spec, v) end
		return tostring(v)
	end)
	return text
end
function Locale.ToUpper(s) return string.upper(tostring(s)) end
function Locale.Compare(a, b) if a < b then return -1 elseif a > b then return 1 end return 0 end

-- Visibility (A59; G NEW-VERIFY): everything revealed unless a test hides it
-- with FAKE.unrevealed[pid][plotIndex] = true.
FAKE.unrevealed = {}
PlayersVisibility = setmetatable({}, {
	__index = function(_, pid)
		return {
			IsRevealed = function(_, x, y)
				local p = Map.GetPlot(x, y)
				if p == nil then return false end
				return not (FAKE.unrevealed[pid] ~= nil and FAKE.unrevealed[pid][p.index] == true)
			end,
			IsVisible = function(_, x, y) return true end,
		}
	end,
})

-- Enacted deals between a and b: one deal per open-borders direction
-- (FAKE.diplo.ob[receiver][grantor]), holding an AGREEMENTS / OPEN_BORDERS
-- item from the grantor to the receiver. nil when no deal exists (Session A).
local DealItem = {}
DealItem.__index = DealItem
function DealItem:GetType() return self.type end
function DealItem:GetSubType() return self.subType end
function DealItem:GetFromPlayerID() return self.from end
function DealItem:GetToPlayerID() return self.to end
function DealItem:GetDuration() return self.duration end
function DealItem:GetEnactedTurn() return self.enacted end
local Deal = {}
Deal.__index = Deal
function Deal:Items()
	local i = 0
	return function()
		i = i + 1
		return self.items[i]
	end
end
function Deal:FindItemByType(itemType, subType, fromPlayer)
	for _, it in ipairs(self.items) do
		if it.type == itemType and (subType == nil or it.subType == subType)
				and (fromPlayer == nil or it.from == fromPlayer) then
			return it
		end
	end
	return nil
end
-- Terms of the agreement "grantor gives receiver open borders":
-- FAKE.obTerms[receiver][grantor] = { enacted, duration }, set by
-- H.openBorders (default: enacted now, 30 turns like the game's deals).
FAKE.obTerms = {}
function FAKE.ObTerms(receiver, grantor)
	local t = FAKE.obTerms[receiver] and FAKE.obTerms[receiver][grantor]
	return t or { enacted = 0, duration = 30 }
end

-- Engine expiry of open borders at the turn start of player pid (Session D
-- 2.3): every agreement granted TO pid whose enacted + duration <= turn is
-- removed, then pid's units standing inside that grantor's borders are moved
-- to the nearest land plot outside them (ring by ring, lowest plot index
-- first, no units there, a plot pid may enter). Same unit object and ID.
function FAKE.ExpireOpenBorders(pid)
	local row = FAKE.diplo.ob[pid]
	if row == nil then return end
	local grantors = {}
	for g, v in pairs(row) do
		if v then grantors[#grantors + 1] = g end
	end
	table.sort(grantors)
	for _, g in ipairs(grantors) do
		local t = FAKE.ObTerms(pid, g)
		if t.enacted + t.duration <= FAKE.turn then
			PairSet(FAKE.diplo.ob, pid, g, false)
			FAKE.expiredOB = FAKE.expiredOB or {}
			FAKE.expiredOB[#FAKE.expiredOB + 1] = { receiver = pid, grantor = g, turn = FAKE.turn }
			print(string.format("[FAKE] open borders %d -> %d expired on turn %d", g, pid, FAKE.turn))
			for _, u in ipairs(FAKE.UnitsOf(pid)) do
				local here = Map.GetPlot(u.x, u.y)
				if here ~= nil and here:GetOwner() == g then
					local dest = nil
					for r = 1, 10 do
						local ring = {}
						for _, p in ipairs(Map.GetNeighborPlots(u.x, u.y, r)) do
							if Map.GetPlotDistance(u.x, u.y, p.x, p.y) == r then ring[#ring + 1] = p end
						end
						table.sort(ring, function(a, b) return a.index < b.index end)
						for _, p in ipairs(ring) do
							if p:GetOwner() ~= g and not p:IsWater() and not p:IsImpassable()
									and p:GetUnitCount() == 0 and FAKE.CreateRefusal(pid, p.x, p.y) == nil then
								dest = p
								break
							end
						end
						if dest ~= nil then break end
					end
					if dest ~= nil then
						print(string.format("[FAKE] expel unit %d of %d from %d,%d to %d,%d (owner %d)",
							u.id, pid, u.x, u.y, dest.x, dest.y, dest:GetOwner()))
						u.x, u.y = dest.x, dest.y
					end
				end
			end
		end
	end
end

DealManager = {
	GetPlayerDeals = function(a, b)
		local deals = {}
		for _, pair in ipairs({ { a, b }, { b, a } }) do
			local receiver, grantor = pair[1], pair[2]
			if PairGet(FAKE.diplo.ob, receiver, grantor) then
				local t = FAKE.ObTerms(receiver, grantor)
				local item = setmetatable({ type = DealItemTypes.AGREEMENTS, subType = DealAgreementTypes.OPEN_BORDERS,
					from = grantor, to = receiver, enacted = t.enacted, duration = t.duration }, DealItem)
				deals[#deals + 1] = setmetatable({ items = { item } }, Deal)
			end
		end
		if #deals == 0 then
			return nil
		end
		return deals
	end,
}

-- ---------------------------------------------------------------------------
-- include(name): runs EFV/Scripts, EFV/UI, EFV_Dev/... or tests/offline/lib
-- files (search order set by the runner). Like the engine, include re-runs
-- the file every time; EFV's load-once guards make that safe.
-- ---------------------------------------------------------------------------
FAKE.includes = {}
function include(name)
	local rel = __py_find(name)
	if rel == nil then
		print("[FAKE] include: file not found: " .. tostring(name))
		return
	end
	FAKE.includes[#FAKE.includes + 1] = rel
	local src = __py_read(rel)
	local fn, err = loadstring(src, "@" .. rel)
	if fn == nil then
		error("include(" .. tostring(name) .. ") syntax error: " .. tostring(err), 2)
	end
	fn()
end

function FAKE.dofile(rel)
	local src = __py_read(rel)
	if src == nil then
		error("FAKE.dofile: not found " .. tostring(rel), 2)
	end
	local fn, err = loadstring(src, "@" .. rel)
	if fn == nil then
		error("FAKE.dofile(" .. rel .. ") syntax error: " .. tostring(err), 2)
	end
	return fn()
end
