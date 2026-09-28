-- EFV_UnitFlagManager.lua (fixture; ReplaceUIScript UnitFlagManager, thin wrapper D8)
include("UnitFlagManager")

local BASE_UpdateReligion = UnitFlag.UpdateReligion

function UnitFlag.UpdateReligion(self)
	BASE_UpdateReligion(self)
	local pUnit = self:GetUnit()
	if pUnit ~= nil and Modding.IsModActive("0f6b6a8e-7c1e-4a55-9d1e-3c2b8a0e5f11") then
		local store = Game:GetProperty("EFV_Records")
		if store ~= nil then
			print("[EFV] flag " .. tostring(pUnit:GetID()))
		end
	end
end
