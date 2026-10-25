import XCTest

/// iPhone Duo: folding and unfolding keeps what the reader has. Each test
/// starts on the unfolded (inner) screen, prints `DUO-FOLD-NOW`, waits for the
/// window to change size, then `DUO-UNFOLD-NOW` and waits again. Something
/// outside folds the simulator meanwhile: `tools/duo-fold.sh`, or
/// `tools/duo-fold-test.sh`, which runs these tests and answers the cues.
/// Skipped unless DUO_FOLD=1 (TEST_RUNNER_DUO_FOLD=1). FM_SHOTS as in
/// ResultScreenUITests.
final class DuoFoldUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DUO_FOLD"] == "1" else {
            throw XCTSkip("needs DUO_FOLD=1 and someone folding the iPhone Duo simulator")
        }
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The result screen: canvas and list side by side unfolded, the pager
    /// folded. The search, the order and the view in use carry across.
    func testResultKeepsSearchOrderAndViewAcrossFolding() {
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-grantConsent", "-noImages", "-targetLang", "en",
            "-demoScan", "naan-n-curry,la-mar",
        ]
        app.launch()

        // Unfolded: the list is on screen next to the canvas, no view bar.
        let search = app.textFields["Search dishes (translated or original)"]
        XCTAssertTrue(search.waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["tab.list"].exists)
        search.tap()
        search.typeText("paneer")
        let dish = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "TANDOORI PANEER")).firstMatch
        if !dish.waitForExistence(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(dish.exists)
        app.buttons["dish.add"].firstMatch.tap()
        // The cart bar stays out of the way while the keyboard is up.
        XCTAssertTrue(app.staticTexts["1"].waitForExistence(timeout: 5))
        let selected = app.staticTexts["1 selected"]
        XCTAssertFalse(selected.exists)
        shot("duo_result_unfolded")

        // Folded: the pager, on the list (the view in use), same search, same order.
        var size = waitForResize(from: app.windows.firstMatch.frame.size, cue: "DUO-FOLD-NOW")
        XCTAssertTrue(app.buttons["tab.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tab.list"].isSelected, "folding shows the list the reader was using")
        XCTAssertEqual(search.value as? String, "paneer")
        XCTAssertTrue(dish.exists)
        XCTAssertTrue(selected.exists)
        shot("duo_result_folded")

        // On the cover screen, move to the canvas; unfolding keeps the search.
        app.buttons["tab.canvas"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.app.buttons["tab.canvas"].isSelected })
        size = waitForResize(from: size, cue: "DUO-UNFOLD-NOW")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["tab.list"].exists)
        XCTAssertEqual(search.value as? String, "paneer")
        XCTAssertTrue(selected.exists)
        shot("duo_result_unfolded_again")
    }

    /// The home screen's queued pages and an open picker (the camera falls
    /// back to the photo picker in the simulator) stay through folding.
    func testCapturePickerStaysOpenAcrossFolding() {
        app.launchArguments = ["-AppleLanguages", "(en)", "-grantConsent"]
        app.launch()

        let camera = app.buttons["Camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 20))
        camera.tap()
        // UIImagePickerController: the camera on a device, the library here.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        shot("duo_picker_unfolded")

        var size = waitForResize(from: app.windows.firstMatch.frame.size, cue: "DUO-FOLD-NOW")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the picker is still open after folding")
        shot("duo_picker_folded")
        size = waitForResize(from: size, cue: "DUO-UNFOLD-NOW")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the picker is still open after unfolding")
        cancel.tap()
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
    }

    /// Prints the cue, then waits until the window's size differs from `size` and has settled.
    private func waitForResize(from size: CGSize, cue: String) -> CGSize {
        print(cue)
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let now = window.frame.size
            if now != size {
                sleep(3) // the fold animation and the relayout
                return window.frame.size
            }
            usleep(300_000)
        }
        XCTFail("the screen never changed size after \(cue)")
        return size
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
        // XCUIScreen.main is the cover screen, black while unfolded: take
        // every screen and keep the one with a picture (the larger PNG).
        let screenshot = XCUIScreen.screens.map { $0.screenshot() }
            .max { $0.pngRepresentation.count < $1.pngRepresentation.count }!
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["FM_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
