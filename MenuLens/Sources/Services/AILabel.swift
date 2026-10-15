import ImageIO
import SwiftUI

/// Disclosure for AI-generated dish pictures (EU AI Act Art. 50, Korea's AI
/// Basic Act, China's labelling rules): a visible "AI" badge wherever one is
/// shown or printed, and IPTC metadata in every generated JPEG we write.
/// Crops of photos printed on the menu are real photos and get neither.
enum AILabel {
    /// IPTC NewsCodes digital source type for generative-model output.
    static let digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    static let description = "AI-generated (ForeignMenu)"

    /// JPEG bytes carrying the AI disclosure: encoded as before, then the
    /// marking added without re-encoding (see `labelled`).
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.8) -> Data? {
        guard let plain = image.jpegData(compressionQuality: quality) else { return nil }
        return labelled(plain) ?? plain
    }

    /// Adds the same marking to a JPEG already on disk (bundled sample
    /// pictures, and ones saved before the marking existed). Lossless;
    /// already-marked files are left alone.
    static func labelFile(at url: URL) {
        guard let data = try? Data(contentsOf: url), !isLabelled(data), let tagged = labelled(data) else { return }
        try? tagged.write(to: url, options: .atomic)
    }

    static func isLabelled(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        else { return false }
        return iptc[kCGImagePropertyIPTCExtDigitalSourceType] as? String == digitalSourceType
    }

    /// The image data unchanged, with XMP added: IPTC Extension
    /// DigitalSourceType, an IPTC caption and the TIFF image description.
    /// The metadata must be a CGImageMetadata — a properties dictionary is
    /// silently ignored by CGImageDestinationCopyImageSource.
    private static func labelled(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(
            metadata, "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString, "Iptc4xmpExt" as CFString, nil
        )
        CGImageMetadataSetValueWithPath(
            metadata, nil, "Iptc4xmpExt:DigitalSourceType" as CFString, digitalSourceType as CFString
        )
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, description as CFString
        )
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, description as CFString
        )
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil),
              CGImageDestinationCopyImageSource(destination, source, [
                  kCGImageDestinationMetadata: metadata,
                  kCGImageDestinationMergeMetadata: true,
              ] as CFDictionary, nil)
        else { return nil }
        return output as Data
    }

    /// The badge drawn into PDFs: a dark capsule with "AI" in the bottom
    /// trailing corner of `rect` (the drawn picture's frame).
    static func drawBadge(in rect: CGRect) {
        let fontSize = max(9, min(rect.width, rect.height) * 0.11)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let text = NSAttributedString(string: L("ai.badge"), attributes: [
            .font: font, .foregroundColor: UIColor.white,
        ])
        let textSize = text.size()
        let inset = fontSize * 0.45
        let badge = CGRect(
            x: rect.maxX - textSize.width - inset * 2 - fontSize * 0.4,
            y: rect.maxY - textSize.height - inset - fontSize * 0.4,
            width: textSize.width + inset * 2,
            height: textSize.height + inset
        )
        UIColor.black.withAlphaComponent(0.55).setFill()
        UIBezierPath(roundedRect: badge, cornerRadius: badge.height / 2).fill()
        text.draw(at: CGPoint(x: badge.minX + inset, y: badge.minY + inset / 2))
    }
}

/// The in-app badge: a small semi-transparent capsule for the corner of a
/// generated thumbnail, legible at 56–68 pt.
struct AIBadge: View {
    var body: some View {
        Text(L("ai.badge"))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(3)
            .accessibilityLabel(L("ai.badge.accessibility"))
    }
}
