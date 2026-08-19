import SwiftUI

@MainActor
final class AnalysisViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// `completed` of `total` pages have come back from the API.
        case analyzing(completed: Int, total: Int)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Pages queued for the next analysis, in menu-page order.
    @Published var pickedImages: [UIImage] = []
    /// The scan currently shown in the result view (fresh or from history).
    @Published var scan: MenuScan?
    @Published var scanImages: [UIImage] = []
    /// AI-generated dish thumbnails, keyed by MenuScan.dishKey.
    @Published var generatedImages: [String: UIImage] = [:]
    /// Non-nil while thumbnails are being generated.
    @Published var imageProgress: (done: Int, total: Int)?
    /// The rendered PDF for the current scan (re-rendered when thumbnails land).
    @Published var pdfData: Data?

    /// Model id is a plain preference; the API key lives in the Keychain.
    @AppStorage("openai_model") var model = "gpt-4.1"
    /// Generate AI thumbnails for dishes that have no printed photo.
    @AppStorage("generate_dish_images") var generateDishImages = true

    let history: HistoryStore
    private var imageGenTask: Task<Void, Never>?

    init(history: HistoryStore = .shared) {
        self.history = history
    }

    /// Analyze all picked pages concurrently (one API call per page),
    /// combine into a MenuScan, auto-save to history, render the PDF,
    /// then start thumbnail generation in the background.
    func analyze() async {
        let images = pickedImages
        guard !images.isEmpty else { return }
        let jpegs = images.compactMap { $0.jpegDataForUpload() }
        guard jpegs.count == images.count else {
            phase = .failed("无法编码所选图片。")
            return
        }
        phase = .analyzing(completed: 0, total: jpegs.count)
        let client = OpenAIClient(apiKey: KeychainStore.loadAPIKey(), model: model)
        do {
            var pages = [MenuDocument?](repeating: nil, count: jpegs.count)
            var completed = 0
            try await withThrowingTaskGroup(of: (Int, MenuDocument).self) { group in
                for (index, jpeg) in jpegs.enumerated() {
                    group.addTask {
                        (index, try await client.analyzeMenu(jpegData: jpeg))
                    }
                }
                for try await (index, document) in group {
                    pages[index] = document
                    completed += 1
                    phase = .analyzing(completed: completed, total: jpegs.count)
                }
            }
            let newScan = MenuScan.combining(pages: pages.compactMap { $0 })
            history.save(scan: newScan, images: images)
            scan = newScan
            scanImages = images
            generatedImages = [:]
            phase = .done
            rerenderPDF()
            startImageGenerationIfNeeded()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Open a saved scan from the history list.
    func open(_ saved: MenuScan) {
        imageGenTask?.cancel()
        scan = saved
        scanImages = history.loadImages(for: saved)
        generatedImages = history.loadGeneratedImages(for: saved)
        imageProgress = nil
        phase = .done
        rerenderPDF()
        startImageGenerationIfNeeded()
    }

    func reset() {
        imageGenTask?.cancel()
        phase = .idle
        pickedImages = []
        scan = nil
        scanImages = []
        generatedImages = [:]
        imageProgress = nil
        pdfData = nil
    }

    func rerenderPDF() {
        guard let scan else { return }
        pdfData = MenuPDFRenderer(
            scan: scan,
            images: scanImages,
            generatedImages: generatedImages
        ).renderPDF()
    }

    // MARK: - Concurrent dish-thumbnail generation

    /// Dishes that have no printed photo on the menu get an AI thumbnail.
    /// Requests are split one-per-dish and run through a small concurrency
    /// window; each result is persisted immediately, and the PDF is
    /// re-rendered once at the end.
    private func startImageGenerationIfNeeded() {
        guard generateDishImages, let scan else { return }

        var jobs: [(key: String, item: MenuItemEntry)] = []
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                for (i, item) in section.items.enumerated() {
                    let key = MenuScan.dishKey(page: p, section: s, item: i)
                    if item.photoBBox == nil, generatedImages[key] == nil {
                        jobs.append((key, item))
                    }
                }
            }
        }
        guard !jobs.isEmpty else { return }

        let client = ImageGenClient(apiKey: KeychainStore.loadAPIKey())
        let scanID = scan.id
        imageProgress = (done: 0, total: jobs.count)

        imageGenTask = Task { [weak self] in
            await withTaskGroup(of: (String, UIImage?).self) { group in
                var pending = jobs[...]
                let window = 3
                func addNext(_ group: inout TaskGroup<(String, UIImage?)>) {
                    guard let job = pending.popFirst() else { return }
                    group.addTask {
                        let image = await client.generateDishThumbnail(
                            name: job.item.originalName,
                            chineseName: job.item.chineseName,
                            description: job.item.originalDescription
                        )
                        return (job.key, image)
                    }
                }
                for _ in 0 ..< window { addNext(&group) }

                var done = 0
                for await (key, image) in group {
                    guard let self, !Task.isCancelled else { return }
                    done += 1
                    if let image {
                        self.generatedImages[key] = image
                        self.history.saveGeneratedImage(image, scanID: scanID, dishKey: key)
                    }
                    self.imageProgress = (done: done, total: jobs.count)
                    addNext(&group)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.imageProgress = nil
            self.rerenderPDF()
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
        phase = .done
        rerenderPDF()
    }
    #endif
}
