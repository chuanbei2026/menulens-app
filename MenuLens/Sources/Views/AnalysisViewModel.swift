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

    /// Where each photographed page of the scan on screen stands, in photo
    /// order. Failed pages keep their slot (and their photo) so they can be
    /// retried; the saved scan leaves them out.
    @Published private(set) var pageStates: [PageState] = []
    /// Per page: OCR lines, and lines the model has translated so far.
    @Published private(set) var pageLineTotals: [Int: Int] = [:]
    @Published private(set) var pageLinesDone: [Int: Int] = [:]
    /// Why dish pictures stopped early (out of credits, region), if they did.
    @Published private(set) var imagesStopReason: String?
    /// The last scan (or its dish pictures) ran out of credits: the error
    /// and notice offer the shop.
    @Published private(set) var outOfCredits = false

    /// Pages not translated yet (queued or in flight) / that failed.
    /// Pending and failed pages hold an empty placeholder document.
    var pendingPages: Set<Int> { Set(pageStates.indices.filter { pageStates[$0].isWaiting }) }
    var failedPages: Set<Int> {
        Set(pageStates.indices.filter { if case .failed = pageStates[$0] { true } else { false } })
    }
    /// True while any page of the scan on screen is still coming in — also
    /// while a failed page is being retried. The PDF (and so the share
    /// button) waits for this: it is rendered complete.
    var isReceivingPages: Bool { !pendingPages.isEmpty }
    /// A failed page of the scan on screen can be asked again.
    var canRetryPages: Bool { current != nil && current?.id == displayedRun }

    /// The fresh scan on screen (nil for one opened from History): what a
    /// single-page retry needs, during the run and after it.
    private var current: ScanRun?
    /// The "N pages failed" line of `notice`, so a successful retry can take
    /// it back out.
    private var partialPagesNotice: String?

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
    /// that page lands. Once every page is in (or failed), the scan is saved
    /// to history without the failed pages and the PDF is rendered — the
    /// same scan, history entry and PDF as if it had been shown all at once.
    /// A failed page can be retried on its own (`retryPage`), during the run
    /// or after it; a late success is saved into the same history entry.
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
            var rectified = original
            #if DEBUG
            // Demo pages are bundled, already-flat sample photos whose
            // geometry the sample answers were made against.
            let flat = Self.debugAnswers != nil
            #else
            let flat = false
            #endif
            if !flat {
                rectified = await Task.detached(priority: .userInitiated) {
                    DocumentRectifier.rectify(original)
                }.value
            }
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
        // The saved model may not be offered in this App Store region (any
        // more); the region's default stands in, as the picker would show.
        let region = RegionStore.shared
        await region.ready()
        if !region.catalog.models.contains(where: { $0.id == model }), let fallback = region.catalog.defaultModel {
            model = fallback
        }
        let client = OpenAIClient(
            sessionToken: account.sessionToken,
            model: model,
            targetLanguage: target.promptName
        )

        let run = ScanRun(client: client, target: target, images: images, jpegs: jpegs)
        imageQueue?.cancel()
        current?.cancelLateQueues()
        current = run
        displayedRun = run.id
        notice = nil
        partialPagesNotice = nil
        outOfCredits = false
        imagesStopReason = nil
        pdfData = nil
        generatedImages = [:]
        cart = [:]
        // Dish keys carry the photo's index. Saved scans leave failed pages
        // out and later pages move up, so pictures on disk are filed through
        // `run.keys`; the screen keeps photo order throughout.
        let queue = makeImageQueue(scanID: run.scanID, run: run.id, keys: run.keys)
        imageQueue = queue
        run.queue = queue
        if queue == nil { pipeline?.imagesTotal = 0 }
        pageLineTotals = [:]
        pageLinesDone = [:]
        publish(run)

        // Pages are independent: one failure must not throw away the pages
        // that came back fine (a 3-page scan losing everything to a single
        // timeout is the worst possible outcome for the user). Results come
        // back through one stream, which a retry of a failed page joins as
        // long as the run is still collecting.
        let (results, continuation) = AsyncStream.makeStream(of: (Int, Result<MenuDocument, Error>).self)
        run.continuation = continuation
        for index in images.indices { startPage(index, of: run) }
        var lastError: Error?
        for await (index, result) in results {
            if case let .failure(error) = result { lastError = error }
            receive(result, page: index, of: run)
            if !run.states.contains(where: \.isWaiting) { break }
        }
        run.continuation = nil
        continuation.finish()

        // Every page was charged (or refused); show the new balance.
        Task { await account.refreshCredits() }
        // 403 region: the catalog changed under us (or the storefront did).
        // Reload it — that moves the model to the region's default — and
        // the error says to scan again.
        if case .region = lastError as? Backend.BackendError {
            Task { await RegionStore.shared.refresh() }
        }

        guard run.documents.contains(where: { $0 != nil }) else {
            queue?.cancel()
            guard displayedRun == run.id else { return }
            current = nil
            pipeline = nil
            pageStates = []
            phase = .failed(lastError?.localizedDescription ?? L("error.recognizeFailed"))
            return
        }

        let saved = commit(run)
        if displayedRun == run.id {
            let failed = run.states.filter { if case .failed = $0 { true } else { false } }.count
            if failed > 0 {
                setPartialPagesNotice(L("notice.partialPages", failed, saved.pages.count))
            } else {
                // Nothing left out: the screen shows exactly the saved scan.
                scan = saved
            }
        }
        // No more dishes: leftovers that were waiting for a collage go out.
        queue?.finish()
        if displayedRun == run.id {
            await renderPDFAsync()
        }
    }

    /// Ask for one failed page again — only that page is sent, and charged.
    /// During the run the answer joins the run; after it, a success is saved
    /// into the same history entry and the PDF is rendered again.
    func retryPage(_ index: Int) {
        guard let run = current, displayedRun == run.id, aiConsentGranted,
              run.states.indices.contains(index), case .failed = run.states[index]
        else { return }
        notice = nil
        partialPagesNotice = nil
        startPage(index, of: run)
    }

    /// OCR and translate one page of `run`, then hand the result back.
    private func startPage(_ index: Int, of run: ScanRun) {
        run.states[index] = .queued
        publish(run)
        let image = run.images[index]
        let jpeg = run.jpegs[index]
        let client = run.client
        Task { [weak self] in
            // v2: OCR first — the line inventory IS the geometry; the model
            // only classifies and translates by index.
            let ocrLines = await Task.detached(priority: .userInitiated) {
                OCRService.recognizeLines(in: image)
            }.value
            guard let self else { return }
            run.lineTotals[index] = ocrLines.count
            run.linesDone[index] = 0
            #if DEBUG
            if let seconds = Self.debugPageDelay[index] {
                try? await Task.sleep(for: .seconds(seconds))
            }
            #endif
            run.states[index] = .translating(since: Date())
            self.publish(run)
            let onProgress: @Sendable (Int) -> Void = { done in
                Task { @MainActor [weak self] in
                    run.linesDone[index] = done
                    self?.publish(run)
                }
            }
            let result: Result<MenuDocument, Error>
            do {
                #if DEBUG
                if let answer = try await Self.debugAnswer(page: index, lines: ocrLines.count, onProgress: onProgress) {
                    result = .success(answer)
                } else {
                    result = .success(try await client.analyzeMenu(
                        jpegData: jpeg, ocrLines: ocrLines, onProgress: onProgress))
                }
                #else
                result = .success(try await client.analyzeMenu(
                    jpegData: jpeg, ocrLines: ocrLines, onProgress: onProgress))
                #endif
            } catch {
                result = .failure(error)
            }
            if let continuation = run.continuation {
                continuation.yield((index, result))
            } else {
                await self.receiveLate(result, page: index, of: run)
            }
        }
    }

    /// One page's answer: into the run, and onto the screen while it shows.
    private func receive(_ result: Result<MenuDocument, Error>, page index: Int, of run: ScanRun) {
        let displayed = displayedRun == run.id
        switch result {
        case let .success(document):
            run.documents[index] = document
            run.states[index] = .done(dishes: document.allItems.count)
            run.linesDone[index] = run.lineTotals[index]
            let dishes = Self.dishesNeedingImages(document, page: index)
            if run.continuation != nil {
                run.queue?.add(dishes)
                if displayed, run.queue != nil {
                    pipeline?.imagesTotal = (pipeline?.imagesTotal ?? 0) + dishes.count
                }
            } else if displayed, !dishes.isEmpty,
                      let queue = makeImageQueue(scanID: run.scanID, run: run.id, keys: run.keys) {
                // A page retried after the run: its own small picture queue.
                run.lateQueues.append(queue)
                pipeline?.imagesTotal = (pipeline?.imagesTotal ?? 0) + dishes.count
                queue.add(dishes)
                queue.finish()
            }
            if displayed { pipeline?.pagesDone += 1 }
        case let .failure(error):
            run.states[index] = .failed(error.localizedDescription)
            if case .outOfCredits = error as? Backend.BackendError, displayed {
                outOfCredits = true
            }
        }
        publish(run)
        guard displayed, run.documents.contains(where: { $0 != nil }) else { return }
        // Show what is in so far; pending and failed pages keep their photo.
        scan = run.screenScan
        scanImages = run.images
        if phase != .done {
            pipeline?.layoutState = .done
            phase = .done
        }
    }

    /// A retried page answering after the run ended: saved into the same
    /// history entry, with the PDF rendered again.
    private func receiveLate(_ result: Result<MenuDocument, Error>, page index: Int, of run: ScanRun) async {
        receive(result, page: index, of: run)
        Task { await AccountStore.shared.refreshCredits() }
        guard case .success = result else {
            if displayedRun == run.id, case let .failed(message) = run.states[index] {
                notice = [notice, message].compactMap { $0 }.joined(separator: "\n")
            }
            return
        }
        let saved = commit(run)
        guard displayedRun == run.id else { return }
        if !run.states.contains(where: { if case .failed = $0 { true } else { false } }) {
            scan = saved
        }
        if !isReceivingPages { await renderPDFAsync() }
    }

    /// Save the run's pages that came back to history (the same entry every
    /// time), filing its dish pictures under the saved page positions.
    @discardableResult
    private func commit(_ run: ScanRun) -> MenuScan {
        let map = PageCompaction.map(present: run.documents.map { $0 != nil })
        let old = run.keys.map
        let moves = old == nil ? map.contains { $0.key != $0.value } : old != map
        if moves {
            history.rekeyGeneratedImages(scanID: run.scanID) { PageCompaction.rekey($0, from: old, to: map) }
        }
        run.keys.map = map
        let saved = run.savedScan
        history.save(scan: saved, images: run.savedImages)
        return saved
    }

    /// Copy the run's page states to the screen, if it is the one shown.
    private func publish(_ run: ScanRun) {
        guard displayedRun == run.id else { return }
        pageStates = run.states
        pageLineTotals = run.lineTotals
        pageLinesDone = run.linesDone
        pipeline?.linesTotal = run.lineTotals.values.reduce(0, +)
        pipeline?.linesDone = run.linesDone.values.reduce(0, +)
    }

    private func setPartialPagesNotice(_ line: String) {
        partialPagesNotice = line
        notice = [notice, line].compactMap { $0 }.joined(separator: "\n")
    }

    /// Open a saved scan from the history list.
    func open(_ saved: MenuScan) {
        imageQueue?.cancel()
        current?.cancelLateQueues()
        current = nil
        let run = UUID()
        displayedRun = run
        pageStates = saved.pages.map { .done(dishes: $0.allItems.count) }
        pageLineTotals = [:]
        pageLinesDone = [:]
        imagesStopReason = nil
        outOfCredits = false
        notice = nil
        partialPagesNotice = nil
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
        current?.cancelLateQueues()
        current = nil
        displayedRun = nil
        pageStates = []
        pageLineTotals = [:]
        pageLinesDone = [:]
        imagesStopReason = nil
        outOfCredits = false
        notice = nil
        partialPagesNotice = nil
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
    /// It is the SAVED scan's PDF: a failed page left on screen for a retry
    /// is not in it, exactly like the history entry.
    func renderPDFAsync() async {
        guard let scan else { return }
        var renderer = MenuPDFRenderer(scan: scan, images: scanImages, generatedImages: generatedImages)
        if let run = current, run.id == displayedRun, run.documents.contains(where: { $0 == nil }) {
            renderer = MenuPDFRenderer(
                scan: run.savedScan,
                images: run.savedImages,
                generatedImages: Dictionary(uniqueKeysWithValues: generatedImages.compactMap { key, image in
                    run.keys.finalKey(key).map { ($0, image) }
                })
            )
        }
        let data = await Task.detached(priority: .userInitiated) {
            renderer.renderPDF()
        }.value
        pdfData = data
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dumpPDF") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: docs.appendingPathComponent("result.pdf"))
        }
        #endif
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
        guard generateDishImages, RegionStore.shared.catalog.images,
              aiConsentGranted, AccountStore.shared.isSignedIn
        else { return nil }
        let queue = DishImageQueue(
            client: ImageGenClient(sessionToken: AccountStore.shared.sessionToken),
            gridMode: thumbnailGridMode
        )
        queue.onResult = { [weak self] queuedKey, image in
            guard let self else { return }
            // On disk under the saved page position; on screen (photo
            // order) under the key it was queued with.
            if let image, let key = keys.currentKey(queuedKey) {
                self.history.saveGeneratedImage(image, scanID: scanID, dishKey: key)
            }
            guard self.displayedRun == run else { return }
            if let image { self.generatedImages[queuedKey] = image }
            self.pipeline?.imagesDone += 1
        }
        queue.onDrained = { [weak self, weak queue] in
            Task { await AccountStore.shared.refreshCredits() }
            guard let self, self.displayedRun == run else { return }
            if let reason = queue?.stopReason {
                self.imagesStopReason = reason.localizedDescription
                if case .outOfCredits = reason { self.outOfCredits = true }
                if case .region = reason { Task { await RegionStore.shared.refresh() } }
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

    /// Shows the open scan as if its last page were still being translated:
    /// the half-arrived result of a multi-page scan, without a request
    /// (`-demoReceiving`, for screenshots; the response cache doesn't
    /// survive the reinstall the screenshot script does per language).
    func debugShowReceiving() {
        guard let scan, scan.pages.count > 1 else { return }
        let pending = scan.pages.count - 1
        self.scan = scan.withPages(scan.pages.enumerated().map { $0.offset == pending ? .placeholder : $0.element })
        pageStates[pending] = .translating(since: Date())
        pdfData = nil
    }

    /// `-demoScan <restaurant>[,<restaurant>…]`: run the real multi-page
    /// pipeline (page states, progressive canvas/list, history, PDF) on the
    /// bundled samples' photos, answered from the samples instead of the
    /// network — free and repeatable. Each page "streams" its lines over a
    /// few seconds; `-failPage <i>` makes page i fail once (a retry then
    /// succeeds).
    static var debugAnswers: [MenuDocument]?
    static var debugFailOnce: Set<Int> = []

    private struct DebugFailure: LocalizedError {
        var errorDescription: String? { L("error.http", 503, "simulated failure (-failPage)") }
    }

    nonisolated static func debugAnswer(
        page: Int, lines: Int, onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> MenuDocument? {
        guard let answers = await MainActor.run(body: { debugAnswers }), page < answers.count else { return nil }
        let fails = await MainActor.run { debugFailOnce.remove(page) != nil }
        let steps = 12
        for step in 1 ... steps {
            try await Task.sleep(for: .milliseconds(450 + 120 * page))
            if fails, step == steps / 2 { throw DebugFailure() }
            onProgress(lines * step / steps)
        }
        return answers[page]
    }

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

/// Where one photographed page stands.
enum PageState: Equatable {
    /// Waiting to be read and sent.
    case queued
    /// Its request is out (the line counter moves if the model streams).
    case translating(since: Date)
    case done(dishes: Int)
    case failed(String)

    var isWaiting: Bool {
        switch self {
        case .queued, .translating: true
        case .done, .failed: false
        }
    }
}

/// One fresh scan: what it was asked with and what came back, per photo.
/// Kept while it is on screen so a failed page can be asked again.
@MainActor
final class ScanRun {
    let id = UUID()
    let scanID = UUID()
    let createdAt = Date()
    let client: OpenAIClient
    let target: AppLanguage
    let images: [UIImage]
    let jpegs: [Data]
    var documents: [MenuDocument?]
    var states: [PageState]
    var lineTotals: [Int: Int] = [:]
    var linesDone: [Int: Int] = [:]
    /// Photo index → saved index, once saved (see `PageCompaction`).
    let keys = PageKeyMap()
    var queue: DishImageQueue?
    /// Picture queues of pages retried after the run.
    var lateQueues: [DishImageQueue] = []
    /// Set while the run is still collecting page results.
    var continuation: AsyncStream<(Int, Result<MenuDocument, Error>)>.Continuation?

    init(client: OpenAIClient, target: AppLanguage, images: [UIImage], jpegs: [Data]) {
        self.client = client
        self.target = target
        self.images = images
        self.jpegs = jpegs
        documents = Array(repeating: nil, count: images.count)
        states = Array(repeating: .queued, count: images.count)
    }

    /// Photo order, pages not (yet) in as placeholders — what the screen shows.
    var screenScan: MenuScan {
        MenuScan.combining(pages: documents.compactMap { $0 }, targetLanguage: target, id: scanID, createdAt: createdAt)
            .withPages(documents.map { $0 ?? .placeholder })
    }

    /// Only the pages that came back — what history and the PDF hold.
    var savedScan: MenuScan {
        MenuScan.combining(pages: documents.compactMap { $0 }, targetLanguage: target, id: scanID, createdAt: createdAt)
    }

    var savedImages: [UIImage] {
        zip(documents, images).compactMap { $0.0 == nil ? nil : $0.1 }
    }

    func cancelLateQueues() {
        lateQueues.forEach { $0.cancel() }
        lateQueues = []
    }
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
