-- EFV_Panel.lua (BROKEN fixture, UI context)
include("InstanceManager")

local m_IM = InstanceManager:new("NoSuchInstance", "RowLabel", Controls.Main)   -- ui-instance

local function OnClick()
	local params = { OnStart = "EFV_Nope" }                                     -- onstart-unhandled
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, params)
	local n = Game.GetRandNum(5, "ui")                                          -- api-context (G only)
	Controls.Missing:SetHide(true)                                              -- ui-control
	local store = Game:GetProperty("EFV_Records")
	for id, rec in pairs(store.recs) do                                         -- pairs-records (warn)
		print(id, rec, n)
	end
end

GameEvents.EFV_Nope.Add(OnClick)                                                -- api-context (G only)
Controls.Title:RegisterCallback(Mouse.eLClick, OnClick)
Events.UnitSelectionChangd.Add(OnClick)                                          -- unknown-event
include("EFV_Util")
function EFV_UIOnlyHelper() end                                                -- defined in the UI state only
local function L(key, ...) return Locale.Lookup(key, ...) end
local s2 = L("LOC_EFV_TWO_ARGS", 1)                                            -- text-args (UI wrapper, WP7.3)
