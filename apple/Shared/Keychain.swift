import Foundation
import LocalAuthentication
import Security

/// Small keychain wrapper shared by the app and the AutoFill extension (one access group).
enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.azet.pass", kSecAttrAccount as String: key]
        #if !targetEnvironment(simulator)
        q[kSecAttrAccessGroup as String] = Config.keychainGroup   // simulator builds are ad-hoc signed: no team prefix
        #endif
        return q
    }

    /// `biometric` items open only after Face ID / Touch ID (or the device passcode) on this device.
    static func set(_ value: String?, for key: String, biometric: Bool = false) {
        SecItemDelete(base(key) as CFDictionary)
        guard let value else { return }
        var q = base(key)
        q[kSecValueData as String] = Data(value.utf8)
        if biometric {
            q[kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String, prompt: String? = nil) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let prompt {
            let ctx = LAContext()
            ctx.localizedReason = prompt
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func has(_ key: String) -> Bool {
        var q = base(key)
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = ctx
        let s = SecItemCopyMatching(q as CFDictionary, nil)
        return s == errSecSuccess || s == errSecInteractionNotAllowed
    }
}

/// Files in the app group container: the encrypted sync body (fields stay EncStrings) and small settings.
enum SharedFiles {
    static var dir: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func write(_ data: Data, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }
    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
    static var defaults: UserDefaults { UserDefaults(suiteName: Config.appGroup) ?? .standard }
}
