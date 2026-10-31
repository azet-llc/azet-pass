import BitwardenSdk
import Foundation
import SafariServices

/// Answers the toolbar popup from the vault the Mac app keeps (encrypted) in the shared container. The vault opens here
/// with Touch ID when it is on in the app, else with the account password typed in the popup, and locks again after the
/// app's auto-lock time without use. Only the logins for the open site leave this process, and only to the popup.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let msg = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        Task { @MainActor in
            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: await PopupVault.shared.answer(msg)]
            context.completeRequest(returningItems: [item])
        }
    }
}

@MainActor
final class PopupVault {
    static let shared = PopupVault()
    private var session = Session()
    private var lastUse = Date()

    func answer(_ m: [String: Any]) async -> [String: Any] {
        let minutes = SharedFiles.defaults.object(forKey: "autoLock") as? Int ?? 5
        if session.phase == .unlocked, Date().timeIntervalSince(lastUse) > Double(minutes * 60) { session.lock() }
        lastUse = Date()
        if session.phase == .welcome { session = Session() }   // signed in to the app after this process started
        guard session.phase != .welcome else { return ["state": "signedOut"] }
        let url = m["url"] as? String
        switch m["cmd"] as? String {
        case "lock":
            session.lock()
            return locked()
        case "unlock":
            do {
                if let p = m["password"] as? String { try await session.unlock(password: p) } else { try await session.unlockWithBiometrics() }
            } catch { return locked(error.localizedDescription) }
            return await logins(url)
        default:
            return session.phase == .unlocked ? await logins(url) : locked()
        }
    }

    private func locked(_ error: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["state": "locked", "touchID": session.biometricOn]
        if let error { r["error"] = error }
        return r
    }

    private func logins(_ url: String?) async -> [String: Any] {
        let host = url.flatMap(URL.init(string:))?.host.flatMap(Domain.of)
        let live = session.items.filter { $0.deletedDate == nil && LoginKind.isLogin($0) }
        var out: [[String: Any]] = []
        for i in LoginKind.matching(live, hosts: host.map { [$0] } ?? []).prefix(20) {
            guard let id = i.id, let v = try? await session.view(id) else { continue }
            var row: [String: Any] = ["id": id, "name": v.name, "username": v.login?.username ?? "", "password": v.login?.password ?? ""]
            if let t = v.login?.totp, let c = session.totp(t) { row["totp"] = c.code }
            out.append(row)
        }
        return ["state": "unlocked", "host": host ?? "", "logins": out]
    }
}
