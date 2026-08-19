import CoreImage
import UIKit
import Vision

/// Perspective-corrects a hand-held photo of a menu.
///
/// Detects the menu sheet with Vision's document segmentation, then warps the
/// detected quad into a straight rectangle with CIPerspectiveCorrection and
/// crops the background away. Everything downstream (the VLM's bboxes, layout
/// rendering, photo crops) then works on a clean, straight base.
///
/// Falls back to the original image when no confident, reasonably large
/// document is found (e.g. our synthetic sample, or a full-frame flat scan).
enum DocumentRectifier {
    /// Normalized corner quad of the detected menu sheet (bottom-left origin).
    private struct Quad {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomLeft: CGPoint
        let bottomRight: CGPoint

        var area: CGFloat {
            polygonArea([topLeft, topRight, bottomRight, bottomLeft])
        }
    }

    static func rectify(_ image: UIImage) -> UIImage {
        let source = image.normalizedOrientation()
        guard let cg = source.cgImage else { return source }

        // Ignore detections that cover only a small part of the frame —
        // warping to a receipt-sized sliver would destroy the menu.
        guard let quad = detectQuad(in: cg), quad.area > 0.35 else {
            // Last resort (e.g. simulator, screenshots with app chrome):
            // crop to the hull of recognized text lines. No perspective fix,
            // but it removes status bars, UI buttons, and table background.
            return textHullCrop(cg) ?? source
        }

        let ciImage = CIImage(cgImage: cg)
        let size = ciImage.extent.size
        // Vision returns normalized points with a bottom-left origin,
        // matching Core Image's coordinate space.
        func scaled(_ point: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: point.x * size.width, y: point.y * size.height))
        }

        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": scaled(quad.topLeft),
            "inputTopRight": scaled(quad.topRight),
            "inputBottomLeft": scaled(quad.bottomLeft),
            "inputBottomRight": scaled(quad.bottomRight),
        ])

        let context = CIContext()
        guard let output = context.createCGImage(corrected, from: corrected.extent)
        else { return source }
        let straightened = UIImage(cgImage: output)

        // CIPerspectiveCorrection's output aspect comes from the quad's pixel
        // footprint, which understates the dimension that was tilted away.
        // Restore the sheet's true aspect from the average opposite-edge
        // lengths of the detected quad.
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = (a.x - b.x) * size.width
            let dy = (a.y - b.y) * size.height
            return (dx * dx + dy * dy).squareRoot()
        }
        let trueWidth = (distance(quad.topLeft, quad.topRight) + distance(quad.bottomLeft, quad.bottomRight)) / 2
        let trueHeight = (distance(quad.topLeft, quad.bottomLeft) + distance(quad.topRight, quad.bottomRight)) / 2
        guard trueWidth > 0, trueHeight > 0 else { return straightened }

        let targetWidth = straightened.size.width
        let targetSize = CGSize(width: targetWidth, height: (targetWidth * trueHeight / trueWidth).rounded())
        guard abs(targetSize.height - straightened.size.height) > 4 else { return straightened }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            straightened.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// ML document segmentation first (best quality, real devices), falling
    /// back to classic rectangle detection (works everywhere, incl. the
    /// simulator where Vision's ML models may be unavailable).
    private static func detectQuad(in cg: CGImage) -> Quad? {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        let docRequest = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([docRequest])) != nil,
           let obs = docRequest.results?.first, obs.confidence > 0.8 {
            return Quad(topLeft: obs.topLeft, topRight: obs.topRight,
                        bottomLeft: obs.bottomLeft, bottomRight: obs.bottomRight)
        }

        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.maximumObservations = 3
        rectRequest.minimumConfidence = 0.6
        rectRequest.minimumAspectRatio = 0.3
        rectRequest.minimumSize = 0.35
        rectRequest.quadratureTolerance = 30
        if (try? handler.perform([rectRequest])) != nil,
           let best = rectRequest.results?.max(by: { lhs, rhs in
               Quad(topLeft: lhs.topLeft, topRight: lhs.topRight,
                    bottomLeft: lhs.bottomLeft, bottomRight: lhs.bottomRight).area
                   < Quad(topLeft: rhs.topLeft, topRight: rhs.topRight,
                          bottomLeft: rhs.bottomLeft, bottomRight: rhs.bottomRight).area
           }) {
            return Quad(topLeft: best.topLeft, topRight: best.topRight,
                        bottomLeft: best.bottomLeft, bottomRight: best.bottomRight)
        }
        return nil
    }

    /// Crop to the bounding hull of all recognized text lines (+3% margin).
    /// Returns nil when there is too little text or the hull is implausible.
    private static func textHullCrop(_ cg: CGImage) -> UIImage? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, observations.count >= 5
        else { return nil }

        // Trimmed hull: sparse UI chrome (status clock, photo-app captions)
        // contributes only a handful of boxes, while the menu body has
        // dozens — quantile-trim the centers, then keep boxes near the dense
        // band and take their union.
        let boxes = observations.map(\.boundingBox)
        func quantile(_ sorted: [CGFloat], _ q: Double) -> CGFloat {
            let position = q * Double(sorted.count - 1)
            return sorted[Int(position.rounded())]
        }
        let ys = boxes.map(\.midY).sorted()
        let xs = boxes.map(\.midX).sorted()
        let yBand = (quantile(ys, 0.06) - 0.06) ... (quantile(ys, 0.94) + 0.06)
        let xBand = (quantile(xs, 0.06) - 0.10) ... (quantile(xs, 0.94) + 0.10)
        let kept = boxes.filter { yBand.contains($0.midY) && xBand.contains($0.midX) }
        guard kept.count >= 5 else { return nil }
        var hull: CGRect = .null
        for box in kept {
            hull = hull.union(box)
        }
        guard !hull.isNull else { return nil }
        // Vision is bottom-left origin; flip to top-left and add margin.
        var crop = CGRect(
            x: hull.minX - 0.03,
            y: (1 - hull.maxY) - 0.03,
            width: hull.width + 0.06,
            height: hull.height + 0.06
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let area = crop.width * crop.height
        guard area > 0.08, area < 0.98 else { return nil }
        crop = CGRect(
            x: crop.minX * CGFloat(cg.width),
            y: crop.minY * CGFloat(cg.height),
            width: crop.width * CGFloat(cg.width),
            height: crop.height * CGFloat(cg.height)
        ).integral
        guard let cropped = cg.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// Shoelace area of a polygon in normalized (0...1) coordinates.
    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2
    }
}
