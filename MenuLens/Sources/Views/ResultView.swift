import SwiftUI

/// Result screen with three views:
///
/// - **Status** — one row per photographed page (translating, done, failed
///   with a retry) and the dish pictures' progress. Where a multi-page scan
///   opens while its pages are still coming in.
/// - **Canvas** — one zoomable canvas per photographed page (pinch to zoom,
///   double-tap to magnify). Cards carry no images; tapping a card jumps to
///   that dish in the list view.
/// - **List** — native iOS list of every dish (with cropped/AI images),
///   searchable in the translation or the menu's original language.
///
/// On a phone the three are swiped through as ONE pager — status, each
/// canvas page, list — so swiping past the last menu page reaches the list
/// (a pager of pages nested in a pager of views would swallow the swipe);
/// the bottom bar jumps between them. On a landscape iPad they stand side
/// by side as columns.
struct ResultView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onRestart: () -> Void
    @ObservedObject private var loc = Localization.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// One stop of the phone pager.
    enum Pane: Hashable {
        case status
        case canvas(Int)
        case list

        var tab: ResultTab {
            switch self {
            case .status: .status
            case .canvas: .canvas
            case .list: .list
            }
        }
    }

    @State private var pane: Pane
    /// The canvas page last looked at — where the canvas tab returns to.
    @State private var canvasPage = 0
    /// The user switched views (tab, swipe, a status row) since the scan
    /// started: no more automatic switching.
    @State private var userChoseView = false
    /// Dish key the list should scroll to (set by tapping a canvas card).
    @State private var listTarget: String?
    @State private var showShop = false
    @State private var showOrderSummary =
        ProcessInfo.processInfo.arguments.contains("-showSummary")
    /// Canvas shows the untouched original menu (order marks kept) — for
    /// handing the phone to a server.
    @State private var showOriginal =
        ProcessInfo.processInfo.arguments.contains("-showOriginal")

    init(viewModel: AnalysisViewModel, onRestart: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onRestart = onRestart
        let args = ProcessInfo.processInfo.arguments
        let initial: ResultTab = args.contains("-listMode") ? .list
            : args.contains("-statusMode") ? .status
            : ResultTab.initial(
                pageCount: viewModel.scan?.pages.count ?? 0,
                receivingPages: viewModel.isReceivingPages
            )
        let firstReady = viewModel.scan?.pages.indices.first { !viewModel.pendingPages.contains($0) } ?? 0
        _canvasPage = State(initialValue: firstReady)
        let pane: Pane = switch initial {
        case .status: .status
        case .canvas: .canvas(firstReady)
        case .list: .list
        }
        _pane = State(initialValue: pane)
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = sizeClass == .regular && geometry.size.width > geometry.size.height
            Group {
                if columns {
                    columnsLayout(width: geometry.size.width)
                } else {
                    pager
                }
            }
            .safeAreaInset(edge: .top) { noticeBanner }
            .safeAreaInset(edge: .bottom) { bottomBars(columns: columns) }
        }
        .sheet(isPresented: $showShop) { ShopView() }
        .sheet(isPresented: $showOrderSummary) {
            OrderSummaryView(viewModel: viewModel) {
                show(.canvas(canvasPage), byUser: false)
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
                // The PDF is rendered once every page is in.
                if !viewModel.isReceivingPages, let url = currentShareURL() {
                    ShareLink(item: url) {
                        Label(L("result.exportPDF"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        // Every page has finished: off the status view to the canvas, once,
        // unless the user has picked a view themselves.
        .onChange(of: viewModel.isReceivingPages) { wasReceiving, receiving in
            guard wasReceiving, !receiving,
                  let next = ResultTab.afterAllPagesFinished(
                    current: pane.tab, userChoseView: userChoseView,
                    anyPageDone: viewModel.pageStates.contains { if case .done = $0 { true } else { false } }
                  ),
                  next == .canvas
            else { return }
            userChoseView = true // once per scan
            show(.canvas(firstReadyPage(preferring: canvasPage)), byUser: false)
        }
        // Pages land in any order. While they do, don't leave the reader
        // looking at a placeholder when another page is ready.
        .onChange(of: viewModel.pendingPages, initial: true) {
            guard viewModel.isReceivingPages, case let .canvas(page) = pane,
                  viewModel.pendingPages.union(viewModel.failedPages).contains(page)
            else { return }
            let ready = firstReadyPage(preferring: page)
            if ready != page { show(.canvas(ready), byUser: false) }
        }
    }

    // MARK: - Layouts

    /// Phone (and portrait iPad): status · canvas pages · list, one swipe apart.
    private var pager: some View {
        let selection = Binding<Pane>(
            get: { pane },
            set: { show($0, byUser: true) } // only the user swipes
        )
        let pageCount = viewModel.scan?.pages.count ?? 0
        return TabView(selection: selection) {
            PageStatusView(viewModel: viewModel) { page in
                show(.canvas(page), byUser: true)
            }
            .tag(Pane.status)
            ForEach(0 ..< pageCount, id: \.self) { index in
                CanvasSlot(viewModel: viewModel, index: index, showOriginal: showOriginal,
                           onSelectDish: openInList)
                    .padding(.bottom, pageCount > 1 ? 30 : 0)
                    .background(Color(.systemGray5))
                    .overlay(alignment: .topTrailing) { originalToggle }
                    .overlay(alignment: .bottom) {
                        if pageCount > 1 { pageDots(count: pageCount, current: index) }
                    }
                    .tag(Pane.canvas(index))
            }
            DishListView(viewModel: viewModel, scrollTarget: $listTarget)
                .tag(Pane.list)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.keyboard)
    }

    /// Landscape iPad: all three at once — status narrow, canvas wide,
    /// list medium.
    private func columnsLayout(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            PageStatusView(viewModel: viewModel) { page in
                canvasPage = page
            }
            .frame(width: min(320, width * 0.24))
            Divider()
            MenuCanvasView(viewModel: viewModel, page: $canvasPage, showOriginal: $showOriginal) { dishKey in
                listTarget = dishKey
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(spacing: 0) {
                DishListView(viewModel: viewModel, scrollTarget: $listTarget)
                MemberChips(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
            }
            .frame(width: min(420, width * 0.32))
        }
    }

    private func show(_ next: Pane, byUser: Bool) {
        if byUser { userChoseView = true }
        if case let .canvas(page) = next { canvasPage = page }
        pane = next
    }

    private func openInList(_ dishKey: String) {
        listTarget = dishKey
        show(.list, byUser: true)
    }

    /// `preferring` if it is in, else the first page that is.
    private func firstReadyPage(preferring page: Int) -> Int {
        let waiting = viewModel.pendingPages.union(viewModel.failedPages)
        guard waiting.contains(page) else { return page }
        return viewModel.scan?.pages.indices.first { !waiting.contains($0) } ?? page
    }

    // MARK: - Chrome

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = viewModel.notice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.footnote)
                Spacer()
                if viewModel.outOfCredits {
                    Button(L("shop.buy")) { showShop = true }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
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

    private func bottomBars(columns: Bool) -> some View {
        VStack(spacing: 0) {
            // The status view says all of this itself, page by page.
            if !columns, pane != .status {
                if viewModel.isReceivingPages, let scan = viewModel.scan {
                    // Pages arrive one at a time; say how many are still out.
                    let total = scan.pages.count
                    let ready = total - viewModel.pendingPages.count - viewModel.failedPages.count
                    Button {
                        show(.status, byUser: true)
                    } label: {
                        VStack(spacing: 6) {
                            HStack {
                                Label(L("result.pagesProgress", ready, total), systemImage: "text.viewfinder")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                            ProgressView(value: Double(ready), total: Double(total))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial)
                    }
                    .buttonStyle(.plain)
                }

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
            }

            if !columns, pane == .list {
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

            // Three big view-switch buttons across the very tail of the screen.
            if !columns {
                HStack(spacing: 0) {
                    viewTab(.status, icon: "square.stack", selectedIcon: "square.stack.fill",
                            title: L("result.tab.status"), busy: viewModel.isReceivingPages)
                    viewTab(.canvas(canvasPage), icon: "doc.richtext", selectedIcon: "doc.richtext.fill",
                            title: L("result.tab.canvas"))
                    viewTab(.list, icon: "list.bullet", selectedIcon: "list.bullet",
                            title: L("result.tab.list"))
                }
                .background(.regularMaterial)
            }
        }
    }

    /// One third of the bottom view-switch bar.
    private func viewTab(_ target: Pane, icon: String, selectedIcon: String, title: String,
                         busy: Bool = false) -> some View {
        let selected = pane.tab == target.tab
        return Button {
            show(target, byUser: true)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? selectedIcon : icon)
                    .font(.title3)
                    .overlay(alignment: .topTrailing) {
                        // Pages still out: a small dot on the status tab.
                        if busy, !selected {
                            Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 5, y: -2)
                        }
                    }
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab.\(target.tab)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Hand-to-server switch: the original menu, order marks kept.
    private var originalToggle: some View {
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

    /// Which menu page this is, under the canvas (tap a dot to jump).
    private func pageDots(count: Int, current: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0 ..< count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { show(.canvas(index), byUser: true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 4)
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

// MARK: - Status view (one row per photographed page)

private struct PageStatusView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let onOpenPage: (Int) -> Void
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        let states = viewModel.pageStates
        let done = states.filter { if case .done = $0 { true } else { false } }.count
        List {
            Section {
                ForEach(states.indices, id: \.self) { index in
                    row(index, state: states[index])
                }
            } header: {
                Text(L("progress.pages.fraction", done, states.count))
            }
            Section {
                imagesRow
            } header: {
                Text(L("progress.stage.images"))
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func row(_ index: Int, state: PageState) -> some View {
        let content = HStack(spacing: 12) {
            thumbnail(index)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("page.number", index + 1))
                    .font(.headline)
                detail(index, state: state)
            }
            Spacer(minLength: 0)
            if case .done = state {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        if case .done = state {
            Button { onOpenPage(index) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func thumbnail(_ index: Int) -> some View {
        Group {
            if index < viewModel.scanImages.count {
                Image(uiImage: viewModel.scanImages[index])
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray5)
            }
        }
        .frame(width: 52, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 0.5))
    }

    @ViewBuilder
    private func detail(_ index: Int, state: PageState) -> some View {
        switch state {
        case .queued:
            Label(L("status.queued"), systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case let .translating(since):
            let total = viewModel.pageLineTotals[index] ?? 0
            let done = viewModel.pageLinesDone[index] ?? 0
            if done > 0, total > 0 {
                // The model streams its answer: an honest line counter.
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                    Text(L("progress.lines.fraction", min(done, total), total))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                // Silent until the whole answer arrives (Bedrock, reasoning
                // models): a spinner and the clock.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(total > 0
                             ? L("progress.linesElapsed", total, max(0, Int(context.date.timeIntervalSince(since))))
                             : L("progress.reading"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .done(dishes):
            Label(L("status.dishes", dishes), systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(L("result.pageFailed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if viewModel.canRetryPages {
                    Button {
                        viewModel.retryPage(index)
                    } label: {
                        Label(L("status.retryPage"), systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var imagesRow: some View {
        let progress = viewModel.pipeline
        HStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                if !RegionStore.shared.catalog.images {
                    Text(L("progress.imagesRegion")).foregroundStyle(.secondary)
                } else if !viewModel.generateDishImages {
                    Text(L("progress.imagesOff")).foregroundStyle(.secondary)
                } else if let total = progress?.imagesTotal {
                    let done = progress?.imagesDone ?? 0
                    if total > 0 {
                        ProgressView(value: Double(min(done, total)), total: Double(total))
                        Text(L("progress.images.fraction", min(done, total), total))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("progress.menuHasPhotos")).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("progress.waitTranslate")).foregroundStyle(.secondary)
                }
                if let reason = viewModel.imagesStopReason {
                    Text(L("notice.imagesStopped", reason))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Canvas

/// One photographed page on the canvas: its translated canvas once in, the
/// dimmed photo while it is out (or failed, with a retry).
private struct CanvasSlot: View {
    @ObservedObject var viewModel: AnalysisViewModel
    let index: Int
    let showOriginal: Bool
    let onSelectDish: (String) -> Void

    var body: some View {
        if let scan = viewModel.scan, index < scan.pages.count, index < viewModel.scanImages.count {
            if viewModel.pendingPages.contains(index) || viewModel.failedPages.contains(index) {
                PendingPage(
                    image: viewModel.scanImages[index],
                    failed: viewModel.failedPages.contains(index),
                    onRetry: viewModel.canRetryPages ? { viewModel.retryPage(index) } : nil
                )
            } else {
                CanvasPage(
                    document: scan.pages[index],
                    pageIndex: index,
                    image: viewModel.scanImages[index],
                    highlights: viewModel.highlightTotals,
                    orderLabels: viewModel.orderLabels,
                    showOriginal: showOriginal,
                    onSelectDish: onSelectDish
                )
            }
        }
    }
}

/// The canvas column on a landscape iPad: its own pager of menu pages.
private struct MenuCanvasView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @Binding var page: Int
    @Binding var showOriginal: Bool
    let onSelectDish: (String) -> Void
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        if let scan = viewModel.scan {
            let multiPage = scan.pages.count > 1
            TabView(selection: $page) {
                ForEach(0 ..< scan.pages.count, id: \.self) { index in
                    CanvasSlot(viewModel: viewModel, index: index, showOriginal: showOriginal,
                               onSelectDish: onSelectDish)
                        // Keep the page dots clear (multi-page only).
                        .padding(.bottom, multiPage ? 34 : 0)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: multiPage ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(Color(.systemGray5))
            .overlay(alignment: .topTrailing) {
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

/// A page of a scan still coming in: its photo, dimmed, with what is
/// happening to it. Replaced by a `CanvasPage` the moment it lands.
private struct PendingPage: View {
    let image: UIImage
    let failed: Bool
    var onRetry: (() -> Void)?

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .opacity(0.35)
            .overlay {
                VStack(spacing: 10) {
                    if failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(L(failed ? "result.pageFailed" : "result.pageTranslating"))
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                    if failed, let onRetry {
                        Button(action: onRetry) {
                            Label(L("status.retryPage"), systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func photo(for row: Row) -> DishPhoto? {
        photo(dishKey: row.id, pageIndex: row.pageIndex, box: row.item.photoBBox)
    }

    /// Printed photo cropped from the page when the menu has one, else the
    /// generated thumbnail (flagged, so it gets the AI badge). Shared by the
    /// list rows and the recommendations.
    private func photo(dishKey: String, pageIndex: Int, box: NormalizedRect? = nil) -> DishPhoto? {
        let printed = box ?? dishItem(dishKey)?.photoBBox
        if let printed, pageIndex < viewModel.scanImages.count {
            return viewModel.scanImages[pageIndex].crop(normalized: printed)
                .map { DishPhoto(image: $0, generated: false) }
        }
        return viewModel.generatedImages[dishKey].map { DishPhoto(image: $0, generated: true) }
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

/// A dish thumbnail and where it came from: a crop of the photo printed on
/// the menu, or an AI-generated picture (which is labelled as such).
private struct DishPhoto {
    let image: UIImage
    let generated: Bool
}

private struct DishRow: View {
    let item: MenuItemEntry
    let inferredTags: [String]
    let photo: DishPhoto?
    let quantity: Int
    let memberBreakdown: String?
    let showGlutenFree: Bool
    let onPlus: () -> Void
    let onMinus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let photo {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if photo.generated { AIBadge() }
                    }
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
    let photo: DishPhoto?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let photo {
                Image(uiImage: photo.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if photo.generated { AIBadge() }
                    }
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
