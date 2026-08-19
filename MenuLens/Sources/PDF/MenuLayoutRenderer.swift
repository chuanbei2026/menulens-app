import UIKit

/// Shared wrapped-text drawing used by the layout and appendix renderers.
enum TextDraw {
    /// Draw a wrapped string; returns its height. `dryRun` only measures.
    @discardableResult
    static func text(
        _ string: String, font: UIFont, color: UIColor,
        at origin: CGPoint, maxWidth: CGFloat, dryRun: Bool = false
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        if !dryRun {
            attributed.draw(
                with: CGRect(origin: origin, size: CGSize(width: maxWidth, height: bounds.height.rounded(.up))),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            )
        }
        return bounds.height.rounded(.up)
    }
}

/// Draws one menu page's bilingual layout: the rectified photo as a clearly
/// readable watermark with translation cards overlaid at their own positions.
/// Deliberately NO photo crops or AI thumbnails here — the menu's own photos
/// already show through the watermark, and dish images live in the list view
/// and the PDF appendix. Used by both the in-app zoomable canvas and the
/// PDF's layout pages, so they always look identical.
struct MenuLayoutRenderer {
    let document: MenuDocument
    /// The rectified page photo (orientation already normalized).
    let image: UIImage
    let pageWidth: CGFloat

    var pageSize: CGSize {
        let aspect = image.size.height / max(image.size.width, 1)
        return CGSize(width: pageWidth, height: (pageWidth * aspect).rounded())
    }

    /// Render the full page into an image (for the zoomable canvas).
    func renderImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { _ in
            draw()
        }
    }

    /// Draw into the current UIKit graphics context (canvas image or PDF page).
    func draw() {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        UIColor.white.setFill()
        UIBezierPath(rect: pageRect).fill()
        image.draw(in: pageRect, blendMode: .normal, alpha: 0.38)

        // Section titles first (they are fixed obstacles for the cards).
        for title in sectionTitles() {
            TextDraw.text(
                title.text, font: .boldSystemFont(ofSize: 26), color: .black,
                at: title.rect.origin, maxWidth: title.rect.width
            )
        }

        for card in resolvedCards() {
            // A visibly displaced card gets a thin leader line back to its
            // anchor so the original menu line stays identifiable.
            if abs(card.rect.minY - card.anchor.y + 6) > 14 {
                UIColor.black.withAlphaComponent(0.22).setStroke()
                let leader = UIBezierPath()
                leader.move(to: card.anchor)
                leader.addLine(to: CGPoint(x: card.rect.minX + 10, y: card.rect.minY))
                leader.lineWidth = 1
                leader.stroke()
            }

            UIColor.white.withAlphaComponent(0.95).setFill()
            let bg = UIBezierPath(roundedRect: card.rect, cornerRadius: 8)
            bg.fill()
            UIColor.black.withAlphaComponent(0.12).setStroke()
            bg.stroke()

            _ = drawItemContent(
                card.item,
                at: CGPoint(x: card.rect.minX + 8, y: card.rect.minY + 6),
                maxWidth: card.rect.width - 16,
                dryRun: false
            )
        }
    }

    /// Which dish card sits under a normalized (0...1, top-left origin) point.
    func hitTest(normalizedPoint point: CGPoint) -> (section: Int, item: Int)? {
        let canvas = pageSize
        let p = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
        return resolvedCards().first { $0.rect.contains(p) }
            .map { ($0.sectionIndex, $0.itemIndex) }
    }

    // MARK: - Smart card placement (mutual exclusion)

    struct ResolvedCard {
        let sectionIndex: Int
        let itemIndex: Int
        let item: MenuItemEntry
        /// The item's original bbox origin on the page.
        let anchor: CGPoint
        /// Where the card actually landed after collision resolution.
        let rect: CGRect
    }

    private struct SectionTitle {
        let text: String
        let rect: CGRect
    }

    private func sectionTitles() -> [SectionTitle] {
        let canvas = pageSize
        return document.sections.compactMap { section in
            guard let bbox = section.bbox,
                  section.originalTitle != nil || section.chineseTitle != nil
            else { return nil }
            let origin = bbox.rect(in: canvas).origin
            let text = [section.originalTitle, section.chineseTitle]
                .compactMap { $0 }.joined(separator: "  ·  ")
            let maxWidth = canvas.width - origin.x - 20
            let height = TextDraw.text(
                text, font: .boldSystemFont(ofSize: 26), color: .black,
                at: origin, maxWidth: maxWidth, dryRun: true
            )
            let width = min(
                (text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26)]).width,
                maxWidth
            )
            return SectionTitle(text: text, rect: CGRect(x: origin.x, y: origin.y, width: width, height: height))
        }
    }

    /// Cards compete for space: sorted top-to-bottom, each card is pushed
    /// below whatever it collides with (section titles and already-placed
    /// cards) until it overlaps nothing. Pure downward motion, so the sweep
    /// always terminates. Two cards only "collide" when their horizontal
    /// overlap is substantial, which keeps two-column menus intact.
    func resolvedCards() -> [ResolvedCard] {
        let canvas = pageSize
        let gap: CGFloat = 6

        struct Pending {
            let sectionIndex: Int
            let itemIndex: Int
            let item: MenuItemEntry
            let anchor: CGPoint
            var rect: CGRect
        }

        var pending: [Pending] = []
        for (s, section) in document.sections.enumerated() {
            for (i, item) in section.items.enumerated() {
                let box = item.bbox.rect(in: canvas)
                let cursor = CGPoint(x: box.minX, y: box.minY)
                let maxWidth = min(max(box.width, 180), canvas.width - cursor.x - 12)
                let measured = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: true)
                pending.append(Pending(
                    sectionIndex: s, itemIndex: i, item: item,
                    anchor: cursor,
                    rect: CGRect(x: cursor.x - 8, y: cursor.y - 6, width: maxWidth + 16, height: measured + 12)
                ))
            }
        }
        pending.sort { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }

        func conflicts(_ a: CGRect, _ b: CGRect) -> Bool {
            guard a.insetBy(dx: 0, dy: -gap / 2).intersects(b) else { return false }
            let xOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            return xOverlap > min(a.width, b.width) * 0.25
        }

        var obstacles: [CGRect] = sectionTitles().map(\.rect)
        var placed: [ResolvedCard] = []
        for var card in pending {
            var iterations = 0
            var moved = true
            while moved, iterations < 64 {
                moved = false
                for obstacle in obstacles where conflicts(card.rect, obstacle) {
                    card.rect.origin.y = obstacle.maxY + gap
                    moved = true
                }
                iterations += 1
            }
            // Keep the card on the page even if the sweep ran out of room.
            card.rect.origin.y = min(card.rect.origin.y, canvas.height - card.rect.height - 4)
            obstacles.append(card.rect)
            placed.append(ResolvedCard(
                sectionIndex: card.sectionIndex, itemIndex: card.itemIndex,
                item: card.item, anchor: card.anchor, rect: card.rect
            ))
        }
        return placed
    }

    /// Draws (or just measures) one item's stacked content:
    /// original name — Chinese name + price — Chinese description.
    @discardableResult
    private func drawItemContent(_ item: MenuItemEntry, at origin: CGPoint, maxWidth: CGFloat, dryRun: Bool) -> CGFloat {
        var y = origin.y

        y += TextDraw.text(
            item.originalName, font: .boldSystemFont(ofSize: 20), color: .black,
            at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
        ) + 4

        var nameLine = item.chineseName
        if let price = item.price { nameLine += "   \(price)" }
        y += TextDraw.text(
            nameLine, font: .systemFont(ofSize: 17, weight: .medium),
            color: UIColor(red: 0.72, green: 0.23, blue: 0.11, alpha: 1),
            at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
        )

        if let zhDesc = item.chineseDescription {
            y += 3
            y += TextDraw.text(
                zhDesc, font: .systemFont(ofSize: 13), color: .darkGray,
                at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
            )
        }
        return y - origin.y
    }
}
