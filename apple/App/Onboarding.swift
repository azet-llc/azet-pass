import SwiftUI

// First start: a welcome that comes alive in stages, then one question per screen with one button at the bottom.
// With Reduce Motion on, nothing blurs, scales or rotates: screens simply fade.

enum Ease {
    /// Things that appear: quick start, long soft landing.
    static func settle(_ d: Double) -> Animation { .timingCurve(0.33, 1, 0.68, 1, duration: d) }
    static func leave(_ d: Double) -> Animation { .timingCurve(0.4, 0, 1, 1, duration: d) }
}

private struct Haze: ViewModifier {
    var blur: CGFloat = 0, dy: CGFloat = 0, opacity: Double = 1
    func body(content: Content) -> some View { content.blur(radius: blur).offset(y: dy).opacity(opacity) }
}

extension AnyTransition {
    /// One step replacing another: the old one fades out fast, the new one sharpens in a moment later. No slide.
    static func stageSwap(plain: Bool) -> AnyTransition {
        if plain { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Haze(blur: 10, opacity: 0), identity: Haze()).animation(Ease.settle(0.4).delay(0.18)),
            removal: .modifier(active: Haze(blur: 10, opacity: 0), identity: Haze()).animation(Ease.leave(0.16)))
    }

    /// The changing line of the welcome: the old one leaves upward, the new one rises in.
    static var lineSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Haze(blur: 3, dy: 8, opacity: 0), identity: Haze()).animation(Ease.settle(0.4).delay(0.22)),
            removal: .modifier(active: Haze(dy: -8, opacity: 0), identity: Haze()).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)))
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.scaleEffect(c.isPressed ? 0.97 : 1).animation(.easeInOut(duration: 0.2), value: c.isPressed)
    }
}

/// The one button at the bottom of a step. It ignores a second tap for 0.6 s and shows a spinner while it works.
struct StepCTA: View {
    let title: LocalizedStringKey
    var busy = false
    var disabled = false
    var height: CGFloat = 62
    var width: CGFloat = Layout.column
    let action: () -> Void
    @State private var cooling = false

    var body: some View {
        Button {
            guard !cooling else { return }
            cooling = true
            action()
            Task { try? await Task.sleep(for: .milliseconds(600)); cooling = false }
        } label: {
            ZStack {
                if busy { ProgressView().controlSize(.small).tint(.white).transition(.scale(scale: 0.9).combined(with: .opacity)) }
                else { Text(title).font(.system(size: 18, weight: .medium)).tracking(-0.18).transition(.scale(scale: 0.96).combined(with: .opacity)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: width, minHeight: height).background(Theme.cta, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(PressScale()).disabled(disabled || busy).opacity(disabled ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: busy).animation(.easeOut(duration: 0.2), value: disabled)
    }
}

/// Three dots circling: shown while the app opens.
struct OrbitDots: View {
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.animation(paused: still)) { t in
            let turn = still ? 0 : t.date.timeIntervalSinceReferenceDate / 1.6
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let a = (turn + Double(i) / 3) * 2 * .pi
                    Circle().fill(Color.primary).frame(width: 18, height: 18)
                        .scaleEffect(1 + 0.17 * sin(a)).offset(x: 21 * cos(a), y: 15 * sin(a)).zIndex(sin(a))
                }
            }
            .frame(width: 80, height: 60)
        }
        .accessibilityLabel(Text("Loading"))
    }
}

/// The frame every step shares: back at the top, the step's own block in the middle, one button at the bottom.
struct StepFrame<Content: View>: View {
    let step: Int
    let cta: LocalizedStringKey
    var busy = false
    var disabled = false
    let back: () -> Void
    let action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(Text("Back"))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 4)
            ScrollView {
                ZStack(alignment: .top) {
                    content.id(step).transition(.stageSwap(plain: still))
                }
                .frame(maxWidth: Layout.column).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 20)
            }
            StepCTA(title: cta, busy: busy, disabled: disabled, action: action).padding(.horizontal, 24).padding(.bottom, 16)
        }
        .background(Theme.screen)
        .animation(.default, value: step)
        .navigationBarBackButtonHidden()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/// What one step shows: its question, the one box to answer in, and what went wrong right under the box.
struct StepBody<Field: View>: View {
    let title: LocalizedStringKey
    var lead: String?
    var error: String?
    var note: LocalizedStringKey?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 22, weight: .medium)).tracking(-0.4).multilineTextAlignment(.center)
            if let lead { Text(lead).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Spacer().frame(height: 18)
            field
            if let error {
                Text(error).font(.system(size: 14)).foregroundStyle(.red).multilineTextAlignment(.center)
                    .padding(.top, 4).transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            if let note { StepNote(note) }
        }
        .animation(.easeOut(duration: 0.2), value: error)
    }
}

// MARK: welcome

struct WelcomeView: View {
    @Binding var mailToken: (token: String, email: String)?
    @State private var route: Route?
    @State private var shown = false
    @State private var line = 0
    @Environment(\.accessibilityReduceMotion) private var still
    enum Route: Hashable, Identifiable { case signIn, signUp, joinHelp; var id: Self { self } }

    private let lines = [
        String(localized: "Up to five people, each with a private vault"),
        String(localized: "Photograph the notebook and the logins fill themselves in"),
        String(localized: "Set up a parent's phone from yours"),
        String(localized: "Locked on your phone before anything is sent"),
        String(localized: "Passkeys, cards and one-time codes in one place"),
        String(localized: "Fills in apps and in the browser"),
        String(localized: "Tells you when a password has leaked"),
        String(localized: "The same vault on iPhone, Android and Mac"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                Hero(shown: shown)
                VStack(spacing: 6) {
                    Text("The password notebook for the whole family")
                        .font(.system(size: 22, weight: .medium)).tracking(-0.22).lineSpacing(4).multilineTextAlignment(.center)
                    ZStack {
                        Text(lines[line % lines.count]).id(line).transition(still ? .opacity : .lineSwap)
                            .font(.system(size: 22, weight: .medium)).tracking(-0.22).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                    }
                    .frame(height: 62, alignment: .top).accessibilityHidden(true) // changes every few seconds: not read out each time
                }
                .frame(maxWidth: 340).padding(.top, 26)
                .scaleEffect(shown || still ? 1 : 0.96).blur(radius: shown || still ? 0 : 6).opacity(shown ? 1 : 0)
                .animation(Ease.settle(0.5), value: shown)
                Spacer(minLength: 20)
                VStack(spacing: 7) {
                    StepCTA(title: "Get started free", height: 60, width: 317) { route = .signUp }
                    Button { route = .signIn } label: {
                        Text("Sign in").font(.system(size: 18, weight: .medium)).tracking(-0.18).foregroundStyle(Color.primary)
                            .frame(maxWidth: 317, minHeight: 60).background(Theme.raised, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    Button { route = .joinHelp } label: { Text("I got an invite from my family").font(.system(size: 15, weight: .medium)).frame(minHeight: 44) }
                        .buttonStyle(.plain).foregroundStyle(Theme.brand)
                    Text(Self.legal).font(.system(size: 12)).foregroundStyle(.tertiary).tint(.secondary).multilineTextAlignment(.center)
                }
                .padding(.bottom, 35)
                .scaleEffect(shown || still ? 1 : 0.98).opacity(shown ? 1 : 0)
                .animation(Ease.settle(0.5).delay(0.12), value: shown)
            }
            .frame(maxWidth: 390).padding(.horizontal, 24).frame(maxWidth: .infinity)
            .background(Theme.screen)
            .navigationDestination(item: $route) { r in
                switch r {
                case .signIn: SignInView()
                case .signUp: SignUpView(mailToken: mailToken)
                case .joinHelp: JoinHelpView()
                }
            }
            .onChange(of: mailToken?.token) { _, t in if t != nil { route = nil; Task { route = .signUp } } }
            .task {
                // The mark arrives first; the words and buttons follow a second later.
                if !still { try? await Task.sleep(for: .seconds(1)) }
                shown = true
                while !still, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { line += 1 }
                }
            }
        }
    }

    /// "By continuing you agree to the Terms and the Privacy Policy", with both names as underlined links.
    private static let legal: AttributedString = {
        var s = (try? AttributedString(markdown: String(localized: "By continuing you agree to the [Terms](https://azet.io/terms) and the [Privacy Policy](https://azet.io/privacy)."))) ?? AttributedString()
        for r in s.runs where r.link != nil { s[r.range].underlineStyle = .single }
        return s
    }()
}

/// The mark with what the vault keeps fanned out around it.
private struct Hero: View {
    let shown: Bool
    @State private var out = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var still
    private let side: [(symbol: String, x: CGFloat, y: CGFloat, turn: Double)] = [
        ("key.fill", -126, 24, -14), ("creditcard.fill", -80, 8, -7), ("person.3.fill", 80, 8, 7), ("lock.shield.fill", 126, 24, 14),
    ]
    var body: some View {
        ZStack {
            ForEach(side.indices, id: \.self) { i in
                IconWell(symbol: side[i].symbol, size: 50)
                    .rotationEffect(.degrees(out ? side[i].turn : 0))
                    .offset(x: out ? side[i].x : 0, y: out ? side[i].y : 0)
                    .opacity(out ? 1 : 0)
                    .animation(still ? nil : Ease.settle(0.7).delay(0.15 + 0.05 * Double(i)), value: out)
            }
            Image("Mark").resizable().scaledToFit().frame(width: 88, height: 88)
                .scaleEffect(out ? (breathe ? 1.03 : 1) : 0.8).opacity(out ? 1 : 0)
                .animation(still ? nil : Ease.settle(0.6), value: out)
        }
        .frame(width: 302, height: 147).accessibilityHidden(true)
        .task {
            out = true
            guard !still else { return }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: sign in

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0 // 0 email, 1 password, 2 code from the authenticator app
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        StepFrame(step: step, cta: step == 0 ? "Next" : "Sign in", busy: busy,
                  disabled: [email.isEmpty, password.isEmpty, code.isEmpty][step],
                  back: { if step == 0 { dismiss() } else { error = nil; step = step == 2 ? 1 : 0 } }, action: next) {
            switch step {
            case 0:
                StepBody(title: "What is your email?", error: error) {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).pillField().onSubmit(next)
                }
            case 1:
                StepBody(title: "Your account password", lead: email, error: error,
                         note: "Your account password never leaves this device. Only a one-way proof of it is sent.") {
                    SecureField("Account password", text: $password).textContentType(.password).focused($focused).pillField().onSubmit(next)
                }
            default:
                StepBody(title: "The 6-digit code", lead: String(localized: "From your authenticator app"), error: error) {
                    TextField("6-digit code from your authenticator app", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .focused($focused).pillField().onSubmit(next)
                }
            }
        }
        .onChange(of: email) { error = nil }.onChange(of: password) { error = nil }.onChange(of: code) { error = nil }
        .task(id: step) { try? await Task.sleep(for: .milliseconds(350)); focused = true }
    }

    private func next() {
        if step == 0 {
            email = email.trimmingCharacters(in: .whitespaces)
            if email.contains("@") { step = 1 } else { error = String(localized: "That does not look like an email address.") }
            return
        }
        guard !busy, !password.isEmpty else { return }
        Task {
            busy = true; defer { busy = false }
            do { try await session.signIn(email: email, password: password, code: step == 2 ? code : nil) }
            catch is TwoFactorNeeded { step = 2 }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: sign up

struct SignUpView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    var mailToken: (token: String, email: String)?
    var invite: Session.Invite?
    var onDone: (() -> Void)?
    @State private var step = 0 // 0 email, 1 mail sent, 2 name, 3 password, 4 password again, 5 hint
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var again = ""
    @State private var hint = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var hasProof: Bool { mailToken != nil || invite != nil }
    private var strength: UInt8 { password.isEmpty ? 0 : session.strength(password) }
    private var first: Int { hasProof ? 2 : 0 }

    var body: some View {
        StepFrame(step: step, cta: [LocalizedStringKey("Send me the link"), "Send again", "Next", "Next", "Next", "Create account"][step], busy: busy,
                  disabled: [!email.contains("@"), false, name.trimmingCharacters(in: .whitespaces).isEmpty, password.count < 8, again.isEmpty, false][step],
                  back: { if step == first { dismiss() } else { error = nil; step -= 1 } }, action: next) {
            switch step {
            case 0:
                StepBody(title: "What is your email?", error: error, note: "We mail you a link to make sure the address is yours.") {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).pillField().onSubmit(next)
                }
            case 1:
                StepBody(title: "Check your mail", lead: email, error: error,
                         note: "Check your mail on this device and open the link. It opens AZET Pass to finish.") { EmptyView() }
            case 2:
                StepBody(title: "What should your family call you?", lead: invite == nil ? email : String(localized: "This is the address your family invited.") + "\n" + email, error: error) {
                    TextField("Your name", text: $name).textContentType(.name).focused($focused).pillField().onSubmit(next)
                }
            case 3:
                StepBody(title: "Choose your account password", error: error,
                         note: "This is the one password you remember. Write it on paper and keep it at home. If you forget it, a family organizer can help you back in.") {
                    SecureField("Account password", text: $password).textContentType(.newPassword).focused($focused).pillField().onSubmit(next)
                    StrengthBar(score: strength).padding(.horizontal, 24)
                }
            case 4:
                StepBody(title: "Type it once more", error: error) {
                    SecureField("Type it again", text: $again).textContentType(.newPassword).focused($focused).pillField().onSubmit(next)
                }
            default:
                StepBody(title: "A hint, if you want one", error: error, note: "Never the password itself. You can leave this empty.") {
                    TextField("Hint (optional, never the password)", text: $hint).focused($focused).pillField().onSubmit(next)
                }
            }
        }
        .onAppear {
            if let m = mailToken { email = m.email }
            if let i = invite { email = i.email ?? ""; name = i.displayName ?? "" }
            step = first
        }
        .onChange(of: password) { error = nil }.onChange(of: again) { error = nil }
        .task(id: step) { try? await Task.sleep(for: .milliseconds(350)); focused = step != 1 }
    }

    private func next() {
        guard !busy else { return }
        switch step {
        case 0, 1:
            guard email.contains("@") else { return }
            run { try await session.requestSignupMail(email: email); step = 1 }
        case 2: if !name.trimmingCharacters(in: .whitespaces).isEmpty { step = 3 }
        case 3: if password.count >= 8 { step = 4 }
        case 4: if again == password { step = 5 } else { error = String(localized: "The two passwords are different.") }
        default:
            run {
                try await session.signUp(email: email, name: name, password: password, hint: hint.isEmpty ? nil : hint, mailToken: mailToken?.token, invite: invite)
                onDone?()
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            busy = true; defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}
