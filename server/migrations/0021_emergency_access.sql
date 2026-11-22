-- Emergency access (spass-271): a person names a trusted contact who may ask for their vault; after a wait the
-- person did not stop, the contact can view it (type 0) or take the account over (type 1).
-- status: 0 invited, 1 accepted, 2 confirmed, 3 recovery asked, 4 recovery approved.
-- key_encrypted: the grantor's user key wrapped by the grantor's device with the grantee's public key (RSA).
CREATE TABLE IF NOT EXISTS emergency_access (
    id TEXT PRIMARY KEY NOT NULL,
    grantor_id TEXT NOT NULL,
    grantee_id TEXT,
    grantee_email TEXT, -- the invited address, until the contact accepts
    key_encrypted TEXT,
    type INTEGER NOT NULL,
    status INTEGER NOT NULL DEFAULT 0,
    wait_time_days INTEGER NOT NULL,
    recovery_initiated_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (grantor_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (grantee_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_emergency_access_grantor ON emergency_access(grantor_id);
CREATE INDEX IF NOT EXISTS idx_emergency_access_grantee ON emergency_access(grantee_id);
CREATE INDEX IF NOT EXISTS idx_emergency_access_email ON emergency_access(grantee_email);
CREATE INDEX IF NOT EXISTS idx_emergency_access_status ON emergency_access(status);
