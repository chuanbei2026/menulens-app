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
    /// The rendered PDF for the current scan (re-rendered when thumbnails land).
    @Published var pdfData: Data?
    /// Order cart for the current scan: dish key -> (member id -> quantity),
    /// so every +1 is attributed to the person who ordered it.
    @Published var cart: [String: [UUID: Int]] = [:]
    /// The member new +1s are attributed to (defaults to the first profile).
    @Published var activeMemberID: UUID = PartyStore.shared.members[0].id

    let party = PartyStore.shared

    /// Model id is a plain preference; the API key lives in the Keychain.
    @AppStorage("openai_model") var model = "gpt-5-mini"
    /// TargetLanguage raw value the menu gets translated into.
    @AppStorage("target_language") var targetLanguageCode = TargetLanguage.simplifiedChinese.rawValue
    /// Generate AI thumbnails for dishes that have no printed photo.
    @AppStorage("generate_dish_images") var generateDishImages = true

    /// Generate thumbnails 4-at-a-time in one 2x2 collage image, then slice —
    /// ~4x cheaper per dish than one request per dish.
    @AppStorage("thumbnail_grid_mode") var thumbnailGridMode = true

    let history: HistoryStore
    private var imageGenTask: Task<Void, Never>?

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

    /// Analyze all picked pages concurrently (one API call per page),
    /// combine into a MenuScan, auto-save to history, then run layout
    /// rendering and thumbnail generation IN PARALLEL. The result view
    /// opens as soon as the layout PDF is ready; thumbnails keep filling
    /// in behind the banner and the PDF refreshes when they finish.
    func analyze() async {
        let originals = pickedImages
        guard !originals.isEmpty else { return }
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
            phase = .failed("无法编码所选图片。")
            return
        }
        let target = TargetLanguage.from(code: targetLanguageCode)
        let client = OpenAIClient(
            apiKey: KeychainStore.loadAPIKey(),
            model: model,
            targetLanguage: target.promptName
        )
        var pages = [MenuDocument?](repeating: nil, count: jpegs.count)
        var lastError: Error?
        // Pages are independent: one failure must not throw away the pages
        // that came back fine (a 3-page scan losing everything to a single
        // timeout is the worst possible outcome for the user).
        await withTaskGroup(of: (Int, Result<MenuDocument, Error>).self) { group in
            for (index, jpeg) in jpegs.enumerated() {
                let pageImage = images[index]
                group.addTask {
                    // v2: OCR first — the line inventory IS the geometry;
                    // the model only classifies and translates by index.
                    let ocrLines = OCRService.recognizeLines(in: pageImage)
                    do {
                        return (index, .success(try await client.analyzeMenu(jpegData: jpeg, ocrLines: ocrLines)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                switch result {
                case let .success(document):
                    pages[index] = document
                    pipeline?.pagesDone += 1
                case let .failure(error):
                    lastError = error
                }
            }
        }

        let succeeded = pages.compactMap { $0 }
        guard !succeeded.isEmpty else {
            pipeline = nil
            phase = .failed(lastError?.localizedDescription ?? "识别失败，请重试。")
            return
        }
        do {
            let newScan = MenuScan.combining(pages: succeeded, targetLanguage: target)
            history.save(scan: newScan, images: images)
            scan = newScan
            scanImages = images
            generatedImages = [:]
            cart = [:]

            // Layout and thumbnails run concurrently from here.
            pipeline?.layoutState = .running
            startImageGenerationIfNeeded()
            await renderPDFAsync()
            pipeline?.layoutState = .done
            phase = .done
        } catch {
            pipeline = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Open a saved scan from the history list.
    func open(_ saved: MenuScan) {
        imageGenTask?.cancel()
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
        startImageGenerationIfNeeded()
    }

    func reset() {
        imageGenTask?.cancel()
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

    /// "我 · 小明×2"-style label per dish, for the canvas annotations.
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
    /// Requests are split one-per-dish and run through a small concurrency
    /// window; each result is persisted immediately, and the PDF is
    /// re-rendered once at the end.
    private func startImageGenerationIfNeeded() {
        guard generateDishImages, let scan, !KeychainStore.loadAPIKey().isEmpty else {
            pipeline?.imagesTotal = 0
            return
        }

        var dishes: [(key: String, spec: ImageGenClient.DishSpec)] = []
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                for (i, item) in section.items.enumerated() {
                    let key = MenuScan.dishKey(page: p, section: s, item: i)
                    if item.photoBBox == nil, generatedImages[key] == nil {
                        dishes.append((key, ImageGenClient.DishSpec(
                            name: item.originalName,
                            chineseName: item.chineseName,
                            description: item.originalDescription
                        )))
                    }
                }
            }
        }
        pipeline?.imagesDone = 0
        pipeline?.imagesTotal = dishes.count
        guard !dishes.isEmpty else { return }

        // One request per full group of 4 (a 2x2 collage sliced into cells,
        // ~4x cheaper per dish); leftovers fall back to single requests.
        enum GenJob {
            case grid([(key: String, spec: ImageGenClient.DishSpec)])
            case single(key: String, spec: ImageGenClient.DishSpec)
        }
        var jobs: [GenJob] = []
        if thumbnailGridMode {
            var rest = dishes[...]
            while rest.count >= 4 {
                jobs.append(.grid(Array(rest.prefix(4))))
                rest = rest.dropFirst(4)
            }
            jobs.append(contentsOf: rest.map { .single(key: $0.key, spec: $0.spec) })
        } else {
            jobs = dishes.map { .single(key: $0.key, spec: $0.spec) }
        }

        let client = ImageGenClient(apiKey: KeychainStore.loadAPIKey())
        let scanID = scan.id

        imageGenTask = Task { [weak self] in
            await withTaskGroup(of: [(String, UIImage?)].self) { group in
                var pending = jobs[...]
                // 2-wide: stays under gpt-image-1's images-per-minute cap.
                let window = 2
                func addNext(_ group: inout TaskGroup<[(String, UIImage?)]>) {
                    guard let job = pending.popFirst() else { return }
                    group.addTask {
                        switch job {
                        case let .single(key, spec):
                            return [(key, await client.generateDishThumbnail(spec))]
                        case let .grid(cells):
                            let images = await client.generateDishGrid(cells.map(\.spec))
                            return cells.enumerated().map { index, cell in
                                (cell.key, images?[index])
                            }
                        }
                    }
                }
                for _ in 0 ..< window { addNext(&group) }

                for await results in group {
                    guard let self, !Task.isCancelled else { return }
                    for (key, image) in results {
                        if let image {
                            self.generatedImages[key] = image
                            self.history.saveGeneratedImage(image, scanID: scanID, dishKey: key)
                        }
                        self.pipeline?.imagesDone += 1
                    }
                    addNext(&group)
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.renderPDFAsync()
        }
    }

    #if DEBUG
    /// Load the synthetic demo menu — verifies bbox cropping and PDF export
    /// in the simulator without an API key.
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
