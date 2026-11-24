import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var invite: Session.Invite?
    @State private var mailToken: (token: String, email: String)?

    var body: some View {
        Group {
            switch session.phase {
            case .loading: OrbitDots()
            case .welcome: WelcomeView(mailToken: $mailToken)
            case .locked: UnlockView()
            case .unlocked:
                if prefs.refuseJailbroken && DeviceIntegrity.isJailbroken { JailbreakRefusal() } else { MainView() }
            }
        }
        .animation(.default, value: session.phase)
        .onChange(of: prefs.pendingURL) { _, url in handle(url) }
        .onAppear { handle(prefs.pendingURL) }
        .sheet(item: $invite) { JoinFamilyView(invite: $0) }
#if DEBUG
        // Screen checks on a debug build: signs in with the account given in the environment (never in a release build).
        .task(id: session.phase) {
            let env = ProcessInfo.processInfo.environment, s = session
            guard let p = env["AZET_PASS_DEBUG_PASSWORD"] else { return }
            if s.phase == .welcome, let e = env["AZET_PASS_DEBUG_EMAIL"] { Task { try? await s.signIn(email: e, password: p, code: nil) } }
            if s.phase == .locked { Task { try? await s.unlock(password: p) } }
            // AZET_PASS_DEBUG_LINK=items|family|watchtower|settings|new opens that screen once the vault is open.
            if s.phase == .unlocked, let l = env["AZET_PASS_DEBUG_LINK"], let u = URL(string: "azetpass://\(l)") { prefs.deepLink = DeepLink(u) }
        }
#endif
    }

    private func handle(_ url: URL?) {
        guard let url else { return }
        prefs.pendingURL = nil
        if let i = Session.parseInvite(url) { invite = i; return }
        if let link = DeepLink(url) { prefs.deepLink = link; return }
        // mailed sign-up link: https://pass.azet.io/redirect-connector.html#finish-signup?token=…&email=…
        if let frag = url.fragment, frag.hasPrefix("finish-signup"), let q = URLComponents(string: "x://y/?" + (frag.split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""))?.queryItems,
           let t = q.first(where: { $0.name == "token" })?.value, let e = q.first(where: { $0.name == "email" })?.value {
            mailToken = (t, e)
        }
    }
}

extension Session.Invite: Identifiable { var id: String { memberId } }

struct JoinHelpView: View {
    @Environment(Prefs.self) private var prefs
    @State private var link = ""
    var body: some View {
        Form {
            Section {
                Text("Open the link your family sent you (KakaoTalk, a text message). It opens AZET Pass and fills in everything for you.")
                TextField("Or paste the link here", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open invite") { prefs.pendingURL = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(URL(string: link).flatMap(Session.parseInvite) == nil)
            }
        }.azetList()
        .navigationTitle("Family invite")
    }
}

struct StrengthBar: View {
    let score: UInt8
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { i in
                Capsule().fill(i < Int(score) ? color : Color(.systemFill)).frame(height: 5)
            }
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
    private var color: Color { [.red, .red, .orange, .yellow, .green][Int(min(score, 4))] }
    private var label: String {
        [String(localized: "Too easy"), String(localized: "Weak"), String(localized: "Fair"), String(localized: "Good"), String(localized: "Strong")][Int(min(score, 4))]
    }
}

// MARK: unlock

struct UnlockView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showSignOut = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image("Mark").resizable().scaledToFit().frame(width: 64, height: 64)
            Text(session.account?.name ?? session.account?.email ?? "").font(.system(size: 22, weight: .medium)).padding(.top, 8)
            Text(session.account?.name == nil ? "" : session.account?.email ?? "").font(.system(size: 15)).foregroundStyle(.secondary).padding(.bottom, 14)
            SecureField("Account password", text: $password).textContentType(.password).pillField()
                .onSubmit { Task { await unlock() } }
            Button { Task { await unlock() } } label: { if busy { ProgressView() } else { Text("Unlock") } }
                .buttonStyle(.pill).disabled(password.isEmpty || busy)
            if session.biometricOn {
                Button { Task { await bio() } } label: { Label(Biometry.unlockLabel, systemImage: Biometry.symbol) }.buttonStyle(.softPill)
            }
            Spacer()
            Button("Use another account") { showSignOut = true }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 20)
        }
        .padding(.horizontal, 24).frame(maxWidth: .infinity)
        .background(Theme.screen)
        .task { if session.biometricOn { await bio() } }
        .confirmationDialog("Sign out of this account on this device?", isPresented: $showSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { session.signOut() }
        }
        .errorAlert($error)
    }

    private func unlock() async {
        busy = true; defer { busy = false }
        do { try await session.unlock(password: password); password = "" } catch { self.error = error.localizedDescription }
    }

    private func bio() async {
        do { try await session.unlockWithBiometrics() } catch {}
    }
}

/// What this device unlocks with: Touch ID on a Mac, Face ID on an iPhone.
enum Biometry {
    #if os(macOS)
    static let unlockLabel = String(localized: "Unlock with Touch ID"), symbol = "touchid"
    #else
    static let unlockLabel = String(localized: "Unlock with Face ID"), symbol = "faceid"
    #endif
}
