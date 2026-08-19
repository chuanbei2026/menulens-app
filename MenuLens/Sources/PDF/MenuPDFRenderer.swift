import UIKit

/// Renders an analyzed menu scan into a large PDF with two parts:
///
/// 1. **Layout pages** — for every photographed menu page, a big PDF page with
///    the same aspect ratio as that photo. The original photo is drawn faintly
///    underneath for spatial context, and every item's translated card is
///    drawn *at its own bbox position*, so the page reads like the original
///    menu, just bilingual.
/// 2. **Appendix pages** — one readable card per dish across all pages
///    (cropped 配图 + full word-by-word gloss), paginated, guaranteed legible
///    even when the original layout is cramped.
struct MenuPDFRenderer {
    let scan: MenuScan
    /// Photographed pages matching `scan.pages` by index. A missing image
    /// degrades gracefully: no background/crops for that page.
    let images: [UIImage]
    /// AI-generated dish thumbnails keyed by MenuScan.dishKey; used in the
    /// appendix for dishes whose menu shows no printed photo.
    var generatedImages: [String: UIImage] = [:]

    /// Width of a layout page in points. ~3x A4 width => "a big PDF".
    private let layoutPageWidth: CGFloat = 1600
    private let appendixPageSize = CGSize(width: 1240, height: 1754)

    func renderPDF() -> Data {
        let firstImage = images.first?.normalizedOrientation()
        let firstAspect = firstImage.map { $0.size.height / max($0.size.width, 1) } ?? 1.4
        let initialBounds = CGRect(
            x: 0, y: 0,
            width: layoutPageWidth,
            height: (layoutPageWidth * firstAspect).rounded()
        )

        let renderer = UIGraphicsPDFRenderer(bounds: initialBounds)
        return renderer.pdfData { ctx in
            for (index, document) in scan.pages.enumerated() {
                guard index < images.count else { break }
                drawLayoutPage(
                    ctx: ctx,
                    pageIndex: index,
                    document: document,
                    image: images[index].normalizedOrientation()
                )
            }
            drawAppendixPages(ctx: ctx)
        }
    }

    // MARK: - Part 1: same-layout pages (one per photographed page)

    private func drawLayoutPage(ctx: UIGraphicsPDFRendererContext, pageIndex: Int, document: MenuDocument, image: UIImage) {
        let aspect = image.size.height / max(image.size.width, 1)
        let pageRect = CGRect(
            x: 0, y: 0,
            width: layoutPageWidth,
            height: (layoutPageWidth * aspect).rounded()
        )
        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
        UIColor.white.setFill()
        ctx.fill(pageRect)

        // The (rectified) original menu as a clearly readable base layer —
        // translations overlay it in place, like a bilingual edition.
        image.draw(in: pageRect, blendMode: .normal, alpha: 0.38)

        let canvas = pageRect.size

        for (sectionIndex, section) in document.sections.enumerated() {
            if let bbox = section.bbox, section.originalTitle != nil || section.chineseTitle != nil {
                let origin = bbox.rect(in: canvas).origin
                let title = [section.originalTitle, section.chineseTitle]
                    .compactMap { $0 }.joined(separator: "  ·  ")
                draw(
                    title,
                    font: .boldSystemFont(ofSize: 26),
                    color: .black,
                    at: origin,
                    maxWidth: canvas.width - origin.x - 20
                )
            }

            for (itemIndex, item) in section.items.enumerated() {
                if let photoBox = item.photoBBox,
                   let cropped = image.crop(normalized: photoBox) {
                    // Clamp to the page so oversized model boxes can't bleed off.
                    let target = photoBox.rect(in: canvas).intersection(pageRect)
                    if !target.isNull, target.width > 8, target.height > 8 {
                        cropped.draw(in: target)
                        UIColor.black.withAlphaComponent(0.15).setStroke()
                        UIBezierPath(rect: target).stroke()
                    }
                }
                let key = MenuScan.dishKey(page: pageIndex, section: sectionIndex, item: itemIndex)
                let thumb = item.photoBBox == nil ? generatedImages[key] : nil
                drawItemCard(item, thumb: thumb, in: canvas)
            }
        }
    }

    /// A translated card pinned at the item's own bbox position; an optional
    /// AI-generated thumbnail is placed beside it (right side preferred,
    /// left as fallback, skipped when neither fits).
    private func drawItemCard(_ item: MenuItemEntry, thumb: UIImage?, in canvas: CGSize) {
        let box = item.bbox.rect(in: canvas)
        let width = max(box.width, 180)
        let cursor = CGPoint(x: box.minX, y: box.minY)
        let maxWidth = min(width, canvas.width - cursor.x - 12)

        // Measure content height first so the card background fits.
        let measured = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: true)
        let cardRect = CGRect(x: cursor.x - 8, y: cursor.y - 6, width: maxWidth + 16, height: measured + 12)

        UIColor.white.withAlphaComponent(0.95).setFill()
        let bg = UIBezierPath(roundedRect: cardRect, cornerRadius: 8)
        bg.fill()
        UIColor.black.withAlphaComponent(0.12).setStroke()
        bg.stroke()

        _ = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: false)

        if let thumb {
            let side = min(max(cardRect.height, 110), 170)
            var frame = CGRect(x: cardRect.maxX + 14, y: cardRect.minY, width: side, height: side)
            if frame.maxX > canvas.width - 8 {
                frame.origin.x = cardRect.minX - side - 14
            }
            if frame.minX >= 8, frame.maxY <= canvas.height - 8 {
                let clip = UIBezierPath(roundedRect: frame, cornerRadius: 10)
                if let cg = UIGraphicsGetCurrentContext() {
                    cg.saveGState()
                    clip.addClip()
                    thumb.draw(in: frame)
                    cg.restoreGState()
                }
                UIColor.black.withAlphaComponent(0.15).setStroke()
                clip.stroke()
            }
        }
    }

    /// Draws (or just measures, when `dryRun`) one item's stacked content:
    /// original name — interlinear gloss — Chinese name + price — description.
    /// Returns total height.
    @discardableResult
    private func drawItemContent(_ item: MenuItemEntry, at origin: CGPoint, maxWidth: CGFloat, dryRun: Bool) -> CGFloat {
        var y = origin.y

        y += draw(
            item.originalName, font: .boldSystemFont(ofSize: 20), color: .black,
            at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
        ) + 4

        var nameLine = item.chineseName
        if let price = item.price { nameLine += "   \(price)" }
        y += draw(
            nameLine, font: .systemFont(ofSize: 17, weight: .medium),
            color: UIColor(red: 0.72, green: 0.23, blue: 0.11, alpha: 1),
            at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
        )

        if let zhDesc = item.chineseDescription {
            y += 3
            y += draw(
                zhDesc, font: .systemFont(ofSize: 13), color: .darkGray,
                at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun
            )
        }
        return y - origin.y
    }

    // MARK: - Part 2: appendix (one readable card per dish, all pages merged)

    private func drawAppendixPages(ctx: UIGraphicsPDFRendererContext) {
        let page = CGRect(origin: .zero, size: appendixPageSize)
        let margin: CGFloat = 70
        let contentWidth = page.width - 2 * margin
        var y: CGFloat = .infinity // force a new page before the first card

        func newPage() {
            ctx.beginPage(withBounds: page, pageInfo: [:])
            UIColor.white.setFill()
            ctx.fill(page)
            var header = "菜品对照 · \(scan.sourceLanguageChinese) → 中文"
            if let name = scan.restaurantName { header = "\(name) — " + header }
            draw(header, font: .boldSystemFont(ofSize: 30), color: .black,
                 at: CGPoint(x: margin, y: 46), maxWidth: contentWidth)
            y = 110
        }

        for (pageIndex, document) in scan.pages.enumerated() {
            let pageImage = pageIndex < images.count ? images[pageIndex] : nil

            if scan.pages.count > 1 {
                if y + 70 > page.height - margin { newPage() }
                y += 16
                y += draw("第 \(pageIndex + 1) 页", font: .systemFont(ofSize: 20, weight: .semibold),
                          color: .gray, at: CGPoint(x: margin, y: y), maxWidth: contentWidth) + 8
            }

            for (sectionIndex, section) in document.sections.enumerated() {
                let sectionTitle = [section.chineseTitle, section.originalTitle]
                    .compactMap { $0 }.joined(separator: " / ")

                if !sectionTitle.isEmpty {
                    if y + 60 > page.height - margin { newPage() }
                    y += 14
                    y += draw(sectionTitle, font: .boldSystemFont(ofSize: 24),
                              color: .black, at: CGPoint(x: margin, y: y), maxWidth: contentWidth) + 10
                }

                for (itemIndex, item) in section.items.enumerated() {
                    let key = MenuScan.dishKey(page: pageIndex, section: sectionIndex, item: itemIndex)
                    let photo = item.photoBBox.flatMap { pageImage?.crop(normalized: $0) }
                        ?? generatedImages[key]
                    let photoSide: CGFloat = photo == nil ? 0 : 190
                    let textX = margin + (photo == nil ? 0 : photoSide + 24)
                    let textWidth = contentWidth - (photo == nil ? 0 : photoSide + 24)

                    let textHeight = appendixCardText(item, at: CGPoint(x: textX, y: 0), maxWidth: textWidth, dryRun: true)
                    let cardHeight = max(textHeight, photoSide) + 26

                    if y + cardHeight > page.height - margin { newPage() }

                    if let photo {
                        let scale = photoSide / max(photo.size.width, photo.size.height)
                        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                        photo.draw(in: CGRect(origin: CGPoint(x: margin, y: y), size: size))
                    }
                    _ = appendixCardText(item, at: CGPoint(x: textX, y: y), maxWidth: textWidth, dryRun: false)

                    y += cardHeight
                    UIColor.black.withAlphaComponent(0.1).setStroke()
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: margin, y: y - 13))
                    line.addLine(to: CGPoint(x: page.width - margin, y: y - 13))
                    line.stroke()
                }
            }
        }
    }

    @discardableResult
    private func appendixCardText(_ item: MenuItemEntry, at origin: CGPoint, maxWidth: CGFloat, dryRun: Bool) -> CGFloat {
        var y = origin.y
        var title = item.originalName
        if let price = item.price { title += "   \(price)" }
        y += draw(title, font: .boldSystemFont(ofSize: 24), color: .black,
                  at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 6
        y += draw(item.chineseName, font: .systemFont(ofSize: 20, weight: .medium),
                  color: UIColor(red: 0.72, green: 0.23, blue: 0.11, alpha: 1),
                  at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 8

        if let desc = item.originalDescription {
            y += draw(desc, font: .italicSystemFont(ofSize: 15), color: .darkGray,
                      at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        if let zhDesc = item.chineseDescription {
            y += draw(zhDesc, font: .systemFont(ofSize: 15), color: .darkGray,
                      at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        return y - origin.y
    }

    // MARK: - Text primitives

    /// Draw a wrapped string; returns its height. `dryRun` only measures.
    @discardableResult
    private func draw(
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
            attributed.draw(with: CGRect(origin: origin, size: CGSize(width: maxWidth, height: bounds.height.rounded(.up))),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return bounds.height.rounded(.up)
    }

}
