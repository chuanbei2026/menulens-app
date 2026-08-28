import SwiftUI

/// Saved scans, newest first. Tap to reopen, swipe left to delete.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    let onOpen: (MenuScan) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loc = Localization.shared
    /// Scan being renamed, plus the draft text. Held here rather than in the
    /// row so the alert survives the list re-rendering after `refresh()`.
    @State private var renaming: MenuScan?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Group {
                if history.scans.isEmpty {
                    ContentUnavailableView(
                        L("history.empty.title"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(L("history.empty.body"))
                    )
                } else {
                    List {
                        ForEach(history.scans) { scan in
                            Button {
                                onOpen(scan)
                                dismiss()
                            } label: {
                                HistoryRow(scan: scan)
                            }
                            .buttonStyle(.plain)
                            // Renaming is the common case for a scan the model
                            // found no name on, so it gets the leading edge
                            // (a full swipe there won't destroy anything) and
                            // delete keeps its usual trailing position.
                            .swipeActions(edge: .leading) {
                                Button {
                                    draftName = scan.restaurantName ?? ""
                                    renaming = scan
                                } label: {
                                    Label(L("history.rename"), systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button {
                                    draftName = scan.restaurantName ?? ""
                                    renaming = scan
                                } label: {
                                    Label(L("history.rename"), systemImage: "pencil")
                                }
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                history.delete(history.scans[offset])
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("history.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                if !history.scans.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
        .onAppear { history.refresh() }
        .alert(L("history.rename"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField(L("history.rename.placeholder"), text: $draftName)
                .textInputAutocapitalization(.words)
            Button(L("common.save")) {
                if let scan = renaming { history.rename(scan, to: draftName) }
                renaming = nil
            }
            Button(L("common.cancel"), role: .cancel) { renaming = nil }
        } message: {
            Text(L("history.rename.prompt"))
        }
    }
}

private struct HistoryRow: View {
    let scan: MenuScan
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.restaurantName ?? L("history.untitled"))
                .font(.headline)
            Text(L("history.meta", scan.sourceLanguageChinese, scan.allItems.count, scan.pages.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Date format follows the chosen language too, not the device.
            Text(scan.createdAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(loc.locale)
            ))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
