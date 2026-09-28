-- ===========================================================================
-- EFV_Notify.lua
-- Module:   EFV_Notify (global table)
-- Context:  gameplay only, include("EFV_Notify").
-- Owner:    WP1.2 (implemented).
--
-- Responsibility (PLAN 2.7; spec 14.3; D9): an in-memory FIFO of
-- notifications (never persisted; cleared at flush) and the flush that sends
-- them with NotificationManager.SendNotification. Text is resolved in
-- gameplay at flush time from "<textKeyBase>_MESSAGE" / "_SUMMARY".
--
-- Queue entry shape (INTERFACES "Notification queue entry"):
--   { pid, typeName, key, args, x, y, extra }
-- extra (optional): { recordID = n, kind = s } -> data.EFV_RecordID /
-- data.EFV_Kind (custom keys for stale-copy cleanup in the UI, D9).
--
-- Rules:
--   * Human players only: Queue is a no-op for AI, city-states, barbarians,
--     Free Cities and invalid IDs (PLAN 2.7; IsHuman is synchronised, so the
--     skip is identical on every client).
--   * Handlers call EFV_Records.Commit(store) and then EFV_Notify.Flush()
--     (INTERFACES Scaffold note 3).
--   * D9 re-send: GRACE and MUTINY are queued again every turn by the
--     Lifecycle timers while the countdown / mutiny actively ticks (not while
--     a lapsed Volunteer's lapse is paused on valid land: one LAPSE_PAUSED
--     instead, INTERFACES note 29). Every notification is sent with AlwaysUnique = true
--     (the engine must not fold the new copy into the old one), and carries
--     data.EFV_Turn plus, when extra is given, data.EFV_RecordID / EFV_Kind,
--     so the Tracker can dismiss older copies for the same record and kind
--     (UI-side NotificationManager.Dismiss, U15). Within one batch, a second
--     entry with the same pid, type, record and kind replaces the first
--     (keeps the first one's queue position), so a record never produces two
--     copies of the same notification in one flush.
--   * GRACE, MUTINY and MUTINY_DEATH also get AlwaysAutoActivate = true (D9
--     map focus: the default activation looks at the LOCATION plot).
-- ===========================================================================

if EFV_Notify ~= nil and EFV_Notify.LOADED == 1 then
	return
end

include("EFV_Config")
include("EFV_Util")

EFV_Notify = {}

-- ---------------------------------------------------------------------------
-- Deprecated alias (WP1.2): use EFV_Config.NOTIF.LAPSE_CANCELLED (added to
-- the contract in WP1.7; SQL row and text by WP1.6).
-- ---------------------------------------------------------------------------
EFV_Notify.NOTIF_LAPSE_CANCELLED = EFV_Config.NOTIF.LAPSE_CANCELLED

-- Types sent with AlwaysAutoActivate (PLAN 2.7, D9).
local AUTO_ACTIVATE = {}
AUTO_ACTIVATE[EFV_Config.NOTIF.GRACE]        = true
AUTO_ACTIVATE[EFV_Config.NOTIF.MUTINY]       = true
AUTO_ACTIVATE[EFV_Config.NOTIF.MUTINY_DEATH] = true
-- Phase 3: a Volunteer lapse notice opens the grace countdown (it replaces
-- GRACE N = 5 on the lapse turn), so it is as unmissable as GRACE (D9).
AUTO_ACTIVATE[EFV_Config.NOTIF.VOLUNTEER_LAPSE] = true
AUTO_ACTIVATE[EFV_Config.NOTIF.ACCESS_LAPSE]    = true

-- Types re-sent every turn while the condition holds (D9). Exposed for the UI
-- tracker's stale-copy cleanup and for tests; the sending itself is ordinary.
local RESEND = {}
RESEND[EFV_Config.NOTIF.GRACE]  = true
RESEND[EFV_Config.NOTIF.MUTINY] = true

-- FIFO of queued entries (module-local; never persisted).
local m_Queue = {}

-- ===========================================================================
-- Local helpers
-- ===========================================================================

local function CurrentTurn()
	local ok, t = pcall(function() return Game.GetCurrentGameTurn() end)
	if ok and type(t) == "number" then
		return t
	end
	return -1
end

-- true if pid is a human player (A42). Any error -> false.
local function IsHumanPlayer(pid)
	if type(pid) ~= "number" or pid < 0 then
		return false
	end
	local ok, human = pcall(function()
		local p = Players[pid]
		if p == nil then
			return false
		end
		return p:IsHuman() == true
	end)
	return ok and human == true
end

-- Dense copy of args (nil -> {}); a non-table single value is wrapped.
local function CopyArgs(args)
	local out = {}
	if args == nil then
		return out
	end
	if type(args) ~= "table" then
		out[1] = args
		return out
	end
	local n = args.n or #args
	for i = 1, n do
		local a = args[i]
		if a == nil then
			a = ""
		end
		out[i] = a
	end
	return out
end

local function EntryKind(entry)
	local extra = entry.extra
	if extra == nil then
		return nil
	end
	return extra.kind or entry.typeName
end

-- Index of an already queued entry this one should replace, or nil. Only
-- entries tied to a record (extra.recordID) are coalesced.
local function FindDuplicate(entry)
	local extra = entry.extra
	if extra == nil or extra.recordID == nil then
		return nil
	end
	local kind = EntryKind(entry)
	for i, q in ipairs(m_Queue) do
		if q.pid == entry.pid and q.typeName == entry.typeName and q.extra ~= nil
			and q.extra.recordID == extra.recordID and EntryKind(q) == kind then
			return i
		end
	end
	return nil
end

local function Lookup(key, args)
	local ok, s = pcall(function()
		return Locale.Lookup(key, unpack(args, 1, #args))
	end)
	if ok and type(s) == "string" then
		return s
	end
	EFV_Log(1, "Notify", "Locale.Lookup(%s) failed: %s", tostring(key), tostring(s))
	return tostring(key)
end

-- Sends one entry. Returns true on success. Errors are caught by the caller.
local function SendEntry(entry)
	local typeRow = GameInfo.Types[entry.typeName]
	if typeRow == nil or typeRow.Hash == nil then
		EFV_Log(1, "Notify", "unknown notification type %s (missing Types row); pid=%d not notified",
			tostring(entry.typeName), entry.pid)
		return false
	end
	local data = {}
	data[ParameterTypes.MESSAGE] = Lookup(entry.key .. "_MESSAGE", entry.args)
	data[ParameterTypes.SUMMARY] = Lookup(entry.key .. "_SUMMARY", entry.args)
	if type(entry.x) == "number" and type(entry.y) == "number" and entry.x >= 0 and entry.y >= 0 then
		data[ParameterTypes.LOCATION] = { x = entry.x, y = entry.y }
	end
	data.AlwaysUnique = true
	if AUTO_ACTIVATE[entry.typeName] then
		data.AlwaysAutoActivate = true
	end
	data.EFV_Turn = entry.turn
	if entry.extra ~= nil then
		if type(entry.extra.recordID) == "number" then
			data.EFV_RecordID = entry.extra.recordID
		end
		data.EFV_Kind = tostring(EntryKind(entry))
	end
	NotificationManager.SendNotification(entry.pid, typeRow.Hash, data)
	return true
end

-- ===========================================================================
-- Public API
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- EFV_Notify.Queue(pid, typeName, textKeyBase, args, x, y, extra)
-- Skips non-human players (Players[pid]:IsHuman(), deterministic). Appends
-- { pid, typeName, key = textKeyBase, args, x, y, extra } to the FIFO (args
-- and extra are copied). A same-batch duplicate for the same pid, type,
-- extra.recordID and kind replaces the queued entry in place (D9 re-send).
-- Params:  pid recipient player ID; typeName EFV_Config.NOTIF value (e.g.
--          "EFV_NOTIF_DEPARTED"); textKeyBase e.g. "LOC_EFV_NOTIF_DEPARTED"
--          (nil -> "LOC_" .. typeName); args dense array of Lookup arguments
--          (already localized strings and numbers, in placeholder order; nil
--          holes become ""); x, y plot for LOCATION or nil; extra table or
--          nil ({ recordID = n, kind = s }; kind defaults to typeName).
-- Returns: nil.
-- PLAN 2.7. APIs: A42.
-- ---------------------------------------------------------------------------
function EFV_Notify.Queue(pid, typeName, textKeyBase, args, x, y, extra)
	if type(typeName) ~= "string" then
		EFV_Log(1, "Notify", "queue: bad typeName %s for pid=%s", tostring(typeName), tostring(pid))
		return nil
	end
	if not IsHumanPlayer(pid) then
		EFV_Log(3, "Notify", "skip pid=%s type=%s (not a human player)", tostring(pid), typeName)
		return nil
	end
	local entry = {
		pid      = pid,
		typeName = typeName,
		key      = textKeyBase or ("LOC_" .. typeName),
		args     = CopyArgs(args),
		x        = x,
		y        = y,
		turn     = CurrentTurn(),
	}
	if type(extra) == "table" then
		entry.extra = { recordID = extra.recordID, kind = extra.kind }
	end
	local dup = FindDuplicate(entry)
	if dup ~= nil then
		m_Queue[dup] = entry
		EFV_Log(3, "Notify", "replaced queued pid=%d type=%s rec=%s", pid, typeName, tostring(entry.extra.recordID))
	else
		m_Queue[#m_Queue + 1] = entry
		EFV_Log(3, "Notify", "queued pid=%d type=%s rec=%s", pid, typeName,
			tostring(entry.extra and entry.extra.recordID))
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Notify.QueueForRecord(rec, typeName, args, opts)   (ADDED helper)
-- Queues typeName for the players of a record, with textKeyBase "LOC_" ..
-- typeName and extra = { recordID = rec.id, kind = opts.kind }. Sends to the
-- sender first, then the recipient (once if they are the same player); each
-- goes through Queue, so AI players are skipped.
-- Params:  rec record; typeName string; args dense array (same for both);
--          opts nil or { sender = bool (default true), recipient = bool
--          (default true), x = n, y = n (default rec.lastX / rec.lastY, else
--          no location), noLocation = bool, kind = s, key = textKeyBase }.
-- Returns: nil.
-- ---------------------------------------------------------------------------
function EFV_Notify.QueueForRecord(rec, typeName, args, opts)
	if type(rec) ~= "table" then
		EFV_Log(1, "Notify", "QueueForRecord: no record for type=%s", tostring(typeName))
		return nil
	end
	opts = opts or {}
	local x, y = opts.x, opts.y
	if x == nil and y == nil and not opts.noLocation then
		x, y = rec.lastX, rec.lastY
	end
	local extra = { recordID = rec.id, kind = opts.kind }
	local key = opts.key or ("LOC_" .. tostring(typeName))
	if opts.sender ~= false then
		EFV_Notify.Queue(rec.senderID, typeName, key, args, x, y, extra)
	end
	if opts.recipient ~= false and rec.recipientID ~= rec.senderID then
		EFV_Notify.Queue(rec.recipientID, typeName, key, args, x, y, extra)
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Notify.IsResendType(typeName) -> bool   (ADDED helper)
-- true for the D9 types re-sent every turn (GRACE, MUTINY).
-- ---------------------------------------------------------------------------
function EFV_Notify.IsResendType(typeName)
	return RESEND[typeName] == true
end

-- ---------------------------------------------------------------------------
-- EFV_Notify.Count() -> n   (ADDED helper; tests / diagnostics)
-- ---------------------------------------------------------------------------
function EFV_Notify.Count()
	return #m_Queue
end

-- ---------------------------------------------------------------------------
-- EFV_Notify.Discard()   (ADDED helper)
-- Drops the queue without sending (logged when non-empty).
-- ---------------------------------------------------------------------------
function EFV_Notify.Discard()
	if #m_Queue > 0 then
		EFV_Log(2, "Notify", "discarded %d queued notification(s)", #m_Queue)
	end
	m_Queue = {}
	return nil
end

-- ---------------------------------------------------------------------------
-- EFV_Notify.Flush()
-- In queue order: NotificationManager.SendNotification(pid,
-- GameInfo.Types[typeName].Hash, data) with data[ParameterTypes.MESSAGE] =
-- Locale.Lookup(key .. "_MESSAGE", unpack(args)), data[ParameterTypes.SUMMARY]
-- = Locale.Lookup(key .. "_SUMMARY", unpack(args)), data[ParameterTypes.
-- LOCATION] = { x = x, y = y } when given, data.AlwaysUnique = true,
-- data.AlwaysAutoActivate = true for GRACE / MUTINY / MUTINY_DEATH (D9 map
-- focus), data.EFV_Turn = queue turn, data.EFV_RecordID / data.EFV_Kind from
-- extra. The queue is detached first, so it is cleared even on error and a
-- Queue call made during the flush lands in the next batch. Each send runs
-- in its own pcall; an unknown type (no Types row) is logged and skipped.
-- Called last in every handler, after EFV_Records.Commit.
-- Params:  none.
-- Returns: nil.
-- PLAN 2.7; D9; BlackDeathScenario_Support.lua:96-109;
-- PiratesScenario_Shared_Script.lua:323-333. APIs: A53, A54, A51, A61.
-- ---------------------------------------------------------------------------
function EFV_Notify.Flush()
	local queue = m_Queue
	m_Queue = {}
	if #queue == 0 then
		return nil
	end
	local sent, failed = 0, 0
	for _, entry in ipairs(queue) do
		local ok, res = pcall(SendEntry, entry)
		if ok and res then
			sent = sent + 1
			EFV_Log(2, "Notify", "sent pid=%d type=%s rec=%s", entry.pid, entry.typeName,
				tostring(entry.extra and entry.extra.recordID))
		else
			failed = failed + 1
			if not ok then
				EFV_Log(1, "Notify", "send failed pid=%d type=%s: %s", entry.pid, entry.typeName, tostring(res))
			end
		end
	end
	EFV_Log(3, "Notify", "flush sent=%d failed=%d", sent, failed)
	return nil
end

EFV_Notify.LOADED = 1
