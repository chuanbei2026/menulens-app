import Foundation
import UIKit

/// Generates small dish thumbnails with OpenAI's gpt-image-1.
///
/// Two modes:
/// - `generateDishThumbnail`: one dish per request.
/// - `generateDishGrid`: up to 4 dishes as one 2x2 collage in a single
///   request, sliced into quadrants afterwards — ~4x cheaper per dish.
///
/// Generation is best-effort decoration: any failure returns nil and must
/// never fail the scan.
struct ImageGenClient {
    struct DishSpec {
        let name: String
        let chineseName: String
        let description: String?

        var promptFragment: String {
            var text = "\"\(name)\" (\(chineseName))"
            if let description, !description.isEmpty {
                text += ", \(description)"
            }
            return text
        }
    }

    var apiKey: String

    private static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!

    // MARK: - Single dish

    func generateDishThumbnail(_ dish: DishSpec) async -> UIImage? {
        let prompt = "A small appetizing overhead photo of the dish \(dish.promptFragment). "
            + "Single plate on a neutral warm background, soft light, "
            + "restaurant menu thumbnail style, no text."
        guard let image = await requestImage(prompt: prompt) else { return nil }
        return downscale(image, to: 512)
    }

    // MARK: - 2x2 collage (4 dishes per request)

    /// Returns one thumbnail per input dish (same order), or nil if the
    /// request failed outright. 2–4 dishes; unused quadrants are ignored.
    func generateDishGrid(_ dishes: [DishSpec]) async -> [UIImage?]? {
        guard dishes.count >= 2, dishes.count <= 4 else {
            if dishes.count == 1 {
                return [await generateDishThumbnail(dishes[0])]
            }
            return nil
        }
        let positions = ["top-left", "top-right", "bottom-left", "bottom-right"]
        var prompt = "A photo collage strictly divided into a 2x2 grid of four equal "
            + "square quadrants separated by thin straight white lines. Each quadrant "
            + "contains exactly one complete overhead dish photo filling that quadrant: "
        for (index, dish) in dishes.enumerated() {
            prompt += "\(positions[index]) quadrant: \(dish.promptFragment). "
        }
        if dishes.count < 4 {
            for index in dishes.count ..< 4 {
                prompt += "\(positions[index]) quadrant: an empty rustic wooden table surface. "
            }
        }
        prompt += "Every dish stays fully inside its own quadrant and never crosses "
            + "the grid lines. Soft light, warm neutral backgrounds, no text."

        guard let sheet = await requestImage(prompt: prompt),
              let cg = sheet.cgImage
        else { return nil }

        let cellWidth = cg.width / 2
        let cellHeight = cg.height / 2
        let origins = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        ]
        return dishes.indices.map { index in
            let origin = origins[index]
            // Inset a little to cut off the white grid lines.
            let inset = CGFloat(min(cellWidth, cellHeight)) * 0.02
            let rect = CGRect(
                x: origin.x * CGFloat(cellWidth) + inset,
                y: origin.y * CGFloat(cellHeight) + inset,
                width: CGFloat(cellWidth) - 2 * inset,
                height: CGFloat(cellHeight) - 2 * inset
            ).integral
            guard let cell = cg.cropping(to: rect) else { return nil }
            return downscale(UIImage(cgImage: cell), to: 512)
        }
    }

    // MARK: - Shared plumbing

    private func requestImage(prompt: String) async -> UIImage? {
        guard !apiKey.isEmpty else { return nil }
        let payload: [String: Any] = [
            "model": "gpt-image-1",
            "prompt": prompt,
            "size": "1024x1024",
            "quality": "low",
            "n": 1,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 120

        struct Response: Decodable {
            struct Item: Decodable { let b64_json: String? }
            let data: [Item]
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let b64 = decoded.data.first?.b64_json,
              let imageData = Data(base64Encoded: b64)
        else { return nil }
        return UIImage(data: imageData)
    }

    private func downscale(_ image: UIImage, to side: CGFloat) -> UIImage {
        guard max(image.size.width, image.size.height) > side else { return image }
        let scale = side / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
