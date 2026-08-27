import SwiftUI

/// Stage-by-stage progress shown while a scan is being processed:
/// one row per pipeline stage (translate / layout / thumbnails), each with
/// its own live progress, so a 1–2 minute wait never looks stuck.
struct AnalysisProgressView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @ObservedObject private var loc = Localization.shared

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
                TimelineView(.periodic(from: .now, by: 1)) { _ in
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
            }

            Text(L("progress.note"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    // MARK: - Stage rows

    private func rectifyRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "perspective",
            title: L("progress.stage.rectify"),
            status: progress.rectifyDone >= progress.rectifyTotal
                ? .done(L("progress.pages", progress.rectifyTotal))
                : .running(
                    fraction: Double(progress.rectifyDone) / Double(max(progress.rectifyTotal, 1)),
                    label: L("progress.pages.fraction", progress.rectifyDone, progress.rectifyTotal)
                )
        )
    }

    /// Reasoning models are silent for most of the request, so show the
    /// clock (and what we already know) rather than a frozen counter.
    private func thinkingLabel(_ progress: PipelineProgress) -> String {
        guard progress.linesTotal > 0 else { return L("progress.reading") }
        guard let started = progress.translateStartedAt else {
            return L("progress.waitingModel", progress.linesTotal)
        }
        let seconds = max(0, Int(Date().timeIntervalSince(started)))
        return L("progress.linesElapsed", progress.linesTotal, seconds)
    }

    private func translateRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "character.book.closed",
            title: L("progress.stage.translate"),
            status: progress.rectifyDone < progress.rectifyTotal
                ? .pending(L("progress.waitRectify"))
                : progress.pagesDone >= progress.pagesTotal
                ? .done(L("progress.pages", progress.pagesTotal))
                : progress.linesDone > 0
                // Line-level movement: the model streams its answer, and the
                // OCR inventory gives us an honest denominator.
                ? .running(
                    fraction: Double(progress.linesDone) / Double(max(progress.linesTotal, 1)),
                    label: L("progress.lines.fraction", progress.linesDone, progress.linesTotal)
                )
                : .running(fraction: nil, label: thinkingLabel(progress))
        )
    }

    private func layoutRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "doc.richtext",
            title: L("progress.stage.layout"),
            status: {
                switch progress.layoutState {
                case .waiting: return .pending(L("progress.waitTranslate"))
                case .running: return .running(fraction: nil, label: L("progress.layoutRunning"))
                case .done: return .done(nil)
                }
            }()
        )
    }

    private func imagesRow(_ progress: PipelineProgress) -> some View {
        StageRow(
            icon: "photo.artframe",
            title: L("progress.stage.images"),
            status: {
                if !viewModel.generateDishImages {
                    return .pending(L("progress.imagesOff"))
                }
                guard let total = progress.imagesTotal else {
                    return .pending(L("progress.waitTranslate"))
                }
                if total == 0 { return .done(L("progress.menuHasPhotos")) }
                if progress.imagesDone >= total { return .done(L("progress.images", total)) }
                return .running(
                    fraction: Double(progress.imagesDone) / Double(total),
                    label: L("progress.images.fraction", progress.imagesDone, total)
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
