-- The id (not the key) of an account's current user key, as 2026.9 clients record it. It is handed back in the sync;
-- without it those clients ask to record it again after every sync.
ALTER TABLE users ADD COLUMN user_key_id TEXT;
