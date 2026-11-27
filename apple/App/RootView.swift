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
    @State private var line = 0
    enum Route: Hashable, Identifiable { case signIn, signUp, joinHelp; var id: Self { self } }
    private let lines = [String(localized: "Up to 5 people, each with a private vault"),
                         String(localized: "One photo of the notebook fills in the logins"),
                         String(localized: "Set up a parent's phone from yours"),
                         String(localized: "Locked on your phone. The server sees only scrambled data")]
    private let tick = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                Image("Mark").resizable().scaledToFit().frame(width: 96, height: 96).modifier(Materialize(delay: 0.1))
                // [3.1] headline 22 / line-height 30.8, a second line that swaps every 2.6 s
                Text("The notebook of passwords, for the whole family.").font(.system(size: 22, weight: .medium)).tracking(-0.22)
                    .multilineTextAlignment(.center).padding(.top, 28).padding(.horizontal, 28).modifier(Materialize())
                ZStack {
                    Text(lines[line]).font(.system(size: 17)).foregroundStyle(Pk.secondaryText).multilineTextAlignment(.center)
                        .id(line).transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .blur(3)),
                                                         removal: .opacity.combined(with: .offset(y: -8))))
                }
                .frame(height: 48).padding(.horizontal, 28).padding(.top, 8).modifier(Materialize(delay: 0.42))
                Spacer()
                VStack(spacing: 8) {
                    NavigationLink(value: Route.signUp) { Text("Create a family account") }.buttonStyle(.pill)
                    NavigationLink(value: Route.signIn) { Text("Sign in") }.buttonStyle(.pillSecondary)
                    NavigationLink(value: Route.joinHelp) { Text("I got an invite from my family").font(.system(size: 15, weight: .medium)) }
                        .foregroundStyle(Pk.ink).padding(.top, 10)
                }
                .padding(.horizontal, 24).padding(.bottom, 24).modifier(Materialize(delay: 0.5))
            }
            .background(Pk.screen)
            .onReceive(tick) { _ in withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.4)) { line = (line + 1) % lines.count } }
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

struct JoinHelpView: View {
    @Environment(Prefs.self) private var prefs
    @State private var link = ""
    var body: some View {
        StepScreen(title: String(localized: "Open the link your family sent you"),
                   subtitle: String(localized: "Tap it in KakaoTalk or Messages and AZET Pass fills in everything. Or paste it here."),
                   cta: String(localized: "Open invite"), enabled: URL(string: link).flatMap(Session.parseInvite) != nil) {
            prefs.pendingURL = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
        } content: {
            TextField("Paste the link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().capsuleField()
        }
    }
}

// MARK: sign in

/// [3.1] email, then password, then (only if needed) the authenticator code — one per screen.
struct SignInView: View {
    @Environment(Session.self) private var session
    @State private var step = 0
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            switch step {
            case 0:
                StepScreen(title: String(localized: "What's your email?"), cta: String(localized: "Next"), enabled: email.contains("@")) { step = 1 } content: {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().capsuleField().focused($focused).onSubmit { if email.contains("@") { step = 1 } }
                }
            case 1:
                StepScreen(title: String(localized: "Your account password"),
                           subtitle: String(localized: "It never leaves this phone. Only a one-way proof of it is sent."),
                           cta: String(localized: "Sign in"), busy: busy, enabled: !password.isEmpty) { Task { await go() } } content: {
                    SecureField("Account password", text: $password).textContentType(.password).capsuleField().focused($focused)
                        .onSubmit { Task { await go() } }
                }
            default:
                StepScreen(title: String(localized: "Code from your authenticator app"), cta: String(localized: "Sign in"), busy: busy, enabled: code.count >= 6) { Task { await go() } } content: {
                    TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).capsuleField().focused($focused)
                }
            }
        }
        .animation(.default, value: step)
        .onChange(of: step) { _, _ in focusSoon() }
        .onAppear { focusSoon() }
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
    }

    private func focusSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }

    private func go() async {
        busy = true; defer { busy = false }
        do { try await session.signIn(email: email, password: password, code: step == 2 ? code : nil) }
        catch is TwoFactorNeeded { step = 2 }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: sign up

/// [3.1] one question per screen. Without a mailed or invite proof: email → we mail a link. With it: name (skipped when the
/// invite already has one) → password → type it again.
struct SignUpView: View {
    @Environment(Session.self) private var session
    var mailToken: (token: String, email: String)?
    var invite: Session.Invite?
    var onDone: (() -> Void)?
    @State private var step = 0
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var again = ""
    @State private var mailSent = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var hasProof: Bool { mailToken != nil || invite != nil }
    private var strength: UInt8 { password.isEmpty ? 0 : session.strength(password) }

    var body: some View {
        ZStack {
            if !hasProof {
                StepScreen(title: mailSent ? String(localized: "Check your mail on this iPhone") : String(localized: "What's your email?"),
                           subtitle: mailSent ? String(localized: "Tap the link in it. AZET Pass opens and you finish there.") : String(localized: "We mail you a link to make sure the address is yours."),
                           cta: mailSent ? String(localized: "Send again") : String(localized: "Send me the link"), busy: busy, enabled: email.contains("@")) { Task { await sendMail() } } content: {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().capsuleField().focused($focused)
                }
            } else if step == 0 {
                StepScreen(title: String(localized: "What should your family call you?"), cta: String(localized: "Next"), enabled: !name.isEmpty) { step = 1 } content: {
                    TextField("Your name", text: $name).textContentType(.name).capsuleField().focused($focused)
                }
            } else if step == 1 {
                StepScreen(title: String(localized: "Make your account password"),
                           subtitle: String(localized: "The one password you remember. Write it on paper and keep it at home."),
                           cta: String(localized: "Next"), enabled: password.count >= 8) { step = 2 } content: {
                    SecureField("Account password", text: $password).textContentType(.newPassword).capsuleField().focused($focused)
                    StrengthBar(score: strength).padding(.horizontal, 8)
                }
            } else {
                StepScreen(title: String(localized: "Type it once more"),
                           subtitle: String(localized: "If you ever forget it, a family organizer can help you back in."),
                           cta: String(localized: "Create account"), busy: busy, enabled: password == again) { Task { await create() } } content: {
                    SecureField("Type it again", text: $again).textContentType(.newPassword).capsuleField().focused($focused)
                    if !again.isEmpty, again != password { Text("Not the same yet").font(.system(size: 14)).foregroundStyle(.red).padding(.horizontal, 8) }
                }
            }
        }
        .animation(.default, value: step)
        .onChange(of: step) { _, _ in focusSoon() }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let m = mailToken { email = m.email }
            if let i = invite { email = i.email ?? ""; name = i.displayName ?? "" }
            if hasProof, !name.isEmpty { step = 1 }
            focusSoon()
        }
        .errorAlert($error)
    }

    private func focusSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }

    private func sendMail() async {
        busy = true; defer { busy = false }
        do { try await session.requestSignupMail(email: email); mailSent = true } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        busy = true; defer { busy = false }
        do {
            try await session.signUp(email: email, name: name, password: password, hint: nil, mailToken: mailToken?.token, invite: invite)
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
            Text(session.account?.name ?? session.account?.email ?? "").font(.system(size: 22, weight: .medium))
            Text(session.account?.email ?? "").foregroundStyle(.secondary)
            SecureField("Account password", text: $password).textContentType(.password).capsuleField().padding(.horizontal, 24)
                .onSubmit { Task { await unlock() } }
            Button { Task { await unlock() } } label: { ZStack { Text("Unlock").opacity(busy ? 0 : 1); if busy { ProgressView().tint(Pk.onInk) } } }
                .buttonStyle(.pill).padding(.horizontal, 24).disabled(password.isEmpty || busy)
            if session.biometricOn {
                Button { Task { await bio() } } label: { Label("Unlock with Face ID", systemImage: "faceid") }
            }
            Spacer()
            Button("Use another account") { showSignOut = true }.font(.footnote)
        }
        .background(Pk.screen)
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
