-- The backfilled runtime owners are not reverted: they are the row's
-- real owner, not a derived value, and dropping them would make every
-- runtime ownerless again (and therefore unusable in the picker).
ALTER TABLE daemon_token DROP COLUMN IF EXISTS owner_id;
