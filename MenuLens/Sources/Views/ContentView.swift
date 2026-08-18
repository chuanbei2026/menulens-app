import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()
    @State private var photosItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .idle, .failed:
                    startScreen
                case .analyzing:
                    analyzingScreen
                case .done:
                    if let document = viewModel.document, let image = viewModel.pickedImage {
                        ResultView(document: document, sourceImage: image) {
                            viewModel.reset()
                        }
                    }
                }
            }
            .navigationTitle("MenuLens")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    viewModel.pickedImage = image
                }
                .ignoresSafeArea()
            }
            .onChange(of: photosItem) {
                guard let item = photosItem else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        viewModel.pickedImage = image
                    }
                    photosItem = nil
                }
            }
        }
    }

    private var startScreen: some View {
        VStack(spacing: 20) {
            Spacer()

            if let image = viewModel.pickedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 4)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("拍一张菜单，得到同版式的中文对照 PDF")
                        .font(.headline)
                    Text("逐词翻译 · 菜品配图 · 任意语言")
                        .font(.subheadline)
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
                    Label("拍照", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $photosItem, matching: .images) {
                    Label("相册", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Button {
                Task { await viewModel.analyze() }
            } label: {
                Label("识别并翻译", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.pickedImage == nil)
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var analyzingScreen: some View {
        VStack(spacing: 16) {
            if let image = viewModel.pickedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(0.6)
            }
            ProgressView()
            Text("正在识别菜单并逐词翻译……")
                .foregroundStyle(.secondary)
            Text("整页菜单一般需要 30–90 秒")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
