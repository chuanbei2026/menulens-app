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

        let canvas = pageSize
        for section in document.sections {
            if let bbox = section.bbox, section.originalTitle != nil || section.chineseTitle != nil {
                let origin = bbox.rect(in: canvas).origin
                let title = [section.originalTitle, section.chineseTitle]
                    .compactMap { $0 }.joined(separator: "  ·  ")
                TextDraw.text(
                    title, font: .boldSystemFont(ofSize: 26), color: .black,
                    at: origin, maxWidth: canvas.width - origin.x - 20
                )
            }
            for item in section.items {
                drawItemCard(item, in: canvas)
            }
        }
    }

    /// Which dish card sits under a normalized (0...1, top-left origin) point.
    func hitTest(normalizedPoint point: CGPoint) -> (section: Int, item: Int)? {
        let canvas = pageSize
        let p = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
        for (sectionIndex, section) in document.sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                if cardRect(for: item, in: canvas).contains(p) {
                    return (sectionIndex, itemIndex)
                }
            }
        }
        return nil
    }

    // MARK: - Cards

    private func cardRect(for item: MenuItemEntry, in canvas: CGSize) -> CGRect {
        let box = item.bbox.rect(in: canvas)
        let cursor = CGPoint(x: box.minX, y: box.minY)
        let maxWidth = min(max(box.width, 180), canvas.width - cursor.x - 12)
        let measured = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: true)
        return CGRect(x: cursor.x - 8, y: cursor.y - 6, width: maxWidth + 16, height: measured + 12)
    }

    private func drawItemCard(_ item: MenuItemEntry, in canvas: CGSize) {
        let card = cardRect(for: item, in: canvas)

        UIColor.white.withAlphaComponent(0.95).setFill()
        let bg = UIBezierPath(roundedRect: card, cornerRadius: 8)
        bg.fill()
        UIColor.black.withAlphaComponent(0.12).setStroke()
        bg.stroke()

        _ = drawItemContent(
            item,
            at: CGPoint(x: card.minX + 8, y: card.minY + 6),
            maxWidth: card.width - 16,
            dryRun: false
        )
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
