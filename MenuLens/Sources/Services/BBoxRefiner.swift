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
            section.items.map {
                Ref(item: $0, nameLine: bestMatch(for: $0.originalName, in: lines, near: $0.bbox.cgRect))
            }
        }
        let matchedNameBoxes = refs.flatMap { $0 }.compactMap { $0.nameLine?.box }
        // Boundaries that end an item's territory: every other item's name
        // line, every item's VLM block (covers items whose OCR name match
        // failed), and the VLM's section-title boxes.
        let anchors = matchedNameBoxes
            + refs.flatMap { $0 }.map { $0.item.bbox.cgRect }
            + document.sections.compactMap { $0.bbox?.cgRect }

        // Pass 2 — an item's description region is EVERYTHING between its
        // name line and the next anchor below in the same column. Geometric,
        // not text-matched, so multi-line descriptions (with allergen codes,
        // hyphenated fragments, OCR errors) are replaced whole — no stripes
        // of leftover original text.
        func regionHull(for ref: Ref) -> NormalizedRect? {
            guard ref.item.originalDescription != nil else { return nil }
            let vlm = ref.item.bbox.cgRect
            // No OCR name match: treat the top edge of the VLM block as a
            // zero-height name line, so the WHOLE block (name included) gets
            // veiled and rewritten — graceful degradation instead of a
            // missing translation.
            let nameBox = ref.nameLine?.box
                ?? CGRect(x: vlm.minX, y: vlm.minY, width: vlm.width, height: 0.002)
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
            for line in lines {
                let box = line.box
                guard !matchedNameBoxes.contains(box) else { continue }
                guard box.midY > top, box.maxY <= boundary + 0.004 else { continue }
                // Skip visibly larger text (section headers and the like).
                guard box.height < nameBox.height * 1.8 + 0.004 else { continue }
                let xOverlap = min(box.maxX, colMinX + colWidth) - max(box.minX, colMinX)
                guard xOverlap > 0.5 * box.width else { continue }
                hull = hull.union(box)
            }
            guard !hull.isNull else { return nil }
            return NormalizedRect(x: hull.minX, y: hull.minY, width: hull.width, height: hull.height)
        }

        let sections = document.sections.enumerated().map { s, section in
            MenuSection(
                originalTitle: section.originalTitle,
                chineseTitle: section.chineseTitle,
                bbox: section.bbox,
                items: section.items.enumerated().map { i, item in
                    let ref = refs[s][i]
                    let nameBox = ref.nameLine.map {
                        NormalizedRect(x: $0.box.minX, y: $0.box.minY, width: $0.box.width, height: $0.box.height)
                    } ?? item.bbox
                    return MenuItemEntry(
                        originalName: item.originalName,
                        chineseName: item.chineseName,
                        price: item.price,
                        originalDescription: item.originalDescription,
                        chineseDescription: item.chineseDescription,
                        bbox: nameBox,
                        photoBBox: item.photoBBox,
                        descriptionBBox: regionHull(for: ref),
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
