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
    /// Signed out there is nothing to scan with, so the capture controls
    /// stay inert until the user signs in.
    @ObservedObject private var account = AccountStore.shared
    /// What this App Store region offers: models, and whether dish pictures.
    @ObservedObject private var region = RegionStore.shared
    @State private var showCamera = false
    @State private var showSettings =
        ProcessInfo.processInfo.arguments.contains("-showSettings")
    @State private var showHistory = false
    @State private var showShop =
        ProcessInfo.processInfo.arguments.contains("-showShop")
    /// Picking a photo sends nothing; only Scan does. So consent is asked
    /// at the button that transmits, which is also where the user can see
    /// what they are about to send.
    @AppStorage(AIConsentView.grantedKey) private var aiConsentGranted = false
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
            .sheet(isPresented: $showShop) { ShopView() }
            .sheet(isPresented: $showAIConsent) {
                AIConsentView {
                    aiConsentGranted = true
                    Task { await viewModel.analyze() }
                }
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
            //   -sessionToken <t> store a backend session token (device or Apple account)
            //   -signOut          forget the session and the device account (a fresh install)
            //   -delayPage <i> <s> hold page i back s seconds (half-arrived result)
            //   -demoReceiving    newest multi-page scan, shown with its last page pending
            //   -demoUsage        a made-up month of credit history (Settings → Account)
            //   -demoMembership   with -demoUsage: a member (87 of 600 used this month);
            //                     -demoMembershipOver: past the fair use
            //   -showShop         open the shop (membership plans + credit packs)
            //   -analyzeSample    run the REAL OpenAI call on the demo image,
            //                     then dump result JSON + PDF into Documents
            //   -showConsent      open the third-party AI consent sheet
            //   -demoScan <r,…>   multi-page run on bundled samples, answered
            //                     from them (no request); -failPage <i> fails
            //                     page i once, -autoRetry <s> retries failed
            //                     pages after s seconds, -dumpPDF writes
            //                     Documents/result.pdf on every render
            //   -statusMode       open the result on the status view
            //   -landscape        rotate (iPad: the three-column result)
            //   -showSettings     open Settings (longest strings live in its footers,
            //                     so this is the screen text overflow shows up on)
            //   -grantConsent     grant the third-party-AI consent; REQUIRED
            //                     alongside -analyzeSample / -analyzeFiles,
            //                     which analyze() otherwise refuses to run
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
                if let idx = args.firstIndex(of: "-delayPage"), idx + 2 < args.count,
                   let page = Int(args[idx + 1]), let seconds = Double(args[idx + 2]) {
                    AnalysisViewModel.debugPageDelay[page] = seconds
                }
                if let idx = args.firstIndex(of: "-model"), idx + 1 < args.count {
                    viewModel.model = args[idx + 1]
                }
                if args.contains("-autoPDF"), let data = viewModel.pdfData {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("sample.pdf")
                    try? data.write(to: url)
                }
                if let idx = args.firstIndex(of: "-sessionToken"), idx + 1 < args.count {
                    account.setSession(args[idx + 1])
                    Task { await account.refreshCredits() }
                }
                // analyze() refuses to run without consent (guideline
                // 5.1.2(i)), which silently turned every -analyzeSample /
                // -analyzeFiles run into a no-op. Automation grants it
                // explicitly rather than -sessionToken implying it: the whole
                // point of the gate is that an account and permission are
                // separate.
                if args.contains("-grantConsent") {
                    aiConsentGranted = true
                }
                // -signOut is applied in AccountStore.init, before the first
                // session is opened.
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
                // Open a specific history scan by UUID prefix (DEBUG nav); also
            // dumps its PDF to Documents/scan.pdf.
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
                            // Like -openLatest: the PDF as it renders once
                            // the thumbnails are in, as Documents/scan.pdf.
                            for _ in 0 ..< 120 where viewModel.pdfData == nil {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                            }
                            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            try? viewModel.pdfData?.write(to: docs.appendingPathComponent("scan.pdf"))
                        }
                    }
                }
                // The newest multi-page scan, half-arrived (DEBUG screenshots).
                if args.contains("-demoReceiving") {
                    Task { @MainActor in
                        for _ in 0 ..< 20 where viewModel.history.scans.isEmpty {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                        guard let scan = viewModel.history.scans.first(where: { $0.pages.count > 1 }) else { return }
                        viewModel.open(scan)
                        viewModel.debugShowReceiving()
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
                        case .traditionalChinese: "小明"
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
                // Simulator only, zero API cost: the multi-page pipeline on
                // bundled samples, answered from the samples themselves —
                // e.g. -demoScan naan-n-curry,la-mar -failPage 1 -noImages.
                // See AnalysisViewModel.debugAnswers.
                if let idx = args.firstIndex(of: "-demoScan"), idx + 1 < args.count,
                   let root = Bundle.main.resourceURL?.appendingPathComponent("Samples") {
                    let language = FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(Loc.language.rawValue).path
                    ) ? Loc.language.rawValue : AppLanguage.english.rawValue
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    var photos: [UIImage] = []
                    var answers: [MenuDocument] = []
                    for name in args[idx + 1].split(separator: ",") {
                        let dir = root.appendingPathComponent(language).appendingPathComponent(String(name))
                        guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")),
                              let sample = try? decoder.decode(MenuScan.self, from: data)
                        else { continue }
                        for (page, document) in sample.pages.enumerated() {
                            guard let photo = UIImage(contentsOfFile: dir.appendingPathComponent("page_\(page).jpg").path)
                            else { continue }
                            photos.append(photo)
                            answers.append(document)
                        }
                    }
                    if let failIdx = args.firstIndex(of: "-failPage"), failIdx + 1 < args.count,
                       let page = Int(args[failIdx + 1]) {
                        AnalysisViewModel.debugFailOnce = [page]
                    }
                    AnalysisViewModel.debugAnswers = answers
                    if !photos.isEmpty { analyzeAndDump(photos) }
                }
                // Retry every failed page after <s> seconds (what the
                // status view's retry button does), e.g. after the run ended.
                if let idx = args.firstIndex(of: "-autoRetry"), idx + 1 < args.count,
                   let seconds = Double(args[idx + 1]) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(seconds))
                        for page in viewModel.failedPages.sorted() { viewModel.retryPage(page) }
                    }
                }
                // iPad screenshots in landscape (the three-column result).
                if args.contains("-landscape") {
                    Task { @MainActor in
                        // Too early at launch: the scene must be active first.
                        try? await Task.sleep(for: .seconds(1))
                        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                            print("-landscape: \(error.localizedDescription)")
                        }
                    }
                }
            }
            #endif
            .onAppear {
                viewModel.history.seedBundledSamplesIfNeeded()
                viewModel.history.labelGeneratedImagesIfNeeded()
            }
            .task {
                // First launch: open the device account (no sign-in step).
                await account.ensureSession()
                await account.refreshCredits()
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
            // A lapsed Apple session or a move to the Apple account: say so
            // (Settings → Account has the Apple button). Nothing here blocks.
            if let message = account.message {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    // No "dish photos" promise where the region has none.
                    Text(L(region.catalog.images ? "home.subheadline" : "home.subheadline.noImages"))
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
                if viewModel.outOfCredits {
                    Button {
                        showShop = true
                    } label: {
                        Label(L("shop.buy"), systemImage: "cart.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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

                PhotosPicker(selection: $photosItems, maxSelectionCount: 8, matching: .images) {
                    Label(L("home.library"), systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            if region.catalog.images {
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
            } else {
                Label(L("home.images.unavailable"), systemImage: "photo.artframe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            if region.isAvailable {
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
                .disabled(viewModel.pickedImages.isEmpty)
                .padding(.horizontal)
            } else {
                // No model may run for this App Store region: say so where
                // the scan would start, instead of a request that fails.
                Label(L("home.region.unavailable"), systemImage: "globe.badge.chevron.backward")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.secondary)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .padding(.horizontal)
            }

            Button(L("home.samples")) {
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
