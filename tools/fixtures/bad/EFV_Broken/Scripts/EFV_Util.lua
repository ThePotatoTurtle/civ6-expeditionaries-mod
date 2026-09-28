-- EFV_Util.lua (BROKEN fixture: shared file with an unclosed region marker)
EFV_Util = {}

function EFV_Util.Log(msg)
	print(msg)
end

-- EFV:G-ONLY begin
function EFV_Util.Mutate()
	Game:SetProperty("EFV_X", 1)
end
