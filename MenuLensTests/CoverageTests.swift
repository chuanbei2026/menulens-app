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

    /// Every line returned, but far fewer dishes than dish names: the six
    /// v21 validation runs (dishes / dish_name lines, all 144/144 lines).
    func testRetriesWhenDishesGoMissing() {
        func run(dishes: Int, dishNames: Int) -> Coverage {
            Coverage(indices: Array(0 ..< 144), lineCount: 144, dishes: dishes,
                     dishNameIndices: Array(0 ..< dishNames))
        }
        XCTAssertTrue(run(dishes: 16, dishNames: 39).needsRetry)  // zh-Hans, 0.41
        XCTAssertTrue(run(dishes: 17, dishNames: 30).needsRetry)  // en, 0.57
        XCTAssertFalse(run(dishes: 28, dishNames: 30).needsRetry) // zh-Hant
        XCTAssertFalse(run(dishes: 27, dishNames: 28).needsRetry) // zh-Hans
        XCTAssertFalse(run(dishes: 28, dishNames: 25).needsRetry) // en: more dishes than names
        XCTAssertFalse(run(dishes: 24, dishNames: 30).needsRetry) // exactly 0.8
        XCTAssertTrue(run(dishes: 16, dishNames: 39).tooFewDishes)
        XCTAssertFalse(run(dishes: 16, dishNames: 39).fraction < Coverage.retryBelow)
    }

    func testSmallPagesSkipTheDishCheck() {
        // Under 5 dish names the ratio is noise: 1 dish for 4 names is fine.
        let small = Coverage(indices: Array(0 ..< 20), lineCount: 20, dishes: 1,
                             dishNameIndices: [2, 5, 8, 11])
        XCTAssertFalse(small.needsRetry)
        let five = Coverage(indices: Array(0 ..< 20), lineCount: 20, dishes: 3,
                            dishNameIndices: [2, 5, 8, 11, 14])
        XCTAssertTrue(five.needsRetry) // 3 < 0.8 × 5
        // Duplicate or out-of-range dish_name indices don't inflate the count.
        let noisy = Coverage(indices: Array(0 ..< 20), lineCount: 20, dishes: 3,
                             dishNameIndices: [2, 2, 5, 5, 8, 40, -1])
        XCTAssertEqual(noisy.dishNameLines, 3)
        XCTAssertFalse(noisy.needsRetry)
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
