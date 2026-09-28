-- ===========================================================================
-- EFV_Lifecycle.lua
-- Module:   EFV_Lifecycle (global table)
-- Context:  gameplay only, include("EFV_Lifecycle").
-- Owner:    WP1.4 (Phase 1 subset), WP2.1 (grace/mutiny), WP3.2 (Volunteers),
--           WP5.1-5.3 (edge cases). See "Phase status" below.
--
-- Responsibility (PLAN 2.9, 2.12; spec 9, 11): reconcile eliminated players
-- and sender-recipient wars, refresh tracked unit references (killed /
-- disbanded / merged / upgraded), expiry timers, grace and mutiny with heal
-- suppression, Volunteer lapse (start AND cancel), recall, end-of-turn
-- snapshots, combat markers and the async elimination hint.
--
-- Designer answers (DECISIONS.md "Designer answers to PLAN.md 7.3 and 7.4")
-- override PLAN 2.9 where they differ:
--   * Q2: a Volunteer lapse is REVERSIBLE (reverses DV10). When the lapse
--     condition clears during GRACE or MUTINY the record returns to
--     rec.preLapseState ("DEPLOYED"); deployedTurn never resets; mutiny damage
--     already taken is not refunded.
--   * Q3: a lapse starts when the recipient stops being an eligible Volunteer
--     partner (EFV_VolunteerBasis == nil: alliance / team / friend with open
--     borders lost) OR the common war fails (EFV_VolunteerLapseReason). It
--     cancels when all conditions hold again. EXP/CS are unaffected by
--     alliance loss.
--   * Recall no longer requires full HP (EFV_RecallReasons).
--   * Q4: no EXPIRY_SOON for Volunteers, ever.
--   * "Lapsed Volunteers on valid land" (designer, 2026-09-28; INTERFACES
--     note 29): Volunteers NEVER auto-return (no GRACE_RETURN /
--     MUTINY_RETURN for VOL). While a lapsed Volunteer (GRACE / MUTINY)
--     stands on the sender's or the recipient's land its lapse is PAUSED
--     (rec.lapsePaused = 1): no graceTurnsLeft decrement, no mutiny damage,
--     no heal floor (engine healing is legitimate there and the floor
--     baseline follows it), recall allowed (minimum waived, no HP rule).
--     Off that land the countdown / 20 flat mutiny damage resume where they
--     stopped, with the heal floor active. The pause is evaluated at every
--     turn boundary (BoundaryOne) and at the turn-start tick (ProcessTimers).
--     EXP / CS keep the spec 9.1 auto-return.
--
-- Loss classification (rec deleted): "KILLED", "DISBANDED", "MERGED_ABSORBED".
-- ===========================================================================

if EFV_Lifecycle ~= nil and EFV_Lifecycle.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")
include("EFV_Notify")
include("EFV_Units")
include("EFV_Spawn")
include("EFV_Transit")

EFV_Lifecycle = {}

-- Phase status:
--   WP1.4 (Phase 1): RefreshTrackedUnits (basic: missing -> KILLED /
--     DISBANDED, delete + notify), OnCombat (lastCombatTurn marker),
--     VerifyCreatedThisTurn.
--   WP2.1 (Phase 2): the full ProcessTimers state machine for EXP / CS and
--     lapsed VOL (EXPIRY_SOON, expiry, GRACE, MUTINY with heal floor, death,
--     return from valid territory during grace or mutiny: since 0.5.1 EXP /
--     CS only, a lapsed Volunteer there is paused, note 29), EnterGrace (shared
--     with the Phase 3 lapse start), and the turn-boundary abstraction that
--     replaces GameEvents.OnPlayerTurnEnded (never fires in GS SP, Session C):
--     TurnBoundaryPass / OnTurnBoundary (S9 snapshots, S8 mutiny floor,
--     merge check, DV16 war check) at every per-player start hook and at
--     GameEvents.OnGameTurnEnded (Session E).
--   Phase 4 (WP4.2): CS branches need no own timer code (duration 10 is
--     frozen in rec.durationTurns; valid return territory = the city-state's
--     or the sender's tiles via EFV_ValidReturnTerritory). Added for CS: the
--     suzerain-levy relink in RefreshTrackedUnits (RelinkLevied), and WP5.1
--     landed early because city-states join their suzerain's wars and are
--     often conquered: ReconcilePlayers (sender / recipient eliminated),
--     HandleSenderRecipientWar and RevertToSender, shared by EXP and CS
--     (INTERFACES note 24). Their in-game acceptance tests stay P5.1-P5.5.
--   Phase 3 (WP3.2): ProcessVolunteerLapse (start WAR / PARTNER, backup
--     cancel), CancelVolunteerLapse (reversible lapse, LAPSE_CANCELLED),
--     OnRequestRecall, the Volunteer branch of OnMergeSurvivor (merge closes
--     the record, D3) and a Volunteer-only MERGED_ABSORBED check in
--     RefreshTrackedUnits.
--   Phase 5 (WP5.1-5.3, INTERFACES note 27): every spec 11 / PLAN 2.12 row
--     has a handler. EXP / CS merges (OnMergeSurvivor keeps the record,
--     rec.formation / rec.mergedTurn, MERGED _SURVIVOR to both; an absorbed
--     unit near a non-STANDARD unit within MergeSearchRadius -> MERGED
--     _ABSORBED to both, record closed), RelinkUpgraded (behind
--     FLAG_UPGRADE_RELINK, on since 0.5.2), the recipient-gone "no usable snapshot -> lost"
--     branch, OnCityConquered (last-moment S9 snapshot) and a log-only
--     OnPlayerDefeatHint (no async writes left).
--   0.5.2 (Session F MUST-FIX 1-4, INTERFACES note 30): stale unit objects
--     count as missing (EFV_UnitMatches GONE_*; dead objects mark
--     rec.killedTurn); relinks only to a provably identical unit, also at
--     every boundary (TryRelink); upgrade targets include the owner's unique
--     units; KILLED instead of a snapshot return when the recipient is
--     eliminated; CityConquered returns living units of an eliminated
--     recipient at once; OnCombat raises the mutiny floor baseline.
--
-- Turn-boundary abstraction (INTERFACES note 23). In-game order (Session C
-- T04, confirmed for every round by Session E T26): OnGameTurnStarted(N) ->
-- TurnBegin(N) -> human PlayerTurnStarted / PlayerTurnStartComplete / acts
-- -> each other living player in ID order (city-states, Free Cities 62,
-- Barbarians 63 last) PlayerTurnStarted -> PlayerTurnStartComplete -> acts
-- -> ENGINE HEAL (once per round, all units) -> GameEvents.OnGameTurnEnded(N)
-- -> TurnEnd(N) -> OnGameTurnStarted(N+1). PTS/PTSC fire for every living
-- player including the human (Session E).
-- Player P's turn has ended when ANY later per-player start hook fires (or
-- OnGameTurnEnded / the next OnGameTurnStarted). So the "turn-end" work is
-- done for ALL tracked records at EVERY GameEvents.PlayerTurnStarted(p) and
-- GameEvents.PlayerTurnStartComplete(p), at GameEvents.OnGameTurnEnded (the
-- first hook after the round heal: the mutiny floor resets it there) and
-- once more in the pipeline (step 0d, safety net). No heal ever falls inside
-- a PTS -> PTSC window: the per-player passes see only mid-turn changes
-- (combat, promotion heals, heal on kill, expulsions). The work is
-- idempotent (snapshot-if-changed, damage floor, war check that converts
-- the record), so it does not need to know whose turn ended, works for any
-- turn order (human not first, MP simultaneous turns, skipped players) and
-- cannot double-process.
-- Edge case (Session E item 2; Session F MUST-FIX 4): Barbarian combat and
-- the round heal fall in the same interval (PTSC[63] -> OnGameTurnEnded),
-- and so do a unit's own combat and a promotion heal / heal on kill in its
-- owner's turn; a floor that saw only the net change would lose up to
-- min(combat damage, heal) of the combat damage. Since 0.5.2 OnCombat raises
-- the baseline at the combat itself (read-only), so the next boundary
-- restores the heal to a value that includes the combat damage. This relies
-- on the damage being applied before GameEvents.OnCombatOccurred fires
-- (unmeasured, in-game check T31); otherwise the raise is a no-op and the
-- documented residual (at most one heal offset) remains.
--
-- Notification text arguments (placeholder order, localized in gameplay).
-- D9 alert types have a recipient text (LOC_<type>) and a sender text
-- (LOC_<type>_SENDER, same order, civ = the recipient):
--   EXPIRY_SOON  {1 unit, 2 N turns left, 3 sender civ | recipient civ}
--   GRACE        {1 unit, 2 sender civ | recipient civ, 3 N grace turns left}
--   MUTINY       {1 unit, 2 N turns until destroyed, 3 sender civ | recipient civ}
--   MUTINY_DEATH {1 unit}
--   UNIT_LOST    {1 unit, 2 loss text (LOC_EFV_LOSS_KILLED / _DISBANDED / _NO_CITY / _RECIPIENT_GONE)}
--   MERGED       {1 unit, 2 sender civ, 3 recipient civ} (text _SURVIVOR / _ABSORBED / _VOLUNTEER)
-- Recipients: EXP / CS -> recipient (the unit's owner) and sender; lapsed VOL
-- (owned by the sender) -> sender only, LOC_<type>_VOLUNTEER text (0.5.1),
-- and no GRACE / MUTINY while its lapse is paused (LAPSE_PAUSED instead:
--   LAPSE_PAUSED {1 unit, 2 recipient civ, 3 state text}, note 29).
--
-- Healing (Session C item 3; D7 "engine native" CONFIRMED for land units by
-- Session E: own/ally 15, neutral 10, friend with open borders 5 (the ENEMY
-- rate), city 20, medic +20). A unit created during turn N does not heal at
-- the end of round N (Session E, 6/6), so every EFV recreate starts healing
-- one round later. Gathering Storm's STRATEGIC_RESOURCE_MINIMUM_FOR_UNIT_
-- HEALING is CONFIRMED (Session F T13: a Swordsman did not heal for 17
-- rounds with Iron 0 and healed the round the stock became >= 1; naval own
-- water 20, neutral 0). The mutiny floor never assumes a heal happened: it
-- compares the current damage with rec.lastDamage and only restores a real
-- decrease.

-- ===========================================================================
-- File-local helpers
-- ===========================================================================

local function CurrentTurn()
	return Game.GetCurrentGameTurn()
end

local function UnitName(rec)
	local ok, s = pcall(EFV_UnitDisplayName, rec.unitType, rec.veteranName)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
	return tostring(rec.unitType)
end

-- Civilization short name: shared helper (EFV_Util, WP1.7).
local PlayerName = EFV_PlayerName

local function Extra(rec, kind)
	return { recordID = rec.id, kind = kind }
end

local function Touch(store)
	EFV_Records.Touch(store)
end

-- Sender-perspective text variant of a D9 alert type: LOC_<type>_SENDER
-- _MESSAGE / _SUMMARY (built at runtime; validate_data counts variant keys of
-- a notification type as used).
local SENDER_KEY_SUFFIX = "_SENDER"

-- ---------------------------------------------------------------------------
-- QueueAlert(rec, typeName, recipientArgs, senderArgs)
-- D9 alert notifications (EXPIRY_SOON, GRACE, MUTINY, MUTINY_DEATH) for a
-- record, located at rec.lastX / lastY, extra = { recordID, kind = type }.
-- EXP / CS: recipient (owner of the unit) with LOC_<type>, then the sender
-- with LOC_<type>_SENDER (senderArgs) or LOC_<type> (senderArgs nil). VOL
-- (lapsed, owned by the sender): sender only, with LOC_<type>_VOLUNTEER
-- (senderArgs; same argument order as _SENDER; the text says "recall it",
-- Volunteers never return by themselves). Non-human players are skipped by
-- EFV_Notify.Queue.
-- ---------------------------------------------------------------------------
local VOLUNTEER_KEY_SUFFIX = "_VOLUNTEER"

local function QueueAlert(rec, typeName, recipientArgs, senderArgs)
	local key = "LOC_" .. typeName
	local kind = string.gsub(typeName, "^EFV_NOTIF_", "")
	local isVol = (rec.forceType == EFV_Config.FT_VOL)
	if not isVol and rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, typeName, key, recipientArgs, rec.lastX, rec.lastY, Extra(rec, kind))
	end
	if senderArgs ~= nil then
		local suffix = isVol and VOLUNTEER_KEY_SUFFIX or SENDER_KEY_SUFFIX
		EFV_Notify.Queue(rec.senderID, typeName, key .. suffix, senderArgs, rec.lastX, rec.lastY, Extra(rec, kind))
	else
		EFV_Notify.Queue(rec.senderID, typeName, key, recipientArgs, rec.lastX, rec.lastY, Extra(rec, kind))
	end
end

local function NotifyGrace(rec, left)
	local unit = UnitName(rec)
	QueueAlert(rec, EFV_Config.NOTIF.GRACE,
		{ unit, PlayerName(rec.senderID), left },
		{ unit, PlayerName(rec.recipientID), left })
end

local function NotifyMutiny(rec, turnsLeft)
	local unit = UnitName(rec)
	QueueAlert(rec, EFV_Config.NOTIF.MUTINY,
		{ unit, turnsLeft, PlayerName(rec.senderID) },
		{ unit, turnsLeft, PlayerName(rec.recipientID) })
end

local function NotifyExpirySoon(rec, left)
	local unit = UnitName(rec)
	QueueAlert(rec, EFV_Config.NOTIF.EXPIRY_SOON,
		{ unit, left, PlayerName(rec.senderID) },
		{ unit, left, PlayerName(rec.recipientID) })
end

-- Current position of the record's unit (updates rec.lastX / lastY) and
-- whether it stands on valid return territory (sender's or recipient's
-- tiles, spec 9.1 / 9.3). Returns valid, x, y, plotOwner.
local function UnitPosition(store, rec, pUnit)
	local x, y = pUnit:GetX(), pUnit:GetY()
	-- Session F item 1: never store an off-map position (GetForRecord rejects
	-- such objects already; this is the second guard).
	if (x ~= rec.lastX or y ~= rec.lastY) and EFV_Units.ValidPosition(x, y) then
		rec.lastX, rec.lastY = x, y
		Touch(store)
	end
	local plot = Map.GetPlot(x, y)
	local valid = plot ~= nil and EFV_ValidReturnTerritory(rec, plot)
	return valid, x, y, plot and plot:GetOwner()
end

-- ---------------------------------------------------------------------------
-- FloorMutiny(store, rec, pUnit, hook) -> damage
-- S8 heal suppression by damage diff (never assumes that a heal happened:
-- GS units lacking their strategic resource do not heal at all, Session C).
-- d < rec.lastDamage -> SetDamage(lastDamage) ("[Floor] restore"); d >
-- lastDamage (combat) -> lastDamage = d ("[Floor] raise"); no lastDamage yet
-- -> lastDamage = d. Called for MUTINY records at every turn boundary and at
-- the pipeline's mutiny step.
-- ---------------------------------------------------------------------------
local function FloorMutiny(store, rec, pUnit, hook)
	local d = pUnit:GetDamage() or 0
	local last = tonumber(rec.lastDamage)
	if last == nil then
		rec.lastDamage = d
		Touch(store)
		return d
	end
	if d < last then
		pUnit:SetDamage(last)
		local now = pUnit:GetDamage() or last
		EFV_Log(2, "Floor", "restore id=%d hook=%s healed=%d from=%d to=%d", rec.id, tostring(hook), last - d, d, now)
		if rec.damage ~= now then
			rec.damage = now
			Touch(store)
		end
		return now
	elseif d > last then
		EFV_Log(2, "Floor", "raise id=%d hook=%s from=%d to=%d (combat)", rec.id, tostring(hook), last, d)
		rec.lastDamage = d
		Touch(store)
	end
	return d
end

-- ---------------------------------------------------------------------------
-- Paused Volunteer lapse (designer ruling "Lapsed Volunteers on valid land",
-- INTERFACES note 29).
-- ---------------------------------------------------------------------------

-- A lapsed Volunteer in GRACE or MUTINY (the only records that can pause).
local function IsLapsedVolunteer(rec)
	return rec.forceType == EFV_Config.FT_VOL and rec.lapsed == 1
		and (rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY)
end

-- Heal-floor baseline while the lapse is paused: engine healing on valid
-- land is legitimate, so nothing is restored; rec.lastDamage follows the
-- current damage, so a unit that later walks off valid land (floor active
-- again) never loses the healing it received while paused. Returns damage.
local function RefreshFloorBaseline(store, rec, pUnit, hook)
	local d = pUnit:GetDamage() or 0
	if tonumber(rec.lastDamage) ~= d then
		EFV_Log(3, "Floor", "baseline id=%d hook=%s from=%s to=%d (lapse paused)", rec.id, tostring(hook),
			tostring(rec.lastDamage), d)
		rec.lastDamage = d
		Touch(store)
	end
	return d
end

-- EFV_NOTIF_LAPSE_PAUSED to the sender: {1 unit, 2 recipient civ, 3 state
-- text (LOC_EFV_STATE_GRACE / _MUTINY with the count that resumes)}. Sent
-- once when a pause begins (not every turn: GRACE / MUTINY are not re-sent
-- while paused; the tracker's sweep dismisses the copy once the pause ends).
local function NotifyPaused(rec, pUnit)
	local stateText
	if rec.state == EFV_Config.ST_MUTINY then
		local d, maxD = 0, 100
		pcall(function()
			d = pUnit:GetDamage() or 0
			maxD = pUnit:GetMaxDamage() or 100
		end)
		local n = math.max(1, math.ceil((maxD - d) / EFV_Config.MUTINY_DAMAGE_PER_TURN))
		stateText = Locale.Lookup("LOC_EFV_STATE_MUTINY", n)
	else
		stateText = Locale.Lookup("LOC_EFV_STATE_GRACE", tonumber(rec.graceTurnsLeft) or EFV_Config.GRACE_TURNS)
	end
	local typeName = EFV_Config.NOTIF.LAPSE_PAUSED
	EFV_Notify.Queue(rec.senderID, typeName, "LOC_" .. typeName,
		{ UnitName(rec), PlayerName(rec.recipientID), stateText }, rec.lastX, rec.lastY, Extra(rec, "LAPSE_PAUSED"))
end

-- Sets rec.lapsePaused (1 / nil). A new pause queues EFV_NOTIF_LAPSE_PAUSED
-- unless silent (the lapse start: its own notification explains the pause).
-- Logs "[Lapse] paused ..." / "[Lapse] resumed ...".
local function SetLapsePaused(store, rec, paused, pUnit, hook, silent)
	local was = (rec.lapsePaused == 1)
	if paused == was then
		return
	end
	if paused then
		rec.lapsePaused = 1
	else
		rec.lapsePaused = nil
	end
	Touch(store)
	EFV_Log(2, "Lapse", "%s id=%d state=%s grace=%s dmg=%s at=%s,%s hook=%s",
		paused and "paused" or "resumed", rec.id, tostring(rec.state), tostring(rec.graceTurnsLeft),
		tostring(pUnit and pUnit:GetDamage()), tostring(rec.lastX), tostring(rec.lastY), tostring(hook))
	if paused and not silent then
		NotifyPaused(rec, pUnit)
	end
end

-- DEPLOYED / GRACE / MUTINY: the record has a unit on the map.
local function IsOnMapState(state)
	return state == EFV_Config.ST_DEPLOYED or state == EFV_Config.ST_GRACE or state == EFV_Config.ST_MUTINY
end

local function ForRecord(tag, rec, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		EFV_Log(1, tag, "record id=%s failed: %s", tostring(rec and rec.id), tostring(err))
	end
	return ok
end

local function StandardFormation()
	local ok, v = pcall(function()
		return MilitaryFormationTypes.STANDARD_FORMATION
	end)
	if ok then
		return v
	end
	return nil
end

-- True when pUnit's formation differs from the recorded one and is not
-- STANDARD (merge survivor, D3). rec.formation is updated only by
-- OnMergeSurvivor, so a change is reported until it has been handled.
local function FormationChanged(rec, pUnit)
	local ok, f = pcall(function()
		return pUnit:GetMilitaryFormation()
	end)
	if not ok or f == nil then
		return false
	end
	local std = StandardFormation()
	return std ~= nil and f ~= std and f ~= rec.formation
end

local function AtWar(a, b)
	local ok, v = pcall(function()
		return Players[a]:GetDiplomacy():IsAtWarWith(b)
	end)
	return ok and v == true
end

local function IsAliveID(pid)
	if pid == nil or Players[pid] == nil then
		return false
	end
	local ok, v = pcall(function()
		return Players[pid]:IsAlive()
	end)
	return ok and v == true
end

-- Merge survivor seen (formation changed, D3). OnMergeSurvivor (WP5.2)
-- updates rec.formation (EXP / CS) or closes the record (VOL), so it is
-- called once per real formation change.
local function CallMergeSurvivor(store, rec, pUnit)
	EFV_Log(2, "Merge", "formation change id=%d recorded=%s", rec.id, tostring(rec.formation))
	EFV_Lifecycle.OnMergeSurvivor(store, rec, pUnit)
end

-- Search radius (hexes from rec.lastX / lastY) for the merge-absorbed and
-- upgrade-relink heuristics (WP5.2): the unit type's BaseMoves (it may have
-- moved after its last snapshot) + EFV_Config.MERGE_SEARCH_EXTRA (the merge
-- partner stands next to it); at least 1.
local function MergeSearchRadius(unitType)
	local moves = 0
	local ok, row = pcall(function() return GameInfo.Units[unitType] end)
	if ok and row ~= nil and tonumber(row.BaseMoves) ~= nil then
		moves = tonumber(row.BaseMoves)
	end
	return math.max(1, moves + (EFV_Config.MERGE_SEARCH_EXTRA or 1))
end

-- D3 merge notifications (WP5.2). variant "SURVIVOR" / "ABSORBED" (EXP / CS:
-- the sender, the recipient and the unit's current owner if another human,
-- e.g. a suzerain holding a levied CS unit) or "VOLUNTEER" (the sender only:
-- the sender merged its own unit). Type EFV_NOTIF_MERGED, text
-- LOC_EFV_NOTIF_MERGED_<variant>_MESSAGE / _SUMMARY, args {1 unit, 2 sender
-- civ, 3 recipient civ}.
local function NotifyMerged(rec, variant, x, y)
	local typeName = EFV_Config.NOTIF.MERGED
	local key = "LOC_" .. typeName .. "_" .. variant
	local args = { UnitName(rec), PlayerName(rec.senderID), PlayerName(rec.recipientID) }
	local sent = {}
	local targets = { rec.senderID }
	if variant ~= "VOLUNTEER" then
		targets[#targets + 1] = rec.recipientID
		targets[#targets + 1] = rec.onMapPlayerID
	end
	for _, pid in ipairs(targets) do
		if pid ~= nil and not sent[pid] then
			sent[pid] = true
			EFV_Notify.Queue(pid, typeName, key, args, x, y, Extra(rec, "MERGED"))
		end
	end
end

-- ---------------------------------------------------------------------------
-- CloseLost(store, rec, class, where)   (0.5.2; shared by step 0b, step 0c
-- and OnCityConquered)
-- Closes a record whose unit is gone: EXP / CS -> EFV_NOTIF_UNIT_LOST
-- (LOC_EFV_LOSS_<class>) to the sender; VOL -> delete only (spec 11 rows
-- 6-7). Logs "[Refresh] missing id= class= ...".
-- ---------------------------------------------------------------------------
local function CloseLost(store, rec, class, where)
	EFV_Log(2, "Refresh", "missing id=%d class=%s owner=%s unit=%s last=%s,%s force=%s where=%s",
		rec.id, class, tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID),
		tostring(rec.lastX), tostring(rec.lastY), tostring(rec.forceType), tostring(where))
	if rec.forceType ~= EFV_Config.FT_VOL then
		EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.UNIT_LOST, "LOC_" .. EFV_Config.NOTIF.UNIT_LOST,
			{ UnitName(rec), Locale.Lookup("LOC_EFV_LOSS_" .. class) }, rec.lastX, rec.lastY, Extra(rec, "UNIT_LOST"))
	end
	EFV_Records.Delete(store, rec.id)
end

-- Marks a record whose unit object FindID still returns but which is dead
-- (GONE_DEAD: damage at the maximum, Session F T20): rec.killedTurn = turn.
-- Step 0b / 0c then classify it KILLED (never a return from the snapshot).
local function MarkKilled(store, rec, turn, hook)
	if rec.killedTurn == nil then
		rec.killedTurn = turn
		Touch(store)
		EFV_Log(2, "Combat", "dead unit object id=%d owner=%s unit=%s hook=%s -> killedTurn=%d",
			rec.id, tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID), tostring(hook), turn)
	end
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.ReconcilePlayers(store, turn)
-- Pipeline step 0b (spec 11 rows 1, 4, 5): sender not alive -> delete every
-- record of that sender (deployed EXP/CS units stay with the recipient).
-- Recipient not alive -> OUTBOUND: ConvertToReturn(.., "RECIPIENT_GONE",
-- destX, destY, turn); EXP/CS on the map: StartReturn(store, rec,
-- pUnitOrNil, "RECIPIENT_GONE", turn) (snapshot path, S9); deployed VOL:
-- unaffected here (step 4 sees the lapse). Sender and recipient at war ->
-- HandleSenderRecipientWar. Logs "[Reconcile] ...".
-- 0.5.2 (Session F MUST-FIX 1): recipient gone and the unit missing with
-- rec.killedTurn set or a combat marker of this or the last turn -> KILLED
-- (UNIT_LOST to the sender), never a return from the snapshot: a unit killed
-- defending the recipient's last city must not come home alive. Units that
-- survive the capture are found alive inside GameEvents.CityConquered (T20)
-- and returned there (OnCityConquered), so the marker is not ambiguous here.
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 0b, 2.9; spec 11. APIs: A42, A36 (+ helpers).
-- ---------------------------------------------------------------------------
-- Implemented in Phase 4 (WP5.1 brought forward, INTERFACES note 24): a
-- city-state recipient is eliminated far more often than a major, and its
-- units vanish with its last city (Session D), so the S9 snapshot return
-- must run before step 0c would classify the missing unit as DISBANDED.
-- Phase 5 (spec 11 row 4, S9): a record's snapshot can recreate the unit when
-- its type is a known unit type (GameInfo) and a snapshot was taken (snapTurn,
-- set at send and at every turn boundary). Promotions / XP gained after the
-- last boundary are not in it (documented limitation).
local function SnapshotUsable(rec)
	if type(rec.unitType) ~= "string" or rec.snapTurn == nil then
		return false
	end
	local ok, row = pcall(function() return GameInfo.Units[rec.unitType] end)
	return ok and row ~= nil
end

local function ReconcileOne(store, rec, turn)
	if not IsAliveID(rec.senderID) then
		-- Spec 11 row 5: deployed EXP / CS units stay with the recipient; the
		-- engine removes Volunteers; in-transit records vanish.
		EFV_Log(2, "Reconcile", "sender gone id=%d sender=%s state=%s force=%s -> record deleted",
			rec.id, tostring(rec.senderID), tostring(rec.state), tostring(rec.forceType))
		EFV_Records.Delete(store, rec.id)
		return
	end
	if not IsAliveID(rec.recipientID) then
		-- Spec 11 row 4.
		if rec.state == EFV_Config.ST_OUTBOUND then
			EFV_Log(2, "Reconcile", "recipient gone id=%d recipient=%s outbound -> return",
				rec.id, tostring(rec.recipientID))
			EFV_Transit.ConvertToReturn(store, rec, "RECIPIENT_GONE", rec.destX, rec.destY, turn)
		elseif IsOnMapState(rec.state) and rec.forceType ~= EFV_Config.FT_VOL then
			-- The engine removed the units with the player (Session D); a unit
			-- that still exists (e.g. levied by a suzerain) is taken along.
			local pUnit, why = EFV_Units.GetForRecord(rec)
			if pUnit == nil and why == "GONE_DEAD" then
				MarkKilled(store, rec, turn, "Reconcile")
			end
			if pUnit == nil and (rec.killedTurn ~= nil
				or (rec.lastCombatTurn ~= nil and rec.lastCombatTurn >= turn - 1)) then
				-- Session F MUST-FIX 1: killed in combat (e.g. defending the
				-- recipient's last city) -> lost, never resurrected.
				EFV_Log(2, "Reconcile", "recipient gone id=%d recipient=%s state=%s: unit killed (killedTurn=%s lastCombatTurn=%s) -> KILLED, no return",
					rec.id, tostring(rec.recipientID), tostring(rec.state), tostring(rec.killedTurn), tostring(rec.lastCombatTurn))
				CloseLost(store, rec, "KILLED", "Reconcile")
				return
			end
			if pUnit == nil and not SnapshotUsable(rec) then
				-- Phase 5: no unit and no restorable snapshot -> the unit is lost
				-- (sender notified; the recipient is gone).
				EFV_Log(2, "Reconcile", "recipient gone id=%d recipient=%s state=%s: no unit and no usable snapshot (type=%s snapTurn=%s) -> lost",
					rec.id, tostring(rec.recipientID), tostring(rec.state), tostring(rec.unitType), tostring(rec.snapTurn))
				EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.UNIT_LOST, "LOC_" .. EFV_Config.NOTIF.UNIT_LOST,
					{ UnitName(rec), Locale.Lookup("LOC_EFV_LOSS_RECIPIENT_GONE") }, rec.lastX, rec.lastY,
					Extra(rec, "UNIT_LOST"))
				EFV_Records.Delete(store, rec.id)
				return
			end
			EFV_Log(2, "Reconcile", "recipient gone id=%d recipient=%s state=%s unit=%s -> return (snapTurn=%s)",
				rec.id, tostring(rec.recipientID), tostring(rec.state), (pUnit ~= nil) and "found" or "snapshot",
				tostring(rec.snapTurn))
			EFV_Transit.StartReturn(store, rec, pUnit, "RECIPIENT_GONE", turn)
		end
		-- Deployed Volunteers: the sender's own units (lapse, step 4).
		-- RETURNING: unaffected.
		return
	end
	if rec.state ~= EFV_Config.ST_RETURNING and AtWar(rec.senderID, rec.recipientID) then
		EFV_Lifecycle.HandleSenderRecipientWar(store, rec, turn)
	end
end

function EFV_Lifecycle.ReconcilePlayers(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil then
			ForRecord("Reconcile", rec, ReconcileOne, store, rec, turn)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.HandleSenderRecipientWar(store, rec, turn)
-- Spec 11 row 1: EXP/CS on the map -> RevertToSender; any OUTBOUND ->
-- ConvertToReturn(.., "WAR", destX, destY, turn); VOL on the map -> delete
-- the record without touching the unit (DV6). Also called from
-- TurnBoundaryPass at every turn boundary (DV16). Logs "[War] ...".
-- Params:  store, rec record, turn number.
-- Returns: nil.
-- PLAN 2.9; DV6, DV16. APIs: via helpers.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.HandleSenderRecipientWar(store, rec, turn)
	if turn == nil then
		turn = CurrentTurn()
	end
	if rec.state == EFV_Config.ST_OUTBOUND then
		EFV_Log(2, "War", "id=%d sender=%s recipient=%s at war; in transit -> return",
			rec.id, tostring(rec.senderID), tostring(rec.recipientID))
		EFV_Transit.ConvertToReturn(store, rec, "WAR", rec.destX, rec.destY, turn)
		return nil
	end
	if not IsOnMapState(rec.state) then
		return nil
	end
	if rec.forceType == EFV_Config.FT_VOL then
		-- DV6: the unit is already the sender's; no recall from enemy land.
		EFV_Log(2, "War", "id=%d volunteer: record closed, the unit stays with its sender (DV6)", rec.id)
		EFV_Records.Delete(store, rec.id)
		return nil
	end
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		-- Killed, disbanded or levied: step 0c classifies / relinks it first.
		EFV_Log(3, "War", "id=%d at war but the unit is missing; left for step 0c", rec.id)
		return nil
	end
	EFV_Lifecycle.RevertToSender(store, rec, pUnit, turn)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.RevertToSender(store, rec, pUnit, turn) -> reverted
-- Snapshot, remove, create for the sender on the same tile if it is now
-- empty (EFV_SpawnValid with opts.ignoreWarOwner) else EFV_Spawn.Pick(lastX,
-- lastY, domain, senderID, "rev" .. id); none -> StartReturn (DV15). Delete
-- the record on success; queue EFV_NOTIF_REVERTED to both.
-- Params:  store, rec record (EXP/CS on the map), pUnit unit object or nil
--          (snapshot used), turn number.
-- Returns: true if the unit now belongs to the sender, false if it was sent
--          on the return trip instead (stub: false).
-- PLAN 2.9; spec 11 row 1; DV15. APIs: via helpers.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.RevertToSender(store, rec, pUnit, turn)
	if turn == nil then
		turn = CurrentTurn()
	end
	local x, y = rec.lastX, rec.lastY
	if pUnit ~= nil then
		local snap = EFV_Units.Snapshot(pUnit)
		if snap ~= nil then
			EFV_Units.ApplySnapshot(rec, snap, turn)
			Touch(store)
		end
		x, y = pUnit:GetX(), pUnit:GetY()
		if not EFV_Units.Remove(pUnit) then
			EFV_Log(1, "War", "revert id=%d: unit removal failed; retried at the next boundary", rec.id)
			return false
		end
	end
	-- The unit is gone from the recipient's side now.
	local wasOwner = rec.onMapPlayerID
	rec.onMapPlayerID = nil
	rec.onMapUnitID = nil
	rec.lastX, rec.lastY = x, y
	Touch(store)

	-- Same tile if it is free (spec 11: "on the same tile"; the at-war owner
	-- rule is skipped there), else the spawn search around it as the sender.
	-- A nil Create (closed borders, Session D 3) tries the next candidates
	-- (EFV_Spawn.PickOrdered, only when the same tile did not work).
	local domain = EFV_Spawn.DomainOf(rec.unitType)
	local pNew, plot, tried = nil, nil, 0
	if domain ~= nil and x ~= nil and y ~= nil then
		local here = Map.GetPlot(x, y)
		if here ~= nil and EFV_SpawnValid(here, domain, rec.senderID, { ignoreWarOwner = true }) then
			tried = 1
			pNew = EFV_Units.Recreate(store, rec.senderID, rec, here, turn)
			if pNew ~= nil then
				plot = here
			end
		end
		if pNew == nil then
			for _, p in ipairs(EFV_Spawn.PickOrdered(x, y, domain, rec.senderID, "rev" .. rec.id)) do
				tried = tried + 1
				pNew = EFV_Units.Recreate(store, rec.senderID, rec, p, turn)
				if pNew ~= nil then
					plot = p
					break
				end
			end
		end
	end
	if pNew == nil then
		-- DV15: no tile (or creation failed) -> the return trip instead.
		EFV_Log(2, "War", "revert id=%d: no tile near %s,%s (%s) -> return",
			rec.id, tostring(x), tostring(y), (tried > 0) and ("create failed, tries=" .. tried) or "no plot")
		EFV_Transit.StartReturn(store, rec, nil, "WAR", turn)
		return false
	end

	local args = { UnitName(rec), PlayerName(rec.senderID), PlayerName(rec.recipientID) }
	local px, py = plot:GetX(), plot:GetY()
	EFV_Notify.Queue(rec.senderID, EFV_Config.NOTIF.REVERTED, "LOC_" .. EFV_Config.NOTIF.REVERTED,
		args, px, py, Extra(rec, "REVERTED"))
	if rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, EFV_Config.NOTIF.REVERTED, "LOC_" .. EFV_Config.NOTIF.REVERTED,
			args, px, py, Extra(rec, "REVERTED"))
	end
	EFV_Log(2, "War", "reverted id=%d force=%s from=%s to=%d unit=%d at=%d,%d same=%s",
		rec.id, tostring(rec.forceType), tostring(wasOwner), rec.senderID, pNew:GetID(), px, py,
		tostring(px == x and py == y))
	EFV_Records.Delete(store, rec.id)
	return true
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.RefreshTrackedUnits(store, turn)
-- Pipeline step 0c (spec 11 rows 6-8, D3). For DEPLOYED / GRACE / MUTINY:
-- pUnit = EFV_Units.GetForRecord(rec) (identity check). Found: update lastX/Y;
-- formation changed from the recorded one -> OnMergeSurvivor. Missing:
-- rec.killedTurn or lastCombatTurn >= turn - 1 -> KILLED; else TryRelink
-- (RelinkUpgraded, (CS) RelinkLevied: provably the same unit only), then
-- MERGED_ABSORBED when a
-- non-STANDARD unit of onMapPlayerID (untracked or a fresh tracked merge
-- survivor) stands within MergeSearchRadius of lastX/lastY; else DISBANDED.
-- KILLED / DISBANDED: delete, EXP/CS queue EFV_NOTIF_UNIT_LOST (sender); VOL
-- delete only (spec 11 rows 6-7). MERGED_ABSORBED: delete, EFV_NOTIF_MERGED
-- (text _ABSORBED) to the sender and the recipient (EXP/CS, D3 ruling) or
-- (text _VOLUNTEER) to the sender (VOL). Complete since Phase 5 (WP5.2).
-- Logs "[Refresh] ...".
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 0c, 2.9; D3. APIs: A17, A33, A15, A12.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Relink safety (0.5.2, Session F MUST-FIX 2; INTERFACES note 30). A levy
-- and an upgrade re-create the unit with a NEW ID (T28, T30), so the record
-- must be re-pointed. A wrong relink would put an unrelated unit under the
-- mutiny floor and the +20 tick, the only way EFV could change the damage of
-- an untracked unit. Rule: relink only to a unit that is provably the same
-- one; a lost record is better than a hijacked unit. Every candidate must be
-- a live unit on the map (EFV_UnitGoneReason nil: the old objects FindID
-- still returns are excluded), owned by the owner the transition hands it
-- to, untracked by any record, of an allowed type and near the last
-- snapshot position; then exactly one candidate (or exactly one that equals
-- the snapshot) is taken, 0 or several -> no relink ("[Levy] ambiguous" /
-- "[Upgrade] ambiguous"), and the caller falls through to the normal loss
-- classification (DISBANDED / KILLED, sender notified).
-- ---------------------------------------------------------------------------

-- Session-local memo so an ambiguous relink is logged once per record, turn
-- and hook family (logging only; no game state).
local m_AmbiguousLogged = {}
local function LogAmbiguous(tag, rec, turn, n, detail)
	local key = tag .. ":" .. tostring(rec.id) .. ":" .. tostring(turn) .. ":" .. tostring(n)
	if m_AmbiguousLogged[key] then
		return
	end
	m_AmbiguousLogged[key] = true
	EFV_Log(2, tag, "ambiguous id=%d candidates=%d last=%s,%s type=%s %s -> no relink (fail safe)",
		rec.id, n, tostring(rec.lastX), tostring(rec.lastY), tostring(rec.unitType), tostring(detail or ""))
end

-- A player's units, sorted by ID (deterministic candidate order).
local function SortedUnits(pid)
	local list = {}
	local ok = pcall(function()
		for _, pU in Players[pid]:GetUnits():Members() do
			if pU ~= nil then
				list[#list + 1] = pU
			end
		end
	end)
	if not ok then
		return {}
	end
	table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
	return list
end

-- Agreement of a candidate with the record's last snapshot (levy: the copy
-- keeps formation, experience and promotions, T28): formation equal to
-- rec.formation (when recorded), experience >= rec.experience, promotions a
-- superset of rec.promotions. Returns agree, exact (exact = experience,
-- promotion count and damage all equal to the snapshot).
local function SnapshotAgreement(rec, pU)
	local ok, agree, exact = pcall(function()
		local exp = pU:GetExperience()
		local xp = exp:GetExperiencePoints() or 0
		local recXP = tonumber(rec.experience) or 0
		if xp < recXP then
			return false, false
		end
		if rec.formation ~= nil and pU:GetMilitaryFormation() ~= rec.formation then
			return false, false
		end
		local want = rec.promotions or {}
		for _, pt in ipairs(want) do
			local row = GameInfo.UnitPromotions[pt]
			if row == nil or not exp:HasPromotion(row.Index) then
				return false, false
			end
		end
		local count = 0
		for row in GameInfo.UnitPromotions() do
			if exp:HasPromotion(row.Index) then
				count = count + 1
			end
		end
		local same = (xp == recXP) and (count == #want) and ((pU:GetDamage() or 0) == (tonumber(rec.damage) or 0))
		return true, same
	end)
	if not ok then
		return false, false
	end
	return agree, exact
end

-- True when pU has every promotion of the record's snapshot (an upgrade
-- keeps the promotions; a candidate without them cannot be the same unit).
local function HasRecordPromotions(rec, pU)
	local ok, has = pcall(function()
		local exp = pU:GetExperience()
		for _, pt in ipairs(rec.promotions or {}) do
			local row = GameInfo.UnitPromotions[pt]
			if row == nil or not exp:HasPromotion(row.Index) then
				return false
			end
		end
		return true
	end)
	return ok and has == true
end

-- Picks the relink target from a candidate list ({ u, o, d, exact }):
-- exactly one candidate, else exactly one exact snapshot match, else nil
-- (ambiguous when there were candidates). Returns cand or nil, n.
local function PickUnique(cands)
	if #cands == 1 then
		return cands[1], 1
	end
	if #cands == 0 then
		return nil, 0
	end
	local exact = {}
	for _, c in ipairs(cands) do
		if c.exact then
			exact[#exact + 1] = c
		end
	end
	if #exact == 1 then
		return exact[1], #cands
	end
	return nil, #cands
end

-- ---------------------------------------------------------------------------
-- RelinkLevied(store, rec, turn, hook) -> pUnit or nil
-- (Phase 4, WP4.2; hardened 0.5.2, Session F items 2 and 8; INTERFACES
-- notes 24, 30)
-- A suzerain's levy hands the city-state's military units to the suzerain
-- (owner ~= original owner, Firaxis levy rule UnitFlagManager.lua:734-758)
-- and hands them back when the levy ends. Session F T28 CONFIRMED: every
-- owner change re-creates the unit with a new ID, GetOriginalOwner() stays
-- the city-state, the formation is kept, the tile is kept or shifts by up to
-- 2 hexes; the old object stays in the old owner's list at -9999,-9999 until
-- the next turn start (excluded as GONE_OFFMAP). Candidate owners: the
-- city-state (when the record currently points elsewhere: the levy ended)
-- and the city-state's current suzerain (GetSuzerain, G confirmed Session A).
-- Candidate unit: live on the map, GetOriginalOwner() == the city-state,
-- type == rec.unitType or an upgrade of it (EFV_IsUpgradeOf, unique units
-- included), untracked, at most EFV_Config.LEVY_RELINK_MAX_DIST (2, the T28
-- maximum) hexes from rec.lastX / lastY, and agreeing with the snapshot
-- (SnapshotAgreement). A levy moves ALL of the city-state's units, so a
-- native unit of the same type can qualify too: exactly one candidate, or
-- exactly one exact snapshot match, is relinked; otherwise none
-- ("[Levy] ambiguous"). Relinks onMapPlayerID / onMapUnitID / lastX / lastY;
-- the timer, grace and return rules continue unchanged (valid territory
-- stays the city-state's or the sender's). Logs "[Levy] relink ...".
-- ---------------------------------------------------------------------------
local function RelinkLevied(store, rec, turn, hook)
	local cs = rec.recipientID
	if not IsAliveID(cs) or not EFV_Units.ValidPosition(rec.lastX, rec.lastY) then
		return nil
	end
	local owners = {}
	if rec.onMapPlayerID ~= cs then
		owners[#owners + 1] = cs
	end
	local okS, suz = pcall(function()
		return Players[cs]:GetInfluence():GetSuzerain()
	end)
	if okS and type(suz) == "number" and suz >= 0 and suz ~= cs and suz ~= rec.onMapPlayerID then
		owners[#owners + 1] = suz
	end
	table.sort(owners)
	local maxDist = EFV_Config.LEVY_RELINK_MAX_DIST or 2
	local cands = {}
	for _, o in ipairs(owners) do
		if IsAliveID(o) then
			for _, pU in ipairs(SortedUnits(o)) do
				local okC, orig, row, uid, ux, uy = pcall(function()
					return pU:GetOriginalOwner(), GameInfo.Units[pU:GetType()], pU:GetID(), pU:GetX(), pU:GetY()
				end)
				if okC and orig == cs and row ~= nil and EFV_IsUpgradeOf(row.UnitType, rec.unitType)
					and EFV_UnitGoneReason(pU, o, uid) == nil
					and EFV_Records.FindByUnit(store, o, uid) == nil then
					local d = Map.GetPlotDistance(rec.lastX, rec.lastY, ux, uy)
					if d ~= nil and d <= maxDist then
						local agree, exact = SnapshotAgreement(rec, pU)
						if agree then
							cands[#cands + 1] = { u = pU, o = o, d = d, exact = exact, id = uid }
						end
					end
				end
			end
		end
	end
	local pick, n = PickUnique(cands)
	if pick == nil then
		if n > 1 then
			LogAmbiguous("Levy", rec, turn, n, "hook=" .. tostring(hook))
		end
		return nil
	end
	local best = pick.u
	EFV_Log(2, "Levy", "relink id=%d from=%s:%s to=%d:%d at=%d,%d dist=%d suzerain=%s candidates=%d hook=%s",
		rec.id, tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID), pick.o, pick.id,
		best:GetX(), best:GetY(), pick.d, tostring(suz), n, tostring(hook))
	rec.onMapPlayerID = pick.o
	rec.onMapUnitID = pick.id
	rec.lastX, rec.lastY = best:GetX(), best:GetY()
	Touch(store)
	return best
end

-- ---------------------------------------------------------------------------
-- TryRelink(store, rec, turn, hook) -> pUnit or nil   (0.5.2)
-- For a record whose unit is missing and has no combat marker of this or
-- the last turn (a marker means KILLED, spec 11): the upgrade relink
-- (FLAG_UPGRADE_RELINK, on since 0.5.2: T30 proved the new ID) and, for CS
-- records, the levy relink. Runs in step 0c AND at every turn boundary
-- (BoundaryOne), so a new unit is found before it can move away.
-- ---------------------------------------------------------------------------
local function TryRelink(store, rec, turn, hook)
	if rec.killedTurn ~= nil or (rec.lastCombatTurn ~= nil and rec.lastCombatTurn >= turn - 1) then
		return nil
	end
	if EFV_Config.FLAG_UPGRADE_RELINK then
		local pU = EFV_Lifecycle.RelinkUpgraded(store, rec, turn, hook)
		if pU ~= nil then
			return pU
		end
	end
	if rec.forceType == EFV_Config.FT_CS then
		return RelinkLevied(store, rec, turn, hook)
	end
	return nil
end

-- MERGED_ABSORBED heuristic (PLAN 2.9; Phase 3 for Volunteers, WP5.2 for
-- EXP / CS): a unit of rec.onMapPlayerID in a non-STANDARD formation within
-- MergeSearchRadius(rec.unitType) hexes of rec.lastX / lastY that is either
-- untracked, or tracked by another record as a fresh merge survivor (its
-- formation differs from that record's, or OnMergeSurvivor saw it this or
-- last turn: rec.mergedTurn). Nearest wins, ties lowest unit ID
-- (deterministic). Returns the survivor unit or nil.
local function AbsorbedIntoFormation(store, rec, turn)
	local pid = rec.onMapPlayerID
	local std = StandardFormation()
	if pid == nil or std == nil or rec.lastX == nil or rec.lastY == nil or not IsAliveID(pid) then
		return nil
	end
	local radius = MergeSearchRadius(rec.unitType)
	local list = {}
	for _, pU in Players[pid]:GetUnits():Members() do
		if pU ~= nil then
			list[#list + 1] = pU
		end
	end
	table.sort(list, function(a, b) return a:GetID() < b:GetID() end)
	local best, bestDist = nil, nil
	for _, pU in ipairs(list) do
		local okF, f = pcall(function() return pU:GetMilitaryFormation() end)
		-- Session F: skip unit objects that are no longer live units.
		if okF and f ~= nil and f ~= std and EFV_UnitGoneReason(pU, pid, pU:GetID()) == nil then
			local other = EFV_Records.FindByUnit(store, pid, pU:GetID())
			local eligible = (other == nil)
			if other ~= nil and other.id ~= rec.id then
				eligible = (f ~= other.formation)
					or (tonumber(other.mergedTurn) ~= nil and other.mergedTurn >= turn - 1)
			end
			if eligible then
				local d = Map.GetPlotDistance(rec.lastX, rec.lastY, pU:GetX(), pU:GetY())
				if d ~= nil and d <= radius and (bestDist == nil or d < bestDist) then
					best, bestDist = pU, d
				end
			end
		end
	end
	return best
end

local function RefreshOne(store, rec, turn)
	-- Identity-checked (Session C item 2; Session F item 1): a reused slot, a
	-- dead, off-map or replaced unit object counts as missing.
	local pUnit, why = EFV_Units.GetForRecord(rec)
	if pUnit ~= nil then
		local x, y = pUnit:GetX(), pUnit:GetY()
		if (x ~= rec.lastX or y ~= rec.lastY) and EFV_Units.ValidPosition(x, y) then
			rec.lastX, rec.lastY = x, y
			EFV_Records.Touch(store)
		end
		if FormationChanged(rec, pUnit) then
			CallMergeSurvivor(store, rec, pUnit)
		end
		return
	end

	-- Missing. A dead unit object (Session F) or a combat marker of this or
	-- the last turn wins (KILLED).
	if why == "GONE_DEAD" then
		MarkKilled(store, rec, turn, "Refresh")
	end
	local class = "DISBANDED"
	if rec.killedTurn ~= nil or (rec.lastCombatTurn ~= nil and rec.lastCombatTurn >= turn - 1) then
		class = "KILLED"
	end
	-- Upgrade relink (spec 11 "(added)" row, PLAN 2.12; FLAG_UPGRADE_RELINK,
	-- on since 0.5.2: T30 proved that an upgrade creates a NEW unit ID) and,
	-- for CS records, the levy relink (T28: new IDs too). Both relink only a
	-- provably identical unit (TryRelink / RelinkUpgraded / RelinkLevied,
	-- Session F item 2); otherwise the record falls through to the loss
	-- classification below. Normally a boundary pass has relinked already.
	if class ~= "KILLED" and TryRelink(store, rec, turn, "Refresh") ~= nil then
		return
	end
	-- D3 (Phase 3 for VOL, WP5.2 for EXP / CS): absorbed into a Corps / Army.
	-- The record is closed either way; only the message differs.
	if class ~= "KILLED" then
		local survivor = AbsorbedIntoFormation(store, rec, turn)
		if survivor ~= nil then
			local sx, sy = survivor:GetX(), survivor:GetY()
			if rec.forceType == EFV_Config.FT_VOL then
				EFV_Log(2, "Merge", "volunteer id=%d absorbed into unit=%d at=%d,%d (last %s,%s) -> record closed (D3)",
					rec.id, survivor:GetID(), sx, sy, tostring(rec.lastX), tostring(rec.lastY))
				NotifyMerged(rec, "VOLUNTEER", sx, sy)
			else
				-- D3 ruling: absorbed into another unit -> lost to the sender,
				-- never returns; both players are told.
				EFV_Log(2, "Merge", "absorbed id=%d force=%s owner=%s into unit=%d at=%d,%d (last %s,%s) -> lost to sender=%d, record closed (D3)",
					rec.id, tostring(rec.forceType), tostring(rec.onMapPlayerID), survivor:GetID(), sx, sy,
					tostring(rec.lastX), tostring(rec.lastY), rec.senderID)
				NotifyMerged(rec, "ABSORBED", sx, sy)
			end
			EFV_Records.Delete(store, rec.id)
			return
		end
	end
	CloseLost(store, rec, class, "Refresh")
end

function EFV_Lifecycle.RefreshTrackedUnits(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and IsOnMapState(rec.state) then
			ForRecord("Refresh", rec, RefreshOne, store, rec, turn)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnMergeSurvivor(store, rec, pUnit)
-- The tracked unit survived a merge (formation ~= STANDARD). EXP/CS: keep
-- the record (returns as a single unit, D3), update rec.formation, queue
-- EFV_NOTIF_MERGED to both. VOL: delete the record (volunteer status ends,
-- D3 ruling), notify the sender. Logs "[Merge] ...".
-- Params:  store, rec record, pUnit unit object.
-- Returns: nil.
-- PLAN 2.9; D3 ruling. APIs: A33.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.OnMergeSurvivor(store, rec, pUnit)
	local x, y = rec.lastX, rec.lastY
	local okP, px, py = pcall(function() return pUnit:GetX(), pUnit:GetY() end)
	if okP and px ~= nil then
		x, y = px, py
	end
	local okF, f = pcall(function() return pUnit:GetMilitaryFormation() end)
	if rec.forceType == EFV_Config.FT_VOL then
		-- Phase 3 (D3 ruling): the sender merged its own Volunteer into a
		-- Corps / Army. Volunteer status ends: the record is closed, the
		-- unit (the sender's) is left alone, the sender is notified. No
		-- return and no recall afterwards.
		NotifyMerged(rec, "VOLUNTEER", x, y)
		EFV_Log(2, "Merge", "volunteer id=%d survivor unit=%s formation=%s state=%s lapsed=%s -> record closed (D3)",
			rec.id, tostring(rec.onMapUnitID), tostring(okF and f), tostring(rec.state), tostring(rec.lapsed))
		EFV_Records.Delete(store, rec.id)
		return nil
	end
	-- WP5.2 (D3 ruling): an EXP / CS unit that survived a merge keeps its
	-- record and its timer. It returns (expiry, war revert, recipient gone)
	-- as a single unit of its current type with its XP and promotions:
	-- EFV_Units.Recreate never restores a formation, so the absorbed partner
	-- (the recipient's unit) does not come along. rec.formation takes the new
	-- value (only writer), so this runs once per formation change (Corps ->
	-- Army notifies again); rec.mergedTurn lets step 0c recognise this unit
	-- as the partner of an absorbed tracked unit.
	if not okF or f == nil then
		EFV_Log(1, "Merge", "survivor id=%d: formation unreadable", rec.id)
		return nil
	end
	local was = rec.formation
	rec.formation = f
	rec.mergedTurn = CurrentTurn()
	rec.lastX, rec.lastY = x, y
	Touch(store)
	NotifyMerged(rec, "SURVIVOR", x, y)
	EFV_Log(2, "Merge", "survivor id=%d force=%s owner=%s unit=%s formation=%s->%s state=%s -> record kept, returns as a single unit (D3)",
		rec.id, tostring(rec.forceType), tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID), tostring(was),
		tostring(f), tostring(rec.state))
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.ProcessTimers(store, turn)
-- Pipeline step 3 (spec 9.1, 9.3, 14.3; D9; DV7). Implemented in WP2.1.
-- EXP/CS in DEPLOYED: left = durationTurns - (turn - deployedTurn); left in
-- EXPIRY_WARN_AT -> EFV_NOTIF_EXPIRY_SOON (recipient and sender; never for
-- VOL, designer answer Q4); left <= 0 (expiry turn E) -> valid return
-- territory ? StartReturn(.., "EXPIRED") : EnterGrace (GRACE, graceTurnsLeft
-- = GRACE_TURNS, EFV_NOTIF_GRACE N = 5).
-- Lapsed VOL in GRACE / MUTINY: FIRST, if EFV_VolunteerLapseReason(sender,
-- recipient) == nil -> CancelVolunteerLapse and skip the rest (designer
-- answer Q2).
-- GRACE (EXP, CS): valid territory -> StartReturn(.., "GRACE_RETURN");
-- else graceTurnsLeft - 1; > 0 -> EFV_NOTIF_GRACE (N, re-sent every turn,
-- D9); == 0 -> state MUTINY, lastDamage = GetDamage(), and the mutiny step
-- runs at once.
-- MUTINY (EXP, CS): heal floor first (S8), then valid territory ->
-- StartReturn(.., "MUTINY_RETURN") (the returned unit keeps its floored
-- damage); else the mutiny step: d + MUTINY_DAMAGE_PER_TURN >=
-- GetMaxDamage() -> remove, delete, EFV_NOTIF_MUTINY_DEATH; else
-- ChangeDamage(20), lastDamage = new damage, EFV_NOTIF_MUTINY (N =
-- ceil((max - lastDamage) / 20)).
-- Lapsed VOL in GRACE / MUTINY (designer ruling "Lapsed Volunteers on valid
-- land", INTERFACES note 29): NEVER an automatic return. Valid territory ->
-- PAUSED (rec.lapsePaused = 1, EFV_NOTIF_LAPSE_PAUSED once when the pause
-- begins): no decrement, no damage, no heal floor (the baseline lastDamage
-- follows the engine healing), no GRACE / MUTINY re-send. Elsewhere ->
-- lapsePaused cleared and the same GRACE / MUTINY step as above, continuing
-- from the stored graceTurnsLeft / current damage (20 flat per turn).
-- Timeline (P2.1): expiry at E -> GRACE 5 at E, 4..1 at E+1..E+4 -> 20 damage
-- at E+5, 40 / 60 / 80 at E+6..E+8 -> death at E+9 (from full HP).
-- A unit that is missing here (it vanished after step 0c) is left for step
-- 0c of the next turn. Logs "[Timer]", "[Grace]", "[Mutiny]", "[Floor]".
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 3, 2.9. APIs: A10, A25, A13 (+ helpers).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.EnterGrace(store, rec, turn, cause, silent)   (added WP2.1)
-- Puts an on-map record into GRACE: state = GRACE, graceTurnsLeft =
-- GRACE_TURNS, lastDamage cleared. Unless silent, queues EFV_NOTIF_GRACE
-- (N = GRACE_TURNS). The grace countdown then runs in ProcessTimers from the
-- NEXT turn start. Used by the EXP / CS expiry (cause "EXPIRED") and, in
-- Phase 3, by ProcessVolunteerLapse (cause "WAR" / "PARTNER", silent = true,
-- because the lapse sends EFV_NOTIF_VOLUNTEER_LAPSE / ACCESS_LAPSE instead;
-- it must also set lapsed / lapseReason / lapseTurn / preLapseState first).
-- Logs "[Grace] start ...".
-- Params:  store; rec record (DEPLOYED); turn number; cause string (log);
--          silent boolean or nil.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.EnterGrace(store, rec, turn, cause, silent)
	rec.state = EFV_Config.ST_GRACE
	rec.graceTurnsLeft = EFV_Config.GRACE_TURNS
	rec.lastDamage = nil
	Touch(store)
	EFV_Log(2, "Grace", "start id=%d cause=%s left=%d at=%s,%s force=%s",
		rec.id, tostring(cause), rec.graceTurnsLeft, tostring(rec.lastX), tostring(rec.lastY), tostring(rec.forceType))
	if not silent then
		NotifyGrace(rec, rec.graceTurnsLeft)
	end
	return nil
end

-- Expiry warnings and expiry for EXP / CS in DEPLOYED.
local function TimerDeployed(store, rec, turn)
	if rec.durationTurns == nil or rec.deployedTurn == nil then
		return
	end
	local left = rec.durationTurns - (turn - rec.deployedTurn)
	if left > 0 then
		for _, warnAt in ipairs(EFV_Config.EXPIRY_WARN_AT) do
			if left == warnAt then
				local pUnit = EFV_Units.GetForRecord(rec)
				if pUnit ~= nil then
					UnitPosition(store, rec, pUnit)
				end
				NotifyExpirySoon(rec, left)
				EFV_Log(2, "Timer", "warn id=%d left=%d", rec.id, left)
			end
		end
		return
	end

	-- Expiry turn (spec 9.1: turn - deployedTurn >= duration).
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		-- Step 0c ran this turn; a unit missing now is classified next turn.
		EFV_Log(1, "Timer", "expiry id=%d unit missing owner=%s unit=%s", rec.id, tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID))
		return
	end
	local valid, x, y, owner = UnitPosition(store, rec, pUnit)
	EFV_Log(2, "Timer", "expiry id=%d left=%d at=%d,%d owner=%s valid=%s",
		rec.id, left, x, y, tostring(owner), tostring(valid))
	if valid then
		-- No HP requirement for Expeditionary auto-return (spec 9.1).
		EFV_Transit.StartReturn(store, rec, pUnit, "EXPIRED", turn)
		return
	end
	-- Spec 9.1 step 2: outside valid territory -> grace (WP2.1).
	EFV_Lifecycle.EnterGrace(store, rec, turn, "EXPIRED", false)
end

-- Designer answer Q2: a lapsed Volunteer whose lapse condition has cleared
-- cancels BEFORE any grace / mutiny tick. Returns true if cancelled.
local function TryCancelLapse(store, rec, turn)
	if EFV_VolunteerLapseReason(rec.senderID, rec.recipientID) ~= nil then
		return false
	end
	EFV_Lifecycle.CancelVolunteerLapse(store, rec, turn)
	return rec.state == EFV_Config.ST_DEPLOYED
end

-- The mutiny step (spec 9.1 "after grace"): floor, then death or +20.
local function MutinyStep(store, rec, turn, pUnit)
	local d = FloorMutiny(store, rec, pUnit, "OnGameTurnStarted")
	local maxD = pUnit:GetMaxDamage() or 100
	local step = EFV_Config.MUTINY_DAMAGE_PER_TURN
	if d + step >= maxD then
		-- Death: remove explicitly (never kill by damage, SPIKES S8).
		local x, y = pUnit:GetX(), pUnit:GetY()
		rec.lastX, rec.lastY = x, y
		if not EFV_Units.Remove(pUnit) then
			EFV_Log(1, "Mutiny", "death id=%d: unit removal failed; retried next turn", rec.id)
			Touch(store)
			return
		end
		EFV_Log(2, "Mutiny", "death id=%d dmg=%d max=%d at=%d,%d force=%s", rec.id, d, maxD, x, y, tostring(rec.forceType))
		QueueAlert(rec, EFV_Config.NOTIF.MUTINY_DEATH, { UnitName(rec) }, nil)
		EFV_Records.Delete(store, rec.id)
		return
	end
	pUnit:ChangeDamage(step)
	local now = pUnit:GetDamage() or (d + step)
	rec.lastDamage = now
	rec.damage = now
	Touch(store)
	local turnsLeft = math.ceil((maxD - now) / step)
	if turnsLeft < 1 then
		turnsLeft = 1
	end
	EFV_Log(2, "Mutiny", "id=%d dmg=%d max=%d turnsLeft=%d at=%s,%s", rec.id, now, maxD, turnsLeft,
		tostring(rec.lastX), tostring(rec.lastY))
	NotifyMutiny(rec, turnsLeft)
end

local function TimerGrace(store, rec, turn)
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		EFV_Log(2, "Grace", "id=%d unit missing; step 0c classifies it next turn", rec.id)
		return
	end
	local valid, x, y = UnitPosition(store, rec, pUnit)
	if rec.forceType == EFV_Config.FT_VOL then
		-- Designer ruling (note 29): a lapsed Volunteer never returns by
		-- itself. On valid land the countdown is paused (recall it there);
		-- off it the countdown continues from graceTurnsLeft.
		SetLapsePaused(store, rec, valid, pUnit, "OnGameTurnStarted")
		if valid then
			EFV_Log(2, "Grace", "paused id=%d left=%s at=%d,%d (volunteer on valid land: no tick)",
				rec.id, tostring(rec.graceTurnsLeft), x, y)
			return
		end
	elseif valid then
		-- Spec 9.1 "during grace" (EXP / CS): back on valid territory -> auto-return.
		EFV_Log(2, "Grace", "return id=%d at=%d,%d", rec.id, x, y)
		EFV_Transit.StartReturn(store, rec, pUnit, "GRACE_RETURN", turn)
		return
	end
	local left = (tonumber(rec.graceTurnsLeft) or EFV_Config.GRACE_TURNS) - 1
	if left > 0 then
		rec.graceTurnsLeft = left
		Touch(store)
		EFV_Log(2, "Grace", "id=%d left=%d at=%d,%d", rec.id, left, x, y)
		NotifyGrace(rec, left)   -- re-sent every turn (D9)
		return
	end
	-- Grace is over: mutiny starts now and the first step applies at once.
	rec.state = EFV_Config.ST_MUTINY
	rec.graceTurnsLeft = nil
	rec.lastDamage = pUnit:GetDamage() or 0
	Touch(store)
	EFV_Log(2, "Mutiny", "start id=%d dmg=%d at=%d,%d force=%s", rec.id, rec.lastDamage, x, y, tostring(rec.forceType))
	MutinyStep(store, rec, turn, pUnit)
end

local function TimerMutiny(store, rec, turn)
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		EFV_Log(2, "Mutiny", "id=%d unit missing; step 0c classifies it next turn", rec.id)
		return
	end
	if rec.forceType == EFV_Config.FT_VOL then
		-- Designer ruling (note 29): no MUTINY_RETURN for Volunteers. On valid
		-- land the mutiny is paused (no damage, no heal floor: the unit heals
		-- by engine rules and the floor baseline follows); off it the 20 flat
		-- damage resumes (MutinyStep floors first).
		local valid, x, y = UnitPosition(store, rec, pUnit)
		SetLapsePaused(store, rec, valid, pUnit, "OnGameTurnStarted")
		if valid then
			local d = RefreshFloorBaseline(store, rec, pUnit, "OnGameTurnStarted")
			EFV_Log(2, "Mutiny", "paused id=%d dmg=%d at=%d,%d (volunteer on valid land: no damage)", rec.id, d, x, y)
			return
		end
		MutinyStep(store, rec, turn, pUnit)
		return
	end
	-- Heal floor first, so a return snapshots the floored damage (spec 9.1:
	-- units in mutiny cannot heal; the returned unit keeps its damage).
	-- Safety net: the OnGameTurnEnded boundary normally reset the round heal
	-- already (Session E), so this finds nothing to restore.
	FloorMutiny(store, rec, pUnit, "OnGameTurnStarted")
	local valid, x, y = UnitPosition(store, rec, pUnit)
	if valid then
		EFV_Log(2, "Mutiny", "return id=%d at=%d,%d dmg=%s", rec.id, x, y, tostring(pUnit:GetDamage()))
		EFV_Transit.StartReturn(store, rec, pUnit, "MUTINY_RETURN", turn)
		return
	end
	MutinyStep(store, rec, turn, pUnit)
end

local function TimerOne(store, rec, turn)
	if rec.forceType == EFV_Config.FT_VOL and rec.lapsed == 1
		and (rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY) then
		if TryCancelLapse(store, rec, turn) then
			return
		end
	end
	if rec.state == EFV_Config.ST_DEPLOYED then
		-- EXP / CS only: Volunteers have no timer and never get EXPIRY_SOON (Q4).
		if rec.forceType ~= EFV_Config.FT_VOL then
			TimerDeployed(store, rec, turn)
		end
	elseif rec.state == EFV_Config.ST_GRACE then
		TimerGrace(store, rec, turn)
	elseif rec.state == EFV_Config.ST_MUTINY then
		TimerMutiny(store, rec, turn)
	end
end

function EFV_Lifecycle.ProcessTimers(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and IsOnMapState(rec.state) then
			ForRecord("Timer", rec, TimerOne, store, rec, turn)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.ProcessVolunteerLapse(store, turn)
-- Pipeline step 4 (spec 11 row 2; D2; designer answers Q2, Q3).
-- Start: VOL records in DEPLOYED with lapsed == 0 and reason =
-- EFV_VolunteerLapseReason(sender, recipient) ~= nil -> preLapseState =
-- state, lapsed = 1, lapseReason = reason, lapseTurn = turn, state = GRACE,
-- graceTurnsLeft = GRACE_TURNS; queue EFV_NOTIF_VOLUNTEER_LAPSE (reason
-- "WAR") or EFV_NOTIF_ACCESS_LAPSE (reason "PARTNER") to the sender, N = 5.
-- The GRACE sequence then starts at turn + 1 (graceTurnsLeft already 5 now).
-- Implemented in Phase 3 with the Phase 2 machinery: the lapse fields, then
-- EFV_Lifecycle.EnterGrace(store, rec, turn, reason, true) (silent: the
-- lapse notification replaces GRACE at L); ProcessTimers then runs the same
-- GRACE / MUTINY / death sequence as for EXP, but with no automatic return:
-- on valid land it is paused (note 29). GRACE and MUTINY go to the sender
-- only, _VOLUNTEER text; see QueueAlert. From full HP and never paused, the
-- unit dies on the 5th mutiny turn (L+9).
-- Open-borders expiry (Session D 2.3): the deal scan predicts the expiry
-- turn (EFV_Rules DealItemEnded), so a FRIEND_OB lapse starts at
-- OnGameTurnStarted of that turn; the engine then moves the unit (same ID)
-- to neutral land outside the recipient's borders at the sender's turn
-- start. The record keeps following it by ID. Neutral land stays INVALID
-- return territory (designer ruling): the unit must walk into the
-- recipient's or the sender's territory (the lapse pauses there; recall it),
-- else mutiny until death. A lapse that starts on valid land starts paused
-- (rec.lapsePaused = 1, silently: the lapse notice explains it; note 29).
-- Cancel: VOL records with lapsed == 1 (GRACE / MUTINY) whose lapse reason
-- is now nil -> CancelVolunteerLapse (normally already done in step 3; this
-- pass covers records step 3 did not see). A lapse whose reason changed
-- (WAR <-> PARTNER) continues; only rec.lapseReason is updated.
-- Sender-recipient war closes the record before this step (step 0b, DV6).
-- Logs "[Lapse] ...".
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 4, 2.9; DECISIONS "Designer answers" Q2, Q3. APIs: via
-- EFV_VolunteerLapseReason.
-- ---------------------------------------------------------------------------
-- Lapse notification type per reason (sender only; the unit is the sender's).
local LAPSE_NOTIF = { WAR = "VOLUNTEER_LAPSE", PARTNER = "ACCESS_LAPSE" }

-- Starts the lapse of one DEPLOYED Volunteer record (reason "WAR" or
-- "PARTNER"). The unit must exist (a missing unit is left for step 0c).
local function StartLapse(store, rec, turn, reason)
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		EFV_Log(2, "Lapse", "id=%d reason=%s: unit missing; step 0c classifies it next turn", rec.id, reason)
		return
	end
	local valid, x, y, owner = UnitPosition(store, rec, pUnit)
	rec.preLapseState = rec.state
	rec.lapsed = 1
	rec.lapseReason = reason
	rec.lapseTurn = turn
	Touch(store)
	-- Phase 2 machinery: GRACE with graceTurnsLeft = GRACE_TURNS now; the
	-- countdown runs in ProcessTimers from turn + 1. Silent: the lapse
	-- notification replaces GRACE (N = 5) on the lapse turn.
	EFV_Lifecycle.EnterGrace(store, rec, turn, reason, true)
	local typeName = EFV_Config.NOTIF[LAPSE_NOTIF[reason]]
	EFV_Notify.Queue(rec.senderID, typeName, "LOC_" .. typeName,
		{ PlayerName(rec.recipientID), rec.graceTurnsLeft }, rec.lastX, rec.lastY, Extra(rec, LAPSE_NOTIF[reason]))
	-- Note 29: on valid land the new lapse starts paused. Silent: the lapse
	-- notice itself explains the pause and the recall (a FRIEND_OB lapse
	-- starts inside the friend's land and the engine expels the unit at the
	-- sender's turn start, which resumes it at that boundary).
	SetLapsePaused(store, rec, valid, pUnit, "LapseStart", true)
	EFV_Log(2, "Lapse", "start id=%d reason=%s basis=%s sender=%d recipient=%d at=%d,%d owner=%s valid=%s deployedTurn=%s",
		rec.id, reason, tostring(rec.accessBasis), rec.senderID, rec.recipientID, x, y, tostring(owner),
		tostring(valid), tostring(rec.deployedTurn))
end

local function LapseOne(store, rec, turn)
	if rec.forceType ~= EFV_Config.FT_VOL then
		return
	end
	local reason = EFV_VolunteerLapseReason(rec.senderID, rec.recipientID)
	if rec.state == EFV_Config.ST_DEPLOYED and rec.lapsed ~= 1 then
		if reason ~= nil then
			StartLapse(store, rec, turn, reason)
		end
		return
	end
	if rec.lapsed == 1 and (rec.state == EFV_Config.ST_GRACE or rec.state == EFV_Config.ST_MUTINY) then
		if reason == nil then
			-- Backup of the step 3 cancel (TryCancelLapse).
			EFV_Lifecycle.CancelVolunteerLapse(store, rec, turn)
		elseif reason ~= rec.lapseReason then
			-- Still lapsed for the other reason: keep the countdown, update
			-- the reason shown by the UI.
			EFV_Log(2, "Lapse", "id=%d reason %s -> %s (lapse continues)", rec.id, tostring(rec.lapseReason), reason)
			rec.lapseReason = reason
			Touch(store)
		end
	end
end

function EFV_Lifecycle.ProcessVolunteerLapse(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.forceType == EFV_Config.FT_VOL and IsOnMapState(rec.state) then
			ForRecord("Lapse", rec, LapseOne, store, rec, turn)
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.CancelVolunteerLapse(store, rec, turn)
-- (Added by WP1.0 for designer answer Q2; implemented in Phase 3.) Restores
-- state = rec.preLapseState ("DEPLOYED"), clears lapsed (0), lapseReason,
-- lapseTurn, preLapseState, lapsePaused, graceTurnsLeft, lastDamage (also
-- while paused, note 29). deployedTurn is NOT
-- changed; damage is not refunded (the unit heals normally afterwards).
-- Queues EFV_NOTIF_LAPSE_CANCELLED {1 recipient civ, 2 unit} to the sender
-- and to the recipient (skipped when not human). Logs "[Lapse] cancel ...".
-- Params:  store, rec record (VOL, lapsed == 1), turn number.
-- Returns: nil.
-- DECISIONS "Designer answers" Q2; orchestrator call (LAPSE_CANCELLED).
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.CancelVolunteerLapse(store, rec, turn)
	if rec == nil or rec.lapsed ~= 1 then
		return nil
	end
	local fromState, reason, since = rec.state, rec.lapseReason, rec.lapseTurn
	rec.state = rec.preLapseState or EFV_Config.ST_DEPLOYED
	rec.lapsed = 0
	rec.lapseReason = nil
	rec.lapseTurn = nil
	rec.preLapseState = nil
	rec.lapsePaused = nil
	rec.graceTurnsLeft = nil
	rec.lastDamage = nil
	Touch(store)
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit ~= nil then
		UnitPosition(store, rec, pUnit)
	end
	local typeName = EFV_Config.NOTIF.LAPSE_CANCELLED
	local args = { PlayerName(rec.recipientID), UnitName(rec) }
	EFV_Notify.Queue(rec.senderID, typeName, "LOC_" .. typeName, args, rec.lastX, rec.lastY, Extra(rec, "LAPSE_CANCELLED"))
	if rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, typeName, "LOC_" .. typeName, args, rec.lastX, rec.lastY, Extra(rec, "LAPSE_CANCELLED"))
	end
	EFV_Log(2, "Lapse", "cancel id=%d from=%s reason=%s since=%s -> %s deployedTurn=%s dmg=%s",
		rec.id, tostring(fromState), tostring(reason), tostring(since), tostring(rec.state),
		tostring(rec.deployedTurn), tostring(pUnit and pUnit:GetDamage()))
	return nil
end

-- ===========================================================================
-- Turn-boundary abstraction (replaces GameEvents.OnPlayerTurnEnded, which
-- never fires in a GS single-player game: 0 times in 28 rounds, Session C
-- T04; INTERFACES note 23).
-- ===========================================================================

-- True when any snapshot field differs from the record (formation excluded:
-- rec.formation is owned by OnMergeSurvivor, D3).
local SNAP_SCALARS = { "unitType", "veteranName", "damage", "experience", "xpNext", "level", "lastX", "lastY" }
local function SnapshotDiffers(rec, snap)
	for _, k in ipairs(SNAP_SCALARS) do
		if rec[k] ~= snap[k] then
			return true
		end
	end
	local a, b = rec.promotions or {}, snap.promotions or {}
	if #a ~= #b then
		return true
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return true
		end
	end
	return false
end

-- One record at a boundary: MUTINY heal floor (S8) BEFORE the snapshot, so
-- the stored damage is the floored value; S9 snapshot when anything changed
-- (or once per turn, to move snapTurn); merge survivor check (D3). A missing
-- unit is left for step 0c (classification needs the turn context).
-- Lapsed Volunteers (note 29): the pause is re-evaluated here (valid land ->
-- paused, EFV_NOTIF_LAPSE_PAUSED when it begins; elsewhere resumed). A
-- paused MUTINY record gets no floor, only the baseline refresh, so healing
-- taken on valid land is kept when the unit walks off it later; an unpaused
-- one is floored as usual. Known edge: a heal that lands between two
-- boundaries in which the unit also walked off valid land is judged by the
-- position at the later boundary (restored).
-- 0.5.2 (Session F items 1, 2): a dead unit object (GONE_DEAD) marks the
-- record killed; a missing unit without a combat marker is relinked here
-- when an upgrade or a levy gave it a new ID (TryRelink: provably the same
-- unit only), so the relink happens before the new unit can move away.
-- Anything else missing is left for step 0c.
local function BoundaryOne(store, rec, turn, hook)
	local pUnit, why = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		if why == "GONE_DEAD" then
			MarkKilled(store, rec, turn, hook)
			return
		end
		pUnit = TryRelink(store, rec, turn, hook)
		if pUnit == nil then
			return
		end
	end
	if IsLapsedVolunteer(rec) then
		local valid = UnitPosition(store, rec, pUnit)
		SetLapsePaused(store, rec, valid, pUnit, hook)
		if rec.state == EFV_Config.ST_MUTINY then
			if valid then
				RefreshFloorBaseline(store, rec, pUnit, hook)
			else
				FloorMutiny(store, rec, pUnit, hook)
			end
		end
	elseif rec.state == EFV_Config.ST_MUTINY then
		FloorMutiny(store, rec, pUnit, hook)
	end
	local snap = EFV_Units.Snapshot(pUnit, true)
	if snap == nil then
		EFV_Log(1, "Snapshot", "boundary snapshot failed id=%d hook=%s", rec.id, tostring(hook))
		return
	end
	if SnapshotDiffers(rec, snap) or rec.snapTurn ~= turn then
		-- rec.formation is owned by OnMergeSurvivor (D3): keep the recorded
		-- value so a merge is detected (here and in step 0c) until handled.
		local recordedFormation = rec.formation
		EFV_Units.ApplySnapshot(rec, snap, turn)
		rec.formation = recordedFormation
		Touch(store)
	end
	if FormationChanged(rec, pUnit) then
		CallMergeSurvivor(store, rec, pUnit)
	end
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.TurnBoundaryPass(store, turn, hook, pid, opts)   (WP2.1)
-- The "turn-end" work, run for ALL records at every turn boundary: for
-- DEPLOYED / GRACE / MUTINY records with a unit that passes the identity
-- check: MUTINY floor (S8), S9 snapshot (when changed), merge check (D3).
-- Then, unless opts.skipWar, HandleSenderRecipientWar for every non-RETURNING
-- record whose sender and recipient are at war (DV16: the revert happens at
-- the first boundary after the declaration, i.e. at the end of the
-- declarer's turn). Idempotent: a second call with no game change writes
-- nothing (snapshot-if-changed; floor restores only a real decrease; the war
-- handler converts the record so it is not seen again).
-- Params:  store; turn number; hook string (log: "PlayerTurnStarted",
--          "PlayerTurnStartComplete", "OnGameTurnEnded", "OnGameTurnStarted",
--          "OnPlayerTurnEnded"); pid player ID of the hook (log only; -1 for
--          the pipeline); opts nil or { skipWar = bool }.
-- Returns: nil.
-- PLAN 1.8 (A02 + PlayerTurnStarted), 2.9; SPIKES S8, S9; DV16. APIs: A25,
-- A36 (+ helpers).
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.TurnBoundaryPass(store, turn, hook, pid, opts)
	local n = 0
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and IsOnMapState(rec.state) then
			n = n + 1
			ForRecord("Snapshot", rec, BoundaryOne, store, rec, turn, hook)
		end
	end
	if not (opts ~= nil and opts.skipWar) then
		-- DV16: sender-recipient war handled at the first boundary after it.
		for _, id in ipairs(EFV_Records.IDs(store)) do
			local rec = EFV_Records.Get(store, id)
			if rec ~= nil and rec.state ~= EFV_Config.ST_RETURNING
				and AtWar(rec.senderID, rec.recipientID) then
				ForRecord("War", rec, EFV_Lifecycle.HandleSenderRecipientWar, store, rec, turn)
			end
		end
	end
	EFV_Log(3, "Hook", "boundary hook=%s pid=%s turn=%s onMap=%d", tostring(hook), tostring(pid), tostring(turn), n)
	return nil
end

-- Key of the last boundary handled in this Lua state (hook:turn:pid). A hook
-- that re-fires for the same player and turn (e.g. around a load) is skipped.
-- Session-local on purpose: the pass is idempotent, so the guard only saves
-- work and cannot make clients diverge.
local m_LastBoundaryKey = nil

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnTurnBoundary(hook, pid)   (WP2.1; engine-shaped)
-- Hook body for GameEvents.PlayerTurnStarted(pid),
-- GameEvents.PlayerTurnStartComplete(pid), GameEvents.OnGameTurnEnded (pid
-- -1; Session E) and the legacy GameEvents.OnPlayerTurnEnded: pcall; load; TurnBoundaryPass(store, turn,
-- hook, pid); commit (writes only when something changed); flush.
-- Params:  hook string; pid player ID of the hook.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.OnTurnBoundary(hook, pid)
	local turn = CurrentTurn()
	local key = tostring(hook) .. ":" .. tostring(turn) .. ":" .. tostring(pid)
	if key == m_LastBoundaryKey then
		EFV_Log(3, "Hook", "boundary repeat skipped %s", key)
		return nil
	end
	m_LastBoundaryKey = key
	local store = nil
	local ok, err = pcall(function()
		store = EFV_Records.Load()
		EFV_Lifecycle.TurnBoundaryPass(store, turn, hook, pid, nil)
	end)
	if not ok then
		EFV_Log(1, "Hook", "boundary %s(%s) failed: %s", tostring(hook), tostring(pid), tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", tostring(errC))
		end
	end
	local okF, errF = pcall(EFV_Notify.Flush)
	if not okF then
		EFV_Log(1, "Notify", "flush failed: %s", tostring(errF))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnPlayerTurnEnded(pid)
-- Legacy hook body of GameEvents.OnPlayerTurnEnded (A03). The event never
-- fires in a GS single-player game (Session C); the registration is kept as
-- a harmless extra boundary: it delegates to OnTurnBoundary, which is
-- idempotent, so a firing (e.g. in another game mode) cannot double-process.
-- Params:  pid player ID.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.OnPlayerTurnEnded(pid)
	return EFV_Lifecycle.OnTurnBoundary("OnPlayerTurnEnded", pid)
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
-- (added Phase 5, WP5.3; engine-shaped: owns pcall / load / commit / flush;
-- 0.5.2: Session F T20 / S9 and MUST-FIX 1)
-- Last-moment S9 point (spec 11 row 4): GameEvents.CityConquered is
-- synchronous and fires before Events.PlayerDestroyed / PlayerDefeat. Session
-- F T20 CONFIRMED: for the old owner's LAST city, IsAlive() is already false
-- inside this event and every unit still exists (they are removed after
-- PlayerDestroyed); a unit killed in that combat is ALSO still found by
-- FindID (damage at the maximum). For every on-map record whose unit the old
-- owner holds:
--   * unit dead (GONE_DEAD) or missing with a combat marker of this turn ->
--     KILLED at once (UNIT_LOST to the sender, record closed): never
--     snapshotted, never returned (the resurrection case of MUST-FIX 1);
--   * unit alive -> the boundary work (identity-checked snapshot, mutiny
--     floor, merge check); then, when the old owner is the record's
--     recipient, it is no longer alive and the record is EXP / CS, the
--     return starts right here from this fresh state (StartReturn,
--     "RECIPIENT_GONE"); step 0b of the next turn start stays the safety net;
--   * missing without a marker -> left for step 0b / 0c.
-- No war check here (the regular boundaries do it).
-- Params:  capturerID, oldOwnerID, cityID, x, y (event arguments).
-- Returns: nil.
-- ---------------------------------------------------------------------------
local function ConqueredOne(store, rec, turn, oldOwnerID, counts)
	counts.n = counts.n + 1
	local pUnit, why = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		if why == "GONE_DEAD" or (rec.lastCombatTurn ~= nil and rec.lastCombatTurn >= turn) then
			counts.killed = counts.killed + 1
			MarkKilled(store, rec, turn, "CityConquered")
			CloseLost(store, rec, "KILLED", "CityConquered")
		end
		return
	end
	counts.found = counts.found + 1
	BoundaryOne(store, rec, turn, "CityConquered")
	if EFV_Records.Get(store, rec.id) == nil or not IsOnMapState(rec.state) then
		return
	end
	if rec.recipientID == oldOwnerID and rec.forceType ~= EFV_Config.FT_VOL and not IsAliveID(oldOwnerID) then
		local pNow = EFV_Units.GetForRecord(rec)
		EFV_Log(2, "Reconcile", "recipient gone at CityConquered id=%d recipient=%s state=%s unit=%s -> return",
			rec.id, tostring(oldOwnerID), tostring(rec.state), (pNow ~= nil) and "found" or "snapshot")
		counts.returned = counts.returned + 1
		EFV_Transit.StartReturn(store, rec, pNow, "RECIPIENT_GONE", turn)
	end
end

function EFV_Lifecycle.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
	local store = nil
	local ok, err = pcall(function()
		store = EFV_Records.Load()
		local turn = CurrentTurn()
		local counts = { n = 0, found = 0, killed = 0, returned = 0 }
		for _, id in ipairs(EFV_Records.IDs(store)) do
			local rec = EFV_Records.Get(store, id)
			if rec ~= nil and IsOnMapState(rec.state) and rec.onMapPlayerID == oldOwnerID then
				ForRecord("Snapshot", rec, ConqueredOne, store, rec, turn, oldOwnerID, counts)
			end
		end
		EFV_Log(counts.n > 0 and 2 or 3, "Snapshot",
			"CityConquered capturer=%s oldOwner=%s city=%s at=%s,%s alive=%s records=%d found=%d killed=%d returned=%d",
			tostring(capturerID), tostring(oldOwnerID), tostring(cityID), tostring(x), tostring(y),
			tostring(IsAliveID(oldOwnerID)), counts.n, counts.found, counts.killed, counts.returned)
	end)
	if not ok then
		EFV_Log(1, "Snapshot", "OnCityConquered failed: %s", tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", tostring(errC))
		end
	end
	local okF, errF = pcall(EFV_Notify.Flush)
	if not okF then
		EFV_Log(1, "Notify", "flush failed: %s", tostring(errF))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnCombat(aP, aU, dP, dU)
-- Hook body of GameEvents.OnCombatOccurred (owns load / commit, pcall): for
-- records whose (onMapPlayerID, onMapUnitID) matches either side,
-- lastCombatTurn = current turn. Logs "[Combat] ...".
-- 0.5.2 (Session F MUST-FIX 4, step 1): for a matching MUTINY record whose
-- unit is alive, the heal-floor baseline is raised to the unit's current
-- damage when that is higher (rec.lastDamage = d, "[Floor] raise ...
-- hook=OnCombat"). Read-only on the unit: never SetDamage inside combat
-- resolution. Why: the Barbarians (the last player) and a promotion heal
-- (EXPERIENCE_PROMOTE_HEALED 50) or a heal on kill share one interval
-- between two boundaries with a heal, and the floor there sees only the net
-- change; with the baseline raised at the combat, the heal is restored to a
-- value that includes the combat damage. If the engine applies the damage
-- only after GameEvents.OnCombatOccurred (unmeasured: T31, EFV/
-- TESTING_FINAL_DRAFT_T31.md) the raise is a no-op and the documented
-- residual stays: such a combat can be offset by at most one heal.
-- Params:  aP attacker player ID, aU attacker unit ID, dP defender player ID,
--          dU defender unit ID.
-- Returns: nil.
-- Implemented early (WP1.4) so RefreshTrackedUnits can tell KILLED from
-- DISBANDED in Phase 1. Commits only when a record matched.
-- PLAN 1.8, 2.9. APIs: A35, A04, A25.
-- ---------------------------------------------------------------------------
local function RaiseFloorOnCombat(rec, turn)
	if rec.state ~= EFV_Config.ST_MUTINY then
		return
	end
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		return
	end
	local okD, d = pcall(function() return pUnit:GetDamage() end)
	local last = tonumber(rec.lastDamage)
	if okD and type(d) == "number" and last ~= nil and d > last then
		EFV_Log(2, "Floor", "raise id=%d hook=OnCombat from=%d to=%d (combat)", rec.id, last, d)
		rec.lastDamage = d
	end
end

function EFV_Lifecycle.OnCombat(aP, aU, dP, dU)
	local ok, err = pcall(function()
		local store = EFV_Records.Load()
		local turn = CurrentTurn()
		local changed = false
		for _, id in ipairs(EFV_Records.IDs(store)) do
			local rec = EFV_Records.Get(store, id)
			if rec ~= nil and IsOnMapState(rec.state) and rec.onMapUnitID ~= nil then
				if (rec.onMapPlayerID == aP and rec.onMapUnitID == aU)
					or (rec.onMapPlayerID == dP and rec.onMapUnitID == dU) then
					rec.lastCombatTurn = turn
					changed = true
					EFV_Log(2, "Combat", "id=%d unit=%d owner=%d", rec.id, rec.onMapUnitID, rec.onMapPlayerID)
					ForRecord("Floor", rec, RaiseFloorOnCombat, rec, turn)
				end
			end
		end
		if changed then
			EFV_Records.Touch(store)
			EFV_Records.Commit(store)
		end
	end)
	if not ok then
		EFV_Log(1, "Combat", "OnCombat failed: %s", tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnRequestRecall(playerID, params)
-- Handler of GameEvents.EFV_Recall (spec 9.2; PLAN 1.5 handler contract):
-- pcall; reject non-human requesters; load; rec = EFV_Records.FindByUnit(
-- store, playerID, params.unitID); require forceType VOLUNTEER, senderID ==
-- playerID, state DEPLOYED / GRACE / MUTINY, EFV_RecallReasons empty (no HP
-- requirement, designer answer; minimum 10 turns waived while lapsed; valid
-- territory = the sender's or the recipient's tiles only, never neutral
-- land, also after an engine expulsion); then StartReturn(.., "RECALL",
-- turn). Recall is the ONLY way home for a lapsed Volunteer (note 29: its
-- lapse is paused on valid land; a MUTINY unit there keeps its engine
-- healing, one elsewhere is floored). On failure EFV_NOTIF_REQUEST_FAILED
-- with the first reason (RECALL_MIN_TURNS names the turns left). Commit,
-- flush. Implemented in Phase 3 (WP3.2). Logs "[Recall] ...".
-- Params:  playerID requesting player (authoritative), params { unitID }.
-- Returns: nil.
-- PLAN 1.5, 2.9; spec 9.2. APIs: via helpers.
-- ---------------------------------------------------------------------------
-- Localized reason text for a rejected recall (LOC_EFV_REASON_<CODE>);
-- RECALL_MIN_TURNS {1_Num} = turns still to serve.
local function RecallReasonText(code, rec, turn)
	local key = "LOC_EFV_REASON_" .. tostring(code)
	local ok, s
	if code == "RECALL_MIN_TURNS" and rec ~= nil then
		local left = EFV_Config.VOLUNTEER_MIN_DEPLOYMENT - (turn - (rec.deployedTurn or turn))
		ok, s = pcall(Locale.Lookup, key, math.max(1, left))
	else
		ok, s = pcall(Locale.Lookup, key)
	end
	if ok and type(s) == "string" then
		return s
	end
	return tostring(code)
end

local function RejectRecall(playerID, codes, rec, turn, unitID)
	EFV_Log(2, "Recall", "rejected player=%s unit=%s id=%s reasons=%s", tostring(playerID), tostring(unitID),
		tostring(rec and rec.id), table.concat(codes, ","))
	EFV_Notify.Queue(playerID, EFV_Config.NOTIF.REQUEST_FAILED, "LOC_" .. EFV_Config.NOTIF.REQUEST_FAILED,
		{ RecallReasonText(codes[1], rec, turn) }, rec and rec.lastX, rec and rec.lastY, { kind = "REQUEST_FAILED" })
end

local function RecallBody(playerID, params, store)
	local turn = CurrentTurn()
	local unitID = tonumber(params.unitID)
	if unitID == nil then
		RejectRecall(playerID, { "REQ_STALE" }, nil, turn, params.unitID)
		return
	end
	if not (EFV_Config.FLAG_RELEASED ~= nil and EFV_Config.FLAG_RELEASED.RECALL == true) then
		RejectRecall(playerID, { "NOT_IMPLEMENTED" }, nil, turn, unitID)
		return
	end
	-- Volunteers are on the map as the sender's units, so (playerID, unitID)
	-- finds only the requester's own on-map records.
	local rec = EFV_Records.FindByUnit(store, playerID, unitID)
	if rec == nil or rec.forceType ~= EFV_Config.FT_VOL or rec.senderID ~= playerID then
		local code = "RECALL_NOT_VOLUNTEER"
		if rec == nil and EFV_Units.Get(playerID, unitID) == nil then
			code = "REQ_STALE"
		end
		RejectRecall(playerID, { code }, rec, turn, unitID)
		return
	end
	if not IsOnMapState(rec.state) then
		RejectRecall(playerID, { "REQ_STALE" }, rec, turn, unitID)
		return
	end
	local pUnit = EFV_Units.GetForRecord(rec)
	if pUnit == nil then
		RejectRecall(playerID, { "REQ_STALE" }, rec, turn, unitID)
		return
	end
	local valid = UnitPosition(store, rec, pUnit)
	if rec.state == EFV_Config.ST_MUTINY then
		if valid then
			-- Note 29: on valid land the mutiny is paused and the unit heals by
			-- engine rules; the returned unit keeps its current damage.
			RefreshFloorBaseline(store, rec, pUnit, "Recall")
		else
			-- Units in active mutiny cannot heal: a mid-turn heal is undone
			-- (the recall is refused below anyway: RECALL_TERRITORY).
			FloorMutiny(store, rec, pUnit, "Recall")
		end
	end
	local codes = EFV_RecallReasons(rec, pUnit, turn)
	if #codes > 0 then
		RejectRecall(playerID, codes, rec, turn, unitID)
		return
	end
	local elapsed = turn - (rec.deployedTurn or turn)
	EFV_Log(2, "Recall", "ok id=%d player=%d unit=%d state=%s lapsed=%s elapsed=%d at=%s,%s dmg=%s",
		rec.id, playerID, unitID, tostring(rec.state), tostring(rec.lapsed), elapsed,
		tostring(rec.lastX), tostring(rec.lastY), tostring(pUnit:GetDamage()))
	EFV_Transit.StartReturn(store, rec, pUnit, "RECALL", turn)
end

function EFV_Lifecycle.OnRequestRecall(playerID, params)
	local store = nil
	local ok, err = pcall(function()
		local pPlayer = Players[playerID]
		if pPlayer == nil or not pPlayer:IsHuman() then
			EFV_Log(2, "Recall", "rejected player=%s reasons=NOT_HUMAN_MAJOR", tostring(playerID))
			return
		end
		if type(params) ~= "table" then
			EFV_Log(1, "Recall", "rejected player=%s: params missing", tostring(playerID))
			return
		end
		store = EFV_Records.Load()
		RecallBody(playerID, params, store)
	end)
	if not ok then
		EFV_Log(1, "Recall", "handler failed player=%s: %s", tostring(playerID), tostring(err))
	end
	if store ~= nil then
		local okC, errC = pcall(EFV_Records.Commit, store)
		if not okC then
			EFV_Log(1, "Store", "commit failed: %s", tostring(errC))
		end
	end
	local okF, errF = pcall(EFV_Notify.Flush)
	if not okF then
		EFV_Log(1, "Notify", "flush failed: %s", tostring(errF))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.OnPlayerDefeatHint(pid)
-- Async Events.PlayerDefeat hint (FLAG_DEFEAT_HINT; DV13). Session D 4:
-- the event arrives AFTER the eliminated player's units are gone
-- (Events.PlayerDestroyed, then PlayerDefeat; IsAlive() already false), so
-- the old plan "re-snapshot records whose unit is still found" is dropped
-- (FindID can never find them, and after slot reuse it is unsafe). The hint
-- only logs (Phase 5, WP5.3: it reads the store and writes nothing, so no
-- async write remains); step 0b of the next OnGameTurnStarted does the
-- IsAlive() check. The authoritative S9 snapshots are the boundary passes
-- (OnGameTurnStarted step 0d, every PlayerTurnStarted / PlayerTurnStartComplete,
-- OnGameTurnEnded) plus the synchronous GameEvents.CityConquered pass
-- (OnCityConquered). No RNG, no unit or gold changes, no notifications.
-- Logs "[Defeat] ...".
-- Params:  pid defeated player ID.
-- Returns: nil.
-- PLAN 1.8, 2.9; SPIKES S9 step 2; DV13. APIs: A55 (+ A06 via Commit).
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.OnPlayerDefeatHint(pid)
	-- WP5.3: log only. The store is read, never written (no async writes:
	-- this is a per-client presentation event, DV13 reduced to a log line).
	-- Step 0b of the next OnGameTurnStarted reads IsAlive() and returns /
	-- deletes the affected records from the last boundary snapshot.
	local ok, err = pcall(function()
		local store = EFV_Records.Load()
		local asSender, asRecipient, onMap = 0, 0, 0
		for _, id in ipairs(EFV_Records.IDs(store)) do
			local rec = EFV_Records.Get(store, id)
			if rec ~= nil then
				if rec.senderID == pid then
					asSender = asSender + 1
				end
				if rec.recipientID == pid then
					asRecipient = asRecipient + 1
				end
				if rec.onMapPlayerID == pid and IsOnMapState(rec.state) then
					onMap = onMap + 1
				end
			end
		end
		EFV_Log(2, "Defeat", "hint pid=%s alive=%s records: sender=%d recipient=%d onMap=%d (handled by step 0b at the next turn start)",
			tostring(pid), tostring(IsAliveID(pid)), asSender, asRecipient, onMap)
	end)
	if not ok then
		EFV_Log(1, "Defeat", "hint failed pid=%s: %s", tostring(pid), tostring(err))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.RelinkUpgraded(store, rec, turn, hook) -> pUnit
-- (Phase 5, WP5.2; rewritten 0.5.2, Session F items 2 and 3; INTERFACES
-- note 30). Called by TryRelink (every turn boundary and step 0c) when
-- FLAG_UPGRADE_RELINK is on (default since 0.5.2). Session F T30: an upgrade
-- removes the unit and creates a new one with a NEW ID on the SAME plot, of
-- the civilization's unique replacement type when it has one (Warrior 0/983047
-- -> UNIT_MACEDONIAN_HYPASPIST 0/1048584 at 15,33); the old object stays
-- findable for the rest of the owner's turn (then GONE, or matched by the
-- identity check until it disappears). Relink rule (provably the same unit):
-- a live unit (EFV_UnitGoneReason nil) of rec.onMapPlayerID (the owner does
-- not change) standing exactly on rec.lastX / lastY (the last snapshot),
-- whose type is in EFV_UpgradeTargets(rec.unitType, owner) (UnitUpgrades
-- chain plus the owner's unique replacements; never the same type, so an
-- unrelated twin is not grabbed), untracked by any record, holding every
-- promotion of the snapshot (an upgrade keeps them); exactly one such unit,
-- else no relink ("[Upgrade] ambiguous" when several). Relinks
-- onMapUnitID / unitType / lastX / lastY. Logs "[Upgrade] relink ...".
-- Params:  store, rec record, turn number, hook string (log).
-- Returns: the relinked unit object or nil.
-- PLAN 2.9; T30. APIs: A15, A51 (+ EFV_UpgradeTargets).
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.RelinkUpgraded(store, rec, turn, hook)
	local pid = rec.onMapPlayerID
	if turn == nil then
		turn = CurrentTurn()
	end
	if pid == nil or not EFV_Units.ValidPosition(rec.lastX, rec.lastY) or not IsAliveID(pid) then
		return nil
	end
	local targets = EFV_UpgradeTargets(rec.unitType, pid)
	if next(targets) == nil then
		return nil
	end
	local cands = {}
	for _, pU in ipairs(SortedUnits(pid)) do
		local okT, t, uid, ux, uy = pcall(function()
			local row = GameInfo.Units[pU:GetType()]
			return row and row.UnitType or nil, pU:GetID(), pU:GetX(), pU:GetY()
		end)
		if okT and t ~= nil and targets[t] and ux == rec.lastX and uy == rec.lastY
			and uid ~= rec.onMapUnitID
			and EFV_UnitGoneReason(pU, pid, uid) == nil
			and EFV_Records.FindByUnit(store, pid, uid) == nil
			and HasRecordPromotions(rec, pU) then
			cands[#cands + 1] = { u = pU, o = pid, d = 0, exact = false, id = uid, t = t }
		end
	end
	if #cands ~= 1 then
		if #cands > 1 then
			LogAmbiguous("Upgrade", rec, turn, #cands, "hook=" .. tostring(hook))
		end
		return nil
	end
	local c = cands[1]
	EFV_Log(2, "Upgrade", "relink id=%d owner=%d unit=%s->%d type=%s->%s at=%d,%d dist=0 hook=%s",
		rec.id, pid, tostring(rec.onMapUnitID), c.id, tostring(rec.unitType), c.t,
		rec.lastX, rec.lastY, tostring(hook))
	rec.onMapUnitID = c.id
	rec.unitType = c.t
	Touch(store)
	return c.u
end

-- ---------------------------------------------------------------------------
-- EFV_Lifecycle.VerifyCreatedThisTurn(store, turn)
-- Pipeline step 6 (log only): every record with deployedTurn == turn has its
-- on-map unit (EFV_Units.Get); logs "[Verify] ..." errors otherwise.
-- Params:  store, turn number.
-- Returns: nil.
-- PLAN 1.8 step 6, 2.9. APIs: A17.
-- ---------------------------------------------------------------------------
function EFV_Lifecycle.VerifyCreatedThisTurn(store, turn)
	for _, id in ipairs(EFV_Records.IDs(store)) do
		local rec = EFV_Records.Get(store, id)
		if rec ~= nil and rec.state == EFV_Config.ST_DEPLOYED and rec.deployedTurn == turn then
			if EFV_Units.GetForRecord(rec) == nil then
				EFV_Log(1, "Verify", "missing id=%d owner=%s unit=%s", rec.id, tostring(rec.onMapPlayerID), tostring(rec.onMapUnitID))
			else
				EFV_Log(3, "Verify", "ok id=%d unit=%s", rec.id, tostring(rec.onMapUnitID))
			end
		end
	end
	return nil
end

EFV_Lifecycle.LOADED = 1
