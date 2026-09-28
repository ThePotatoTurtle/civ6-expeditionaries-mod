-- EFV_Gameplay.lua (fixture; AddGameplayScripts entry point)
include("EFV_Util")
include("EFV_Rules")

local STORE_KEY = "EFV_Records"

local function Load()
	local store = Game:GetProperty(STORE_KEY)
	if store == nil then
		store = { ids = {} }
	end
	return store
end

local function Commit(store)
	Game:SetProperty(STORE_KEY, store)
end

local function Notify(playerID, notifType)
	local data = {}
	data[ParameterTypes.MESSAGE] = Locale.Lookup("LOC_EFV_NOTIF_" .. notifType .. "_MESSAGE")
	data[ParameterTypes.SUMMARY] = Locale.Lookup("LOC_EFV_NOTIF_" .. notifType .. "_SUMMARY")
	NotificationManager.SendNotification(playerID, GameInfo.Types["EFV_NOTIF_" .. notifType].Hash, data)
end

local function OnSend(playerID, params)
	local store = Load()
	local pPlayer = Players[playerID]
	if pPlayer == nil then
		return
	end
	local pUnit = pPlayer:GetUnits():FindID(params.UnitID)
	if pUnit == nil then
		return
	end
	local reasons = EFV_Rules.SendReasons(pUnit)
	if #reasons > 0 then
		EFV_Log("Send", Locale.Lookup("LOC_EFV_REASON_" .. reasons[1]))
		return
	end
	local roll = Game.GetRandNum(100, "EFV spawn pick")
	store.ids[#store.ids + 1] = roll
	Commit(store)
	Notify(playerID, "DEPARTED")
	EFV_Log("Send", "type " .. tostring(GameInfo.Types["EFV_NOTIF_ARRIVED"].Hash))
end

local function OnTurnStarted(turn)
	for _, pid in ipairs(EFV_Util.SortedAlivePlayers()) do
		EFV_Log("Turn", "player " .. tostring(pid) .. " turn " .. tostring(turn))
	end
end

-- DV13: async hint, snapshot write only (allowed exception, reported as a warning).
function OnPlayerDefeatHint(pid, defeatType, eventID)
	local store = Load()
	store.defeated = pid
	Commit(store)
end

GameEvents.EFV_Send.Add(OnSend)
GameEvents.OnGameTurnStarted.Add(OnTurnStarted)
Events.PlayerDefeat.Add(OnPlayerDefeatHint)
