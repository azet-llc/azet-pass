-- AZET Pass families: Bitwarden-shaped organizations, members and collections (a collection = a shared vault).
-- The server only stores keys wrapped by the clients: org key per member (akey, RSA to the member's public key),
-- user key for account recovery (reset_password_key, RSA to the org public key). Nothing here is plaintext.
CREATE TABLE IF NOT EXISTS organizations (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    billing_email TEXT,
    public_key TEXT,
    private_key TEXT, -- org private key encrypted with the org key
    seats INTEGER NOT NULL DEFAULT 5,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- status: 0 invited, 1 accepted, 2 confirmed, -1 revoked (suspended)
-- type: 0 owner (family organizer), 1 admin (family organizer), 2 member, 5 guest (one shared vault only)
CREATE TABLE IF NOT EXISTS org_members (
    id TEXT PRIMARY KEY NOT NULL,
    org_id TEXT NOT NULL,
    user_id TEXT,
    email TEXT NOT NULL,
    display_name TEXT,
    status INTEGER NOT NULL DEFAULT 0,
    type INTEGER NOT NULL DEFAULT 2,
    access_all INTEGER NOT NULL DEFAULT 0,
    akey TEXT,
    reset_password_key TEXT,
    invite_token TEXT,
    invited_by TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE (org_id, email)
);
CREATE INDEX IF NOT EXISTS idx_org_members_user ON org_members(user_id);

CREATE TABLE IF NOT EXISTS collections (
    id TEXT PRIMARY KEY NOT NULL,
    org_id TEXT NOT NULL,
    name TEXT NOT NULL, -- encrypted with the org key
    travel_safe INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS collection_members (
    collection_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    read_only INTEGER NOT NULL DEFAULT 0,
    hide_passwords INTEGER NOT NULL DEFAULT 0,
    manage INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (collection_id, member_id),
    FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE,
    FOREIGN KEY (member_id) REFERENCES org_members(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS collection_ciphers (
    collection_id TEXT NOT NULL,
    cipher_id TEXT NOT NULL,
    PRIMARY KEY (collection_id, cipher_id),
    FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE,
    FOREIGN KEY (cipher_id) REFERENCES ciphers(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_collection_ciphers_cipher ON collection_ciphers(cipher_id);

-- Travel Mode: while users.travel_mode = 1 only items marked travel_safe (or in travel_safe collections) sync.
ALTER TABLE users ADD COLUMN travel_mode INTEGER NOT NULL DEFAULT 0;
ALTER TABLE ciphers ADD COLUMN travel_safe INTEGER NOT NULL DEFAULT 0;

-- Every cipher a user may read (can_edit = 0 for read-only shared vaults). All cipher queries go through this.
CREATE VIEW IF NOT EXISTS cipher_access AS
    SELECT c.id AS cipher_id, c.user_id AS user_id, 1 AS can_edit, c.travel_safe AS travel_safe
      FROM ciphers c WHERE c.organization_id IS NULL AND c.user_id IS NOT NULL
    UNION ALL
    SELECT c.id, m.user_id, 1,
           COALESCE((SELECT MAX(col.travel_safe) FROM collection_ciphers cc JOIN collections col ON col.id = cc.collection_id WHERE cc.cipher_id = c.id), 0)
      FROM ciphers c JOIN org_members m ON m.org_id = c.organization_id AND m.status = 2 AND m.access_all = 1
    UNION ALL
    SELECT cc.cipher_id, m.user_id, 1 - cm.read_only, col.travel_safe
      FROM collection_ciphers cc
      JOIN collections col ON col.id = cc.collection_id
      JOIN collection_members cm ON cm.collection_id = cc.collection_id
      JOIN org_members m ON m.id = cm.member_id AND m.status = 2 AND m.access_all = 0;
