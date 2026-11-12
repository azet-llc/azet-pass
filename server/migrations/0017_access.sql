-- AZET Pass teams: AI agent members, access that runs out, and an access log that cannot be quietly edited.
-- agent = 1 marks a member account driven by an AI agent; what it reads is written to org_events.
-- access_until: after this moment the member gets no team items and no team key (NULL = no end date).
ALTER TABLE org_members ADD COLUMN agent INTEGER NOT NULL DEFAULT 0;
ALTER TABLE org_members ADD COLUMN access_until TEXT;
-- What the organizer's device last checked: an EncString (team key) of {seq, hash}. The server cannot read or forge it.
ALTER TABLE organizations ADD COLUMN log_checkpoint TEXT;

-- One row per access. hash = SHA-256(prev hash + this row's fields), so removing or changing a row breaks every
-- hash after it. kind: read | write | delete | grant | revoke.
CREATE TABLE IF NOT EXISTS org_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    org_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    cipher_id TEXT,
    count INTEGER NOT NULL DEFAULT 1,
    detail TEXT,
    created_at TEXT NOT NULL,
    prev TEXT NOT NULL,
    hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_org_events_org ON org_events(org_id, seq);

DROP VIEW IF EXISTS cipher_access;
CREATE VIEW cipher_access AS
    SELECT c.id AS cipher_id, c.user_id AS user_id, 1 AS can_edit, c.travel_safe AS travel_safe
      FROM ciphers c WHERE c.organization_id IS NULL AND c.user_id IS NOT NULL
    UNION ALL
    SELECT c.id, m.user_id, 1,
           COALESCE((SELECT MAX(col.travel_safe) FROM collection_ciphers cc JOIN collections col ON col.id = cc.collection_id WHERE cc.cipher_id = c.id), 0)
      FROM ciphers c JOIN org_members m ON m.org_id = c.organization_id AND m.status = 2 AND m.access_all = 1
       AND (m.access_until IS NULL OR m.access_until > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    UNION ALL
    SELECT cc.cipher_id, m.user_id, 1 - cm.read_only, col.travel_safe
      FROM collection_ciphers cc
      JOIN collections col ON col.id = cc.collection_id
      JOIN collection_members cm ON cm.collection_id = cc.collection_id
      JOIN org_members m ON m.id = cm.member_id AND m.status = 2 AND m.access_all = 0
       AND (m.access_until IS NULL OR m.access_until > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
