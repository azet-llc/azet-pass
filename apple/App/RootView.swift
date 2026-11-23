import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(Prefs.self) private var prefs
    @State private var invite: Session.Invite?
    @State private var mailToken: (token: String, email: String)?

    var body: some View {
        Group {
            switch session.phase {
            case .loading: ProgressView()
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

// MARK: welcome

struct WelcomeView: View {
    @Binding var mailToken: (token: String, email: String)?
    @State private var route: Route?
    enum Route: Hashable, Identifiable { case signIn, signUp, joinHelp; var id: Self { self } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Image("Mark").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("AZET Pass").font(.system(size: 28, weight: .semibold)).padding(.top, 14)
                Text("The notebook of passwords, for the whole family.").font(.system(size: 17)).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).padding(.top, 6)
                VStack(alignment: .leading, spacing: 14) {
                    Feature(symbol: "person.3.fill", text: String(localized: "Up to 5 people share one family, each with a private vault"))
                    Feature(symbol: "camera.viewfinder", text: String(localized: "Take a photo of the notebook, the logins fill themselves in"))
                    Feature(symbol: "hand.raised.fill", text: String(localized: "Set up a parent's phone from yours, then compare five words"))
                    Feature(symbol: "lock.shield.fill", text: String(localized: "Locked on your phone first: the server only ever sees scrambled data"))
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Layout.cardRadius)).padding(.top, 28)
                Spacer(minLength: 24)
                VStack(spacing: 8) {
                    NavigationLink(value: Route.signUp) { Text("Create a family account") }.buttonStyle(.pill)
                    NavigationLink(value: Route.signIn) { Text("Sign in") }.buttonStyle(.softPill)
                    NavigationLink(value: Route.joinHelp) { Text("I got an invite from my family").font(.system(size: 15, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.brand).padding(.top, 10)
                }
                .padding(.bottom, 28)
            }
            .frame(maxWidth: 390).padding(.horizontal, 24).frame(maxWidth: .infinity)
            .background(Theme.screen)
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .signIn: SignInView()
                case .signUp: SignUpView(mailToken: mailToken)
                case .joinHelp: JoinHelpView()
                }
            }
            .onChange(of: mailToken?.token) { _, t in if t != nil { route = .signUp } }
            .navigationDestination(item: $route) { r in
                if r == .signUp { SignUpView(mailToken: mailToken) }
            }
        }
    }
}

struct Feature: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            IconWell(symbol: symbol, size: 34)
            Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

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

// MARK: sign in

struct SignInView: View {
    @Environment(Session.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needCode = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        StepScreen(title: "Sign in") {
            TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled().pillField()
            SecureField("Account password", text: $password).textContentType(.password).pillField()
                .onSubmit { Task { await go() } }
            if needCode {
                TextField("6-digit code from your authenticator app", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).pillField()
                    .onSubmit { Task { await go() } }
            }
            StepNote("Your account password never leaves this device. Only a one-way proof of it is sent.")
        } action: {
            Button { Task { await go() } } label: { if busy { ProgressView() } else { Text("Sign in") } }
                .buttonStyle(.pill).disabled(email.isEmpty || password.isEmpty || busy)
        }
        .navigationTitle("Sign in")
        .errorAlert($error)
    }

    private func go() async {
        busy = true; defer { busy = false }
        do { try await session.signIn(email: email, password: password, code: needCode ? code : nil) }
        catch is TwoFactorNeeded { needCode = true }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: sign up

struct SignUpView: View {
    @Environment(Session.self) private var session
    var mailToken: (token: String, email: String)?
    var invite: Session.Invite?
    var onDone: (() -> Void)?
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var again = ""
    @State private var hint = ""
    @State private var mailSent = false
    @State private var busy = false
    @State private var error: String?

    private var hasProof: Bool { mailToken != nil || invite != nil }
    private var strength: UInt8 { password.isEmpty ? 0 : session.strength(password) }

    var body: some View {
        StepScreen(title: invite == nil ? "Create account" : "Join your family") {
            TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(hasProof).pillField()
            TextField("Your name", text: $name).textContentType(.name).pillField()
            if invite != nil { StepNote("This is the address your family invited.") }
            if hasProof {
                SecureField("Account password", text: $password).textContentType(.newPassword).pillField().padding(.top, 14)
                StrengthBar(score: strength).padding(.horizontal, 24)
                SecureField("Type it again", text: $again).textContentType(.newPassword).pillField()
                TextField("Hint (optional, never the password)", text: $hint).pillField()
                StepNote("This is the one password you remember. Write it on paper and keep it at home. If you forget it, a family organizer can help you back in.")
            } else {
                StepNote(mailSent ? "Check your mail on this device and open the link. It opens AZET Pass to finish." : "We mail you a link to make sure the address is yours.")
            }
        } action: {
            if hasProof {
                Button { Task { await create() } } label: { if busy { ProgressView() } else { Text("Create account") } }
                    .buttonStyle(.pill).disabled(password.count < 8 || password != again || busy || name.isEmpty)
            } else {
                Button { Task { await sendMail() } } label: { if busy { ProgressView() } else { Text(mailSent ? "Send again" : "Send me the link") } }
                    .buttonStyle(.pill).disabled(!email.contains("@") || busy)
            }
        }
        .navigationTitle(invite == nil ? "Create account" : "Join your family")
        .onAppear {
            if let m = mailToken { email = m.email }
            if let i = invite { email = i.email ?? ""; name = i.displayName ?? "" }
        }
        .errorAlert($error)
    }

    private func sendMail() async {
        busy = true; defer { busy = false }
        do { try await session.requestSignupMail(email: email); mailSent = true } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        busy = true; defer { busy = false }
        do {
            try await session.signUp(email: email, name: name, password: password, hint: hint.isEmpty ? nil : hint, mailToken: mailToken?.token, invite: invite)
            onDone?()
        } catch { self.error = error.localizedDescription }
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
