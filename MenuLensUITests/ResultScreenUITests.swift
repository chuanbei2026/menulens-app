import XCTest

/// The multi-page result screen driven by real gestures, on the free
/// `-demoScan` pipeline (bundled samples answer instead of the network):
/// it opens on the status view while pages come in, a failed page is
/// retried from there, the screen moves to the canvas once every page is in,
/// and swipes walk status → each canvas page → list.
///
///   xcodebuild test -scheme MenuLens -destination '…' -only-testing:MenuLensUITests
///
/// Set TEST_RUNNER_FM_SHOTS=<folder> to also write the screenshots there.
final class ResultScreenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-grantConsent", "-noImages", "-targetLang", "en",
            // 3 pages: Naan n Curry 1–2, La Mar. Page 2 fails once; page 3
            // is held back so the status view can be looked at.
            "-demoScan", "naan-n-curry,la-mar", "-failPage", "1", "-delayPage", "2", "8",
        ]
        app.launch()
    }

    func testStatusRetryAutoSwitchAndSwipes() {
        let status = app.buttons["tab.status"]
        let canvas = app.buttons["tab.canvas"]
        let list = app.buttons["tab.list"]

        // Opens on the status view while pages are still out.
        XCTAssertTrue(status.waitForExistence(timeout: 60))
        XCTAssertTrue(status.isSelected)

        // Page 2 fails; retry it from its status row (the run is still on).
        let retry = app.buttons["Retry this page"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        shot("ui_status_failed")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Page 2"].exists)

        // Every page in: the screen moves to the canvas by itself.
        XCTAssertTrue(waitUntil(timeout: 60) { canvas.isSelected })
        XCTAssertFalse(app.buttons["Retry this page"].exists)
        shot("ui_canvas_after")

        // Swipes: back to status, then through the three menu pages to the list.
        app.swipeRight()
        XCTAssertTrue(waitUntil(timeout: 5) { status.isSelected })
        for _ in 0 ..< 3 {
            app.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 5) { canvas.isSelected })
        }
        app.swipeLeft()
        XCTAssertTrue(waitUntil(timeout: 5) { list.isSelected })
        shot("ui_list")

        // The bar: status, then a done page's row jumps to the canvas.
        status.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { status.isSelected })
        app.staticTexts["Page 3"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { canvas.isSelected })
        list.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { list.isSelected })
    }

    /// Landscape iPad: status, canvas and list side by side, no swiping
    /// (and no view-switch bar). Skipped on a phone. FM_LANG picks the app
    /// language (default en).
    func testIPadLandscapeColumns() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        let language = ProcessInfo.processInfo.environment["FM_LANG"] ?? "en"
        app.terminate()
        app.launchArguments = [
            "-grantConsent", "-noImages", "-targetLang", language,
            "-demoScan", "naan-n-curry,la-mar", "-failPage", "1", "-delayPage", "2", "14",
        ]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        // The status column shows the failed page with its retry, mid-scan.
        let retry = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                                     "Retry this page", "重试这一页")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["tab.status"].exists) // columns: no bar
        shot("ipad_\(language)_columns_mid")
        // All pages in (page 2 left failed): the three columns, finished.
        XCTAssertTrue(waitUntil(timeout: 60) {
            self.app.buttons.matching(NSPredicate(format: "label CONTAINS 'PDF'")).count > 0
        })
        shot("ipad_\(language)_columns_done")
        XCUIDevice.shared.orientation = .portrait
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["FM_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
