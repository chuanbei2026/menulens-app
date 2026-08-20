import Foundation

/// Languages the menu can be translated INTO (the source language is always
/// auto-detected). The raw value is persisted in AppStorage and on MenuScan.
enum TargetLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case spanish = "es"

    var id: String { rawValue }

    /// Shown in Settings and in headers, in the language itself.
    var displayName: String {
        switch self {
        case .simplifiedChinese: return "中文（简体）"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .spanish: return "Español"
        }
    }

    /// Gluten-free matters to English/Spanish-speaking diners; East-Asian
    /// audiences don't look for it, so their lists omit the GF mark.
    var showsGlutenFree: Bool {
        switch self {
        case .english, .french, .spanish: return true
        case .simplifiedChinese, .japanese, .korean: return false
        }
    }

    /// Name used inside the LLM prompt.
    var promptName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }

    static func from(code: String?) -> TargetLanguage {
        code.flatMap(TargetLanguage.init(rawValue:)) ?? .simplifiedChinese
    }
}
