import XCTest
@testable import MenuLens

/// The Simplified→Traditional safety net applied to zh-Hant scans. The cases
/// are the leaks real models produced (gpt-4.1: 酸橘汁腌鱼; Mistral: 洋蓟), and
/// correct Traditional text that a whole-script transform would have broken.
final class TraditionalChineseTests: XCTestCase {
    private let fix = TraditionalChinese.fixingSimplified

    func testFixesSimplifiedLeaks() {
        XCTAssertEqual(fix("腌"), "醃")
        XCTAssertEqual(fix("鱼"), "魚")
        XCTAssertEqual(fix("蓟"), "薊")
        XCTAssertEqual(fix("經典酸橘汁腌魚"), "經典酸橘汁醃魚")
        XCTAssertEqual(fix("酸橘汁腌鱼"), "酸橘汁醃魚")
        XCTAssertEqual(fix("烤時令根菜，酪梨，洋蓟confit，洋蓟脆片"), "烤時令根菜，酪梨，洋薊confit，洋薊脆片")
        // Taiwan forms, not OpenCC's base ones (爲, 啓).
        XCTAssertEqual(fix("为"), "為")
        XCTAssertEqual(fix("启"), "啟")
    }

    func testLeavesTraditionalTextAlone() {
        // Characters with several Traditional forms are not touched: 干貝 is
        // right as written (ICU's Hans-Hant makes it 乾貝), and so are 杰 in a
        // transliteration, the surname 范, 了解 and 秘魯.
        for text in ["經典", "頭髮", "發票", "干貝", "北海道干貝", "鄧杰內斯蟹", "范", "了解",
                     "秘魯", "濃郁", "里脊", "牛裡脊", "臺灣", "台灣", "麵包", "雲吞"] {
            XCTAssertEqual(fix(text), text, text)
        }
    }

    func testLeavesNonChineseAlone() {
        for text in ["", "Clásico* 31 (f)(sme)", "$14.99", "ceviche — Limeño", "唐揚げ定食", "김치찌개"] {
            XCTAssertEqual(fix(text), text, text)
        }
    }

    func testIdempotent() {
        let once = fix("经典酸橘汁腌鱼，为你推荐")
        XCTAssertEqual(once, "經典酸橘汁醃魚，為你推荐") // 荐 has two Traditional forms: left alone
        XCTAssertEqual(fix(once), once)
    }

    func testMapsOnlyTranslatedFields() {
        let box = NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let document = MenuDocument(
            sourceLanguage: "Chinese",
            sourceLanguageChinese: "简体中文",
            restaurantName: "鱼家",
            sections: [MenuSection(
                originalTitle: "凉菜",
                chineseTitle: "凉菜",
                bbox: box,
                items: [MenuItemEntry(
                    originalName: "腌鱼", chineseName: "腌鱼", price: "¥38",
                    originalDescription: "鱼", chineseDescription: "鱼",
                    bbox: box, photoBBox: nil, recommendation: "鱼最好"
                )]
            )],
            textLines: [TextLine(role: "dish_name", original: "腌鱼", translated: "腌鱼", box: box)]
        )
        let mapped = document.mappingTranslations(fix)
        let item = mapped.sections[0].items[0]
        XCTAssertEqual(mapped.sourceLanguageChinese, "簡體中文")
        XCTAssertEqual(mapped.sections[0].chineseTitle, "涼菜")
        XCTAssertEqual(item.chineseName, "醃魚")
        XCTAssertEqual(item.chineseDescription, "魚")
        XCTAssertEqual(item.recommendation, "魚最好")
        XCTAssertEqual(mapped.textLines?[0].translated, "醃魚")
        // The menu's own (here Simplified) text is what was printed.
        XCTAssertEqual(mapped.restaurantName, "鱼家")
        XCTAssertEqual(mapped.sections[0].originalTitle, "凉菜")
        XCTAssertEqual(item.originalName, "腌鱼")
        XCTAssertEqual(item.originalDescription, "鱼")
        XCTAssertEqual(mapped.textLines?[0].original, "腌鱼")
    }
}
