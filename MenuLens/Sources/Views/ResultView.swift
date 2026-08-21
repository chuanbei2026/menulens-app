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
    @State private var showOrderSummary =
        ProcessInfo.processInfo.arguments.contains("-showSummary")
    /// Canvas shows the untouched original menu (order marks kept) — for
    /// handing the phone to a server.
    @State private var showOriginal =
        ProcessInfo.processInfo.arguments.contains("-showOriginal")

    var body: some View {
        Group {
            switch mode {
            case .canvas:
                MenuCanvasView(viewModel: viewModel, showOriginal: $showOriginal) { dishKey in
                    listTarget = dishKey
                    mode = .list
                }
            case .list:
                DishListView(viewModel: viewModel, scrollTarget: $listTarget)
            }
        }
        .safeAreaInset(edge: .top) {
            if let notice = viewModel.notice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.footnote)
                    Spacer()
                    Button {
                        viewModel.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
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

                // Two big view-switch buttons across the very tail of the screen.
                HStack(spacing: 0) {
                    viewTab(.canvas, icon: "doc.richtext", selectedIcon: "doc.richtext.fill", title: "画布")
                    viewTab(.list, icon: "list.bullet", selectedIcon: "list.bullet", title: "列表")
                }
                .background(.regularMaterial)
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

    /// One half of the bottom view-switch bar.
    private func viewTab(_ tab: Mode, icon: String, selectedIcon: String, title: String) -> some View {
        let selected = mode == tab
        return Button {
            mode = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
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
    @Binding var showOriginal: Bool
    let onSelectDish: (String) -> Void

    var body: some View {
        if let scan = viewModel.scan {
            let multiPage = scan.pages.count > 1
            TabView {
                ForEach(Array(scan.pages.enumerated()), id: \.offset) { index, document in
                    if index < viewModel.scanImages.count {
                        CanvasPage(
                            document: document,
                            pageIndex: index,
                            image: viewModel.scanImages[index],
                            highlights: viewModel.highlightTotals,
                            orderLabels: viewModel.orderLabels,
                            showOriginal: showOriginal,
                            onSelectDish: onSelectDish
                        )
                        // Keep the page dots clear (multi-page only).
                        .padding(.bottom, multiPage ? 34 : 0)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: multiPage ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Color(.systemGray5))
            .overlay(alignment: .topTrailing) {
                // Hand-to-server switch: the original menu, order marks kept.
                Button {
                    showOriginal.toggle()
                } label: {
                    Label(
                        showOriginal ? "看译文" : "看原文",
                        systemImage: showOriginal ? "character.bubble" : "globe"
                    )
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                }
                .padding(.trailing, 14)
                .padding(.top, 10)
            }
        }
    }
}

private struct CanvasPage: View {
    let document: MenuDocument
    let pageIndex: Int
    let image: UIImage
    let highlights: [String: Int]
    let orderLabels: [String: String]
    let showOriginal: Bool
    let onSelectDish: (String) -> Void

    @State private var rendered: UIImage?

    /// Stable signature so the canvas re-renders when the order changes.
    private var highlightSignature: String {
        highlights.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value):\(orderLabels[$0.key] ?? "")" }
            .joined(separator: ",") + (showOriginal ? "|orig" : "")
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
            let page = image.normalizedOrientation()
            let showOriginal = showOriginal
            let document = document
            let pageIndex = pageIndex
            let highlights = highlights
            let orderLabels = orderLabels
            rendered = await Task.detached(priority: .userInitiated) {
                // Background reconstruction is only needed when translations
                // are drawn; the original view paints the raw photo.
                let prepared = showOriginal ? (plate: nil, background: nil) : PaperPlate.prepare(page)
                let renderer = MenuLayoutRenderer(
                    document: document,
                    image: page,
                    pageWidth: 1600,
                    pageIndex: pageIndex,
                    highlights: highlights,
                    orderLabels: orderLabels,
                    paperPlate: prepared.plate,
                    backgroundImage: prepared.background,
                    translationsHidden: showOriginal
                )
                return renderer.renderImage()
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

    /// Dishes a member ordered that clash with what they don't eat.
    private func conflicts(for member: PartyMember) -> [(item: MenuItemEntry, tags: [DietTag])] {
        let avoided = member.avoidedTags
        guard !avoided.isEmpty else { return [] }
        return viewModel.cartEntries(for: member.id).compactMap { entry in
            let hits = DietTag.tags(for: entry.item).intersection(avoided)
            return hits.isEmpty ? nil : (entry.item, hits.sorted { $0.rawValue < $1.rawValue })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Diet clashes first and loud: this is the one thing in the
                // summary that can ruin someone's meal.
                let allConflicts = party.members.map { ($0, conflicts(for: $0)) }
                    .filter { !$0.1.isEmpty }
                if !allConflicts.isEmpty {
                    Section {
                        ForEach(allConflicts, id: \.0.id) { member, hits in
                            ForEach(hits, id: \.item.originalName) { hit in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(member.name) \(hit.tags.map(\.avoidanceLabel).joined(separator: "、"))")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.red)
                                        Text("但点了「\(hit.item.chineseName)」\(hit.item.originalName)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Label("忌口冲突", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                // Grouped by person, so it's obvious whose dish is whose.
                ForEach(party.members) { member in
                    let entries = viewModel.cartEntries(for: member.id)
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries, id: \.key) { entry in
                                let clash = DietTag.tags(for: entry.item).intersection(member.avoidedTags)
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(entry.item.originalName)
                                                .font(.subheadline.weight(.semibold))
                                            if !clash.isEmpty {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.red)
                                            }
                                        }
                                        Text(entry.item.chineseName)
                                            .font(.footnote)
                                            .foregroundStyle(clash.isEmpty ? .orange : .red)
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
                            HStack(spacing: 6) {
                                AvatarView(party: party, memberID: member.id, size: 20)
                                Text(member.name)
                                    .foregroundStyle(party.color(of: member.id))
                            }
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
    /// Chinese-target users don't look for gluten-free; hide the GF chip
    /// there and keep it for other target languages.
    var showGlutenFree: Bool = true
    /// Meat markers are only shown where they matter (the list); the canvas
    /// stays clean.
    var showMeat: Bool = true

    var body: some View {
        let all = (tags ?? []).compactMap(DietTag.init(rawValue:))
        let visible = all.filter { tag in
            switch tag {
            case .glutenFree: return showGlutenFree
            case .pork, .chicken, .beef, .lamb, .seafood: return showMeat
            case .vegan, .vegetarian: return true
            }
        }
        if !visible.isEmpty {
            HStack(spacing: 3) {
                ForEach(visible) { tag in
                    if tag == .glutenFree {
                        Text(tag.badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text(tag.badge).font(.caption)
                    }
                }
            }
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
                                inferredTags: DietTag.tags(for: row.item).map(\.rawValue),
                                photo: photo(for: row),
                                quantity: viewModel.quantity(of: row.id),
                                memberBreakdown: viewModel.orderLabels[row.id],
                                showGlutenFree: TargetLanguage.from(code: viewModel.scan?.targetLanguage).showsGlutenFree,
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
        // Custom search field pinned to the TOP — the system .searchable
        // drawer moves between top and bottom on its own, which looked buggy.
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索菜名（中文或原文）", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
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
    let inferredTags: [String]
    let photo: UIImage?
    let quantity: Int
    let memberBreakdown: String?
    let showGlutenFree: Bool
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
                    DietTagBadges(tags: inferredTags, showGlutenFree: showGlutenFree)
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
                        HStack(spacing: 5) {
                            AvatarView(party: party, memberID: member.id, size: 20)
                            Text(member.name)
                                .font(.footnote.weight(selected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
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
