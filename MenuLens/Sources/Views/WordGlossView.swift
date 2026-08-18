import SwiftUI

/// Interlinear word-by-word gloss: for each token, the foreign word on top,
/// optional romanization in the middle, Chinese meaning at the bottom.
/// Tokens flow horizontally and wrap like text.
struct WordGlossView: View {
    let words: [WordGloss]
    var compact = false

    var body: some View {
        FlowLayout(spacing: compact ? 6 : 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                VStack(spacing: 1) {
                    Text(word.text)
                        .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                    if let roman = word.romanization, !roman.isEmpty {
                        Text(roman)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(word.chinese)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray6))
                )
            }
        }
    }
}

/// Minimal wrapping flow layout (iOS 16+ `Layout` protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(proposal: proposal, subviews: subviews).placements
        for (subview, position) in zip(subviews, placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, placements: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var placements: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return (CGSize(width: totalWidth, height: y + rowHeight), placements)
    }
}
