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
            case .unlocked: MainView()
            }
        }
        .animation(.default, value: session.phase)
        .onChange(of: prefs.pendingURL) { _, url in handle(url) }
        .onAppear { handle(prefs.pendingURL) }
        .sheet(item: $invite) { JoinFamilyView(invite: $0) }
    }

    private func handle(_ url: URL?) {
        guard let url else { return }
        prefs.pendingURL = nil
        if let i = Session.parseInvite(url) { invite = i; return }
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
                Spacer()
                Image("Mark").resizable().scaledToFit().frame(width: 76, height: 76)
                Text("AZET Pass").font(.largeTitle.bold()).padding(.top, 12)
                Text("The notebook of passwords, for the whole family.").font(.title3).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).padding(.top, 6).padding(.horizontal, 32)
                VStack(alignment: .leading, spacing: 14) {
                    Feature(symbol: "person.3.fill", text: String(localized: "Up to 5 people share one family, each with a private vault"))
                    Feature(symbol: "camera.viewfinder", text: String(localized: "Take a photo of the notebook, the logins fill themselves in"))
                    Feature(symbol: "hand.raised.fill", text: String(localized: "Set up a parent's phone from yours, then compare four words"))
                    Feature(symbol: "lock.shield.fill", text: String(localized: "Locked on your phone first: the server only ever sees scrambled data"))
                }
                .padding(24)
                Spacer()
                VStack(spacing: 12) {
                    NavigationLink(value: Route.signUp) { Text("Create a family account").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    NavigationLink(value: Route.signIn) { Text("Sign in").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                    NavigationLink(value: Route.joinHelp) { Text("I got an invite from my family") }.padding(.top, 4)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.brand).frame(width: 30)
            Text(text).font(.body)
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
        }
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
        Form {
            Section {
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Account password", text: $password).textContentType(.password)
                if needCode {
                    TextField("6-digit code from your authenticator app", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                }
            } footer: { Text("Your account password never leaves this phone. Only a one-way proof of it is sent.") }
            Section {
                Button {
                    Task { await go() }
                } label: { HStack { Text("Sign in"); if busy { Spacer(); ProgressView() } } }
                .disabled(email.isEmpty || password.isEmpty || busy)
            }
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
        Form {
            Section {
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(hasProof)
                TextField("Your name", text: $name).textContentType(.name)
            } footer: {
                if invite != nil { Text("This is the address your family invited.") }
            }
            if hasProof {
                Section {
                    SecureField("Account password", text: $password).textContentType(.newPassword)
                    StrengthBar(score: strength)
                    SecureField("Type it again", text: $again).textContentType(.newPassword)
                    TextField("Hint (optional, never the password)", text: $hint)
                } header: { Text("Account password") } footer: {
                    Text("This is the one password you remember. Write it on paper and keep it at home. If you forget it, a family organizer can help you back in.")
                }
                Section {
                    Button { Task { await create() } } label: { HStack { Text("Create account"); if busy { Spacer(); ProgressView() } } }
                        .disabled(password.count < 8 || password != again || busy || name.isEmpty)
                }
            } else {
                Section {
                    Button { Task { await sendMail() } } label: { HStack { Text(mailSent ? "Send again" : "Send me the link"); if busy { Spacer(); ProgressView() } } }
                        .disabled(!email.contains("@") || busy)
                } footer: {
                    Text(mailSent ? "Check your mail on this iPhone and tap the link. It opens AZET Pass to finish." : "We mail you a link to make sure the address is yours.")
                }
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
        VStack(spacing: 20) {
            Spacer()
            Image("Mark").resizable().scaledToFit().frame(width: 64, height: 64)
            Text(session.account?.name ?? session.account?.email ?? "").font(.title2.bold())
            Text(session.account?.email ?? "").foregroundStyle(.secondary)
            SecureField("Account password", text: $password).textContentType(.password)
                .padding().background(Theme.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24)
                .onSubmit { Task { await unlock() } }
            Button { Task { await unlock() } } label: { HStack { if busy { ProgressView() } else { Text("Unlock") } }.frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 24).disabled(password.isEmpty || busy)
            if session.biometricOn {
                Button { Task { await bio() } } label: { Label("Unlock with Face ID", systemImage: "faceid") }
            }
            Spacer()
            Button("Use another account") { showSignOut = true }.font(.footnote)
        }
        .background(Theme.page)
        .task { if session.biometricOn { await bio() } }
        .confirmationDialog("Sign out of this account on this iPhone?", isPresented: $showSignOut, titleVisibility: .visible) {
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
