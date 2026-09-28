-- EFV_Bad.sql (BROKEN fixture)
-- Types row with KIND_NOTIFICATION but no Notifications row -> sql-notification
INSERT INTO Types (Type, Kind) VALUES ('EFV_NOTIF_ORPHAN', 'KIND_NOTIFICATION');

-- unknown Kind -> foreign key violation at the end of the load -> sql-fk
INSERT INTO Types (Type, Kind) VALUES ('EFV_BAD_KIND', 'KIND_NOPE');

-- unknown column -> sql
INSERT INTO Notifications (NotificationType, SeverityType, NoSuchColumn) VALUES ('EFV_NOTIF_X', 'LOW', 1);

-- unknown table -> sql
INSERT INTO NoSuchTable (A) VALUES (1);

-- CHECK constraint (ExpiresEndOfTurn IN (0,1)) -> sql
INSERT INTO Notifications (NotificationType, ExpiresEndOfTurn) VALUES ('EFV_NOTIF_ORPHAN2', 5);
