import UIKit
import Vision

/// Snaps the VLM's item bboxes onto real text lines found by on-device OCR.
///
/// The VLM's normalized coordinates are approximate (often half a line off);
/// Vision's text recognition returns pixel-accurate line boxes. For each menu
/// item we fuzzy-match its printed name against the recognized lines and, on
/// a confident match, move the item's bbox origin onto the OCR line. Items
/// with no confident match keep the VLM box; if OCR yields nothing at all
/// (e.g. the model is unavailable), the document passes through unchanged.
enum BBoxRefiner {
    private struct Line {
        let text: String
        /// Normalized, top-left origin (converted from Vision's bottom-left).
        let box: CGRect
    }

    static func refine(_ document: MenuDocument, in image: UIImage) -> MenuDocument {
        let lines = recognizeLines(in: image)
        guard !lines.isEmpty else { return document }

        // Pass 1 — anchor every item's NAME line via fuzzy text match.
        struct Ref {
            let item: MenuItemEntry
            let nameLine: Line?
        }
        let refs: [[Ref]] = document.sections.map { section in
            section.items.map { item in
                var nameLine = bestMatch(for: item.originalName, in: lines, near: item.bbox.cgRect)
                // Name unmatched: locate the item via its (longer, more
                // unique) description prefix and hang a zero-height anchor
                // just above that line.
                if nameLine == nil, let description = item.originalDescription {
                    if let descLine = bestMatch(for: String(description.prefix(30)), in: lines, near: item.bbox.cgRect) {
                        nameLine = Line(
                            text: "",
                            box: CGRect(x: descLine.box.minX, y: descLine.box.minY - 0.002,
                                        width: descLine.box.width, height: 0.001)
                        )
                    }
                }
                return Ref(item: item, nameLine: nameLine)
            }
        }
        let matchedNameBoxes = refs.flatMap { $0 }.compactMap { $0.nameLine?.box }

        // Section titles are OCR-anchored too — a mislocated VLM title box
        // would paint stray fragments, so unmatched titles simply don't draw.
        let sectionTitleLines: [CGRect?] = document.sections.map { section in
            guard let title = section.originalTitle else { return nil }
            return bestMatch(for: title, in: lines, near: section.bbox?.cgRect ?? CGRect(x: 0.5, y: 0.5, width: 0, height: 0))?.box
        }

        // Boundaries that end an item's territory: every other item's name
        // line, every item's VLM block (covers items whose OCR name match
        // failed), and the section-title lines.
        let anchors = matchedNameBoxes
            + refs.flatMap { $0 }.map { $0.item.bbox.cgRect }
            + sectionTitleLines.compactMap { $0 }
            + document.sections.compactMap { $0.bbox?.cgRect }

        // Pass 2 — an item's description region is EVERYTHING between its
        // name line and the next anchor below in the same column. Geometric,
        // not text-matched, so multi-line descriptions (with allergen codes,
        // hyphenated fragments, OCR errors) are replaced whole — no stripes
        // of leftover original text.
        func regionHull(for ref: Ref) -> (hull: NormalizedRect, lines: [NormalizedRect])? {
            guard ref.item.originalDescription != nil else { return nil }
            let vlm = ref.item.bbox.cgRect
            let nameBox: CGRect
            if let line = ref.nameLine {
                nameBox = line.box
            } else {
                // Whole-block fallback, but ONLY when no other item's matched
                // name line sits inside this VLM block — a mislocated block
                // would relabel a neighbor's dish, which is worse than
                // skipping the canvas annotation (the list still has it).
                let claimed = matchedNameBoxes.contains { vlm.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                guard !claimed else { return nil }
                nameBox = CGRect(x: vlm.minX, y: vlm.minY, width: vlm.width, height: 0.002)
            }
            let colMinX = min(nameBox.minX, vlm.minX) - 0.01
            let colWidth = max(nameBox.width, vlm.width) + 0.02
            let top = nameBox.maxY - 0.002

            // Hard cap: a bit past the VLM's own block bottom — even with no
            // anchor below, the veil can't run away down the column.
            var boundary = min(nameBox.maxY + 0.22, max(vlm.maxY, nameBox.maxY + 0.03) + 0.015)
            for other in anchors where other != nameBox && other != vlm {
                guard other.minY > nameBox.maxY + 0.004, other.minY < boundary else { continue }
                let xOverlap = min(other.maxX, colMinX + colWidth) - max(other.minX, colMinX)
                if xOverlap > 0.3 * min(other.width, colWidth) {
                    boundary = other.minY - 0.004
                }
            }

            var hull = CGRect.null
            var kept: [CGRect] = []
            for line in lines {
                let box = line.box
                guard !matchedNameBoxes.contains(box) else { continue }
                guard box.midY > top, box.maxY <= boundary + 0.004 else { continue }
                // Skip visibly larger text (section headers and the like).
                guard box.height < nameBox.height * 1.8 + 0.004 else { continue }
                let xOverlap = min(box.maxX, colMinX + colWidth) - max(box.minX, colMinX)
                // A description line may be much WIDER than the (short) name
                // line that defined the column window — accept a line when it
                // covers most of the window, even if the window covers little
                // of the line.
                guard xOverlap > min(0.5 * box.width, 0.7 * colWidth) else { continue }
                hull = hull.union(box)
                kept.append(box)
            }
            guard !hull.isNull else { return nil }
            kept.sort { lhs, rhs in
                abs(lhs.midY - rhs.midY) < 0.004 ? lhs.minX < rhs.minX : lhs.midY < rhs.midY
            }
            return (
                NormalizedRect(x: hull.minX, y: hull.minY, width: hull.width, height: hull.height),
                kept.map { NormalizedRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
            )
        }

        let sections = document.sections.enumerated().map { s, section in
            MenuSection(
                originalTitle: section.originalTitle,
                chineseTitle: section.chineseTitle,
                bbox: sectionTitleLines[s].map {
                    NormalizedRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
                },
                items: section.items.enumerated().map { i, item in
                    let ref = refs[s][i]
                    let nameBox = ref.nameLine.map {
                        NormalizedRect(x: $0.box.minX, y: $0.box.minY, width: $0.box.width, height: $0.box.height)
                    } ?? item.bbox
                    let region = regionHull(for: ref)
                    return MenuItemEntry(
                        originalName: item.originalName,
                        chineseName: item.chineseName,
                        price: item.price,
                        originalDescription: item.originalDescription,
                        chineseDescription: item.chineseDescription,
                        bbox: nameBox,
                        photoBBox: item.photoBBox,
                        descriptionBBox: region?.hull,
                        descriptionLines: region?.lines,
                        tags: item.tags
                    )
                }
            )
        }
        return MenuDocument(
            sourceLanguage: document.sourceLanguage,
            sourceLanguageChinese: document.sourceLanguageChinese,
            restaurantName: document.restaurantName,
            sections: sections
        )
    }

    // MARK: - OCR

    private static func recognizeLines(in image: UIImage) -> [Line] {
        let source = image.normalizedOrientation()
        guard let cg = source.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results
        else { return [] }
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return Line(
                text: candidate.string,
                box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            )
        }
    }

    // MARK: - Fuzzy text matching

    /// Case/diacritic/punctuation-insensitive containment matching, scored by
    /// length overlap; a shared 8-char prefix counts as a weak match.
    /// The same dish name can be printed more than once (set-menu boxes!),
    /// so the text score is discounted by the distance to the VLM's block —
    /// among equal texts, the spatially closest line wins.
    private static func bestMatch(for name: String, in lines: [Line], near vlmRect: CGRect) -> Line? {
        let target = normalize(name)
        guard target.count >= 4 else { return nil }
        var best: (score: Double, line: Line)?
        for line in lines {
            let candidate = normalize(line.text)
            guard candidate.count >= 4 else { continue }
            var score = 0.0
            if candidate.contains(target) || target.contains(candidate) {
                score = Double(min(candidate.count, target.count))
                    / Double(max(candidate.count, target.count))
            } else {
                let k = min(8, min(candidate.count, target.count))
                if k >= 6, candidate.prefix(k) == target.prefix(k) {
                    score = 0.55
                }
            }
            guard score > 0.45 else { continue }
            let distance = abs(line.box.midX - vlmRect.midX) + abs(line.box.midY - vlmRect.midY)
            let adjusted = score - 1.2 * Double(distance)
            if adjusted > (best?.score ?? -1) {
                best = (adjusted, line)
            }
        }
        return best?.line
    }

    private static func normalize(_ string: String) -> String {
        String(
            string.lowercased()
                .folding(options: [.diacriticInsensitive], locale: nil)
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
        )
    }
}
