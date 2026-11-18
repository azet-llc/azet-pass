# AZET Pass threat model

Scope: the sync server at `https://pass.azet.io` (Cloudflare Worker `azet-pass`, D1 `azet-pass`, KV, Durable Objects; code in `server/`) and the clients that talk to it (Bitwarden GPL-3.0 clients, rebranded). Written 2026-10-06.

## The promise

The server never holds anything that opens a vault. Every item field (name, username, password, notes, URIs, TOTP secret, card and identity fields, attachments, Send contents, folder names) is encrypted on the device before it leaves, with keys the server never receives. Proof: `server/test/e2ee.sh` (local) and `server/test/e2ee-live.sh` (production) store an item through the official `bw` CLI and search every byte on the wire and in D1 for the master password and each field; the count must be 0, and a control (the account email, which the server is meant to see) must be found.

## Keys (unchanged from Bitwarden)

| Key | Made where | What the server gets |
|---|---|---|
| Master password | in the person's head | nothing |
| Master key = PBKDF2-SHA256(master password, email, 600,000) or Argon2id | on the device | nothing |
| Master password hash = PBKDF2(master key, master password, 1) | on the device | the hash, which the server hashes again with its own salt and PBKDF2 (`password_salt`, `password_iterations`) before storing |
| User key (64 random bytes: AES-256 + HMAC-SHA256) | on the device | only wrapped by the stretched master key (`users.key`, EncString type 2) |
| RSA-2048 key pair | on the device | public key in clear, private key wrapped by the user key |
| Item fields | on the device | EncString type 2 under the user key or a per-item key |

## What the server does see

- Email address (login name and KDF salt), account creation and update times.
- KDF type and parameters (needed by every client before login).
- The doubly hashed master password hash.
- Encrypted keys and encrypted items, their count, size, type (login, card, identity, note, SSH key), folder membership, favourite flag, revision and deletion times. Item type and counts are metadata the server can read.
- Devices: identifier (random, made by the client), name (e.g. "Chrome", "macOS"), type, refresh token, push token if push is on.
- `auth_requests.request_ip` for "log in with device" requests (shown to the approving device, as in Bitwarden).
- The AZET licence key the account entered (`users.azet_license`), its last status and expiry. The key unlocks Premium only; it opens no vault data.
- Request IP and user agent in Cloudflare's own request logs (not stored in D1).
- Master password hint, if the person set one, in clear (Bitwarden stores it the same way). It is never returned to anyone: `POST /api/accounts/password-hint` answers the same sentence for every address (upstream warden-worker returned the hint to whoever asked; closed here).

## Attackers and what they get

| Attacker | Gets | Does not get | Mitigation |
|---|---|---|---|
| Someone who dumps D1 or KV (Cloudflare insider, stolen API key) | everything in "What the server does see" | any item plaintext | offline guessing of a weak master password: client KDF 600,000 PBKDF2 or Argon2id, then the server's own PBKDF2 on top. The client requires a 12-character minimum (Bitwarden default) |
| A network attacker | nothing beyond TLS metadata | — | Cloudflare TLS; Bitwarden clients refuse http URLs |
| Online password guessing | — | — | `LOGIN_RATE_LIMITER` 5 per minute per email or IP; constant-ish delay for unknown accounts (`LOGIN_MISSING_USER_DELAY_MS`) |
| Account enumeration | whether an address has an account (prelogin returns default KDF for unknown addresses, but register says "already exists") | — | accepted, as in Bitwarden |
| A malicious or compromised server operator | can change the web vault JavaScript it serves and capture the master password typed into it | — | **the weak point.** The installed clients (browser extension, desktop, Android, iOS) ship their code inside the signed package and do not load code from the server, so a server compromise does not reach them. The web vault served by this Worker is a convenience; the apps are the trusted path. Today `public/web-vault` is empty in production, so no code is served from the server at all |
| A malicious server sending crafted ciphertext or keys | could try key-substitution: when an organizer hands the shared-vault key to a new member, the server could present a public key it controls instead of the member's | — | the organizer does not trust the key the server shows. The member reads the fingerprint of their own public key (20 hex characters, shown on their device) to the organizer over a channel the server does not carry, and the organizer hands the vault key over only when it matches (`server/gw/team.html`, `server/scripts/team.mjs`; covered by `server/test/team.sh`). A member who skips the check gets no protection against this server-side attack |
| Licence service compromise (suite-api) | could grant or remove Premium | vault data (it never receives any) | the Pass server sends suite-api only the key, the account id and `pass` |
| Lost master password | — | — | nobody can recover the vault, including AZET. The hint is not emailed. Stated in the hint answer |

## Out of scope / not built

Emergency access, SSO, Key Connector, an admin panel, and mail for the password hint or new-device notices. The only mail this service sends is the sign-up confirmation link (`server/src/signup.js`).

Built since the first version of this document: shared vaults for a family or a team, including accounts for AI agents whose access can be limited in time and whose reads and changes are recorded (`server/migrations/0014`–`0017`). What the server learns from sharing: who is a member of which shared vault, when an item was handed over, changed or deleted, and how many — never an item's contents.

## Connecting an AI: one item at a time

The owner's account holds everything, encrypted with keys only the owner's devices have. An AI is meant to work from its own account, joined to a shared vault, where it receives only the items the owner moved there, one by one.

- **Where the line is.** It is the server boundary and the encryption, not a rule file on the AI's machine: an item that was not shared is not sent to the AI account at all, and the AI account has no key that opens it. An AI process that misbehaves can read what was shared with it and nothing else.
- **What the line depends on.** It holds only for an AI that does not have the owner's master password or an unlocked owner session. A machine where the owner's password sits in a key store the AI can read, or where the desktop app is signed in to the owner's account and unlocked for AI use, gives that AI the whole vault; the shared vault then limits nothing. One-at-a-time is real once the owner's password is known to the owner alone and each AI machine is signed in with the AI account.
- **"Randomised".** There is no home-made scrambling layer. Names, values and notes are AES-256 ciphertext with a random IV on the server; what an AI works with for anything not shared is a name or reference, never a value.
- **Giving one.** In the vault: item menu → Assign to collections. Or add it on pass.azet.io/team. The item is re-encrypted on the owner's device with the shared vault's key.
- **Taking one back.** pass.azet.io/team → the login → Stop sharing (`PUT /api/ciphers/{id}/unshare`): re-encrypted on the owner's device back to the owner's own key; members stop receiving it on their next sync. Turning an AI account's access off, or removing it from the vault, stops everything at once.
- **What cannot be undone.** A value an AI account has already received may have been kept by it, and a removed member has seen the shared vault's key. Taking back stops future delivery; a secret that mattered is changed at its source. The shared vault's key is not rotated when a member is removed (not built).
- **Record.** Each time an AI account receives shared items, and each change of its access, is a row in the hash-chained access log the organizer's device verifies with the vault key.

### On a computer that runs AI agents (AZET Desktop: "Give AI agents only what I share")

AZET Desktop holds two sign-ins. The person's own: its key is sealed by the computer's keychain and, with this setting on, is never written where another program can read it. The AI account's: its session is the readable one, and it is what agents, `azet-desktop pass …` and the browser's login typing use.

- **Asking for one.** An agent runs `azet-desktop pass share --name X`. The app shows the person that exact name (Touch ID) and, on approval, uses the sealed key for one command that moves the item into the shared vault. Refusal moves nothing. A key that was not given answers "Not shared", never "unlock".
- **Taking one back.** `azet-desktop pass unshare --name X`: a copy in the person's own vault, checked equal, then the shared one is removed.
- **What an agent cannot do there.** Save, import or remove (those belong to the person's vault), or loosen the setting: leaving it needs the person's approval, and deleting the AI account's folder leaves readers with nothing to read (they do not fall back to the person's vault).
- **Limits found in review (2026-11-19), not closed.** A program of the same user that copied the person's session while it was still readable (before the setting was turned on, or during free use) keeps the vault: turning the setting on does not make a new session, so sign out and in again first. The sealed piece can be put back from an older copy, which returns the app to the earlier setting at its next start. A program that can replace the vault tool the app runs (`azet-pass/bin/bw`, or the system copy) receives the person's key at the next share the person approves. All three need a program already running as the same user; none is reachable from the network.
- **Limits.** (1) While the app runs the one command for a share or a take-back, the person's key is in that process's environment for a few seconds; treat it as readable by other programs of the same user during that window (not measured conclusively). (2) If the sealed piece is deleted, the person is signed out; signing in again starts in the default setting, without the AI account, until they connect it again. (3) Everything in "What the line depends on" above: a master password an AI can read makes all of this moot.

## How to re-check

```sh
bash server/test/e2ee.sh        # local Worker + official bw CLI + recording proxy + local D1 search
bash server/test/e2ee-live.sh   # production: bw CLI against pass.azet.io, remote D1 export search, test account deleted
bash server/test/team.sh         # AI account: gets only what was shared (3b, 4a), new share / removal / take-back reach a signed-in agent (4b2, 4b3), expiry and off (4e–4g), log (4c, 4d)
bash server/test/desktop-shared.sh # AZET Desktop: sign-in, AI account connected, one key shared / refused / taken back, owner key never readable
bash server/test/premium.sh     # Premium follows the AZET licence (stub licence service)
(cd server && cargo test --lib) # premium rule: active/trial, expiry, 7-day offline grace
```
