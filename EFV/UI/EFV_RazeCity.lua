-- ===========================================================================
-- EFV_RazeCity.lua  -- E2 FALLBACK ONLY (not active)
-- Context:  UI, ReplaceUIScript LuaContext "RazeCity", LoadOrder 1000, used
--           only if T24 fails (EFV_Config.FLAG_ENTRUST_UI = "REPLACE"). The
--           modinfo action EFV_RazeCity is commented out; activating E2 also
--           needs an ImportFiles copy of the base UI/RazeCity.xml with an
--           EFV_EntrustStack after the unnamed button stack
--           (RazeCity.xml:38-42), and removing UI/EFV_EntrustPopup.xml from
--           the AddUserInterfaces action (PLAN 1.1, 3.4, 4.3 item 8).
-- Owner:    WP6.3 (only if T24 fails). Structure only.
--
-- Responsibility (PLAN 3.4 E2): include the GS RazeCity script, wrap the
-- global OnOpen (registered by the base in LateInitialize, RazeCity.lua:172,
-- i.e. after this file ran) and fill the EFV recipient stack using the same
-- rules as EFV_EntrustPopup (snapshot from EFV_UI_ReadStore, confirm, KEEP,
-- EFV_Entrust request). Uses the base Close() (RazeCity.lua:59).
-- ===========================================================================

include("RazeCity_Expansion2")
include("EFV_UIShared")

local BASE_OnOpen = OnOpen

-- ---------------------------------------------------------------------------
-- EFV_FillEntrustStack()
-- Builds the Entrust recipient buttons into Controls.EFV_EntrustStack of the
-- replaced RazeCity.xml (same content and request flow as
-- EFV_EntrustPopup InjectButtons / SendEntrust).
-- Params:  none.
-- Returns: nil.
-- PLAN 3.4 E2. APIs: U04, U03, U07, U10, U12.
-- ---------------------------------------------------------------------------
local function EFV_FillEntrustStack()
	EFV_Log(3, "Stub", "EFV_RazeCity.EFV_FillEntrustStack not implemented (WP6.3)")
	return nil
end

-- Wrapped global OnOpen: base first, then the EFV stack.
function OnOpen()
	if BASE_OnOpen ~= nil then
		BASE_OnOpen()
	end
	EFV_FillEntrustStack()
end
