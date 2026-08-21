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
    /// Text-free reconstruction of this page (PaperPlate). When present,
    /// erasing copies the plate's own pixels — paper texture and lighting
    /// carry through, so patches stop reading as patches.
    var paperPlate: UIImage?
    /// Illumination-flattened page painted instead of the raw photo.
    var backgroundImage: UIImage?
    /// Show the untouched menu (plus order marks) — for handing the phone
    /// to a server who reads the original language.
    var translationsHidden: Bool = false

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
    ///
    /// Three phases so erasure can happen in ONE pass: plan what to erase and
    /// what to write, erase (ideally by copying the text-free plate), then
    /// write. A single clipped plate draw means neighbouring strips share
    /// exactly the paper they sit on — no visible patch edges.
    func draw() {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        UIColor.white.setFill()
        UIBezierPath(rect: pageRect).fill()
        (backgroundImage ?? image).draw(in: pageRect)

        let canvas = pageSize
        let nameColor = UIColor(red: 0.72, green: 0.20, blue: 0.10, alpha: 1)

        guard !translationsHidden else {
            drawAllHighlights(in: canvas)
            return
        }

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

        // MARK: Phase 1 — plan

        struct Flow {
            let text: String
            let strips: [CGRect]
            let block: CGRect?
        }
        var eraseRects: [CGRect] = []
        var flows: [Flow] = []

        // Rects already claimed by a dish's description. Compared by
        // intersection, not identity: a near-duplicate line box would
        // otherwise get a second, overlapping translation drawn on top.
        var claimed: [CGRect] = []
        for section in document.sections {
            for item in section.items {
                for lineBox in item.descriptionLines ?? [] {
                    claimed.append(lineBox.rect(in: canvas))
                }
            }
        }
        func isClaimed(_ rect: CGRect) -> Bool {
            claimed.contains { other in
                let intersection = other.intersection(rect)
                guard !intersection.isNull else { return false }
                return intersection.height > 0.4 * min(other.height, rect.height)
                    && intersection.width > 0.3 * min(other.width, rect.width)
            }
        }

        // v2 pages: description/other lines that belong to no dish (footers,
        // taglines, legends, set-menu notes) are translated in place too.
        if let textLines = document.textLines {
            for line in textLines {
                guard line.role == "description" || line.role == "other",
                      !line.translated.isEmpty,
                      !isClaimed(line.box.rect(in: canvas)),
                      // Big display text (logos) keeps its original pixels.
                      line.box.height < 0.03
                else { continue }
                let strip = line.box.rect(in: canvas)
                eraseRects.append(strip.insetBy(dx: -2, dy: -1))
                flows.append(Flow(text: line.translated, strips: [strip], block: nil))
            }
        }

        for section in document.sections {
            for item in section.items {
                let nameRect = item.bbox.rect(in: canvas)
                // A description line has to be geometrically plausible for
                // its dish: at/below the name, close by, same column. The
                // model occasionally hands over a neighbouring column's line
                // (or, when a dish name appears twice on the menu, the other
                // one's lines) — rewriting those would overwrite text that
                // belongs to a different dish.
                func plausible(_ strip: CGRect) -> Bool {
                    guard strip.midY > nameRect.minY - 4,
                          strip.minY < nameRect.maxY + canvas.height * 0.16
                    else { return false }
                    let overlap = min(strip.maxX, nameRect.maxX + canvas.width * 0.10)
                        - max(strip.minX, nameRect.minX - canvas.width * 0.04)
                    return overlap > 0.3 * min(strip.width, max(nameRect.width, canvas.width * 0.05))
                }
                let ownStrips = (item.descriptionLines ?? [])
                    .map { $0.rect(in: canvas) }
                    .filter(plausible)

                if !ownStrips.isEmpty,
                   let zhDesc = item.chineseDescription,
                   shouldFlowThroughStrips(ownStrips, text: zhDesc) {
                    let strips = ownStrips
                    eraseRects.append(contentsOf: strips.map { $0.insetBy(dx: -2, dy: -1) })
                    flows.append(Flow(text: zhDesc, strips: strips, block: nil))
                } else if let descBox = item.descriptionBBox, let zhDesc = item.chineseDescription,
                          plausible(descBox.rect(in: canvas)) {
                    let block = descBox.rect(in: canvas).insetBy(dx: -2, dy: -1)
                    eraseRects.append(block)
                    flows.append(Flow(text: zhDesc, strips: [], block: block))
                }
            }
        }

        // MARK: Phase 2 — erase

        erase(eraseRects, pageRect: pageRect)

        // MARK: Phase 3 — write

        for flow in flows {
            if let block = flow.block {
                drawFitted(flow.text, in: block.insetBy(dx: 2, dy: 1))
            } else {
                flowTranslation(flow.text, through: flow.strips)
            }
        }

        // Section headings get their translation in the blank space beside
        // them (right first) — "CEBICHES" means nothing to the diner either.
        // One caption per printed heading: a section split across several
        // MenuSection entries (same title, non-adjacent dishes) would
        // otherwise stamp its translation two or three times over.
        var captionedTitles = Set<String>()
        for section in document.sections {
            guard let bbox = section.bbox, let translated = section.chineseTitle,
                  !translated.isEmpty, translated != section.originalTitle
            else { continue }
            let key = "\(boxKey(bbox))|\(translated)"
            guard captionedTitles.insert(key).inserted else { continue }
            placeCaption(translated, anchor: bbox.rect(in: canvas), canvas: canvas,
                         occupancy: &occupancy, color: nameColor)
        }
        for section in document.sections {
            for item in section.items {
                placeCaption(item.chineseName, anchor: item.bbox.rect(in: canvas), canvas: canvas,
                             occupancy: &occupancy, color: nameColor)
            }
        }

        drawAllHighlights(in: canvas)
    }

    /// Erase text regions. With a plate: clip to all regions and draw the
    /// text-free page once, so every patch inherits the exact local paper,
    /// texture and shading. Without: fall back to sampled flat fills.
    private func erase(_ rects: [CGRect], pageRect: CGRect) {
        guard !rects.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        if let plate = paperPlate {
            ctx.saveGState()
            let path = UIBezierPath()
            for rect in rects {
                path.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))
            }
            path.addClip()
            plate.draw(in: pageRect)
            ctx.restoreGState()
        } else {
            let canvas = pageSize
            for rect in rects {
                let normalized = NormalizedRect(
                    x: rect.minX / canvas.width, y: rect.minY / canvas.height,
                    width: rect.width / canvas.width, height: rect.height / canvas.height
                )
                paperColor(nearStrip: normalized).withAlphaComponent(0.98).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 2).fill()
            }
        }
    }

    private func drawAllHighlights(in canvas: CGSize) {
        for (sectionIndex, section) in document.sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                let key = MenuScan.dishKey(page: pageIndex, section: sectionIndex, item: itemIndex)
                if let quantity = highlights[key], quantity > 0 {
                    drawOrderHighlight(for: item, quantity: quantity,
                                       label: orderLabels[key], in: canvas)
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

        func isFree(_ rect: CGRect) -> Bool {
            guard rect.minX >= 4, rect.maxX <= canvas.width - 4,
                  rect.minY >= 0, rect.maxY <= canvas.height
            else { return false }
            for obstacle in occupancy where obstacle != anchor {
                if rect.intersects(obstacle.insetBy(dx: -3, dy: -1)) { return false }
            }
            return true
        }

        // Right of the line reads as a same-line annotation; below and above
        // are the fallbacks. Never overlap printed content: if no slot is
        // free even at a smaller size, the canvas simply omits the caption
        // (the list view always carries it).
        for scale in [1.0, 0.8] as [CGFloat] {
            let fontSize = max(min(anchor.height * 0.8 * scale, 16), 9)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let size = (text as NSString).size(withAttributes: [.font: font])
            let candidates = [
                CGRect(x: anchor.maxX + 10, y: anchor.midY - size.height / 2,
                       width: size.width, height: size.height),
                CGRect(x: anchor.minX, y: anchor.maxY + 2,
                       width: size.width, height: size.height),
                CGRect(x: anchor.minX, y: anchor.minY - size.height - 2,
                       width: size.width, height: size.height),
            ]
            for rect in candidates where isFree(rect) {
                (text as NSString).draw(
                    at: rect.origin,
                    withAttributes: [.font: font, .foregroundColor: color]
                )
                occupancy.append(rect)
                return
            }
        }
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
        guard !strips.isEmpty, !text.isEmpty else { return }
        let ink = UIColor(white: 0.20, alpha: 1)
        let accent = UIColor(red: 0.72, green: 0.20, blue: 0.10, alpha: 1)

        func width(_ string: String, _ font: UIFont) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }

        // Plan the whole paragraph before drawing a single glyph. `balanced`
        // aims for equal fill across every inherited strip (an erased-but-
        // empty band reads as a bright patch); greedy is the fallback that
        // packs each line to its full width. A plan is only valid if the
        // text FITS — otherwise the tail would spill onto the next dish.
        func plan(_ font: UIFont, balanced: Bool) -> [String]? {
            var rest = Substring(text)
            var lines: [String] = []
            for (index, strip) in strips.enumerated() {
                guard !rest.isEmpty else { lines.append(""); continue }
                let remaining = strips.count - index
                let soft: CGFloat = balanced && remaining > 1
                    // 15% slack so a nearby punctuation break can be reached
                    // without starving the lines that follow.
                    ? min(strip.width, width(String(rest), font) / CGFloat(remaining) * 1.15)
                    : strip.width
                let count = Self.breakPoint(
                    in: rest, font: font,
                    hardWidth: strip.width + 2, softWidth: soft + 2
                )
                lines.append(String(rest.prefix(count)))
                rest = rest.dropFirst(count)
            }
            return rest.isEmpty ? lines : nil
        }

        // Chinese is more compact than the Latin text it replaces, so start
        // from the largest size the line height allows and shrink only until
        // the paragraph fits.
        let heights = strips.map(\.height).sorted()
        let lineHeight = heights[heights.count / 2]
        // Walk sizes down from a generous ceiling. The best size is the
        // largest one whose plan both fits AND uses every strip — a strip
        // left empty was erased for nothing and shows as a pale band. If no
        // size manages that, take the largest that simply fits.
        var chosen: (size: CGFloat, lines: [String])?
        var fallback: (size: CGFloat, lines: [String])?
        var probe = min(max(lineHeight * 1.25, 9), 22)
        while probe > 8 {
            let font = UIFont.systemFont(ofSize: probe)
            if let candidate = plan(font, balanced: true) ?? plan(font, balanced: false) {
                if fallback == nil { fallback = (probe, candidate) }
                if !candidate.contains(where: { $0.isEmpty }) {
                    chosen = (probe, candidate)
                    break
                }
            }
            probe -= 0.5
        }
        let picked = chosen ?? fallback
        let fontSize = picked?.size ?? 9
        let lines = picked?.lines
        let font = UIFont.systemFont(ofSize: fontSize)
        let boldFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let planned = lines ?? plan(font, balanced: false) ?? [String(text)]

        // Fewer lines than inherited strips (Chinese is compact): spread them
        // evenly over the whole erased region instead of stacking at the top,
        // so the reclaimed space becomes generous leading rather than a hole
        // at the bottom.
        let used = planned.filter { !$0.isEmpty }
        var slots = strips
        if used.count < strips.count, used.count > 0 {
            var union = strips[0]
            for strip in strips.dropFirst() { union = union.union(strip) }
            let slotHeight = union.height / CGFloat(used.count)
            slots = (0 ..< used.count).map { index in
                CGRect(
                    x: union.minX, y: union.minY + CGFloat(index) * slotHeight,
                    width: union.width, height: slotHeight
                )
            }
        }

        var consumed = 0
        for (index, chunk) in used.enumerated() {
            guard index < slots.count else { break }
            let strip = slots[index]
            let origin = CGPoint(x: strip.minX, y: strip.midY - font.lineHeight / 2)
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
                (String(chunk.dropFirst(accentCount)) as NSString).draw(
                    at: CGPoint(x: x, y: origin.y),
                    withAttributes: [.font: font, .foregroundColor: ink]
                )
            }
            consumed += chunk.count
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

    // MARK: - Line breaking

    /// Characters that must not start a line (CJK 禁则) …
    private static let noLineStart: Set<Character> = [
        "，", "。", "、", "；", "：", "？", "！", "）", "》", "】", "」", "』", "”", "’",
        "…", "·", "%", ",", ".", ")", "]", "}", "!", "?", ":", ";",
    ]
    /// … and characters that must not end one.
    private static let noLineEnd: Set<Character> = [
        "（", "《", "【", "「", "『", "“", "‘", "(", "[", "{", "$", "¥", "€",
    ]

    /// How many characters of `text` belong on this line.
    ///
    /// Chinese has no spaces, so a width-only split lands mid-word ("土|豆").
    /// Instead: find the widest fit, then look back for a punctuation break
    /// (commas and full stops are where a human would break), never split a
    /// Latin word or number, and finally apply the 禁则 rules so a line never
    /// starts with closing punctuation or ends with an opening bracket.
    static func breakPoint(in text: Substring, font: UIFont, hardWidth: CGFloat, softWidth: CGFloat) -> Int {
        let characters = Array(text)
        func width(_ upTo: Int) -> CGFloat {
            (String(characters[0 ..< upTo]) as NSString)
                .size(withAttributes: [.font: font]).width
        }
        func fitting(_ limit: CGFloat) -> Int {
            var low = 0, high = characters.count
            while low < high {
                let mid = (low + high + 1) / 2
                if width(mid) <= limit { low = mid } else { high = mid - 1 }
            }
            return low
        }

        let hard = fitting(hardWidth)
        if hard >= characters.count { return characters.count }
        // Strip too narrow for even one character: emit one anyway, else the
        // planner would never consume the text.
        guard hard >= 1 else { return 1 }
        let soft = max(1, min(fitting(softWidth), hard))

        // Prefer a punctuation boundary; search the window around the soft
        // target, closest-to-target first, so lines stay evenly filled.
        let lower = max(1, min(Int(Double(soft) * 0.6), hard))
        let breakers: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", " ", "/"]
        var candidates = Array(lower ... hard)
        candidates.sort { abs($0 - soft) < abs($1 - soft) }
        for position in candidates where breakers.contains(characters[position - 1]) {
            return position
        }

        // No punctuation: keep Latin words and numbers whole.
        var position = soft
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter && character.isASCII || character.isNumber || character == "."
        }
        if position < characters.count,
           isWordCharacter(characters[position]), isWordCharacter(characters[position - 1]) {
            var back = position
            while back > lower, isWordCharacter(characters[back - 1]) { back -= 1 }
            if back > lower { position = back }
        }

        // 禁则: pull a closing mark up onto this line if it still fits,
        // otherwise push the preceding character down to the next one.
        var guardCounter = 0
        while position < characters.count, position >= 1,
              noLineStart.contains(characters[position]), guardCounter < characters.count {
            if width(position + 1) <= hardWidth { position += 1 } else { position -= 1 }
            guardCounter += 1
        }
        while position > 1, noLineEnd.contains(characters[position - 1]) { position -= 1 }
        return max(1, min(position, hard))
    }

}
