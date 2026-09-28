-- EFV_Gameplay.lua (BROKEN fixture: every marked line must be reported)
include("EFV_Util")

local function Helper(pid)
	Players[pid]:GetTreasury():ChangeGoldBalance(-10)          -- async-mutation (reached from Events.PlayerDefeat)
	return Game.GetRandNum(10, "bad")                          -- async-mutation
end

local function OnDefeat(pid)
	Helper(pid)
end

function Scan(store)
	for k, v in pairs(store.recs) do                           -- forbidden-pairs
		print(k, v)
	end
	counter = 1                                                -- global-assign-in-function
	local r = math.random(1, 10)                               -- forbidden (math.random)
	local t = os.time()                                        -- forbidden (os.* in G)
	local me = Game.GetLocalPlayer()                           -- api-context (UI only)
	local u = Plyers[0]                                        -- undefined-global (typo)
	local x = table.unpack({ 1, 2 })                           -- lua52
	local d = pUnit:GetDamagee()                               -- undefined-global + unknown-method
	UI.RequestPlayerOperation(0, PlayerOperations.EXECUTE_SCRIPT, {})  -- api-context
	ExposedMembers.EFV = {}                                    -- forbidden
	EFV_Util.Missing()                                         -- unknown-member
	local unit = UnitManager.GetUnit(0, 1)
	unit:Kill()                                                -- forbidden (:Kill)
	print(Locale.Lookup("LOC_EFV_TWO_ARGS", 1))                -- text-args (needs 2)
	print(Locale.Lookup("LOC_EFV_UNDEFINED_KEY"))              -- text-missing
	print(Locale.Lookup("LOC_EFV_REASON_" .. tostring(r)))     -- Appendix B codes without text -> text-reason
	print("EFV_NOTIF_NOPE")                                    -- notification-missing
	local tbl = GameInfo.NoSuchTable                           -- gameinfo-unknown
	local tbl2 = GameInfo.Buildings                            -- gameinfo-unlisted (warn)
	local m = MapLayers.ANYY                                   -- unknown-api (enum typo)
	return r, t, me, u, x, d, tbl, tbl2, m
end

GameEvents.OnGameTurnStartd.Add(Scan)                          -- unknown-event (typo)
Events.PlayerDefeat.Add(OnDefeat)
Events.UnitAddedToMap.Add(Scan)                                -- api-context (UI event in G)
EFV_UIOnlyHelper()                                             -- undefined-global: only the UI state defines it
