import AuthenticationServices
import BitwardenSdk
import Foundation

/// Passkeys through the SDK's FIDO2 authenticator: the private key is a field of a login item, encrypted like any
/// other field, so a passkey saved on one family device works on every device of that person (and in a shared
/// vault, for the family).
@MainActor
final class PasskeyBridge {
    let session: Session
    init(session: Session) { self.session = session }

    var authenticator: ClientFido2Authenticator {
        session.client.platform().fido2().authenticator(userInterface: PasskeyUI(), credentialStore: PasskeyStore(session: session))
    }

    func register(rpId: String, userName: String, userHandle: Data, clientDataHash: Data) async throws -> MakeCredentialResult {
        try await authenticator.makeCredential(request: MakeCredentialRequest(
            clientDataHash: clientDataHash, rp: PublicKeyCredentialRpEntity(id: rpId, name: rpId),
            user: PublicKeyCredentialUserEntity(id: userHandle, displayName: userName, name: userName),
            pubKeyCredParams: [PublicKeyCredentialParameters(ty: "public-key", alg: -7)], excludeList: nil,
            options: Options(rk: true, uv: .preferred), extensions: nil))
    }

    func assert(rpId: String, credentialId: Data?, clientDataHash: Data) async throws -> GetAssertionResult {
        try await authenticator.getAssertion(request: GetAssertionRequest(
            rpId: rpId, clientDataHash: clientDataHash,
            allowList: credentialId.map { [PublicKeyCredentialDescriptor(ty: "public-key", id: $0, transports: nil)] },
            options: Options(rk: credentialId == nil, uv: .preferred), extensions: nil))
    }

    /// QuickType suggestions: every login with a website and every passkey, so iOS can offer them above the keyboard.
    func refreshIdentityStore() async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        var ids: [ASCredentialIdentity] = []
        for i in session.items where i.deletedDate == nil {
            guard case .login = i.type, let id = i.id, let c = session.ciphers[id],
                  let v = try? await session.client.vault().ciphers().decrypt(cipher: c) else { continue }
            for u in v.login?.uris ?? [] {
                if let host = u.uri.flatMap(URL.init(string:))?.host {
                    ids.append(ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                                                            user: v.login?.username ?? "", recordIdentifier: id))
                }
            }
            for p in (try? session.client.platform().fido2().decryptFido2AutofillCredentials(cipherView: v)) ?? [] {
                ids.append(ASPasskeyCredentialIdentity(relyingPartyIdentifier: p.rpId, userName: p.userNameForUi ?? "",
                                                       credentialID: p.credentialId, userHandle: p.userHandle, recordIdentifier: id))
            }
        }
        try? await store.replaceCredentialIdentities(ids)
    }
}

/// The user was already verified (Face ID or account password) when the vault was unlocked for this request.
final class PasskeyUI: Fido2UserInterface, @unchecked Sendable {
    func checkUser(options: CheckUserOptions, hint: UiHint) async throws -> CheckUserResult { CheckUserResult(userPresent: true, userVerified: true) }

    func pickCredentialForAuthentication(availableCredentials: [CipherView]) async throws -> CipherViewWrapper {
        guard let c = availableCredentials.first else { throw APIError(status: 404, message: String(localized: "No passkey for this site.")) }
        return CipherViewWrapper(cipher: c)
    }

    func checkUserAndPickCredentialForCreation(options: CheckUserOptions, newCredential: Fido2CredentialNewView) async throws -> CheckUserAndPickCredentialForCreationResult {
        var d = Draft(category: .login)
        d.name = newCredential.rpName ?? newCredential.rpId
        d.username = newCredential.userName ?? ""
        d.urls = ["https://\(newCredential.rpId)"]
        return CheckUserAndPickCredentialForCreationResult(cipher: CipherViewWrapper(cipher: d.view()), checkUserResult: CheckUserResult(userPresent: true, userVerified: true))
    }

    func isVerificationEnabled() -> Bool { true }
}

final class PasskeyStore: Fido2CredentialStore, @unchecked Sendable {
    let session: Session
    init(session: Session) { self.session = session }

    func findCredentials(ids: [Data]?, ripId: String, userHandle: Data?) async throws -> [CipherView] {
        await matching(ids: ids, rpId: ripId)
    }

    @MainActor private func matching(ids: [Data]?, rpId: String) async -> [CipherView] {
        var out: [CipherView] = []
        for (_, c) in session.ciphers where c.deletedDate == nil {
            guard let v = try? await session.client.vault().ciphers().decrypt(cipher: c), !(v.login?.fido2Credentials ?? []).isEmpty else { continue }
            let creds = (try? session.client.platform().fido2().decryptFido2AutofillCredentials(cipherView: v)) ?? []
            if creds.contains(where: { $0.rpId == rpId && (ids == nil || ids!.contains($0.credentialId)) }) { out.append(v) }
        }
        return out
    }

    func allCredentials() async throws -> [CipherListView] { await MainActor.run { session.items } }

    func saveCredential(cred: EncryptionContext) async throws {
        let body = try JSONSerialization.jsonObject(with: Data(try azetCipherRequestJson(ctx: cred).utf8))
        let api = await MainActor.run { session.api }
        if let id = cred.cipher.id { try await api.send("PUT", "/api/ciphers/\(id)", body) }
        else { try await api.send("POST", "/api/ciphers", body) }
        try await session.sync()
    }
}
