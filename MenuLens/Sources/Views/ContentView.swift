import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()
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
                case let .analyzing(completed, total):
                    analyzingScreen(completed: completed, total: total)
                case .done:
                    ResultView(viewModel: viewModel) {
                        viewModel.reset()
                    }
                }
            }
            .navigationTitle("MenuLens")
            .toolbar {
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
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) {
                HistoryView(history: viewModel.history) { scan in
                    viewModel.open(scan)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    viewModel.pickedImages.append(image)
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
                if args.contains("-autoPDF"), let data = viewModel.pdfData {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("sample.pdf")
                    try? data.write(to: url)
                }
                if let idx = args.firstIndex(of: "-apiKey"), idx + 1 < args.count {
                    KeychainStore.saveAPIKey(args[idx + 1])
                }
                if args.contains("-analyzeSample") {
                    viewModel.pickedImages = [SampleData.sampleImage()]
                    Task {
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
            }
            #endif
            .onChange(of: photosItems) {
                let items = photosItems
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            viewModel.pickedImages.append(image)
                        }
                    }
                    photosItems = []
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

            #if DEBUG
            Button("载入示例菜单（无需 API key）") {
                viewModel.loadSample()
            }
            .font(.footnote)
            .padding(.top, 4)
            #endif

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

    // MARK: - Analyzing screen

    private func analyzingScreen(completed: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            if let first = viewModel.pickedImages.first {
                Image(uiImage: first)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(0.6)
            }
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .padding(.horizontal, 40)
            Text(total > 1 ? "正在识别翻译……已完成 \(completed)/\(total) 页" : "正在识别菜单并翻译……")
                .foregroundStyle(.secondary)
            Text("多页会并发处理，通常 1–2 分钟内完成")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
