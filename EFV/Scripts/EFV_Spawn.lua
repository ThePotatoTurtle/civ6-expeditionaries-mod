-- ===========================================================================
-- EFV_Spawn.lua
-- Module:   EFV_Spawn (global table)
-- Context:  gameplay only, include("EFV_Spawn").
-- Owner:    WP1.3.
--
-- Responsibility (PLAN 2.6; spec 8): pick one spawn plot with the synced RNG
-- (Game.GetRandNum) from the deterministic candidate list, and map a unit
-- type to its spawn domain. Pick may only be called from GameEvents handlers
-- (pipeline, requests), never from Events.* handlers (PLAN 1.6).
--
-- Candidate source (WP1.7 integration): the ONLY spawn search is
-- EFV_SpawnCandidates / EFV_SpawnValid in EFV_Rules (shared with the UI naval
-- dry run, INTERFACES 3.3). EFV_Spawn.Valid, Candidates, DryRun and Search
-- are thin delegations kept for callers and tests; WP1.3's second
-- implementation and its divergence log were removed. Every unit creation
-- goes through Pick (arrivals, returns) because Create does not check
-- stacking (Session B T05).
-- ===========================================================================

if EFV_Spawn ~= nil and EFV_Spawn.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")

EFV_Spawn = {}

local function ErrText(e)
	local s = string.gsub(tostring(e), "[\r\n]+", " ")
	return s
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.Valid(plot, domain, newOwnerID, opts) -> ok, why
-- Delegates to EFV_SpawnValid (EFV_Rules). why = "DOMAIN" | "WONDER" |
-- "UNITS" | "CITY" | "WAR_OWNER" | "ACCESS" | "DEAD_END" | "LAKE" | "ERROR".
-- PLAN 2.3, 2.6; spec 8.
-- ---------------------------------------------------------------------------
function EFV_Spawn.Valid(plot, domain, newOwnerID, opts)
	return EFV_SpawnValid(plot, domain, newOwnerID, opts)
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.Candidates(cx, cy, domain, newOwnerID, opts) -> ring, plots
-- Delegates to EFV_SpawnCandidates (EFV_Rules): first ring 1..5 with a valid
-- plot, plots sorted by GetIndex(); nil when none.
-- PLAN 2.3, 2.6; spec 8.
-- ---------------------------------------------------------------------------
function EFV_Spawn.Candidates(cx, cy, domain, newOwnerID, opts)
	return EFV_SpawnCandidates(cx, cy, domain, newOwnerID, opts)
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.Search(cx, cy, domain, newOwnerID, opts, label) -> ring, plots
-- EFV_SpawnCandidates in a pcall (an engine error is logged with the label
-- and treated as "no candidate"); the list is re-sorted by GetIndex() so
-- the RNG index always addresses an index-ordered list.
-- PLAN 2.3, 2.6.
-- ---------------------------------------------------------------------------
function EFV_Spawn.Search(cx, cy, domain, newOwnerID, opts, label)
	local ok, ring, plots = pcall(EFV_SpawnCandidates, cx, cy, domain, newOwnerID, opts)
	if not ok then
		EFV_Log(1, "Arrival", "EFV_SpawnCandidates failed label=%s err=%s", tostring(label), ErrText(ring))
		return nil
	end
	if ring == nil or plots == nil or #plots == 0 then
		return nil
	end
	table.sort(plots, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return ring, plots
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.DryRun(cx, cy, domain, newOwnerID, opts) -> ok, ring, count
-- Same search as Pick without the RNG (send validation, spec 6.2.7).
-- Returns: true, ring, #plots when a candidate exists; false otherwise.
-- ---------------------------------------------------------------------------
function EFV_Spawn.DryRun(cx, cy, domain, newOwnerID, opts)
	local ring, plots = EFV_Spawn.Search(cx, cy, domain, newOwnerID, opts, nil)
	if ring == nil then
		return false
	end
	return true, ring, #plots
end

-- The RNG pick shared by Pick and PickOrdered: ring, plots, k (0-based) or nil.
local function PickCore(cx, cy, domain, newOwnerID, lbl, opts)
	local ring, plots = EFV_Spawn.Search(cx, cy, domain, newOwnerID, opts, lbl)
	if ring == nil or plots == nil or #plots == 0 then
		EFV_Log(2, "Arrival", "spawn none label=%s x=%s y=%s domain=%s owner=%s",
			lbl, tostring(cx), tostring(cy), tostring(domain), tostring(newOwnerID))
		return nil
	end
	local n = #plots
	local k = 0
	if n > 1 then
		local r = Game.GetRandNum(n, "EFV spawn " .. lbl)
		if type(r) == "number" then
			k = math.floor(r)
		end
		if k < 0 or k >= n then
			EFV_Log(1, "Arrival", "GetRandNum out of range r=%s n=%d label=%s", tostring(r), n, lbl)
			k = 0
		end
	end
	local plot = plots[k + 1]
	EFV_Log(2, "Arrival", "spawn label=%s ring=%d candidates=%d pick=%d plot=%s x=%s y=%s",
		lbl, ring, n, k + 1, tostring(plot:GetIndex()), tostring(plot:GetX()), tostring(plot:GetY()))
	return ring, plots, k
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.Pick(cx, cy, domain, newOwnerID, label, opts) -> plot
-- ring, plots = EFV_Spawn.Search(...); returns plots[Game.GetRandNum(#plots,
-- "EFV spawn " .. label) + 1]. The RNG is not called for a single candidate
-- (same on every client). Gameplay only.
-- Params:  cx, cy centre coordinates; domain "LAND" | "SEA"; newOwnerID
--          player ID; label string (RNG log label, e.g. "arr" .. rec.id);
--          opts optional "Spawn opts" (trailing, backward compatible; e.g.
--          ignoreWarOwner, unused since 1.0.4).
-- Returns: plot object or nil when no candidate exists.
-- PLAN 2.6; spec 8; SPIKES 3 row 10. APIs: A07.
-- ---------------------------------------------------------------------------
function EFV_Spawn.Pick(cx, cy, domain, newOwnerID, label, opts)
	if not EFV_IsGameplay() then
		EFV_Log(1, "Arrival", "Pick called outside gameplay label=%s", tostring(label))
		return nil
	end
	local ring, plots, k = PickCore(cx, cy, domain, newOwnerID, tostring(label or "?"), opts)
	if ring == nil then
		return nil
	end
	return plots[k + 1]
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.PickOrdered(cx, cy, domain, newOwnerID, label, opts, maxN)
--   -> plots   (added Session D item 3)
-- The plots to try, in order, when Create may return nil (the engine refuses
-- a plot the new owner may not enter, Session D 3): [1] = exactly Pick's
-- choice (same single RNG call), then the other candidates of the same ring
-- in index order starting after the pick (wrapping), then the valid plots of
-- the next rings up to SPAWN_SEARCH_MAX_RING (EFV_SpawnRing, index order).
-- No extra RNG calls (deterministic on every client). At most maxN plots
-- (default EFV_Config.SPAWN_CREATE_TRIES). Gameplay only.
-- Returns: dense array of plot objects ({} when no candidate exists).
-- ---------------------------------------------------------------------------
function EFV_Spawn.PickOrdered(cx, cy, domain, newOwnerID, label, opts, maxN)
	local out = {}
	if not EFV_IsGameplay() then
		EFV_Log(1, "Arrival", "PickOrdered called outside gameplay label=%s", tostring(label))
		return out
	end
	local limit = tonumber(maxN) or EFV_Config.SPAWN_CREATE_TRIES or 1
	if limit < 1 then
		limit = 1
	end
	local ring, plots, k = PickCore(cx, cy, domain, newOwnerID, tostring(label or "?"), opts)
	if ring == nil then
		return out
	end
	local n = #plots
	for i = 0, n - 1 do
		if #out >= limit then
			return out
		end
		out[#out + 1] = plots[((k + i) % n) + 1]
	end
	for r = ring + 1, EFV_Config.SPAWN_SEARCH_MAX_RING do
		local okR, more = pcall(EFV_SpawnRing, cx, cy, r, domain, newOwnerID, opts)
		if okR and type(more) == "table" then
			for _, plot in ipairs(more) do
				if #out >= limit then
					return out
				end
				out[#out + 1] = plot
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- EFV_Spawn.DomainOf(unitType) -> domain
-- "SEA" if GameInfo.Units[unitType].Domain == "DOMAIN_SEA", else "LAND".
-- Params:  unitType string.
-- Returns: "LAND" | "SEA", or nil for an unknown type.
-- PLAN 2.6. APIs: A51.
-- ---------------------------------------------------------------------------
function EFV_Spawn.DomainOf(unitType)
	if type(unitType) ~= "string" then
		return nil
	end
	local row = GameInfo.Units[unitType]
	if row == nil then
		return nil
	end
	if row.Domain == "DOMAIN_SEA" then
		return "SEA"
	end
	return "LAND"
end

EFV_Spawn.LOADED = 1
