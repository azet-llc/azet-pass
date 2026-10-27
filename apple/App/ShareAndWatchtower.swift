import BitwardenSdk
import CryptoKit
import SwiftUI

// MARK: share a copy by link (1Password item sharing → AZET Pass Send)

/// A copy of the item, encrypted on this phone, behind a link that expires. The key is in the link fragment, so the
/// server cannot read it; anyone with the link can open it in a browser, no app or account needed.
struct ShareLinkView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let item: CipherView
    @State private var days = 7
    @State private var oneView = false
    @State private var includePassword = true
    @State private var link: URL?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let link {
                    Section {
                        Label("Link ready", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.brand)
                        ShareLink(item: link) { Label("Send the link", systemImage: "square.and.arrow.up") }
                        Button { copyToClipboard(link.absoluteString) } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    } footer: { Text("It stops working \(days == 1 ? String(localized: "tomorrow") : String(localized: "in \(days) days"))\(oneView ? String(localized: " or after one view") : "").") }
                } else {
                    Section {
                        Picker("Link expires", selection: $days) {
                            Text("After 1 hour").tag(0); Text("After 1 day").tag(1); Text("After 7 days").tag(7); Text("After 30 days").tag(30)
                        }
                        Toggle("Only one view", isOn: $oneView)
                        if item.login?.password != nil { Toggle("Include the password", isOn: $includePassword) }
                    } footer: { Text("The person sees a copy. Changing the item later does not change what they see.") }
                    Section {
                        Button { Task { await make() } } label: { HStack { Text("Create link"); if busy { Spacer(); ProgressView() } } }.disabled(busy)
                    }
                }
            }
            .navigationTitle("Share \(item.name)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private var text: String {
        var lines = [item.name]
        if let u = item.login?.username { lines.append(String(localized: "ID: \(u)")) }
        if includePassword, let p = item.login?.password { lines.append(String(localized: "Password: \(p)")) }
        for u in item.login?.uris ?? [] { if let s = u.uri { lines.append(s) } }
        for f in item.fields ?? [] where f.name != ItemCategory.marker { lines.append("\(f.name ?? ""): \(f.value ?? "")") }
        if let n = item.notes { lines.append(n) }
        return lines.joined(separator: "\n")
    }

    private func make() async {
        busy = true; defer { busy = false }
        do {
            let end = days == 0 ? Date().addingTimeInterval(3600) : Date().addingTimeInterval(Double(days) * 86400)
            let v = SendView(id: nil, accessId: nil, name: item.name, notes: nil, key: nil, newPassword: nil, hasPassword: false,
                             type: .text, file: nil, text: SendTextView(text: text, hidden: true), maxAccessCount: oneView ? 1 : nil,
                             accessCount: 0, disabled: false, hideEmail: true, revisionDate: Date(), deletionDate: end, expirationDate: end,
                             emails: [], authType: .none)
            let send = try session.client.sends().encrypt(send: v)
            let body = try JSONSerialization.jsonObject(with: Data(try azetSendRequestJson(send: send).utf8))
            let r = try await session.api.raw("POST", "/api/sends", json: body)
            let made = try azetSendFromJson(json: String(data: r, encoding: .utf8) ?? "")
            let view = try session.client.sends().decrypt(send: made)
            let key = (view.key ?? "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            link = URL(string: "https://pass.azet.io/#/send/\(made.accessId ?? "")/\(key)")
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Watchtower

/// Reference: 1Password Watchtower (score, compromised / vulnerable / weak / reused / unsecured / 2FA available /
/// expiring). Password checks against Have I Been Pwned send only the first 5 characters of a SHA-1 hash.
@MainActor @Observable
final class Watchtower {
    struct Finding: Identifiable { let id: String; let name: String; let detail: String }
    var weak: [Finding] = []
    var reused: [Finding] = []
    var breached: [Finding] = []
    var unsecured: [Finding] = []
    var twoFactor: [Finding] = []
    var expiring: [Finding] = []
    var passkeys: [Finding] = []
    var score = 0
    var checked = 0
    var running = false
    var strengthBuckets = [0, 0, 0, 0, 0]

    static let totpSites: Set<String> = ["google.com", "naver.com", "kakao.com", "facebook.com", "instagram.com", "amazon.com", "microsoft.com", "live.com",
                                         "apple.com", "dropbox.com", "github.com", "coupang.com", "toss.im", "paypal.com", "x.com", "twitter.com", "discord.com"]
    static let passkeySites: Set<String> = ["google.com", "apple.com", "amazon.com", "microsoft.com", "github.com", "paypal.com", "naver.com", "kakao.com"]

    func run(_ s: Session, breaches: Bool) async {
        running = true; defer { running = false }
        var views: [CipherView] = []
        for i in s.items where i.deletedDate == nil { if let id = i.id, let v = try? await s.view(id) { views.append(v) } }
        let logins = views.filter { $0.login?.password?.isEmpty == false }
        var byPassword: [String: [CipherView]] = [:]
        for v in logins { byPassword[v.login!.password!, default: []].append(v) }
        weak = []; reused = []; breached = []; unsecured = []; twoFactor = []; expiring = []; passkeys = []
        strengthBuckets = [0, 0, 0, 0, 0]
        for v in logins {
            let p = v.login!.password!
            let st = Int(s.strength(p))
            strengthBuckets[min(st, 4)] += 1
            if st < 2 { weak.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "Easy to guess"))) }
            if (byPassword[p]?.count ?? 0) > 1 {
                reused.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "Same password on \(byPassword[p]!.count) sites")))
            }
            let hosts = (v.login?.uris ?? []).compactMap { $0.uri.flatMap(URL.init(string:)) }
            if hosts.contains(where: { $0.scheme == "http" }) { unsecured.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "Uses http, not https"))) }
            let domains = hosts.compactMap { Watchtower.domain($0.host) }
            if (v.login?.totp ?? "").isEmpty, domains.contains(where: Watchtower.totpSites.contains) {
                twoFactor.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "This site offers two-step login")))
            }
            if (v.login?.fido2Credentials ?? []).isEmpty, domains.contains(where: Watchtower.passkeySites.contains) {
                passkeys.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "This site supports passkeys")))
            }
        }
        for v in views {
            let soon = Date().addingTimeInterval(60 * 86400)
            if let c = v.card, let m = Int(c.expMonth ?? ""), let y = Int(c.expYear ?? ""), let d = Calendar.current.date(from: DateComponents(year: y < 100 ? 2000 + y : y, month: m)), d < soon {
                expiring.append(.init(id: v.id ?? "", name: v.name, detail: d < Date() ? String(localized: "Expired") : String(localized: "Expires soon")))
            }
            if let e = v.passport?.expirationDate ?? v.driversLicense?.expirationDate, e < soon {
                expiring.append(.init(id: v.id ?? "", name: v.name, detail: e < Date() ? String(localized: "Expired") : String(localized: "Expires soon")))
            }
        }
        if breaches {
            for (p, list) in byPassword {
                if let n = await Watchtower.pwnedCount(p), n > 0 {
                    for v in list { breached.append(.init(id: v.id ?? "", name: v.name, detail: String(localized: "Found in \(n.formatted()) data breaches"))) }
                }
            }
        }
        checked = logins.count
        let bad = Set(weak.map(\.id) + reused.map(\.id) + breached.map(\.id))
        score = logins.isEmpty ? 0 : Int((Double(logins.count - bad.count) / Double(logins.count)) * 900 + Double(min(100, logins.count * 5)))
    }

    static func domain(_ host: String?) -> String? { Domain.of(host) }

    /// Have I Been Pwned range API (k-anonymity): only the first 5 hex characters of SHA-1(password) leave the phone.
    static func pwnedCount(_ password: String) async -> Int? {
        let hash = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        var r = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(hash.prefix(5))")!)
        r.setValue("true", forHTTPHeaderField: "Add-Padding")
        guard let (d, _) = try? await URLSession.shared.data(for: r), let body = String(data: d, encoding: .utf8) else { return nil }
        let suffix = hash.dropFirst(5)
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix(suffix) {
            return Int(line.split(separator: ":").last ?? "0")
        }
        return 0
    }
}

struct WatchtowerView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var w = Watchtower()
    @State private var showSettings = false
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Gauge(score: w.score)
                        Text(label(w.score)).font(.headline).foregroundStyle(.secondary)
                        Text("Get alerts for anything that puts your family's accounts at risk. Fix the flagged items to raise the score.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    if w.checked > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Overall password strength").font(.headline)
                            GeometryReader { g in
                                HStack(spacing: 2) {
                                    ForEach(Array([Color.red, .orange, .yellow, Color(red: 0.5, green: 0.8, blue: 0.2), .green].enumerated().reversed()), id: \.offset) { i, c in
                                        c.frame(width: max(0, g.size.width * Double(w.strengthBuckets[i]) / Double(max(w.checked, 1)) - 2))
                                    }
                                }.clipShape(Capsule())
                            }.frame(height: 12)
                        }
                    }
                }
                group(String(localized: "Compromised passwords"), "exclamationmark.octagon.fill", .red, w.breached)
                group(String(localized: "Weak passwords"), "lock.open.fill", .orange, w.weak)
                group(String(localized: "Reused passwords"), "arrow.triangle.2.circlepath", .orange, w.reused)
                group(String(localized: "Unsecured websites"), "network.slash", .yellow, w.unsecured)
                group(String(localized: "Two-step login available"), "lock.rotation", .blue, w.twoFactor)
                group(String(localized: "Passkeys available"), "person.badge.key.fill", .blue, w.passkeys)
                group(String(localized: "Expiring"), "calendar.badge.exclamationmark", .purple, w.expiring)
                if !prefs.watchtowerBreaches {
                    Section { Text("Checking passwords against data breaches is off in Settings.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .overlay { if w.running && w.checked == 0 { ProgressView() } }
            .navigationTitle("Watchtower")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .task(id: session.lastSync) { await w.run(session, breaches: prefs.watchtowerBreaches) }
            .refreshable { await w.run(session, breaches: prefs.watchtowerBreaches) }
            .navigationDestination(for: String.self) { ItemDetailView(id: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
        }
    }

    @ViewBuilder private func group(_ title: String, _ symbol: String, _ color: Color, _ list: [Watchtower.Finding]) -> some View {
        if !list.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(list) { f in NavigationLink(value: f.id) { VStack(alignment: .leading) { Text(f.name); Text(f.detail).font(.caption).foregroundStyle(.secondary) } } }
                } label: {
                    HStack { Label(title, systemImage: symbol).foregroundStyle(color); Spacer(); Text("\(list.count)").bold() }
                }
            }
        }
    }

    private func label(_ s: Int) -> String {
        switch s {
        case 0: String(localized: "Add logins to see your score")
        case ..<500: String(localized: "NEEDS WORK")
        case ..<800: String(localized: "FAIR")
        case ..<950: String(localized: "GOOD")
        default: String(localized: "FANTASTIC")
        }
    }
}

struct Gauge: View {
    let score: Int
    var body: some View {
        ZStack {
            Circle().trim(from: 0.12, to: 0.88).stroke(Color(.systemFill), style: StrokeStyle(lineWidth: 18, lineCap: .round)).rotationEffect(.degrees(90))
            Circle().trim(from: 0.12, to: 0.12 + 0.76 * min(Double(score) / 1000, 1))
                .stroke(AngularGradient(colors: [.red, .orange, .yellow, .green, Theme.brand], center: .center), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(90))
            Text("\(score)").font(.system(size: 54, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        .frame(width: 210, height: 210)
        .accessibilityElement().accessibilityLabel(Text("Watchtower score \(score)"))
    }
}
