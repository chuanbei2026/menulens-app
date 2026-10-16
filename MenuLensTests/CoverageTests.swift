import XCTest
@testable import MenuLens

/// When a page's answer is thin enough to ask again, and which of the two
/// answers is kept. Numbers are from real gpt-4.1 runs on the 144-line La Mar
/// page: 43, 64 and 87 lines returned (retry), 129+ (fine).
final class CoverageTests: XCTestCase {
    private typealias Coverage = OpenAIClient.Coverage

    func testRetriesThinAnswers() {
        XCTAssertTrue(Coverage(indices: Array(0 ..< 43), lineCount: 144, dishes: 17).needsRetry)
        XCTAssertTrue(Coverage(indices: Array(0 ..< 87), lineCount: 144, dishes: 20).needsRetry)
        XCTAssertTrue(Coverage(indices: [], lineCount: 144, dishes: 0).needsRetry)
    }

    func testKeepsCompleteEnoughAnswers() {
        XCTAssertFalse(Coverage(indices: Array(0 ..< 144), lineCount: 144, dishes: 30).needsRetry)
        XCTAssertFalse(Coverage(indices: Array(0 ..< 130), lineCount: 144, dishes: 30).needsRetry) // 90.3%
        XCTAssertTrue(Coverage(indices: Array(0 ..< 129), lineCount: 144, dishes: 30).needsRetry) // 89.6%
        // A page with no OCR lines has nothing to cover.
        XCTAssertFalse(Coverage(indices: [], lineCount: 0, dishes: 0).needsRetry)
    }

    func testCountsDistinctInRangeIndicesOnly() {
        // Duplicates and out-of-range indices don't make an answer complete.
        let coverage = Coverage(indices: [0, 0, 1, 1, 2, 7, -1, 99], lineCount: 4, dishes: 1)
        XCTAssertEqual(coverage.returnedLines, 3)
        XCTAssertEqual(coverage.fraction, 0.75)
        XCTAssertTrue(coverage.needsRetry)
    }

    func testKeepsTheBetterAnswer() {
        let first = Coverage(indices: Array(0 ..< 64), lineCount: 144, dishes: 21)
        // More lines wins, whatever the dish count.
        XCTAssertTrue(Coverage(indices: Array(0 ..< 140), lineCount: 144, dishes: 19).isBetter(than: first))
        XCTAssertFalse(Coverage(indices: Array(0 ..< 43), lineCount: 144, dishes: 30).isBetter(than: first))
        // Same lines: more dishes wins; a full tie keeps the first answer.
        XCTAssertTrue(Coverage(indices: Array(0 ..< 64), lineCount: 144, dishes: 22).isBetter(than: first))
        XCTAssertFalse(Coverage(indices: Array(0 ..< 64), lineCount: 144, dishes: 21).isBetter(than: first))
    }
}
