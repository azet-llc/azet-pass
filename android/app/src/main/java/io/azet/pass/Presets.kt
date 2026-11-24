package io.azet.pass

/** One-tap logins for sites people actually use: pick one and only the user name and password are left to type. */
data class Preset(val name: String, val url: String, val group: String)

object Presets {
    val korea = listOf(
        Preset("네이버", "https://nid.naver.com", "portal"),
        Preset("카카오", "https://accounts.kakao.com", "portal"),
        Preset("다음 메일", "https://mail.daum.net", "portal"),
        Preset("Google", "https://accounts.google.com", "portal"),
        Preset("정부24", "https://www.gov.kr", "government"),
        Preset("홈택스", "https://www.hometax.go.kr", "government"),
        Preset("국민건강보험", "https://www.nhis.or.kr", "government"),
        Preset("국민연금", "https://www.nps.or.kr", "government"),
        Preset("정부24 민원(여권·등본)", "https://www.gov.kr/mw", "government"),
        Preset("KB국민은행", "https://www.kbstar.com", "bank"),
        Preset("신한은행", "https://www.shinhan.com", "bank"),
        Preset("우리은행", "https://www.wooribank.com", "bank"),
        Preset("하나은행", "https://www.kebhana.com", "bank"),
        Preset("NH농협은행", "https://banking.nonghyup.com", "bank"),
        Preset("IBK기업은행", "https://www.ibk.co.kr", "bank"),
        Preset("새마을금고", "https://www.kfcc.co.kr", "bank"),
        Preset("우체국", "https://www.epostbank.go.kr", "bank"),
        Preset("카카오뱅크", "https://www.kakaobank.com", "bank"),
        Preset("토스", "https://toss.im", "bank"),
        Preset("신한카드", "https://www.shinhancard.com", "card"),
        Preset("삼성카드", "https://www.samsungcard.com", "card"),
        Preset("현대카드", "https://www.hyundaicard.com", "card"),
        Preset("KB국민카드", "https://card.kbcard.com", "card"),
        Preset("롯데카드", "https://www.lottecard.co.kr", "card"),
        Preset("쿠팡", "https://login.coupang.com", "shopping"),
        Preset("11번가", "https://login.11st.co.kr", "shopping"),
        Preset("G마켓", "https://signinssl.gmarket.co.kr", "shopping"),
        Preset("SSG.COM", "https://member.ssg.com", "shopping"),
        Preset("컬리", "https://www.kurly.com", "shopping"),
        Preset("SK텔레콤 T world", "https://www.tworld.co.kr", "telecom"),
        Preset("KT", "https://www.kt.com", "telecom"),
        Preset("LG U+", "https://www.lguplus.com", "telecom"),
        Preset("배달의민족", "https://www.baemin.com", "delivery"),
        Preset("요기요", "https://www.yogiyo.co.kr", "delivery"),
        Preset("코레일", "https://www.letskorail.com", "delivery"),
        Preset("SRT", "https://etk.srail.kr", "delivery"),
        Preset("대한항공", "https://www.koreanair.com", "delivery"),
        Preset("넷플릭스", "https://www.netflix.com", "media"),
        Preset("유튜브", "https://www.youtube.com", "media"),
        Preset("티빙", "https://www.tving.com", "media"),
        Preset("웨이브", "https://www.wavve.com", "media"),
        Preset("멜론", "https://member.melon.com", "media"),
        Preset("쿠팡플레이", "https://www.coupangplay.com", "media"),
        Preset("인스타그램", "https://www.instagram.com", "social"),
        Preset("페이스북", "https://www.facebook.com", "social"),
        Preset("밴드", "https://auth.band.us", "social"),
        Preset("카카오스토리", "https://story.kakao.com", "social"),
        Preset("아파트아이", "https://www.apti.co.kr", "work"),
        Preset("학교 알리미 · e알리미", "https://www.ealimi.com", "work"),
    )
    val world = listOf(
        Preset("Google", "https://accounts.google.com", "portal"),
        Preset("Apple Account", "https://account.apple.com", "portal"),
        Preset("Microsoft", "https://login.live.com", "portal"),
        Preset("Amazon", "https://www.amazon.com", "shopping"),
        Preset("PayPal", "https://www.paypal.com", "bank"),
        Preset("Chase", "https://www.chase.com", "bank"),
        Preset("Bank of America", "https://www.bankofamerica.com", "bank"),
        Preset("IRS", "https://www.irs.gov", "government"),
        Preset("Social Security", "https://www.ssa.gov", "government"),
        Preset("Netflix", "https://www.netflix.com", "media"),
        Preset("Spotify", "https://accounts.spotify.com", "media"),
        Preset("Disney+", "https://www.disneyplus.com", "media"),
        Preset("Facebook", "https://www.facebook.com", "social"),
        Preset("Instagram", "https://www.instagram.com", "social"),
        Preset("Verizon", "https://www.verizon.com", "telecom"),
        Preset("Uber", "https://auth.uber.com", "delivery"),
    )
    val japan = listOf(
        Preset("Yahoo! JAPAN", "https://login.yahoo.co.jp", "portal"),
        Preset("LINE", "https://access.line.me", "social"),
        Preset("楽天", "https://login.account.rakuten.com", "shopping"),
        Preset("マイナポータル", "https://myna.go.jp", "government"),
        Preset("三菱UFJ銀行", "https://direct.bk.mufg.jp", "bank"),
        Preset("ゆうちょ銀行", "https://www.jp-bank.japanpost.jp", "bank"),
        Preset("Amazon.co.jp", "https://www.amazon.co.jp", "shopping"),
    )
    val all get() = korea + world + japan
    /** Group ids in the order they are shown. */
    val groups = listOf("portal", "bank", "card", "government", "shopping", "telecom", "delivery", "media", "social", "work")

    /** The preset a free-form name or address points at (used when reading a notebook page). */
    fun match(text: String): Preset? {
        val t = text.lowercase().replace(" ", "")
        return all.firstOrNull { t.contains(it.name.lowercase().replace(" ", "")) } ?: all.firstOrNull { p ->
            val host = runCatching { java.net.URI(p.url).host }.getOrNull()?.removePrefix("www.") ?: return@firstOrNull false
            val core = host.split(".").dropLast(1).lastOrNull() ?: host
            core.length > 2 && t.contains(core)
        } ?: aliases.entries.firstOrNull { t.contains(it.key) }?.let { a -> all.firstOrNull { it.url == a.value } }
    }

    private fun jamo(s: String) = buildString {
        for (ch in s) if (ch in '\uAC00'..'\uD7A3') { val i = ch - '\uAC00'; append((0x1100 + i / 588).toChar()); append((0x1161 + i % 588 / 28).toChar()); append((0x11A7 + i % 28).toChar()) } else append(ch.lowercaseChar())
    }
    private fun distance(a: String, b: String): Int {
        var prev = IntArray(b.length + 1) { it }
        for (i in 1..a.length) { val cur = IntArray(b.length + 1); cur[0] = i
            for (j in 1..b.length) cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            prev = cur }
        return prev[b.length]
    }
    /** A handwritten Korean site name read one stroke wrong ("쿠땅" for "쿠팡"): the single preset one letter-part away.
     *  Two or more equally close names give nothing, so a misread never picks a site by chance. */
    fun near(text: String): Preset? {
        val t = text.replace(" ", ""); if (t.length < 2 || t.none { it in '\uAC00'..'\uD7A3' }) return null
        val j = jamo(t)
        val hits = all.filter { p -> p.name.any { it in '\uAC00'..'\uD7A3' } && p.name.replace(" ", "").length == t.length && distance(j, jamo(p.name.replace(" ", ""))) == 1 }.distinctBy { it.url }
        return hits.singleOrNull()
    }

    /** Other names people write for the same site. */
    val aliases = mapOf(
        "국민은행" to "https://www.kbstar.com",
        "kb" to "https://www.kbstar.com",
        "농협" to "https://banking.nonghyup.com",
        "기업은행" to "https://www.ibk.co.kr",
        "naver" to "https://nid.naver.com",
        "kakao" to "https://accounts.kakao.com",
        "카톡" to "https://accounts.kakao.com",
        "다음" to "https://mail.daum.net",
        "구글" to "https://accounts.google.com",
        "gmail" to "https://accounts.google.com",
        "지메일" to "https://accounts.google.com",
        "건강보험" to "https://www.nhis.or.kr",
        "연금" to "https://www.nps.or.kr",
        "배민" to "https://www.baemin.com",
        "유플러스" to "https://www.lguplus.com",
        "티월드" to "https://www.tworld.co.kr",
        "애플" to "https://account.apple.com",
        "아이클라우드" to "https://account.apple.com",
    )
}
