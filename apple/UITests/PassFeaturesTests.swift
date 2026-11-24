import XCTest

/// Google Authenticator import (from a screenshot of the export QR) and Send (share a copy by link) on a real server.
/// Input: /private/tmp/claude-501/azp-ui.json {email, password, out}. The export QR must be the newest photo in the
/// simulator's library (xcrun simctl addmedia).
final class PassFeaturesTests: XCTestCase {
    var cfg: [String: String] = [:]
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let d = try Data(contentsOf: URL(fileURLWithPath: "/private/tmp/claude-501/azp-ui.json"))
        cfg = try JSONSerialization.jsonObject(with: d) as? [String: String] ?? [:]
    }

    func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: cfg["out"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func wait(_ e: XCUIElement, _ t: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        if !e.waitForExistence(timeout: t) {
            shot("FAIL")
            try? app.debugDescription.write(toFile: (cfg["out"] ?? NSTemporaryDirectory()) + "/FAIL-tree.txt", atomically: true, encoding: .utf8)
            XCTFail("not found: \(e)", file: file, line: line)
        }
    }

    func tap(_ e: XCUIElement, _ t: TimeInterval = 30) { wait(e, t); e.tap() }

    func type(_ field: XCUIElement, _ text: String) {
        wait(field)
        for _ in 0..<4 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 1.5) { break }
        }
        field.typeText(text)
    }

    /// From the email step: a wrong address is refused under the box, then email, Next, password, Sign in.
    func signInByTyping() {
        type(app.textFields["Email"], "not-an-address")
        tap(app.buttons["Next"])
        wait(app.staticTexts["That does not look like an email address."], 5)
        shot("step-email-error")
        app.textFields["Email"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + cfg["email"]!)
        tap(app.buttons["Next"])
        wait(app.secureTextFields["Account password"], 10)
        shot("step-password")
        type(app.secureTextFields["Account password"], cfg["password"]!)
        tap(app.buttons["Sign in"])
    }

    /// The first-start screens as a person meets them: welcome, the email step, the password step, home.
    func testFirstStart() throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uitest-reset"]
        app.launch()
        wait(app.buttons["Create a family account"], 10)
        shot("welcome")
        tap(app.buttons["Create a family account"])
        wait(app.staticTexts["What is your email?"], 10)
        shot("signup-email")
        tap(app.buttons["Back"])
        tap(app.buttons["Sign in"].firstMatch)
        signInByTyping()
        wait(app.staticTexts["Home"].firstMatch, 60) // the page title: an iPad has no bottom tab bar
        shot("home")
    }

    /// Every main screen, captured for a look: the steps of creating an account from a mailed link (nothing is created),
    /// then signing in and the tabs, an item, settings and the new-item sheet.
    func testScreens() throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-uitest-reset"]
        app.launchEnvironment["AZET_PASS_DEBUG_URL"] = "https://pass.azet.io/redirect-connector.html#finish-signup?token=preview&email=kim@azet.example"
        app.launch()
        wait(app.textFields["내 이름"], 15); shot("k1-signup-name")
        type(app.textFields["내 이름"], "김에이젯"); tap(app.buttons["다음"])
        wait(app.secureTextFields["계정 비밀번호"], 10)
        type(app.secureTextFields["계정 비밀번호"], "Preview-only-2026!"); shot("k2-signup-password")
        tap(app.buttons["다음"]); wait(app.secureTextFields["한 번 더 입력"], 10)
        type(app.secureTextFields["한 번 더 입력"], "different"); tap(app.buttons["다음"]); shot("k3-signup-mismatch")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-uitest-reset"]
        app.launch()
        wait(app.buttons["가족 계정 만들기"], 10); sleep(2); shot("k0-welcome")
        tap(app.buttons["로그인"].firstMatch)
        wait(app.textFields["이메일"], 10); shot("k4-signin-email")
        type(app.textFields["이메일"], cfg["email"]!); tap(app.buttons["다음"])
        wait(app.secureTextFields["계정 비밀번호"], 10); shot("k5-signin-password")
        type(app.secureTextFields["계정 비밀번호"], cfg["password"]!); tap(app.buttons["로그인"])
        wait(app.tabBars.buttons["홈"], 60)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for b in [app.buttons["나중에"], sb.buttons["나중에"], app.buttons["Not Now"], sb.buttons["Not Now"]] where b.waitForExistence(timeout: 2) { b.tap(); break }
        sleep(1); shot("k6-home")
        for (i, name) in ["항목", "가족", "보안 점검"].enumerated() { tap(app.tabBars.buttons[name]); sleep(2); shot("k\(7 + i)-\(name)") }
        tap(app.tabBars.buttons["홈"])
        if app.staticTexts["demo-login"].waitForExistence(timeout: 5) { app.staticTexts["demo-login"].tap(); sleep(2); shot("k10-item") }
    }

    func testGoogleImportAndSend() throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uitest-reset"]
        app.launch()
        tap(app.buttons["Sign in"].firstMatch)
        signInByTyping()
        wait(app.staticTexts["Home"].firstMatch, 60) // the page title: an iPad has no bottom tab bar
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for b in [app.buttons["Not Now"], sb.buttons["Not Now"]] where b.waitForExistence(timeout: 3) { b.tap(); break }

        // Google Authenticator export QR, read from a photo
        let row = app.buttons["Import from Google Authenticator"]
        for _ in 0..<4 {  // the system's "save password" sheet can swallow the first tap
            for b in [app.buttons["Not Now"], sb.buttons["Not Now"]] where b.exists { b.tap() }
            tap(app.navigationBars.buttons["Settings"].firstMatch)
            if app.buttons["Import from 1Password, Chrome, CSV"].waitForExistence(timeout: 5) || row.waitForExistence(timeout: 1) { break }
        }
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        tap(row)
        shot("01-google-import")
        tap(app.buttons["Read QR code from a photo"])
        // The picker runs in another process and its photos are not elements: tap the first one (the QR) by position.
        wait(app.buttons["Photos"].firstMatch, 30)
        sleep(2)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 66, dy: 377)).tap()
        wait(app.staticTexts["2 items imported"], 60)
        shot("02-google-imported")

        // Send: share a copy of an imported item by link
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.tabBars.buttons["Home"])
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("Naver") }
        tap(app.staticTexts["Naver"].firstMatch)
        tap(app.buttons["Share a copy by link"])
        tap(app.buttons["Create link"])
        wait(app.staticTexts["Link ready"], 60)
        shot("03-send-link")
    }
}
