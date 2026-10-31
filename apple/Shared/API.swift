import BitwardenSdk
import Foundation

/// Where the app and the AutoFill extension talk to. One server for every country; language and currency come from
/// the device, never from here.
enum Config {
    static let server = URL(string: "https://pass.azet.io")!
    #if os(macOS)
    static let appGroup = "95P4H2RG24.io.azet.pass"   // Mac App Store: team-prefixed group, no portal registration
    static let safariExtension = "io.azet.pass.safari.extension"
    #else
    static let appGroup = "group.io.azet.pass"
    #endif
    static let keychainGroup = "95P4H2RG24.io.azet.pass.shared"
    static let clientVersion = "2026.9.1"
    #if os(macOS)
    static let userAgent = "AZET Pass macOS"
    static let deviceType = DeviceType.macOsDesktop
    #else
    static let userAgent = "AZET Pass iOS"
    static let deviceType = DeviceType.iOs
    #endif
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// The JSON HTTP calls of the AZET Pass server (Bitwarden-compatible API + AZET family routes).
final class API: @unchecked Sendable {
    var accessToken: String?
    var refreshToken: String?
    var onTokens: ((String, String?) -> Void)?
    let deviceId: String

    init(deviceId: String) { self.deviceId = deviceId }

    private func request(_ method: String, _ path: String, json: Any? = nil, form: [String: String]? = nil, auth: Bool = true) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: Config.server)!)
        r.httpMethod = method
        r.setValue("AZET Pass iOS/\(Config.clientVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue(Config.clientVersion, forHTTPHeaderField: "Bitwarden-Client-Version")
        r.setValue("mobile", forHTTPHeaderField: "Bitwarden-Client-Name")
        r.setValue("1", forHTTPHeaderField: "Device-Type")
        if auth, let t = accessToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = json as? Data ?? (try? JSONSerialization.data(withJSONObject: json))
        } else if let form {
            r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        return r
    }

    @discardableResult
    func raw(_ method: String, _ path: String, json: Any? = nil, form: [String: String]? = nil, auth: Bool = true, retry: Bool = true) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request(method, path, json: json, form: form, auth: auth))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, auth, retry, refreshToken != nil {
            try await refresh()
            return try await raw(method, path, json: json, form: form, auth: auth, retry: false)
        }
        guard (200..<300).contains(status) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (obj?["message"] as? String) ?? (obj?["error_description"] as? String) ?? (obj?["error"] as? String)
                ?? (obj?["ErrorModel"] as? [String: Any])?["Message"] as? String ?? String(localized: "Something went wrong. Try again.")
            throw APIError(status: status, message: msg)
        }
        return data
    }

    func get(_ path: String) async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await raw("GET", path)) as? [String: Any] ?? [:]
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ body: Any? = nil, auth: Bool = true) async throws -> [String: Any] {
        let d = try await raw(method, path, json: method == "GET" ? nil : body ?? [String: Any](), auth: auth)   // iOS refuses a GET with a body
        return d.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:])
    }

    // MARK: identity

    func prelogin(email: String) async throws -> [String: Any] {
        try await send("POST", "/identity/accounts/prelogin", ["email": email], auth: false)
    }

    /// Password grant. Throws `TwoFactorNeeded` when the account has an authenticator app turned on.
    func token(email: String, hash: String, twoFactorCode: String? = nil) async throws -> [String: Any] {
        var f = ["grant_type": "password", "username": email, "password": hash, "scope": "api offline_access",
                 "client_id": "mobile", "deviceType": "1", "deviceIdentifier": deviceId, "deviceName": "iPhone"]
        if let twoFactorCode { f["twoFactorToken"] = twoFactorCode; f["twoFactorProvider"] = "0"; f["twoFactorRemember"] = "1" }
        let (data, resp) = try await URLSession.shared.data(for: request("POST", "/identity/connect/token", form: f, auth: false))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode == 400, obj["TwoFactorProviders"] != nil || obj["TwoFactorProviders2"] != nil {
            throw TwoFactorNeeded()
        }
        guard let access = obj["access_token"] as? String else {
            throw APIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                           message: (obj["error_description"] as? String).map { _ in String(localized: "Email or account password is not right.") } ?? String(localized: "Email or account password is not right."))
        }
        accessToken = access
        refreshToken = obj["refresh_token"] as? String
        onTokens?(access, refreshToken)
        return obj
    }

    func refresh() async throws {
        guard let rt = refreshToken else { throw APIError(status: 401, message: String(localized: "Sign in again.")) }
        let d = try await raw("POST", "/identity/connect/token", form: ["grant_type": "refresh_token", "client_id": "mobile", "refresh_token": rt], auth: false, retry: false)
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        accessToken = obj["access_token"] as? String
        if let r = obj["refresh_token"] as? String { refreshToken = r }
        if let a = accessToken { onTokens?(a, refreshToken) }
    }
}

struct TwoFactorNeeded: Error {}
