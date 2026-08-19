import SwiftUI

/// Result screen with two switchable views (segmented control in the nav bar):
///
/// - **画布** — one zoomable canvas per photographed page (pinch to zoom,
///   double-tap to magnify), pages swiped via bottom page dots. Cards carry
///   no images; tapping a card jumps to that dish in the list view.
/// - **列表** — native iOS list of every dish (with cropped/AI images),
///   searchable in Chinese or the menu's original language.
struct ResultView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onRestart: () -> Void

    enum Mode: Hashable {
        case canvas
        case list
    }

    @State private var mode: Mode =
        ProcessInfo.processInfo.arguments.contains("-listMode") ? .list : .canvas
    /// Dish key the list should scroll to (set by tapping a canvas card).
    @State private var listTarget: String?

    var body: some View {
        Group {
            switch mode {
            case .canvas:
                MenuCanvasView(viewModel: viewModel) { dishKey in
                    listTarget = dishKey
                    mode = .list
                }
            case .list:
                DishListView(viewModel: viewModel, scrollTarget: $listTarget)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $mode) {
                    Image(systemName: "doc.richtext").tag(Mode.canvas)
                    Image(systemName: "list.bullet").tag(Mode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onRestart) {
                    Image(systemName: "house")
                }
                .accessibilityLabel("返回首页")
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
        let name = (scan.restaurantName ?? "菜单").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(scan.id.uuidString.prefix(8)).pdf")
        if (try? Data(contentsOf: url))?.count != data.count {
            try? data.write(to: url)
        }
        return url
    }
}

// MARK: - Canvas view (zoomable pages + page dots)

private struct MenuCanvasView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onSelectDish: (String) -> Void

    var body: some View {
        if let scan = viewModel.scan {
            TabView {
                ForEach(Array(scan.pages.enumerated()), id: \.offset) { index, document in
                    if index < viewModel.scanImages.count {
                        CanvasPage(
                            document: document,
                            pageIndex: index,
                            image: viewModel.scanImages[index],
                            onSelectDish: onSelectDish
                        )
                        .padding(.bottom, 34) // keep the page dots clear
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Color(.systemGray5))
        }
    }
}

private struct CanvasPage: View {
    let document: MenuDocument
    let pageIndex: Int
    let image: UIImage
    let onSelectDish: (String) -> Void

    @State private var rendered: UIImage?

    var body: some View {
        Group {
            if let rendered {
                ZoomableImageView(image: rendered) { normalizedPoint in
                    let renderer = MenuLayoutRenderer(
                        document: document, image: image, pageWidth: 1600
                    )
                    if let hit = renderer.hitTest(normalizedPoint: normalizedPoint) {
                        onSelectDish(MenuScan.dishKey(page: pageIndex, section: hit.section, item: hit.item))
                    }
                }
            } else {
                ProgressView("正在绘制画布…")
                    .task {
                        let renderer = MenuLayoutRenderer(
                            document: document,
                            image: image.normalizedOrientation(),
                            pageWidth: 1600
                        )
                        rendered = await Task.detached(priority: .userInitiated) {
                            renderer.renderImage()
                        }.value
                    }
            }
        }
    }
}

// MARK: - List view (native, searchable)

private struct DishListView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @Binding var scrollTarget: String?
    @State private var searchText = ""

    private struct Row: Identifiable {
        let id: String // dish key
        let item: MenuItemEntry
        let pageIndex: Int
    }

    private struct SectionGroup: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            DishRow(
                                item: row.item,
                                photo: photo(for: row)
                            )
                            .id(row.id)
                        }
                    } header: {
                        if !group.title.isEmpty { Text(group.title) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .onAppear { jumpIfNeeded(proxy) }
            .onChange(of: scrollTarget) { jumpIfNeeded(proxy) }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索菜名（中文或原文）"
        )
    }

    private func jumpIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        // Give the list one runloop to build before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation { proxy.scrollTo(target, anchor: .center) }
            scrollTarget = nil
        }
    }

    private func photo(for row: Row) -> UIImage? {
        if let box = row.item.photoBBox, row.pageIndex < viewModel.scanImages.count {
            return viewModel.scanImages[row.pageIndex].crop(normalized: box)
        }
        return viewModel.generatedImages[row.id]
    }

    private var groups: [SectionGroup] {
        guard let scan = viewModel.scan else { return [] }
        let multiPage = scan.pages.count > 1
        var result: [SectionGroup] = []
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                let rows = section.items.enumerated().compactMap { i, item -> Row? in
                    guard matches(item) else { return nil }
                    return Row(id: MenuScan.dishKey(page: p, section: s, item: i), item: item, pageIndex: p)
                }
                guard !rows.isEmpty else { continue }
                var title = [section.chineseTitle, section.originalTitle]
                    .compactMap { $0 }.joined(separator: " / ")
                if multiPage {
                    title = title.isEmpty ? "第 \(p + 1) 页" : "第 \(p + 1) 页 · \(title)"
                }
                result.append(SectionGroup(id: "p\(p)s\(s)", title: title, rows: rows))
            }
        }
        return result
    }

    private func matches(_ item: MenuItemEntry) -> Bool {
        let query = normalized(searchText)
        guard !query.isEmpty else { return true }
        let haystack = [
            item.originalName, item.chineseName,
            item.originalDescription ?? "", item.chineseDescription ?? "",
            item.price ?? "",
        ].map(normalized).joined(separator: " ")
        return haystack.contains(query)
    }

    private func normalized(_ string: String) -> String {
        string.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DishRow: View {
    let item: MenuItemEntry
    let photo: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.originalName)
                    .font(.headline)
                Text(item.chineseName)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                if let zhDesc = item.chineseDescription {
                    Text(zhDesc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let price = item.price {
                Text(price)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
