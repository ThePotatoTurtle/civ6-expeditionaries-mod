-- EFV_Tracker.lua (fixture; AddUserInterfaces InGame)
include("InstanceManager")
include("EFV_UIShared")

local m_RowIM = InstanceManager:new("RowInstance", "RowLabel", Controls.RowStack)

local function Refresh()
	m_RowIM:ResetInstances()
	local store = EFV_UI_ReadStore()
	if store == nil or store.ids == nil then
		return
	end
	for _, id in ipairs(store.ids) do
		local inst = m_RowIM:GetInstance()
		inst.RowLabel:SetText(Locale.Lookup("LOC_EFV_STATE_GRACE", id))
	end
end

local function OnSendClicked()
	local pUnit = UI.GetHeadSelectedUnit()
	if pUnit == nil then
		return
	end
	EFV_UI_Request("EFV_Send", { UnitID = pUnit:GetID() })
end

local function Initialize()
	Controls.Title:LocalizeAndSetText("LOC_EFV_TRACKER_TITLE")
	Controls.SendButton:RegisterCallback(Mouse.eLClick, OnSendClicked)
	Events.LoadGameViewStateDone.Add(Refresh)
	Events.PlayerTurnActivated.Add(Refresh)
	ContextPtr:SetHide(false)
end
Initialize()
