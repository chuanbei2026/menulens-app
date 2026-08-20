import Foundation

/// Languages the menu can be translated INTO (the source language is always
/// auto-detected). The raw value is persisted in AppStorage and on MenuScan.
enum TargetLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"

    var id: String { rawValue }

    /// Shown in Settings and in headers, in the language itself.
    var displayName: String {
        switch self {
        case .simplifiedChinese: return "中文（简体）"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
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
        }
    }

    static func from(code: String?) -> TargetLanguage {
        code.flatMap(TargetLanguage.init(rawValue:)) ?? .simplifiedChinese
    }
}
