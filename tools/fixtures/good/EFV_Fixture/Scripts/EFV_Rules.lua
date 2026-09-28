-- EFV_Rules.lua (fixture; shared, context adapters with region markers, PLAN 2.3)
EFV_Rules = {}

function EFV_Rules.PartnerBasis(s, r)
	local pS = Players[s]
	local pR = Players[r]
	if pS == nil or pR == nil then
		return nil
	end
	if pS:GetTeam() == pR:GetTeam() then
		return "TEAM"
	end
	if EFV_IsGameplay() then
		-- EFV:G-ONLY begin
		if pS:GetDiplomacy():HasAllied(r) then
			return "ALLIANCE"
		end
		-- EFV:G-ONLY end
	else
		-- EFV:UI-ONLY begin
		local idx = pR:GetDiplomaticAI():GetDiplomaticStateIndex(s)
		local row = GameInfo.DiplomaticStates[idx]
		if row ~= nil and row.StateType == "DIPLO_STATE_ALLIED" then
			return "ALLIANCE"
		end
		-- EFV:UI-ONLY end
	end
	return nil
end

function EFV_Rules.SendReasons(pUnit)
	local reasons = {}
	if pUnit:GetDamage() > 0 then
		reasons[#reasons + 1] = "DAMAGED"
	end
	if pUnit:GetMovesRemaining() == 0 then
		reasons[#reasons + 1] = "NO_MOVES"
	end
	return reasons
end
