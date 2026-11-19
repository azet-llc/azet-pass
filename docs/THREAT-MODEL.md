# AZET Pass threat model

Scope: the sync server at `https://pass.azet.io` (Cloudflare Worker `azet-pass`, D1 `azet-pass`, KV, Durable Objects; code in `server/`) and the clients that talk to it (Bitwarden GPL-3.0 clients, rebranded). Written 2026-10-06.

## The promise

The server never holds anything that opens a vault. Every item field (name, username, password, notes, URIs, TOTP secret, card and identity fields, attachments, Send contents, folder names) is encrypted on the device before it leaves, with keys the server never receives. Proof: `server/test/e2ee.sh` (local) and `server/test/e2ee-live.sh` (production) store an item through the official `bw` CLI and search every byte on the wire and in D1 for the master password and each field; the count must be 0, and a control (the account email, which the server is meant to see) must be found.

The server also enforces it (2026-11-19): a stored item or folder name whose text is not ciphertext is answered 400 (`CipherData::new`, `is_ciphertext` in `server/src/models/cipher.rs`), so a client bug, a script or a tool cannot leave readable data in D1. Checked on production the same day: all 4,656 items held ciphertext only in every name, username, password, note, URI, TOTP, card and custom field; the official `bw` CLI still saved an item and a folder; a readable name sent straight to `/api/ciphers` and `/api/folders` got 400.

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
- No master password hint: since 2026-11-19 the server does not keep the hint a client sends (Bitwarden stores it in clear), and the one that was stored was erased. Nothing is returned either: `POST /api/accounts/password-hint` answers the same sentence for every address (upstream warden-worker returned the hint to whoever asked; closed here).

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
- **What cannot be undone.** A value an AI account has already received may have been kept by it, and a removed member has seen the shared vault's key. Taking back stops future delivery; a secret that mattered is changed at its source. The vault's key is changed when a member is removed or leaves (next section), so what they kept opens nothing saved afterwards.
- **Record.** Each time an AI account receives shared items, and each change of its access, is a row in the hash-chained access log the organizer's device verifies with the vault key.

### Changing a shared vault's key (2026-11-19)

A member who is removed, or who leaves, has seen the vault key and the vault's RSA private key (every member can fetch it). The organizer's device then makes a new key and a new key pair, opens everything the old ones sealed and seals it again, and sends it in one request (`server/src/handlers/rotate.rs`, `rotate` in `server/scripts/team.mjs` and `server/gw/team.html`).

- **When.** Removing a member on pass.azet.io/team or with `team.mjs remove` changes the key at once. A member who leaves on their own marks the change as due, and it is done the next time the organizer opens the team page (or runs `team.mjs rotate`). Turning access off and an access period running out do not change the key (the member is still in the vault and can be turned on again); the organizer can run `rotate` after those.
- **What is sealed again.** The vault key wrapped for every member who holds it (suspended ones too), the vault's key pair, each member's account-recovery key (opened with the old private key, wrapped to the new public key), vault names, every item including the trash, file names and file keys, and the access-log checkpoint. An item that had its own key gets a new item key, so a later edit is not readable with a key someone kept. A file's contents are not encrypted again: someone who kept a file's key and its ciphertext keeps that file.
- **All or nothing.** The server checks that the request names exactly the members, vaults, items and files the vault holds, that no item changed since the device read it, and that every value is ciphertext; then it writes everything in one D1 batch. Anything missing: 400, nothing changed. Before sending, the device opens each newly sealed value again and compares it with what it opened from the old one.
- **Who gets the new key.** Only public keys the organizer confirmed by fingerprint. Their fingerprints (SHA-256 of the public key) are kept next to the vault, sealed with the vault key (`organizations.member_pins`), so the server cannot swap a public key at a key change. A member whose public key no longer matches is not handed the key and is confirmed by fingerprint again. The organizer's own key is wrapped to the public key made from the private key on the device, never to one the server shows. A vault made before fingerprints were kept has none: at its first key change its confirmed members are taken as the server shows them, once.
- **Devices that still hold the old key.** A device that has not synced would save data nobody could open. Each vault has a key generation, a sync records the generation a device was handed (`org_key_seen`), and a save into the vault (item, share, vault name, file) from a device that has not been handed the current one is answered 400 "Sync this device, then try again". A vault whose key was never changed asks nothing.
- **Limits.** Two organizers changing the key in the same second are not excluded by a lock (the second request is refused by the generation check in almost every interleaving, but the check and the write are not one statement). What a removed member already read stays read: a secret that mattered is changed at its source.
- **Checked by** `server/test/team.sh` 7a–7e (a partial request changes nothing; the leaver's key opens no item afterwards; a device with the old key is refused until it syncs; the organizer and the remaining member read everything with the official `bw` CLI), `server/test/family.mjs` 10 (file key, file name and recovery key), `server/test/team-page.sh` (the team page in a headless browser: remove with two taps; a member leaves and the key changes when the organizer opens the page).

### On a computer that runs AI agents (AZET Desktop: "Give AI agents only what I share")

AZET Desktop holds two sign-ins. The person's own: its key is sealed by the computer's keychain and, with this setting on, is never written where another program can read it. The AI account's: its session is the readable one, and it is what agents, `azet-desktop pass …` and the browser's login typing use.

- **Asking for one.** An agent runs `azet-desktop pass share --name X`. The app shows the person that exact name (Touch ID) and, on approval, uses the sealed key for one command that moves the item into the shared vault. Refusal moves nothing. A key that was not given answers "Not shared", never "unlock".
- **Taking one back.** `azet-desktop pass unshare --name X`: a copy in the person's own vault, checked equal, then the shared one is removed.
- **What an agent cannot do there.** Save, import or remove (those belong to the person's vault), or loosen the setting: leaving it needs the person's approval, and deleting the AI account's folder leaves readers with nothing to read (they do not fall back to the person's vault).
- **Limits found in review (2026-11-19), not closed.** A program of the same user that copied the person's session while it was still readable (before the setting was turned on, or during free use) keeps the vault: turning the setting on does not make a new session, so sign out and in again first. The sealed piece can be put back from an older copy, which returns the app to the earlier setting at its next start. (Closed since: a swapped vault tool — the app now runs only its pinned copy, checked by SHA-256, for any command that carries the person's key.) Both need a program already running as the same user; none is reachable from the network.
- **Limits.** (1) While the app runs the one command for a share or a take-back, the person's key is in that process's environment for a few seconds; treat it as readable by other programs of the same user during that window (not measured conclusively). (2) If the sealed piece is deleted, the person is signed out; signing in again starts in the default setting, without the AI account, until they connect it again. (3) Everything in "What the line depends on" above: a master password an AI can read makes all of this moot.

## How to re-check

```sh
bash server/test/e2ee.sh        # local Worker + official bw CLI + recording proxy + local D1 search
bash server/test/e2ee-live.sh   # production: bw CLI against pass.azet.io, remote D1 export search, test account deleted
bash server/test/team-page.sh    # the team page changes a shared vault's key when a member is removed or leaves (headless browser)
bash server/test/team.sh         # AI account: gets only what was shared (3b, 4a), new share / removal / take-back reach a signed-in agent (4b2, 4b3), expiry and off (4e–4g), log (4c, 4d)
bash server/test/desktop-shared.sh # AZET Desktop: sign-in, AI account connected, one key shared / refused / taken back, owner key never readable
bash server/test/premium.sh     # Premium follows the AZET licence (stub licence service)
(cd server && cargo test --lib) # premium rule: active/trial, expiry, 7-day offline grace
```
