import BitwardenSdk
import SwiftUI
#if os(macOS)
import SafariServices
#endif
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var faceID = false
    @State private var travelAsk = false
    @State private var travelPassword = ""
    @State private var error: String?

    var body: some View {
        @Bindable var prefs = prefs
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Avatar(name: session.account?.name ?? "?", size: 44)
                        VStack(alignment: .leading) {
                            Text(session.account?.name ?? "").font(.headline)
                            Text(session.account?.email ?? "").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Toggle(isOn: $prefs.parentMode) { Label("Parent mode", systemImage: "textformat.size.larger") }
                } footer: { Text("Big letters and only three buttons: find a password, save a new one, ask family for help.") }
                Section("Security") {
                    Toggle(isOn: $faceID) { Label("Unlock with Face ID", systemImage: "faceid") }
                        .onChange(of: faceID) { _, on in Task { await session.setBiometrics(on) } }
                    Picker(selection: $prefs.autoLockMinutes) {
                        Text("Immediately").tag(0); Text("After 1 minute").tag(1); Text("After 5 minutes").tag(5); Text("After 1 hour").tag(60)
                    } label: { Label("Lock", systemImage: "lock") }
                    Toggle(isOn: Binding(get: { session.travelMode }, set: { _ in travelAsk = true })) { Label("Travel Mode", systemImage: "airplane") }
                    Toggle(isOn: $prefs.watchtowerBreaches) { Label("Check passwords against data breaches", systemImage: "shield.lefthalf.filled") }
                    NavigationLink { AutofillHelpView() } label: { Label("Fill passwords in apps and Safari", systemImage: "key.viewfinder") }
                    NavigationLink { TwoStepLoginView() } label: { Label("Two-step login for this account", systemImage: "lock.rotation") }
                }
                Section("Your data") {
                    NavigationLink { ImportView() } label: { Label("Import from 1Password, Chrome, CSV", systemImage: "square.and.arrow.down") }
                    NavigationLink { ExportView() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    NavigationLink { EmergencyKitView() } label: { Label("Emergency Kit", systemImage: "doc.richtext") }
                    NavigationLink { GeneratorView() } label: { Label("Password generator", systemImage: "wand.and.stars") }
                }
                Section {
                    Link(destination: URL(string: "https://github.com/azet-llc/azet-pass")!) { Label("Source code (GPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right") }
                    NavigationLink { LicensesView() } label: { Label("Open-source licences", systemImage: "doc.plaintext") }
                    Link(destination: URL(string: "https://azet.io/privacy")!) { Label("Privacy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "https://pass.azet.io/#/settings/account")!) { Label("Delete account", systemImage: "person.crop.circle.badge.xmark") }
                }
                Section {
                    Button("Lock now") { session.lock(); dismiss() }
                    Button("Sign out", role: .destructive) { session.signOut(); dismiss() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { faceID = session.biometricOn }
            .alert(session.travelMode ? "Turn off Travel Mode" : "Turn on Travel Mode", isPresented: $travelAsk) {
                SecureField("Account password", text: $travelPassword)
                Button("Cancel", role: .cancel) { travelPassword = "" }
                Button(session.travelMode ? "Turn off" : "Turn on") {
                    Task { do { try await session.setTravelMode(!session.travelMode, password: travelPassword) } catch { self.error = error.localizedDescription }; travelPassword = "" }
                }
            } message: {
                Text("While on, only items and vaults marked safe for travel stay on your devices. Everything else comes back when you turn it off.")
            }
            .errorAlert($error)
        }
    }
}

struct AutofillHelpView: View {
    var body: some View {
        List {
            Section {
                #if os(iOS)
                Text("1. Open the Settings app\n2. General → AutoFill & Passwords\n3. Turn on AZET Pass").font(.body)
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                #else
                Text("1. Open Safari Settings → Extensions\n2. Turn on AZET Pass\n3. Allow it on the sites you sign in to").font(.body)
                Button("Open Safari Settings") { SFSafariApplication.showPreferencesForExtension(withIdentifier: Config.safariExtension) }
                #endif
            } footer: {
                #if os(iOS)
                Text("Then the keyboard offers your logins, passkeys and one-time passwords in every app and in Safari. On a computer, install AZET Pass for Chrome, Safari, Edge or Firefox.")
                #else
                Text("Then click the AZET Pass button in the Safari toolbar on a sign-in page: it lists the logins for that site and fills them in.")
                #endif
            }
        }
        .navigationTitle("AutoFill")
    }
}

struct TwoStepLoginView: View {
    @Environment(Session.self) private var session
    @State private var secret: String?
    @State private var code = ""
    @State private var password = ""
    @State private var on = false
    @State private var error: String?

    var body: some View {
        Form {
            if on {
                Section { Label("Two-step login is on", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.brand) }
            } else if let secret {
                Section {
                    Text("Add this key to an authenticator app (not AZET Pass itself), then type the 6-digit code it shows.")
                    FieldRow(label: String(localized: "Setup key"), value: secret)
                    TextField("6-digit code", text: $code).keyboardType(.numberPad)
                    Button("Turn on") { Task { await enable() } }.disabled(code.count != 6)
                }
            } else {
                Section {
                    SecureField("Account password", text: $password)
                    Button("Set up") { Task { await start() } }.disabled(password.isEmpty)
                } footer: { Text("Signing in on a new device will also ask for a code from your authenticator app.") }
            }
        }
        .navigationTitle("Two-step login")
        .task {
            if let r = try? await session.api.get("/api/two-factor"), let d = r["data"] as? [[String: Any]] { on = d.contains { ($0["enabled"] as? Bool) == true } }
        }
        .errorAlert($error)
    }

    private func hash() async throws -> String {
        try await session.client.auth().hashPassword(email: session.account?.email ?? "", password: password, kdfParams: session.kdf, purpose: .serverAuthorization)
    }
    private func start() async {
        do { secret = try await session.api.send("POST", "/api/two-factor/get-authenticator", ["masterPasswordHash": try await hash()])["key"] as? String }
        catch { self.error = error.localizedDescription }
    }
    private func enable() async {
        do { try await session.api.send("PUT", "/api/two-factor/authenticator", ["masterPasswordHash": try await hash(), "key": secret ?? "", "token": code]); on = true }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: import / export

struct ImportView: View {
    @Environment(Session.self) private var session
    @State private var picking = false
    @State private var rows: [Draft] = []
    @State private var done = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("1Password: File → Export → CSV. Chrome: Settings → Passwords → Export passwords. Apple Passwords, Bitwarden and most others export CSV too.")
                    .font(.subheadline)
                Button { picking = true } label: { Label("Choose the exported file", systemImage: "doc.badge.plus") }
            } footer: { Text("The file is read on this iPhone. Delete it after importing: it holds your passwords in plain text.") }
            if !rows.isEmpty, done == 0 {
                Section("\(rows.count) items found") {
                    ForEach(Array(rows.prefix(30).enumerated()), id: \.offset) { _, d in Text(d.name) }
                    if rows.count > 30 { Text("and \(rows.count - 30) more").foregroundStyle(.secondary) }
                }
                Section { Button { Task { await importAll() } } label: { HStack { Text("Import \(rows.count) items"); if busy { Spacer(); ProgressView() } } }.disabled(busy) }
            }
            if done > 0 { Section { Label("\(done) items imported", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.brand) } }
        }
        .navigationTitle("Import")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { r in
            guard case .success(let url) = r, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            rows = CSVImport.drafts(String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self))
            if rows.isEmpty { error = String(localized: "No logins found in that file.") }
        }
        .errorAlert($error)
    }

    private func importAll() async {
        busy = true; defer { busy = false }
        var n = 0
        for d in rows {
            do {
                let ctx = try await session.client.vault().ciphers().encrypt(cipherView: d.view())
                try await session.api.send("POST", "/api/ciphers", try JSONSerialization.jsonObject(with: Data(try azetCipherRequestJson(ctx: ctx).utf8)))
                n += 1
            } catch { self.error = error.localizedDescription; break }
        }
        try? await session.sync()
        done = n
    }
}

/// CSV exports of 1Password (Title, Url, Username, Password, OTPAuth, …), Chrome/Edge (name, url, username, password,
/// note), Apple Passwords (Title, URL, Username, Password, Notes, OTPAuth), Bitwarden (name, login_uri, …).
enum CSVImport {
    static func drafts(_ text: String) -> [Draft] {
        let table = parse(text)
        guard let head = table.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return [] }
        func col(_ names: String...) -> Int? { head.firstIndex { names.contains($0) } }
        let name = col("title", "name"), url = col("url", "login_uri", "website"), user = col("username", "login_username", "login name")
        let pass = col("password", "login_password"), otp = col("otpauth", "login_totp", "one-time password", "totp"), note = col("notes", "note", "extra")
        let fav = col("favorite")
        return table.dropFirst().compactMap { r in
            func v(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
            guard !(v(name) + v(user) + v(pass)).isEmpty else { return nil }
            var d = Draft(category: .login)
            d.name = v(name).isEmpty ? (URL(string: v(url))?.host ?? v(user)) : v(name)
            d.urls = [v(url)]; d.username = v(user); d.password = v(pass); d.totp = v(otp); d.notes = v(note)
            d.favorite = ["1", "true", "yes"].contains(v(fav).lowercased())
            return d
        }
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    static func parse(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = s.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" { if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

struct ExportView: View {
    @Environment(Session.self) private var session
    @State private var format = 0
    @State private var password = ""
    @State private var file: URL?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $format) { Text("Encrypted (.json, with a password)").tag(0); Text("CSV (plain text)").tag(1) }
                if format == 0 { SecureField("Password for the file", text: $password) }
            } footer: { Text(format == 1 ? "A CSV holds every password in plain text. Delete it once you've moved it." : "Only your private vault is exported. Family vaults belong to the family.") }
            Section { Button("Export") { Task { await export() } }.disabled(format == 0 && password.count < 8) }
            if let file { Section { ShareLink(item: file) { Label("Save or send the file", systemImage: "square.and.arrow.up") } } }
        }
        .navigationTitle("Export")
        .errorAlert($error)
    }
    private func export() async {
        do {
            let data = try await session.api.raw("GET", "/api/sync?excludeDomains=true")
            let json = String(data: data, encoding: .utf8) ?? ""
            let personal = try azetCiphersFromJson(json: json).filter { $0.organizationId == nil && $0.deletedDate == nil }
            let out = try await session.client.exporters().exportVault(folders: try azetFoldersFromJson(json: json), ciphers: personal,
                                                                          format: format == 0 ? .encryptedJson(password: password) : .csv)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("azet-pass-export.\(format == 0 ? "json" : "csv")")
            try out.write(to: url, atomically: true, encoding: .utf8)
            file = url
        } catch { self.error = error.localizedDescription }
    }
}

/// 1Password Emergency Kit: a page to print and keep at home with the sign-in address and a blank for the password.
struct EmergencyKitView: View {
    @Environment(Session.self) private var session
    @State private var pdf: URL?
    var body: some View {
        Form {
            Section {
                Text("Print it, write your account password on it by hand, and keep it with other important papers. A family organizer can also help you back in.")
                Button("Make the Emergency Kit") { pdf = make() }
                if let pdf { ShareLink(item: pdf) { Label("Print or save", systemImage: "printer") } }
            }
        }
        .navigationTitle("Emergency Kit")
    }
    private func make() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AZET-Pass-Emergency-Kit.pdf")
        let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try? r.writePDF(to: url) { ctx in
            ctx.beginPage()
            func draw(_ s: String, _ y: CGFloat, _ size: CGFloat, bold: Bool = false) {
                (s as NSString).draw(in: CGRect(x: 56, y: y, width: 483, height: 200), withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)])
            }
            draw("AZET Pass — " + String(localized: "Emergency Kit"), 56, 26, bold: true)
            draw(String(localized: "Created for") + " \(session.account?.name ?? "") · \(Date().formatted(date: .long, time: .omitted))", 100, 12)
            draw(String(localized: "Sign-in address"), 160, 12, bold: true); draw("https://pass.azet.io", 180, 16)
            draw(String(localized: "Email"), 230, 12, bold: true); draw(session.account?.email ?? "", 250, 16)
            draw(String(localized: "Account password (write it by hand)"), 300, 12, bold: true)
            UIColor.gray.setStroke(); let p = UIBezierPath(rect: CGRect(x: 56, y: 322, width: 483, height: 44)); p.stroke()
            if let f = session.families.first {
                draw(String(localized: "Family"), 400, 12, bold: true); draw(f.name + " — " + String(localized: "a family organizer can help you back in"), 420, 14)
            }
            draw(String(localized: "Keep this page somewhere safe at home. Anyone with it and your password can open your vault."), 760, 11)
        }
        return url
    }
}

struct GeneratorView: View {
    @Environment(Session.self) private var session
    @State private var words = false
    @State private var length = 20.0
    @State private var symbols = true
    @State private var value = ""
    var body: some View {
        Form {
            Section {
                Text(value).font(.title3.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                StrengthBar(score: session.strength(value))
                HStack { Button("Copy") { copyToClipboard(value) }; Spacer(); Button("New") { make() } }
            }
            Section {
                Picker("Type", selection: $words) { Text("Random").tag(false); Text("Words").tag(true) }.pickerStyle(.segmented)
                if !words {
                    Stepper("Length \(Int(length))", value: $length, in: 8...64)
                    Toggle("Symbols", isOn: $symbols)
                }
            }
        }
        .navigationTitle("Password generator")
        .onAppear(perform: make)
        .onChange(of: words) { make() }.onChange(of: length) { make() }.onChange(of: symbols) { make() }
    }
    private func make() { value = session.generate(length: UInt8(length), symbols: symbols, words: words) }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text("""
            AZET Pass for iPhone — Copyright © 2026 AZET LLC. Licensed under the GNU General Public License v3.0. Source: https://github.com/azet-llc/azet-pass

            Encryption: Bitwarden SDK (sdk-internal), GNU GPL v3.0, Copyright © Bitwarden Inc. Built from source without the Bitwarden-licensed parts. AZET Pass is not made or endorsed by Bitwarden.

            Sync server: warden-worker, MIT licence.

            Password breach checks: Have I Been Pwned (Troy Hunt), range API, CC BY 4.0.

            This program comes with ABSOLUTELY NO WARRANTY. You may redistribute it under the terms of the GPL v3.0: https://www.gnu.org/licenses/gpl-3.0.html
            """).font(.footnote).padding()
        }
        .navigationTitle("Licences")
    }
}

// MARK: parent mode

/// Parent mode: three huge buttons, no tabs, no jargon. Same vault underneath.
struct ParentHomeView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var find = false
    @State private var add = false
    @State private var scan = false
    @State private var help = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Hello, \(session.account?.name ?? "")").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    BigButton(title: String(localized: "Find a password"), symbol: "magnifyingglass", color: Theme.brand) { find = true }
                    BigButton(title: String(localized: "Save a new password"), symbol: "plus", color: .blue) { add = true }
                    BigButton(title: String(localized: "Scan my notebook"), symbol: "camera.fill", color: Theme.warm) { scan = true }
                    if let f = session.families.first, f.status == 2 {
                        BigButton(title: String(localized: "Ask my family for help"), symbol: "person.2.fill", color: .purple) { help = true }
                    }
                    Button("Show the full app") { prefs.parentMode = false }.font(.body).padding(.top, 20)
                }
                .padding(20)
            }
            .background(Theme.page)
            .navigationDestination(isPresented: $find) { ItemListView(filter: .all) }
            .navigationDestination(for: String.self) { ItemDetailView(id: $0) }
            .sheet(isPresented: $add) { NewItemView() }
            .sheet(isPresented: $scan) { ScanNotebookView() }
            .sheet(isPresented: $help) { FamilyHelpSheet() }
        }
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.largeTitle.weight(.bold)).frame(width: 56)
                Text(title).font(.title.bold()).multilineTextAlignment(.leading)
                Spacer()
            }
            .foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, minHeight: 110)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

struct FamilyHelpSheet: View {
    @Environment(Session.self) private var session
    @State private var organizers: [Member] = []
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your family organizer can add logins for you, fix a password, or let you back in if you forget your account password.")
                }
                Section("Family organizers") {
                    ForEach(organizers) { m in
                        HStack { Avatar(name: m.name); Text(m.name).font(.title3); Spacer()
                            ShareLink(item: String(localized: "Can you help me with AZET Pass?")) { Image(systemName: "message.fill") }
                        }
                    }
                }
            }
            .navigationTitle("Family help")
            .task { if let f = session.families.first { organizers = ((try? await session.members(f)) ?? []).filter { $0.role <= 1 && $0.userId != session.account?.userId } } }
        }
    }
}
