import CoreImage
import UIKit

/// Background reconstruction for seamless text replacement.
///
/// Instead of covering original text with a flat sampled color (visible as
/// patches), we build a **text-free plate** of the whole page and erase by
/// copying the plate's own pixels at that exact position — the patch inherits
/// the paper's texture, grain and lighting, so the seam disappears.
///
/// Building the plate takes two filters that each solve half the problem,
/// measured on a real menu photo (true paper = 218.3 of 255):
///
/// | plate               | tone over text | text removed? |
/// |---------------------|----------------|---------------|
/// | closing (max→min)   | 233.0 (+14.7)  | yes           |
/// | median ×5           | 217.7 (−0.7)   | no (ghosts)   |
/// | closing − bias field| 221.0 (+2.7)   | yes           |
///
/// Dilation takes the brightest pixel in its window, so the closing runs
/// bright — bright enough that erased line tails read as pale halos. The
/// median plate keeps the true paper tone but leaves glyphs behind. So: erase
/// with the closing, then subtract the low-frequency difference between the
/// two as a local bias field. Text gone, tone matched.
enum PaperPlate {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Which background treatment the renderer should apply.
    struct Options {
        /// Erase by copying the text-free plate (vs. flat sampled fills).
        var usePlate = true
        /// Paint the illumination-flattened page instead of the raw photo.
        var flattenLighting = false

        static var current: Options {
            let args = ProcessInfo.processInfo.arguments
            let stored = (UserDefaults.standard.object(forKey: "flatten_lighting") as? Bool) ?? true
            return Options(
                usePlate: !args.contains("-plateOff"),
                flattenLighting: !args.contains("-flattenOff") && (args.contains("-flatten") || stored)
            )
        }
    }

    /// Build whatever the current options ask for, in one place.
    static func prepare(_ image: UIImage, options: Options = .current) -> (plate: UIImage?, background: UIImage?) {
        guard options.usePlate || options.flattenLighting else { return (nil, nil) }
        let plate = textFree(from: image)
        // Division-based flattening assumes light paper. On a dark or heavily
        // colored menu it would bleach the design, so skip it there.
        let flatten = options.flattenLighting && isLightPaper(image)
        let background = flatten ? flattened(image, plate: plate) : nil
        // When flattening, the plate must match the painted background.
        let matchedPlate: UIImage?
        if options.usePlate {
            matchedPlate = background.flatMap { textFree(from: $0) } ?? plate
        } else {
            matchedPlate = nil
        }
        return (matchedPlate, background)
    }

    /// Per-channel mean (0...1, sRGB-encoded) of a region.
    private static func average(_ image: CIImage, in rect: CGRect) -> (CGFloat, CGFloat, CGFloat)? {
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let averaged = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect),
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            averaged, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    /// Mean luminance test — light paper is the case flattening is built for.
    private static func isLightPaper(_ image: UIImage) -> Bool {
        guard let cg = image.normalizedOrientation().cgImage else { return false }
        let source = CIImage(cgImage: cg)
        let averaged = source.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: source.extent),
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            averaged, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let luminance = (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
        return luminance > 0.55
    }

    /// Text-free reconstruction of the page (nil if the filters fail).
    /// `strokeRadius` should exceed the thickness of body-text strokes.
    static func textFree(from image: UIImage, strokeRadius: CGFloat = 4) -> UIImage? {
        guard let cg = image.normalizedOrientation().cgImage else { return nil }
        let source = CIImage(cgImage: cg)

        // Closing = dilate then erode: removes dark thin strokes, keeps the
        // extent of genuinely large dark areas (photos, rules, banners).
        let closing = source
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: strokeRadius])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: strokeRadius])
            .cropped(to: source.extent)

        // Median keeps the true paper tone (glyphs survive faintly), so it
        // serves as the reference the closing gets calibrated against.
        var median = source
        for _ in 0 ..< 5 {
            median = median.applyingFilter("CIMedianFilter").cropped(to: source.extent)
        }

        let blurRadius = 18.0
        func lowFrequency(_ image: CIImage) -> CIImage {
            image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: source.extent)
        }
        // CISubtractBlendMode computes background − source.
        let biasField = lowFrequency(median)
            .applyingFilter("CISubtractBlendMode", parameters: [
                kCIInputBackgroundImageKey: lowFrequency(closing),
            ])
            .cropped(to: source.extent)
        let corrected = biasField
            .applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: closing])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0])
            .cropped(to: source.extent)

        guard let output = context.createCGImage(corrected, from: source.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    /// Illumination-flattened page: `image / lightingField`, where the field
    /// comes from a heavily blurred text-free plate (blurring the original
    /// would let dark glyphs bias the estimate). Paper becomes an even tone
    /// while print stays crisp.
    static func flattened(_ image: UIImage, plate: UIImage?) -> UIImage? {
        guard let cg = image.normalizedOrientation().cgImage,
              let plateCG = (plate ?? textFree(from: image))?.cgImage
        else { return nil }
        let source = CIImage(cgImage: cg)
        let field = CIImage(cgImage: plateCG)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: source.extent.width / 24])
            .cropped(to: source.extent)

        // CIDivideBlendMode computes background / source.
        let divided = field.applyingFilter("CIDivideBlendMode", parameters: [
            kCIInputBackgroundImageKey: source,
        ])

        // Division removes the shading but also the stock's own color: paper
        // lands on flat white. Multiply the paper tone back so the sheet keeps
        // its character (this menu's cool blue-grey, another's warm cream)
        // while staying evenly lit. The blurred plate's average IS that color.
        // CIColorMatrix multiplies in LINEAR light, so linearize it first, and
        // nudge up slightly — dark logos and photos drag the average down.
        var tinted = divided
        if let paper = average(field, in: source.extent) {
            func linear(_ channel: CGFloat) -> CGFloat {
                let value = min(channel * 1.04, 1)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            tinted = divided.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: linear(paper.0), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: linear(paper.1), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: linear(paper.2), w: 0),
            ])
        }

        let balanced = tinted.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.04,
        ]).cropped(to: source.extent)

        guard let output = context.createCGImage(balanced, from: source.extent) else { return nil }
        return UIImage(cgImage: output)
    }
}
