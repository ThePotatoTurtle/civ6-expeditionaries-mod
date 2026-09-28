-- ===========================================================================
-- EFV_Rules.lua
-- Module:   EFV_Rules (load marker table + reason-code list) + global EFV_*
--           rule functions
-- Context:  shared (gameplay + UI), include("EFV_Rules").
-- Owner:    WP1.1 (EXP, partner/volunteer basis, lapse reason, recall, spawn
--           search), WP3.1 (VOL release), WP4.1 (CS release).
--
-- Responsibility (PLAN 2.3): the single source of truth for eligibility in
-- both contexts. Returns reason codes (PLAN Appendix B, list below); the UI
-- turns them into text (LOC_EFV_REASON_<CODE>), gameplay logs them and puts
-- the first one into EFV_NOTIF_REQUEST_FAILED. Also the spawn candidate
-- search (spec 8) used by EFV_Spawn (G) and the naval dry run (UI + G).
--
-- Context adapters: calls that differ by context branch on EFV_IsGameplay().
-- G-only and UI-only calls sit inside G-ONLY / UI-ONLY region markers
-- (PLAN 2.3, 6.3; checked by tools/api_audit.py). Adapters in this file:
--   PartnerState      G: HasAllied / HasDeclaredFriendship (A37, A38)
--                     UI: GetDiplomaticAI():GetDiplomaticStateIndex (U20)
--   EFV_HasOpenBordersFrom  UI: HasOpenBordersFrom (A39)
--                     G: deal scan (A40; HasOpenBordersFrom is nil in G,
--                        Session A T09; the scan is confirmed in game by
--                        Session D, the one-way direction is Session F) with
--                        the predicted expiry turn (Phase 3)
--   HasUnitsOnPlot    G: plot:GetUnitCount (A13) / UI: Units.GetUnitsInPlot
--                     (A15); both + GetUnitsInPlotLayerID(x, y, ANY) (A16)
--   TinyLake          G only: IsLake + GetArea():GetPlotCount (A14)
--   HasAttackedCtx    both: GetAttacksRemaining (G confirmed, Session A T09);
--                     UI only: IsCannotAttack (nil in G)
-- Calls available in both contexts but unverified in G (IsRevealed,
-- GetUnitsInPlotLayerID) go through pcall with a logged, documented fallback.
--
-- Force-type release: EvaluateSend prepends NOT_IMPLEMENTED for force types
-- whose phase is not released yet (EFV_Config.FLAG_RELEASED; PLAN 5.1
-- WP1.1). WP4.1 released CS (Phase 4); Phase 3 released VOLUNTEER, so every
-- force type is released now (the gate stays as a kill switch).
--
-- City-State Expeditionary (spec 6.1, 9.3; WP4.1): recipient = any alive
-- city-state the sender HasMet (CS_NOT_MET otherwise; majors, Free Cities
-- and barbarians are never CS recipients); war requirement = EFV_HasCommonWar
-- (the sender and the city-state both at war with some third player,
-- barbarians excluded; Free Cities count); not at war with the city-state
-- (AT_WAR_WITH_RECIPIENT); fee FEE_CS_EXPEDITIONARY (= the Expeditionary
-- column); duration CS_EXPEDITIONARY_DURATION (10); naval dry run as the
-- city-state (future owner); valid return territory = the city-state's or
-- the sender's tiles (EFV_ValidReturnTerritory, recipientID = the city-state).
--
-- Designer answers (DECISIONS.md, "Designer answers to PLAN.md 7.3 and 7.4")
-- applied here: Volunteer recall no longer requires full HP (RECALL_DAMAGED
-- retired); Volunteer lapse conditions are shared via EFV_VolunteerLapseReason.
-- ===========================================================================

if EFV_Rules ~= nil and EFV_Rules.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")

EFV_Rules = {}

-- Every reason code the rules may emit (PLAN Appendix B, updated). Each has a
-- text key "LOC_EFV_REASON_" .. code (PLAN 3.7, 4.2).
-- RECALL_DAMAGED is retired (designer answer: recall needs no full HP).
-- NOT_IMPLEMENTED is interim (PLAN 5.1 WP1.1: unreleased VOL/CS branches).
EFV_Rules.ALL_REASON_CODES = {
	-- unit level
	"NOT_HUMAN_MAJOR", "NOT_OWNER", "CLASS_NEVER", "FORMATION", "DAMAGED",
	"NOT_OWN_TERRITORY", "EMBARKED", "NO_MOVES", "ATTACKED", "ALREADY_TRACKED",
	-- destination level
	"NOT_PARTNER", "VOL_NEEDS_ACCESS", "CS_NOT_MET", "AT_WAR_WITH_RECIPIENT",
	"NO_COMMON_WAR", "CITY_NOT_OWNED", "NOT_REVEALED", "GOLD", "NAVAL_NO_SPAWN",
	"FEE_CHANGED", "REQ_STALE",
	-- recall
	"RECALL_MIN_TURNS", "RECALL_TERRITORY", "RECALL_NOT_VOLUNTEER",
	-- entrust
	"ENTRUST_NO_PARTNER", "ENTRUST_STALE", "ENTRUST_RECIPIENT_INVALID",
	"ENTRUST_FAILED",
	-- interim
	"NOT_IMPLEMENTED",
}

-- Text-argument contract of the reason texts (EFV_Text.xml), shared by the
-- UI (EFV_UIShared) and the gameplay REQUEST_FAILED text (EFV_Transit):
--   NAME_REASON_CODES  LOC_EFV_REASON_<CODE> takes {1_Name} = recipient civ
--                      name (UI: one name or a comma list);
--   GOLD, FEE_CHANGED  {1_Num} = fee; RECALL_MIN_TURNS {1_Num} = turns left;
--   ENTRUST_NO_PARTNER {1_Name} = the captured city's former owner (civ name);
--   all other codes    no arguments.
EFV_Rules.NAME_REASON_CODES = { "NOT_PARTNER", "VOL_NEEDS_ACCESS", "CS_NOT_MET", "AT_WAR_WITH_RECIPIENT", "NO_COMMON_WAR" }

-- ---------------------------------------------------------------------------
-- File-local state and helpers
-- ---------------------------------------------------------------------------

-- Released force types (see header): EFV_Config.FLAG_RELEASED[forceType].
local function IsReleased(forceType)
	local rel = EFV_Config.FLAG_RELEASED
	return rel ~= nil and rel[forceType] == true
end

local DOMAIN_LAND = "LAND"
local DOMAIN_SEA  = "SEA"

local m_LoggedOnce = {}

local function LogOnce(key, level, fmt, ...)
	if m_LoggedOnce[key] then
		return
	end
	m_LoggedOnce[key] = true
	EFV_Log(level, "Config", fmt, ...)
end

local function Add(list, code)
	list[#list + 1] = code
end

local function IsKnownForce(forceType)
	return forceType == EFV_Config.FT_EXP or forceType == EFV_Config.FT_VOL or forceType == EFV_Config.FT_CS
end

local function Diplo(pid)
	if pid == nil then
		return nil
	end
	local pPlayer = Players[pid]
	if pPlayer == nil then
		return nil
	end
	local ok, d = pcall(function() return pPlayer:GetDiplomacy() end)
	if ok then
		return d
	end
	return nil
end

local function IsAlive(pid)
	if pid == nil or Players[pid] == nil then
		return false
	end
	local ok, v = pcall(function() return Players[pid]:IsAlive() end)
	return ok and v == true
end

-- Players[a]:GetDiplomacy():IsAtWarWith(b) (A36; majors, minors, Free Cities).
local function AtWar(a, b)
	local d = Diplo(a)
	if d == nil or b == nil then
		return false
	end
	local ok, v = pcall(function() return d:IsAtWarWith(b) end)
	return ok and v == true
end

local function HasMet(s, r)
	local d = Diplo(s)
	if d == nil then
		return false
	end
	local ok, v = pcall(function() return d:HasMet(r) end)
	return ok and v == true
end

local function SameTeam(s, r)
	local ok, v = pcall(function() return Players[s]:GetTeam() == Players[r]:GetTeam() end)
	return ok and v == true
end

local function GoldOf(pid)
	local ok, g = pcall(function() return Players[pid]:GetTreasury():GetGoldBalance() end)
	if ok and type(g) == "number" then
		return math.floor(g)
	end
	return 0
end

-- GameInfo.Units row of a unit object (A31, A51).
local function UnitRowOf(pUnit)
	if pUnit == nil then
		return nil
	end
	local ok, row = pcall(function() return GameInfo.Units[pUnit:GetType()] end)
	if ok then
		return row
	end
	return nil
end

-- Cities of a player sorted by GetID() (PLAN 1.6).
local function SortedCities(pid)
	local list = {}
	local pPlayer = Players[pid]
	if pPlayer == nil then
		return list
	end
	local pCities = pPlayer:GetCities()
	if pCities == nil then
		return list
	end
	for _, pCity in pCities:Members() do
		if pCity ~= nil then
			list[#list + 1] = pCity
		end
	end
	table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
	return list
end

-- Revealed test (spec 6.3.1, A59). UI CONFIRMED; G NEW-VERIFY [T09+]: pcall,
-- and if the call is unavailable the check is skipped with a log line
-- (PLAN 2.3: "skipped with a log line until T09+ confirms").
local function IsRevealedTo(pid, x, y)
	local ok, v = pcall(function() return PlayersVisibility[pid]:IsRevealed(x, y) end)
	if ok and v ~= nil then
		return v == true
	end
	LogOnce("revealed", 2, "PlayersVisibility:IsRevealed unavailable in %s (%s); NOT_REVEALED check skipped (T09+)",
		EFV_IsGameplay() and "G" or "UI", tostring(v))
	return true
end

-- Alliance / declared-friendship adapter. Returns allied, friend (booleans).
local function PartnerState(s, r)
	local allied, friend = false, false
	if EFV_IsGameplay() then
		local d = Diplo(s)
		if d ~= nil then
			-- EFV:G-ONLY begin
			local okA, a = pcall(function() return d:HasAllied(r) end)
			allied = (okA and a == true)
			-- HasDeclaredFriendship in G is LIKELY [T09]: probe; without it
			-- declared friends are not eligible in G (logged once).
			if EFV_Has(d, "HasDeclaredFriendship") then
				local okF, f = pcall(function() return d:HasDeclaredFriendship(r) end)
				friend = (okF and f == true)
			else
				LogOnce("friendG", 1, "HasDeclaredFriendship unavailable in G (T09); declared friends are not eligible partners")
			end
			-- EFV:G-ONLY end
		end
	else
		-- EFV:UI-ONLY begin
		local okS, stateType = pcall(function()
			local idx = Players[r]:GetDiplomaticAI():GetDiplomaticStateIndex(s)
			local row = GameInfo.DiplomaticStates[idx]
			if row == nil then
				return nil
			end
			return row.StateType
		end)
		if okS then
			allied = (stateType == "DIPLO_STATE_ALLIED")
			friend = (stateType == "DIPLO_STATE_DECLARED_FRIEND")
		end
		-- EFV:UI-ONLY end
	end
	return allied, friend
end

-- Predicted expiry of an open-borders deal item (Session D 2.2, INTEGRATION
-- NOTES D item 1): the agreement ends on turn GetEnactedTurn() +
-- GetDuration(). On that turn the deal is still listed at OnGameTurnStarted
-- and the engine expels the units later in the same turn (at the unit
-- owner's turn start), so an item counts as ended once enacted + duration
-- <= the current turn. Any failure or a missing / non-positive value ->
-- "still active" (the engine then decides; the scan stays as before).
-- Returns true when the item has ended.
local function DealItemEnded(item)
	local ok, enacted, duration = pcall(function()
		local e, d = nil, nil
		-- EFV:G-ONLY begin
		e, d = item:GetEnactedTurn(), item:GetDuration()
		-- EFV:G-ONLY end
		return e, d
	end)
	if not ok or type(enacted) ~= "number" or type(duration) ~= "number" or enacted < 0 or duration <= 0 then
		return false
	end
	return enacted + duration <= Game.GetCurrentGameTurn()
end

-- G-only open-borders reader (A40): an enacted deal between s and r
-- containing an OPEN_BORDERS agreement given by r that has not reached its
-- predicted expiry turn (DealItemEnded). FindItemByType third argument =
-- from-player (DiplomacyDealView.lua:1395). CONFIRMED-INGAME for presence,
-- absence and the expiry turn (Session D 2.2); the one-way direction is
-- still Session F T27 (kept behind FLAG_VOLUNTEER_FRIENDS_OB).
local function OpenBordersFromDeals(s, r)
	local found = false
	local ok, err = pcall(function()
		-- EFV:G-ONLY begin
		local deals = DealManager.GetPlayerDeals(s, r)
		if deals == nil then
			return
		end
		for _, pDeal in ipairs(deals) do
			local item = pDeal:FindItemByType(DealItemTypes.AGREEMENTS, DealAgreementTypes.OPEN_BORDERS, r)
			if item ~= nil and item:GetFromPlayerID() == r then
				if DealItemEnded(item) then
					LogOnce("obEnded" .. tostring(s) .. ":" .. tostring(r) .. ":" .. tostring(Game.GetCurrentGameTurn()), 2,
						"open borders %s -> %s: agreement at its predicted expiry (enacted + duration <= turn %s); treated as ended",
						tostring(r), tostring(s), tostring(Game.GetCurrentGameTurn()))
				else
					found = true
					return
				end
			end
		end
		-- EFV:G-ONLY end
	end)
	if not ok then
		LogOnce("obDeals", 1, "open-borders deal scan failed (%s); friends without alliance are not Volunteer partners",
			tostring(err))
		return false
	end
	return found
end

-- Unit of a record-bearing store is tracked (DV8). store = G or UI store.
local function IsTracked(store, ownerID, unitID)
	if store == nil or store.ids == nil or store.recs == nil then
		return false
	end
	for _, id in ipairs(store.ids) do
		local rec = store.recs["r" .. tostring(id)]
		if rec ~= nil and rec.onMapPlayerID == ownerID and rec.onMapUnitID == unitID then
			return true
		end
	end
	return false
end

-- Embarked (spec 6.2.5). IsEmbarked is UI CONFIRMED, G LIKELY [T09]. Fallback
-- (PLAN 2.3): land-domain unit standing on water.
local function IsEmbarkedCtx(pUnit, plot, row)
	if EFV_Has(pUnit, "IsEmbarked") then
		local ok, v = pcall(function() return pUnit:IsEmbarked() end)
		if ok then
			return v == true
		end
	end
	LogOnce("embarked", 2, "unit:IsEmbarked unavailable in %s; using land-unit-on-water fallback (T09)",
		EFV_IsGameplay() and "G" or "UI")
	if row == nil or plot == nil then
		return false
	end
	local okW, water = pcall(function() return plot:IsWater() end)
	return row.Domain == "DOMAIN_LAND" and okW and water == true
end

-- Attacked this turn (spec 6.2.6, SPIKES 3 row 6): GetAttacksRemaining() <= 0
-- (G CONFIRMED, Session A T09). The UI additionally excludes units that can
-- never attack (IsCannotAttack, UI only: nil in G); EFV only sends combat
-- units, so both contexts agree in practice.
local function HasAttackedCtx(pUnit)
	if not EFV_Has(pUnit, "GetAttacksRemaining") then
		LogOnce("attacks", 2, "unit:GetAttacksRemaining unavailable in %s; ATTACKED check skipped",
			EFV_IsGameplay() and "G" or "UI")
		return false
	end
	local cannotAttack = false
	if not EFV_IsGameplay() then
		-- EFV:UI-ONLY begin
		local okC, c = pcall(function() return pUnit:IsCannotAttack() end)
		cannotAttack = (okC and c == true)
		-- EFV:UI-ONLY end
	end
	if cannotAttack then
		return false
	end
	local ok, res = pcall(function() return pUnit:GetAttacksRemaining() <= 0 end)
	return ok and res == true
end

-- Levy / foreign-origin test (D4, spec 1.2 "levied units"): owner differs
-- from the original owner. GetOriginalOwner is UI CONFIRMED, G LIKELY [T09].
-- The same rule runs in both contexts so UI and G agree; it covers the
-- Firaxis levy rule (UnitFlagManager.lua:734-758 requires owner ~= original
-- owner) and additionally excludes units gifted by mods.
local function IsForeignOrigin(pUnit)
	if not EFV_Has(pUnit, "GetOriginalOwner") then
		LogOnce("origOwner", 1, "unit:GetOriginalOwner unavailable in %s; levied units cannot be detected (T09)",
			EFV_IsGameplay() and "G" or "UI")
		return false
	end
	local ok, orig, owner = pcall(function() return pUnit:GetOriginalOwner(), pUnit:GetOwner() end)
	if not ok or type(orig) ~= "number" or orig < 0 then
		return false
	end
	return orig ~= owner
end

-- Domain test used by the spawn search and its exit count (spec 8).
local function DomainOK(plot, domain)
	if plot == nil then
		return false
	end
	local ok, res = pcall(function()
		if plot:IsImpassable() then
			return false
		end
		if domain == DOMAIN_SEA then
			return plot:IsWater()
		elseif domain == DOMAIN_LAND then
			return not plot:IsWater()
		end
		return false
	end)
	return ok and res == true
end

-- Any unit of any player on the plot (spec 8).
local function HasUnitsOnPlot(plot, x, y)
	if EFV_IsGameplay() then
		-- EFV:G-ONLY begin
		local ok, n = pcall(function() return plot:GetUnitCount() or 0 end)
		if ok and type(n) == "number" and n > 0 then
			return true
		end
		-- EFV:G-ONLY end
	else
		-- EFV:UI-ONLY begin
		local ok, list = pcall(function() return Units.GetUnitsInPlot(plot) end)
		if ok and type(list) == "table" and #list > 0 then
			return true
		end
		-- EFV:UI-ONLY end
	end
	-- All layers (traders, spies, religious; A16): UI CONFIRMED, G NEW-VERIFY
	-- [T09+]. Skipped with a log line when unavailable.
	local okL, all = pcall(function() return Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY) end)
	if okL then
		return type(all) == "table" and #all > 0
	end
	LogOnce("layerID", 2, "Units.GetUnitsInPlotLayerID unavailable in %s (%s); spawn ignores other unit layers (T09+)",
		EFV_IsGameplay() and "G" or "UI", tostring(all))
	return false
end

-- 1-tile lake (spec 8, SPIKES 3 row 12). G only (A14; UI unverified and
-- skipped). The exit rule (>= SPAWN_MIN_EXITS water neighbours) already
-- rejects 1-tile lakes, so UI and G agree in practice.
local function IsTinyLake(plot)
	local tiny = false
	if EFV_IsGameplay() then
		-- EFV:G-ONLY begin
		local ok, v = pcall(function() return plot:IsLake() and plot:GetArea():GetPlotCount() <= 1 end)
		tiny = (ok and v == true)
		-- EFV:G-ONLY end
	end
	return tiny
end

-- ---------------------------------------------------------------------------
-- EFV_PartnerBasis(s, r) -> basis
-- Eligible-partner test for Expeditionary and Entrust (spec 2): both players
-- alive majors, s ~= r; same team -> "TEAM"; at war -> nil (war wins over an
-- alliance flag: SetHasAllied does not end a war, a pair can be allied and at
-- war at once, Session E 6); alliance -> "ALLIANCE"; declared friendship ->
-- "FRIEND". Adapter PartnerState: G uses
-- GetDiplomacy():HasAllied(r) / HasDeclaredFriendship(r) (A37, A38 probe);
-- UI uses Players[r]:GetDiplomaticAI():GetDiplomaticStateIndex(s) ->
-- GameInfo.DiplomaticStates[i].StateType DIPLO_STATE_ALLIED /
-- DIPLO_STATE_DECLARED_FRIEND (U20).
-- Params:  s sender player ID, r recipient player ID.
-- Returns: "TEAM" | "ALLIANCE" | "FRIEND" | nil.
-- PLAN 2.3. APIs: A42, A37, A38 (G); U20 (UI).
-- ---------------------------------------------------------------------------
function EFV_PartnerBasis(s, r)
	if s == nil or r == nil or s == r then
		return nil
	end
	if not IsAlive(s) or not IsAlive(r) then
		return nil
	end
	if EFV_PlayerKind(s) ~= "MAJOR" or EFV_PlayerKind(r) ~= "MAJOR" then
		return nil
	end
	if SameTeam(s, r) then
		return "TEAM"
	end
	if AtWar(s, r) then
		-- Session E: war is checked before the alliance flag.
		return nil
	end
	local allied, friend = PartnerState(s, r)
	if allied then
		return "ALLIANCE"
	end
	if friend then
		return "FRIEND"
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_HasOpenBordersFrom(s, r) -> bool
-- "recipient r grants sender s open borders" =
-- Players[s]:GetDiplomacy():HasOpenBordersFrom(r) (DiplomacyActionView.lua:
-- 1428-1430). Mode per EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB:
--   "OFF"         always false (allies and teammates only), both contexts.
--   UI (not OFF)  HasOpenBordersFrom (A39, UI CONFIRMED).
--   G  (not OFF)  deal scan (A40): an enacted deal between s and r with an
--                 OPEN_BORDERS agreement given by r whose predicted expiry
--                 turn (GetEnactedTurn() + GetDuration()) has not been
--                 reached. HasOpenBordersFrom is nil in G (Session A T09), so
--                 there is no direct G mode. The scan matched the diplomacy
--                 screen and the engine in Session D (the one-way direction
--                 is Session F T27); a failing scan -> false. The old default
--                 "HAS_OB_FROM" behaves like "DEALS".
--                 The expiry prediction makes a Volunteer lapse start at
--                 OnGameTurnStarted of the expiry turn, before the engine
--                 expels the units later in that turn (Session D 2.3).
-- Validation never trusts a UI-computed flag (D2).
-- Params:  s sender player ID, r recipient player ID.
-- Returns: boolean.
-- PLAN 2.3; D2 ruling; T09 (mandatory), T09+. APIs: A39, A40.
-- ---------------------------------------------------------------------------
function EFV_HasOpenBordersFrom(s, r)
	local mode = EFV_Config.FLAG_VOLUNTEER_FRIENDS_OB
	if mode == "OFF" or s == nil or r == nil or s == r then
		return false
	end
	local d = Diplo(s)
	if d == nil then
		return false
	end
	if not EFV_IsGameplay() then
		local has = false
		-- EFV:UI-ONLY begin
		local ok, v = pcall(function() return d:HasOpenBordersFrom(r) end)
		has = (ok and v == true)
		-- EFV:UI-ONLY end
		return has
	end
	return OpenBordersFromDeals(s, r)
end

-- ---------------------------------------------------------------------------
-- EFV_VolunteerBasis(s, r) -> basis
-- Eligible Volunteer partner (D2 ruling): same team -> "TEAM", alliance ->
-- "ALLIANCE", declared friend AND EFV_HasOpenBordersFrom(s, r) -> "FRIEND_OB".
-- If an alliance ends but the pair are still declared friends with open
-- borders, the result is "FRIEND_OB" (still eligible; designer answer Q3).
-- Params:  s sender player ID, r recipient player ID.
-- Returns: "TEAM" | "ALLIANCE" | "FRIEND_OB" | nil.
-- PLAN 2.3; D2 ruling; designer answer Q3. APIs: as EFV_PartnerBasis + A39/A40.
-- ---------------------------------------------------------------------------
function EFV_VolunteerBasis(s, r)
	local basis = EFV_PartnerBasis(s, r)
	if basis == "TEAM" or basis == "ALLIANCE" then
		return basis
	end
	if basis == "FRIEND" and EFV_HasOpenBordersFrom(s, r) then
		return "FRIEND_OB"
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_HasCommonWar(s, r) -> bool
-- true if some alive player e (sorted IDs), not barbarian, e ~= s and e ~= r,
-- has s:IsAtWarWith(e) and r:IsAtWarWith(e). Works for city-states and Free
-- Cities (R3 2.2); Free Cities count as a common enemy, barbarians do not.
-- Params:  s, r player IDs.
-- Returns: boolean.
-- PLAN 2.3; spec 6.1.3. APIs: A43, A42, A36.
-- ---------------------------------------------------------------------------
function EFV_HasCommonWar(s, r)
	if s == nil or r == nil then
		return false
	end
	local dS, dR = Diplo(s), Diplo(r)
	if dS == nil or dR == nil then
		return false
	end
	for _, e in ipairs(EFV_SortedAlivePlayers()) do
		if e ~= s and e ~= r then
			local okB, isBarb = pcall(function() return Players[e]:IsBarbarian() end)
			if okB and not isBarb then
				local ok, both = pcall(function() return dS:IsAtWarWith(e) and dR:IsAtWarWith(e) end)
				if ok and both then
					return true
				end
			end
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- EFV_VolunteerLapseReason(s, r) -> reason
-- Volunteer lapse condition (designer answers Q2/Q3, generalising D2):
-- "WAR" if not EFV_HasCommonWar(s, r); else "PARTNER" if
-- EFV_VolunteerBasis(s, r) == nil (alliance, team or friend-with-open-borders
-- lost); else nil (all conditions hold: no lapse / lapse cancels).
-- Teammates never return "PARTNER" (TEAM basis).
-- Used by EFV_Lifecycle (start and cancel a lapse) and by the UI (tracker
-- text).
-- Params:  s sender player ID, r recipient player ID.
-- Returns: "WAR" | "PARTNER" | nil.
-- DECISIONS "Designer answers" Q2, Q3; PLAN 2.9 ProcessVolunteerLapse.
-- APIs: via EFV_HasCommonWar / EFV_VolunteerBasis.
-- ---------------------------------------------------------------------------
function EFV_VolunteerLapseReason(s, r)
	if not EFV_HasCommonWar(s, r) then
		return "WAR"
	end
	if EFV_VolunteerBasis(s, r) == nil then
		return "PARTNER"
	end
	return nil
end

-- ===========================================================================
-- Entrust rules (spec 12.2-12.4; PLAN 2.10, 3.4; Phase 6, INTERFACES note 31)
-- Shared by the gameplay snapshot / request handler (EFV_Entrust) and the
-- capture-popup buttons (EFV_EntrustPopup via EFV_UI_EntrustState), so both
-- sides give the same answer.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- EFV_EntrustCandidates(capturerID, oldOwnerID) -> recipients, partners
-- Capture-time eligibility (spec 12.2). partners = every alive player P
-- (ascending ID, P ~= capturer, P ~= old owner) with EFV_PartnerBasis(
-- capturer, P) ~= nil: a major civ that is a teammate, ally or declared
-- friend of the capturer and not at war with it (spec 2; the D2 open-borders
-- rule is for Volunteers only). recipients = the partners at war with the
-- city's pre-capture owner; when that owner is the Free Cities every partner
-- qualifies ("Free Cities count as at war with everyone"). Capitals and any
-- kind of captured city (major, city-state, Free City) are allowed: nothing
-- here looks at the city.
-- Params:  capturerID, oldOwnerID player IDs.
-- Returns: two dense ascending arrays of player IDs (may be empty).
-- APIs: A43, A42, A36 (+ EFV_PartnerBasis adapters).
-- ---------------------------------------------------------------------------
function EFV_EntrustCandidates(capturerID, oldOwnerID)
	local recipients, partners = {}, {}
	if type(capturerID) ~= "number" or type(oldOwnerID) ~= "number" then
		return recipients, partners
	end
	local oldIsFree = (EFV_PlayerKind(oldOwnerID) == "FREE_CITIES")
	for _, p in ipairs(EFV_SortedAlivePlayers()) do
		if p ~= capturerID and p ~= oldOwnerID and EFV_PartnerBasis(capturerID, p) ~= nil then
			partners[#partners + 1] = p
			if oldIsFree or AtWar(p, oldOwnerID) then
				recipients[#recipients + 1] = p
			end
		end
	end
	return recipients, partners
end

-- ---------------------------------------------------------------------------
-- EFV_EntrustSnapshotReasons(snap, playerID, turn) -> codes
-- Whether Entrust is offered at all for a capture (spec 12.1, 12.4 "only in
-- the capture decision"): no snapshot at the plot, another capturer, or a
-- snapshot from an earlier turn -> ENTRUST_STALE; no recipient qualified at
-- capture -> ENTRUST_NO_PARTNER. Empty = offered.
-- Params:  snap Entrust snapshot or nil; playerID the (local / requesting)
--          player; turn current game turn.
-- Returns: dense array of reason codes.
-- APIs: none.
-- ---------------------------------------------------------------------------
function EFV_EntrustSnapshotReasons(snap, playerID, turn)
	local codes = {}
	if type(snap) ~= "table" or snap.capturerID == nil or snap.capturerID ~= playerID
		or snap.turn == nil or snap.turn ~= turn then
		Add(codes, "ENTRUST_STALE")
		return codes
	end
	if type(snap.recipients) ~= "table" or #snap.recipients == 0 then
		Add(codes, "ENTRUST_NO_PARTNER")
	end
	return codes
end

-- ---------------------------------------------------------------------------
-- EFV_EntrustRecipientReasons(snap, playerID, recipientID) -> codes
-- Re-validation of one recipient against the capture-time snapshot (spec
-- 12.3 step 3; PLAN 2.10): recipientID must be in snap.recipients, still an
-- alive major civ, not the capturer and not at war with the capturer now.
-- Any failure -> ENTRUST_RECIPIENT_INVALID. Empty = may receive the city.
-- Params:  snap Entrust snapshot; playerID capturer; recipientID player ID.
-- Returns: dense array of reason codes.
-- APIs: A42, A36.
-- ---------------------------------------------------------------------------
function EFV_EntrustRecipientReasons(snap, playerID, recipientID)
	local codes = {}
	local listed = false
	if type(snap) == "table" and type(snap.recipients) == "table" then
		for _, r in ipairs(snap.recipients) do
			if r == recipientID then
				listed = true
			end
		end
	end
	if not listed or type(recipientID) ~= "number" or recipientID == playerID
		or not IsAlive(recipientID) or EFV_PlayerKind(recipientID) ~= "MAJOR"
		or AtWar(playerID, recipientID) then
		Add(codes, "ENTRUST_RECIPIENT_INVALID")
	end
	return codes
end

-- ---------------------------------------------------------------------------
-- EFV_UnitClass(pUnit) -> status, code
-- Whether a unit type can ever be sent (spec 1.2, 6.2.2; D4): FormationClass
-- in {FORMATION_CLASS_LAND_COMBAT, FORMATION_CLASS_NAVAL} (excludes air,
-- civilian incl. religious / great people / traders / spies, support); not
-- UNIT_HERO_*; CanTrain ~= 0 (Vampire, Questing Knight); not levied
-- (owner ~= original owner, same rule in both contexts, A32).
-- Warrior Monk and Nihang pass (D4). "NEVER" hides the Send buttons (14.1).
-- Params:  pUnit unit object.
-- Returns: "OK", nil  |  "NEVER", "CLASS_NEVER".
-- PLAN 2.3; D4. APIs: A31, A51, A32.
-- ---------------------------------------------------------------------------
function EFV_UnitClass(pUnit)
	local row = UnitRowOf(pUnit)
	if row == nil then
		return "NEVER", "CLASS_NEVER"
	end
	local fc = row.FormationClass
	if fc ~= "FORMATION_CLASS_LAND_COMBAT" and fc ~= "FORMATION_CLASS_NAVAL" then
		return "NEVER", "CLASS_NEVER"
	end
	if type(row.UnitType) == "string" and string.find(row.UnitType, "UNIT_HERO_", 1, true) == 1 then
		return "NEVER", "CLASS_NEVER"
	end
	if row.CanTrain == false or row.CanTrain == 0 then
		return "NEVER", "CLASS_NEVER"
	end
	if IsForeignOrigin(pUnit) then
		return "NEVER", "CLASS_NEVER"
	end
	return "OK", nil
end

-- ---------------------------------------------------------------------------
-- EFV_UnitSendReasons(pUnit, senderID, store) -> codes
-- Unit-level send conditions (spec 6.1.1, 6.2), in this order: sender human
-- major (NOT_HUMAN_MAJOR), owner == sender (NOT_OWNER), unit class
-- (CLASS_NEVER, from EFV_UnitClass, so the G handler re-validates it),
-- formation STANDARD (FORMATION, D3, A33), damage 0 (DAMAGED), plot owner ==
-- sender (NOT_OWN_TERRITORY), not embarked (EMBARKED; fallback land unit on
-- water), moves > 0 (NO_MOVES), not attacked (ATTACKED; skipped in G unless
-- EFV_Has(unit, "GetAttacksRemaining"), T09), not tracked by any record
-- (ALREADY_TRACKED, DV8). All failing conditions are listed (spec 6).
-- A nil unit (not found / not the requester's) returns { "REQ_STALE" }.
-- Params:  pUnit unit object, senderID player ID, store = gameplay store or
--          UI store (both expose ids/recs; INTERFACES "Store").
-- Returns: dense array of reason codes; empty = eligible.
-- PLAN 2.3; spec 6.2; SPIKES 3 row 6. APIs: A42, A31, A33, A25, A13, A32,
-- A23, A24.
-- ---------------------------------------------------------------------------
function EFV_UnitSendReasons(pUnit, senderID, store)
	local reasons = {}
	if pUnit == nil then
		Add(reasons, "REQ_STALE")
		return reasons
	end
	local pSender = (senderID ~= nil) and Players[senderID] or nil
	local okH, humanMajor = pcall(function() return pSender:IsHuman() and pSender:IsMajor() end)
	if pSender == nil or not okH or not humanMajor then
		Add(reasons, "NOT_HUMAN_MAJOR")
	end
	local owner = pUnit:GetOwner()
	if owner ~= senderID then
		Add(reasons, "NOT_OWNER")
	end
	local status, code = EFV_UnitClass(pUnit)
	if status ~= "OK" then
		Add(reasons, code or "CLASS_NEVER")
	end
	local okF, formation = pcall(function() return pUnit:GetMilitaryFormation() end)
	if okF and formation ~= nil and MilitaryFormationTypes ~= nil
			and formation ~= MilitaryFormationTypes.STANDARD_FORMATION then
		Add(reasons, "FORMATION")
	end
	local okD, damage = pcall(function() return pUnit:GetDamage() end)
	if okD and type(damage) == "number" and damage > 0 then
		Add(reasons, "DAMAGED")
	end
	local plot = Map.GetPlot(pUnit:GetX(), pUnit:GetY())
	local plotOwner = -1
	if plot ~= nil then
		plotOwner = plot:GetOwner()
	end
	if plotOwner ~= senderID then
		Add(reasons, "NOT_OWN_TERRITORY")
	end
	if IsEmbarkedCtx(pUnit, plot, UnitRowOf(pUnit)) then
		Add(reasons, "EMBARKED")
	end
	local okM, moves = pcall(function() return pUnit:GetMovesRemaining() end)
	if not okM or type(moves) ~= "number" or moves <= 0 then
		Add(reasons, "NO_MOVES")
	end
	if HasAttackedCtx(pUnit) then
		Add(reasons, "ATTACKED")
	end
	if IsTracked(store, owner, pUnit:GetID()) then
		Add(reasons, "ALREADY_TRACKED")
	end
	return reasons
end

-- Recipient-level evaluation, shared by all cities of one recipient.
-- Returns { reasons = {codes}, basis = accessBasis or nil }.
-- Order: basis (NOT_PARTNER / VOL_NEEDS_ACCESS / CS_NOT_MET),
-- AT_WAR_WITH_RECIPIENT, NO_COMMON_WAR (spec 6.1.2-6.1.4).
local function RecipientInfo(senderID, recipientID, forceType)
	local info = { reasons = {}, basis = nil }
	if recipientID == nil or recipientID == senderID or Players[recipientID] == nil or not IsAlive(recipientID) then
		Add(info.reasons, (forceType == EFV_Config.FT_CS) and "CS_NOT_MET" or "NOT_PARTNER")
		return info
	end
	local kind = EFV_PlayerKind(recipientID)
	if forceType == EFV_Config.FT_EXP then
		if kind == "MAJOR" then
			info.basis = EFV_PartnerBasis(senderID, recipientID)
		end
		if info.basis == nil then
			Add(info.reasons, "NOT_PARTNER")
		end
	elseif forceType == EFV_Config.FT_VOL then
		if kind == "MAJOR" then
			info.basis = EFV_VolunteerBasis(senderID, recipientID)
		end
		if info.basis == nil then
			if kind == "MAJOR" and EFV_PartnerBasis(senderID, recipientID) ~= nil then
				Add(info.reasons, "VOL_NEEDS_ACCESS")
			else
				Add(info.reasons, "NOT_PARTNER")
			end
		end
	elseif forceType == EFV_Config.FT_CS then
		if kind == "CITY_STATE" and HasMet(senderID, recipientID) then
			info.basis = "CITY_STATE"
		else
			Add(info.reasons, "CS_NOT_MET")
		end
	end
	if AtWar(senderID, recipientID) then
		Add(info.reasons, "AT_WAR_WITH_RECIPIENT")
	end
	if not EFV_HasCommonWar(senderID, recipientID) then
		Add(info.reasons, "NO_COMMON_WAR")
	end
	return info
end

-- Unit-level context shared by all rows of one picker build.
local function UnitContext(senderID, pUnit, store)
	local ctx = { senderID = senderID, pUnit = pUnit, row = nil, unitType = nil,
		unitReasons = nil, origin = nil, gold = GoldOf(senderID) }
	ctx.unitReasons = EFV_UnitSendReasons(pUnit, senderID, store)
	if pUnit ~= nil then
		ctx.row = UnitRowOf(pUnit)
		if ctx.row ~= nil then
			ctx.unitType = ctx.row.UnitType
		end
		ctx.origin = EFV_NearestCity(senderID, pUnit:GetX(), pUnit:GetY())
	end
	return ctx
end

-- One destination (city) for a prepared unit context and recipient info.
local function EvaluateCore(uctx, recipientID, pCity, forceType, rinfo)
	local reasons = {}
	if not IsReleased(forceType) then
		Add(reasons, "NOT_IMPLEMENTED")
	end
	for _, code in ipairs(uctx.unitReasons) do
		Add(reasons, code)
	end
	if pCity == nil then
		Add(reasons, "REQ_STALE")
		return false, reasons, nil
	end
	local cx, cy = pCity:GetX(), pCity:GetY()
	if pCity:GetOwner() ~= recipientID then
		Add(reasons, "CITY_NOT_OWNED")
	end
	if not IsRevealedTo(uctx.senderID, cx, cy) then
		Add(reasons, "NOT_REVEALED")
	end
	for _, code in ipairs(rinfo.reasons) do
		Add(reasons, code)
	end
	-- calc (filled whenever origin and band are computable, also when not ok)
	local calc = nil
	if uctx.origin ~= nil then
		local band, d = EFV_Band(uctx.origin:GetX(), uctx.origin:GetY(), cx, cy)
		if band ~= nil then
			calc = {
				origin   = uctx.origin,
				band     = band,
				distance = d,
				transit  = band,
				fee      = EFV_Fee(uctx.unitType, forceType, band),
				duration = EFV_Duration(forceType),
				basis    = rinfo.basis,
			}
		end
	end
	if calc ~= nil and calc.fee ~= nil and uctx.gold < calc.fee then
		Add(reasons, "GOLD")
	end
	-- Naval dry run (spec 6.2.7): future owner = recipient (EXP/CS), sender (VOL).
	if uctx.row ~= nil and uctx.row.Domain == "DOMAIN_SEA" then
		local futureOwner = recipientID
		if forceType == EFV_Config.FT_VOL then
			futureOwner = uctx.senderID
		end
		if EFV_SpawnCandidates(cx, cy, DOMAIN_SEA, futureOwner, nil) == nil then
			Add(reasons, "NAVAL_NO_SPAWN")
		end
	end
	-- Defensive: never report ok without the numbers the send handler needs.
	if #reasons == 0 and (calc == nil or calc.fee == nil) then
		Add(reasons, "REQ_STALE")
	end
	return #reasons == 0, reasons, calc
end

-- ---------------------------------------------------------------------------
-- EFV_DestinationRows(senderID, pUnit, forceType, store) -> rows
-- Picker rows. Candidate recipients in ascending ID order: EXP: alive majors
-- with EFV_PartnerBasis ~= nil; VOL: same list, rows disabled with
-- VOL_NEEDS_ACCESS when EFV_VolunteerBasis is nil; CS: alive city-states the
-- sender HasMet (A41). For each recipient city (sorted by GetID()) one row,
-- evaluated exactly like EFV_EvaluateSend (shared core; unit and recipient
-- checks computed once per call). Unreleased force types carry
-- NOT_IMPLEMENTED in every row.
-- Params:  senderID player ID, pUnit unit object, forceType EFV_Config.FT_*,
--          store (gameplay or UI store).
-- Returns: dense array of rows (shape INTERFACES "Destination row"):
--          { recipientID, cityID, destX, destY, ok, reasons, calc }
--          ({} for an unknown force type or on an engine error, logged).
-- PLAN 2.3, 3.3; spec 6.3, 14.2. APIs: A45, A41 (+ EFV_EvaluateSend).
-- ---------------------------------------------------------------------------
function EFV_DestinationRows(senderID, pUnit, forceType, store)
	local rows = {}
	if not IsKnownForce(forceType) then
		return rows
	end
	local ok, err = pcall(function()
		local uctx = UnitContext(senderID, pUnit, store)
		for _, r in ipairs(EFV_SortedAlivePlayers()) do
			if r ~= senderID then
				local candidate = false
				if forceType == EFV_Config.FT_CS then
					candidate = (EFV_PlayerKind(r) == "CITY_STATE" and HasMet(senderID, r))
				else
					candidate = (EFV_PartnerBasis(senderID, r) ~= nil)
				end
				if candidate then
					local rinfo = RecipientInfo(senderID, r, forceType)
					for _, pCity in ipairs(SortedCities(r)) do
						local okRow, reasons, calc = EvaluateCore(uctx, r, pCity, forceType, rinfo)
						rows[#rows + 1] = {
							recipientID = r,
							cityID      = pCity:GetID(),
							destX       = pCity:GetX(),
							destY       = pCity:GetY(),
							ok          = okRow,
							reasons     = reasons,
							calc        = calc,
						}
					end
				end
			end
		end
	end)
	if not ok then
		EFV_Log(1, "Config", "EFV_DestinationRows failed: %s", tostring(err))
		return {}
	end
	return rows
end

-- ---------------------------------------------------------------------------
-- EFV_EvaluateSend(senderID, pUnit, recipientID, pCity, forceType, store)
--   -> ok, reasons, calc
-- The full spec 6 check list for one destination, used by the UI rows AND
-- the gameplay send handler, in this order: NOT_IMPLEMENTED (unreleased
-- force type), unit reasons (EFV_UnitSendReasons), city owner == recipient
-- (CITY_NOT_OWNED), revealed to sender (NOT_REVEALED; G: A59 NEW-VERIFY,
-- skipped with a log line if unavailable), basis present (EXP: NOT_PARTNER,
-- VOL: VOL_NEEDS_ACCESS / NOT_PARTNER, CS: CS_NOT_MET), not at war
-- sender-recipient (AT_WAR_WITH_RECIPIENT), common war (NO_COMMON_WAR), gold
-- floor(GetGoldBalance()) >= fee (GOLD), naval dry run
-- EFV_SpawnCandidates(city, "SEA", futureOwner) ~= nil (NAVAL_NO_SPAWN;
-- futureOwner = recipient for EXP/CS, sender for VOL). A nil city -> REQ_STALE;
-- an unknown force type -> REQ_STALE. FEE_CHANGED is the handler's check.
-- calc is filled whenever origin and band can be computed (also when ok is
-- false, so disabled rows can show the fee). origin = sender city nearest to
-- the unit's tile (EFV_NearestCity, DV3).
-- Params:  senderID, recipientID player IDs; pUnit unit object; pCity city
--          object (destination); forceType EFV_Config.FT_*; store.
-- Returns: ok boolean; reasons dense array of codes (empty when ok);
--          calc table or nil (shape INTERFACES "calc"):
--          { origin = senderCity, band, distance, transit, fee, duration,
--            basis }
-- PLAN 2.3; spec 6. APIs: A46, A59, A36, A49 + those of the helpers.
-- ---------------------------------------------------------------------------
function EFV_EvaluateSend(senderID, pUnit, recipientID, pCity, forceType, store)
	if not IsKnownForce(forceType) then
		return false, { "REQ_STALE" }, nil
	end
	local okCall, ok, reasons, calc = pcall(function()
		local uctx = UnitContext(senderID, pUnit, store)
		local rinfo = RecipientInfo(senderID, recipientID, forceType)
		return EvaluateCore(uctx, recipientID, pCity, forceType, rinfo)
	end)
	if not okCall then
		EFV_Log(1, "Config", "EFV_EvaluateSend failed: %s", tostring(ok))
		return false, { "REQ_STALE" }, nil
	end
	return ok, reasons, calc
end

-- ---------------------------------------------------------------------------
-- EFV_ValidReturnTerritory(rec, plot) -> bool
-- plot:GetOwner() equals rec.senderID or rec.recipientID (spec 2; for CS
-- records the recipient is the city-state, spec 9.3).
-- Params:  rec record, plot plot object.
-- Returns: boolean (false for a nil record or plot).
-- PLAN 2.3. APIs: A13.
-- ---------------------------------------------------------------------------
function EFV_ValidReturnTerritory(rec, plot)
	if rec == nil or plot == nil then
		return false
	end
	local owner = plot:GetOwner()
	if owner == nil or owner < 0 then
		return false
	end
	return owner == rec.senderID or owner == rec.recipientID
end

-- ---------------------------------------------------------------------------
-- EFV_RecallReasons(rec, pUnit, turn) -> codes
-- Volunteer recall conditions (spec 9.2 as amended by the designer answers):
-- rec.forceType == VOLUNTEER (RECALL_NOT_VOLUNTEER; returned alone);
-- (turn - rec.deployedTurn >= VOLUNTEER_MIN_DEPLOYMENT or rec.lapsed == 1)
-- (RECALL_MIN_TURNS; UI shows N = VOLUNTEER_MIN_DEPLOYMENT - (turn -
-- deployedTurn)); unit on valid return territory (RECALL_TERRITORY). NO
-- full-HP requirement (designer answer; RECALL_DAMAGED retired). deployedTurn
-- never resets, so a lapse and its cancellation do not restart the minimum.
-- The record state (DEPLOYED / GRACE / MUTINY) is the caller's check.
-- Recall is a lapsed Volunteer's only way home: it never auto-returns, and
-- on valid territory its lapse is paused (designer ruling "Lapsed Volunteers
-- on valid land", INTERFACES note 29).
-- Params:  rec record, pUnit unit object (on-map unit of the record), turn
--          number (current turn).
-- Returns: dense array of reason codes; empty = recall allowed.
-- PLAN 2.3; spec 9.2; DECISIONS "Designer answers" (recall HP rule, Q2).
-- APIs: A13.
-- ---------------------------------------------------------------------------
function EFV_RecallReasons(rec, pUnit, turn)
	local reasons = {}
	if rec == nil or rec.forceType ~= EFV_Config.FT_VOL then
		Add(reasons, "RECALL_NOT_VOLUNTEER")
		return reasons
	end
	if rec.lapsed ~= 1 then
		if rec.deployedTurn == nil or turn == nil
				or (turn - rec.deployedTurn) < EFV_Config.VOLUNTEER_MIN_DEPLOYMENT then
			Add(reasons, "RECALL_MIN_TURNS")
		end
	end
	local plot = nil
	if pUnit ~= nil then
		plot = Map.GetPlot(pUnit:GetX(), pUnit:GetY())
	end
	if not EFV_ValidReturnTerritory(rec, plot) then
		Add(reasons, "RECALL_TERRITORY")
	end
	return reasons
end

-- ---------------------------------------------------------------------------
-- EFV_SpawnCandidates(cx, cy, domain, newOwnerID, opts) -> ring, plots
-- Spec 8 ring loop: for ring = 1..SPAWN_SEARCH_MAX_RING, plots of
-- Map.GetNeighborPlots(cx, cy, ring) with GetPlotDistance == ring that pass
-- EFV_SpawnValid; the first non-empty ring wins; plots sorted by
-- plot:GetIndex() (deterministic input for Game.GetRandNum, PLAN 1.6).
-- Params:  cx, cy centre (city) coordinates; domain "LAND" | "SEA";
--          newOwnerID player ID of the future owner; opts table or nil
--          (INTERFACES "Spawn opts": skipLake, ignoreWarOwner).
-- Returns: ring number and dense array of plot objects, or nil if no ring
--          has a valid plot.
-- PLAN 2.3; spec 8. APIs: A11, A08, A10.
-- ---------------------------------------------------------------------------
function EFV_SpawnCandidates(cx, cy, domain, newOwnerID, opts)
	if cx == nil or cy == nil or (domain ~= DOMAIN_LAND and domain ~= DOMAIN_SEA) then
		return nil
	end
	for ring = 1, EFV_Config.SPAWN_SEARCH_MAX_RING do
		local valid = EFV_SpawnRing(cx, cy, ring, domain, newOwnerID, opts)
		if #valid > 0 then
			return ring, valid
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_SpawnRing(cx, cy, ring, domain, newOwnerID, opts) -> plots
-- The valid plots (EFV_SpawnValid) at exactly distance ring from (cx, cy),
-- sorted by plot:GetIndex(); {} when none (or bad arguments). One ring of
-- EFV_SpawnCandidates; also used by EFV_Spawn.PickOrdered for the fallback
-- plots of the next rings (Session D item 3).
-- ---------------------------------------------------------------------------
function EFV_SpawnRing(cx, cy, ring, domain, newOwnerID, opts)
	local valid = {}
	if cx == nil or cy == nil or ring == nil or (domain ~= DOMAIN_LAND and domain ~= DOMAIN_SEA) then
		return valid
	end
	local plots = Map.GetNeighborPlots(cx, cy, ring)
	if plots ~= nil then
		for _, plot in ipairs(plots) do
			if plot ~= nil and Map.GetPlotDistance(cx, cy, plot:GetX(), plot:GetY()) == ring
					and EFV_SpawnValid(plot, domain, newOwnerID, opts) then
				valid[#valid + 1] = plot
			end
		end
	end
	table.sort(valid, function(a, b) return a:GetIndex() < b:GetIndex() end)
	return valid
end

-- ---------------------------------------------------------------------------
-- EFV_SpawnValid(plot, domain, newOwnerID, opts) -> ok, why
-- The single implementation of spec 8 valid(plot) (EFV_Spawn delegates here):
--   1. DOMAIN    LAND: not IsWater() and not IsImpassable(); SEA: IsWater()
--                and not IsImpassable();
--   2. WONDER    not IsNaturalWonder() if FLAG_SPAWN_EXCLUDE_NATURAL_WONDER;
--   3. UNITS     no unit of any player (G: GetUnitCount()==0; UI:
--                #Units.GetUnitsInPlot==0; plus #Units.GetUnitsInPlotLayerID(x,
--                y, MapLayers.ANY)==0 when available, A16, T09+). Mandatory:
--                Create does not check stacking (Session B T05);
--   4. CITY      not a city centre of another player (CityManager.GetCityAt);
--   5. WAR_OWNER owner -1, the new owner, or not at war with newOwnerID
--                (skipped when opts.ignoreWarOwner);
--   5b. ACCESS   the new owner may enter the plot (Session D 3: Create
--                returns nil on a free plot whose owner's borders are closed
--                to the new owner): owner -1, the new owner, a teammate, at
--                war with the new owner (war opens borders; rule 5 decides),
--                a city-state (borders open to players at peace), allied
--                with the new owner, or granting it open borders (G: deal
--                scan; UI: HasOpenBordersFrom, which is also true for
--                allies). Independent of FLAG_VOLUNTEER_FRIENDS_OB. The
--                Early Empire exception (all borders open before the civic)
--                is not modelled: such plots are rejected (conservative);
--   6. DEAD_END  >= SPAWN_MIN_EXITS adjacent plots (Map.GetAdjacentPlot over
--                0 .. DirectionTypes.NUM_DIRECTION_TYPES-1) passing rule 1;
--   7. LAKE      SEA: reject IsLake() and GetArea():GetPlotCount() <= 1 (G
--                only; skipped when opts.skipLake or in UI, A14; rule 6
--                already rejects 1-tile lakes).
-- An engine error is caught and reported as false, "ERROR" (logged once).
-- Params:  plot plot object; domain "LAND" | "SEA"; newOwnerID player ID;
--          opts table or nil.
-- Returns: true, nil  |  false, why (rule tag above; diagnostics only).
-- PLAN 2.3; spec 8; SPIKES 3 rows 11, 12. APIs: A13, A14, A15, A16, A12,
-- A36, A44.
-- ---------------------------------------------------------------------------
-- Rule 5b ACCESS: may newOwnerID's units enter land/water owned by owner?
local function HasPlotAccess(newOwnerID, owner)
	if owner == nil or owner < 0 or owner == newOwnerID then
		return true
	end
	if AtWar(newOwnerID, owner) or SameTeam(newOwnerID, owner) then
		return true
	end
	if EFV_PlayerKind(owner) == "CITY_STATE" then
		return true
	end
	local allied = PartnerState(newOwnerID, owner)
	if allied then
		return true
	end
	if EFV_IsGameplay() then
		return OpenBordersFromDeals(newOwnerID, owner)
	end
	local has = false
	-- EFV:UI-ONLY begin
	local d = Diplo(newOwnerID)
	if d ~= nil then
		local ok, v = pcall(function() return d:HasOpenBordersFrom(owner) end)
		has = (ok and v == true)
	end
	-- EFV:UI-ONLY end
	return has
end

local function SpawnValidCore(plot, domain, newOwnerID, opts)
	if not DomainOK(plot, domain) then
		return false, "DOMAIN"
	end
	if EFV_Config.FLAG_SPAWN_EXCLUDE_NATURAL_WONDER then
		local okN, nw = pcall(function() return plot:IsNaturalWonder() end)
		if okN and nw then
			return false, "WONDER"
		end
	end
	local x, y = plot:GetX(), plot:GetY()
	if HasUnitsOnPlot(plot, x, y) then
		return false, "UNITS"
	end
	local pCityAt = CityManager.GetCityAt(x, y)
	if pCityAt ~= nil and pCityAt:GetOwner() ~= newOwnerID then
		return false, "CITY"
	end
	if opts == nil or not opts.ignoreWarOwner then
		local owner = plot:GetOwner()
		if owner ~= nil and owner >= 0 and owner ~= newOwnerID and AtWar(newOwnerID, owner) then
			return false, "WAR_OWNER"
		end
	end
	if not HasPlotAccess(newOwnerID, plot:GetOwner()) then
		return false, "ACCESS"
	end
	local exits = 0
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local adj = Map.GetAdjacentPlot(x, y, dir)
		if adj ~= nil and DomainOK(adj, domain) then
			exits = exits + 1
		end
	end
	if exits < EFV_Config.SPAWN_MIN_EXITS then
		return false, "DEAD_END"
	end
	if domain == DOMAIN_SEA and (opts == nil or not opts.skipLake) and IsTinyLake(plot) then
		return false, "LAKE"
	end
	return true, nil
end

function EFV_SpawnValid(plot, domain, newOwnerID, opts)
	if plot == nil then
		return false, "ERROR"
	end
	local ok, valid, why = pcall(SpawnValidCore, plot, domain, newOwnerID, opts)
	if not ok then
		LogOnce("spawnValid", 1, "EFV_SpawnValid failed: %s", tostring(valid))
		return false, "ERROR"
	end
	return valid == true, why
end

EFV_Rules.LOADED = 1
