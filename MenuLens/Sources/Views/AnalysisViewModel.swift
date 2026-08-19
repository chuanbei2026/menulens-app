import SwiftUI

/// Live progress of the three pipeline stages, driven by AnalysisViewModel
/// and rendered by AnalysisProgressView / the ResultView banner.
struct PipelineProgress: Equatable {
    enum LayoutState: Equatable {
        case waiting
        case running
        case done
    }

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
    /// Pages queued for the next analysis, in menu-page order.
    /// Already perspective-rectified — photos are corrected as they're picked.
    @Published var pickedImages: [UIImage] = []
    /// True while freshly picked photos are being rectified.
    @Published var isRectifying = false
    /// The scan currently shown in the result view (fresh or from history).
    @Published var scan: MenuScan?
    @Published var scanImages: [UIImage] = []
    /// AI-generated dish thumbnails, keyed by MenuScan.dishKey.
    @Published var generatedImages: [String: UIImage] = [:]
    /// Stage-by-stage progress; nil when nothing is in flight.
    @Published var pipeline: PipelineProgress?
    /// The rendered PDF for the current scan (re-rendered when thumbnails land).
    @Published var pdfData: Data?

    /// Model id is a plain preference; the API key lives in the Keychain.
    @AppStorage("openai_model") var model = "gpt-4.1"
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

    /// Rectify freshly picked photos (document detection + perspective
    /// correction, all on-device) and append them to the queue. The
    /// thumbnails the user sees are already the corrected pages.
    func appendPhotos(_ photos: [UIImage]) async {
        guard !photos.isEmpty else { return }
        isRectifying = true
        for photo in photos {
            let rectified = await Task.detached(priority: .userInitiated) {
                DocumentRectifier.rectify(photo)
            }.value
            pickedImages.append(rectified)
        }
        isRectifying = false
    }

    /// Analyze all picked pages concurrently (one API call per page),
    /// combine into a MenuScan, auto-save to history, then run layout
    /// rendering and thumbnail generation IN PARALLEL. The result view
    /// opens as soon as the layout PDF is ready; thumbnails keep filling
    /// in behind the banner and the PDF refreshes when they finish.
    func analyze() async {
        let images = pickedImages // already rectified at pick time
        guard !images.isEmpty else { return }
        phase = .analyzing
        pipeline = PipelineProgress(pagesTotal: images.count)

        let jpegs = images.compactMap { $0.jpegDataForUpload() }
        guard jpegs.count == images.count else {
            pipeline = nil
            phase = .failed("无法编码所选图片。")
            return
        }
        let client = OpenAIClient(apiKey: KeychainStore.loadAPIKey(), model: model)
        do {
            var pages = [MenuDocument?](repeating: nil, count: jpegs.count)
            try await withThrowingTaskGroup(of: (Int, MenuDocument).self) { group in
                for (index, jpeg) in jpegs.enumerated() {
                    let pageImage = images[index]
                    group.addTask {
                        let document = try await client.analyzeMenu(jpegData: jpeg)
                        // Snap bboxes onto OCR-detected text lines (no-op when
                        // OCR finds nothing, e.g. simulator without the model).
                        return (index, BBoxRefiner.refine(document, in: pageImage))
                    }
                }
                for try await (index, document) in group {
                    pages[index] = document
                    pipeline?.pagesDone += 1
                }
            }
            let newScan = MenuScan.combining(pages: pages.compactMap { $0 })
            history.save(scan: newScan, images: images)
            scan = newScan
            scanImages = images
            generatedImages = [:]

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
        pipeline = PipelineProgress(
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
        guard generateDishImages, let scan else {
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
                let window = 3
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
    /// in the simulator without an API key. `crowded` swaps in the
    /// overlapping-bbox fixture that exercises the smart card layout.
    func loadSample(crowded: Bool = false) {
        let image = SampleData.sampleImage()
        pickedImages = [image]
        scan = MenuScan.combining(pages: [crowded ? SampleData.crowdedDocument : SampleData.document])
        scanImages = [image]
        generatedImages = [:]
        pipeline = nil
        phase = .done
        Task { await renderPDFAsync() }
    }
    #endif
}
