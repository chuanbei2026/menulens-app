import Foundation
import UIKit

/// Generates a small dish thumbnail with OpenAI's gpt-image-1.
/// One call per dish; callers run several calls concurrently.
struct ImageGenClient {
    var apiKey: String

    private static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!

    /// Returns a thumbnail already downscaled for storage/rendering,
    /// or nil on any failure (image generation is best-effort decoration —
    /// a failed thumbnail must never fail the scan).
    func generateDishThumbnail(name: String, chineseName: String, description: String?) async -> UIImage? {
        guard !apiKey.isEmpty else { return nil }

        var prompt = "A small appetizing overhead photo of the dish \"\(name)\" (\(chineseName))"
        if let description, !description.isEmpty {
            prompt += ", \(description)"
        }
        prompt += ". Single plate on a neutral warm background, soft light, restaurant menu thumbnail style, no text."

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
              let imageData = Data(base64Encoded: b64),
              let image = UIImage(data: imageData)
        else { return nil }

        // 1024px is overkill for a thumbnail; store at 512 to keep scans light.
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
    }
}
