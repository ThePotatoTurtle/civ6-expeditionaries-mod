-- ===========================================================================
-- EFV_VetRestore.lua
-- Context:  UI (AddUserInterfaces, InGame), EFV_VetRestore.xml.
-- Owner:    WP0 (0.7 stub); WP3 (implementation, FIXPLAN_0.7 item 7 step 2).
--
-- Responsibility (INTERFACES note 33): for each veteran job of the local
-- player (EFV_UI_ReadStore().vet, job.p == Game.GetLocalPlayer()), issue
-- the engine's own UnitCommandTypes.PROMOTE for the next wanted promotion
-- (UnitManager.CanStartCommand / RequestCommand, the base UnitPromotionPopup
-- pattern, UnitPromotionPopup.lua:66-72, 81-82) and report a promotion
-- taken with the EFV_VetStep request (EFV_Config.REQ_VETSTEP, params
-- unitID, have). Only the owner's client acts; gameplay owns all state and
-- verifies (EFV_Veteran.Sync). Log tag "UIVet".
--
-- Per job, each poll:
--   have > job.got (a promotion landed, gameplay not synced yet): send
--     EFV_VetStep once per (unit, have), resend after RESEND_S;
--   else: the first name of job.want whose index the engine offers
--     (tResults[UnitCommandResults.PROMOTIONS]; handles prerequisites
--     whatever the snapshot order) -> PROMOTE once per (unit, got), one
--     resend after RESEND_S; nothing offered -> logged once, wait (the
--     job has no time limit since 0.7.4; the engine offers the next
--     promotion on a later turn).
-- Triggers: ContextPtr:SetUpdate poll every POLL_S (EFV_UI_ReadStore is
-- cached by EFV_Rev and turn), plus Events.UnitPromoted,
-- Events.UnitAddedToMap and Events.PlayerTurnActivated (poll at once).
-- m_Units is presentation memory only (what was sent when), pruned when a
-- job disappears.
-- ===========================================================================

include("EFV_UIShared")

local LOG_TAG = "UIVet"
local POLL_S = 0.25
local RESEND_S = 3.0

local m_Clock = 0
local m_NextPoll = 0
local m_Units = {}   -- uid -> { step = { have, at }, promote = { got, at, n }, waitGot }

local function LocalID()
	local ok, pid = pcall(function() return Game.GetLocalPlayer() end)
	if ok and type(pid) == "number" then
		return pid
	end
	return -1
end

local function Memo(uid)
	local m = m_Units[uid]
	if m == nil then
		m = {}
		m_Units[uid] = m
	end
	return m
end

-- Indexes the engine offers for PROMOTE now (set), or nil when no promotion
-- can be taken.
local function Offered(pUnit)
	local bCanStart, tResults = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.PROMOTE, true, true)
	if not bCanStart or type(tResults) ~= "table" then
		return nil
	end
	local list = tResults[UnitCommandResults.PROMOTIONS]
	if type(list) ~= "table" then
		return nil
	end
	local set = {}
	for _, idx in ipairs(list) do
		set[idx] = true
	end
	return set
end

local function SendPromote(pUnit, job, row, attempt)
	local ok, err = pcall(function()
		local t = {}
		t[UnitCommandTypes.PARAM_PROMOTION_TYPE] = row.Index
		UnitManager.RequestCommand(pUnit, UnitCommandTypes.PROMOTE, t)
	end)
	EFV_Log(2, LOG_TAG, "PROMOTE uid=%s id=%s promotion=%s attempt=%d ok=%s%s", tostring(job.u), tostring(job.rid),
		tostring(row.UnitPromotionType), attempt, tostring(ok), ok and "" or (" err=" .. tostring(err)))
end

local function ProcessJob(job, localID)
	local pUnit = nil
	pcall(function() pUnit = Players[localID]:GetUnits():FindID(job.u) end)
	if not EFV_UnitMatches(pUnit, job.p, job.u, job.ut) then
		return
	end
	local m = Memo(job.u)
	local have = #(pUnit:GetExperience():GetPromotions() or {})
	local got = tonumber(job.got) or 0
	if have > got then
		if m.step == nil or m.step.have ~= have or m_Clock - m.step.at >= RESEND_S then
			m.step = { have = have, at = m_Clock }
			EFV_UI_Request(EFV_Config.REQ_VETSTEP, { unitID = job.u, have = have })
		end
		return
	end
	local offered = Offered(pUnit)
	local pick = nil
	if offered ~= nil then
		for _, name in ipairs(job.want or {}) do
			local row = GameInfo.UnitPromotions[name]
			if row ~= nil and offered[row.Index] then
				pick = row
				break
			end
		end
	end
	if pick == nil then
		if m.waitGot ~= got then
			m.waitGot = got
			EFV_Log(2, LOG_TAG, "waiting uid=%s id=%s got=%s: no wanted promotion offered now", tostring(job.u),
				tostring(job.rid), tostring(got))
		end
		return
	end
	local p = m.promote
	if p == nil or p.got ~= got then
		m.promote = { got = got, at = m_Clock, n = 1 }
		SendPromote(pUnit, job, pick, 1)
	elseif p.n < 2 and m_Clock - p.at >= RESEND_S then
		p.n = 2
		p.at = m_Clock
		SendPromote(pUnit, job, pick, 2)
	end
end

-- One pass over the local player's jobs.
local function Poll()
	local localID = LocalID()
	if localID < 0 then
		return
	end
	local store = EFV_UI_ReadStore()
	local live = {}
	for _, job in ipairs(store.vet or {}) do
		if type(job) == "table" and job.p == localID and type(job.u) == "number" then
			live[job.u] = true
			local ok, err = pcall(ProcessJob, job, localID)
			if not ok then
				EFV_Log(1, LOG_TAG, "job uid=%s failed: %s", tostring(job.u), tostring(err))
			end
		end
	end
	for _, uid in ipairs(EFV_SortedKeys(m_Units)) do
		if not live[uid] then
			m_Units[uid] = nil
		end
	end
end

local function PollNow()
	local ok, err = pcall(Poll)
	if not ok then
		EFV_Log(1, LOG_TAG, "poll failed: %s", tostring(err))
	end
end

local function OnUpdate(dt)
	m_Clock = m_Clock + (tonumber(dt) or 0)
	if m_Clock >= m_NextPoll then
		m_NextPoll = m_Clock + POLL_S
		PollNow()
	end
end

-- ---------------------------------------------------------------------------
-- Initialize(): contexts load hidden (note 19), so show this one.
-- ---------------------------------------------------------------------------
local function Initialize()
	ContextPtr:SetHide(false)
	ContextPtr:SetUpdate(OnUpdate)
	Events.UnitPromoted.Add(PollNow)
	Events.UnitAddedToMap.Add(PollNow)
	Events.PlayerTurnActivated.Add(PollNow)
	EFV_Log(2, LOG_TAG, "initialized")
end

Initialize()
