import Foundation
import UIKit

/// Minimal OpenAI Chat Completions client for vision + structured output.
/// One request does everything: OCR, layout extraction, translation, and the
/// word-by-word gloss — returned as strict JSON matching `MenuDocument`.
struct OpenAIClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case badHTTPStatus(Int, String)
        case emptyResponse
        case refusal(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "尚未设置 OpenAI API Key，请先在设置页填写。"
            case let .badHTTPStatus(code, body):
                return "OpenAI 请求失败（HTTP \(code)）：\(body)"
            case .emptyResponse:
                return "OpenAI 返回了空结果。"
            case let .refusal(reason):
                return "模型拒绝了这次请求：\(reason)"
            }
        }
    }

    var apiKey: String
    var model: String

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private static let systemPrompt = """
        You are a menu digitization engine. The user sends one photo of a restaurant menu. \
        Extract EVERY menu item visible in the photo and return strict JSON.

        Rules:
        - Detect the menu's language yourself. Translate everything into Simplified Chinese.
        - `words` is a word-by-word (interlinear) gloss of the item name, in reading order: \
        each token is the exact word as printed, an optional romanization (kana reading, \
        romaja, etc. — null for Latin-script languages), and its Chinese meaning. \
        Do the same for descriptions in `descriptionWords` when a description exists.
        - Every bounding box is normalized to the photo: x, y, width, height all in [0, 1], \
        origin at the top-left. `bbox` covers the item's text block. `photoBBox` covers the \
        dish's printed photo ONLY if the menu actually shows a picture for that item; \
        otherwise null. Never invent photo boxes.
        - Keep prices exactly as printed (currency symbol included). Use null when absent.
        - Group items under the menu's own section headings; if the menu has no sections, \
        return a single section with null titles.
        """

    /// The strict JSON Schema mirroring `MenuDocument`. Strict mode requires every
    /// property listed in `required` and `additionalProperties: false`; optional
    /// fields are expressed as type ["string", "null"] etc.
    private static let responseSchema: [String: Any] = {
        let normalizedRect: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "x": ["type": "number"],
                "y": ["type": "number"],
                "width": ["type": "number"],
                "height": ["type": "number"],
            ],
            "required": ["x", "y", "width", "height"],
        ]
        let wordGloss: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "text": ["type": "string"],
                "romanization": ["type": ["string", "null"]],
                "chinese": ["type": "string"],
            ],
            "required": ["text", "romanization", "chinese"],
        ]
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "originalName": ["type": "string"],
                "chineseName": ["type": "string"],
                "price": ["type": ["string", "null"]],
                "originalDescription": ["type": ["string", "null"]],
                "chineseDescription": ["type": ["string", "null"]],
                "words": ["type": "array", "items": wordGloss],
                "descriptionWords": ["type": ["array", "null"], "items": wordGloss],
                "bbox": normalizedRect,
                "photoBBox": ["anyOf": [normalizedRect, ["type": "null"]]],
            ],
            "required": [
                "originalName", "chineseName", "price",
                "originalDescription", "chineseDescription",
                "words", "descriptionWords", "bbox", "photoBBox",
            ],
        ]
        let section: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "originalTitle": ["type": ["string", "null"]],
                "chineseTitle": ["type": ["string", "null"]],
                "bbox": ["anyOf": [normalizedRect, ["type": "null"]]],
                "items": ["type": "array", "items": item],
            ],
            "required": ["originalTitle", "chineseTitle", "bbox", "items"],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "sourceLanguage": ["type": "string"],
                "sourceLanguageChinese": ["type": "string"],
                "restaurantName": ["type": ["string", "null"]],
                "sections": ["type": "array", "items": section],
            ],
            "required": ["sourceLanguage", "sourceLanguageChinese", "restaurantName", "sections"],
        ]
    }()

    func analyzeMenu(jpegData: Data) async throws -> MenuDocument {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": dataURL, "detail": "high"],
                        ],
                        [
                            "type": "text",
                            "text": "Digitize this menu photo. Return every visible item.",
                        ],
                    ],
                ],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "menu_document",
                    "strict": true,
                    "schema": Self.responseSchema,
                ],
            ],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.badHTTPStatus(http.statusCode, String(body.prefix(500)))
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let refusal: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let message = chat.choices.first?.message else { throw ClientError.emptyResponse }
        if let refusal = message.refusal { throw ClientError.refusal(refusal) }
        guard let content = message.content, let jsonData = content.data(using: .utf8) else {
            throw ClientError.emptyResponse
        }
        return try JSONDecoder().decode(MenuDocument.self, from: jsonData)
    }
}
