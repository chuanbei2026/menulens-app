import SwiftUI

/// Saved scans, newest first. Tap to reopen, swipe left to delete.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    let onOpen: (MenuScan) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loc = Localization.shared

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
