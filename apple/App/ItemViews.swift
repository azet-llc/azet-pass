import BitwardenSdk
import SwiftUI

// MARK: detail

struct ItemDetailView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var view: CipherView?
    @State private var edit = false
    @State private var share = false
    @State private var move = false
    @State private var history = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let v = view {
                List {
                    Section {
                        HStack(spacing: 14) {
                            ItemIcon(name: v.name, category: ItemCategory.of(v), size: 56)
                            VStack(alignment: .leading) {
                                Text(v.name).font(.title2.bold())
                                Text(where_(v)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    fields(v)
                    if let n = v.notes, !n.isEmpty { Section("Notes") { Text(n).textSelection(.enabled) } }
                    if let f = v.fields?.filter({ $0.name != ItemCategory.marker }), !f.isEmpty {
                        Section { ForEach(Array(f.enumerated()), id: \.offset) { _, x in FieldRow(label: x.name ?? "", value: x.value ?? "", secret: x.type == .hidden) } }
                    }
                    if let p = v.login?.fido2Credentials, !p.isEmpty {
                        Section("Passkey") { Label("Passkey saved for this site", systemImage: "person.badge.key.fill") }
                    }
                    Section {
                        LabeledContent("Modified", value: v.revisionDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Created", value: v.creationDate.formatted(date: .abbreviated, time: .shortened))
                        if let h = v.passwordHistory, !h.isEmpty { Button("Password history (\(h.count))") { history = true } }
                    }
                    if v.deletedDate == nil {
                        Section {
                            Button { share = true } label: { Label("Share a copy by link", systemImage: "link") }
                            if v.organizationId == nil, !session.vaults.isEmpty {
                                Button { move = true } label: { Label("Move to a family vault", systemImage: "person.2.fill") }
                            }
                            if v.organizationId == nil {
                                Toggle(isOn: Binding(get: { session.isTravelSafe(id) }, set: { on in Task { try? await session.setTravelSafe(id, on) } })) {
                                    Label("Safe for travel", systemImage: "airplane")
                                }
                            }
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.disabled(!v.edit)
                        }
                    } else {
                        Section {
                            Button { Task { try? await session.restore(id); dismiss() } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { Task { try? await session.purge(id); dismiss() } } label: { Label("Delete for good", systemImage: "trash.slash") }
                        }
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { Task { try? await session.setFavorite(id, !v.favorite); await load() } } label: { Image(systemName: v.favorite ? "star.fill" : "star") }
                            .accessibilityLabel(Text("Favorite"))
                        if v.edit, v.deletedDate == nil { Button("Edit") { edit = true } }
                    }
                }
                .sheet(isPresented: $edit, onDismiss: { Task { await load() } }) { ItemEditView(draft: Draft(v)) }
                .sheet(isPresented: $share) { ShareLinkView(item: v) }
                .sheet(isPresented: $history) { PasswordHistoryView_(entries: v.passwordHistory ?? []) }
                .confirmationDialog("Move to a family vault", isPresented: $move) {
                    ForEach(session.vaults.filter { !$0.readOnly }, id: \.id) { vault in
                        Button(vault.name) { Task { do { try await session.move(id, to: vault); await load() } catch { self.error = error.localizedDescription } } }
                    }
                } message: { Text("Everyone with access to that vault will see this item.") }
                .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Move to Recently Deleted", role: .destructive) { Task { try? await session.trash(id); dismiss() } }
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .errorAlert($error)
    }

    private func load() async {
        do { view = try await session.view(id) } catch { self.error = error.localizedDescription }
    }

    private func where_(_ v: CipherView) -> String {
        guard v.organizationId != nil else { return String(localized: "Private vault") }
        let names = v.collectionIds.map(session.vaultName).filter { !$0.isEmpty }
        return names.isEmpty ? String(localized: "Family") : names.joined(separator: ", ")
    }

    @ViewBuilder private func fields(_ v: CipherView) -> some View {
        switch v.type {
        case .login:
            Section {
                if let u = v.login?.username, !u.isEmpty { FieldRow(label: String(localized: "Username"), value: u) }
                if let p = v.login?.password, !p.isEmpty { FieldRow(label: String(localized: "Password"), value: p, secret: true, strength: session.strength(p)) }
                if let t = v.login?.totp, !t.isEmpty { TotpRow(key: t) }
                ForEach(Array((v.login?.uris ?? []).enumerated()), id: \.offset) { _, u in
                    if let s = u.uri, let url = URL(string: s) {
                        LabeledContent(String(localized: "Website")) { Link(url.host ?? s, destination: url) }
                    }
                }
            }
        case .card:
            Section {
                FieldRow(label: String(localized: "Cardholder"), value: v.card?.cardholderName ?? "")
                FieldRow(label: String(localized: "Number"), value: v.card?.number ?? "", secret: true)
                FieldRow(label: String(localized: "Expires"), value: [v.card?.expMonth, v.card?.expYear].compactMap { $0 }.joined(separator: "/"))
                FieldRow(label: String(localized: "Security code"), value: v.card?.code ?? "", secret: true)
            }
        case .identity:
            Section {
                FieldRow(label: String(localized: "Name"), value: [v.identity?.lastName, v.identity?.firstName].compactMap { $0 }.joined(separator: " "))
                FieldRow(label: String(localized: "Email"), value: v.identity?.email ?? "")
                FieldRow(label: String(localized: "Phone"), value: v.identity?.phone ?? "")
                FieldRow(label: String(localized: "Address"), value: [v.identity?.address1, v.identity?.city, v.identity?.postalCode].compactMap { $0 }.joined(separator: " "))
                FieldRow(label: String(localized: "ID number"), value: v.identity?.ssn ?? "", secret: true)
            }
        case .bankAccount:
            Section {
                FieldRow(label: String(localized: "Bank"), value: v.bankAccount?.bankName ?? "")
                FieldRow(label: String(localized: "Account holder"), value: v.bankAccount?.nameOnAccount ?? "")
                FieldRow(label: String(localized: "Account number"), value: v.bankAccount?.accountNumber ?? "", secret: true)
                FieldRow(label: String(localized: "PIN"), value: v.bankAccount?.pin ?? "", secret: true)
            }
        case .driversLicense:
            Section {
                FieldRow(label: String(localized: "Name"), value: [v.driversLicense?.lastName, v.driversLicense?.firstName].compactMap { $0 }.joined(separator: " "))
                FieldRow(label: String(localized: "License number"), value: v.driversLicense?.licenseNumber ?? "", secret: true)
                FieldRow(label: String(localized: "Expires"), value: v.driversLicense?.expirationDate?.formatted(date: .numeric, time: .omitted) ?? "")
            }
        case .passport:
            Section {
                FieldRow(label: String(localized: "Name"), value: [v.passport?.surname, v.passport?.givenName].compactMap { $0 }.joined(separator: " "))
                FieldRow(label: String(localized: "Passport number"), value: v.passport?.passportNumber ?? "", secret: true)
                FieldRow(label: String(localized: "Expires"), value: v.passport?.expirationDate?.formatted(date: .numeric, time: .omitted) ?? "")
            }
        case .sshKey:
            Section {
                FieldRow(label: String(localized: "Public key"), value: v.sshKey?.publicKey ?? "")
                FieldRow(label: String(localized: "Fingerprint"), value: v.sshKey?.fingerprint ?? "")
                FieldRow(label: String(localized: "Private key"), value: v.sshKey?.privateKey ?? "", secret: true)
            }
        default: EmptyView()
        }
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    var secret = false
    var strength: UInt8?
    @State private var reveal = false
    @State private var large = false

    var body: some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(secret && !reveal ? String(repeating: "•", count: min(value.count, 12)) : value)
                        .font(secret ? .body.monospaced() : .body).lineLimit(secret ? 1 : nil).textSelection(.enabled)
                    Spacer()
                    if secret { Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        .accessibilityLabel(Text(reveal ? "Hide" : "Show")) }
                    Button { copyToClipboard(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy \(label)"))
                }
                if let strength { StrengthBar(score: strength) }
            }
            .contextMenu {
                Button { copyToClipboard(value) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { large = true } label: { Label("Show in large type", systemImage: "textformat.size") }
            }
            .sheet(isPresented: $large) { LargeType(text: value) }
        }
    }
}

/// 1Password "Large Type": every character big, numbers and symbols coloured, for reading off to someone.
struct LargeType: View {
    let text: String
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 10) {
                ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                    VStack {
                        Text(String(ch)).font(.system(size: 40, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ch.isNumber ? .blue : ch.isLetter ? .primary : .red)
                        Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 56, minHeight: 72).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
    }
}

struct TotpRow: View {
    @Environment(Session.self) private var session
    let key: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let r = session.totp(key)
            let left = Double(r?.period ?? 30) - ctx.date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(r?.period ?? 30))
            VStack(alignment: .leading, spacing: 4) {
                Text("One-time password").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(format(r?.code ?? "------")).font(.title2.monospacedDigit().weight(.semibold))
                    Spacer()
                    ZStack {
                        Circle().stroke(Color(.systemFill), lineWidth: 3)
                        Circle().trim(from: 0, to: left / Double(r?.period ?? 30)).stroke(left < 6 ? .red : Theme.brand, lineWidth: 3).rotationEffect(.degrees(-90))
                        Text("\(Int(left))").font(.caption2.monospacedDigit())
                    }
                    .frame(width: 28, height: 28)
                    Button { copyToClipboard(r?.code ?? "") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy one-time password"))
                }
            }
        }
    }
    private func format(_ c: String) -> String { c.count == 6 ? "\(c.prefix(3)) \(c.suffix(3))" : c }
}

struct PasswordHistoryView_: View {
    let entries: [PasswordHistoryView]
    var body: some View {
        NavigationStack {
            List(Array(entries.enumerated()), id: \.offset) { _, e in
                FieldRow(label: e.lastUsedDate.formatted(date: .abbreviated, time: .shortened), value: e.password, secret: true)
            }
            .navigationTitle("Password history")
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: new item

struct NewItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var draft: Draft?
    @State private var scan = false
    var familyVault: CollectionView?

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Button { scan = true } label: { Label("Scan a notebook page", systemImage: "camera.viewfinder") }
                    }
                    Section("Categories") {
                        ForEach(ItemCategory.allCases) { c in
                            Button { draft = Draft(category: c).placed(in: familyVault) } label: { Label(c.title, systemImage: c.symbol) }
                        }
                    }
                }
                let presets = Preset.forDevice().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
                ForEach(Preset.Group.allCases, id: \.self) { g in
                    let list = presets.filter { $0.group == g }
                    if !list.isEmpty {
                        Section(g.title) {
                            ForEach(list) { p in
                                Button { draft = Draft(preset: p).placed(in: familyVault) } label: {
                                    HStack { ItemIcon(name: p.name, size: 30); Text(p.name) }
                                }
                            }
                        }
                    }
                }
                if !query.isEmpty {
                    Button { var d = Draft(category: .login); d.name = query; draft = d.placed(in: familyVault) } label: { Label("New login named \"\(query)\"", systemImage: "plus") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Popular logins and categories"))
            .navigationTitle("New item")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: Binding(get: { draft.map(DraftBox.init) }, set: { draft = $0?.draft })) { box in
                ItemEditView(draft: box.draft, onSaved: { dismiss() })
            }
            .sheet(isPresented: $scan) { ScanNotebookView(target: familyVault) }
        }
    }
}

struct DraftBox: Identifiable { let id = UUID(); var draft: Draft }

extension Draft {
    init(preset p: Preset) {
        self.init(category: .login)
        name = p.name
        urls = [p.url]
        fields = p.extras.map { CustomField(name: $0, value: "", hidden: true) }
    }

    func placed(in vault: CollectionView?) -> Draft {
        var d = self
        if let v = vault { d.familyId = v.organizationId; d.vaultIds = [v.id ?? ""] }
        return d
    }
}

// MARK: edit

struct ItemEditView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    var onSaved: (() -> Void)?
    @State private var busy = false
    @State private var error: String?
    @State private var scanTotp = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(draft.category.title, text: $draft.name).font(.title3.weight(.semibold))
                    if draft.id == nil { vaultPicker }
                }
                fields
                if !draft.fields.isEmpty || draft.category.type == .secureNote {
                    Section {
                        ForEach($draft.fields) { $f in
                            VStack(alignment: .leading) {
                                TextField("Label", text: $f.name).font(.caption)
                                if f.hidden { SecureField("Value", text: $f.value) } else { TextField("Value", text: $f.value, axis: .vertical) }
                            }
                        }
                        .onDelete { draft.fields.remove(atOffsets: $0) }
                    }
                }
                Section {
                    Menu {
                        Button("Text") { draft.fields.append(.init(name: "", value: "", hidden: false)) }
                        Button("Password") { draft.fields.append(.init(name: "", value: "", hidden: true)) }
                    } label: { Label("Add more", systemImage: "plus.circle") }
                }
                Section("Notes") { TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...12) }
            }
            .navigationTitle(draft.id == nil ? String(localized: "New \(draft.category.title)") : String(localized: "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if busy { ProgressView() } else { Text("Save").bold() } }.disabled(busy)
                }
            }
            .sheet(isPresented: $scanTotp) { QRScannerView { code in draft.totp = code; scanTotp = false } }
            .errorAlert($error)
        }
    }

    @ViewBuilder private var vaultPicker: some View {
        if !session.vaults.isEmpty {
            Picker("Vault", selection: Binding(get: { draft.vaultIds.first ?? "" }, set: { id in
                if id.isEmpty { draft.familyId = nil; draft.vaultIds = [] }
                else { draft.vaultIds = [id]; draft.familyId = session.vaults.first { $0.id == id }?.organizationId }
            })) {
                Text("Private").tag("")
                ForEach(session.vaults.filter { !$0.readOnly }, id: \.id) { v in Text(v.name).tag(v.id ?? "") }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch draft.category.type {
        case .login:
            Section {
                if draft.category == .login {
                    TextField("Username", text: $draft.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack {
                    SecureField("Password", text: $draft.password).textContentType(.newPassword)
                    Menu {
                        Button("Strong password") { draft.password = session.generate() }
                        Button("Easy to type (words)") { draft.password = session.generate(words: true) }
                        Button("Numbers only (PIN)") { draft.password = String((0..<6).map { _ in "0123456789".randomElement()! }) }
                    } label: { Image(systemName: "wand.and.stars") }.accessibilityLabel(Text("Make a password"))
                }
                if !draft.password.isEmpty { StrengthBar(score: session.strength(draft.password)) }
            }
            if draft.category == .login {
                Section("Websites") {
                    ForEach(draft.urls.indices, id: \.self) { i in
                        TextField("Website", text: $draft.urls[i]).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button { draft.urls.append("") } label: { Label("Add website", systemImage: "plus") }
                }
                Section {
                    HStack {
                        TextField("One-time password setup key", text: $draft.totp).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { scanTotp = true } label: { Image(systemName: "qrcode.viewfinder") }.accessibilityLabel(Text("Scan QR code"))
                    }
                } footer: { Text("Two-step login code. Scan the QR code the site shows, or paste its setup key.") }
            }
        case .card:
            Section {
                TextField("Cardholder name", text: $draft.cardholder).textContentType(.name)
                TextField("Card number", text: $draft.cardNumber).keyboardType(.numberPad).textContentType(.creditCardNumber)
                HStack { TextField("MM", text: $draft.expMonth).keyboardType(.numberPad); TextField("YYYY", text: $draft.expYear).keyboardType(.numberPad) }
                SecureField("Security code", text: $draft.code).keyboardType(.numberPad)
                TextField("Brand", text: $draft.brand)
            }
        case .identity:
            Section {
                TextField("Last name", text: $draft.identity.lastName); TextField("First name", text: $draft.identity.firstName)
                TextField("Email", text: $draft.identity.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Phone", text: $draft.identity.phone).keyboardType(.phonePad)
                TextField("Address", text: $draft.identity.address1); TextField("City", text: $draft.identity.city)
                TextField("Postal code", text: $draft.identity.postalCode); TextField("Country", text: $draft.identity.country)
                SecureField("ID number", text: $draft.identity.ssn)
            }
        case .bankAccount:
            Section {
                TextField("Bank", text: $draft.bankName); TextField("Account holder", text: $draft.accountName)
                TextField("Account number", text: $draft.accountNumber).keyboardType(.numbersAndPunctuation)
                TextField("Account type", text: $draft.accountType); SecureField("PIN", text: $draft.pin).keyboardType(.numberPad)
                TextField("SWIFT", text: $draft.swift); TextField("IBAN", text: $draft.iban); TextField("Bank phone", text: $draft.bankPhone).keyboardType(.phonePad)
            }
        case .driversLicense:
            Section {
                TextField("Last name", text: $draft.lastName); TextField("First name", text: $draft.firstName)
                TextField("License number", text: $draft.licenseNumber); TextField("Class", text: $draft.licenseClass)
                TextField("Country", text: $draft.issuingCountry)
                OptionalDate(title: String(localized: "Expires"), date: $draft.expiryDate)
            }
        case .passport:
            Section {
                TextField("Surname", text: $draft.surname); TextField("Given name", text: $draft.givenName)
                TextField("Passport number", text: $draft.passportNumber); TextField("Nationality", text: $draft.nationality)
                OptionalDate(title: String(localized: "Date of birth"), date: $draft.birthDate)
                OptionalDate(title: String(localized: "Expires"), date: $draft.expiryDate)
            }
        case .sshKey:
            Section {
                if draft.sshPrivate.isEmpty {
                    Button("Make a new Ed25519 key") {
                        if let k = try? session.client.ssh().generateSshKey(keyAlgorithm: .ed25519) {
                            draft.sshPrivate = k.privateKey; draft.sshPublic = k.publicKey; draft.sshFingerprint = k.fingerprint
                        }
                    }
                }
                TextField("Public key", text: $draft.sshPublic, axis: .vertical).font(.caption.monospaced())
                SecureField("Private key", text: $draft.sshPrivate)
            }
        default: EmptyView()
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        do {
            try await session.save(draft.view(), vaultIds: draft.vaultIds)
            dismiss(); onSaved?()
        } catch { self.error = error.localizedDescription }
    }
}

struct OptionalDate: View {
    let title: String
    @Binding var date: Date?
    var body: some View {
        if let d = date {
            DatePicker(title, selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
        } else {
            Button(title) { date = Date() }
        }
    }
}
