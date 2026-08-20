import CoreImage
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

/// Replace-style bilingual layout, like a translation camera:
///
/// - the rectified menu photo is drawn at FULL opacity — the page IS the menu;
/// - each dish name stays in the original language, with a small Chinese
///   name painted just beneath its own line;
/// - each description block is painted over with the sampled paper color and
///   rewritten in Chinese within the exact same region.
///
/// Because every piece of text only ever occupies the space its original
/// occupied, overlaps are impossible by construction. Used by both the
/// in-app zoomable canvas and the PDF's layout pages.
struct MenuLayoutRenderer {
    let document: MenuDocument
    /// The rectified page photo (orientation already normalized).
    let image: UIImage
    let pageWidth: CGFloat
    /// This page's index within the scan — used to compose dish keys.
    var pageIndex: Int = 0
    /// Ordered dishes (dish key -> quantity): outlined with a quantity badge
    /// so a waiter can match the order against the printed menu.
    var highlights: [String: Int] = [:]

    private static let ciContext = CIContext()

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
        image.draw(in: pageRect)

        let canvas = pageSize
        let nameColor = UIColor(red: 0.72, green: 0.20, blue: 0.10, alpha: 1)

        for (sectionIndex, section) in document.sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                let nameRect = item.bbox.rect(in: canvas)

                if let descBox = item.descriptionBBox, let zhDesc = item.chineseDescription {
                    // Veil the original description with SEMI-transparent
                    // paper color: the original stays faintly visible, edges
                    // blend into the page, and nothing is ever fully lost.
                    let block = descBox.rect(in: canvas).insetBy(dx: -2, dy: -1)
                    let paper = sampledColor(around: descBox)
                    paper.withAlphaComponent(0.84).setFill()
                    UIBezierPath(roundedRect: block, cornerRadius: 4).fill()

                    drawFitted(
                        name: item.chineseName, body: zhDesc,
                        nameColor: nameColor,
                        in: block.insetBy(dx: 2, dy: 1)
                    )
                } else {
                    // No description block: paint the small Chinese name just
                    // beneath the original name line.
                    let size = max(min(nameRect.height * 0.72, 15), 9)
                    TextDraw.text(
                        item.chineseName,
                        font: .systemFont(ofSize: size, weight: .semibold),
                        color: nameColor,
                        at: CGPoint(x: nameRect.minX, y: nameRect.maxY + 1),
                        maxWidth: canvas.width - nameRect.minX - 8
                    )
                }

                let key = MenuScan.dishKey(page: pageIndex, section: sectionIndex, item: itemIndex)
                if let quantity = highlights[key], quantity > 0 {
                    drawOrderHighlight(for: item, quantity: quantity, in: canvas)
                }
            }
        }
    }

    /// Accent outline around the dish's printed area plus a x-quantity badge.
    private func drawOrderHighlight(for item: MenuItemEntry, quantity: Int, in canvas: CGSize) {
        var zone = item.bbox.rect(in: canvas)
        zone.size.height += 16 // include the Chinese caption under the name
        if let descBox = item.descriptionBBox {
            zone = zone.union(descBox.rect(in: canvas))
        }
        zone = zone.insetBy(dx: -8, dy: -6)

        let accent = UIColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1)
        accent.setStroke()
        let outline = UIBezierPath(roundedRect: zone, cornerRadius: 9)
        outline.lineWidth = 3
        outline.stroke()

        let label = "×\(quantity)" as NSString
        let font = UIFont.systemFont(ofSize: 15, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let badgeWidth = max(textSize.width + 12, 28)
        let badge = CGRect(
            x: zone.maxX - badgeWidth + 10, y: zone.minY - 13,
            width: badgeWidth, height: 26
        )
        accent.setFill()
        UIBezierPath(roundedRect: badge, cornerRadius: 13).fill()
        label.draw(
            at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
            withAttributes: [.font: font, .foregroundColor: UIColor.white]
        )
    }

    /// Chinese name (accent color) + description (dark gray) flowed together
    /// inside the replaced block, font auto-shrunk until it fits.
    private func drawFitted(name: String, body: String, nameColor: UIColor, in block: CGRect) {
        let combined = "\(name)  \(body)"
        var fontSize = max(min(block.height * 0.8, 15), 9)
        while fontSize > 8 {
            let height = TextDraw.text(
                combined, font: .systemFont(ofSize: fontSize),
                color: .black, at: .zero, maxWidth: block.width, dryRun: true
            )
            if height <= block.height + 4 { break }
            fontSize -= 1
        }
        let font = UIFont.systemFont(ofSize: fontSize)
        let nameFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: name + "  ", attributes: [
            .font: nameFont, .foregroundColor: nameColor,
        ]))
        attributed.append(NSAttributedString(string: body, attributes: [
            .font: font, .foregroundColor: UIColor(white: 0.22, alpha: 1),
        ]))
        attributed.draw(
            with: CGRect(origin: block.origin, size: CGSize(width: block.width, height: block.height + 6)),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
    }

    /// Which dish sits under a normalized (0...1, top-left origin) point:
    /// the name line (plus its Chinese caption) or the description block.
    func hitTest(normalizedPoint point: CGPoint) -> (section: Int, item: Int)? {
        let canvas = pageSize
        let p = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
        for (sectionIndex, section) in document.sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                var zone = item.bbox.rect(in: canvas).insetBy(dx: -6, dy: -6)
                zone.size.height += 18 // include the Chinese caption below
                if zone.contains(p) { return (sectionIndex, itemIndex) }
                if let descBox = item.descriptionBBox,
                   descBox.rect(in: canvas).insetBy(dx: -4, dy: -4).contains(p) {
                    return (sectionIndex, itemIndex)
                }
            }
        }
        return nil
    }

    /// Average paper color of the region (slightly lightened) — used to
    /// paint over the original text before rewriting it in Chinese.
    private func sampledColor(around normalizedRect: NormalizedRect) -> UIColor {
        guard let cg = image.cgImage else { return UIColor(white: 0.97, alpha: 1) }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        // Convert top-left normalized rect to Core Image's bottom-left space.
        let rect = CGRect(
            x: normalizedRect.x * w,
            y: h - (normalizedRect.y + normalizedRect.height) * h,
            width: normalizedRect.width * w,
            height: normalizedRect.height * h
        ).integral
        guard rect.width >= 2, rect.height >= 2 else { return UIColor(white: 0.97, alpha: 1) }

        let averaged = CIImage(cgImage: cg).applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect),
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(
            averaged, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Lighten slightly: the average includes the (dark) glyphs, while we
        // want the paper behind them.
        func lift(_ v: UInt8) -> CGFloat { min(CGFloat(v) / 255 * 1.05 + 0.01, 1) }
        return UIColor(red: lift(pixel[0]), green: lift(pixel[1]), blue: lift(pixel[2]), alpha: 1)
    }
}
