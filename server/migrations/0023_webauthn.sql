-- Passkey sign-in to the AZET Pass account (spass-092). public_key is the passkey's public key as a JWK; with PRF on
-- (prf_status 0) the client also stores its user key wrapped by the passkey's PRF key (encrypted_* — never readable
-- here). Challenges are used once and live five minutes.
CREATE TABLE IF NOT EXISTS webauthn_credentials (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    credential_id TEXT NOT NULL UNIQUE,
    public_key TEXT NOT NULL,
    alg INTEGER NOT NULL,
    counter INTEGER NOT NULL DEFAULT 0,
    prf_status INTEGER NOT NULL DEFAULT 2,
    encrypted_user_key TEXT,
    encrypted_public_key TEXT,
    encrypted_private_key TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_webauthn_credentials_user ON webauthn_credentials(user_id);
CREATE TABLE IF NOT EXISTS webauthn_challenges (
    token TEXT PRIMARY KEY NOT NULL,
    user_id TEXT,
    challenge TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL
);
