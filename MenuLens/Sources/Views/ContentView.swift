import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()
    /// Redraws this screen when the app language changes in Settings.
    @ObservedObject private var loc = Localization.shared
    /// Per-scan choice, surfaced next to the analyze button; the last choice
    /// is remembered as the default for the next scan (same key the view
    /// model reads at analyze time).
    @AppStorage("generate_dish_images") private var generateDishImages = true
    @State private var photosItems: [PhotosPickerItem] = []
    /// Without a key there is nothing to scan with, so the capture controls
    /// stay inert until one is entered.
    @State private var hasAPIKey = !KeychainStore.loadAPIKey().isEmpty
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var showHistory = false
    /// Picking a photo sends nothing; only Scan does. So consent is asked
    /// at the button that transmits, which is also where the user can see
    /// what they are about to send.
    @AppStorage("openai_consent_granted") private var aiConsentGranted = false
    @State private var showAIConsent =
        ProcessInfo.processInfo.arguments.contains("-showConsent")

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
            .navigationTitle(L("app.name"))
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
            .sheet(isPresented: $showAIConsent) {
                AIConsentView {
                    aiConsentGranted = true
                    Task { await viewModel.analyze() }
                }
            }
            .onChange(of: showSettings) {
                if !showSettings { hasAPIKey = !KeychainStore.loadAPIKey().isEmpty }
            }
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
            //   -showConsent      open the third-party AI consent sheet
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
                if let idx = args.firstIndex(of: "-model"), idx + 1 < args.count {
                    viewModel.model = args[idx + 1]
                }
                if args.contains("-autoPDF"), let data = viewModel.pdfData {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("sample.pdf")
                    try? data.write(to: url)
                }
                if let idx = args.firstIndex(of: "-apiKey"), idx + 1 < args.count {
                    KeychainStore.saveAPIKey(args[idx + 1])
                    hasAPIKey = true
                }
                // Keychain items outlive an app uninstall, so first-run
                // onboarding needs an explicit way to reproduce.
                if args.contains("-clearKey") {
                    KeychainStore.saveAPIKey("")
                    hasAPIKey = false
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
                        // A companion name that matches the app language —
                        // a Chinese name in an English App Store screenshot
                        // reads as a leftover, not as a feature.
                        let companion: String = switch Loc.language {
                        case .simplifiedChinese: "小明"
                        case .japanese: "ゆき"
                        case .korean: "지훈"
                        case .hindi: "आरव"
                        case .french: "Camille"
                        case .spanish: "Lucía"
                        case .english: "Alex"
                        }
                        if !PartyStore.shared.members.contains(where: { $0.name == companion }) {
                            PartyStore.shared.add(name: companion)
                        }
                        let friend = PartyStore.shared.members.first { $0.name == companion }!.id
                        if args.contains("-demoAvoid") {
                            // Find a dish with a detectable meat, give it to
                            // the friend, and mark that meat as avoided so the
                            // summary has a real clash to warn about.
                            var clash: (key: String, tag: DietTag)?
                            for (p, page) in scan.pages.enumerated() where clash == nil {
                                for (s, section) in page.sections.enumerated() where clash == nil {
                                    for (i, item) in section.items.enumerated() where clash == nil {
                                        if let tag = DietTag.tags(for: item).first(where: {
                                            DietTag.avoidable.contains($0)
                                        }) {
                                            clash = (MenuScan.dishKey(page: p, section: s, item: i), tag)
                                        }
                                    }
                                }
                            }
                            if let clash {
                                viewModel.addToCart(clash.key, member: friend)
                                if !(PartyStore.shared.members.first { $0.id == friend }?
                                    .avoidedTags.contains(clash.tag) ?? false) {
                                    PartyStore.shared.toggle(clash.tag, for: friend)
                                }
                            }
                        }
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
                hasAPIKey = !KeychainStore.loadAPIKey().isEmpty
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
            if !hasAPIKey {
                // First run: say what is needed before anything can be
                // scanned, and offer the sample menus as the way to look
                // around in the meantime.
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("onboarding.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("onboarding.body"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button {
                            showSettings = true
                        } label: {
                            Label(L("onboarding.enterKey"), systemImage: "key")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            showHistory = true
                        } label: {
                            Label(L("onboarding.viewSamples"), systemImage: "clock.arrow.circlepath")
                        }
                        .controlSize(.small)
                    }
                    .font(.footnote)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Spacer()

            if viewModel.pickedImages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text(L("home.headline"))
                        .font(.headline)
                    Text(L("home.subheadline"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                pageThumbnails
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
                    Label(viewModel.pickedImages.isEmpty ? L("home.capture") : L("home.captureMore"), systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasAPIKey)

                PhotosPicker(selection: $photosItems, maxSelectionCount: 8, matching: .images) {
                    Label(L("home.library"), systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasAPIKey)
            }
            .padding(.horizontal)

            Toggle(isOn: $generateDishImages) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(L("home.images.title"), systemImage: "photo.artframe")
                        .font(.subheadline)
                    Text(L("home.images.note"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            Button {
                if aiConsentGranted {
                    Task { await viewModel.analyze() }
                } else {
                    showAIConsent = true
                }
            } label: {
                Label(
                    viewModel.pickedImages.count > 1
                        ? L("home.analyze.pages", viewModel.pickedImages.count)
                        : L("home.analyze"),
                    systemImage: "sparkles"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.pickedImages.isEmpty || !hasAPIKey)
            .padding(.horizontal)

            if hasAPIKey {
                Button(L("home.samples")) {
                    showHistory = true
                }
                .font(.footnote)
                .padding(.top, 4)
            }

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
                        Text(L("page.number", index + 1))
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
