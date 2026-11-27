import SwiftUI

/// Look-and-feel measured from Pickle 1.1.16 (~/Code/pickle-dissect/notes/azet-ui-spec.md): near-monochrome,
/// black capsule CTAs, one question per screen, big capsule inputs, flat cards. Values in pt, spec section in brackets.
enum Pk {
    #if os(iOS)
    private static func dyn(_ light: Int, _ dark: Int, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { t in
            let (v, a) = t.userInterfaceStyle == .dark ? (dark, da) : (light, la)
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
        })
    }
    /// [1.1] actionPrimary #000 / #F4F5F7 and the text on it.
    static let ink = dyn(0x000000, 0xF4F5F7)
    static let onInk = dyn(0xFFFFFF, 0x101114)
    /// [1.1] surfaceInputField, surfaceRaised (secondary pill), surfaceScreen.
    static let field = dyn(0xF3F3F3, 0xFFFFFF, 1, 0.09)
    static let raised = dyn(0xF4F4F4, 0xFFFFFF, 1, 0.09)
    static let screen = dyn(0xFFFFFF, 0x101114)
    #else
    static let ink = Color.primary, onInk = Color(.windowBackgroundColor), field = Color(.controlBackgroundColor)
    static let raised = Color(.controlBackgroundColor), screen = Color(.windowBackgroundColor)
    #endif
    static let secondaryText = Color.primary.opacity(0.5)
}

/// [3.1 bottom CTA, 2.4c] capsule buttons: primary = black, secondary = light grey. Pressed = scale 0.97 + dim (press-dim).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, small }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .small ? 15 : 18, weight: .medium)).tracking(kind == .small ? -0.3 : -0.18)
            .foregroundStyle(kind == .secondary ? Pk.ink : Pk.onInk)
            .frame(maxWidth: kind == .small ? nil : .infinity)
            .frame(height: kind == .small ? 34 : 58)
            .padding(.horizontal, kind == .small ? 14 : 0)
            .background(kind == .secondary ? Pk.raised : Pk.ink, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillSecondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var pillSmall: PillButtonStyle { PillButtonStyle(kind: .small) }
}

/// [3.1 form steps] one big capsule input: 56 tall, #F3F3F3, text 18 medium, 24 side padding.
struct CapsuleField: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 18, weight: .medium)).padding(.horizontal, 24).frame(height: 56)
            .background(Pk.field, in: Capsule())
    }
}
extension View { func capsuleField() -> some View { modifier(CapsuleField()) } }

/// [3.1] one question per screen: title 22 / 500 at the top, the field(s) under it, the black CTA pinned above the keyboard.
/// Steps swap with setup-stage-swap: fade + blur, no slide.
struct StepScreen<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let cta: String
    var busy = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 22, weight: .medium)).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).font(.system(size: 15)).foregroundStyle(Pk.secondaryText).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) { content }.padding(.top, 24)
            Spacer(minLength: 16)
            Button(action: action) {
                ZStack { Text(cta).opacity(busy ? 0 : 1); if busy { ProgressView().tint(Pk.onInk) } }
            }
            .buttonStyle(.pill).disabled(!enabled || busy)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
        .background(Pk.screen)
        .transition(.asymmetric(insertion: .opacity.combined(with: .blur(10)).animation(.easeOut(duration: 0.4).delay(0.18)),
                                removal: .opacity.animation(.easeIn(duration: 0.16))))
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
extension AnyTransition {
    static func blur(_ r: CGFloat) -> AnyTransition { .modifier(active: BlurModifier(radius: r), identity: BlurModifier(radius: 0)) }
}

/// [3.1 login] the welcome headline materializes: scale 0.96 → 1 and blur 6 → 0.
struct Materialize: ViewModifier {
    var delay: Double = 0.3
    @State private var shown = false
    func body(content: Content) -> some View {
        content.scaleEffect(shown ? 1 : 0.96).blur(radius: shown ? 0 : 6).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5).delay(delay)) { shown = true } }
    }
}
