-- Which version of the AZET Pass terms and privacy policy each account accepted, and when (spass-005). The current
-- version is decided in AZET_CLIENT_CONFIG ("terms": {"version", "url"}); apps ask again when the two differ.
ALTER TABLE users ADD COLUMN terms_version TEXT;
ALTER TABLE users ADD COLUMN terms_accepted_at TEXT;
