import PDFKit
import SwiftUI

/// Zoomable result viewer: shows the rendered bilingual PDF (layout pages that
/// mirror the original menu + the per-dish appendix) in a PDFKit view with
/// pinch-zoom and pan, plus a share/export button.
struct ResultView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onRestart: () -> Void

    @State private var shareURL: URL?

    var body: some View {
        Group {
            if let data = viewModel.pdfData {
                PDFKitView(data: data)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView("正在排版……")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = viewModel.pipeline,
               let total = progress.imagesTotal, total > 0, !progress.imagesFinished {
                VStack(spacing: 6) {
                    HStack {
                        Label("正在生成菜品配图", systemImage: "photo.artframe")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(progress.imagesDone)/\(total) 张")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.imagesDone), total: Double(total))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
        .navigationTitle(viewModel.scan?.restaurantName ?? "翻译结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("重新开始", action: onRestart)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let url = currentShareURL() {
                    ShareLink(item: url) {
                        Label("导出 PDF", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// Write the current PDF to a stable temp file for ShareLink.
    /// Re-written whenever the PDF bytes change (e.g. thumbnails landed).
    private func currentShareURL() -> URL? {
        guard let data = viewModel.pdfData, let scan = viewModel.scan else { return nil }
        let name = (scan.restaurantName ?? "菜单")
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(scan.id.uuidString.prefix(8)).pdf")
        if (try? Data(contentsOf: url))?.count != data.count {
            try? data.write(to: url)
        }
        return url
    }
}

/// PDFKit wrapper — gives pinch-zoom, pan, and continuous page scrolling.
struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGray6
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Replace the document only when the bytes actually changed,
        // otherwise every SwiftUI update would reset the zoom/scroll position.
        if view.document?.dataRepresentation()?.count != data.count {
            view.document = PDFDocument(data: data)
            view.autoScales = true
        }
    }
}
