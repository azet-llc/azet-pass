import BitwardenSdk
import Foundation
import Observation

/// What a device remembers about the signed-in account between launches (no secrets that open the vault).
struct Account: Codable {
    var userId: String
    var email: String
    var name: String?
    var kdfIterations: UInt32
    var key: String          // user key wrapped by the account password (EncString)
    var privateKey: String   // private key wrapped by the user key (EncString)
    var publicKey: String?
    var refreshToken: String?
    var deviceId: String
}

/// A family the user belongs to (Bitwarden organization on the wire).
struct Family: Identifiable, Hashable {
    let id: String
    var name: String
    var role: Int            // 0 owner, 1 admin (both "family organizer"), 2 member, 5 guest
    var status: Int          // 0 invited, 1 accepted (waiting for the organizer), 2 confirmed
    var memberId: String
    var akey: String?
    var recoveryOn: Bool
    var isOrganizer: Bool { role <= 1 }
}

struct Member: Identifiable, Hashable {
    let id: String
    var userId: String?
    var email: String
    var name: String
    var role: Int
    var status: Int
    var publicKey: String?
    var inviteToken: String?
    var recoveryOn: Bool
    var vaults: [String: Bool]   // collection id → read only
}

final class Tokens: ClientManagedTokens, @unchecked Sendable {
    var access: String?
    func getAccessToken() async -> String? { access }
}

@MainActor @Observable
final class Session {
    enum Phase { case loading, welcome, locked, unlocked }
    var phase: Phase = .loading
    var account: Account?
    var items: [CipherListView] = []
    var vaults: [CollectionView] = []
    var folders: [FolderView] = []
    var families: [Family] = []
    var travelMode = false
    var lastSync: Date?
    var busy = false
    var banner: String?

    private(set) var ciphers: [String: Cipher] = [:]
    private var orgKeys: [String: String] = [:]   // family id → family key (base64), in memory only
    private var syncJSON: String?
    let tokens = Tokens()
    let api: API
    private(set) var client: Client

    init() {
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            Keychain.set(nil, for: "account"); Keychain.set(nil, for: "userKey"); SharedFiles.remove("sync.json")
        }
        let stored = Keychain.get("account").flatMap { try? JSONDecoder().decode(Account.self, from: Data($0.utf8)) }
        let device = stored?.deviceId ?? UUID().uuidString.lowercased()
        api = API(deviceId: device)
        client = Session.makeClient(tokens: tokens, device: device)
        account = stored
        api.refreshToken = stored?.refreshToken
        api.onTokens = { [weak self] access, refresh in
            Task { @MainActor in
                self?.tokens.access = access
                if var a = self?.account, let refresh { a.refreshToken = refresh; self?.account = a; self?.persist() }
            }
        }
        phase = stored == nil ? .welcome : .locked
    }

    static func makeClient(tokens: Tokens, device: String) -> Client {
        Client(tokenProvider: tokens, settings: ClientSettings(
            identityUrl: Config.server.appendingPathComponent("identity").absoluteString,
            apiUrl: Config.server.appendingPathComponent("api").absoluteString,
            userAgent: Config.userAgent, deviceType: Config.deviceType, deviceIdentifier: device,
            bitwardenClientVersion: Config.clientVersion, bitwardenPackageType: nil))
    }

    private func persist() {
        if let a = account, let d = try? JSONEncoder().encode(a) { Keychain.set(String(data: d, encoding: .utf8), for: "account") }
    }

    var kdf: Kdf { .pbkdf2(iterations: account?.kdfIterations ?? 600_000) }
    var biometricOn: Bool { Keychain.has("userKey") }

    // MARK: account

    struct Invite: Hashable, Codable {
        let familyId: String
        let memberId: String
        let token: String
        var email: String?
        var displayName: String?
        var familyName: String?
        var invitedBy: String?
    }

    /// Ask the server to mail a sign-up link (no account is made until the link is used).
    func requestSignupMail(email: String) async throws {
        try await api.raw("POST", "/identity/accounts/register/send-verification-email",
                          json: ["email": email.lowercased(), "name": NSNull(), "receiveMarketingEmails": false], auth: false)
    }

    /// New account. Proof of the address = the mailed link token, or a family invite for that exact address.
    func signUp(email raw: String, name: String, password: String, hint: String?, mailToken: String?, invite: Invite?) async throws {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let keys = try client.auth().makeRegisterKeys(email: email, password: password, kdf: .pbkdf2(iterations: 600_000))
        var body: [String: Any] = [
            "email": email, "name": name, "masterPasswordHash": keys.masterPasswordHash,
            "masterPasswordHint": hint ?? NSNull(), "key": keys.encryptedUserKey, "kdf": 0, "kdfIterations": 600_000,
            "userAsymmetricKeys": ["publicKey": keys.keys.public, "encryptedPrivateKey": keys.keys.private],
        ]
        if let invite { body["orgInviteToken"] = invite.token; body["organizationUserId"] = invite.memberId }
        if let mailToken { body["emailVerificationToken"] = mailToken }
        try await api.send("POST", "/identity/accounts/register", body, auth: false)
        try await signIn(email: email, password: password)
    }

    func signIn(email raw: String, password: String, code: String? = nil) async throws {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let pre = try await api.prelogin(email: email)
        let iterations = (pre["kdfIterations"] as? NSNumber)?.uint32Value ?? 600_000
        guard (pre["kdf"] as? Int ?? 0) == 0 else {
            throw APIError(status: 0, message: String(localized: "This account uses Argon2id. Change it to PBKDF2 in the web vault, then sign in here."))
        }
        let k = Kdf.pbkdf2(iterations: iterations)
        let hash = try await client.auth().hashPassword(email: email, password: password, kdfParams: k, purpose: .serverAuthorization)
        let t = try await api.token(email: email, hash: hash, twoFactorCode: code)
        tokens.access = api.accessToken
        let key = (t["Key"] ?? t["key"]) as? String ?? ""
        let pk = (t["PrivateKey"] ?? t["privateKey"]) as? String ?? ""
        let uid = Session.jwtSubject(api.accessToken) ?? ""
        account = Account(userId: uid, email: email, name: nil, kdfIterations: iterations, key: key, privateKey: pk,
                          publicKey: nil, refreshToken: api.refreshToken, deviceId: api.deviceId)
        persist()
        try await unlock(password: password)
    }

    static func jwtSubject(_ jwt: String?) -> String? {
        guard let part = jwt?.split(separator: ".").dropFirst().first else { return nil }
        var s = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["sub"] as? String
    }

    private func initCrypto(_ method: InitUserCryptoMethod) async throws {
        guard let a = account else { return }
        client = Session.makeClient(tokens: tokens, device: a.deviceId)
        try await client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
            userId: a.userId, kdfParams: kdf, email: a.email,
            accountCryptographicState: .v1(privateKey: a.privateKey), method: method, upgradeToken: nil))
    }

    func unlock(password: String) async throws {
        guard let a = account else { return }
        do {
            try await initCrypto(.masterPasswordUnlock(password: password, masterPasswordUnlock: MasterPasswordUnlockData(kdf: kdf, masterKeyWrappedUserKey: a.key, salt: a.email)))
        } catch {
            throw APIError(status: 0, message: String(localized: "That account password is not right."))
        }
        lastPasswordForFamily = password
        await afterUnlock()
    }

    /// Face ID unlock: the user key sits in the keychain behind biometry on this device only.
    func unlockWithBiometrics() async throws {
        guard let key = Keychain.get("userKey", prompt: String(localized: "Unlock AZET Pass")) else {
            throw APIError(status: 0, message: String(localized: "Face ID did not unlock. Type your account password."))
        }
        try await initCrypto(.decryptedKey(decryptedUserKey: key))
        await afterUnlock()
    }

    func setBiometrics(_ on: Bool) async {
        if on, let k = try? await client.crypto().getUserEncryptionKey() { Keychain.set(k, for: "userKey", biometric: true) }
        else { Keychain.set(nil, for: "userKey") }
    }

    private func afterUnlock() async {
        phase = .unlocked
        if let cached = SharedFiles.read("sync.json").flatMap({ String(data: $0, encoding: .utf8) }) { await apply(cached) }
        do {
            if tokens.access == nil { try await api.refresh(); tokens.access = api.accessToken }
            try await sync()
        } catch { banner = error.localizedDescription }
    }

    /// Kept only until the first family join enrols recovery (the server re-checks the account password then).
    private var lastPasswordForFamily: String?

    func lock() {
        client = Session.makeClient(tokens: tokens, device: account?.deviceId ?? "")
        items = []; vaults = []; ciphers = [:]; orgKeys = [:]; families = []; lastPasswordForFamily = nil
        phase = .locked
    }

    func signOut() {
        lock()
        Keychain.set(nil, for: "account"); Keychain.set(nil, for: "userKey")
        SharedFiles.remove("sync.json")
        account = nil; tokens.access = nil; api.accessToken = nil; api.refreshToken = nil
        phase = .welcome
    }

    // MARK: sync

    func sync() async throws {
        let data = try await api.raw("GET", "/api/sync?excludeDomains=true")
        let json = String(data: data, encoding: .utf8) ?? "{}"
        SharedFiles.write(data, "sync.json")
        await apply(json)
        lastSync = Date()
        Task { await PasskeyBridge(session: self).refreshIdentityStore() }
    }

    private func apply(_ json: String) async {
        syncJSON = json
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let profile = obj["profile"] as? [String: Any] ?? [:]
        if var a = account {
            a.name = profile["name"] as? String
            if let k = profile["key"] as? String { a.key = k }
            if let pk = profile["privateKey"] as? String { a.privateKey = pk }
            a.publicKey = ((profile["accountKeys"] as? [String: Any])?["publicKeyEncryptionKeyPair"] as? [String: Any])?["publicKey"] as? String ?? a.publicKey
            account = a; persist()
        }
        travelMode = profile["travelMode"] as? Bool ?? false
        let orgs = profile["organizations"] as? [[String: Any]] ?? []
        families = orgs.map {
            Family(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", role: $0["azetRole"] as? Int ?? $0["type"] as? Int ?? 2,
                   status: $0["status"] as? Int ?? 0, memberId: $0["organizationUserId"] as? String ?? "", akey: $0["key"] as? String,
                   recoveryOn: $0["resetPasswordEnrolled"] as? Bool ?? false)
        }
        let confirmed = families.filter { $0.status == 2 && $0.akey != nil }
        if !confirmed.isEmpty {
            try? await client.crypto().initializeOrgCrypto(req: InitOrgCryptoRequest(
                organizationKeys: Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0.akey!) })))
            if let uk = try? await client.crypto().getUserEncryptionKey(), let pk = account?.privateKey {
                for f in confirmed { orgKeys[f.id] = try? azetFamilyUnwrap(userKey: uk, userPrivateKey: pk, akey: f.akey!) }
            }
        }
        let list = (try? azetCiphersFromJson(json: json)) ?? []
        ciphers = Dictionary(list.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        items = ((try? await client.vault().ciphers().decryptList(ciphers: list)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        vaults = (try? client.vault().collections().decryptList(collections: (try? azetCollectionsFromJson(json: json)) ?? [])) ?? []
        folders = (try? await client.vault().folders().decryptList(folders: (try? azetFoldersFromJson(json: json)) ?? [])) ?? []
    }

    // MARK: items

    func view(_ id: String) async throws -> CipherView {
        guard let c = ciphers[id] else { throw APIError(status: 404, message: String(localized: "This item is gone. Pull to refresh.")) }
        return try await client.vault().ciphers().decrypt(cipher: c)
    }

    /// Create or update. A family item needs at least one shared vault; moving a personal item into the family goes
    /// through /share with the item re-encrypted under the family key.
    func save(_ view: CipherView, vaultIds: [String] = []) async throws {
        let wasPersonal = view.id.flatMap { ciphers[$0] }.map { $0.organizationId == nil } ?? true
        let ctx = try await client.vault().ciphers().encrypt(cipherView: view)
        let body = try JSONSerialization.jsonObject(with: Data(try azetCipherRequestJson(ctx: ctx).utf8))
        if let id = view.id {
            if view.organizationId != nil, wasPersonal {
                try await api.send("PUT", "/api/ciphers/\(id)/share", ["cipher": body, "collectionIds": vaultIds])
            } else {
                try await api.send("PUT", "/api/ciphers/\(id)", body)
                if view.organizationId != nil, !vaultIds.isEmpty { try await api.send("PUT", "/api/ciphers/\(id)/collections", ["collectionIds": vaultIds]) }
            }
        } else if view.organizationId != nil {
            try await api.send("POST", "/api/ciphers/create", ["cipher": body, "collectionIds": vaultIds])
        } else {
            try await api.send("POST", "/api/ciphers", body)
        }
        try await sync()
    }

    /// Move a personal item into a shared vault (1Password: Move to another vault).
    func move(_ id: String, to vault: CollectionView) async throws {
        guard let orgId = vault.organizationId as String?, let vid = vault.id else { return }
        let v = try await view(id)
        let moved = try client.vault().ciphers().moveToOrganization(cipher: v, organizationId: orgId)
        try await save(moved, vaultIds: [vid])
    }

    // MARK: files — encrypted on this phone with the item's key; the server stores only the ciphertext

    func attach(_ id: String, name: String, data: Data) async throws {
        guard let c = ciphers[id] else { return }
        guard data.count <= 25_000_000 else { throw APIError(status: 413, message: String(localized: "Files can be up to 25 MB.")) }
        let enc = try client.vault().attachments().encryptBuffer(
            cipher: c, attachment: AttachmentView(id: nil, url: nil, size: String(data.count), sizeName: nil, fileName: name, key: nil), buffer: data)
        let slot = try await api.send("POST", "/api/ciphers/\(id)/attachment/v2",
                                      ["key": enc.attachment.key ?? "", "fileName": enc.attachment.fileName ?? "", "fileSize": enc.contents.count])
        guard let url = slot["url"] as? String else { throw APIError(status: 0, message: String(localized: "Something went wrong. Try again.")) }
        try await api.raw("PUT", url, json: enc.contents)
        try await sync()
    }

    /// The decrypted file, written to a temporary file for Quick Look / sharing (removed by the system).
    func open(_ id: String, _ file: AttachmentView) async throws -> URL {
        guard let c = ciphers[id], let aid = file.id else { throw APIError(status: 404, message: String(localized: "This item is gone. Pull to refresh.")) }
        let meta = try await api.get("/api/ciphers/\(id)/attachment/\(aid)")
        guard let url = meta["url"] as? String else { throw APIError(status: 404, message: String(localized: "This item is gone. Pull to refresh.")) }
        let plain = try client.vault().attachments().decryptBuffer(cipher: c, attachment: file, buffer: try await api.raw("GET", url))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(file.fileName ?? "file")
        try plain.write(to: out, options: .completeFileProtection)
        return out
    }

    func removeFile(_ id: String, _ file: AttachmentView) async throws {
        guard let aid = file.id else { return }
        try await api.raw("DELETE", "/api/ciphers/\(id)/attachment/\(aid)")
        try await sync()
    }

    func trash(_ id: String) async throws { try await api.send("PUT", "/api/ciphers/\(id)/delete"); try await sync() }
    func restore(_ id: String) async throws { try await api.send("PUT", "/api/ciphers/\(id)/restore"); try await sync() }
    func purge(_ id: String) async throws { try await api.raw("DELETE", "/api/ciphers/\(id)"); try await sync() }

    func setFavorite(_ id: String, _ on: Bool) async throws {
        try await api.send("PUT", "/api/ciphers/\(id)/partial", ["favorite": on, "folderId": ciphers[id]?.folderId ?? NSNull()])
        try await sync()
    }

    func totp(_ key: String) -> TotpResponse? { try? client.vault().generateTotp(key: key, time: nil) }

    func strength(_ password: String) -> UInt8 {
        client.auth().passwordStrength(password: password, email: account?.email ?? "", additionalInputs: [])
    }

    func generate(length: UInt8 = 20, symbols: Bool = true, words: Bool = false) -> String {
        if words {
            return (try? client.generators().passphrase(settings: PassphraseGeneratorRequest(numWords: 4, wordSeparator: "-", capitalize: true, includeNumber: true))) ?? ""
        }
        return (try? client.generators().password(settings: PasswordGeneratorRequest(
            lowercase: true, uppercase: true, numbers: true, special: symbols, length: length, avoidAmbiguous: true,
            minLowercase: nil, minUppercase: nil, minNumber: nil, minSpecial: nil, customRequiredChars: nil))) ?? ""
    }

    func vaultName(_ id: String) -> String { vaults.first { $0.id == id }?.name ?? "" }

    // MARK: family

    func familyKey(_ id: String) -> String? { orgKeys[id] }

    func myPublicKey() async throws -> String {
        if let p = account?.publicKey { return p }
        let r = try await api.get("/api/users/\(account?.userId ?? "")/public-key")
        return r["publicKey"] as? String ?? ""
    }

    func createFamily(name: String, firstVault: String) async throws {
        let keys = try azetFamilyMake(ownerPublicKey: try await myPublicKey(), firstVaultName: firstVault)
        try await api.send("POST", "/api/organizations", [
            "name": name, "billingEmail": account?.email ?? "", "planType": 11, "key": keys.ownerKey,
            "keys": ["publicKey": keys.publicKey, "encryptedPrivateKey": keys.encryptedPrivateKey],
            "collectionName": keys.encryptedVaultName,
        ])
        try await sync()
    }

    func members(_ family: Family) async throws -> [Member] {
        let r = try await api.get("/api/organizations/\(family.id)/users")
        return (r["data"] as? [[String: Any]] ?? []).map { m in
            Member(id: m["id"] as? String ?? "", userId: m["userId"] as? String, email: m["email"] as? String ?? "",
                   name: (m["displayName"] as? String) ?? (m["name"] as? String) ?? (m["email"] as? String ?? ""),
                   role: m["azetRole"] as? Int ?? 2, status: m["status"] as? Int ?? 0, publicKey: m["publicKey"] as? String,
                   inviteToken: m["inviteToken"] as? String, recoveryOn: m["resetPasswordEnrolled"] as? Bool ?? false,
                   vaults: Dictionary((m["collections"] as? [[String: Any]] ?? []).map { ($0["id"] as? String ?? "", $0["readOnly"] as? Bool ?? false) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    /// Returns the invite link to send (KakaoTalk, SMS). The token is in the fragment, so it never reaches web logs.
    func invite(to family: Family, email: String, name: String, role: Int, vaults: [String: Bool]) async throws -> URL {
        let r = try await api.send("POST", "/api/organizations/\(family.id)/users/invite", [
            "emails": [email.trimmingCharacters(in: .whitespaces).lowercased()], "type": role, "displayName": name,
            "collections": vaults.map { ["id": $0.key, "readOnly": $0.value] },
        ])
        let d = (r["data"] as? [[String: Any]])?.first ?? [:]
        return Session.inviteLink(family: family.id, member: d["id"] as? String ?? "", token: d["token"] as? String ?? "")
    }

    static func inviteLink(family: String, member: String, token: String) -> URL {
        URL(string: "https://pass.azet.io/invite#\(family).\(member).\(token)")!
    }

    static func parseInvite(_ url: URL) -> Invite? {
        let frag = url.fragment ?? url.query ?? ""
        let p = frag.split(separator: ".").map(String.init)
        guard p.count == 3, url.path.hasPrefix("/invite") || url.host == "invite" else { return nil }
        return Invite(familyId: p[0], memberId: p[1], token: p[2])
    }

    func preview(_ invite: Invite) async throws -> Invite {
        let r = try await api.send("GET", "/api/azet/invites/\(invite.memberId)/\(invite.token)", nil, auth: false)
        var i = invite
        i.email = r["email"] as? String; i.displayName = r["displayName"] as? String
        i.familyName = r["organizationName"] as? String; i.invitedBy = r["invitedBy"] as? String
        return i
    }

    /// Join: accept, then turn on family recovery (the user key wrapped to the family public key).
    func accept(_ invite: Invite) async throws {
        try await api.send("POST", "/api/organizations/\(invite.familyId)/users/\(invite.memberId)/accept", ["token": invite.token])
        let pub = try await api.get("/api/organizations/\(invite.familyId)/public-key")["publicKey"] as? String ?? ""
        if let pw = lastPasswordForFamily, !pub.isEmpty {
            let reset = try client.crypto().enrollAdminPasswordReset(publicKey: pub)
            let hash = try await client.auth().hashPassword(email: account?.email ?? "", password: pw, kdfParams: kdf, purpose: .serverAuthorization)
            try await api.send("PUT", "/api/organizations/\(invite.familyId)/users/\(account?.userId ?? "")/reset-password-enrollment",
                               ["resetPasswordKey": reset, "masterPasswordHash": hash])
        }
        try await sync()
    }

    /// The words both people read out loud before the organizer hands over the family key.
    func fingerprint(userId: String, publicKey: String) -> String {
        (try? client.platform().fingerprint(req: FingerprintRequest(fingerprintMaterial: userId, publicKey: publicKey))) ?? ""
    }

    func myFingerprint() -> String {
        (try? client.platform().userFingerprint(fingerprintMaterial: account?.userId ?? "")) ?? ""
    }

    func confirm(_ m: Member, in family: Family) async throws {
        guard let key = orgKeys[family.id], let pub = m.publicKey else { return }
        try await api.send("POST", "/api/organizations/\(family.id)/users/\(m.id)/confirm", ["key": try azetFamilyWrap(orgKey: key, memberPublicKey: pub)])
    }

    func createVault(in family: Family, name: String, access: [String: Bool], travelSafe: Bool = false) async throws {
        guard let key = orgKeys[family.id] else { return }
        try await api.send("POST", "/api/organizations/\(family.id)/collections", [
            "name": try azetFamilyEncrypt(orgKey: key, plain: name), "travelSafe": travelSafe,
            "users": access.map { ["id": $0.key, "readOnly": $0.value] },
        ])
        try await sync()
    }

    func updateVault(_ v: CollectionView, name: String?, access: [String: Bool]?, travelSafe: Bool?) async throws {
        guard let fid = v.organizationId as String?, let vid = v.id else { return }
        var body: [String: Any] = [:]
        if let name, let key = orgKeys[fid] { body["name"] = try azetFamilyEncrypt(orgKey: key, plain: name) }
        if let access { body["users"] = access.map { ["id": $0.key, "readOnly": $0.value] } }
        if let travelSafe { body["travelSafe"] = travelSafe }
        try await api.send("PUT", "/api/organizations/\(fid)/collections/\(vid)", body)
        try await sync()
    }

    func deleteVault(_ v: CollectionView) async throws {
        guard let fid = v.organizationId as String?, let vid = v.id else { return }
        try await api.raw("DELETE", "/api/organizations/\(fid)/collections/\(vid)")
        try await sync()
    }

    func setMember(_ m: Member, in family: Family, suspended: Bool) async throws {
        try await api.send("PUT", "/api/organizations/\(family.id)/users/\(m.id)/\(suspended ? "revoke" : "restore")")
    }

    func updateMember(_ m: Member, in family: Family, role: Int, vaults: [String: Bool]) async throws {
        try await api.send("PUT", "/api/organizations/\(family.id)/users/\(m.id)", ["type": role, "collections": vaults.map { ["id": $0.key, "readOnly": $0.value] }])
    }

    func remove(_ m: Member, from family: Family) async throws {
        try await api.raw("DELETE", "/api/organizations/\(family.id)/users/\(m.id)")
    }

    func reinvite(_ m: Member, in family: Family) async throws -> URL {
        let r = try await api.send("POST", "/api/organizations/\(family.id)/users/\(m.id)/reinvite")
        return Session.inviteLink(family: family.id, member: m.id, token: r["token"] as? String ?? "")
    }

    /// Organizer recovery: a temporary account password for a member who forgot theirs. Their items stay as they are.
    func recover(_ m: Member, in family: Family, temporaryPassword: String) async throws {
        guard let key = orgKeys[family.id] else { return }
        let d = try await api.get("/api/organizations/\(family.id)/users/\(m.id)/reset-password-details")
        let it = (d["kdfIterations"] as? NSNumber)?.uint32Value ?? 600_000
        let r = try azetFamilyRecover(orgKey: key, orgEncryptedPrivateKey: d["encryptedPrivateKey"] as? String ?? "",
                                     resetPasswordKey: d["resetPasswordKey"] as? String ?? "", email: m.email,
                                     newPassword: temporaryPassword, kdf: .pbkdf2(iterations: it))
        try await api.send("PUT", "/api/organizations/\(family.id)/users/\(m.id)/reset-password",
                           ["newMasterPasswordHash": r.newMasterPasswordHash, "key": r.newKey])
    }

    func leave(_ family: Family) async throws {
        try await api.send("POST", "/api/organizations/\(family.id)/leave")
        try await sync()
    }

    // MARK: travel mode, share links, account

    func setTravelMode(_ on: Bool, password: String) async throws {
        let hash = try await client.auth().hashPassword(email: account?.email ?? "", password: password, kdfParams: kdf, purpose: .serverAuthorization)
        try await api.send("POST", "/api/azet/travel-mode", ["enabled": on, "masterPasswordHash": hash])
        travelMode = on
        try await sync()
    }

    func setTravelSafe(_ id: String, _ on: Bool) async throws {
        try await api.send("PUT", "/api/ciphers/\(id)/travel-safe", ["travelSafe": on])
        try await sync()
    }

    func isTravelSafe(_ id: String) -> Bool {
        guard let json = syncJSON, let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        return (o["ciphers"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id }?["travelSafe"] as? Bool ?? false
    }

    func verifyPassword(_ password: String) async -> Bool {
        guard let a = account else { return false }
        return (try? await client.auth().validatePasswordUserKey(password: password, encryptedUserKey: a.key)) != nil
    }
}
