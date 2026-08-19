import SwiftUI

/// Stage-by-stage progress shown while a scan is being processed:
/// one row per pipeline stage (translate / layout / thumbnails), each with
/// its own live progress, so a 1–2 minute wait never looks stuck.
struct AnalysisProgressView: View {
    @ObservedObject var viewModel: AnalysisViewModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            // Queued pages, dimmed while working.
            if !viewModel.pickedImages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.pickedImages.prefix(5).enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if viewModel.pickedImages.count > 5 {
                        Text("+\(viewModel.pickedImages.count - 5)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(0.55)
            }

            if let progress = viewModel.pipeline {
                VStack(spacing: 18) {
                    rectifyRow(progress)
                    translateRow(progress)
                    layoutRow(progress)
                    imagesRow(progress)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal)
            }

            Text("排版完成后立即可以查看，配图会在后台继续补齐")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    // MARK: - Stage rows

    private func rectifyRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "perspective",
            title: "矫正照片",
            status: progress.rectifyDone >= progress.rectifyTotal
                ? .done("\(progress.rectifyTotal) 页")
                : .running(
                    fraction: Double(progress.rectifyDone) / Double(max(progress.rectifyTotal, 1)),
                    label: "\(progress.rectifyDone)/\(progress.rectifyTotal) 页"
                )
        )
    }

    private func translateRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "character.book.closed",
            title: "翻译文字",
            status: progress.rectifyDone < progress.rectifyTotal
                ? .pending("等待矫正完成")
                : progress.pagesDone >= progress.pagesTotal
                ? .done("\(progress.pagesTotal) 页")
                : .running(
                    fraction: Double(progress.pagesDone) / Double(max(progress.pagesTotal, 1)),
                    label: "\(progress.pagesDone)/\(progress.pagesTotal) 页"
                )
        )
    }

    private func layoutRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "doc.richtext",
            title: "排版布局",
            status: {
                switch progress.layoutState {
                case .waiting: return .pending("等待翻译完成")
                case .running: return .running(fraction: nil, label: "排版中…")
                case .done: return .done(nil)
                }
            }()
        )
    }

    private func imagesRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "photo.artframe",
            title: "生成配图",
            status: {
                if !viewModel.generateDishImages {
                    return .pending("已在设置中关闭")
                }
                guard let total = progress.imagesTotal else {
                    return .pending("等待翻译完成")
                }
                if total == 0 { return .done("菜单已有照片") }
                if progress.imagesDone >= total { return .done("\(total) 张") }
                return .running(
                    fraction: Double(progress.imagesDone) / Double(total),
                    label: "\(progress.imagesDone)/\(total) 张"
                )
            }()
        )
    }
}

/// One pipeline stage: icon + title on the left, live state on the right,
/// and a progress bar underneath while the stage is running.
struct StageRow: View {
    enum Status: Equatable {
        case pending(String)
        /// fraction == nil renders an indeterminate spinner.
        case running(fraction: Double?, label: String)
        case done(String?)
    }

    let icon: String
    let title: String
    let status: Status

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 26)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                trailing
            }
            if case let .running(fraction, _) = status {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .controlSize(.small)
                }
            }
        }
        .animation(.default, value: status)
    }

    private var iconColor: Color {
        switch status {
        case .pending: return .secondary
        case .running: return .blue
        case .done: return .green
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case let .pending(note):
            Text(note)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        case let .running(_, label):
            Text(label)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        case let .done(note):
            HStack(spacing: 5) {
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
