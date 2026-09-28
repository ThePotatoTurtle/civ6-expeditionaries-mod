-- EFV_Util.lua (fixture; shared G + UI via ImportFiles)
EFV_Util = {}

function EFV_IsGameplay()
	return UI == nil
end

function EFV_Log(tag, msg)
	print("[EFV][T" .. tostring(Game.GetCurrentGameTurn()) .. "][" .. tag .. "] " .. msg)
end

-- The only sanctioned pairs() (PLAN 1.6).
function EFV_SortedKeys(t)
	local keys = {}
	for k, _ in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

function EFV_Util.SortedAlivePlayers()
	local ids = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end
