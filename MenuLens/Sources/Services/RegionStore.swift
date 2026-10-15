import StoreKit
import SwiftUI

/// Which models (and whether dish pictures) the App Store storefront allows.
/// OpenAI doesn't serve every region; the server picks what each storefront
/// may use (`GET /models?storefront=`) and checks the `X-Storefront` header
/// every request carries (see `Backend.request`).
@MainActor
final class RegionStore: ObservableObject {
    static let shared = RegionStore()

    struct Model: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let provider: String
    }

    struct Catalog: Codable, Equatable {
        /// nil: no model is offered in this region at all.
        var defaultModel: String?
        var images: Bool
        var models: [Model]

        enum CodingKeys: String, CodingKey {
            case defaultModel = "default", images, models
        }

        /// What the app offered before regions existed.
        static let openAI = Catalog(defaultModel: "gpt-4.1", images: true, models: [
            Model(id: "gpt-4.1", name: "GPT-4.1", provider: "openai"),
            Model(id: "gpt-5-mini", name: "GPT-5 mini", provider: "openai"),
            Model(id: "gpt-5", name: "GPT-5", provider: "openai"),
            Model(id: "gpt-4o", name: "GPT-4o", provider: "openai"),
        ])
        /// Where OpenAI doesn't serve but Bedrock does.
        static let mistralOnly = Catalog(defaultModel: "mistral-large-3", images: false, models: [
            Model(id: "mistral-large-3", name: "Mistral Large 3", provider: "bedrock"),
        ])
    }

    /// ISO 3166 alpha-3 of the App Store storefront ("USA"); nil until known.
    @Published private(set) var storefront: String?
    @Published private(set) var catalog: Catalog

    var isAvailable: Bool { catalog.defaultModel != nil }

    /// Read off the main actor by `Backend.request`.
    nonisolated static var storefrontCode: String? {
        codeLock.lock()
        defer { codeLock.unlock() }
        return code
    }

    private nonisolated(unsafe) static var code: String?
    private static let codeLock = NSLock()
    private static let storefrontKey = "region_storefront"
    private var updates: Task<Void, Never>?
    /// The launch-time storefront lookup and catalog fetch; see `ready()`.
    private var firstLoad: Task<Void, Never>?

    /// Cached per storefront: a catalog from another region is no guide.
    private static func cacheKey(_ storefront: String?) -> String {
        "region_catalog.\(storefront ?? "unknown")"
    }

    private static func cached(for storefront: String?) -> Catalog {
        UserDefaults.standard.data(forKey: cacheKey(storefront))
            .flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
            ?? fallback(for: storefront)
    }

    private init() {
        var front = UserDefaults.standard.string(forKey: Self.storefrontKey)
        #if DEBUG
        // `-storefront HKG`: act as if the App Store account were in that region.
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "-storefront").flatMap { index in
            index + 1 < args.count ? args[index + 1].uppercased() : nil
        }
        if let override { front = override }
        #else
        let override: String? = nil
        #endif
        catalog = Self.cached(for: front)
        if let front { setStorefront(front) }
        firstLoad = Task { [weak self] in
            if override == nil, let current = await Storefront.current {
                self?.setStorefront(current.countryCode)
            }
            await self?.refresh()
        }
        guard override == nil else { return }
        updates = Task { [weak self] in
            for await front in Storefront.updates {
                self?.setStorefront(front.countryCode)
                await self?.refresh()
            }
        }
    }

    /// Waits for the launch-time catalog (at most 8 s — `Storefront.current`
    /// can take its time), so the first scan after launch doesn't run on a
    /// stale or wrong-region list. Later calls return at once.
    func ready() async {
        guard let firstLoad else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await firstLoad.value }
            group.addTask { try? await Task.sleep(for: .seconds(8)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func setStorefront(_ value: String) {
        if value != storefront { catalog = Self.cached(for: value) }
        Self.codeLock.lock()
        Self.code = value
        Self.codeLock.unlock()
        storefront = value
        UserDefaults.standard.set(value, forKey: Self.storefrontKey)
    }

    /// Fetches this storefront's catalog (cached for offline launches) and
    /// moves the chosen model to the default when it is no longer offered.
    func refresh() async {
        var components = URLComponents(url: Backend.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        if let storefront { components.queryItems = [URLQueryItem(name: "storefront", value: storefront)] }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let fresh = try? JSONDecoder().decode(Catalog.self, from: data) {
            catalog = fresh
            UserDefaults.standard.set(data, forKey: Self.cacheKey(storefront))
        }
        adoptDefaultIfNeeded()
    }

    /// Without the server's answer: the old OpenAI list, except where OpenAI
    /// is known not to serve.
    private static func fallback(for storefront: String?) -> Catalog {
        switch storefront {
        case "HKG", "MAC": .mistralOnly
        case "CHN": Catalog(defaultModel: nil, images: false, models: [])
        default: .openAI
        }
    }

    /// The model setting lives in "openai_model" (its pre-region name).
    static let modelKey = "openai_model"

    private func adoptDefaultIfNeeded() {
        let chosen = UserDefaults.standard.string(forKey: Self.modelKey) ?? "gpt-4.1"
        guard !catalog.models.contains(where: { $0.id == chosen }), let fallback = catalog.defaultModel else { return }
        UserDefaults.standard.set(fallback, forKey: Self.modelKey)
    }

    func name(of id: String) -> String {
        catalog.models.first { $0.id == id }?.name ?? id
    }

    /// One short line about a model, for the picker.
    func blurb(for model: Model) -> String {
        let key = "model.blurb.\(model.id)"
        let text = L(key)
        return text == key ? model.provider : text
    }
}
