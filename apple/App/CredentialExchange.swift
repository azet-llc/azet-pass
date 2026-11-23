#if os(iOS)
import AuthenticationServices
import BitwardenSdk
import SwiftUI

// spass-286: passwords and passkeys move between AZET Pass and another app through iOS 26
// credential exchange (FIDO CXF). The SDK writes and reads the CXF account JSON; Apple carries it.

/// Apple's CXF types read and write dates as seconds since 1970, as the spec has them.
private let cxfDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
private let cxfEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()

@available(iOS 26.0, *)
enum CredentialExchange {
    @MainActor
    static func export(_ session: Session) async throws {
        guard let me = session.account,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let manager = ASCredentialExportManager(presentationAnchor: window)
        _ = try await manager.requestExport()
        let live = session.ciphers.values.filter { $0.deletedDate == nil }
        let json = try session.client.exporters().exportCxf(
            account: BitwardenSdk.Account(id: me.userId, email: me.email, name: me.name), ciphers: Array(live))
        let account = try cxfDecoder.decode(ASImportableAccount.self, from: Data(json.utf8))
        try await manager.exportCredentials(ASExportedCredentialData(
            accounts: [account], formatVersion: .v1,
            exporterRelyingPartyIdentifier: "pass.azet.io", exporterDisplayName: "AZET Pass", timestamp: Date()))
    }

    /// Saves what the other app handed over into this person's own vault; returns how many items.
    @MainActor
    static func importItems(token: UUID, into session: Session) async throws -> Int {
        let data = try await ASCredentialImportManager().importCredentials(token: token)
        var saved = 0
        for account in data.accounts {
            let json = String(decoding: try cxfEncoder.encode(account), as: UTF8.self)
            for ctx in try session.client.exporters().importCxf(payload: json) {
                try await session.api.send("POST", "/api/ciphers", try JSONSerialization.jsonObject(with: Data(try azetCipherRequestJson(ctx: ctx).utf8)))
                saved += 1
            }
        }
        try await session.sync()
        return saved
    }
}

/// Settings row: hand everything to another password app (it lists the apps that take it).
struct CredentialExportRow: View {
    @Environment(Session.self) private var session
    @State private var failure: String?

    var body: some View {
        if #available(iOS 26.0, *) {
            Button {
                Task {
                    do { try await CredentialExchange.export(session) } catch let e as ASAuthorizationError where e.code == .canceled {
                    } catch { failure = error.localizedDescription }
                }
            } label: { Label("Move passwords and passkeys to another app", systemImage: "arrow.up.forward.app") }
            .alert("Couldn't move items", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }
}

/// Runs an import another app started (iOS opened AZET Pass with a credential exchange token) once unlocked.
struct CredentialImportRunner: ViewModifier {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var result: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: prefs.importToken) { _, _ in run() }
            .onAppear(perform: run)
            .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) { Button("OK", role: .cancel) {} }
    }

    private func run() {
        guard let token = prefs.importToken, #available(iOS 26.0, *) else { return }
        prefs.importToken = nil
        Task {
            do {
                let n = try await CredentialExchange.importItems(token: token, into: session)
                result = String(localized: "Moved \(n) items into AZET Pass")
            } catch { result = error.localizedDescription }
        }
    }
}
#endif
