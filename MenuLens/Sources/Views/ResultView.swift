import SwiftUI

/// Result screen with two switchable views (segmented control in the nav bar):
///
/// - **Canvas** — one zoomable canvas per photographed page (pinch to zoom,
///   double-tap to magnify), pages swiped via bottom page dots. Cards carry
///   no images; tapping a card jumps to that dish in the list view.
/// - **List** — native iOS list of every dish (with cropped/AI images),
///   searchable in the translation or the menu's original language.
struct ResultView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onRestart: () -> Void
    @ObservedObject private var loc = Localization.shared

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
                            Label(L("result.generatingImages"), systemImage: "photo.artframe")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L("progress.images.fraction", progress.imagesDone, total))
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
                        Text(L("result.selected", viewModel.cartCount))
                            .font(.subheadline.weight(.medium))
                        if let total = viewModel.cartTotalText {
                            Text(total)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("result.summary")) { showOrderSummary = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                }

                // Two big view-switch buttons across the very tail of the screen.
                HStack(spacing: 0) {
                    viewTab(.canvas, icon: "doc.richtext", selectedIcon: "doc.richtext.fill",
                            title: L("result.tab.canvas"))
                    viewTab(.list, icon: "list.bullet", selectedIcon: "list.bullet",
                            title: L("result.tab.list"))
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
                .accessibilityLabel(L("result.home"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let url = currentShareURL() {
                    ShareLink(item: url) {
                        Label(L("result.exportPDF"), systemImage: "square.and.arrow.up")
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
        let name = (scan.restaurantName ?? L("share.menu")).replacingOccurrences(of: "/", with: "-")
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
    @ObservedObject private var loc = Localization.shared

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
                        showOriginal ? L("canvas.showTranslation") : L("canvas.showOriginal"),
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
                ProgressView(L("canvas.drawing"))
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
    @ObservedObject private var loc = Localization.shared
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
                                        Text("\(member.name) \(hit.tags.map(\.avoidanceLabel).joined(separator: L("list.separator")))")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.red)
                                        Text(L("summary.avoidsButOrdered", hit.item.chineseName, hit.item.originalName))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Label(L("summary.conflicts"), systemImage: "exclamationmark.triangle.fill")
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
                        Text(L("summary.count", viewModel.cartCount))
                        Spacer()
                        if let total = viewModel.cartTotalText {
                            Text(L("summary.total", total))
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle(L("summary.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("summary.continue")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAnnotate()
                    dismiss()
                } label: {
                    Label(L("summary.annotate"), systemImage: "checkmark.circle.fill")
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
    /// East-Asian-language users don't look for gluten-free; hide the GF
    /// chip there and keep it for the other languages.
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
    @ObservedObject private var loc = Localization.shared
    /// Observed so recommendations re-filter the moment someone's
    /// restrictions change in Settings.
    @ObservedObject private var party = PartyStore.shared
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

    private struct Recommendation: Identifiable {
        let id: String // dish key
        let item: MenuItemEntry
        let reason: String
        let pageIndex: Int
    }

    /// Dishes the model singled out, minus anything someone at the table
    /// can't eat. Recommending a dish and then flagging it as a clash two
    /// screens later would be worse than not recommending it at all.
    ///
    /// The filter runs here, at render time, rather than at scan time:
    /// restrictions change after a scan is saved, and a recommendation baked
    /// into the file would go stale.
    private var recommendations: [Recommendation] {
        guard let scan = viewModel.scan else { return [] }
        let avoided = Set(party.members.flatMap(\.avoidedTags))
        var result: [Recommendation] = []
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                for (i, item) in section.items.enumerated() {
                    guard let reason = item.recommendation else { continue }
                    guard DietTag.tags(for: item).isDisjoint(with: avoided) else { continue }
                    result.append(Recommendation(
                        id: MenuScan.dishKey(page: p, section: s, item: i),
                        item: item, reason: reason, pageIndex: p
                    ))
                }
            }
        }
        return result
    }

    /// True when the scan HAS recommendations but every one of them clashes
    /// with someone's restrictions — worth saying out loud, otherwise the
    /// section just silently disappears and looks broken.
    private var allRecommendationsFiltered: Bool {
        guard let scan = viewModel.scan else { return false }
        let any = scan.pages.contains { page in
            page.sections.contains { $0.items.contains { $0.recommendation != nil } }
        }
        return any && recommendations.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if searchText.isEmpty {
                    if !recommendations.isEmpty {
                        Section {
                            ForEach(recommendations) { rec in
                                Button {
                                    withAnimation { proxy.scrollTo(rec.id, anchor: .center) }
                                } label: {
                                    RecommendationRow(
                                        recommendation: rec.item,
                                        reason: rec.reason,
                                        photo: photo(dishKey: rec.id, pageIndex: rec.pageIndex)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Label(L("list.recommended"), systemImage: "hand.thumbsup.fill")
                                .foregroundStyle(.orange)
                        }
                    } else if allRecommendationsFiltered {
                        Section {
                            Text(L("list.recommended.allFiltered"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            DishRow(
                                item: row.item,
                                inferredTags: DietTag.tags(for: row.item).map(\.rawValue),
                                photo: photo(for: row),
                                quantity: viewModel.quantity(of: row.id),
                                memberBreakdown: viewModel.orderLabels[row.id],
                                showGlutenFree: AppLanguage.from(code: viewModel.scan?.targetLanguage).showsGlutenFree,
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
                TextField(L("list.searchPlaceholder"), text: $searchText)
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
        photo(dishKey: row.id, pageIndex: row.pageIndex, box: row.item.photoBBox)
    }

    /// Printed photo cropped from the page when the menu has one, else the
    /// generated thumbnail. Shared by the list rows and the recommendations.
    private func photo(dishKey: String, pageIndex: Int, box: NormalizedRect? = nil) -> UIImage? {
        let printed = box ?? dishItem(dishKey)?.photoBBox
        if let printed, pageIndex < viewModel.scanImages.count {
            return viewModel.scanImages[pageIndex].crop(normalized: printed)
        }
        return viewModel.generatedImages[dishKey]
    }

    private func dishItem(_ key: String) -> MenuItemEntry? {
        guard let scan = viewModel.scan else { return nil }
        for (p, page) in scan.pages.enumerated() {
            for (s, section) in page.sections.enumerated() {
                for (i, item) in section.items.enumerated()
                where MenuScan.dishKey(page: p, section: s, item: i) == key {
                    return item
                }
            }
        }
        return nil
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
                var title = MenuItemEntry.bilingual(
                    translated: section.chineseTitle, original: section.originalTitle
                )
                if multiPage {
                    let pageLabel = L("page.number", p + 1)
                    title = title.isEmpty ? pageLabel : "\(pageLabel) · \(title)"
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
                    // Nothing to compare when the menu is already in the
                    // reader's language — printing the same name twice
                    // (bold, then orange) just looks broken.
                    if !item.translationIsRedundant {
                        Text(item.chineseName)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
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

/// One recommended dish: why it's worth ordering, above the usual name and
/// price. Tapping it scrolls to that dish in the list, where the stepper
/// lives — no second way to order the same thing.
private struct RecommendationRow: View {
    let recommendation: MenuItemEntry
    let reason: String
    let photo: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recommendation.originalName)
                        .font(.subheadline.weight(.semibold))
                    if let price = recommendation.price {
                        Text(price)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !recommendation.translationIsRedundant {
                    Text(recommendation.chineseName)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                // The reason is the whole point of the section, so it gets
                // the body weight and the name gets subheadline.
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

/// Horizontal picker of party members — new +1s go to the selected person.
private struct MemberChips: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @ObservedObject private var party = PartyStore.shared
    @ObservedObject private var loc = Localization.shared
    @State private var showAddMember = false
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(L("chips.forWhom"))
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
        .alert(L("chips.addMember"), isPresented: $showAddMember) {
            TextField(L("settings.member.name"), text: $newName)
            Button(L("common.add")) {
                PartyStore.shared.add(name: newName)
                newName = ""
            }
            Button(L("common.cancel"), role: .cancel) { newName = "" }
        } message: {
            Text(L("chips.addMemberNote"))
        }
    }
}
