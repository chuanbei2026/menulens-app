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
        guard let quad = detectQuad(in: cg), quad.area > 0.35 else { return source }

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
        return UIImage(cgImage: output)
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
