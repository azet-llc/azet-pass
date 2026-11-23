import Foundation

/// Google Authenticator's "Transfer accounts" QR (otpauth-migration://offline?data=…): a protobuf list of accounts,
/// turned into ordinary otpauth:// links so each becomes a login with live codes. Same reading as the Android app.
enum GoogleOtp {
    struct Account: Equatable { let issuer: String; let name: String; let uri: String }

    private struct Reader {
        let b: [UInt8]; var i = 0
        var more: Bool { i < b.count }
        mutating func varint() throws -> UInt64 {
            var r: UInt64 = 0, s: UInt64 = 0
            while true {
                guard i < b.count, s < 64 else { throw CocoaError(.coderReadCorrupt) }
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7f) << s
                if x < 0x80 { return r }
                s += 7
            }
        }
        mutating func bytes() throws -> [UInt8] {
            let n = Int(try varint())
            guard n >= 0, i + n <= b.count else { throw CocoaError(.coderReadCorrupt) }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        mutating func skip(_ wire: UInt64) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: i += 8
            case 2: _ = try bytes()
            case 5: i += 4
            default: throw CocoaError(.coderReadCorrupt)
            }
        }
    }

    static func parse(_ link: String) -> [Account] {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("otpauth-migration://"),
              let comps = URLComponents(string: t),
              let data = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              let payload = Data(base64Encoded: data.replacingOccurrences(of: " ", with: "+"))
        else { return [] }
        return (try? parseData([UInt8](payload))) ?? []
    }

    static func parseData(_ payload: [UInt8]) throws -> [Account] {
        var out: [Account] = []
        var r = Reader(b: payload)
        while r.more {
            let key = try r.varint()
            guard key >> 3 == 1, key & 7 == 2 else { try r.skip(key & 7); continue }
            var p = Reader(b: try r.bytes())
            var secret: [UInt8] = [], name = "", issuer = "", algo: UInt64 = 1, digits: UInt64 = 1, type: UInt64 = 2, counter: UInt64 = 0
            while p.more {
                let k = try p.varint()
                switch k >> 3 {
                case 1: secret = try p.bytes()
                case 2: name = String(decoding: try p.bytes(), as: UTF8.self)
                case 3: issuer = String(decoding: try p.bytes(), as: UTF8.self)
                case 4: algo = try p.varint()
                case 5: digits = try p.varint()
                case 6: type = try p.varint()
                case 7: counter = try p.varint()
                default: try p.skip(k & 7)
                }
            }
            if secret.isEmpty { continue }
            let label = !issuer.isEmpty && !name.hasPrefix("\(issuer):") ? "\(issuer):\(name)" : name
            var q = "secret=\(base32(secret))"
            if !issuer.isEmpty { q += "&issuer=\(enc(issuer))" }
            q += "&algorithm=\([2: "SHA256", 3: "SHA512", 4: "MD5"][algo] ?? "SHA1")&digits=\(digits == 2 ? 8 : 6)"
            if type == 1 { q += "&counter=\(counter)" }
            let shown = name.hasPrefix("\(issuer):") && !issuer.isEmpty ? String(name.dropFirst(issuer.count + 1)) : name
            out.append(Account(issuer: issuer, name: shown, uri: "otpauth://\(type == 1 ? "hotp" : "totp")/\(enc(label, keep: ":@"))?\(q)"))
        }
        return out
    }

    private static func enc(_ s: String, keep: String = "") -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~" + keep)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func base32(_ b: [UInt8]) -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"); var out = "", buf = 0, bits = 0
        for x in b { buf = (buf << 8) | Int(x); bits += 8; while bits >= 5 { out.append(a[(buf >> (bits - 5)) & 31]); bits -= 5 } }
        if bits > 0 { out.append(a[(buf << (5 - bits)) & 31]) }
        return out
    }
}
