import SwiftUI

// AZET Pass's form: flat surfaces, one content column, capsule buttons and fields, soft icon tiles.
// Colours are AZET's (azet-desktop src/shared/design/azet-tokens.ts): blue #2f6fe8, white screen, #f7f7f8 page.

extension Color {
    /// One colour for light and one for dark, on iPhone and Mac.
    init(light: Int, dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        func c(_ v: Int, _ a: Double) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
        }
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? c(dark, darkAlpha) : c(light, lightAlpha) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark, darkAlpha) : c(light, lightAlpha) })
        #endif
    }
}

enum Layout {
    /// Width of the single column on sign-in screens and of buttons and fields in it.
    static let column: CGFloat = 328
    /// Widest a list or home page grows on a Mac or iPad window.
    static let page: CGFloat = 640
    static let control: CGFloat = 56
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 12
}

/// The capsule button. `.primary` is the one filled AZET-blue action of a screen; `.soft` is every other choice.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, soft }
    var kind = Kind.primary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(kind == .primary ? Color.white : Color.primary)
            .frame(maxWidth: Layout.column, minHeight: Layout.control)
            .background(kind == .primary ? Theme.brand : Theme.raised, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var softPill: PillButtonStyle { PillButtonStyle(kind: .soft) }
}

extension View {
    /// A text or password box as one capsule (sign-in, unlock, create account).
    func pillField() -> some View {
        textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 24).frame(maxWidth: Layout.column, minHeight: Layout.control)
            .background(Theme.input, in: Capsule())
    }

    /// Keeps a page readable on a wide window: one centred column.
    func pageColumn(_ width: CGFloat = Layout.page) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// One step of signing in or setting up: a title, the fields, and the action pinned at the bottom.
struct StepScreen<Content: View, Action: View>: View {
    let title: LocalizedStringKey
    var lead: LocalizedStringKey?
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 22, weight: .medium)).multilineTextAlignment(.center).padding(.top, 28)
                    if let lead { Text(lead).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Spacer().frame(height: 14)
                    content
                }
                .frame(maxWidth: Layout.column).frame(maxWidth: .infinity).padding(.horizontal, 24)
            }
            VStack(spacing: 8) { action }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(Theme.screen)
    }
}

/// Small print under the fields of a step.
struct StepNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 8)
    }
}

/// The 40-point well a row's symbol sits in.
struct IconWell: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = Theme.brand
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3).fill(Theme.raised)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(tint))
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A card that leads somewhere: symbol, title, one line of help, chevron.
struct NoticeCard: View {
    let title: String
    let text: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconWell(symbol: symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .medium)).multilineTextAlignment(.leading)
                    Text(text).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        }
        .buttonStyle(.plain)
    }
}

/// A list of rows: the system list on iPhone; on a Mac the same rows as grouped cards (a Mac list is a bare table).
struct PageList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

#if os(macOS)
/// A Mac list keeps the whole window (so the toolbar stays one piece) and insets its rows to the page column.
struct MacPageColumn: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { g in
            content.scrollContentBackground(.hidden)
                .contentMargins(.horizontal, max(0, (g.size.width - Layout.page) / 2), for: .scrollContent)
                .background(Theme.page)
        }
        .frame(minWidth: 520, minHeight: 560) // a Mac sheet takes its size from its content, and a list has none
    }
}
#endif
