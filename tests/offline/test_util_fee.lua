-- @harness native
-- EFV_Config.Derive + EFV_Util: band thresholds for every map size, band
-- boundaries, base gold cost and the fee table of spec 5.2 / PLAN 2.2, plus
-- the small helpers (sorted keys, players, plot keys, nearest city).

local MAP_BANDS = {
	-- spec 4.2: t_k = max(1, floor(thr_k * W / 84 + 0.5)), thr = 10/20/35
	{ "MAPSIZE_DUEL", 44, { 5, 10, 18 } },
	{ "MAPSIZE_TINY", 60, { 7, 14, 25 } },
	{ "MAPSIZE_SMALL", 74, { 9, 18, 31 } },
	{ "MAPSIZE_STANDARD", 84, { 10, 20, 35 } },
	{ "MAPSIZE_LARGE", 96, { 11, 23, 40 } },
	{ "MAPSIZE_HUGE", 106, { 13, 25, 44 } },
}

for _, m in ipairs(MAP_BANDS) do
	test("Derive band thresholds " .. m[1], function()
		H.world{ map = m[1] }
		H.loadEFV()
		local D = EFV_Config.Derive()
		H.eq(D.MAP_WIDTH, m[2], "map width")
		H.deq(D.BAND_THRESHOLDS, m[3], "thresholds")
		H.deq(EFV_BandThresholds(), m[3], "EFV_BandThresholds accessor")
	end)

	test("EFV_Band boundaries " .. m[1], function()
		H.world{ map = m[1], wrapX = false }
		H.loadEFV()
		local t = m[3]
		-- same row: distance = |dx|
		local cases = { { 1, 1 }, { t[1], 1 }, { t[1] + 1, 2 }, { t[2], 2 }, { t[2] + 1, 3 }, { t[3], 3 }, { t[3] + 1, 4 } }
		for _, c in ipairs(cases) do
			local band, d = EFV_Band(0, 10, c[1], 10)
			H.eq(d, c[1], "distance returned")
			H.eq(band, c[2], "band for d=" .. c[1])
		end
	end)
end

test("Derive: purchase multiplier, speed and percents", function()
	H.world{}
	H.loadEFV()
	local D = EFV_Config.Derive()
	H.eq(D.PURCHASE_MULTIPLIER, 4)
	H.eq(D.SPEED_PCT, 100)
	H.eq(D.SPEED_SOURCE, "GetGameSpeedType")
	-- 0.5.2 fee ruling: EXP / CS 0% + surcharge, VOL 20% + surcharge.
	H.deq(D.FEE_PCT, { EXPEDITIONARY = 0, VOLUNTEER = 20, CS_EXPEDITIONARY = 0 })
	H.deq(D.SURCHARGE_PCT, { 0, 10, 20, 30 })
end)

test("Derive: speed falls back to GetValue, then to Standard with an error", function()
	H.world{ speed = "GAMESPEED_EPIC" }
	GameConfiguration.GetGameSpeedType = nil
	H.loadEFV()
	local D = EFV_Config.Derive()
	H.eq(D.SPEED_PCT, 150); H.eq(D.SPEED_SOURCE, "GetValue")
end)

test("Derive: no speed API at all -> 100 and an ERROR line", function()
	H.world{ speed = "GAMESPEED_EPIC" }
	GameConfiguration.GetGameSpeedType = nil
	GameConfiguration.GetValue = nil
	H.loadEFV()
	local D = EFV_Config.Derive()
	H.eq(D.SPEED_PCT, 100); H.eq(D.SPEED_SOURCE, "DEFAULT")
	H.ok(#H.errorLines() > 0, "logged as error")
end, { allowErrors = true })

-- Worked table (Standard speed; Swordsman base 360, Galley 260, Warrior 160)
-- with the 0.5.2 fee ruling: EXP / CS 0% / 10% / 20% / 30% (band 1 free),
-- VOL 20% / 30% / 40% / 50%.
local FEES = {
	{ "UNIT_SWORDSMAN", "EXPEDITIONARY", { 0, 36, 72, 108 } },
	{ "UNIT_SWORDSMAN", "CS_EXPEDITIONARY", { 0, 36, 72, 108 } },
	{ "UNIT_SWORDSMAN", "VOLUNTEER", { 72, 108, 144, 180 } },
	{ "UNIT_GALLEY", "EXPEDITIONARY", { 0, 26, 52, 78 } },
	{ "UNIT_GALLEY", "CS_EXPEDITIONARY", { 0, 26, 52, 78 } },
	{ "UNIT_GALLEY", "VOLUNTEER", { 52, 78, 104, 130 } },
	{ "UNIT_WARRIOR", "EXPEDITIONARY", { 0, 16, 32, 48 } },
	{ "UNIT_WARRIOR", "VOLUNTEER", { 32, 48, 64, 80 } },
}

test("EFV_Fee: worked table (Standard speed, 0.5.2 fee ruling; band 1 free for EXP / CS)", function()
	H.world{}
	H.loadEFV()
	for _, f in ipairs(FEES) do
		for band = 1, 4 do
			H.eq(EFV_Fee(f[1], f[2], band), f[3][band], f[1] .. " " .. f[2] .. " band " .. band)
		end
	end
end)

test("EFV_BaseGoldCost: Cost x speed x 4", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_BaseGoldCost("UNIT_SWORDSMAN"), 360)
	H.eq(EFV_BaseGoldCost("UNIT_GALLEY"), 260)
	H.isnil(EFV_BaseGoldCost("UNIT_DOES_NOT_EXIST"))
	H.isnil(EFV_Fee("UNIT_DOES_NOT_EXIST", "EXPEDITIONARY", 1))
end)

-- Other speeds: fee = ceil(Cost * speed * 4 * pct / 10000); Quick (67) checks
-- the ceiling. { speed, EXP / CS bands 1-4, VOL bands 1-4 } for the Swordsman.
local SPEEDS = {
	{ "GAMESPEED_MARATHON", { 0, 108, 216, 324 }, { 216, 324, 432, 540 } },
	{ "GAMESPEED_EPIC", { 0, 54, 108, 162 }, { 108, 162, 216, 270 } },
	{ "GAMESPEED_QUICK", { 0, 25, 49, 73 }, { 49, 73, 97, 121 } },   -- 24.12 / 48.24 / 72.36 / 96.48 / 120.6 rounded up
	{ "GAMESPEED_ONLINE", { 0, 18, 36, 54 }, { 36, 54, 72, 90 } },
}
for _, sp in ipairs(SPEEDS) do
	test("EFV_Fee Swordsman EXP / CS / VOL at " .. sp[1], function()
		H.world{ speed = sp[1] }
		H.loadEFV()
		for band = 1, 4 do
			H.eq(EFV_Fee("UNIT_SWORDSMAN", "EXPEDITIONARY", band), sp[2][band], "EXP band " .. band)
			H.eq(EFV_Fee("UNIT_SWORDSMAN", "CS_EXPEDITIONARY", band), sp[2][band], "CS band " .. band)
			H.eq(EFV_Fee("UNIT_SWORDSMAN", "VOLUNTEER", band), sp[3][band], "VOL band " .. band)
		end
	end)
end

test("EFV_Fee is an integer (no float artefacts) for every trainable combat unit", function()
	H.world{ speed = "GAMESPEED_QUICK" }
	H.loadEFV()
	for row in GameInfo.Units() do
		if row.FormationClass == "FORMATION_CLASS_LAND_COMBAT" or row.FormationClass == "FORMATION_CLASS_NAVAL" then
			for band = 1, 4 do
				local fee = EFV_Fee(row.UnitType, "VOLUNTEER", band)
				H.eq(fee, math.floor(fee), row.UnitType)
				local n = row.Cost * 67 * 4 * (10 + band * 10)   -- VOL 20% + surcharge (band - 1) * 10%
				H.eq(fee, math.ceil(n / 10000 - 1e-9), row.UnitType .. " band " .. band)
				local e = EFV_Fee(row.UnitType, "EXPEDITIONARY", band)
				H.eq(e, math.ceil(row.Cost * 67 * 4 * (band - 1) * 10 / 10000 - 1e-9), row.UnitType .. " EXP band " .. band)
			end
		end
	end
end)

test("EFV_Duration and EFV_ForceLabelKey", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_Duration("EXPEDITIONARY"), 20)
	H.eq(EFV_Duration("CS_EXPEDITIONARY"), 10)
	H.isnil(EFV_Duration("VOLUNTEER"))
	H.eq(EFV_ForceLabelKey("VOLUNTEER"), "LOC_EFV_FORCE_VOLUNTEER")
	H.isnil(EFV_ForceLabelKey("NOPE"))
end)

test("EFV_SortedKeys / EFV_SortedAlivePlayers are ascending", function()
	H.world{}
	H.loadEFV()
	H.deq(EFV_SortedKeys({ r3 = 1, r10 = 1, r1 = 1 }), { "r1", "r10", "r3" })
	H.deq(EFV_SortedKeys({ [5] = 1, [2] = 1 }), { 2, 5 })
	H.deq(EFV_SortedKeys(nil), {})
	H.deq(EFV_SortedAlivePlayers(), { 0, 1, 2, 3, 4, 62, 63 })
	H.kill(2)
	H.deq(EFV_SortedAlivePlayers(), { 0, 1, 3, 4, 62, 63 })
end)

test("EFV_PlayerKind", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_PlayerKind(0), "MAJOR")
	H.eq(EFV_PlayerKind(4), "CITY_STATE")
	H.eq(EFV_PlayerKind(62), "FREE_CITIES")
	H.eq(EFV_PlayerKind(63), "BARBARIAN")
	H.isnil(EFV_PlayerKind(30))
end)

test("EFV_PlotKey", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_PlotKey(5, 7), "p" .. (7 * 84 + 5))
	H.isnil(EFV_PlotKey(5, 999))
end)

test("EFV_NearestCity: minimum distance, tie -> lowest city ID", function()
	H.world{ wrapX = false }
	H.loadEFV()
	local a = H.city(1, 20, 10, { radius = 0 })
	local b = H.city(1, 30, 10, { radius = 0 })   -- created later: higher ID
	local c, d = EFV_NearestCity(1, 25, 10)       -- equidistant (5 / 5)
	H.eq(c, a, "tie-break lowest ID"); H.eq(d, 5)
	c, d = EFV_NearestCity(1, 29, 10)
	H.eq(c, b); H.eq(d, 1)
	H.isnil(EFV_NearestCity(2, 1, 1), "no cities")
end)

test("EFV_IsGameplay is true without UI", function()
	H.world{}
	H.loadEFV()
	H.ok(EFV_IsGameplay())
end)

test("EFV_Has probes methods without throwing", function()
	H.world{}
	H.loadEFV()
	local u = H.unit(0, "UNIT_WARRIOR", 3, 3)
	H.ok(EFV_Has(u, "GetAttacksRemaining"))
	H.ok(not EFV_Has(u, "NoSuchMethod"))
	H.ok(not EFV_Has(nil, "GetID"))
end)

test("EFV_UnitDisplayName: veteran name wins", function()
	H.world{}
	H.loadEFV()
	H.eq(EFV_UnitDisplayName("UNIT_SWORDSMAN", "Bob"), "Bob")
	H.eq(EFV_UnitDisplayName("UNIT_SWORDSMAN", nil), Locale.Lookup(GameInfo.Units["UNIT_SWORDSMAN"].Name))
	H.eq(EFV_UnitDisplayName("UNIT_SWORDSMAN", ""), Locale.Lookup(GameInfo.Units["UNIT_SWORDSMAN"].Name))
end)
