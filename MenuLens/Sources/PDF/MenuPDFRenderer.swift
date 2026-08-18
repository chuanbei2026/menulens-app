import UIKit

/// Renders the analyzed menu into a large PDF with two parts:
///
/// 1. **Layout page** — a big page with the same aspect ratio as the photo.
///    The original photo is drawn faintly underneath for spatial context, and
///    every item's translated card is drawn *at its own bbox position*, so the
///    page reads like the original menu, just bilingual.
/// 2. **Appendix pages** — one readable card per dish (cropped 配图 + full
///    word-by-word gloss), paginated A4-portrait-like, guaranteed legible even
///    when the original layout is cramped.
struct MenuPDFRenderer {
    let document: MenuDocument
    let sourceImage: UIImage

    /// Width of the layout page in points. ~3x A4 width => "a big PDF".
    private let layoutPageWidth: CGFloat = 1600
    private let appendixPageSize = CGSize(width: 1240, height: 1754)

    func renderPDF() -> Data {
        let image = sourceImage.normalizedOrientation()
        let aspect = image.size.height / max(image.size.width, 1)
        let layoutPage = CGRect(
            x: 0, y: 0,
            width: layoutPageWidth,
            height: (layoutPageWidth * aspect).rounded()
        )

        let renderer = UIGraphicsPDFRenderer(bounds: layoutPage)
        return renderer.pdfData { ctx in
            drawLayoutPage(ctx: ctx, pageRect: layoutPage, image: image)
            drawAppendixPages(ctx: ctx, image: image)
        }
    }

    // MARK: - Part 1: same-layout page

    private func drawLayoutPage(ctx: UIGraphicsPDFRendererContext, pageRect: CGRect, image: UIImage) {
        ctx.beginPage(withBounds: pageRect, pageInfo: [:])
        UIColor.white.setFill()
        ctx.fill(pageRect)

        // Faint original photo as the spatial anchor.
        image.draw(in: pageRect, blendMode: .normal, alpha: 0.12)

        let canvas = pageRect.size

        for section in document.sections {
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

            for item in section.items {
                if let photoBox = item.photoBBox,
                   let cropped = sourceImage.crop(normalized: photoBox) {
                    let target = photoBox.rect(in: canvas)
                    cropped.draw(in: target)
                    UIColor.black.withAlphaComponent(0.15).setStroke()
                    UIBezierPath(rect: target).stroke()
                }
                drawItemCard(item, in: canvas)
            }
        }
    }

    /// A translated card pinned at the item's own bbox position.
    private func drawItemCard(_ item: MenuItemEntry, in canvas: CGSize) {
        let box = item.bbox.rect(in: canvas)
        let width = max(box.width, 180)
        var cursor = CGPoint(x: box.minX, y: box.minY)
        let maxWidth = min(width, canvas.width - cursor.x - 12)

        // Measure content height first so the card background fits.
        let measured = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: true)
        let cardRect = CGRect(x: cursor.x - 8, y: cursor.y - 6, width: maxWidth + 16, height: measured + 12)

        UIColor.white.withAlphaComponent(0.92).setFill()
        let bg = UIBezierPath(roundedRect: cardRect, cornerRadius: 8)
        bg.fill()
        UIColor.black.withAlphaComponent(0.12).setStroke()
        bg.stroke()

        _ = drawItemContent(item, at: cursor, maxWidth: maxWidth, dryRun: false)
        _ = cursor // origin unchanged; content drew itself
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

        y += drawGloss(
            item.words, at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth,
            wordSize: 13, dryRun: dryRun
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

    // MARK: - Part 2: appendix (one readable card per dish)

    private func drawAppendixPages(ctx: UIGraphicsPDFRendererContext, image: UIImage) {
        let page = CGRect(origin: .zero, size: appendixPageSize)
        let margin: CGFloat = 70
        let contentWidth = page.width - 2 * margin
        var y: CGFloat = .infinity // force a new page before the first card

        func newPage() {
            ctx.beginPage(withBounds: page, pageInfo: [:])
            UIColor.white.setFill()
            ctx.fill(page)
            var header = "逐词对照 · \(document.sourceLanguageChinese) → 中文"
            if let name = document.restaurantName { header = "\(name) — " + header }
            draw(header, font: .boldSystemFont(ofSize: 30), color: .black,
                 at: CGPoint(x: margin, y: 46), maxWidth: contentWidth)
            y = 110
        }

        for section in document.sections {
            let sectionTitle = [section.chineseTitle, section.originalTitle]
                .compactMap { $0 }.joined(separator: " / ")

            if !sectionTitle.isEmpty {
                if y + 60 > page.height - margin { newPage() }
                y += 14
                y += draw(sectionTitle, font: .boldSystemFont(ofSize: 24),
                          color: .black, at: CGPoint(x: margin, y: y), maxWidth: contentWidth) + 10
            }

            for item in section.items {
                let photo = item.photoBBox.flatMap { sourceImage.crop(normalized: $0) }
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
        y += drawGloss(item.words, at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth,
                       wordSize: 16, dryRun: dryRun) + 6

        if let desc = item.originalDescription {
            y += draw(desc, font: .italicSystemFont(ofSize: 15), color: .darkGray,
                      at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        if let zhDesc = item.chineseDescription {
            y += draw(zhDesc, font: .systemFont(ofSize: 15), color: .darkGray,
                      at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        if let descWords = item.descriptionWords, !descWords.isEmpty {
            y += 4
            y += drawGloss(descWords, at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth,
                           wordSize: 13, dryRun: dryRun)
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

    /// Interlinear gloss: for each token draw the foreign word on top, an
    /// optional romanization under it, and the Chinese meaning at the bottom.
    /// Tokens flow left-to-right and wrap. Returns total height.
    @discardableResult
    private func drawGloss(
        _ words: [WordGloss], at origin: CGPoint, maxWidth: CGFloat,
        wordSize: CGFloat, dryRun: Bool
    ) -> CGFloat {
        guard !words.isEmpty else { return 0 }
        let wordFont = UIFont.systemFont(ofSize: wordSize, weight: .semibold)
        let romanFont = UIFont.systemFont(ofSize: wordSize * 0.72)
        let zhFont = UIFont.systemFont(ofSize: wordSize * 0.88)
        let cellPadding: CGFloat = 10
        let rowGap: CGFloat = 8
        let hasRoman = words.contains { $0.romanization?.isEmpty == false }
        let rowHeight = wordFont.lineHeight + (hasRoman ? romanFont.lineHeight : 0) + zhFont.lineHeight + 4

        var x = origin.x
        var y = origin.y

        func width(of text: String, font: UIFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        for word in words {
            let cellWidth = max(
                width(of: word.text, font: wordFont),
                max(width(of: word.chinese, font: zhFont),
                    width(of: word.romanization ?? "", font: romanFont))
            )
            if x + cellWidth > origin.x + maxWidth, x > origin.x {
                x = origin.x
                y += rowHeight + rowGap
            }
            if !dryRun {
                var cy = y
                (word.text as NSString).draw(
                    at: CGPoint(x: x, y: cy),
                    withAttributes: [.font: wordFont, .foregroundColor: UIColor.black])
                cy += wordFont.lineHeight
                if hasRoman {
                    if let roman = word.romanization, !roman.isEmpty {
                        (roman as NSString).draw(
                            at: CGPoint(x: x, y: cy),
                            withAttributes: [.font: romanFont, .foregroundColor: UIColor.gray])
                    }
                    cy += romanFont.lineHeight
                }
                (word.chinese as NSString).draw(
                    at: CGPoint(x: x, y: cy + 2),
                    withAttributes: [.font: zhFont,
                                     .foregroundColor: UIColor(red: 0.1, green: 0.35, blue: 0.65, alpha: 1)])
            }
            x += cellWidth + cellPadding
        }
        return (y + rowHeight) - origin.y
    }
}
