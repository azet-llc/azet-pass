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
