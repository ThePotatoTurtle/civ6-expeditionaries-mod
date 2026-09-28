-- EFV_UIShared.lua (fixture; UI include)
include("EFV_Util")
include("EFV_Rules")

function EFV_UI_Request(onStart, params)
	params.OnStart = onStart
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, params)
end

function EFV_UI_ReadStore()
	return Game:GetProperty("EFV_Records")
end
