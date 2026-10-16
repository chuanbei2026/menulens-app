import XCTest
@testable import MenuLens

/// "N pages could not be scanned; the other M were kept" agrees with both
/// numbers (Localizable.stringsdict) in the languages that inflect.
@MainActor
final class PluralNoticeTests: XCTestCase {
    private var saved: AppLanguage!

    override func setUp() async throws {
        saved = Localization.shared.language
    }

    override func tearDown() async throws {
        Localization.shared.setLanguage(saved)
    }

    private func notice(_ language: AppLanguage, failed: Int, kept: Int) -> String {
        Localization.shared.setLanguage(language)
        return L("notice.partialPages", failed, kept)
    }

    func testEnglish() {
        XCTAssertEqual(notice(.english, failed: 1, kept: 2),
                       "1 page could not be scanned; the other 2 were kept. You can retry under Status.")
        XCTAssertEqual(notice(.english, failed: 2, kept: 1),
                       "2 pages could not be scanned; the other page was kept. You can retry under Status.")
        XCTAssertEqual(notice(.english, failed: 3, kept: 2),
                       "3 pages could not be scanned; the other 2 were kept. You can retry under Status.")
    }

    func testFrenchSpanishHindi() {
        XCTAssertEqual(notice(.french, failed: 1, kept: 1),
                       "1 page n'a pas pu être scannée ; la page restante a été conservée. Vous pouvez réessayer depuis État.")
        XCTAssertEqual(notice(.french, failed: 2, kept: 3),
                       "2 pages n'ont pas pu être scannées ; les 3 autres ont été conservées. Vous pouvez réessayer depuis État.")
        XCTAssertEqual(notice(.spanish, failed: 1, kept: 1),
                       "No se ha podido escanear 1 página; se ha conservado la otra. Puedes reintentarlo desde Estado.")
        XCTAssertEqual(notice(.spanish, failed: 2, kept: 3),
                       "No se han podido escanear 2 páginas; se han conservado las otras 3. Puedes reintentarlo desde Estado.")
        XCTAssertEqual(notice(.hindi, failed: 1, kept: 1),
                       "1 पेज स्कैन नहीं हो सका; बाकी 1 पेज रख लिया गया। स्थिति में जाकर फिर से आज़मा सकते हैं।")
        XCTAssertEqual(notice(.hindi, failed: 2, kept: 3),
                       "2 पेज स्कैन नहीं हो सके; बाकी 3 पेज रख लिए गए। स्थिति में जाकर फिर से आज़मा सकते हैं।")
    }

    func testLanguagesWithoutPluralUseTheStringsTable() {
        XCTAssertEqual(notice(.simplifiedChinese, failed: 1, kept: 2), "有 1 页没能识别，已保留其余 2 页。可以在「状态」里重试。")
        XCTAssertEqual(notice(.japanese, failed: 1, kept: 2),
                       "1ページを読み取れませんでしたが、残りの 2ページは保持しました。「状況」から再試行できます。")
    }
}
