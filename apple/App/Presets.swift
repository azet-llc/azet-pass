import Foundation

/// One-tap logins for sites people actually use, by region (1Password: "search for popular logins"). The region list
/// is the only place countries live; the device region picks the first group shown, the rest stay searchable.
struct Preset: Identifiable, Hashable {
    var id: String { url }
    let name: String
    let url: String
    let group: Group
    /// What people usually type as the ID there (shown as the field hint).
    var idHint: String? = nil
    /// Extra fields worth saving for this site (e.g. bank security card, certificate password).
    var extras: [String] = []

    enum Group: String, CaseIterable {
        case portal, bank, card, government, shopping, telecom, delivery, media, social, work
        var title: String {
            switch self {
            case .portal: String(localized: "Portals & mail")
            case .bank: String(localized: "Banks")
            case .card: String(localized: "Card companies")
            case .government: String(localized: "Government")
            case .shopping: String(localized: "Shopping")
            case .telecom: String(localized: "Phone carriers")
            case .delivery: String(localized: "Delivery & travel")
            case .media: String(localized: "Video & music")
            case .social: String(localized: "Social")
            case .work: String(localized: "Work & study")
            }
        }
    }

    static let byRegion: [String: [Preset]] = ["KR": korea, "US": world, "JP": japan]

    static func forDevice() -> [Preset] {
        let r = Locale.current.region?.identifier ?? "KR"
        let first = byRegion[r] ?? world
        return first + byRegion.filter { $0.key != r }.flatMap(\.value).filter { p in !first.contains { $0.url == p.url } }
    }

    static let korea: [Preset] = [
        Preset(name: "네이버", url: "https://nid.naver.com", group: .portal, idHint: "아이디"),
        Preset(name: "카카오", url: "https://accounts.kakao.com", group: .portal, idHint: "카카오메일 또는 전화번호"),
        Preset(name: "다음 메일", url: "https://mail.daum.net", group: .portal),
        Preset(name: "Google", url: "https://accounts.google.com", group: .portal),
        Preset(name: "정부24", url: "https://www.gov.kr", group: .government, idHint: "아이디", extras: ["간편인증 방법"]),
        Preset(name: "홈택스", url: "https://www.hometax.go.kr", group: .government, idHint: "아이디", extras: ["공동인증서 비밀번호"]),
        Preset(name: "국민건강보험", url: "https://www.nhis.or.kr", group: .government),
        Preset(name: "국민연금", url: "https://www.nps.or.kr", group: .government),
        Preset(name: "정부24 민원(여권·등본)", url: "https://www.gov.kr/mw", group: .government),
        Preset(name: "KB국민은행", url: "https://www.kbstar.com", group: .bank, extras: ["보안카드 번호", "이체 비밀번호", "인증서 비밀번호"]),
        Preset(name: "신한은행", url: "https://www.shinhan.com", group: .bank, extras: ["보안카드 번호", "이체 비밀번호", "인증서 비밀번호"]),
        Preset(name: "우리은행", url: "https://www.wooribank.com", group: .bank, extras: ["보안카드 번호", "이체 비밀번호", "인증서 비밀번호"]),
        Preset(name: "하나은행", url: "https://www.kebhana.com", group: .bank, extras: ["보안카드 번호", "이체 비밀번호", "인증서 비밀번호"]),
        Preset(name: "NH농협은행", url: "https://banking.nonghyup.com", group: .bank, extras: ["보안카드 번호", "이체 비밀번호", "인증서 비밀번호"]),
        Preset(name: "IBK기업은행", url: "https://www.ibk.co.kr", group: .bank, extras: ["보안카드 번호", "이체 비밀번호"]),
        Preset(name: "새마을금고", url: "https://www.kfcc.co.kr", group: .bank),
        Preset(name: "우체국", url: "https://www.epostbank.go.kr", group: .bank),
        Preset(name: "카카오뱅크", url: "https://www.kakaobank.com", group: .bank, idHint: "앱 비밀번호 6자리", extras: ["앱 비밀번호"]),
        Preset(name: "토스", url: "https://toss.im", group: .bank, idHint: "전화번호", extras: ["앱 비밀번호"]),
        Preset(name: "신한카드", url: "https://www.shinhancard.com", group: .card),
        Preset(name: "삼성카드", url: "https://www.samsungcard.com", group: .card),
        Preset(name: "현대카드", url: "https://www.hyundaicard.com", group: .card),
        Preset(name: "KB국민카드", url: "https://card.kbcard.com", group: .card),
        Preset(name: "롯데카드", url: "https://www.lottecard.co.kr", group: .card),
        Preset(name: "쿠팡", url: "https://login.coupang.com", group: .shopping, idHint: "이메일 또는 전화번호"),
        Preset(name: "11번가", url: "https://login.11st.co.kr", group: .shopping),
        Preset(name: "G마켓", url: "https://signinssl.gmarket.co.kr", group: .shopping),
        Preset(name: "SSG.COM", url: "https://member.ssg.com", group: .shopping),
        Preset(name: "컬리", url: "https://www.kurly.com", group: .shopping),
        Preset(name: "SK텔레콤 T world", url: "https://www.tworld.co.kr", group: .telecom),
        Preset(name: "KT", url: "https://www.kt.com", group: .telecom),
        Preset(name: "LG U+", url: "https://www.lguplus.com", group: .telecom),
        Preset(name: "배달의민족", url: "https://www.baemin.com", group: .delivery),
        Preset(name: "요기요", url: "https://www.yogiyo.co.kr", group: .delivery),
        Preset(name: "코레일", url: "https://www.letskorail.com", group: .delivery, idHint: "회원번호 또는 전화번호"),
        Preset(name: "SRT", url: "https://etk.srail.kr", group: .delivery),
        Preset(name: "대한항공", url: "https://www.koreanair.com", group: .delivery, idHint: "스카이패스 번호"),
        Preset(name: "넷플릭스", url: "https://www.netflix.com", group: .media),
        Preset(name: "유튜브", url: "https://www.youtube.com", group: .media),
        Preset(name: "티빙", url: "https://www.tving.com", group: .media),
        Preset(name: "웨이브", url: "https://www.wavve.com", group: .media),
        Preset(name: "멜론", url: "https://member.melon.com", group: .media),
        Preset(name: "쿠팡플레이", url: "https://www.coupangplay.com", group: .media),
        Preset(name: "인스타그램", url: "https://www.instagram.com", group: .social),
        Preset(name: "페이스북", url: "https://www.facebook.com", group: .social),
        Preset(name: "밴드", url: "https://auth.band.us", group: .social),
        Preset(name: "카카오스토리", url: "https://story.kakao.com", group: .social),
        Preset(name: "아파트아이", url: "https://www.apti.co.kr", group: .work),
        Preset(name: "학교 알리미 · e알리미", url: "https://www.ealimi.com", group: .work),
    ]

    static let world: [Preset] = [
        Preset(name: "Google", url: "https://accounts.google.com", group: .portal),
        Preset(name: "Apple Account", url: "https://account.apple.com", group: .portal),
        Preset(name: "Microsoft", url: "https://login.live.com", group: .portal),
        Preset(name: "Amazon", url: "https://www.amazon.com", group: .shopping),
        Preset(name: "PayPal", url: "https://www.paypal.com", group: .bank),
        Preset(name: "Chase", url: "https://www.chase.com", group: .bank),
        Preset(name: "Bank of America", url: "https://www.bankofamerica.com", group: .bank),
        Preset(name: "IRS", url: "https://www.irs.gov", group: .government),
        Preset(name: "Social Security", url: "https://www.ssa.gov", group: .government),
        Preset(name: "Netflix", url: "https://www.netflix.com", group: .media),
        Preset(name: "Spotify", url: "https://accounts.spotify.com", group: .media),
        Preset(name: "Disney+", url: "https://www.disneyplus.com", group: .media),
        Preset(name: "Facebook", url: "https://www.facebook.com", group: .social),
        Preset(name: "Instagram", url: "https://www.instagram.com", group: .social),
        Preset(name: "Verizon", url: "https://www.verizon.com", group: .telecom),
        Preset(name: "Uber", url: "https://auth.uber.com", group: .delivery),
    ]

    static let japan: [Preset] = [
        Preset(name: "Yahoo! JAPAN", url: "https://login.yahoo.co.jp", group: .portal),
        Preset(name: "LINE", url: "https://access.line.me", group: .social),
        Preset(name: "楽天", url: "https://login.account.rakuten.com", group: .shopping),
        Preset(name: "マイナポータル", url: "https://myna.go.jp", group: .government),
        Preset(name: "三菱UFJ銀行", url: "https://direct.bk.mufg.jp", group: .bank),
        Preset(name: "ゆうちょ銀行", url: "https://www.jp-bank.japanpost.jp", group: .bank),
        Preset(name: "Amazon.co.jp", url: "https://www.amazon.co.jp", group: .shopping),
    ]

    /// Picks the preset whose site a free-form name or URL points at (used by notebook scanning).
    static func match(_ text: String) -> Preset? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        let all = korea + world + japan
        return all.first { t.contains($0.name.lowercased().replacingOccurrences(of: " ", with: "")) }
            ?? all.first { p in
                guard let host = URL(string: p.url)?.host?.replacingOccurrences(of: "www.", with: "") else { return false }
                let core = host.split(separator: ".").dropLast().last.map(String.init) ?? host
                return t.contains(core) && core.count > 2
            }
            ?? aliases.first { t.contains($0.key) }.flatMap { a in all.first { $0.url == a.value } }
    }

    static let aliases: [String: String] = [
        "국민은행": "https://www.kbstar.com", "kb": "https://www.kbstar.com", "농협": "https://banking.nonghyup.com",
        "기업은행": "https://www.ibk.co.kr", "naver": "https://nid.naver.com", "kakao": "https://accounts.kakao.com",
        "카톡": "https://accounts.kakao.com", "다음": "https://mail.daum.net", "구글": "https://accounts.google.com",
        "gmail": "https://accounts.google.com", "지메일": "https://accounts.google.com", "건강보험": "https://www.nhis.or.kr",
        "연금": "https://www.nps.or.kr", "배민": "https://www.baemin.com", "유플러스": "https://www.lguplus.com",
        "티월드": "https://www.tworld.co.kr", "애플": "https://account.apple.com", "아이클라우드": "https://account.apple.com",
    ]
}
