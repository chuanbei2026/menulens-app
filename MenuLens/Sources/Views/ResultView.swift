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
    @State private var showOrderSummary = false

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
        .overlay(alignment: .bottomLeading) {
            // View switcher floats at the bottom-left, out of the nav bar.
            Picker("视图", selection: $mode) {
                Image(systemName: "doc.richtext").tag(Mode.canvas)
                Image(systemName: "list.bullet").tag(Mode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 118)
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.leading, 12)
            .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
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

                if mode == .list {
                    MemberChips(viewModel: viewModel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial)
                }

                if viewModel.cartCount > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "cart")
                        Text("已选 \(viewModel.cartCount) 道")
                            .font(.subheadline.weight(.medium))
                        if let total = viewModel.cartTotalText {
                            Text(total)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("总结") { showOrderSummary = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                }
            }
        }
        .sheet(isPresented: $showOrderSummary) {
            OrderSummaryView(viewModel: viewModel) {
                mode = .canvas
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                            highlights: viewModel.highlightTotals,
                            orderLabels: viewModel.orderLabels,
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
    let highlights: [String: Int]
    let orderLabels: [String: String]
    let onSelectDish: (String) -> Void

    @State private var rendered: UIImage?

    /// Stable signature so the canvas re-renders when the order changes.
    private var highlightSignature: String {
        highlights.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value):\(orderLabels[$0.key] ?? "")" }
            .joined(separator: ",")
    }

    var body: some View {
        Group {
            if let rendered {
                ZoomableImageView(image: rendered) { normalizedPoint in
                    let renderer = MenuLayoutRenderer(
                        document: document, image: image, pageWidth: 1600, pageIndex: pageIndex
                    )
                    if let hit = renderer.hitTest(normalizedPoint: normalizedPoint) {
                        onSelectDish(MenuScan.dishKey(page: pageIndex, section: hit.section, item: hit.item))
                    }
                }
            } else {
                ProgressView("正在绘制画布…")
            }
        }
        .task(id: highlightSignature) {
            let renderer = MenuLayoutRenderer(
                document: document,
                image: image.normalizedOrientation(),
                pageWidth: 1600,
                pageIndex: pageIndex,
                highlights: highlights,
                orderLabels: orderLabels
            )
            rendered = await Task.detached(priority: .userInitiated) {
                renderer.renderImage()
            }.value
        }
    }
}

// MARK: - Order summary sheet

private struct OrderSummaryView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    /// Called when the user confirms — the caller switches to the canvas
    /// so the annotated menu can be shown to the waiter.
    let onAnnotate: () -> Void
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var party = PartyStore.shared

    var body: some View {
        NavigationStack {
            List {
                // Grouped by person, so it's obvious whose dish is whose.
                ForEach(party.members) { member in
                    let entries = viewModel.cartEntries(for: member.id)
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries, id: \.key) { entry in
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.item.originalName)
                                            .font(.subheadline.weight(.semibold))
                                        Text(entry.item.chineseName)
                                            .font(.footnote)
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    if let price = entry.item.price {
                                        Text(price)
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    QuantityStepper(quantity: entry.quantity) {
                                        viewModel.addToCart(entry.key, member: member.id)
                                    } onMinus: {
                                        viewModel.removeFromCart(entry.key, member: member.id)
                                    }
                                }
                            }
                        } header: {
                            Label(member.name, systemImage: "person.fill")
                                .foregroundStyle(party.color(of: member.id))
                        }
                    }
                }

                Section {
                    HStack {
                        Text("共 \(viewModel.cartCount) 道")
                        Spacer()
                        if let total = viewModel.cartTotalText {
                            Text("合计 \(total)")
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("已点菜品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("继续点单") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAnnotate()
                    dismiss()
                } label: {
                    Label("标注到菜单上给服务员看", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.cartCount == 0)
                .padding()
                .background(.thinMaterial)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Dietary tag icons shown next to the translated dish name:
/// 🌱 vegan · 🥬 vegetarian · GF gluten-free · 🐑 contains lamb · 🐟 seafood.
struct DietTagBadges: View {
    let tags: [String]?

    var body: some View {
        if let tags, !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags, id: \.self) { tag in
                    badge(for: tag)
                }
            }
        }
    }

    @ViewBuilder
    private func badge(for tag: String) -> some View {
        switch tag {
        case "vegan":
            Text("🌱").font(.caption)
        case "vegetarian":
            Text("🥬").font(.caption)
        case "gluten_free":
            Text("GF")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .overlay(Capsule().stroke(.green, lineWidth: 1))
        case "contains_lamb":
            Text("🐑").font(.caption)
        case "contains_seafood":
            Text("🐟").font(.caption)
        default:
            EmptyView()
        }
    }
}

/// Compact − qty + control used in list rows and the summary sheet.
struct QuantityStepper: View {
    let quantity: Int
    let onPlus: () -> Void
    let onMinus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if quantity > 0 {
                Button(action: onMinus) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.gray)
                }
                Text("\(quantity)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 18)
            }
            Button(action: onPlus) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.title3)
        .buttonStyle(.borderless)
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
                                photo: photo(for: row),
                                quantity: viewModel.quantity(of: row.id),
                                memberBreakdown: viewModel.orderLabels[row.id],
                                onPlus: { viewModel.addToCart(row.id) },
                                onMinus: { viewModel.removeFromCart(row.id) }
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
    let quantity: Int
    let memberBreakdown: String?
    let onPlus: () -> Void
    let onMinus: () -> Void

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
                HStack(spacing: 5) {
                    Text(item.chineseName)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    DietTagBadges(tags: item.tags)
                }
                if let zhDesc = item.chineseDescription {
                    Text(zhDesc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if let price = item.price {
                    Text(price)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                QuantityStepper(quantity: quantity, onPlus: onPlus, onMinus: onMinus)
                if let memberBreakdown, quantity > 0 {
                    Text(memberBreakdown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Horizontal picker of party members — new +1s go to the selected person.
private struct MemberChips: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @ObservedObject private var party = PartyStore.shared
    @State private var showAddMember = false
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("为谁点:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(party.members) { member in
                    let selected = viewModel.activeMemberID == member.id
                    Button {
                        viewModel.activeMemberID = member.id
                    } label: {
                        Text(member.name)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(selected ? party.color(of: member.id).opacity(0.22) : Color(.systemGray5))
                            )
                            .overlay(
                                Capsule().stroke(selected ? party.color(of: member.id) : .clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showAddMember = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
            }
        }
        .alert("添加成员", isPresented: $showAddMember) {
            TextField("名字", text: $newName)
            Button("添加") {
                PartyStore.shared.add(name: newName)
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        } message: {
            Text("也可以在设置页管理同行成员。")
        }
    }
}
