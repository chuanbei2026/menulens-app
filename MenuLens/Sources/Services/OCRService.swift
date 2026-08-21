import UIKit
import Vision

/// On-device OCR: the definitive geometry source of Architecture v2.
/// Every downstream consumer (LLM prompt, renderer, item boxes) refers to
/// these lines by index — the LLM never invents coordinates.
enum OCRService {
    struct RecognizedLine {
        let text: String
        /// Normalized, top-left origin.
        let box: NormalizedRect
    }

    /// Recognize all text lines, sorted into natural reading order
    /// (top-to-bottom with left-to-right tie-breaking).
    static func recognizeLines(in image: UIImage) -> [RecognizedLine] {
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

        var lines: [RecognizedLine] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let b = obs.boundingBox // Vision: bottom-left origin
            return RecognizedLine(
                text: candidate.string,
                box: NormalizedRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            )
        }
        lines.sort { lhs, rhs in
            abs(lhs.box.y - rhs.box.y) < 0.006 ? lhs.box.x < rhs.box.x : lhs.box.y < rhs.box.y
        }
        return lines
    }
}
