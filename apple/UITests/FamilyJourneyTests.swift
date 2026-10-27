import XCTest

/// The four-people-in-a-day journey on a real server, in Korean, saving a screenshot at every step:
/// organizer signs in → makes the family → invites 엄마 with her own vault → fills it (preset + notebook scan) →
/// parent mode → 엄마 opens the link and signs up → five words → organizer lets her in → 엄마 sees her vault.
/// Input: /private/tmp/claude-501/l649-ui.json {orgEmail, orgPassword, momEmail, momPassword, out}. The notebook
/// photo must be in the simulator's library (xcrun simctl addmedia).
final class FamilyJourneyTests: XCTestCase {
    var cfg: [String: String] = [:]
    var app: XCUIApplication!
    var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        let d = try Data(contentsOf: URL(fileURLWithPath: "/private/tmp/claude-501/l649-ui.json"))
        cfg = try JSONSerialization.jsonObject(with: d) as? [String: String] ?? [:]
    }

    func launch(reset: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"] + (reset ? ["-uitest-reset"] : [])
        app.launch()
    }

    func shot(_ name: String) {
        step += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: cfg["out"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", step, name)))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ t: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !e.waitForExistence(timeout: t) {
            let alert = app.alerts.firstMatch
            shot("FAIL")
            try? app.debugDescription.write(toFile: (cfg["out"] ?? NSTemporaryDirectory()) + "/FAIL-tree.txt", atomically: true, encoding: .utf8)
            XCTFail("not found: \(e) — alert: \(alert.exists ? alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ") : "none")", file: file, line: line)
        }
        return e
    }

    func tap(_ e: XCUIElement, _ t: TimeInterval = 30) {
        if !e.waitForExistence(timeout: t) {
            let alert = app.alerts.firstMatch
            XCTFail("not found: \(e) — alert: \(alert.exists ? alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ") : "none")")
        }
        e.tap()
    }

    func type(_ field: XCUIElement, _ text: String) {
        wait(field)
        for _ in 0..<4 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true || app.keyboards.firstMatch.waitForExistence(timeout: 1.5) { break }
        }
        field.typeText(text)
    }

    func signIn(_ email: String, _ password: String) {
        tap(app.buttons["로그인"].firstMatch)
        type(app.textFields["이메일"], email)
        type(app.secureTextFields["계정 비밀번호"], password)
        app.buttons.matching(NSPredicate(format: "label == '로그인'")).element(boundBy: app.buttons.matching(NSPredicate(format: "label == '로그인'")).count - 1).tap()
        wait(app.tabBars.buttons["홈"], 60)
        dismissSavePassword()
    }

    /// iOS offers to save the typed account password in Apple Passwords; say not now.
    func dismissSavePassword() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            for b in [app.buttons["지금 안 함"], sb.buttons["지금 안 함"], app.buttons["Not Now"], sb.buttons["Not Now"]] where b.waitForExistence(timeout: 2) { b.tap(); return }
        }
    }

    func signOut() {
        tap(app.navigationBars.buttons["설정"].firstMatch)
        let out = app.buttons["로그아웃"]
        for _ in 0..<6 where !out.isHittable { app.swipeUp() }
        out.tap()
        wait(app.buttons["가족 계정 만들기"], 20)
    }

    func testFamilyDay() throws {
        let org = cfg["orgEmail"]!, orgPw = cfg["orgPassword"]!, mom = cfg["momEmail"]!, momPw = cfg["momPassword"]!
        launch(reset: true)
        wait(app.buttons["가족 계정 만들기"])
        shot("welcome")
        signIn(org, orgPw)
        shot("home")

        // 1 family
        // the Passwords "save?" sheet can swallow the first tap: retry until the family page shows
        for _ in 0..<4 {
            dismissSavePassword()
            tap(app.tabBars.buttons["가족"])
            if app.textFields["가족 이름 (예: 김씨네)"].waitForExistence(timeout: 6) || app.staticTexts["가족 세팅"].exists { break }
        }
        if app.textFields["가족 이름 (예: 김씨네)"].exists {
            shot("family-create")
            type(app.textFields["가족 이름 (예: 김씨네)"], "김씨네")
            tap(app.buttons["가족 만들기"])
        }
        wait(app.staticTexts["가족 세팅"], 40)
        shot("family-checklist-start")

        // 2 invite 엄마 with her own vault
        tap(app.buttons["가족 초대하기"])
        type(app.textFields["이름 (예: 엄마)"], "엄마")
        type(app.textFields["그분 이메일"], mom)
        shot("invite-form")
        tap(app.buttons["초대 링크 만들기"])
        wait(app.staticTexts["초대 준비 완료"], 40)
        shot("invite-ready")
        // the link is the copy button's value (reading UIPasteboard from the runner raises iOS's paste prompt)
        let link = wait(app.buttons["링크 복사"]).value as? String ?? ""
        XCTAssertTrue(link.contains("/invite#"), "copied link: \(link)")
        tap(app.buttons["완료"])

        // 3 fill 엄마's vault: a preset, then the notebook page
        let momVault = app.buttons["vault.엄마"].firstMatch
        for _ in 0..<5 where !momVault.waitForExistence(timeout: 3) { app.swipeUp() }
        tap(momVault)
        tap(app.buttons["이 금고에 로그인 추가"])
        type(app.searchFields.firstMatch, "은행")
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS 'KB국민은행'")).firstMatch)
        shot("presets-korea")
        app.searchFields.firstMatch.buttons.firstMatch.tap()   // clear
        type(app.searchFields.firstMatch, "네이버")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS '네이버' AND NOT label CONTAINS '새 로그인'")).firstMatch)
        type(app.textFields["아이디"], "soonja.kim")
        type(app.secureTextFields["비밀번호"], "Naver-2026!")
        shot("preset-naver-edit")
        tap(app.buttons["저장"])
        wait(app.buttons["메모장 사진을 이 금고로"], 30)
        tap(app.buttons["메모장 사진을 이 금고로"])
        shot("scan-start")
        tap(app.buttons["사진 고르기"])
        // the photo picker runs out of process: tap the newest photo (top-left, the notebook page) by position
        sleep(4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.24)).tap()
        wait(app.textFields.matching(NSPredicate(format: "value == 'KB국민은행'")).firstMatch, 60)
        shot("scan-found-4")
        let save4 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '4개 저장'")).firstMatch
        for _ in 0..<8 where !(save4.exists && save4.isHittable) { app.swipeUp() }
        tap(save4)
        wait(app.staticTexts["4개 저장했어요"], 60)
        shot("scan-saved")
        tap(app.buttons["완료"])
        shot("vault-mom-filled")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        shot("family-checklist-filled")

        // 4 parent mode
        tap(app.navigationBars.buttons["설정"].firstMatch)
        let parent = app.switches["부모님 모드"]
        wait(parent)
        let knob = parent.switches.firstMatch   // tapping the row's label does not flip a SwiftUI Toggle
        (knob.exists ? knob : parent).tap()
        // parent mode replaces the whole screen, which usually closes Settings on its own
        if app.buttons["완료"].waitForExistence(timeout: 3) { app.buttons["완료"].tap() }
        wait(app.buttons["비밀번호 찾기"])
        shot("parent-mode")
        tap(app.buttons["전체 앱 보기"])
        signOut()

        // 5 엄마 opens the link on "her" phone and signs up straight from it
        let scheme = link.replacingOccurrences(of: "https://pass.azet.io/invite", with: "azetpass://invite")
        XCUIDevice.shared.system.open(URL(string: scheme)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["열기"].waitForExistence(timeout: 5) { springboard.buttons["열기"].tap() }
        else if springboard.buttons["Open"].waitForExistence(timeout: 2) { springboard.buttons["Open"].tap() }
        wait(app.secureTextFields["계정 비밀번호"], 40)
        shot("mom-invite-signup")
        type(app.secureTextFields["계정 비밀번호"], momPw)
        type(app.secureTextFields["한 번 더 입력"], momPw)
        tap(app.buttons["계정 만들기"])
        dismissSavePassword()
        wait(app.staticTexts["들어왔어요. 마지막 한 단계"], 90)
        shot("mom-five-words")
        tap(app.buttons["완료"])
        signOut()

        // 6 organizer compares the words and lets her in
        signIn(org, orgPw)
        tap(app.tabBars.buttons["가족"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS '확인 기다림'")).firstMatch, 40)
        tap(app.buttons["다섯 단어 맞춰 보기"])
        wait(app.buttons["같은 단어예요, 들이기"])
        shot("organizer-five-words")
        tap(app.buttons["같은 단어예요, 들이기"])
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(app.staticTexts["가족 세팅"])
        shot("family-checklist-done")
        signOut()

        // 7 엄마 sees everything that was prepared for her
        signIn(mom, momPw)
        tap(app.tabBars.buttons["항목"])
        tap(app.buttons["엄마"].firstMatch)
        wait(app.staticTexts["네이버"], 30)
        shot("mom-sees-vault")
    }
}
