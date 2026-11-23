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

    func testGoogleImportAndSend() throws {
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uitest-reset"]
        app.launch()
        tap(app.buttons["Sign in"].firstMatch)
        type(app.textFields["Email"], cfg["email"]!)
        type(app.secureTextFields["Account password"], cfg["password"]!)
        let signIns = app.buttons.matching(NSPredicate(format: "label == 'Sign in'"))
        signIns.element(boundBy: signIns.count - 1).tap()
        wait(app.tabBars.buttons["Home"], 60)
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
