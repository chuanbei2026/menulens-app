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
    /// Per-dish "who ordered it" label (dish key -> "我 · 小明×2").
    var orderLabels: [String: String] = [:]

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

        // Occupancy map: every printed text line (v2) — or, on legacy scans,
        // every known box — is an obstacle. Translated-name captions are
        // placed only into genuinely blank space, and each placed caption
        // becomes an obstacle for the next one.
        var occupancy: [CGRect]
        if let textLines = document.textLines, !textLines.isEmpty {
            occupancy = textLines.map { $0.box.rect(in: canvas) }
        } else {
            occupancy = []
            for section in document.sections {
                if let b = section.bbox { occupancy.append(b.rect(in: canvas)) }
                for item in section.items {
                    occupancy.append(item.bbox.rect(in: canvas))
                    for lineBox in item.descriptionLines ?? [] {
                        occupancy.append(lineBox.rect(in: canvas))
                    }
                    if let hull = item.descriptionBBox { occupancy.append(hull.rect(in: canvas)) }
                }
            }
        }

        // v2 pages: every description/other line not owned by a dish is
        // erased and rewritten in the target language too — footers,
        // taglines, set-menu notes. Nothing stays untranslated.
        if let textLines = document.textLines, !textLines.isEmpty {
            var owned = Set<String>()
            for section in document.sections {
                for item in section.items {
                    for lineBox in item.descriptionLines ?? [] {
                        owned.insert(boxKey(lineBox))
                    }
                }
            }
            for line in textLines {
                guard line.role == "description" || line.role == "other",
                      !line.translated.isEmpty,
                      !owned.contains(boxKey(line.box)),
                      // Big display text (logos, decorative headlines) keeps
                      // its original pixels — rewriting it wrecks the design.
                      line.box.height < 0.03
                else { continue }
                let strip = line.box.rect(in: canvas)
                let paper = paperColor(nearStrip: line.box)
                paper.withAlphaComponent(0.98).setFill()
                UIBezierPath(roundedRect: strip.insetBy(dx: -2, dy: -1), cornerRadius: 2).fill()
                flowTranslation(line.translated, through: [strip])
            }
        }

        // Section headings get their translation in the blank space beside
        // them (right first) — "CEBICHES" means nothing to the diner either.
        for section in document.sections {
            guard let bbox = section.bbox, let translated = section.chineseTitle,
                  !translated.isEmpty, translated != section.originalTitle
            else { continue }
            placeCaption(
                translated,
                anchor: bbox.rect(in: canvas),
                canvas: canvas,
                occupancy: &occupancy,
                color: nameColor
            )
        }

        for (sectionIndex, section) in document.sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                let nameRect = item.bbox.rect(in: canvas)

                // Translated name: accent caption in the blank space next to
                // the original name line (never inside the description).
                placeCaption(
                    item.chineseName,
                    anchor: nameRect,
                    canvas: canvas,
                    occupancy: &occupancy,
                    color: nameColor
                )

                if let lineBoxes = item.descriptionLines, !lineBoxes.isEmpty,
                   let zhDesc = item.chineseDescription,
                   shouldFlowThroughStrips(lineBoxes.map { $0.rect(in: canvas) }, text: zhDesc) {
                    // Lens-style: veil each original line strip separately
                    // (paper color sampled from the line gap right above it)
                    // and flow the PURE translated description through the
                    // original slots — Chinese fully replaces the English.
                    let strips = lineBoxes.map { $0.rect(in: canvas) }
                    for (index, strip) in strips.enumerated() {
                        let paper = paperColor(nearStrip: lineBoxes[index])
                        paper.withAlphaComponent(0.98).setFill()
                        UIBezierPath(roundedRect: strip.insetBy(dx: -2, dy: -1), cornerRadius: 2).fill()
                    }
                    flowTranslation(zhDesc, through: strips)
                } else if let descBox = item.descriptionBBox, let zhDesc = item.chineseDescription {
                    // Block mode (set-menu boxes, strip-flow misfits): veil
                    // the whole region and re-typeset the pure translation.
                    let block = descBox.rect(in: canvas).insetBy(dx: -2, dy: -1)
                    let paper = sampledColor(around: descBox)
                    paper.withAlphaComponent(0.92).setFill()
                    UIBezierPath(roundedRect: block, cornerRadius: 4).fill()

                    drawFitted(zhDesc, in: block.insetBy(dx: 2, dy: 1))
                }

                let key = MenuScan.dishKey(page: pageIndex, section: sectionIndex, item: itemIndex)
                if let quantity = highlights[key], quantity > 0 {
                    drawOrderHighlight(
                        for: item, quantity: quantity,
                        label: orderLabels[key], in: canvas
                    )
                }
            }
        }
    }

    /// Accent outline around the dish's printed area plus a x-quantity badge
    /// and a "who ordered it" name tag.
    private func drawOrderHighlight(for item: MenuItemEntry, quantity: Int, label: String?, in canvas: CGSize) {
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

        let qtyText = "×\(quantity)" as NSString
        let font = UIFont.systemFont(ofSize: 15, weight: .bold)
        let textSize = qtyText.size(withAttributes: [.font: font])
        let badgeWidth = max(textSize.width + 12, 28)
        let badge = CGRect(
            x: zone.maxX - badgeWidth + 10, y: zone.minY - 13,
            width: badgeWidth, height: 26
        )
        accent.setFill()
        UIBezierPath(roundedRect: badge, cornerRadius: 13).fill()
        (("×\(quantity)") as NSString).draw(
            at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
            withAttributes: [.font: font, .foregroundColor: UIColor.white]
        )

        // Name tag to the LEFT of the quantity badge: who ordered this dish.
        if let label, !label.isEmpty {
            let nameFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
            let nameText = label as NSString
            let nameSize = nameText.size(withAttributes: [.font: nameFont])
            let tag = CGRect(
                x: badge.minX - nameSize.width - 20, y: zone.minY - 12,
                width: nameSize.width + 14, height: 24
            )
            accent.withAlphaComponent(0.92).setFill()
            UIBezierPath(roundedRect: tag, cornerRadius: 12).fill()
            nameText.draw(
                at: CGPoint(x: tag.midX - nameSize.width / 2, y: tag.midY - nameSize.height / 2),
                withAttributes: [.font: nameFont, .foregroundColor: UIColor.white]
            )
        }
    }

    /// Place a translated-name caption into blank space near its anchor:
    /// right of the line first (reads like a same-line annotation), below
    /// as fallback — never over another printed line or an earlier caption.
    /// The chosen rect joins the occupancy map.
    private func placeCaption(
        _ text: String, anchor: CGRect, canvas: CGSize,
        occupancy: inout [CGRect], color: UIColor
    ) {
        guard !text.isEmpty else { return }
        let fontSize = max(min(anchor.height * 0.8, 16), 10)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let height = font.lineHeight

        func isFree(_ rect: CGRect) -> Bool {
            guard rect.minX >= 4, rect.maxX <= canvas.width - 4,
                  rect.minY >= 0, rect.maxY <= canvas.height
            else { return false }
            for obstacle in occupancy where obstacle != anchor {
                if rect.intersects(obstacle.insetBy(dx: -3, dy: -1)) { return false }
            }
            return true
        }

        // 1) Right of the line, vertically centered on it.
        var rect = CGRect(x: anchor.maxX + 10, y: anchor.midY - height / 2, width: width, height: height)
        if !isFree(rect) {
            // 2) Just below, left-aligned with the line.
            rect = CGRect(x: anchor.minX, y: anchor.maxY + 2, width: width, height: height)
            if !isFree(rect) {
                // 3) Last resort: below with a small extra offset (accepting
                //    a possible brush with a rule line, never with text).
                rect = CGRect(x: anchor.minX, y: anchor.maxY + 4, width: width, height: height)
            }
        }

        (text as NSString).draw(
            at: rect.origin,
            withAttributes: [.font: font, .foregroundColor: color]
        )
        occupancy.append(rect)
    }

    private func boxKey(_ box: NormalizedRect) -> String {
        "\(box.x)-\(box.y)-\(box.width)-\(box.height)"
    }

    /// Strip flow suits short descriptions (1–6 lines) whose combined slot
    /// width can hold the translation at a readable size. Set-menu boxes
    /// (many centered short lines) and undersized regions read better as one
    /// replaced block, so they fall back to block mode.
    private func shouldFlowThroughStrips(_ strips: [CGRect], text: String) -> Bool {
        guard !strips.isEmpty, strips.count <= 6 else { return false }
        let totalWidth = strips.reduce(0) { $0 + $1.width }
        let needed = (text as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 9)]).width
        return needed <= totalWidth * 1.05
    }

    /// Flow the translated description through the original line slots:
    /// one uniform font sized so the whole text fits the combined slot
    /// width, then greedy prefix-fitting per strip (binary search). Any
    /// leftover wraps below the last strip.
    private func flowTranslation(_ text: String, through strips: [CGRect], accentPrefixLength: Int = 0) {
        guard !strips.isEmpty else { return }
        let ink = UIColor(white: 0.20, alpha: 1)
        let accent = UIColor(red: 0.72, green: 0.20, blue: 0.10, alpha: 1)
        let heights = strips.map(\.height).sorted()
        var fontSize = min(max(heights[heights.count / 2] * 0.78, 9), 18)

        func width(_ string: String, _ font: UIFont) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        let totalWidth = strips.reduce(0) { $0 + $1.width }
        while fontSize > 8, width(text, .systemFont(ofSize: fontSize)) > totalWidth * 0.96 {
            fontSize -= 1
        }
        let font = UIFont.systemFont(ofSize: fontSize)

        let boldFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        var consumed = 0
        var remainder = Substring(text)

        // Draw one chunk, splitting accent-prefix characters from ink ones.
        func drawChunk(_ chunk: String, at origin: CGPoint) {
            let accentCount = max(0, min(chunk.count, accentPrefixLength - consumed))
            var x = origin.x
            if accentCount > 0 {
                let head = String(chunk.prefix(accentCount))
                (head as NSString).draw(
                    at: CGPoint(x: x, y: origin.y),
                    withAttributes: [.font: boldFont, .foregroundColor: accent]
                )
                x += width(head, boldFont)
            }
            if accentCount < chunk.count {
                let tail = String(chunk.dropFirst(accentCount))
                (tail as NSString).draw(
                    at: CGPoint(x: x, y: origin.y),
                    withAttributes: [.font: font, .foregroundColor: ink]
                )
            }
            consumed += chunk.count
        }

        for strip in strips {
            guard !remainder.isEmpty else { break }
            var low = 0
            var high = remainder.count
            while low < high {
                let mid = (low + high + 1) / 2
                if width(String(remainder.prefix(mid)), font) <= strip.width + 2 {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            let count = max(low, 1)
            drawChunk(
                String(remainder.prefix(count)),
                at: CGPoint(x: strip.minX, y: strip.midY - font.lineHeight / 2)
            )
            remainder = remainder.dropFirst(count)
        }
        if !remainder.isEmpty, let last = strips.last {
            TextDraw.text(
                String(remainder), font: font, color: ink,
                at: CGPoint(x: last.minX, y: last.maxY + 2),
                maxWidth: max(last.width, 180)
            )
        }
    }

    /// Paper color for a line strip, sampled from the line GAP right above
    /// it — pure paper, no glyph ink to distort the average.
    private func paperColor(nearStrip strip: NormalizedRect) -> UIColor {
        let gap = NormalizedRect(
            x: strip.x,
            y: max(0, strip.y - strip.height * 0.45),
            width: strip.width,
            height: strip.height * 0.32
        )
        return sampledColor(around: gap, lift: 1.02)
    }

    /// Chinese name (accent color) + description (dark gray) flowed together
    /// inside the replaced block, font auto-shrunk until it fits.
    private func drawFitted(_ text: String, in block: CGRect) {
        var fontSize = max(min(block.height * 0.8, 15), 11)
        while fontSize > 10 {
            let height = TextDraw.text(
                text, font: .systemFont(ofSize: fontSize),
                color: .black, at: .zero, maxWidth: block.width, dryRun: true
            )
            if height <= block.height + 4 { break }
            fontSize -= 1
        }
        TextDraw.text(
            text, font: .systemFont(ofSize: fontSize),
            color: UIColor(white: 0.22, alpha: 1),
            at: block.origin, maxWidth: block.width
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
    private func sampledColor(around normalizedRect: NormalizedRect, lift liftFactor: CGFloat = 1.05) -> UIColor {
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
        func lift(_ v: UInt8) -> CGFloat { min(CGFloat(v) / 255 * liftFactor + 0.01, 1) }
        return UIColor(red: lift(pixel[0]), green: lift(pixel[1]), blue: lift(pixel[2]), alpha: 1)
    }
}
