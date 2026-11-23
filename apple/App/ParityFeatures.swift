import BitwardenSdk
import CoreImage
import CryptoKit
import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
import VisionKit
#endif

// Samsung Pass parity on iPhone: deep links, a privacy cover, the jailbreak switch, HOTP codes,
// a QR code from a photo and a card from the camera.

// MARK: deep links (walletpass:// actions that apply here)

/// azetpass://home | items | family | watchtower | new | settings | search?q=… | item?id=…
enum DeepLink: Equatable {
    case tab(MainView.Tab)
    case newItem, settings
    case search(String)
    case item(String)

    init?(_ url: URL) {
        guard url.scheme == "azetpass" else { return nil }
        let action = url.host ?? url.pathComponents.dropFirst().first ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch action {
        case "home": self = .tab(.home)
        case "items": self = .tab(.items)
        case "family": self = .tab(.family)
        case "watchtower": self = .tab(.watchtower)
        case "new", "add": self = .newItem
        case "settings": self = .settings
        case "search": self = .search(value("q") ?? "")
        case "item":
            guard let id = value("id"), !id.isEmpty else { return nil }
            self = .item(id)
        default: return nil
        }
    }

    /// The tab that shows it.
    var tab: MainView.Tab {
        if case .tab(let t) = self { return t }
        return .items
    }
}

// MARK: privacy cover (screen recording, mirroring, the app switcher)

#if os(iOS)
/// Covers the app while the screen is recorded or mirrored (UIScreen.isCaptured) and while it is not
/// in front, so the app switcher's snapshot shows no item.
struct PrivacyCover: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var captured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .overlay {
                if captured || phase != .active {
                    ZStack {
                        Theme.page.ignoresSafeArea()
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(Theme.brand)
                            Text(captured ? "Hidden while the screen is recorded or shared" : "AZET Pass")
                                .font(.headline).multilineTextAlignment(.center)
                        }.padding()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = UIScreen.main.isCaptured
            }
    }
}

// MARK: jailbreak switch (spass-184)

enum DeviceIntegrity {
    /// Common signs of a jailbroken iPhone: its package managers, and a sandbox that lets the app write outside its container.
    static var isJailbroken: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/var/jb", "/private/var/lib/apt", "/usr/sbin/sshd", "/bin/bash"]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        let probe = "/private/azet-jb-\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        return false
        #endif
    }
}

struct JailbreakRefusal: View {
    var body: some View {
        ContentUnavailableView {
            Label("AZET Pass is off on this device", systemImage: "exclamationmark.shield.fill")
        } description: {
            Text("This iPhone looks jailbroken, and Settings asked AZET Pass not to open items here. Your items are safe on your other devices.")
        }
    }
}
#endif
#if os(macOS)
/// The Mac window has no app-switcher snapshot or screen-capture flag to cover for.
struct PrivacyCover: ViewModifier { func body(content: Content) -> some View { content } }
/// A Mac is not jailbroken; the refusal switch is iPhone-only.
enum DeviceIntegrity { static let isJailbroken = false }
struct JailbreakRefusal: View { var body: some View { EmptyView() } }
#endif

// MARK: HOTP (counter codes, spass-082)

enum Hotp {
    struct Key { var secret: Data; var counter: UInt64; var digits: Int; var url: URLComponents }

    static func parse(_ text: String) -> Key? {
        guard var url = URLComponents(string: text), url.scheme == "otpauth", url.host == "hotp",
              let secret = url.queryItems?.first(where: { $0.name == "secret" })?.value.flatMap(base32) else { return nil }
        let counter = url.queryItems?.first(where: { $0.name == "counter" })?.value.flatMap(UInt64.init) ?? 0
        let digits = url.queryItems?.first(where: { $0.name == "digits" })?.value.flatMap(Int.init) ?? 6
        url.queryItems = url.queryItems ?? []
        return Key(secret: secret, counter: counter, digits: min(max(digits, 6), 8), url: url)
    }

    /// RFC 4226 with HMAC-SHA1.
    static func code(_ key: Key) -> String {
        var counter = key.counter.bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key.secret)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let modulo = UInt32(pow(10, Double(key.digits)))
        return String(format: "%0\(key.digits)u", bin % modulo)
    }

    /// The same key with the counter moved on by one.
    static func next(_ key: Key) -> String {
        var url = key.url
        var items = (url.queryItems ?? []).filter { $0.name != "counter" }
        items.append(URLQueryItem(name: "counter", value: String(key.counter + 1)))
        url.queryItems = items
        return url.string ?? ""
    }

    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in text.uppercased() where ch != "=" && ch != " " {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// A counter code: it changes only when you ask for the next one, which is saved to the item.
struct HotpRow: View {
    @Environment(Session.self) private var session
    let view: CipherView
    let key: Hotp.Key
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("One-time password (counter \(key.counter))").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(Hotp.code(key)).font(.title2.monospacedDigit().weight(.semibold))
                Spacer()
                Button("Next code") {
                    saving = true
                    Task {
                        var draft = Draft(view)
                        draft.totp = Hotp.next(key)
                        try? await session.save(draft.view(), vaultIds: draft.vaultIds)
                        saving = false
                    }
                }.buttonStyle(.bordered).disabled(saving)
                Button { copyToClipboard(Hotp.code(key)) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    .accessibilityLabel(Text("Copy one-time password"))
            }
        }
    }
}

// MARK: QR code from a photo (spass-074)

enum PhotoQR {
    /// The first QR code text in the image, read on this device.
    static func read(_ data: Data) -> String? {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

struct PhotoQRButton: View {
    let onCode: (String) -> Void
    @State private var pick: PhotosPickerItem?
    @State private var failed = false

    var body: some View {
        PhotosPicker(selection: $pick, matching: .images) { Image(systemName: "photo.on.rectangle") }
            .accessibilityLabel(Text("Read QR code from a photo"))
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    if let code = data.flatMap(PhotoQR.read) { onCode(code) } else { failed = true }
                    pick = nil
                }
            }
            .alert("No QR code in that photo", isPresented: $failed) { Button("OK", role: .cancel) {} }
    }
}

// MARK: card from the camera (spass-099)

enum CardText {
    /// Card number (Luhn-checked), expiry and the holder's name from text the camera read.
    static func parse(_ lines: [String]) -> (number: String?, month: String?, year: String?, name: String?) {
        var number: String?, month: String?, year: String?, name: String?
        for line in lines {
            let digits = line.filter(\.isNumber)
            if number == nil, (13...19).contains(digits.count), luhn(digits), line.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
                number = digits
            } else if month == nil, let m = line.range(of: #"\b(0[1-9]|1[0-2])\s?/\s?(\d{2}|\d{4})\b"#, options: .regularExpression) {
                let parts = line[m].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                month = parts[0]
                year = parts[1].count == 2 ? "20" + parts[1] : parts[1]
            } else if name == nil, line.count >= 5, line.allSatisfy({ $0.isUppercase || $0 == " " || $0 == "." }), line.contains(" ") {
                name = line
            }
        }
        return (number, month, year, name)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}

#if os(iOS)
/// Live text from the camera (VisionKit); stops as soon as a card number is seen.
struct CardScannerView: UIViewControllerRepresentable {
    let onCard: (String?, String?, String?, String?) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.text()], qualityLevel: .accurate, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCard: onCard) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCard: (String?, String?, String?, String?) -> Void
        private var lines: [String] = []
        init(onCard: @escaping (String?, String?, String?, String?) -> Void) { self.onCard = onCard }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            lines = allItems.compactMap { if case .text(let t) = $0 { return t.transcript } else { return nil } }
            let card = CardText.parse(lines)
            if card.number != nil {
                scanner.stopScanning()
                onCard(card.number, card.month, card.year, card.name)
            }
        }
    }

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
}
#endif
