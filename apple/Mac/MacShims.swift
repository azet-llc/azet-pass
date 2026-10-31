#if os(macOS)
import AppKit
import SwiftUI

// The iPhone screens build unchanged on the Mac: iOS-only names map to their AppKit equivalent or to nothing
// (a Mac has no on-screen keyboard to pick, no navigation bar to size).

typealias UIImage = NSImage
typealias UIFont = NSFont
typealias UIColor = NSColor
typealias UIBezierPath = NSBezierPath

extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    var cgOrientation: CGImagePropertyOrientation { .up }
}

extension NSColor {
    static let secondarySystemGroupedBackground = NSColor.controlBackgroundColor
    static let systemGroupedBackground = NSColor.windowBackgroundColor
    static let secondarySystemBackground = NSColor.controlBackgroundColor
    static let systemFill = NSColor.quaternaryLabelColor
}

enum UIKeyboardType { case `default`, URL, emailAddress, numberPad, numbersAndPunctuation, phonePad }
struct TextInputAutocapitalization { static let never = Self(), words = Self(), sentences = Self(), characters = Self() }
enum NavigationBarTitleDisplayMode { case automatic, inline, large }
enum DrawerDisplayMode { case automatic, always }

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ a: TextInputAutocapitalization?) -> some View { self }
    func navigationBarTitleDisplayMode(_ m: NavigationBarTitleDisplayMode) -> some View { self }
}

extension ToolbarItemPlacement {
    static let topBarLeading = ToolbarItemPlacement.navigation
    static let topBarTrailing = ToolbarItemPlacement.primaryAction
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: DrawerDisplayMode) -> SearchFieldPlacement { .automatic }
}

/// Same contract as UIKit's renderer (top-left origin, `beginPage`, NSString drawing) over a Core Graphics PDF.
final class UIGraphicsPDFRenderer {
    final class Context {
        let cg: CGContext
        let bounds: CGRect
        var open = false
        init(cg: CGContext, bounds: CGRect) { self.cg = cg; self.bounds = bounds }
        func beginPage() {
            if open { cg.endPDFPage() }
            cg.beginPDFPage(nil); open = true
            cg.translateBy(x: 0, y: bounds.height); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        }
    }
    private let bounds: CGRect
    init(bounds: CGRect) { self.bounds = bounds }
    func writePDF(to url: URL, withActions actions: (Context) -> Void) throws {
        var box = bounds
        guard let cg = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let c = Context(cg: cg, bounds: bounds)
        actions(c)
        if c.open { cg.endPDFPage() }
        cg.closePDF()
    }
}
#endif
