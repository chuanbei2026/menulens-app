import Foundation
import SwiftUI

/// Localized-string lookup that follows the IN-APP language choice.
///
/// `NSLocalizedString` (and SwiftUI's own `LocalizedStringKey`) resolve
/// against the *device* language, which is exactly wrong here: someone
/// travelling with a Chinese phone who picks "Français" in Settings expects
/// every screen to turn French, not just the menu translations. So every
/// user-visible string in the app goes through `L(...)`, which loads the
/// chosen language's `.lproj` bundle by hand.
///
/// Deliberately not `@MainActor`: error descriptions and PDF headers are
/// built off the main thread. `UserDefaults` is thread-safe and `Bundle`
/// lookup is read-only, so this is safe from anywhere.
enum Loc {
    /// Kept as `target_language` (its pre-system-language name) so upgrading
    /// installs keep the language they already chose.
    static let defaultsKey = "target_language"

    static var language: AppLanguage {
        if let code = UserDefaults.standard.string(forKey: defaultsKey),
           let language = AppLanguage(rawValue: code) {
            return language
        }
        return .deviceDefault
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var bundles: [String: Bundle] = [:]

    /// The `<language>.lproj` bundle, cached. Falls back to the main bundle
    /// so a missing translation degrades to the base language rather than
    /// crashing or blanking the screen.
    static func bundle(for language: AppLanguage) -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[language.rawValue] { return cached }
        let resolved = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        bundles[language.rawValue] = resolved
        return resolved
    }

    static func string(_ key: String) -> String {
        // value: key — an untranslated key shows up as itself, which is
        // obvious in a screenshot instead of silently empty.
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }
}

/// Look up one string in the current app language.
func L(_ key: String) -> String {
    Loc.string(key)
}

/// Look up a format string and fill it in. Translations use positional
/// specifiers (`%1$@`, `%2$d`) because word order moves between languages.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Loc.string(key), locale: Loc.language.locale, arguments: arguments)
}

/// Observable face of the same setting, so SwiftUI redraws when it changes.
/// Every view that renders text observes this; nothing is torn down, so a
/// language switch mid-scan keeps the scan.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    @Published private(set) var language: AppLanguage = Loc.language

    var locale: Locale { language.locale }

    private init() {
        // The language can also change from outside Settings (the DEBUG
        // `-targetLang` launch argument), so track the defaults key itself.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.syncFromDefaults() }
        }
    }

    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        UserDefaults.standard.set(new.rawValue, forKey: Loc.defaultsKey)
        language = new
    }

    private func syncFromDefaults() {
        let current = Loc.language
        if current != language { language = current }
    }

    /// Called once at launch so `@AppStorage` reads of the key see the
    /// device-matched default before anything is written.
    static func registerDeviceDefault() {
        UserDefaults.standard.register(defaults: [Loc.defaultsKey: AppLanguage.deviceDefault.rawValue])
    }
}
