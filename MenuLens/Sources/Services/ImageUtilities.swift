import UIKit

extension UIImage {
    /// Redraw so `imageOrientation` becomes `.up`. Camera photos usually carry
    /// a rotation flag; normalized bboxes from the VLM are relative to the
    /// *displayed* image, so we bake the rotation in before cropping/encoding.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Downscale so the longest edge is at most `maxDimension`, re-encode as JPEG.
    /// Keeps upload latency and token cost sane on 48MP iPhone photos.
    func jpegDataForUpload(maxDimension: CGFloat = 2000, quality: CGFloat = 0.85) -> Data? {
        let source = normalizedOrientation()
        let longest = max(source.size.width, source.size.height)
        guard longest > maxDimension else { return source.jpegData(compressionQuality: quality) }
        let scale = maxDimension / longest
        let target = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Crop a normalized rect (0...1, top-left origin) out of the image,
    /// with a small margin so tight VLM boxes don't clip the dish photo.
    func crop(normalized: NormalizedRect, margin: Double = 0.015) -> UIImage? {
        let source = normalizedOrientation()
        guard let cg = source.cgImage else { return nil }
        let full = CGSize(width: cg.width, height: cg.height)
        let padded = NormalizedRect(
            x: max(0, normalized.x - margin),
            y: max(0, normalized.y - margin),
            width: min(1 - max(0, normalized.x - margin), normalized.width + 2 * margin),
            height: min(1 - max(0, normalized.y - margin), normalized.height + 2 * margin)
        )
        let pixelRect = padded.rect(in: full).integral
        guard pixelRect.width >= 4, pixelRect.height >= 4,
              let cropped = cg.cropping(to: pixelRect)
        else { return nil }
        return UIImage(cgImage: cropped)
    }
}
