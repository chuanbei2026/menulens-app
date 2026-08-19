import UIKit

/// Renders an analyzed menu scan into a large PDF with two parts:
///
/// 1. **Layout pages** — one per photographed page, drawn by
///    `MenuLayoutRenderer` (identical to the in-app canvas): the rectified
///    photo as a readable watermark with translation cards overlaid in place.
/// 2. **Appendix pages** — one readable card per dish across all pages
///    (cropped or AI-generated 配图 + bilingual name/description/price),
///    paginated, guaranteed legible even when the original layout is cramped.
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
        let layouts: [MenuLayoutRenderer] = scan.pages.enumerated().compactMap { index, document in
            guard index < images.count else { return nil }
            return MenuLayoutRenderer(
                document: document,
                image: images[index].normalizedOrientation(),
                pageWidth: layoutPageWidth
            )
        }
        let initialBounds = CGRect(
            origin: .zero,
            size: layouts.first?.pageSize ?? CGSize(width: layoutPageWidth, height: layoutPageWidth * 1.4)
        )

        let renderer = UIGraphicsPDFRenderer(bounds: initialBounds)
        return renderer.pdfData { ctx in
            for layout in layouts {
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: layout.pageSize), pageInfo: [:])
                layout.draw()
            }
            drawAppendixPages(ctx: ctx)
        }
    }

    // MARK: - Appendix (one readable card per dish, all pages merged)

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
            TextDraw.text(header, font: .boldSystemFont(ofSize: 30), color: .black,
                          at: CGPoint(x: margin, y: 46), maxWidth: contentWidth)
            y = 110
        }

        for (pageIndex, document) in scan.pages.enumerated() {
            let pageImage = pageIndex < images.count ? images[pageIndex] : nil

            if scan.pages.count > 1 {
                if y + 70 > page.height - margin { newPage() }
                y += 16
                y += TextDraw.text("第 \(pageIndex + 1) 页", font: .systemFont(ofSize: 20, weight: .semibold),
                                   color: .gray, at: CGPoint(x: margin, y: y), maxWidth: contentWidth) + 8
            }

            for (sectionIndex, section) in document.sections.enumerated() {
                let sectionTitle = [section.chineseTitle, section.originalTitle]
                    .compactMap { $0 }.joined(separator: " / ")

                if !sectionTitle.isEmpty {
                    if y + 60 > page.height - margin { newPage() }
                    y += 14
                    y += TextDraw.text(sectionTitle, font: .boldSystemFont(ofSize: 24),
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
        y += TextDraw.text(title, font: .boldSystemFont(ofSize: 24), color: .black,
                           at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 6
        y += TextDraw.text(item.chineseName, font: .systemFont(ofSize: 20, weight: .medium),
                           color: UIColor(red: 0.72, green: 0.23, blue: 0.11, alpha: 1),
                           at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 8

        if let desc = item.originalDescription {
            y += TextDraw.text(desc, font: .italicSystemFont(ofSize: 15), color: .darkGray,
                               at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        if let zhDesc = item.chineseDescription {
            y += TextDraw.text(zhDesc, font: .systemFont(ofSize: 15), color: .darkGray,
                               at: CGPoint(x: origin.x, y: y), maxWidth: maxWidth, dryRun: dryRun) + 3
        }
        return y - origin.y
    }
}
