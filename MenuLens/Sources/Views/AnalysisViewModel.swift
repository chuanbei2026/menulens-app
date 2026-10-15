import SwiftUI

/// Live progress of the three pipeline stages, driven by AnalysisViewModel
/// and rendered by AnalysisProgressView / the ResultView banner.
struct PipelineProgress: Equatable {
    enum LayoutState: Equatable {
        case waiting
        case running
        case done
    }

    var rectifyDone = 0
    var rectifyTotal = 0
    var pagesDone = 0
    var pagesTotal = 0
    /// Text lines the model has translated, across all pages in flight.
    var linesDone = 0
    var linesTotal = 0
    /// When the translation request went out — the progress row counts the
    /// seconds so a thinking model never looks frozen.
    var translateStartedAt: Date?
    var layoutState: LayoutState = .waiting
    var imagesDone = 0
    /// nil = count not known yet; 0 = no thumbnails needed (or disabled).
    var imagesTotal: Int?

    var imagesFinished: Bool {
        if let total = imagesTotal { return imagesDone >= total }
        return false
    }
}

/// Collects per-page translated-line counts from concurrent page tasks.
actor LineProgress {
    private var byPage: [Int: Int] = [:]

    func record(page: Int, done: Int) -> Int {
        byPage[page] = done
        return byPage.values.reduce(0, +)
    }
}

@MainActor
final class AnalysisViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case analyzing
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Pages queued for the next analysis, in menu-page order — exactly the
    /// photos the user picked (correction happens in `analyze()`).
    @Published var pickedImages: [UIImage] = []
    /// The scan currently shown in the result view (fresh or from history).
    @Published var scan: MenuScan?
    @Published var scanImages: [UIImage] = []
    /// AI-generated dish thumbnails, keyed by MenuScan.dishKey.
    @Published var generatedImages: [String: UIImage] = [:]
    /// Stage-by-stage progress; nil when nothing is in flight.
    @Published var pipeline: PipelineProgress?
    /// Non-fatal outcome worth telling the user about (e.g. a page failed).
    @Published var notice: String?
    /// The rendered PDF for the current scan (re-rendered when thumbnails land).
    @Published var pdfData: Data?
    /// Order cart for the current scan: dish key -> (member id -> quantity),
    /// so every +1 is attributed to the person who ordered it.
    @Published var cart: [String: [UUID: Int]] = [:]
    /// The member new +1s are attributed to (defaults to the first profile).
    @Published var activeMemberID: UUID = PartyStore.shared.members[0].id

    let party = PartyStore.shared

    /// Model id is a plain preference; the server honours the four in Settings.
    @AppStorage("openai_model") var model = "gpt-4.1"
    /// The app language, which is also what the menu gets translated into.
    /// Same defaults key `Loc` reads — see Localization.swift.
    @AppStorage("target_language") var targetLanguageCode = AppLanguage.deviceDefault.rawValue
    /// Generate AI thumbnails for dishes that have no printed photo.
    @AppStorage("generate_dish_images") var generateDishImages = true
    /// Permission to send anything to our server / OpenAI at all (guideline
    /// 5.1.2(i)). Checked here, not only at the button, because opening a
    /// saved scan can also start thumbnail generation — see AIConsentView.
    @AppStorage(AIConsentView.grantedKey) var aiConsentGranted = false

    /// Generate thumbnails 4-at-a-time in one 2x2 collage image, then slice —
    /// ~4x cheaper per dish than one request per dish.
    @AppStorage("thumbnail_grid_mode") var thumbnailGridMode = true

    let history: HistoryStore
    /// Thumbnails for the scan on screen (nil when generation is off).
    private var imageQueue: DishImageQueue?
    /// The analysis run (or opened scan) whose result is on screen. A run
    /// the user has left — home, or another scan from History — still
    /// finishes and saves to history, but stops touching the screen.
    private var displayedRun: UUID?

    /// While a multi-page scan is still coming in: indices into
    /// `scan.pages` of pages not translated yet / that failed. Those pages
    /// hold an empty placeholder document until the run finishes.
    @Published private(set) var pendingPages: Set<Int> = []
    @Published private(set) var failedPages: Set<Int> = []
    /// The last scan (or its dish pictures) ran out of credits: the error
    /// and notice offer the shop.
    @Published private(set) var outOfCredits = false
    /// True until every page of the scan on screen is in. The PDF (and so
    /// the share button) waits for this: it is rendered once, complete.
    var isReceivingPages: Bool { !pendingPages.isEmpty }

    init(history: HistoryStore = .shared) {
        self.history = history
    }

    /// Queue freshly picked photos. Deliberately instant: what the user
    /// picked is what they see. Perspective correction is real work, so it
    /// runs as the first stage of `analyze()` where the progress screen can
    /// account for it.
    func appendPhotos(_ photos: [UIImage]) async {
        pickedImages.append(contentsOf: photos)
    }

    /// Analyze all picked pages concurrently (one API call per page). The
    /// result view opens as soon as the FIRST page is back; the others fill
    /// in as they finish, and each page's dish thumbnails start as soon as
    /// that page lands. Once every page is in (or failed), failed pages are
    /// dropped, the scan is saved to history and the PDF is rendered — the
    /// same scan, history entry and PDF as if it had been shown all at once.
    func analyze() async {
        let originals = pickedImages
        guard !originals.isEmpty else { return }
        // Backstop: the button already asks first, but nothing may reach
        // OpenAI without permission, whatever calls this.
        guard aiConsentGranted else { return }
        phase = .analyzing
        pipeline = PipelineProgress(rectifyTotal: originals.count, pagesTotal: originals.count)

        // Stage 0 — straighten and sharpen each page so every downstream
        // step (OCR geometry, canvas, crops, history) works on a clean sheet.
        var images: [UIImage] = []
        for original in originals {
            let rectified = await Task.detached(priority: .userInitiated) {
                DocumentRectifier.rectify(original)
            }.value
            images.append(rectified)
            pipeline?.rectifyDone += 1
        }

        let jpegs = images.compactMap { $0.jpegDataForUpload() }
        guard jpegs.count == images.count else {
            pipeline = nil
            phase = .failed(L("error.encodeImages"))
            return
        }
        pipeline?.translateStartedAt = Date()
        let target = AppLanguage.from(code: targetLanguageCode)
        let account = AccountStore.shared
        let client = OpenAIClient(
            sessionToken: account.sessionToken,
            model: model,
            targetLanguage: target.promptName
        )

        let run = UUID()
        imageQueue?.cancel()
        displayedRun = run
        let scanID = UUID()
        let createdAt = Date()
        notice = nil
        outOfCredits = false
        pdfData = nil
        generatedImages = [:]
        cart = [:]
        // Dish keys carry the page index. Until the run ends that is the
        // photo's index; failed pages are then dropped and later pages move
        // up, so thumbnails and cart entries are re-keyed through this.
        let keys = PageKeyMap()
        let queue = makeImageQueue(scanID: scanID, run: run, keys: keys)
        imageQueue = queue
        if queue == nil { pipeline?.imagesTotal = 0 }

        var pages = [MenuDocument?](repeating: nil, count: jpegs.count)
        var pending = Set(pages.indices)
        var failed: Set<Int> = []
        var lastError: Error?
        // Pages are independent: one failure must not throw away the pages
        // that came back fine (a 3-page scan losing everything to a single
        // timeout is the worst possible outcome for the user).
        // Per-page line counters, summed for the progress bar.
        let linesDoneByPage = LineProgress()
        await withTaskGroup(of: (Int, Result<MenuDocument, Error>).self) { group in
            for (index, jpeg) in jpegs.enumerated() {
                let pageImage = images[index]
                group.addTask { [weak self] in
                    // v2: OCR first — the line inventory IS the geometry;
                    // the model only classifies and translates by index.
                    let ocrLines = OCRService.recognizeLines(in: pageImage)
                    await MainActor.run { self?.pipeline?.linesTotal += ocrLines.count }
                    #if DEBUG
                    if let seconds = await Self.debugPageDelay[index] {
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                    #endif
                    do {
                        let document = try await client.analyzeMenu(
                            jpegData: jpeg, ocrLines: ocrLines,
                            onProgress: { done in
                                Task { @MainActor [weak self] in
                                    let total = await linesDoneByPage.record(page: index, done: done)
                                    self?.pipeline?.linesDone = total
                                }
                            }
                        )
                        return (index, .success(document))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                pending.remove(index)
                switch result {
                case let .success(document):
                    pages[index] = document
                    let dishes = Self.dishesNeedingImages(document, page: index)
                    queue?.add(dishes)
                    guard displayedRun == run else { continue }
                    pipeline?.pagesDone += 1
                    if queue != nil { pipeline?.imagesTotal = (pipeline?.imagesTotal ?? 0) + dishes.count }
                case let .failure(error):
                    lastError = error
                    failed.insert(index)
                    if case .outOfCredits = error as? Backend.BackendError, displayedRun == run {
                        outOfCredits = true
                    }
                }
                guard displayedRun == run, pages.contains(where: { $0 != nil }) else { continue }
                // Show what is in so far; pending pages keep their photo.
                let landed = pages.compactMap { $0 }
                scan = MenuScan.combining(pages: landed, targetLanguage: target, id: scanID, createdAt: createdAt)
                    .withPages(pages.map { $0 ?? .placeholder })
                scanImages = images
                pendingPages = pending
                failedPages = failed
                if phase != .done {
                    pipeline?.layoutState = .done
                    phase = .done
                }
            }
        }

        // Every page was charged (or refused); show the new balance.
        Task { await account.refreshCredits() }

        // Keep documents and photos PAIRED. Dropping failed pages from the
        // documents while keeping every image would shift the two lists apart
        // and paint one page's translations onto another page's photo.
        var results: [(document: MenuDocument, image: UIImage)] = []
        var finalIndex: [Int: Int] = [:]
        for (index, page) in pages.enumerated() {
            if let page {
                finalIndex[index] = results.count
                results.append((page, images[index]))
            }
        }
        guard !results.isEmpty else {
            queue?.cancel()
            guard displayedRun == run else { return }
            pipeline = nil
            pendingPages = []
            failedPages = []
            phase = .failed(lastError?.localizedDescription ?? L("error.recognizeFailed"))
            return
        }

        let finalScan = MenuScan.combining(
            pages: results.map(\.document), targetLanguage: target, id: scanID, createdAt: createdAt
        )
        keys.map = finalIndex
        if !failed.isEmpty {
            history.rekeyGeneratedImages(scanID: scanID) { keys.finalKey($0) }
        }
        history.save(scan: finalScan, images: results.map(\.image))

        if displayedRun == run {
            if !failed.isEmpty {
                notice = [notice, L("notice.partialPages", failed.count, results.count)]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                generatedImages = Dictionary(uniqueKeysWithValues: generatedImages.compactMap { key, image in
                    keys.finalKey(key).map { ($0, image) }
                })
                cart = Dictionary(uniqueKeysWithValues: cart.compactMap { key, perMember in
                    keys.finalKey(key).map { ($0, perMember) }
                })
            }
            scan = finalScan
            scanImages = results.map(\.image)
            pendingPages = []
            failedPages = []
        }
        // No more dishes: leftovers that were waiting for a collage go out.
        queue?.finish()
        if displayedRun == run {
            await renderPDFAsync()
        }
    }

    /// Open a saved scan from the history list.
    func open(_ saved: MenuScan) {
        imageQueue?.cancel()
        let run = UUID()
        displayedRun = run
        pendingPages = []
        failedPages = []
        outOfCredits = false
        notice = nil
        scan = saved
        scanImages = history.loadImages(for: saved)
        generatedImages = history.loadGeneratedImages(for: saved)
        cart = [:]
        pipeline = PipelineProgress(
            rectifyDone: saved.pages.count,
            rectifyTotal: saved.pages.count,
            pagesDone: saved.pages.count,
            pagesTotal: saved.pages.count,
            layoutState: .done,
            imagesDone: 0,
            imagesTotal: nil
        )
        phase = .done
        Task {
            await renderPDFAsync()
        }
        let queue = makeImageQueue(scanID: saved.id, run: run, keys: PageKeyMap())
        imageQueue = queue
        var dishes: [DishImageQueue.Dish] = []
        for (p, page) in saved.pages.enumerated() {
            dishes += Self.dishesNeedingImages(page, page: p).filter { generatedImages[$0.key] == nil }
        }
        pipeline?.imagesTotal = queue == nil ? 0 : dishes.count
        queue?.add(dishes)
        queue?.finish()
    }

    func reset() {
        imageQueue?.cancel()
        imageQueue = nil
        displayedRun = nil
        pendingPages = []
        failedPages = []
        outOfCredits = false
        notice = nil
        phase = .idle
        pickedImages = []
        scan = nil
        scanImages = []
        generatedImages = [:]
        pipeline = nil
        pdfData = nil
        cart = [:]
    }

    // MARK: - Cart

    /// Ensure the active member still exists (profiles can be deleted).
    private var validActiveMember: UUID {
        if party.members.contains(where: { $0.id == activeMemberID }) {
            return activeMemberID
        }
        activeMemberID = party.members[0].id
        return activeMemberID
    }

    func addToCart(_ dishKey: String, member: UUID? = nil) {
        let member = member ?? validActiveMember
        cart[dishKey, default: [:]][member, default: 0] += 1
    }

    /// Removes one unit — from the given (or active) member first, otherwise
    /// from whoever has some.
    func removeFromCart(_ dishKey: String, member: UUID? = nil) {
        guard var perMember = cart[dishKey] else { return }
        let preferred = member ?? validActiveMember
        let target: UUID? = (perMember[preferred] ?? 0) > 0
            ? preferred
            : perMember.first { $0.value > 0 }?.key
        guard let target else { return }
        perMember[target]! -= 1
        if perMember[target]! <= 0 { perMember.removeValue(forKey: target) }
        if perMember.isEmpty {
            cart.removeValue(forKey: dishKey)
        } else {
            cart[dishKey] = perMember
        }
    }

    func quantity(of dishKey: String) -> Int {
        cart[dishKey]?.values.reduce(0, +) ?? 0
    }

    var cartCount: Int { cart.values.reduce(0) { $0 + $1.values.reduce(0, +) } }

    /// Total quantity per dish, for the canvas highlight badges.
    var highlightTotals: [String: Int] {
        cart.mapValues { $0.values.reduce(0, +) }
    }

    /// "Me · Alex×2"-style label per dish, for the canvas annotations.
    var orderLabels: [String: String] {
        cart.mapValues { perMember in
            party.members.compactMap { member in
                guard let quantity = perMember[member.id], quantity > 0 else { return nil }
                return quantity > 1 ? "\(member.name)×\(quantity)" : member.name
            }
            .joined(separator: " · ")
        }
    }

    /// All carted dishes resolved against the current scan, in menu order.
    var cartEntries: [(key: String, item: MenuItemEntry, quantity: Int, perMember: [UUID: Int])] {
        guard let scan else { return [] }
        var result: [(String, MenuItemEntry, Int, [UUID: Int])] = []
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                for (i, item) in section.items.enumerated() {
                    let key = MenuScan.dishKey(page: p, section: s, item: i)
                    if let perMember = cart[key] {
                        let total = perMember.values.reduce(0, +)
                        if total > 0 { result.append((key, item, total, perMember)) }
                    }
                }
            }
        }
        return result
    }

    /// Cart entries of one member only.
    func cartEntries(for member: UUID) -> [(key: String, item: MenuItemEntry, quantity: Int)] {
        cartEntries.compactMap { entry in
            guard let quantity = entry.perMember[member], quantity > 0 else { return nil }
            return (entry.key, entry.item, quantity)
        }
    }

    /// Sum of parseable prices weighted by quantity, formatted with the
    /// first seen currency symbol. nil when nothing parseable is selected.
    var cartTotalText: String? {
        var total = 0.0
        var symbol = ""
        var parsedAny = false
        for entry in cartEntries {
            guard let price = entry.item.price else { continue }
            if let range = price.range(of: #"[0-9]+([.,][0-9]{1,2})?"#, options: .regularExpression),
               let value = Double(price[range].replacingOccurrences(of: ",", with: ".")) {
                total += value * Double(entry.quantity)
                parsedAny = true
                if symbol.isEmpty {
                    symbol = String(price.prefix(while: { !$0.isNumber && !$0.isWhitespace }))
                }
            }
        }
        guard parsedAny else { return nil }
        return "\(symbol)\(String(format: "%.2f", total))"
    }

    /// Render the PDF off the main thread so scrolling/progress stay smooth.
    func renderPDFAsync() async {
        guard let scan else { return }
        let renderer = MenuPDFRenderer(
            scan: scan,
            images: scanImages,
            generatedImages: generatedImages
        )
        let data = await Task.detached(priority: .userInitiated) {
            renderer.renderPDF()
        }.value
        pdfData = data
    }

    // MARK: - Concurrent dish-thumbnail generation

    /// Dishes that have no printed photo on the menu get an AI thumbnail.
    static func dishesNeedingImages(_ document: MenuDocument, page: Int) -> [DishImageQueue.Dish] {
        var dishes: [DishImageQueue.Dish] = []
        for (s, section) in document.sections.enumerated() {
            for (i, item) in section.items.enumerated() where item.photoBBox == nil {
                dishes.append((MenuScan.dishKey(page: page, section: s, item: i), ImageGenClient.DishSpec(
                    name: item.originalName,
                    chineseName: item.chineseName,
                    description: item.originalDescription
                )))
            }
        }
        return dishes
    }

    /// A thumbnail queue for one scan whose results are persisted as they
    /// arrive and shown while `run` is on screen; nil when generation is off.
    /// The PDF is re-rendered once, when the queue drains.
    private func makeImageQueue(scanID: UUID, run: UUID, keys: PageKeyMap) -> DishImageQueue? {
        guard generateDishImages, aiConsentGranted, AccountStore.shared.isSignedIn else { return nil }
        let queue = DishImageQueue(
            client: ImageGenClient(sessionToken: AccountStore.shared.sessionToken),
            gridMode: thumbnailGridMode
        )
        queue.onResult = { [weak self] queuedKey, image in
            guard let self, let key = keys.currentKey(queuedKey) else { return }
            if let image {
                self.history.saveGeneratedImage(image, scanID: scanID, dishKey: key)
            }
            guard self.displayedRun == run else { return }
            if let image { self.generatedImages[key] = image }
            self.pipeline?.imagesDone += 1
        }
        queue.onDrained = { [weak self, weak queue] in
            Task { await AccountStore.shared.refreshCredits() }
            guard let self, self.displayedRun == run else { return }
            if let reason = queue?.stopReason {
                if case .outOfCredits = reason { self.outOfCredits = true }
                // Close the progress out at what was actually made.
                if let done = self.pipeline?.imagesDone { self.pipeline?.imagesTotal = done }
                self.notice = [self.notice, L("notice.imagesStopped", reason.localizedDescription)]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            Task { await self.renderPDFAsync() }
        }
        return queue
    }

    #if DEBUG
    /// Holds a page back before its request (`-delayPage <index> <seconds>`),
    /// so the half-arrived result screen can be looked at even when the
    /// pages come from the response cache and would otherwise land at once.
    static var debugPageDelay: [Int: Double] = [:]

    /// Load the synthetic demo menu — verifies bbox cropping and PDF export
    /// in the simulator without signing in.
    func loadSample() {
        let image = SampleData.sampleImage()
        pickedImages = [image]
        scan = MenuScan.combining(pages: [SampleData.document])
        scanImages = [image]
        generatedImages = [:]
        pipeline = nil
        phase = .done
        Task { await renderPDFAsync() }
    }
    #endif
}

/// Original page index → index in the saved scan, filled in when a run
/// ends. Until then dish keys are used as they are.
@MainActor
final class PageKeyMap {
    var map: [Int: Int]?

    /// The key to file a thumbnail under right now.
    func currentKey(_ key: String) -> String? {
        map == nil ? key : finalKey(key)
    }

    /// "p2_s0_i3" with page 2 moved to its saved position; nil when that
    /// page was dropped.
    func finalKey(_ key: String) -> String? {
        guard let map else { return key }
        guard key.hasPrefix("p"), let separator = key.firstIndex(of: "_"),
              let page = Int(key[key.index(after: key.startIndex) ..< separator]),
              let moved = map[page]
        else { return nil }
        return "p\(moved)" + key[separator...]
    }
}
