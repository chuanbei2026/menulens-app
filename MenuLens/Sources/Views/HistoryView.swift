import SwiftUI

/// Saved scans, newest first. Tap to reopen, swipe left to delete.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    let onOpen: (MenuScan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.scans.isEmpty {
                    ContentUnavailableView(
                        "还没有记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("识别过的菜单会自动保存在这里，方便再去同一家餐厅时直接查看。")
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
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scan.restaurantName ?? "未命名菜单")
                .font(.headline)
            Text("\(scan.sourceLanguageChinese) · \(scan.allItems.count) 道菜 · \(scan.pages.count) 页")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
