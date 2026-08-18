import CoreGraphics
import Foundation

/// A rectangle normalized to the source photo: all fields are in 0...1,
/// with the origin at the photo's top-left corner.
struct NormalizedRect: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

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

/// One token of the interlinear (word-by-word) gloss:
/// the foreign word as printed on the menu, an optional romanization
/// (e.g. kana reading / pinyin-style transcription), and its Chinese meaning.
struct WordGloss: Codable, Hashable {
    let text: String
    let romanization: String?
    let chinese: String
}

/// One dish on the menu.
struct MenuItemEntry: Codable, Hashable {
    let originalName: String
    let chineseName: String
    let price: String?
    let originalDescription: String?
    let chineseDescription: String?
    /// Word-by-word gloss of the dish name.
    let words: [WordGloss]
    /// Word-by-word gloss of the description, when the menu has one.
    let descriptionWords: [WordGloss]?
    /// Where this item's text block sits on the photo.
    let bbox: NormalizedRect
    /// Where this item's printed photo sits on the menu photo, if the menu
    /// itself shows a picture of the dish. Used to crop the 配图.
    let photoBBox: NormalizedRect?
}

/// A titled group of dishes ("Appetizers", "前菜", ...).
struct MenuSection: Codable, Hashable {
    let originalTitle: String?
    let chineseTitle: String?
    let bbox: NormalizedRect?
    let items: [MenuItemEntry]
}

/// The whole analyzed menu.
struct MenuDocument: Codable, Hashable {
    /// BCP-47-ish language name detected by the model, e.g. "Japanese", "French".
    let sourceLanguage: String
    /// Chinese name of the detected language, e.g. "日语".
    let sourceLanguageChinese: String
    let restaurantName: String?
    let sections: [MenuSection]

    var allItems: [MenuItemEntry] { sections.flatMap(\.items) }
}
