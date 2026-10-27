import BitwardenSdk
import SwiftUI

struct FamilyView: View {
    @Environment(Session.self) private var session
    @State private var showSettings = false
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Group {
                if let f = session.families.first(where: { $0.status == 2 }) {
                    FamilyHome(family: f)
                } else if let f = session.families.first {
                    WaitingForConfirm(family: f)
                } else {
                    CreateFamilyView()
                }
            }
            .navigationTitle("Family")
            .toolbar { MainToolbar(showSettings: $showSettings, showNew: $showNew) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNew) { NewItemView() }
        }
    }
}

struct CreateFamilyView: View {
    @Environment(Session.self) private var session
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "person.3.fill").font(.largeTitle).foregroundStyle(Theme.brand)
                    Text("Make your family").font(.title2.bold())
                    Text("Up to 5 people, each with their own private vault, plus a Shared vault for the Wi-Fi, Netflix and everything the family uses together. As the family organizer you can help anyone who forgets their password.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            Section {
                TextField("Family name (e.g. the Kims)", text: $name)
                Button { Task { await create() } } label: { HStack { Text("Make the family"); if busy { Spacer(); ProgressView() } } }
                    .disabled(name.isEmpty || busy)
            } footer: { Text("Got an invite instead? Open the link your family sent you.") }
        }
        .errorAlert($error)
    }
    private func create() async {
        busy = true; defer { busy = false }
        do { try await session.createFamily(name: name, firstVault: String(localized: "Shared")) } catch { self.error = error.localizedDescription }
    }
}

struct WaitingForConfirm: View {
    @Environment(Session.self) private var session
    let family: Family
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Almost in \(family.name)").font(.title2.bold())
                    Text("Read these words to the person who invited you. When they see the same words, they let you in and the family's items appear here.")
                    FingerprintWords(phrase: session.myFingerprint())
                }.padding(.vertical, 6)
            }
            Section { Button("Check again") { Task { try? await session.sync() } } }
        }
        .refreshable { try? await session.sync() }
    }
}

struct FingerprintWords: View {
    let phrase: String
    var body: some View {
        let words = phrase.split(separator: "-").map(String.init)
        HStack(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                VStack(spacing: 2) {
                    Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    Text(w).font(.headline.monospaced())
                }
                .padding(.vertical, 8).frame(maxWidth: .infinity).background(Theme.warm.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FamilyHome: View {
    @Environment(Session.self) private var session
    let family: Family
    @State private var members: [Member] = []
    @State private var invite = false
    @State private var newVault = false
    @State private var confirming: Member?
    @State private var error: String?

    var body: some View {
        List {
            Section { SetupChecklist(family: family, members: members, invite: $invite) }
            Section {
                ForEach(members) { m in
                    NavigationLink { MemberView(family: family, member: m, onChange: reload) } label: { MemberRow(member: m) }
                        .swipeActions {
                            if family.isOrganizer, m.status == 1 { Button("Let in") { confirming = m }.tint(Theme.brand) }
                        }
                }
                if family.isOrganizer, members.filter({ $0.role != 5 }).count < 5 {
                    Button { invite = true } label: { Label("Invite someone", systemImage: "person.badge.plus") }
                }
            } header: { Text("\(family.name) · \(members.filter { $0.role != 5 }.count)/5") }
            Section("Shared vaults") {
                ForEach(session.vaults.filter { $0.organizationId == family.id }, id: \.id) { v in
                    NavigationLink { VaultView(family: family, vault: v, members: members) } label: {
                        HStack {
                            Label(v.name, systemImage: "person.2.fill")
                            Spacer()
                            Text("\(session.items.filter { $0.collectionIds.contains(v.id ?? "") && $0.deletedDate == nil }.count)").foregroundStyle(.secondary)
                        }
                    }
                }
                if family.role != 5 { Button { newVault = true } label: { Label("New shared vault", systemImage: "plus") } }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $invite, onDismiss: { Task { await reload() } }) { InviteView(family: family) }
        .sheet(isPresented: $newVault) { VaultEditView(family: family, members: members, vault: nil) }
        .sheet(item: $confirming, onDismiss: { Task { await reload() } }) { ConfirmMemberView(family: family, member: $0) }
        .errorAlert($error)
    }

    private func reload() async {
        do { members = try await session.members(family); try? await session.sync() } catch { self.error = error.localizedDescription }
    }
}

struct MemberRow: View {
    let member: Member
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: member.name)
            VStack(alignment: .leading) {
                Text(member.name).font(.body)
                Text(member.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(member.statusText).font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((member.status == 2 ? Color.green : member.status == 1 ? Theme.warm : Color.gray).opacity(0.18), in: Capsule())
        }
    }
}

extension Member {
    var statusText: String {
        switch status {
        case 0: String(localized: "Invited")
        case 1: String(localized: "Waiting for you")
        case 2: roleText
        default: String(localized: "Suspended")
        }
    }
    var roleText: String {
        switch role {
        case 0, 1: String(localized: "Organizer")
        case 5: String(localized: "Guest")
        default: String(localized: "Member")
        }
    }
}

/// The checklist that gets four people set up in one day: each step names the next thing to do and who does it.
struct SetupChecklist: View {
    @Environment(Session.self) private var session
    let family: Family
    let members: [Member]
    @Binding var invite: Bool

    var body: some View {
        let others = members.filter { $0.userId != session.account?.userId && $0.role != 5 }
        let steps: [(String, Bool)] = [
            (String(localized: "Family made"), true),
            (String(localized: "Everyone invited (\(others.count)/4)"), others.count >= 1),
            (String(localized: "Their vaults filled in for them"), session.vaults.contains { v in v.organizationId == family.id && session.items.contains { $0.collectionIds.contains(v.id ?? "") } }),
            (String(localized: "Everyone opened the link"), !others.isEmpty && others.allSatisfy { $0.status >= 1 }),
            (String(localized: "Everyone let in after the four words"), !others.isEmpty && others.allSatisfy { $0.status == 2 }),
        ]
        let done = steps.filter(\.1).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Family setup").font(.headline)
                Spacer()
                Text("\(done)/\(steps.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(steps.count)).tint(Theme.brand)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                Label(s.0, systemImage: s.1 ? "checkmark.circle.fill" : "circle").foregroundStyle(s.1 ? Theme.brand : .secondary)
            }
            if done < steps.count, family.isOrganizer {
                Text(next(steps)).font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func next(_ steps: [(String, Bool)]) -> String {
        if !steps[1].1 { return String(localized: "Next: tap Invite someone. You can add a parent's logins for them before they even install the app.") }
        if !steps[2].1 { return String(localized: "Next: open a person's vault and add their logins, or scan their notebook page.") }
        if !steps[3].1 { return String(localized: "Next: send each person their link (KakaoTalk or text). They tap it and make their password.") }
        return String(localized: "Next: call them and compare the four words, then tap Let in.")
    }
}

struct InviteView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let family: Family
    @State private var name = ""
    @State private var email = ""
    @State private var role = 2
    @State private var ownVault = true
    @State private var link: URL?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let link {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Invite ready", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.brand)
                            Text("Send this link to \(name). When they open it on their phone, AZET Pass installs, fills in their email and asks them to make a password.")
                        }
                        ShareLink(item: link, message: Text(String(localized: "\(session.account?.name ?? "") invited you to the \(family.name) family on AZET Pass. Open this link on your phone:"))) {
                            Label("Send the link", systemImage: "square.and.arrow.up")
                        }
                        Button { copyToClipboard(link.absoluteString) } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    }
                    if ownVault {
                        Section { Text("A vault called \"\(name)\" is ready. Add their logins now, so everything is there the moment they join.").foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        TextField("Name (e.g. Mom)", text: $name)
                        TextField("Their email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Role", selection: $role) {
                            Text("Member").tag(2); Text("Family organizer").tag(1); Text("Guest (one vault only)").tag(5)
                        }
                    } footer: {
                        Text(role == 1 ? "Organizers can invite people and help anyone back in if they forget their password." : role == 5 ? "Guests see one vault you choose, like the babysitter with the Wi-Fi and alarm code." : "Members get a private vault and the Shared vault.")
                    }
                    if role != 5 {
                        Section {
                            Toggle("Make a vault to fill in for them", isOn: $ownVault)
                        } footer: { Text("You and they can both see it. Add their bank, government and shopping logins before they join, then they only have to open the link.") }
                    }
                    Section {
                        Button { Task { await make() } } label: { HStack { Text("Create invite link"); if busy { Spacer(); ProgressView() } } }
                            .disabled(name.isEmpty || !email.contains("@") || busy)
                    }
                }
            }
            .navigationTitle("Invite")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(link == nil ? "Cancel" : "Done") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private func make() async {
        busy = true; defer { busy = false }
        do {
            let shared = session.vaults.filter { $0.organizationId == family.id }
            var access: [String: Bool] = [:]
            if role == 5 { if let first = shared.first?.id { access[first] = true } }
            else { for v in shared where v.name == String(localized: "Shared") { access[v.id ?? ""] = false } }
            let url = try await session.invite(to: family, email: email, name: name, role: role, vaults: access)
            if ownVault, role != 5 {
                let members = try await session.members(family)
                if let m = members.first(where: { $0.email == email.lowercased() }), let me = members.first(where: { $0.userId == session.account?.userId }) {
                    try await session.createVault(in: family, name: name, access: [m.id: false, me.id: false])
                }
            }
            link = url
        } catch { self.error = error.localizedDescription }
    }
}

/// Organizer side of the four-word check. The family key goes to the member only after the words match.
struct ConfirmMemberView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let family: Family
    let member: Member
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Call \(member.name) and ask them to read their four words.").font(.headline)
                        FingerprintWords(phrase: session.fingerprint(userId: member.userId ?? "", publicKey: member.publicKey ?? ""))
                        Text("Same words? Let them in. Different words? Someone else may have the link: tap Not the same and send a new invite.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                Section {
                    Button { Task { await confirm() } } label: { HStack { Label("Same words, let them in", systemImage: "checkmark.circle.fill"); if busy { Spacer(); ProgressView() } } }
                    Button(role: .destructive) { Task { try? await session.remove(member, from: family); dismiss() } } label: { Label("Not the same", systemImage: "xmark.circle") }
                }
            }
            .navigationTitle(member.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private func confirm() async {
        busy = true; defer { busy = false }
        do { try await session.confirm(member, in: family); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct MemberView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let family: Family
    @State var member: Member
    var onChange: () async -> Void
    @State private var link: URL?
    @State private var recover = false
    @State private var confirmRemove = false
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        List {
            Section { MemberRow(member: member) }
            if family.isOrganizer, member.userId != session.account?.userId {
                if member.status == 0 {
                    Section {
                        Button { Task { link = try? await session.reinvite(member, in: family) } } label: { Label("Make a new invite link", systemImage: "link") }
                        if let link { ShareLink(item: link) { Label("Send the link", systemImage: "square.and.arrow.up") } }
                    } footer: { Text("They haven't opened their link yet. A new link stops the old one from working.") }
                }
                if member.status == 1 { Section { Button { confirming = true } label: { Label("Compare the four words", systemImage: "checkmark.shield") } } }
                Section("Access") {
                    Picker("Role", selection: Binding(get: { member.role }, set: { r in member.role = r; Task { try? await session.updateMember(member, in: family, role: r, vaults: member.vaults); await onChange() } })) {
                        Text("Member").tag(2); Text("Family organizer").tag(1); Text("Guest").tag(5)
                    }
                    ForEach(session.vaults.filter { $0.organizationId == family.id }, id: \.id) { v in
                        let vid = v.id ?? ""
                        Picker(v.name, selection: Binding(get: { member.vaults[vid].map { $0 ? 1 : 2 } ?? 0 }, set: { x in
                            if x == 0 { member.vaults[vid] = nil } else { member.vaults[vid] = x == 1 }
                            Task { try? await session.updateMember(member, in: family, role: member.role, vaults: member.vaults); await onChange() }
                        })) { Text("No access").tag(0); Text("View only").tag(1); Text("View & edit").tag(2) }
                    }
                }
                Section {
                    if member.status == 2 {
                        Button { recover = true } label: { Label("Help with a forgotten password", systemImage: "key.horizontal") }.disabled(!member.recoveryOn)
                    }
                    Button { Task { try? await session.setMember(member, in: family, suspended: member.status != -1); await onChange(); dismiss() } } label: {
                        Label(member.status == -1 ? "Restore access" : "Suspend", systemImage: member.status == -1 ? "play.circle" : "pause.circle")
                    }
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from family", systemImage: "person.fill.xmark") }
                } footer: {
                    if !member.recoveryOn, member.status == 2 { Text("Recovery turns on when they join from this app.") }
                }
            }
            if member.userId == session.account?.userId, !family.isOrganizer || session.families.count > 0 {
                Section { Button(role: .destructive) { Task { try? await session.leave(family) } } label: { Text("Leave this family") } }
            }
        }
        .navigationTitle(member.name)
        .sheet(isPresented: $recover) { RecoverMemberView(family: family, member: member) }
        .sheet(isPresented: $confirming, onDismiss: { Task { await onChange() } }) { ConfirmMemberView(family: family, member: member) }
        .confirmationDialog("Remove \(member.name)? Their private vault stays theirs; they lose the family vaults.", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { try? await session.remove(member, from: family); await onChange(); dismiss() } }
        }
        .errorAlert($error)
    }
}

struct RecoverMemberView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let family: Family
    let member: Member
    @State private var temp = ""
    @State private var done = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label("\(member.name) can sign in now", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.brand)
                        Text("Tell them this temporary password in person or on the phone. Ask them to change it in Settings after signing in.")
                        FieldRow(label: String(localized: "Temporary password"), value: temp)
                    }
                } else {
                    Section {
                        Text("\(member.name) forgot their account password. Set a temporary one; their items stay exactly as they are.")
                        HStack {
                            TextField("Temporary password", text: $temp).font(.body.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.never)
                            Button { temp = session.generate(words: true) } label: { Image(systemName: "wand.and.stars") }
                        }
                    } footer: { Text("They will be signed out on every device.") }
                    Section {
                        Button { Task { await go() } } label: { HStack { Text("Set temporary password"); if busy { Spacer(); ProgressView() } } }
                            .disabled(temp.count < 8 || busy)
                    }
                }
            }
            .navigationTitle("Account recovery")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(done ? "Done" : "Cancel") { dismiss() } } }
            .onAppear { temp = session.generate(words: true) }
            .errorAlert($error)
        }
    }
    private func go() async {
        busy = true; defer { busy = false }
        do { try await session.recover(member, in: family, temporaryPassword: temp); done = true } catch { self.error = error.localizedDescription }
    }
}

struct VaultView: View {
    @Environment(Session.self) private var session
    let family: Family
    let vault: CollectionView
    let members: [Member]
    @State private var edit = false
    @State private var add = false
    @State private var scan = false

    var body: some View {
        let items = session.items.filter { $0.collectionIds.contains(vault.id ?? "") && $0.deletedDate == nil }
        List {
            Section {
                let who = members.filter { m in m.role <= 1 || m.vaults[vault.id ?? ""] != nil }
                HStack(spacing: -8) { ForEach(who) { Avatar(name: $0.name, size: 30).overlay(Circle().stroke(.background, lineWidth: 2)) } }
                Text(who.map(\.name).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Who can see it") }
            if !vault.readOnly {
                Section {
                    Button { add = true } label: { Label("Add a login for this vault", systemImage: "plus") }
                    Button { scan = true } label: { Label("Scan a notebook page into this vault", systemImage: "camera.viewfinder") }
                }
            }
            Section("Items") {
                ForEach(items) { i in NavigationLink { ItemDetailView(id: i.id ?? "") } label: { ItemRow(item: i) } }
            }
        }
        .navigationTitle(vault.name)
        .toolbar { if family.isOrganizer || vault.manage { Button("Edit") { edit = true } } }
        .sheet(isPresented: $edit) { VaultEditView(family: family, members: members, vault: vault) }
        .sheet(isPresented: $add) { NewItemView(familyVault: vault) }
        .sheet(isPresented: $scan) { ScanNotebookView(target: vault) }
    }
}

struct VaultEditView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let family: Family
    let members: [Member]
    let vault: CollectionView?
    @State private var name = ""
    @State private var access: [String: Bool] = [:]
    @State private var travelSafe = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Vault name", text: $name) }
                Section("People") {
                    ForEach(members.filter { $0.role > 1 }) { m in
                        Picker(m.name, selection: Binding(get: { access[m.id].map { $0 ? 1 : 2 } ?? 0 }, set: { x in access[m.id] = x == 0 ? nil : x == 1 })) {
                            Text("No access").tag(0); Text("View only").tag(1); Text("View & edit").tag(2)
                        }
                    }
                    Text("Family organizers see every shared vault.").font(.footnote).foregroundStyle(.secondary)
                }
                Section { Toggle("Safe for travel", isOn: $travelSafe) } footer: { Text("When someone turns on Travel Mode, only travel-safe vaults stay on their phone.") }
                if let vault {
                    Section { Button("Delete vault and its items", role: .destructive) { confirmDelete = true } }
                        .confirmationDialog("Delete \(vault.name)? Its items are deleted for everyone.", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { Task { try? await session.deleteVault(vault); dismiss() } }
                        }
                }
            }
            .navigationTitle(vault == nil ? "New shared vault" : "Edit vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(name.isEmpty) }
            }
            .onAppear {
                guard let v = vault else { return }
                name = v.name
                for m in members { if let ro = m.vaults[v.id ?? ""] { access[m.id] = ro } }
            }
            .errorAlert($error)
        }
    }

    private func save() async {
        do {
            if let vault { try await session.updateVault(vault, name: name, access: access, travelSafe: travelSafe) }
            else { try await session.createVault(in: family, name: name, access: access, travelSafe: travelSafe) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: joining from an invite link

struct JoinFamilyView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var invite: Session.Invite
    @State private var loaded = false
    @State private var joined = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if joined {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("You're in. One last step").font(.title2.bold())
                                Text("Read these four words to \(invite.invitedBy ?? String(localized: "the person who invited you")). When their screen shows the same words, they let you in.")
                                FingerprintWords(phrase: session.myFingerprint())
                            }.padding(.vertical, 6)
                        }
                    }
                } else if !loaded {
                    ProgressView()
                } else if session.phase == .unlocked {
                    Form {
                        Section {
                            Text("\(invite.invitedBy ?? "") invited you to the \(invite.familyName ?? "") family.").font(.headline)
                            if session.account?.email != invite.email {
                                Text("This invite is for \(invite.email ?? ""). You're signed in as \(session.account?.email ?? ""). Sign out first to use it.").foregroundStyle(.red)
                            }
                        }
                        Section {
                            Button { Task { await join() } } label: { HStack { Text("Join the family"); if busy { Spacer(); ProgressView() } } }
                                .disabled(session.account?.email != invite.email || busy)
                        }
                    }
                } else if session.phase == .locked {
                    VStack(spacing: 12) { Text("Unlock AZET Pass first, then open the link again."); Button("OK") { dismiss() } }.padding()
                } else {
                    VStack(spacing: 0) {
                        Text("\(invite.invitedBy ?? "") invited you to the \(invite.familyName ?? "") family.").font(.headline).padding()
                        SignUpView(invite: invite, onDone: { Task { await join() } })
                    }
                }
            }
            .navigationTitle("Family invite")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(joined ? "Done" : "Close") { dismiss() } } }
            .task {
                do { invite = try await session.preview(invite); loaded = true } catch { self.error = error.localizedDescription; loaded = true }
            }
            .errorAlert($error)
        }
    }

    private func join() async {
        busy = true; defer { busy = false }
        do { try await session.accept(invite); joined = true } catch { self.error = error.localizedDescription }
    }
}
