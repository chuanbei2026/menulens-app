import XCTest
@testable import MenuLens

/// Which result view opens and when it moves on; how photo-order dish keys
/// map onto the saved scan when pages fail and are retried.
final class ResultLayoutTests: XCTestCase {
    func testInitialView() {
        // A multi-page scan still coming in opens on the status view…
        XCTAssertEqual(ResultTab.initial(pageCount: 3, receivingPages: true), .status)
        // …a single page, a finished scan or one from History on the canvas.
        XCTAssertEqual(ResultTab.initial(pageCount: 1, receivingPages: true), .canvas)
        XCTAssertEqual(ResultTab.initial(pageCount: 3, receivingPages: false), .canvas)
        XCTAssertEqual(ResultTab.initial(pageCount: 1, receivingPages: false), .canvas)
    }

    func testAutoSwitchWhenAllPagesFinished() {
        XCTAssertEqual(ResultTab.afterAllPagesFinished(current: .status, userChoseView: false, anyPageDone: true),
                       .canvas)
        // The user picked a view since the scan started: leave them there.
        XCTAssertNil(ResultTab.afterAllPagesFinished(current: .status, userChoseView: true, anyPageDone: true))
        // Already elsewhere: nothing to do.
        XCTAssertNil(ResultTab.afterAllPagesFinished(current: .list, userChoseView: false, anyPageDone: true))
        XCTAssertNil(ResultTab.afterAllPagesFinished(current: .canvas, userChoseView: false, anyPageDone: true))
        // Nothing landed: the status view (with its retry buttons) stays.
        XCTAssertNil(ResultTab.afterAllPagesFinished(current: .status, userChoseView: false, anyPageDone: false))
    }

    func testCompactionMap() {
        XCTAssertEqual(PageCompaction.map(present: [true, true, true]), [0: 0, 1: 1, 2: 2])
        XCTAssertEqual(PageCompaction.map(present: [true, false, true]), [0: 0, 2: 1])
        XCTAssertEqual(PageCompaction.map(present: [false, false]), [:])
    }

    func testRekeyFirstSaveDropsFailedPage() {
        // Nothing saved yet (keys in photo order); page 2 of 3 failed.
        let saved = PageCompaction.map(present: [true, false, true])
        XCTAssertEqual(PageCompaction.rekey("p0_s1_i2", from: nil, to: saved), "p0_s1_i2")
        XCTAssertNil(PageCompaction.rekey("p1_s0_i0", from: nil, to: saved))
        XCTAssertEqual(PageCompaction.rekey("p2_s0_i4", from: nil, to: saved), "p1_s0_i4")
    }

    func testRekeyLateRetryInsertsPage() {
        // Saved as [photo 0, photo 2]; then photo 1 is retried and comes back.
        let before = PageCompaction.map(present: [true, false, true])
        let after = PageCompaction.map(present: [true, true, true])
        XCTAssertEqual(PageCompaction.rekey("p0_s0_i0", from: before, to: after), "p0_s0_i0")
        // Photo 2's pictures were filed as saved page 1; now page 2.
        XCTAssertEqual(PageCompaction.rekey("p1_s3_i1", from: before, to: after), "p2_s3_i1")
    }

    func testRekeyRejectsGarbage() {
        XCTAssertNil(PageCompaction.rekey("cover", from: nil, to: [0: 0]))
        XCTAssertNil(PageCompaction.rekey("px_s0_i0", from: nil, to: [0: 0]))
        XCTAssertNil(PageCompaction.rekey("p5_s0_i0", from: nil, to: [0: 0]))
    }
}

/// Dish pictures on disk follow their page when a retried page is put back
/// in between: every saved page after it moves UP, which an in-place rename
/// in ascending order would get wrong (p1 → p2 overwrites the old p2).
@MainActor
final class RekeyOnDiskTests: XCTestCase {
    func testRetriedPageMovesLaterPicturesUp() throws {
        let history = HistoryStore()
        let scanID = UUID()
        let dir = history.directory(for: scanID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Saved as [photo 0, photo 2, photo 3]: photo 1 failed.
        for key in ["p0_s0_i0", "p1_s0_i0", "p2_s0_i0"] {
            try Data(key.utf8).write(to: dir.appendingPathComponent("gen_\(key).jpg"))
        }
        let before = PageCompaction.map(present: [true, false, true, true])
        let after = PageCompaction.map(present: [true, true, true, true])
        history.rekeyGeneratedImages(scanID: scanID) { PageCompaction.rekey($0, from: before, to: after) }

        func content(_ key: String) -> String? {
            (try? Data(contentsOf: dir.appendingPathComponent("gen_\(key).jpg"))).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(content("p0_s0_i0"), "p0_s0_i0")
        XCTAssertNil(content("p1_s0_i0")) // the retried page has no pictures yet
        XCTAssertEqual(content("p2_s0_i0"), "p1_s0_i0") // photo 2
        XCTAssertEqual(content("p3_s0_i0"), "p2_s0_i0") // photo 3, not overwritten
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("rekey_") }
        XCTAssertEqual(leftovers, [])
    }
}
