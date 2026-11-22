-- New-device approval (spass-186), off by default: with users.device_approval = 1 a password sign-in from a device
-- the account has never used waits until a device already signed in approves it. One row per waiting device;
-- approved_at is set by the approving device and the row goes when the new device signs in or is denied.
ALTER TABLE users ADD COLUMN device_approval INTEGER NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS device_approvals (
    user_id TEXT NOT NULL,
    identifier TEXT NOT NULL,
    name TEXT NOT NULL,
    type INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    approved_at TEXT,
    PRIMARY KEY (user_id, identifier),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
