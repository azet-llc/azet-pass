import BitwardenSdk
import Foundation

/// 1Password's item categories, on top of the SDK's eight cipher types. Categories the SDK has no type for are
/// secure notes with a fixed field set and a hidden `azet.category` field naming the category.
enum ItemCategory: String, CaseIterable, Identifiable, Codable {
    case login, password, secureNote, card, identity, document, bankAccount, driversLicense, passport, sshKey
    case wifi, membership, softwareLicense, emailAccount, server, database, apiCredential, cryptoWallet
    case medicalRecord, socialSecurity, rewardProgram, outdoorLicense
    var id: String { rawValue }

    var title: String {
        switch self {
        case .login: String(localized: "Login")
        case .password: String(localized: "Password")
        case .secureNote: String(localized: "Secure Note")
        case .card: String(localized: "Credit Card")
        case .identity: String(localized: "Identity")
        case .document: String(localized: "Document")
        case .bankAccount: String(localized: "Bank Account")
        case .driversLicense: String(localized: "Driver License")
        case .passport: String(localized: "Passport")
        case .sshKey: String(localized: "SSH Key")
        case .wifi: String(localized: "Wi-Fi")
        case .membership: String(localized: "Membership")
        case .softwareLicense: String(localized: "Software License")
        case .emailAccount: String(localized: "Email Account")
        case .server: String(localized: "Server")
        case .database: String(localized: "Database")
        case .apiCredential: String(localized: "API Credential")
        case .cryptoWallet: String(localized: "Crypto Wallet")
        case .medicalRecord: String(localized: "Medical Record")
        case .socialSecurity: String(localized: "ID Number")
        case .rewardProgram: String(localized: "Reward Program")
        case .outdoorLicense: String(localized: "Outdoor License")
        }
    }

    var symbol: String {
        switch self {
        case .login: "key.fill"
        case .password: "ellipsis.rectangle.fill"
        case .secureNote: "note.text"
        case .card: "creditcard.fill"
        case .identity: "person.text.rectangle.fill"
        case .document: "doc.fill"
        case .bankAccount: "building.columns.fill"
        case .driversLicense: "car.fill"
        case .passport: "globe.asia.australia.fill"
        case .sshKey: "terminal.fill"
        case .wifi: "wifi"
        case .membership: "person.crop.square.filled.and.at.rectangle"
        case .softwareLicense: "app.badge.checkmark.fill"
        case .emailAccount: "envelope.fill"
        case .server: "server.rack"
        case .database: "cylinder.split.1x2.fill"
        case .apiCredential: "curlybraces"
        case .cryptoWallet: "bitcoinsign.circle.fill"
        case .medicalRecord: "cross.case.fill"
        case .socialSecurity: "number.square.fill"
        case .rewardProgram: "gift.fill"
        case .outdoorLicense: "leaf.fill"
        }
    }

    var type: CipherType {
        switch self {
        case .login, .password: .login
        case .card: .card
        case .identity: .identity
        case .bankAccount: .bankAccount
        case .driversLicense: .driversLicense
        case .passport: .passport
        case .sshKey: .sshKey
        default: .secureNote
        }
    }

    /// Fields of the categories that ride on a secure note (labels in the user's language; stored as text).
    var noteFields: [(String, FieldType)] {
        switch self {
        case .wifi: [(String(localized: "Network name"), .text), (String(localized: "Wi-Fi password"), .hidden), (String(localized: "Security"), .text)]
        case .membership: [(String(localized: "Group"), .text), (String(localized: "Member name"), .text), (String(localized: "Member ID"), .text), (String(localized: "PIN"), .hidden), (String(localized: "Expires"), .text)]
        case .softwareLicense: [(String(localized: "Version"), .text), (String(localized: "License key"), .hidden), (String(localized: "Licensed to"), .text), (String(localized: "Purchase date"), .text)]
        case .emailAccount: [(String(localized: "Email address"), .text), (String(localized: "Password"), .hidden), (String(localized: "Incoming server"), .text), (String(localized: "Outgoing server"), .text)]
        case .server: [(String(localized: "URL"), .text), (String(localized: "Username"), .text), (String(localized: "Password"), .hidden), (String(localized: "Admin console"), .text)]
        case .database: [(String(localized: "Type"), .text), (String(localized: "Server"), .text), (String(localized: "Port"), .text), (String(localized: "Database"), .text), (String(localized: "Username"), .text), (String(localized: "Password"), .hidden)]
        case .apiCredential: [(String(localized: "Username"), .text), (String(localized: "Credential"), .hidden), (String(localized: "Type"), .text), (String(localized: "Host"), .text), (String(localized: "Expires"), .text)]
        case .cryptoWallet: [(String(localized: "Recovery phrase"), .hidden), (String(localized: "Password"), .hidden), (String(localized: "Wallet address"), .text)]
        case .medicalRecord: [(String(localized: "Date"), .text), (String(localized: "Place"), .text), (String(localized: "Doctor"), .text), (String(localized: "Patient"), .text), (String(localized: "Reason"), .text), (String(localized: "Medication"), .text)]
        case .socialSecurity: [(String(localized: "Name"), .text), (String(localized: "Number"), .hidden)]
        case .rewardProgram: [(String(localized: "Company"), .text), (String(localized: "Member name"), .text), (String(localized: "Member ID"), .text), (String(localized: "PIN"), .hidden)]
        case .outdoorLicense: [(String(localized: "Full name"), .text), (String(localized: "Valid from"), .text), (String(localized: "Expires"), .text), (String(localized: "Approved wildlife"), .text), (String(localized: "Country"), .text)]
        case .document: [(String(localized: "Where it is kept"), .text)]
        default: []
        }
    }

    static let marker = "azet.category"

    static func of(_ v: CipherView) -> ItemCategory {
        if let raw = v.fields?.first(where: { $0.name == marker })?.value, let c = ItemCategory(rawValue: raw) { return c }
        switch v.type {
        case .login: return (v.login?.username ?? "").isEmpty && (v.login?.uris ?? []).isEmpty ? .password : .login
        case .card: return .card
        case .identity: return .identity
        case .bankAccount: return .bankAccount
        case .driversLicense: return .driversLicense
        case .passport: return .passport
        case .sshKey: return .sshKey
        default: return .secureNote
        }
    }

    static func of(_ v: CipherListView) -> ItemCategory {
        switch v.type {
        case .login: .login
        case .card: .card
        case .identity: .identity
        case .bankAccount: .bankAccount
        case .driversLicense: .driversLicense
        case .passport: .passport
        case .sshKey: .sshKey
        case .secureNote: .secureNote
        }
    }
}

/// An editable copy of an item. `CipherView` is immutable; the editor works on this and builds a new view on save.
struct Draft {
    var id: String?
    var category: ItemCategory = .login
    var name = ""
    var notes = ""
    var favorite = false
    var familyId: String?
    var vaultIds: [String] = []
    var folderId: String?
    // login
    var username = ""
    var password = ""
    var urls: [String] = [""]
    var totp = ""
    var fido2: [Fido2Credential]? = nil
    var passwordRevision: Date?
    // card
    var cardholder = "", cardNumber = "", expMonth = "", expYear = "", code = "", brand = ""
    // identity
    var identity = IdentityFields()
    // bank
    var bankName = "", accountName = "", accountType = "", accountNumber = "", routing = "", branch = "", pin = "", swift = "", iban = "", bankPhone = ""
    // license / passport
    var firstName = "", lastName = "", licenseNumber = "", issuingCountry = "", issuingState = "", licenseClass = ""
    var surname = "", givenName = "", passportNumber = "", nationality = "", sex = ""
    var birthDate: Date?, issueDate: Date?, expiryDate: Date?
    // ssh
    var sshPrivate = "", sshPublic = "", sshFingerprint = ""
    // custom fields (and category templates)
    var fields: [CustomField] = []
    // kept from the original
    var original: CipherView?

    struct IdentityFields {
        var title = "", firstName = "", middleName = "", lastName = "", company = "", email = "", phone = ""
        var address1 = "", address2 = "", city = "", state = "", postalCode = "", country = ""
        var ssn = "", passportNumber = "", licenseNumber = "", username = ""
    }

    struct CustomField: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var hidden: Bool
    }

    init(category: ItemCategory = .login) {
        self.category = category
        fields = category.noteFields.map { CustomField(name: $0.0, value: "", hidden: $0.1 == .hidden) }
    }

    init(_ v: CipherView) {
        self.init()
        original = v
        id = v.id; category = ItemCategory.of(v); name = v.name; notes = v.notes ?? ""; favorite = v.favorite
        familyId = v.organizationId; vaultIds = v.collectionIds; folderId = v.folderId
        if let l = v.login {
            username = l.username ?? ""; password = l.password ?? ""; totp = l.totp ?? ""
            urls = (l.uris ?? []).compactMap(\.uri); if urls.isEmpty { urls = [""] }
            fido2 = l.fido2Credentials; passwordRevision = l.passwordRevisionDate
        }
        if let c = v.card {
            cardholder = c.cardholderName ?? ""; cardNumber = c.number ?? ""; expMonth = c.expMonth ?? ""; expYear = c.expYear ?? ""
            code = c.code ?? ""; brand = c.brand ?? ""
        }
        if let i = v.identity {
            identity = IdentityFields(title: i.title ?? "", firstName: i.firstName ?? "", middleName: i.middleName ?? "", lastName: i.lastName ?? "",
                                      company: i.company ?? "", email: i.email ?? "", phone: i.phone ?? "", address1: i.address1 ?? "",
                                      address2: i.address2 ?? "", city: i.city ?? "", state: i.state ?? "", postalCode: i.postalCode ?? "",
                                      country: i.country ?? "", ssn: i.ssn ?? "", passportNumber: i.passportNumber ?? "",
                                      licenseNumber: i.licenseNumber ?? "", username: i.username ?? "")
        }
        if let b = v.bankAccount {
            bankName = b.bankName ?? ""; accountName = b.nameOnAccount ?? ""; accountType = b.accountType ?? ""; accountNumber = b.accountNumber ?? ""
            routing = b.routingNumber ?? ""; branch = b.branchNumber ?? ""; pin = b.pin ?? ""; swift = b.swiftCode ?? ""; iban = b.iban ?? ""
            bankPhone = b.bankContactPhone ?? ""
        }
        if let d = v.driversLicense {
            firstName = d.firstName ?? ""; lastName = d.lastName ?? ""; licenseNumber = d.licenseNumber ?? ""; issuingCountry = d.issuingCountry ?? ""
            issuingState = d.issuingState ?? ""; licenseClass = d.licenseClass ?? ""; birthDate = d.dateOfBirth; issueDate = d.issueDate
            expiryDate = d.expirationDate
        }
        if let p = v.passport {
            surname = p.surname ?? ""; givenName = p.givenName ?? ""; passportNumber = p.passportNumber ?? ""; nationality = p.nationality ?? ""
            sex = p.sex ?? ""; issuingCountry = p.issuingCountry ?? ""; birthDate = p.dateOfBirth; issueDate = p.issueDate; expiryDate = p.expirationDate
        }
        if let s = v.sshKey { sshPrivate = s.privateKey; sshPublic = s.publicKey; sshFingerprint = s.fingerprint }
        fields = (v.fields ?? []).filter { $0.name != ItemCategory.marker }.map { CustomField(name: $0.name ?? "", value: $0.value ?? "", hidden: $0.type == .hidden) }
    }

    private func s(_ x: String) -> String? { x.isEmpty ? nil : x }

    func view() -> CipherView {
        let o = original
        let t = category.type
        var history = o?.passwordHistory ?? []
        var revision = passwordRevision
        if let old = o?.login?.password, !old.isEmpty, old != password {
            history.insert(PasswordHistoryView(password: old, lastUsedDate: Date()), at: 0)
            revision = Date()
        }
        var f = fields.filter { !$0.name.isEmpty || !$0.value.isEmpty }
            .map { FieldView(name: $0.name, value: $0.value, type: $0.hidden ? .hidden : .text, linkedId: nil) }
        if ItemCategory.of(t) != category { f.append(FieldView(name: ItemCategory.marker, value: category.rawValue, type: .hidden, linkedId: nil)) }
        return CipherView(
            id: id, organizationId: familyId, folderId: folderId, collectionIds: vaultIds, key: o?.key, name: name.isEmpty ? category.title : name,
            notes: s(notes), type: t,
            login: t == .login ? LoginView(username: s(username), password: s(password), passwordRevisionDate: revision,
                                           uris: urls.filter { !$0.isEmpty }.map { LoginUriView(uri: Draft.normalizeURL($0), match: nil, uriChecksum: nil) },
                                           totp: s(totp.replacingOccurrences(of: " ", with: "")), autofillOnPageLoad: nil, fido2Credentials: fido2) : nil,
            identity: t == .identity ? IdentityView(title: s(identity.title), firstName: s(identity.firstName), middleName: s(identity.middleName),
                                                    lastName: s(identity.lastName), address1: s(identity.address1), address2: s(identity.address2), address3: nil,
                                                    city: s(identity.city), state: s(identity.state), postalCode: s(identity.postalCode), country: s(identity.country),
                                                    company: s(identity.company), email: s(identity.email), phone: s(identity.phone), ssn: s(identity.ssn),
                                                    username: s(identity.username), passportNumber: s(identity.passportNumber), licenseNumber: s(identity.licenseNumber)) : nil,
            card: t == .card ? CardView(cardholderName: s(cardholder), expMonth: s(expMonth), expYear: s(expYear), code: s(code), brand: s(brand), number: s(cardNumber.filter(\.isNumber))) : nil,
            secureNote: t == .secureNote ? SecureNoteView(type: .generic) : nil,
            sshKey: t == .sshKey ? SshKeyView(privateKey: sshPrivate, publicKey: sshPublic, fingerprint: sshFingerprint) : nil,
            bankAccount: t == .bankAccount ? BankAccountView(bankName: s(bankName), nameOnAccount: s(accountName), accountType: s(accountType), accountNumber: s(accountNumber),
                                                             routingNumber: s(routing), branchNumber: s(branch), pin: s(pin), swiftCode: s(swift), iban: s(iban), bankContactPhone: s(bankPhone)) : nil,
            driversLicense: t == .driversLicense ? DriversLicenseView(firstName: s(firstName), middleName: nil, lastName: s(lastName), dateOfBirth: birthDate, licenseNumber: s(licenseNumber),
                                                                      issuingCountry: s(issuingCountry), issuingState: s(issuingState), issueDate: issueDate, expirationDate: expiryDate,
                                                                      issuingAuthority: nil, licenseClass: s(licenseClass)) : nil,
            passport: t == .passport ? PassportView(surname: s(surname), givenName: s(givenName), dateOfBirth: birthDate, sex: s(sex), birthPlace: nil, nationality: s(nationality),
                                                    issuingCountry: s(issuingCountry), passportNumber: s(passportNumber), passportType: nil, nationalIdentificationNumber: nil,
                                                    issuingAuthority: nil, issueDate: issueDate, expirationDate: expiryDate) : nil,
            favorite: favorite, reprompt: o?.reprompt ?? .none, organizationUseTotp: true, edit: true, permissions: o?.permissions,
            viewPassword: true, localData: o?.localData, attachments: o?.attachments, attachmentDecryptionFailures: nil,
            fields: f.isEmpty ? nil : f, passwordHistory: history.isEmpty ? nil : Array(history.prefix(10)),
            creationDate: o?.creationDate ?? Date(), deletedDate: nil, revisionDate: o?.revisionDate ?? Date(), archivedDate: o?.archivedDate)
    }

    static func normalizeURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("://") ? t : "https://\(t)"
    }
}

extension ItemCategory {
    static func of(_ t: CipherType) -> ItemCategory {
        switch t {
        case .login: .login
        case .card: .card
        case .identity: .identity
        case .bankAccount: .bankAccount
        case .driversLicense: .driversLicense
        case .passport: .passport
        case .sshKey: .sshKey
        default: .secureNote
        }
    }
}

/// Registrable domain of a host ("nid.naver.com" → "naver.com", "www.gov.kr" → "gov.kr").
enum Domain {
    static func of(_ host: String?) -> String? {
        guard let h = host?.lowercased() else { return nil }
        let p = h.split(separator: ".")
        guard p.count >= 2 else { return h }
        let two = p.suffix(2).joined(separator: ".")
        return ["co.kr", "or.kr", "go.kr", "ac.kr", "co.jp", "or.jp", "co.uk", "com.au"].contains(two) && p.count >= 3 ? p.suffix(3).joined(separator: ".") : two
    }
}

extension CipherListView: @retroactive Identifiable {}

enum LoginKind {
    static func isLogin(_ i: CipherListView) -> Bool { if case .login = i.type { return true }; return false }
    /// Items for these sites (registrable domains): a saved website, the username line or the name carries the domain.
    static func matching(_ items: [CipherListView], hosts: [String]) -> [CipherListView] {
        items.filter { i in
            let saved = domains(i)
            return !hosts.isEmpty && hosts.contains { saved.contains($0) || i.subtitle.localizedCaseInsensitiveContains($0) || i.name.localizedCaseInsensitiveContains($0.split(separator: ".").first.map(String.init) ?? $0) }
        }
    }
    static func domains(_ i: CipherListView) -> [String] {
        guard case .login(let l) = i.type else { return [] }
        return (l.uris ?? []).compactMap { $0.uri.flatMap { URL(string: $0.contains("://") ? $0 : "https://" + $0)?.host }.flatMap(Domain.of) }
    }
}
