-- ===========================================================================
-- EFV_Gameplay.lua
-- Module:   EFV_Gameplay (global table) - gameplay entry point
-- Context:  gameplay (modinfo AddGameplayScripts EFV_Gameplay). Runs on every
--           new game and on every load. NOT included by any other file, so
--           it has no load-once guard.
-- Owner:    WP1.4. WP1.0 wired the includes, the hook registration and the
--           turn pipeline skeleton; WP1.4 reviewed it against PLAN 1.8 and
--           INTERFACES 7 (order G, 0a, 0b, 0c, 1, 2, 3, 4, 6, 7). Phase 2+
--           work lives in the module functions, not here.
--
-- Responsibility (PLAN 1.7, 1.8, 2.11):
--   1. include all modules in dependency order (A57);
--   2. register every handler at file load, never conditionally, one log
--      line per registration (misspelt GameEvents fail silently, SPIKES S2);
--   3. EFV_Records.Init() (first-init guard / schema migrations);
--   4. RunTurnStart(turn): the turn pipeline with the EFV_LastTurn
--      idempotency guard (DV9), one pcall per step;
--   4b. the turn-boundary abstraction (INTERFACES note 23): the "turn-end"
--      work (S9 snapshots, S8 mutiny floor, merge check, DV16 war check) runs
--      at EVERY GameEvents.PlayerTurnStarted(p) and PlayerTurnStartComplete(p),
--      at GameEvents.OnGameTurnEnded and in pipeline step 0d, because
--      GameEvents.OnPlayerTurnEnded never fires in a GS single-player game
--      (Session C). Confirmed round order (Session E T26): OnGameTurnStarted(N)
--      -> per player PTS > PTSC > acts (human first, ..., Barbarians 63 last)
--      -> ENGINE HEAL (once per round) -> OnGameTurnEnded(N) -> next round.
--      So OnGameTurnEnded is the first hook after the heal (mutiny floor);
--      the per-player passes never see the round heal, only mid-turn changes.
--      OnPlayerTurnEnded stays registered as a harmless extra boundary (the
--      pass is idempotent);
--   4c. 0.7 (INTERFACES note 33): veteran route B. EFV_Veteran.OnBoundary
--      runs after the boundary pass at PlayerTurnStarted,
--      PlayerTurnStartComplete and OnGameTurnEnded; pipeline step 0e syncs
--      the jobs (no deadline since 0.7.4); GameEvents.EFV_VetStep ->
--      EFV_Veteran.OnRequestStep;
--   5. thin hook wrappers: pcall + log + delegate to the module function.
--      Module functions with engine-shaped signatures (no store parameter)
--      own their load / commit / flush; wrappers that pass a store
--      (PlayerTurnStartComplete) load and commit themselves.
--
-- Rules (PLAN 1.2, 1.6): no Game.GetLocalPlayer, no math.random, no pairs()
-- over records; RNG only inside GameEvents handlers; the Events.PlayerDefeat
-- hint is the only async handler (DV13).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Includes (PLAN 2.11 order)
-- ---------------------------------------------------------------------------
include("EFV_Config")
include("EFV_Util")
include("EFV_Rules")
include("EFV_Records")
include("EFV_Notify")
include("EFV_Units")
include("EFV_Veteran")   -- 0.7 (note 33); already included by EFV_Units
include("EFV_Spawn")
include("EFV_Transit")
include("EFV_Lifecycle")
include("EFV_Entrust")

EFV_Gameplay = {}

EFV_Log(2, "Init", "EFV_Gameplay loading version=%s", tostring(EFV_Config.VERSION))

-- ---------------------------------------------------------------------------
-- Helpers (file-local)
-- ---------------------------------------------------------------------------

-- pcall wrapper: logs "<label> failed: <error>" at level 1 under tag.
-- Returns true when fn ran without error.
local function SafeCall(tag, label, fn, ...)
	if fn == nil then
		EFV_Log(1, tag, "%s: function missing", tostring(label))
		return false
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		EFV_Log(1, tag, "%s failed: %s", tostring(label), tostring(err))
	end
	return ok
end

-- One pipeline step (PLAN 1.8): a failing step logs and the pipeline goes on.
local function RunStep(stepID, fn, ...)
	return SafeCall("Pipeline", "step " .. stepID, fn, ...)
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.RunTurnStart(turn)
-- The turn pipeline (PLAN 1.8), called from GameEvents.OnGameTurnStarted.
--   G   guard: turn <= store.lastTurn -> log "[Pipeline] skip" and return (DV9)
--   0a  EFV_Entrust.CleanupSnapshots
--   0b  EFV_Lifecycle.ReconcilePlayers (also the outbound transit check:
--       cancel, R2 orphans; designer rulings 2026-09-30)
--   0c  EFV_Lifecycle.RefreshTrackedUnits
--   0d  EFV_Lifecycle.TurnBoundaryPass (safety net after OnGameTurnEnded,
--       which normally already floored the round heal: S9 snapshot, S8
--       floor, merge check; war check is 0b's)
--   0e  EFV_Veteran.ProcessJobs(store, turn, "OnGameTurnStarted")
--       (0.7, note 33: veteran route B sync; no deadline since 0.7.4)
--   1   EFV_Transit.ChargeTransitMaintenance
--   2   EFV_Transit.ProcessArrivals
--   3   EFV_Lifecycle.ProcessTimers (also cancels reversible Volunteer lapses)
--   4   EFV_Lifecycle.ProcessVolunteerLapse
--   5   none (Volunteer heal top-up dropped, D7 revision; contingency PLAN 7.1)
--   6   EFV_Lifecycle.VerifyCreatedThisTurn
--   7   store.lastTurn = turn; EFV_Records.Commit; EFV_Notify.Flush
-- The store is committed even when a step failed (PLAN 1.6). Step 7 uses
-- commit-then-flush, the same order as every other handler (PLAN 1.5).
-- Params:  turn number (Game.GetCurrentGameTurn()).
-- Returns: nil.
-- PLAN 1.8, 2.11; DV2, DV9. APIs: via modules.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.RunTurnStart(turn)
	local store = EFV_Records.Load()
	if store == nil then
		EFV_Log(1, "Pipeline", "store unavailable turn=%s", tostring(turn))
		return nil
	end
	if store.lastTurn ~= nil and turn <= store.lastTurn then
		EFV_Log(2, "Pipeline", "skip turn=%s lastTurn=%s", tostring(turn), tostring(store.lastTurn))
		return nil
	end
	EFV_Log(2, "Pipeline", "start turn=%s", tostring(turn))

	RunStep("0a", EFV_Entrust.CleanupSnapshots, store, turn)
	RunStep("0b", EFV_Lifecycle.ReconcilePlayers, store, turn)
	RunStep("0c", EFV_Lifecycle.RefreshTrackedUnits, store, turn)
	RunStep("0d", EFV_Lifecycle.TurnBoundaryPass, store, turn, "OnGameTurnStarted", -1, { skipWar = true })
	RunStep("0e", EFV_Veteran.ProcessJobs, store, turn, "OnGameTurnStarted")
	RunStep("1", EFV_Transit.ChargeTransitMaintenance, store, turn)
	RunStep("2", EFV_Transit.ProcessArrivals, store, turn)
	RunStep("3", EFV_Lifecycle.ProcessTimers, store, turn)
	RunStep("4", EFV_Lifecycle.ProcessVolunteerLapse, store, turn)
	-- Step 5 intentionally empty (D7 revision).
	RunStep("6", EFV_Lifecycle.VerifyCreatedThisTurn, store, turn)

	store.lastTurn = turn
	if store.dirty == nil then
		store.dirty = {}
	end
	store.dirty[EFV_Config.PROP.LAST_TURN] = true
	RunStep("7-commit", EFV_Records.Commit, store)
	RunStep("7-flush", EFV_Notify.Flush)

	EFV_Log(2, "Pipeline", "done turn=%s", tostring(turn))
	return nil
end

-- ---------------------------------------------------------------------------
-- Hook wrappers (PLAN 1.8, 2.11). Each: pcall + log + delegate.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnGameTurnStarted(eventTurn)
-- GameEvents.OnGameTurnStarted (A01): once per round, after the engine's
-- end-of-round heal (S8) and after OnGameTurnEnded of the previous round. Uses Game.GetCurrentGameTurn() as the turn
-- (SPIKES 3 row 20); logs a mismatch with the event argument at level 3.
-- Params:  eventTurn number (event argument).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnGameTurnStarted(eventTurn)
	local turn = Game.GetCurrentGameTurn()
	if eventTurn ~= nil and eventTurn ~= turn then
		EFV_Log(3, "Hook", "OnGameTurnStarted eventTurn=%s currentTurn=%s", tostring(eventTurn), tostring(turn))
	end
	SafeCall("Pipeline", "RunTurnStart", EFV_Gameplay.RunTurnStart, turn)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnPlayerTurnStarted(pid)   (added WP2.1, Session C item 1)
-- GameEvents.PlayerTurnStarted (fires in G for every player, Session C T04;
-- AlexanderScenario.lua:247): a turn boundary. Every player whose turn came
-- before pid in this round has ended its turn, so the turn-end work runs
-- here: EFV_Lifecycle.OnTurnBoundary("PlayerTurnStarted", pid). The
-- transit check of pid's own outbound records runs inside that boundary
-- pass (EFV_Transit.CheckTransits, transit cancel 2026-09-30).
-- Params:  pid player ID.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnPlayerTurnStarted(pid)
	SafeCall("Hook", "PlayerTurnStarted", EFV_Lifecycle.OnTurnBoundary, "PlayerTurnStarted", pid)
	SafeCall("Vet", "OnBoundary", EFV_Veteran.OnBoundary, "PlayerTurnStarted", pid)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnPlayerTurnStartComplete(pid)
-- GameEvents.PlayerTurnStartComplete (A02): moves are restored now, so
-- zero the moves of units created for pid (S10, T06): loads the store,
-- calls EFV_Units.ExhaustPending(store, pid), commits. Then a turn boundary
-- (EFV_Lifecycle.OnTurnBoundary("PlayerTurnStartComplete", pid)): S9
-- snapshot of units right before pid acts, DV16 war check, [Floor] raise on
-- combat damage dealt by earlier players, [Floor] restore of mid-turn heals
-- (promotion heal, heal on kill, medic), the position after an open-borders
-- expulsion (between pid's PTS and PTSC, Session D). The engine's round heal
-- never falls inside a PTS -> PTSC window (Session E T26): OnGameTurnEnded
-- catches it.
-- Params:  pid player ID.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnPlayerTurnStartComplete(pid)
	SafeCall("Exhaust", "ExhaustPending", function()
		local store = EFV_Records.Load()
		EFV_Units.ExhaustPending(store, pid)
		EFV_Records.Commit(store)
	end)
	SafeCall("Hook", "PlayerTurnStartComplete", EFV_Lifecycle.OnTurnBoundary, "PlayerTurnStartComplete", pid)
	SafeCall("Vet", "OnBoundary", EFV_Veteran.OnBoundary, "PlayerTurnStartComplete", pid)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnGameTurnEnded(eventTurn)   (added Session E integration)
-- GameEvents.OnGameTurnEnded: fires exactly once per round, synchronously,
-- immediately AFTER the engine's once-per-round heal (after the last
-- player's PlayerTurnStartComplete, player 63 Barbarians) and before the next
-- OnGameTurnStarted; Game.GetCurrentGameTurn() is still the ending turn
-- (Session E T26: 186/186 rounds, 29/29 heals). A turn boundary:
-- EFV_Lifecycle.OnTurnBoundary("OnGameTurnEnded", -1), so the S8 mutiny
-- floor resets the round heal before the round is over (the heal animation
-- still plays: there is no pre-heal hook). Step 0d and the pipeline mutiny
-- step stay as the safety net; they then normally find nothing to restore.
-- The +20 mutiny damage and removals stay at OnGameTurnStarted (spec 9.1).
-- Params:  eventTurn number (the ending turn; logged on mismatch only).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnGameTurnEnded(eventTurn)
	local turn = Game.GetCurrentGameTurn()
	if eventTurn ~= nil and eventTurn ~= turn then
		EFV_Log(3, "Hook", "OnGameTurnEnded eventTurn=%s currentTurn=%s", tostring(eventTurn), tostring(turn))
	end
	SafeCall("Hook", "OnGameTurnEnded", EFV_Lifecycle.OnTurnBoundary, "OnGameTurnEnded", -1)
	SafeCall("Vet", "OnBoundary", EFV_Veteran.OnBoundary, "OnGameTurnEnded", -1)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnPlayerTurnEnded(pid)
-- GameEvents.OnPlayerTurnEnded (A03). NEVER fires in a GS single-player game
-- (Session C: 0 times in 28 rounds). Kept registered as a harmless extra
-- boundary -> EFV_Lifecycle.OnPlayerTurnEnded(pid) -> OnTurnBoundary, which
-- is idempotent (cannot double-process).
-- Params:  pid player ID.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnPlayerTurnEnded(pid)
	SafeCall("Hook", "OnPlayerTurnEnded", EFV_Lifecycle.OnPlayerTurnEnded, pid)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnCombatOccurred(aP, aU, dP, dU, aD, dD)
-- GameEvents.OnCombatOccurred (A35; 6 args, SPIKES 1) ->
-- EFV_Lifecycle.OnCombat(aP, aU, dP, dU). District IDs are ignored.
-- Params:  attacker player/unit, defender player/unit, attacker/defender
--          district IDs.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnCombatOccurred(aP, aU, dP, dU, aD, dD)
	SafeCall("Hook", "OnCombat", EFV_Lifecycle.OnCombat, aP, aU, dP, dU)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
-- GameEvents.CityConquered (A47) -> EFV_Lifecycle.OnCityConquered (Phase 5:
-- last-moment S9 snapshot of the old owner's tracked units, in case this
-- was its last city; marks outbound destinations for the transit cancel)
-- -> EFV_Entrust.OnCityConquered (Entrust snapshot).
-- Params:  capturerID, oldOwnerID, cityID, x, y.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnCityConquered(capturerID, oldOwnerID, cityID, x, y)
	SafeCall("Snapshot", "OnCityConquered", EFV_Lifecycle.OnCityConquered, capturerID, oldOwnerID, cityID, x, y)
	SafeCall("Entrust", "OnCityConquered", EFV_Entrust.OnCityConquered, capturerID, oldOwnerID, cityID, x, y)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnRequestSend(playerID, params)
-- GameEvents.EFV_Send (A05) -> EFV_Transit.OnRequestSend.
-- Params:  playerID requesting player (authoritative), params (PLAN 1.5).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnRequestSend(playerID, params)
	EFV_Log(2, "Send", "request from player=%s", tostring(playerID))
	SafeCall("Send", "OnRequestSend", EFV_Transit.OnRequestSend, playerID, params)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnRequestRecall(playerID, params)
-- GameEvents.EFV_Recall (A05) -> EFV_Lifecycle.OnRequestRecall.
-- Params:  playerID requesting player (authoritative), params (PLAN 1.5).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnRequestRecall(playerID, params)
	EFV_Log(2, "Recall", "request from player=%s", tostring(playerID))
	SafeCall("Recall", "OnRequestRecall", EFV_Lifecycle.OnRequestRecall, playerID, params)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnRequestEntrust(playerID, params)
-- GameEvents.EFV_Entrust (A05) -> EFV_Entrust.OnRequestEntrust.
-- Params:  playerID requesting player (authoritative), params (PLAN 1.5).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnRequestEntrust(playerID, params)
	EFV_Log(2, "Entrust", "request from player=%s", tostring(playerID))
	SafeCall("Entrust", "OnRequestEntrust", EFV_Entrust.OnRequestEntrust, playerID, params)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnRequestVetStep(playerID, params)   (0.7, note 33)
-- GameEvents.EFV_VetStep (A05) -> EFV_Veteran.OnRequestStep: the owner's UI
-- reports a promotion taken for a veteran route B job.
-- Params:  playerID requesting player (authoritative), params (unitID, have).
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnRequestVetStep(playerID, params)
	EFV_Log(2, "Vet", "step request from player=%s", tostring(playerID))
	SafeCall("Vet", "OnRequestStep", EFV_Veteran.OnRequestStep, playerID, params)
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Gameplay.OnPlayerDefeat(pid, defeatType, eventID)
-- Events.PlayerDefeat (A55, async hint, DV13). Registered unconditionally;
-- acts only when EFV_Config.FLAG_DEFEAT_HINT -> EFV_Lifecycle.
-- OnPlayerDefeatHint(pid). No RNG, no unit/gold changes.
-- Params:  pid player ID, defeatType, eventID.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Gameplay.OnPlayerDefeat(pid, defeatType, eventID)
	if not EFV_Config.FLAG_DEFEAT_HINT then
		return nil
	end
	SafeCall("Defeat", "OnPlayerDefeatHint", EFV_Lifecycle.OnPlayerDefeatHint, pid)
	return nil
end

-- ---------------------------------------------------------------------------
-- 2. Handler registration (PLAN 1.7 step 2): at file load, unconditionally.
-- Literal GameEvents.<Name>.Add calls so the API audit (PLAN 6.3) can match
-- every UI OnStart with its gameplay handler.
-- ---------------------------------------------------------------------------
GameEvents.OnGameTurnStarted.Add(EFV_Gameplay.OnGameTurnStarted)
EFV_Log(2, "Init", "registered %s", "GameEvents.OnGameTurnStarted")

GameEvents.PlayerTurnStarted.Add(EFV_Gameplay.OnPlayerTurnStarted)
EFV_Log(2, "Init", "registered %s", "GameEvents.PlayerTurnStarted")

GameEvents.PlayerTurnStartComplete.Add(EFV_Gameplay.OnPlayerTurnStartComplete)
EFV_Log(2, "Init", "registered %s", "GameEvents.PlayerTurnStartComplete")

-- First hook after the engine's round heal (Session E T26): mutiny floor.
GameEvents.OnGameTurnEnded.Add(EFV_Gameplay.OnGameTurnEnded)
EFV_Log(2, "Init", "registered %s", "GameEvents.OnGameTurnEnded")

-- Never fires in GS single player (Session C); harmless idempotent extra.
GameEvents.OnPlayerTurnEnded.Add(EFV_Gameplay.OnPlayerTurnEnded)
EFV_Log(2, "Init", "registered %s", "GameEvents.OnPlayerTurnEnded")

GameEvents.OnCombatOccurred.Add(EFV_Gameplay.OnCombatOccurred)
EFV_Log(2, "Init", "registered %s", "GameEvents.OnCombatOccurred")

GameEvents.CityConquered.Add(EFV_Gameplay.OnCityConquered)
EFV_Log(2, "Init", "registered %s", "GameEvents.CityConquered")

GameEvents.EFV_Send.Add(EFV_Gameplay.OnRequestSend)
EFV_Log(2, "Init", "registered %s", "GameEvents.EFV_Send")

GameEvents.EFV_Recall.Add(EFV_Gameplay.OnRequestRecall)
EFV_Log(2, "Init", "registered %s", "GameEvents.EFV_Recall")

GameEvents.EFV_Entrust.Add(EFV_Gameplay.OnRequestEntrust)
EFV_Log(2, "Init", "registered %s", "GameEvents.EFV_Entrust")

GameEvents.EFV_VetStep.Add(EFV_Gameplay.OnRequestVetStep)
EFV_Log(2, "Init", "registered %s", "GameEvents.EFV_VetStep")

Events.PlayerDefeat.Add(EFV_Gameplay.OnPlayerDefeat)
EFV_Log(2, "Init", "registered %s", "Events.PlayerDefeat")

-- ---------------------------------------------------------------------------
-- 3. Store init (PLAN 1.7 step 3): EFV_Init guard, schema migrations.
-- EFV_Config.Derive() is lazy (first use), not called here (PLAN 1.7 step 4).
-- ---------------------------------------------------------------------------
SafeCall("Init", "EFV_Records.Init", EFV_Records.Init)

EFV_Log(2, "Init", "EFV_Gameplay loaded")
