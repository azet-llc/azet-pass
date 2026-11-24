import AuthenticationServices
import SwiftUI

@main
struct AZETPassApp: App {
    @State private var session = Session()
    @State private var prefs = Prefs()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(prefs)
                .tint(Theme.brand)
#if os(macOS)
                .formStyle(.grouped) // the Mac default (columns) cut the labels off at the window's left edge
                .frame(minWidth: 720, minHeight: 560)
#endif
                .dynamicTypeSize(prefs.parentMode ? DynamicTypeSize.accessibility2 ... .accessibility2 : DynamicTypeSize.xSmall ... .accessibility3)
                .modifier(PrivacyCover())
                .onOpenURL { url in prefs.pendingURL = url }
                .onContinueUserActivity(credentialExchangeActivity) { a in prefs.importToken = a.userInfo?[credentialImportTokenKey] as? UUID }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in if let u = a.webpageURL { prefs.pendingURL = u } }
        }
#if os(macOS)
        .defaultSize(width: 980, height: 700)
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { prefs.wentBackground = Date() }
            if phase == .active, let t = prefs.wentBackground, session.phase == .unlocked,
               Date().timeIntervalSince(t) > Double(prefs.autoLockMinutes * 60) { session.lock() }
        }
    }
}

/// Per-device preferences (no secrets).
@MainActor @Observable
final class Prefs {
    var parentMode: Bool { didSet { d.set(parentMode, forKey: "parentMode") } }
    var autoLockMinutes: Int { didSet { d.set(autoLockMinutes, forKey: "autoLock") } }
    var seenOnboarding: Bool { didSet { d.set(seenOnboarding, forKey: "seenOnboarding") } }
    var watchtowerBreaches: Bool { didSet { d.set(watchtowerBreaches, forKey: "wtBreaches") } }
    var pendingURL: URL?
    var deepLink: DeepLink?
    /// Another app started moving its items here (iOS 26 credential exchange).
    var importToken: UUID?
    /// Samsung Pass: off on a rooted / jailbroken phone. Off by default.
    var refuseJailbroken: Bool { didSet { d.set(refuseJailbroken, forKey: "refuseJailbroken") } }
    var wentBackground: Date?
    private let d = SharedFiles.defaults

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") { d.removeObject(forKey: "parentMode") }
        #endif
        parentMode = d.bool(forKey: "parentMode")
        autoLockMinutes = d.object(forKey: "autoLock") as? Int ?? 5
        seenOnboarding = d.bool(forKey: "seenOnboarding")
        watchtowerBreaches = d.object(forKey: "wtBreaches") as? Bool ?? true
        refuseJailbroken = d.bool(forKey: "refuseJailbroken")
    }
}

enum Theme {
    /// AZET blue #2f6fe8, the family accent (azet-desktop src/shared/design/azet-tokens.ts); warm amber for family moments.
    static let brand = Color(red: 47 / 255, green: 111 / 255, blue: 232 / 255)
    static let warm = Color(red: 0.96, green: 0.64, blue: 0.15)
    /// Flat surfaces: white screen and cards on a #f7f7f8 page (dark: #0d0d0d with #1a1a1c cards).
    static let screen = Color(light: 0xffffff, dark: 0x0d0d0d)
    #if os(macOS)
    // A Mac's grouped rows are soft grey by themselves: the page stays white and cards take the same soft grey.
    static let page = screen
    static let card = Color(light: 0xf4f4f5, dark: 0xffffff, darkAlpha: 0.06)
    #else
    static let page = Color(light: 0xf7f7f8, dark: 0x0d0d0d)
    static let card = Color(light: 0xffffff, dark: 0x1a1a1c)
    #endif
    /// Icon wells, soft buttons, chips.
    static let raised = Color(light: 0xf4f4f5, dark: 0xffffff, darkAlpha: 0.09)
    static let input = Color(light: 0xf3f3f4, dark: 0xffffff, darkAlpha: 0.09)
    /// The one button at the bottom of a first-start step.
    static let cta = Color(light: 0x000000, dark: 0x2b2c31)
    static let hairline = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.1, darkAlpha: 0.14)

    static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .brown, .mint]
        return palette[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
    }
}

/// Site icon: the first letter on a colour from the name (no network call, nothing about the vault leaves the phone).
struct ItemIcon: View {
    let name: String
    var category: ItemCategory = .login
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3).fill(Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(Theme.hairline.opacity(0.5), lineWidth: 1))
            if category == .login || category == .password, let ch = name.trimmingCharacters(in: .whitespaces).first {
                Text(String(ch).uppercased()).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.primary)
            } else {
                Image(systemName: category.symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Theme.brand)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Circle().fill(Theme.raised)
            .overlay(Text(String(name.first ?? "?").uppercased()).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.primary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    func cardStyle() -> some View {
        padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
    }

    /// Shows a session error as an alert.
    func errorAlert(_ text: Binding<String?>) -> some View {
        alert(String(localized: "Couldn't finish"), isPresented: Binding(get: { text.wrappedValue != nil }, set: { if !$0 { text.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(text.wrappedValue ?? "") }
    }
}

/// Copies to the clipboard and clears it after 90 seconds (1Password default), local-only so it never syncs.
@MainActor
func copyToClipboard(_ s: String) {
    #if os(iOS)
    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: s]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(90)])
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #else
    let pb = NSPasteboard.general
    pb.clearContents(); pb.setString(s, forType: .string)
    let n = pb.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { if pb.changeCount == n { pb.clearContents() } }
    #endif
}

extension View {
    /// A list or form on the AZET page colour; its white groups stay as they are.
    func azetList() -> some View {
        #if os(macOS)
        modifier(MacPageColumn())
        #else
        scrollContentBackground(.hidden).background(Theme.page)
        #endif
    }
}

/// iOS 26 credential exchange names; an activity type nothing sends on older iOS.
private var credentialExchangeActivity: String {
    if #available(iOS 26.0, macOS 26.0, *) { return ASCredentialExchangeActivity }
    return "io.azet.pass.no-credential-exchange"
}
private var credentialImportTokenKey: String {
    if #available(iOS 26.0, macOS 26.0, *) { return ASCredentialImportToken }
    return "token"
}
