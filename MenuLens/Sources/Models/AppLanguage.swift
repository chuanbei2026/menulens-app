import Foundation

/// The app's one language setting. It is BOTH the language every screen is
/// drawn in AND the language menus get translated into — picking "Français"
/// in Settings means a French UI and French translations. (The menu's own
/// language is never set by hand; it is always auto-detected.)
///
/// The raw value is a bundle localization name, so it doubles as the
/// `.lproj` directory to load strings from — see `Loc`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case spanish = "es"

    var id: String { rawValue }

    /// Shown in the Settings picker, each language written in itself — the
    /// one list a user must be able to read before the UI is in their
    /// language.
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

    var locale: Locale { Locale(identifier: rawValue) }

    /// Gluten-free matters to English/French/Spanish-speaking diners; East-Asian
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

    /// Resolve a persisted code. The nil fallback is deliberately Chinese
    /// and NOT the device language: this is what decodes `MenuScan
    /// .targetLanguage`, and a scan saved before multi-language support was
    /// translated into Chinese.
    static func from(code: String?) -> AppLanguage {
        code.flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    /// What a fresh install starts in: the device language when we speak it,
    /// otherwise English. Defaulting to Chinese would hand most of the world
    /// — App Review included — a UI they cannot read.
    static var deviceDefault: AppLanguage {
        for identifier in Locale.preferredLanguages {
            switch identifier.split(separator: "-").first.map(String.init)?.lowercased() {
            case "zh": return .simplifiedChinese // incl. zh-Hant: closer than English
            case "en": return .english
            case "ja": return .japanese
            case "ko": return .korean
            case "fr": return .french
            case "es": return .spanish
            default: continue
            }
        }
        return .english
    }
}
