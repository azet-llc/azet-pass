-- A member sees a shared vault's items only when the membership and the vault belong to the same family.
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
      JOIN org_members m ON m.id = cm.member_id AND m.org_id = col.org_id AND m.status = 2 AND m.access_all = 0
       AND (m.access_until IS NULL OR m.access_until > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
