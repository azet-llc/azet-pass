import AuthenticationServices
import BitwardenSdk
import SwiftUI

/// AutoFill: logins and one-time passwords in any app or Safari. Unlocks with Face ID from the key the app keeps in
/// the shared keychain, reads the encrypted vault the app keeps in the shared container.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var services: [ASCredentialServiceIdentifier] = []
    private var oneTimeCode = false

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        services = serviceIdentifiers; show()
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        services = serviceIdentifiers; oneTimeCode = true; show()
    }

    // MARK: passkeys (iOS 17+)

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        guard let r = registrationRequest as? ASPasskeyCredentialRequest, let id = r.credentialIdentity as? ASPasskeyCredentialIdentity else { return fail() }
        embed(UIHostingController(rootView: PasskeyRun(title: String(localized: "Save a passkey for \(id.relyingPartyIdentifier)")) { s in
            let res = try await PasskeyBridge(session: s).register(rpId: id.relyingPartyIdentifier, userName: id.userName, userHandle: id.userHandle, clientDataHash: r.clientDataHash)
            await self.extensionContext.completeRegistrationRequest(using: ASPasskeyRegistrationCredential(
                relyingParty: id.relyingPartyIdentifier, clientDataHash: r.clientDataHash, credentialID: res.credentialId, attestationObject: res.attestationObject))
        } cancel: { [weak self] in self?.fail() }))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        if let r = credentialRequest as? ASPasskeyCredentialRequest, let id = r.credentialIdentity as? ASPasskeyCredentialIdentity {
            embed(UIHostingController(rootView: PasskeyRun(title: String(localized: "Sign in with a passkey")) { s in
                let res = try await PasskeyBridge(session: s).assert(rpId: id.relyingPartyIdentifier, credentialId: id.credentialID, clientDataHash: r.clientDataHash)
                await self.extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
                    userHandle: res.userHandle, relyingParty: id.relyingPartyIdentifier, signature: res.signature,
                    clientDataHash: r.clientDataHash, authenticatorData: res.authenticatorData, credentialID: res.credentialId))
            } cancel: { [weak self] in self?.fail() }))
        } else if let p = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            embed(UIHostingController(rootView: PasskeyRun(title: p.user) { s in
                let v = try await s.view(p.recordIdentifier ?? "")
                await self.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: v.login?.username ?? "", password: v.login?.password ?? ""))
            } cancel: { [weak self] in self?.fail() }))
        } else { fail() }
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        services = serviceIdentifiers
        let rp = requestParameters.relyingPartyIdentifier
        let allow = requestParameters.allowedCredentials.first
        embed(UIHostingController(rootView: PasskeyRun(title: String(localized: "Sign in with a passkey")) { s in
            let res = try await PasskeyBridge(session: s).assert(rpId: rp, credentialId: allow, clientDataHash: requestParameters.clientDataHash)
            await self.extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
                userHandle: res.userHandle, relyingParty: rp, signature: res.signature,
                clientDataHash: requestParameters.clientDataHash, authenticatorData: res.authenticatorData, credentialID: res.credentialId))
        } cancel: { [weak self] in self?.fail() }))
    }

    private func fail() {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue))
    }

    override func prepareInterfaceForExtensionConfiguration() {
        let v = UIHostingController(rootView: Text("AZET Pass is ready to fill your passwords.").padding())
        embed(v)
    }

    private func show() {
        let root = AutofillList(services: services, oneTimeCode: oneTimeCode,
                                pick: { [weak self] user, secret, isCode in
                                    if isCode, #available(iOS 18.0, *) {
                                        self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: secret))
                                    } else {
                                        self?.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: user, password: secret))
                                    }
                                },
                                cancel: { [weak self] in self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue)) })
        embed(UIHostingController(rootView: root))
    }

    private func embed(_ v: UIViewController) {
        addChild(v); v.view.frame = view.bounds; v.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(v.view); v.didMove(toParent: self)
    }
}

struct AutofillList: View {
    let services: [ASCredentialServiceIdentifier]
    let oneTimeCode: Bool
    let pick: (String, String, Bool) -> Void
    let cancel: () -> Void
    @State private var session = Session()
    @State private var password = ""
    @State private var query = ""
    @State private var error: String?

    private var hosts: [String] {
        services.compactMap { s in s.type == .URL ? URL(string: s.identifier)?.host : s.identifier }.compactMap(Domain.of)
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.phase == .unlocked {
                    let all = session.items.filter { $0.deletedDate == nil }
                    let match = LoginKind.matching(all, hosts: hosts)
                    let rest = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
                    List {
                        if !match.isEmpty, query.isEmpty { Section("Suggested") { ForEach(match) { row($0) } } }
                        Section("All logins") { ForEach(rest.filter { LoginKind.isLogin($0) }) { row($0) } }
                    }
                    .searchable(text: $query)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.fill").font(.largeTitle)
                        SecureField("Account password", text: $password).textContentType(.password).padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        Button("Unlock") { Task { do { try await session.unlock(password: password) } catch { self.error = error.localizedDescription } } }.buttonStyle(.borderedProminent)
                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    }.padding(24)
                }
            }
            .navigationTitle("AZET Pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
            .task { if session.biometricOn { try? await session.unlockWithBiometrics() } }
        }
    }

    private func row(_ i: CipherListView) -> some View {
        Button {
            Task {
                guard let id = i.id, let v = try? await session.view(id) else { return }
                if oneTimeCode, let t = v.login?.totp, let code = session.totp(t)?.code { pick(v.login?.username ?? "", code, true) }
                else { pick(v.login?.username ?? "", v.login?.password ?? "", false) }
            }
        } label: { ItemRowLite(name: i.name, subtitle: i.subtitle) }
    }
}

struct ItemRowLite: View {
    let name: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading) { Text(name).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
    }
}

/// Unlock (Face ID, else account password), then run one passkey or password step.
struct PasskeyRun: View {
    let title: String
    let run: (Session) async throws -> Void
    let cancel: () -> Void
    @State private var session = Session()
    @State private var password = ""
    @State private var error: String?
    @State private var started = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 44)).foregroundStyle(.tint)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if session.phase != .unlocked {
                    SecureField("Account password", text: $password).textContentType(.password)
                        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    Button("Unlock") { Task { do { try await session.unlock(password: password); await go() } catch { self.error = error.localizedDescription } } }
                        .buttonStyle(.borderedProminent)
                } else { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
            .task { if session.biometricOn, (try? await session.unlockWithBiometrics()) != nil { await go() } }
        }
    }

    private func go() async {
        guard !started else { return }
        started = true
        do { try await run(session) } catch { self.error = error.localizedDescription; started = false }
    }
}
