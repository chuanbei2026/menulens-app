import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()
    /// Per-scan choice, surfaced next to the analyze button; the last choice
    /// is remembered as the default for the next scan (same key the view
    /// model reads at analyze time).
    @AppStorage("generate_dish_images") private var generateDishImages = true
    @State private var photosItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .idle, .failed:
                    startScreen
                case .analyzing:
                    AnalysisProgressView(viewModel: viewModel)
                case .done:
                    ResultView(viewModel: viewModel) {
                        viewModel.reset()
                    }
                }
            }
            .navigationTitle("口袋菜单")
            .toolbar {
                // Home-screen chrome only; the result screen brings its own
                // minimal toolbar (home / view switch / share).
                if viewModel.phase != .done {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) {
                HistoryView(history: viewModel.history) { scan in
                    viewModel.open(scan)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    Task { await viewModel.appendPhotos([image]) }
                }
                .ignoresSafeArea()
            }
            #if DEBUG
            // Automation hooks for headless simulator verification:
            //   -loadSample       load the demo menu on launch
            //   -autoPDF          also dump the rendered PDF into Documents
            //   -apiKey <key>     store the key in the Keychain
            //   -analyzeSample    run the REAL OpenAI call on the demo image,
            //                     then dump result JSON + PDF into Documents
            .onAppear {
                let args = CommandLine.arguments
                if args.contains("-loadSample") || args.contains("-autoPDF") {
                    viewModel.loadSample()
                }
                if args.contains("-noImages") {
                    viewModel.generateDishImages = false
                }
                if let idx = args.firstIndex(of: "-targetLang"), idx + 1 < args.count {
                    viewModel.targetLanguageCode = args[idx + 1]
                }
                if args.contains("-autoPDF"), let data = viewModel.pdfData {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("sample.pdf")
                    try? data.write(to: url)
                }
                if let idx = args.firstIndex(of: "-apiKey"), idx + 1 < args.count {
                    KeychainStore.saveAPIKey(args[idx + 1])
                }
                func analyzeAndDump(_ photos: [UIImage]) {
                    Task { @MainActor in
                        await viewModel.appendPhotos(photos)
                        await viewModel.analyze()
                        guard let scan = viewModel.scan else { return }
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        try? (try? encoder.encode(scan))?.write(to: docs.appendingPathComponent("real_result.json"))
                        try? viewModel.pdfData?.write(to: docs.appendingPathComponent("real_result.pdf"))
                    }
                }
                if args.contains("-analyzeSample") || args.contains("-analyzeSampleWarped") {
                    analyzeAndDump([
                        args.contains("-analyzeSampleWarped")
                            ? SampleData.warpedSampleImage()
                            : SampleData.sampleImage(),
                    ])
                }
                // Open a specific history scan by UUID prefix (DEBUG nav).
                if let idx = args.firstIndex(of: "-openScan"), idx + 1 < args.count {
                    let prefix = args[idx + 1].uppercased()
                    Task { @MainActor in
                        for _ in 0 ..< 20 where viewModel.history.scans.isEmpty {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                        if let match = viewModel.history.scans.first(where: {
                            $0.id.uuidString.hasPrefix(prefix)
                        }) {
                            viewModel.open(match)
                        }
                    }
                }
                // Reopen the newest history scan (thumbnails load from disk)
                // and dump the fully-illustrated PDF to Documents/final.pdf.
                if args.contains("-openLatest") {
                    Task { @MainActor in
                        guard let latest = viewModel.history.scans.first else { return }
                        viewModel.open(latest)
                        for _ in 0 ..< 120 where viewModel.pdfData == nil {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        try? viewModel.pdfData?.write(to: docs.appendingPathComponent("final.pdf"))
                    }
                }
                // Put the first few dishes in the cart (for UI verification).
                if args.contains("-demoCart") {
                    Task { @MainActor in
                        for _ in 0 ..< 20 where viewModel.scan == nil {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        guard let scan = viewModel.scan else { return }
                        var keys: [String] = []
                        for (p, page) in scan.pages.enumerated() {
                            for (s, section) in page.sections.enumerated() {
                                for (i, _) in section.items.enumerated() {
                                    keys.append(MenuScan.dishKey(page: p, section: s, item: i))
                                }
                            }
                        }
                        if !PartyStore.shared.members.contains(where: { $0.name == "小明" }) {
                            PartyStore.shared.add(name: "小明")
                        }
                        let friend = PartyStore.shared.members.first { $0.name == "小明" }!.id
                        for key in keys.prefix(3) { viewModel.addToCart(key) }
                        if let first = keys.first { viewModel.addToCart(first, member: friend) } // ×2 across two people
                        if keys.count > 3 { viewModel.addToCart(keys[3], member: friend) }
                    }
                }
                // Simulator only, zero API cost: rectify the given photos and
                // dump rectified_<n>.jpg into Documents for inspection.
                if let idx = args.firstIndex(of: "-rectifyOnly"), idx + 1 < args.count {
                    let paths = args[idx + 1].split(separator: ",").map(String.init)
                    Task.detached {
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        for (n, path) in paths.enumerated() {
                            guard let photo = UIImage(contentsOfFile: path) else { continue }
                            let rectified = DocumentRectifier.rectify(photo)
                            try? rectified.jpegData(compressionQuality: 0.85)?
                                .write(to: docs.appendingPathComponent("rectified_\(n).jpg"))
                        }
                    }
                }
                // Simulator only: feed real photo files straight from the Mac,
                // e.g. -analyzeFiles /Users/me/Desktop/menu1.jpg,/Users/me/Desktop/menu2.jpg
                if let idx = args.firstIndex(of: "-analyzeFiles"), idx + 1 < args.count {
                    let photos = args[idx + 1]
                        .split(separator: ",")
                        .compactMap { UIImage(contentsOfFile: String($0)) }
                    if !photos.isEmpty { analyzeAndDump(photos) }
                }
            }
            #endif
            .onAppear {
                viewModel.history.seedBundledSamplesIfNeeded()
            }
            .onChange(of: photosItems) {
                let items = photosItems
                guard !items.isEmpty else { return }
                Task {
                    var loaded: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            loaded.append(image)
                        }
                    }
                    photosItems = []
                    await viewModel.appendPhotos(loaded)
                }
            }
        }
    }

    // MARK: - Start screen

    private var startScreen: some View {
        VStack(spacing: 16) {
            Spacer()

            if viewModel.pickedImages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("拍下菜单，得到同版式的中文对照 PDF")
                        .font(.headline)
                    Text("支持多页 · 自动配图 · 任意语言 · 本地保存")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                pageThumbnails
            }

            if viewModel.isRectifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在矫正照片…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if case let .failed(message) = viewModel.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            HStack(spacing: 14) {
                Button {
                    showCamera = true
                } label: {
                    Label(viewModel.pickedImages.isEmpty ? "拍照" : "再拍一页", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $photosItems, maxSelectionCount: 8, matching: .images) {
                    Label("相册", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Toggle(isOn: $generateDishImages) {
                VStack(alignment: .leading, spacing: 1) {
                    Label("为没有照片的菜生成配图", systemImage: "photo.artframe")
                        .font(.subheadline)
                    Text("AI 生成，约 $0.003/道，稍慢；本次识别生效")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            Button {
                Task { await viewModel.analyze() }
            } label: {
                Label(
                    viewModel.pickedImages.count > 1
                        ? "识别并翻译（\(viewModel.pickedImages.count) 页）"
                        : "识别并翻译",
                    systemImage: "sparkles"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.pickedImages.isEmpty)
            .padding(.horizontal)

            Button("看看内置示例菜单（无需 API key）") {
                showHistory = true
            }
            .font(.footnote)
            .padding(.top, 4)

            Spacer().frame(height: 24)
        }
    }

    /// Horizontal strip of queued menu pages, each removable.
    private var pageThumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(viewModel.pickedImages.enumerated()), id: \.offset) { index, image in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 130, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button {
                                viewModel.pickedImages.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .padding(5)
                        }
                        Text("第 \(index + 1) 页")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 210)
    }

}
