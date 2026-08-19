#if DEBUG
import CoreImage
import SwiftUI
import UIKit

/// Debug-only fixture: a synthetic French menu photo drawn with CoreGraphics,
/// plus the `MenuDocument` a perfect analysis of it would return. Lets us
/// exercise the whole pipeline — gloss rendering, photo cropping from bboxes,
/// and PDF generation — in the simulator with no API key and no real photo.
/// The bboxes below are hand-matched to the drawing code; keep them in sync.
enum SampleData {
    // MARK: - The synthetic menu photo (1000 x 1400)

    static func sampleImage() -> UIImage {
        let size = CGSize(width: 1000, height: 1400)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            func text(_ string: String, _ pt: CGFloat, _ weight: UIFont.Weight, at point: CGPoint, color: UIColor = .black) {
                (string as NSString).draw(
                    at: point,
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: pt, weight: weight),
                        .foregroundColor: color,
                    ])
            }

            /// A colored rounded rect standing in for a printed dish photo.
            func dishPhoto(_ rect: CGRect, _ color: UIColor, _ label: String) {
                color.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
                text(label, 26, .bold, at: CGPoint(x: rect.minX + 14, y: rect.minY + 12), color: .white)
            }

            // Header
            text("Chez Camille", 52, .bold, at: CGPoint(x: 330, y: 50))
            text("· Bistro Parisien ·", 24, .regular, at: CGPoint(x: 400, y: 120), color: .darkGray)

            // Section: Entrées (y ≈ 200)
            text("Entrées", 38, .semibold, at: CGPoint(x: 80, y: 200))

            // Item 1 text block (y ≈ 270), photo on the right
            text("Soupe à l'oignon gratinée", 30, .medium, at: CGPoint(x: 80, y: 270))
            text("Oignons caramélisés, croûtons, fromage fondu", 20, .regular,
                 at: CGPoint(x: 80, y: 315), color: .darkGray)
            text("9,50 €", 26, .regular, at: CGPoint(x: 80, y: 355))
            dishPhoto(CGRect(x: 640, y: 250, width: 280, height: 180), UIColor(red: 0.80, green: 0.52, blue: 0.25, alpha: 1), "🧅 soupe")

            // Item 2 text block (y ≈ 480), no photo
            text("Salade de chèvre chaud", 30, .medium, at: CGPoint(x: 80, y: 480))
            text("Fromage de chèvre rôti sur toast, miel, noix", 20, .regular,
                 at: CGPoint(x: 80, y: 525), color: .darkGray)
            text("11,00 €", 26, .regular, at: CGPoint(x: 80, y: 565))

            // Section: Plats (y ≈ 700)
            text("Plats", 38, .semibold, at: CGPoint(x: 80, y: 700))

            // Item 3 text block (y ≈ 770), photo on the right
            text("Confit de canard", 30, .medium, at: CGPoint(x: 80, y: 770))
            text("Cuisse de canard confite, pommes sarladaises", 20, .regular,
                 at: CGPoint(x: 80, y: 815), color: .darkGray)
            text("19,50 €", 26, .regular, at: CGPoint(x: 80, y: 855))
            dishPhoto(CGRect(x: 640, y: 750, width: 280, height: 180), UIColor(red: 0.55, green: 0.30, blue: 0.18, alpha: 1), "🦆 canard")

            // Item 4 text block (y ≈ 990), photo on the right
            text("Steak frites, sauce au poivre", 30, .medium, at: CGPoint(x: 80, y: 990))
            text("Entrecôte grillée, frites maison", 20, .regular,
                 at: CGPoint(x: 80, y: 1035), color: .darkGray)
            text("22,00 €", 26, .regular, at: CGPoint(x: 80, y: 1075))
            dishPhoto(CGRect(x: 640, y: 970, width: 280, height: 180), UIColor(red: 0.45, green: 0.25, blue: 0.20, alpha: 1), "🥩 steak")

            text("Service compris · Prix nets", 18, .regular,
                 at: CGPoint(x: 370, y: 1330), color: .gray)
        }
    }

    /// The sample menu warped into a fake hand-held photo: tilted with
    /// perspective and dropped onto a gray "table" background. Exercises the
    /// DocumentRectifier path end-to-end.
    static func warpedSampleImage() -> UIImage {
        let flat = sampleImage()
        guard let cg = flat.cgImage else { return flat }
        let ci = CIImage(cgImage: cg)
        // Core Image uses a bottom-left origin. An asymmetric quad = real tilt.
        let warped = ci.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 260, y: 1640),
            "inputTopRight": CIVector(x: 1090, y: 1710),
            "inputBottomLeft": CIVector(x: 170, y: 190),
            "inputBottomRight": CIVector(x: 1230, y: 90),
        ])
        let canvas = CIImage(color: CIColor(red: 0.35, green: 0.33, blue: 0.31))
            .cropped(to: CGRect(x: 0, y: 0, width: 1400, height: 1800))
        let composited = warped.composited(over: canvas)
        let context = CIContext()
        guard let out = context.createCGImage(composited, from: canvas.extent) else { return flat }
        return UIImage(cgImage: out)
    }

    // MARK: - The matching analysis result

    /// Fractions of the 1000 x 1400 canvas above.
    static let document = MenuDocument(
        sourceLanguage: "French",
        sourceLanguageChinese: "法语",
        restaurantName: "Chez Camille",
        sections: [
            MenuSection(
                originalTitle: "Entrées",
                chineseTitle: "前菜",
                bbox: NormalizedRect(x: 0.08, y: 0.143, width: 0.18, height: 0.036),
                items: [
                    MenuItemEntry(
                        originalName: "Soupe à l'oignon gratinée",
                        chineseName: "法式焗洋葱汤",
                        price: "9,50 €",
                        originalDescription: "Oignons caramélisés, croûtons, fromage fondu",
                        chineseDescription: "焦糖化洋葱、面包丁、融化的奶酪",
                        bbox: NormalizedRect(x: 0.08, y: 0.193, width: 0.50, height: 0.088),
                        photoBBox: NormalizedRect(x: 0.64, y: 0.179, width: 0.28, height: 0.129)
                    ),
                    MenuItemEntry(
                        originalName: "Salade de chèvre chaud",
                        chineseName: "热山羊奶酪沙拉",
                        price: "11,00 €",
                        originalDescription: "Fromage de chèvre rôti sur toast, miel, noix",
                        chineseDescription: "烤山羊奶酪配吐司、蜂蜜、核桃",
                        bbox: NormalizedRect(x: 0.08, y: 0.343, width: 0.50, height: 0.088),
                        photoBBox: nil
                    ),
                ]
            ),
            MenuSection(
                originalTitle: "Plats",
                chineseTitle: "主菜",
                bbox: NormalizedRect(x: 0.08, y: 0.50, width: 0.14, height: 0.036),
                items: [
                    MenuItemEntry(
                        originalName: "Confit de canard",
                        chineseName: "油封鸭腿",
                        price: "19,50 €",
                        originalDescription: "Cuisse de canard confite, pommes sarladaises",
                        chineseDescription: "油封鸭腿配萨尔拉风味土豆",
                        bbox: NormalizedRect(x: 0.08, y: 0.55, width: 0.50, height: 0.088),
                        photoBBox: NormalizedRect(x: 0.64, y: 0.536, width: 0.28, height: 0.129)
                    ),
                    MenuItemEntry(
                        originalName: "Steak frites, sauce au poivre",
                        chineseName: "牛排薯条配黑胡椒汁",
                        price: "22,00 €",
                        originalDescription: "Entrecôte grillée, frites maison",
                        chineseDescription: "炭烤肋眼牛排、自制薯条",
                        bbox: NormalizedRect(x: 0.08, y: 0.707, width: 0.50, height: 0.088),
                        photoBBox: NormalizedRect(x: 0.64, y: 0.693, width: 0.28, height: 0.129)
                    ),
                ]
            ),
        ]
    )
}

#endif
