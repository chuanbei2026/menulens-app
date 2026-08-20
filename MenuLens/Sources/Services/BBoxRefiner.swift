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

        let sections = document.sections.map { section in
            MenuSection(
                originalTitle: section.originalTitle,
                chineseTitle: section.chineseTitle,
                bbox: section.bbox,
                items: section.items.map { refineItem($0, lines: lines) }
            )
        }
        return MenuDocument(
            sourceLanguage: document.sourceLanguage,
            sourceLanguageChinese: document.sourceLanguageChinese,
            restaurantName: document.restaurantName,
            sections: sections
        )
    }

    private static func refineItem(_ item: MenuItemEntry, lines: [Line]) -> MenuItemEntry {
        let nameLine = bestMatch(for: item.originalName, in: lines)
        // The name bbox becomes the pure OCR line box (not the VLM's whole
        // text block) — the replace-style canvas needs line-accurate frames.
        let nameBox = nameLine.map { line in
            NormalizedRect(
                x: line.box.minX, y: line.box.minY,
                width: line.box.width, height: line.box.height
            )
        } ?? item.bbox

        var descriptionBox: NormalizedRect?
        if let description = item.originalDescription {
            descriptionBox = descriptionHull(
                for: description,
                in: lines,
                below: nameLine?.box ?? item.bbox.cgRect
            )
        }

        return MenuItemEntry(
            originalName: item.originalName,
            chineseName: item.chineseName,
            price: item.price,
            originalDescription: item.originalDescription,
            chineseDescription: item.chineseDescription,
            bbox: nameBox,
            photoBBox: item.photoBBox,
            descriptionBBox: descriptionBox,
            tags: item.tags
        )
    }

    /// Union of OCR lines that are fragments of this item's description and
    /// sit spatially near (at/below) the item's name line.
    private static func descriptionHull(for description: String, in lines: [Line], below nameBox: CGRect) -> NormalizedRect? {
        let target = normalize(description)
        guard target.count >= 8 else { return nil }
        var hull: CGRect = .null
        for line in lines {
            let candidate = normalize(line.text)
            guard candidate.count >= 6, target.contains(candidate) else { continue }
            // Spatial gate: same column region, within ~1.5 block-heights below.
            let xOverlap = min(line.box.maxX, nameBox.maxX + 0.05) - max(line.box.minX, nameBox.minX - 0.05)
            guard xOverlap > 0,
                  line.box.midY > nameBox.minY - 0.01,
                  line.box.midY < nameBox.maxY + 0.15
            else { continue }
            hull = hull.union(line.box)
        }
        guard !hull.isNull else { return nil }
        return NormalizedRect(x: hull.minX, y: hull.minY, width: hull.width, height: hull.height)
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
    private static func bestMatch(for name: String, in lines: [Line]) -> Line? {
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
            if score > 0.45, score > (best?.score ?? 0) {
                best = (score, line)
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
