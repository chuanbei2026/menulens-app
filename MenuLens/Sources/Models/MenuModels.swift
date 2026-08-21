import CoreGraphics
import Foundation

/// A rectangle normalized to the source photo: all fields are in 0...1,
/// with the origin at the photo's top-left corner.
struct NormalizedRect: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// The same rectangle as a normalized CGRect (unit square).
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Denormalize into pixel/point coordinates of a concrete canvas.
    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}

/// One dish on the menu.
struct MenuItemEntry: Codable, Hashable {
    let originalName: String
    let chineseName: String
    let price: String?
    let originalDescription: String?
    let chineseDescription: String?
    /// Where this item's NAME line sits on the photo (OCR-refined when
    /// possible; falls back to the VLM's text-block box).
    let bbox: NormalizedRect
    /// Where this item's printed photo sits on the menu photo, if the menu
    /// itself shows a picture of the dish. Used to crop the 配图.
    let photoBBox: NormalizedRect?
    /// Hull of the OCR text lines belonging to this item's description —
    /// the region the replace-style canvas paints over and rewrites in
    /// Chinese. nil when OCR found no matching lines (older scans too).
    var descriptionBBox: NormalizedRect?
    /// The individual OCR line boxes inside descriptionBBox, reading order.
    /// When present, the canvas replaces line-by-line (Lens-style): each
    /// strip is veiled separately and the translation flows through the
    /// original line slots, preserving the menu's own line arrangement.
    var descriptionLines: [NormalizedRect]?
    /// Dietary attributes inferred by the model (menu markings first, then
    /// culinary common sense). Allowed values: vegan, vegetarian,
    /// gluten_free, contains_lamb, contains_seafood.
    var tags: [String]?
}

/// A titled group of dishes ("Appetizers", "前菜", ...).
struct MenuSection: Codable, Hashable {
    let originalTitle: String?
    let chineseTitle: String?
    let bbox: NormalizedRect?
    let items: [MenuItemEntry]
}

/// One OCR-measured text line on the page with its LLM-assigned semantics.
/// Architecture v2: geometry comes exclusively from OCR; the LLM only ever
/// classifies and translates lines — it never emits coordinates.
struct TextLine: Codable, Hashable {
    /// section_title | dish_name | description | price | other
    let role: String
    let original: String
    /// Empty string = keep the original as printed (prices, numbers).
    let translated: String
    let box: NormalizedRect
}

/// One analyzed menu page (the unit returned by a single OpenAI call).
struct MenuDocument: Codable, Hashable {
    /// BCP-47-ish language name detected by the model, e.g. "Japanese", "French".
    let sourceLanguage: String
    /// Chinese name of the detected language, e.g. "日语".
    let sourceLanguageChinese: String
    let restaurantName: String?
    let sections: [MenuSection]
    /// v2 scans: the complete page text inventory (nil on older scans,
    /// which render through the legacy item-only path).
    var textLines: [TextLine]?

    var allItems: [MenuItemEntry] { sections.flatMap(\.items) }
}

/// One complete scan of a menu: one or more photographed pages analyzed
/// together, plus the metadata shown in the history list. This is the unit
/// that gets persisted to Documents/scans/<id>/ and exported as one PDF.
struct MenuScan: Codable, Hashable, Identifiable {
    let id: UUID
    let createdAt: Date
    let restaurantName: String?
    let sourceLanguage: String
    let sourceLanguageChinese: String
    /// One document per photographed page, in page order.
    let pages: [MenuDocument]
    /// TargetLanguage raw value this scan was translated into
    /// (nil on scans made before multi-language support = Chinese).
    var targetLanguage: String?

    var allItems: [MenuItemEntry] { pages.flatMap(\.allItems) }

    /// Combine per-page analysis results into one scan record.
    static func combining(pages: [MenuDocument], targetLanguage: TargetLanguage = .simplifiedChinese) -> MenuScan {
        MenuScan(
            id: UUID(),
            createdAt: Date(),
            restaurantName: pages.compactMap(\.restaurantName).first,
            sourceLanguage: pages.first?.sourceLanguage ?? "unknown",
            sourceLanguageChinese: pages.first?.sourceLanguageChinese ?? "未知",
            pages: pages,
            targetLanguage: targetLanguage.rawValue
        )
    }

    /// Stable key for one dish across the scan, used to file its generated
    /// thumbnail on disk and look it up at render time.
    static func dishKey(page: Int, section: Int, item: Int) -> String {
        "p\(page)_s\(section)_i\(item)"
    }
}
