-- ===========================================================================
-- EFV_Icons.sql  (modinfo InGameActions UpdateIcons EFV_Icons)
-- Owner: WP1.6 (all rows); WP2.2 re-pointed MUTINY; WP7.3 may re-point cells.
--
-- D9 (WP2.2): the alert types are distinct from every other EFV type and
-- from each other: GRACE = DECLARE_WAR (12, a war warning), MUTINY =
-- REBELLION (66, units turning on their owner), MUTINY_DEATH = UNIT_LOST
-- (53). Together with the severity (HIGH / VERY_HIGH), AutoActivate (camera
-- jumps to the unit), the UI alert sound and the tracker banner.
--
-- PLAN 4.1, D9: IconDefinitions(Name, Atlas, 'Index') aliases to existing
-- atlas cells (QuickDeals pattern WS\2460661464\data\qd_icons.sql). No new
-- textures: every row points into ICON_ATLAS_NOTIFICATIONS (sizes 40 and 100,
-- GAME\Base\Assets\UI\Icons\Icons_Notifications.xml). The notification
-- panel's fallback icon name is "ICON_" .. NotificationType
-- (NotificationPanel.lua:25,793), so each alias is named ICON_EFV_NOTIF_<X>.
-- EFV_Notifications.sql also sets the Icon column to the shipped icon of the
-- SAME cell (belt and braces); keep the two files in step.
-- NEW-VERIFY (Phase 2, T21 session): whether an alias row alone renders.
-- ===========================================================================

INSERT INTO IconDefinitions (Name, Atlas, 'Index') VALUES
	('ICON_EFV_NOTIF_DEPARTED',        'ICON_ATLAS_NOTIFICATIONS', 9),    -- COMMAND_UNITS
	('ICON_EFV_NOTIF_ARRIVED',         'ICON_ATLAS_NOTIFICATIONS', 9),    -- COMMAND_UNITS
	('ICON_EFV_NOTIF_SPAWN_BLOCKED',   'ICON_ATLAS_NOTIFICATIONS', 110),  -- CITY_BESIEGED_BY_OTHER_PLAYER
	('ICON_EFV_NOTIF_EXPIRY_SOON',     'ICON_ATLAS_NOTIFICATIONS', 85),   -- DIPLO_DEAL_EXPIRED
	('ICON_EFV_NOTIF_GRACE',           'ICON_ATLAS_NOTIFICATIONS', 12),   -- DECLARE_WAR (D9)
	('ICON_EFV_NOTIF_MUTINY',          'ICON_ATLAS_NOTIFICATIONS', 66),   -- REBELLION (D9, WP2.2)
	('ICON_EFV_NOTIF_MUTINY_DEATH',    'ICON_ATLAS_NOTIFICATIONS', 53),   -- UNIT_LOST
	('ICON_EFV_NOTIF_RETURNING',       'ICON_ATLAS_NOTIFICATIONS', 9),    -- COMMAND_UNITS
	('ICON_EFV_NOTIF_RETURNED',        'ICON_ATLAS_NOTIFICATIONS', 9),    -- COMMAND_UNITS
	('ICON_EFV_NOTIF_REROUTED',        'ICON_ATLAS_NOTIFICATIONS', 59),   -- CITY_LOST (type retired 2026-09-30, kept for older saves)
	('ICON_EFV_NOTIF_VOLUNTEER_LAPSE', 'ICON_ATLAS_NOTIFICATIONS', 15),   -- MAKE_PEACE
	('ICON_EFV_NOTIF_ENTRUSTED',       'ICON_ATLAS_NOTIFICATIONS', 11),   -- CONSIDER_RAZE_CITY
	('ICON_EFV_NOTIF_ACCESS_LAPSE',    'ICON_ATLAS_NOTIFICATIONS', 122),  -- DIPLO_ALLIANCE_EXPIRED
	('ICON_EFV_NOTIF_UNIT_LOST',       'ICON_ATLAS_NOTIFICATIONS', 53),   -- UNIT_LOST
	('ICON_EFV_NOTIF_MERGED',          'ICON_ATLAS_NOTIFICATIONS', 52),   -- UNIT_DISBANDED
	('ICON_EFV_NOTIF_REVERTED',        'ICON_ATLAS_NOTIFICATIONS', 0),    -- GENERIC (1.0.4; was UNIT_CAPTURED)
	('ICON_EFV_NOTIF_REQUEST_FAILED',  'ICON_ATLAS_NOTIFICATIONS', 0),    -- GENERIC
	('ICON_EFV_NOTIF_LAPSE_CANCELLED', 'ICON_ATLAS_NOTIFICATIONS', 84),   -- DIPLOMATIC_PROMISE_TO_KEPT
	('ICON_EFV_NOTIF_LAPSE_PAUSED',    'ICON_ATLAS_NOTIFICATIONS', 9);    -- COMMAND_UNITS (0.5.1: "give it an order: recall")
