-- ===========================================================================
-- EFV_Notifications.sql  (modinfo InGameActions UpdateDatabase EFV_Data)
-- Owner: WP1.6. PLAN 4.1, DECISIONS D9, orchestrator call 2026-09-28
-- (EFV_NOTIF_LAPSE_CANCELLED), designer ruling "Lapsed Volunteers on valid
-- land" 2026-09-28 (EFV_NOTIF_LAPSE_PAUSED, 0.5.1).
--
-- One Types row (Kind 'KIND_NOTIFICATION') and one Notifications row per
-- type. Columns per GAME\Base\Assets\Gameplay\Data\Schema\01_GameplaySchema.sql
-- (checked against DebugGameplay.sqlite): NotificationType, Message, Summary,
-- SeverityType, ExpiresEndOfTurn, ExpiresEndOfNextTurn, SubType, AutoNotify,
-- GroupType, Icon, AutoActivate, VisibleInUI, ShowIconSinglePlayer.
--
-- - Message/Summary: NULL. Text is supplied at send time from
--   LOC_<type>_MESSAGE / LOC_<type>_SUMMARY (EFV_Notify.Flush, PLAN 2.7).
-- - GroupType: NULL (no shipped row uses "USER"; spike harness note).
-- - ExpiresEndOfTurn 0 = persists until dismissed or re-sent (D9; the
--   gameplay side re-sends GRACE/MUTINY every turn with AlwaysUnique).
--   0.7.2 designer policy: VEF never clears its notifications on a turn
--   basis, only when what they warn about is over (EFV_Tracker SweepStale:
--   GRACE / MUTINY, LAPSE_PAUSED, ACCESS_ / VOLUNTEER_LAPSE, EXPIRY_SOON,
--   SPAWN_BLOCKED, REROUTED, by record) or when the player dismisses them
--   (MUTINY_DEATH, UNIT_LOST, MERGED, REVERTED: losses, kept until read).
--   ExpiresEndOfTurn 1 stays only on pure one-off news that needs no action:
--   DEPARTED, ARRIVED, RETURNING, RETURNED, ENTRUSTED, REQUEST_FAILED,
--   LAPSE_CANCELLED.
-- - AutoActivate 1 on GRACE / MUTINY / MUTINY_DEATH (D9 map focus): the
--   default activate handler only calls LookAtPlot (NotificationPanel.lua:
--   642-713), it never dismisses. Gameplay also sets data.AlwaysAutoActivate
--   (the DB flag alone is ignored in MP below VERY_HIGH,
--   BlackDeathScenario_Support.lua:100).
-- - Icon: a shipped IconDefinitions name, so the icon renders even if the
--   ICON_EFV_NOTIF_* alias rows of EFV_Icons.sql do not (NEW-VERIFY T21).
--   If the engine ignores this column (Icon is NULL on every shipped row),
--   NotificationPanel.lua:793 falls back to "ICON_" .. NotificationType,
--   i.e. the EFV_Icons.sql alias, which points at the SAME atlas cell.
--   Keep the two files in step.
--
-- NotificationType            Recipients                          Severity   Expires  AutoAct  Icon cell (ICON_ATLAS_NOTIFICATIONS)
-- EFV_NOTIF_DEPARTED          sender                              LOW        1        0        9   COMMAND_UNITS
-- EFV_NOTIF_ARRIVED           both                                MID        1        0        9   COMMAND_UNITS
-- EFV_NOTIF_SPAWN_BLOCKED     sender                              MID        0        0        110 CITY_BESIEGED_BY_OTHER_PLAYER
-- EFV_NOTIF_EXPIRY_SOON       recipient, sender (EXP/CS only)     MID        0        0        85  DIPLO_DEAL_EXPIRED
-- EFV_NOTIF_GRACE             recipient, sender                   HIGH       0        1        12  DECLARE_WAR (D9)
-- EFV_NOTIF_MUTINY            recipient, sender                   VERY_HIGH  0        1        66  REBELLION (D9, WP2.2)
-- EFV_NOTIF_MUTINY_DEATH      both                                VERY_HIGH  0        1        53  UNIT_LOST
-- EFV_NOTIF_RETURNING         sender                              LOW        1        0        9   COMMAND_UNITS
-- EFV_NOTIF_RETURNED          sender                              MID        1        0        9   COMMAND_UNITS
-- EFV_NOTIF_REROUTED          sender                              MID        0        0        59  CITY_LOST
--   REROUTED: retired 2026-09-30 (transit cancel): no longer sent; row kept so
--   notifications stored in older saves still resolve. The transit cancel
--   uses text variants of ARRIVED / RETURNING / RETURNED (_CANCELLED, _KEPT).
-- EFV_NOTIF_VOLUNTEER_LAPSE   sender (lapse reason WAR)           HIGH       0        0        15  MAKE_PEACE
-- EFV_NOTIF_ENTRUSTED         both                                MID        1        0        11  CONSIDER_RAZE_CITY
-- EFV_NOTIF_ACCESS_LAPSE      sender (lapse reason PARTNER)       HIGH       0        0        122 DIPLO_ALLIANCE_EXPIRED
-- EFV_NOTIF_UNIT_LOST         sender (and recipient when NO_CITY) MID        0        0        53  UNIT_LOST
-- EFV_NOTIF_MERGED            both                                MID        0        0        52  UNIT_DISBANDED
-- EFV_NOTIF_REVERTED          both                                HIGH       0        0        55  UNIT_CAPTURED
-- EFV_NOTIF_REQUEST_FAILED    requester                           LOW        1        0        0   GENERIC
-- EFV_NOTIF_LAPSE_CANCELLED   sender, recipient if human          MID        1        0        84  DIPLOMATIC_PROMISE_TO_KEPT
-- EFV_NOTIF_LAPSE_PAUSED      sender (lapsed VOL on valid land)   HIGH       0        0        9   COMMAND_UNITS
--
-- EFV_NOTIF_LAPSE_CANCELLED is the 18th type (not in PLAN 4.1; added by the
-- orchestrator call in DECISIONS.md). EFV_Config.NOTIF must gain
-- LAPSE_CANCELLED = "EFV_NOTIF_LAPSE_CANCELLED" (Config is not WP1.6's file).
-- EFV_NOTIF_LAPSE_PAUSED is the 19th type (0.5.1, INTERFACES note 29): sent
-- once when a lapsed Volunteer's countdown pauses on valid land (GRACE /
-- MUTINY are not re-sent while paused). ExpiresEndOfTurn 0: it stays while
-- the pause lasts; the tracker dismisses it once the pause ends.
-- ===========================================================================

INSERT INTO Types (Type, Kind) VALUES
	('EFV_NOTIF_DEPARTED',        'KIND_NOTIFICATION'),
	('EFV_NOTIF_ARRIVED',         'KIND_NOTIFICATION'),
	('EFV_NOTIF_SPAWN_BLOCKED',   'KIND_NOTIFICATION'),
	('EFV_NOTIF_EXPIRY_SOON',     'KIND_NOTIFICATION'),
	('EFV_NOTIF_GRACE',           'KIND_NOTIFICATION'),
	('EFV_NOTIF_MUTINY',          'KIND_NOTIFICATION'),
	('EFV_NOTIF_MUTINY_DEATH',    'KIND_NOTIFICATION'),
	('EFV_NOTIF_RETURNING',       'KIND_NOTIFICATION'),
	('EFV_NOTIF_RETURNED',        'KIND_NOTIFICATION'),
	('EFV_NOTIF_REROUTED',        'KIND_NOTIFICATION'),
	('EFV_NOTIF_VOLUNTEER_LAPSE', 'KIND_NOTIFICATION'),
	('EFV_NOTIF_ENTRUSTED',       'KIND_NOTIFICATION'),
	('EFV_NOTIF_ACCESS_LAPSE',    'KIND_NOTIFICATION'),
	('EFV_NOTIF_UNIT_LOST',       'KIND_NOTIFICATION'),
	('EFV_NOTIF_MERGED',          'KIND_NOTIFICATION'),
	('EFV_NOTIF_REVERTED',        'KIND_NOTIFICATION'),
	('EFV_NOTIF_REQUEST_FAILED',  'KIND_NOTIFICATION'),
	('EFV_NOTIF_LAPSE_CANCELLED', 'KIND_NOTIFICATION'),
	('EFV_NOTIF_LAPSE_PAUSED',    'KIND_NOTIFICATION');

INSERT INTO Notifications (NotificationType, SeverityType, ExpiresEndOfTurn, AutoActivate, Icon) VALUES
	('EFV_NOTIF_DEPARTED',        'LOW',       1, 0, 'ICON_NOTIFICATION_COMMAND_UNITS'),
	('EFV_NOTIF_ARRIVED',         'MID',       1, 0, 'ICON_NOTIFICATION_COMMAND_UNITS'),
	('EFV_NOTIF_SPAWN_BLOCKED',   'MID',       0, 0, 'ICON_NOTIFICATION_CITY_BESIEGED_BY_OTHER_PLAYER'),
	('EFV_NOTIF_EXPIRY_SOON',     'MID',       0, 0, 'ICON_NOTIFICATION_DIPLO_DEAL_EXPIRED'),
	('EFV_NOTIF_GRACE',           'HIGH',      0, 1, 'ICON_NOTIFICATION_DECLARE_WAR'),
	('EFV_NOTIF_MUTINY',          'VERY_HIGH', 0, 1, 'ICON_NOTIFICATION_REBELLION'),
	('EFV_NOTIF_MUTINY_DEATH',    'VERY_HIGH', 0, 1, 'ICON_NOTIFICATION_UNIT_LOST'),
	('EFV_NOTIF_RETURNING',       'LOW',       1, 0, 'ICON_NOTIFICATION_COMMAND_UNITS'),
	('EFV_NOTIF_RETURNED',        'MID',       1, 0, 'ICON_NOTIFICATION_COMMAND_UNITS'),
	('EFV_NOTIF_REROUTED',        'MID',       0, 0, 'ICON_NOTIFICATION_CITY_LOST'),
	('EFV_NOTIF_VOLUNTEER_LAPSE', 'HIGH',      0, 0, 'ICON_NOTIFICATION_MAKE_PEACE'),
	('EFV_NOTIF_ENTRUSTED',       'MID',       1, 0, 'ICON_NOTIFICATION_CONSIDER_RAZE_CITY'),
	('EFV_NOTIF_ACCESS_LAPSE',    'HIGH',      0, 0, 'ICON_NOTIFICATION_DIPLO_ALLIANCE_EXPIRED'),
	('EFV_NOTIF_UNIT_LOST',       'MID',       0, 0, 'ICON_NOTIFICATION_UNIT_LOST'),
	('EFV_NOTIF_MERGED',          'MID',       0, 0, 'ICON_NOTIFICATION_UNIT_DISBANDED'),
	('EFV_NOTIF_REVERTED',        'HIGH',      0, 0, 'ICON_NOTIFICATION_UNIT_CAPTURED'),
	('EFV_NOTIF_REQUEST_FAILED',  'LOW',       1, 0, 'ICON_NOTIFICATION_GENERIC'),
	('EFV_NOTIF_LAPSE_CANCELLED', 'MID',       1, 0, 'ICON_NOTIFICATION_DIPLOMATIC_PROMISE_TO_KEPT'),
	('EFV_NOTIF_LAPSE_PAUSED',    'HIGH',      0, 0, 'ICON_NOTIFICATION_COMMAND_UNITS');
