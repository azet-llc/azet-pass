-- Changing a shared vault's key (server/src/handlers/rotate.rs). key_gen counts the changes; rotate_due is set when a
-- member is removed or leaves, until the organizer's device has changed the key; org_key_seen is the generation each
-- device last received in a sync, so a device still holding an older key cannot write into the vault.
ALTER TABLE organizations ADD COLUMN key_gen INTEGER NOT NULL DEFAULT 1;
ALTER TABLE organizations ADD COLUMN rotate_due INTEGER NOT NULL DEFAULT 0;
-- member_pins: the public-key fingerprint of each member the organizer confirmed, sealed with the vault key, so a
-- key change hands the new key only to the public keys that were checked by fingerprint (the server cannot swap one).
ALTER TABLE organizations ADD COLUMN member_pins TEXT;
CREATE TABLE IF NOT EXISTS org_key_seen (device TEXT NOT NULL, org_id TEXT NOT NULL, gen INTEGER NOT NULL, PRIMARY KEY (device, org_id));
