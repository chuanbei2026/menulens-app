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
    /// Language the menu gets translated into (prompt name, e.g. "Japanese").
    /// Historical note: the JSON fields are still named chineseName /
    /// chineseDescription / sourceLanguageChinese — they hold the TARGET-
    /// language translation regardless of which target is selected.
    var targetLanguage: String = "Simplified Chinese"

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private var systemPrompt: String {
        """
        You are a menu digitization engine. The user sends one photo of a restaurant menu. \
        Extract EVERY menu item visible in the photo and return strict JSON.

        Rules:
        - Detect the menu's language yourself. Translate every dish name and every \
        description into natural \(targetLanguage) (whole-phrase translation). The fields \
        `chineseName` and `chineseDescription` hold these \(targetLanguage) translations, \
        and `sourceLanguageChinese` holds the detected language's name written in \
        \(targetLanguage).
        - `tags`: dietary attributes per dish. Trust the menu's own markings first, then \
        infer from culinary knowledge; include only values you are confident about. \
        Allowed: vegan, vegetarian, gluten_free, contains_lamb, contains_seafood.
        - Every bounding box is normalized to the photo: x, y, width, height all in [0, 1], \
        origin at the top-left. `bbox` covers the item's text block. `photoBBox` covers the \
        dish's printed photo ONLY if the menu actually shows a picture for that item; \
        otherwise null. Never invent photo boxes, and make photoBBox hug the photo tightly — \
        it must not extend past the photo's edges or past the image border.
        - Keep prices exactly as printed (currency symbol included). Use null when absent.
        - Group items under the menu's own section headings; if the menu has no sections, \
        return a single section with null titles. Translate section titles too.
        - Set menus / tasting boxes / prix-fixe boxes (e.g. an "executive lunch" box): \
        treat the WHOLE box as ONE item — name = the box title, `bbox` covers the ENTIRE \
        box including all its course/option lines, and the description lists every course \
        and option printed inside the box.
        """
    }

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
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "originalName": ["type": "string"],
                "chineseName": ["type": "string"],
                "price": ["type": ["string", "null"]],
                "originalDescription": ["type": ["string", "null"]],
                "chineseDescription": ["type": ["string", "null"]],
                "tags": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": ["vegan", "vegetarian", "gluten_free", "contains_lamb", "contains_seafood"],
                    ],
                ],
                "bbox": normalizedRect,
                "photoBBox": ["anyOf": [normalizedRect, ["type": "null"]]],
            ],
            "required": [
                "originalName", "chineseName", "price",
                "originalDescription", "chineseDescription",
                "tags", "bbox", "photoBBox",
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

    /// Bump when the prompt or schema changes so stale cache entries miss.
    private static let promptVersion = "v9"

    func analyzeMenu(jpegData: Data) async throws -> MenuDocument {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        // Identical request → cached result, no API call.
        let cacheKey = ResponseCache.key([
            jpegData,
            Data("\(model)|\(targetLanguage)|\(Self.promptVersion)".utf8),
        ])
        if let cached = ResponseCache.load(cacheKey),
           let document = try? JSONDecoder().decode(MenuDocument.self, from: cached) {
            return document
        }

        let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2, // steadier bbox geometry across runs
            "messages": [
                ["role": "system", "content": systemPrompt],
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
        let document = try JSONDecoder().decode(MenuDocument.self, from: jsonData)
        ResponseCache.store(cacheKey, jsonData)
        return document
    }
}
