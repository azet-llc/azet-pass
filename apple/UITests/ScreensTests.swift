import XCTest

/// Screens that need no server: welcome → sign-in steps → create-account step, in Korean, one PNG each.
/// Output folder = env SHOTS_OUT (default: the runner's temp dir).
final class ScreensTests: XCTestCase {
    func testOnboardingScreens() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHOTS_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var n = 0
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "-uitest-reset"]
        app.launch()
        func shot(_ name: String) {
            n += 1
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
        }
        XCTAssertTrue(app.buttons["가족 계정 만들기"].waitForExistence(timeout: 20))
        sleep(2); shot("welcome")
        app.buttons["로그인"].firstMatch.tap()
        XCTAssertTrue(app.textFields["이메일"].waitForExistence(timeout: 10))
        sleep(1); shot("signin-email")
        app.textFields["이메일"].typeText("mom@example.com")
        app.buttons["다음"].tap()
        XCTAssertTrue(app.secureTextFields["계정 비밀번호"].waitForExistence(timeout: 10))
        sleep(1); shot("signin-password")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["가족 계정 만들기"].tap()
        XCTAssertTrue(app.textFields["이메일"].waitForExistence(timeout: 10))
        sleep(1); shot("signup-email")
    }
}
