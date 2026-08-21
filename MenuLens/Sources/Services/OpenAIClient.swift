import Foundation
import UIKit

/// Architecture v2 client: the request carries the OCR line inventory
/// (indices + text) plus a LOW-detail reference image; the model classifies
/// and translates lines and groups dishes — referring to lines strictly by
/// index. Geometry lives entirely on our side.
struct OpenAIClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case badHTTPStatus(Int, String)
        case emptyResponse
        case refusal(String)
        case badLineIndex

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
            case .badLineIndex:
                return "模型返回了无效的行号。"
            }
        }
    }

    var apiKey: String
    var model: String
    /// Language the menu gets translated into (prompt name, e.g. "Japanese").
    var targetLanguage: String = "Simplified Chinese"

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Bump when the prompt or schema changes so stale cache entries miss.
    private static let promptVersion = "v11"

    private var systemPrompt: String {
        """
        You are a menu translation engine. You receive (a) a reference photo of one \
        restaurant menu page and (b) the DEFINITIVE list of OCR text lines on that page, \
        each with an index. The line list is the single source of truth for what text \
        exists and where; refer to lines ONLY by their index and never invent lines.

        Tasks:
        1. Classify EVERY line's role: section_title | dish_name | description | price | other.
        2. Translate into \(targetLanguage):
           - description and other lines: natural whole-phrase translation in `translated`;
           - dish_name and section_title lines: short translated name in `translated`;
           - lines that are purely prices/numbers/symbols: translated = "".
           `translated` must contain ONLY the translation — never repeat or
           parenthesize the original text inside it.
           Brand/logo text keeps translated = "" (leave logos untouched).
           Fix obvious OCR misreads using the photo before translating.
        3. Group the dishes: for each dish report its name line index, its description \
        line indices (reading order; empty array if none), the price EXACTLY as printed \
        (null if absent), its section (original + translated title, and the section \
        title's line index, -1 when the menu has no section headings), dietary `tags` \
        (menu markings first, then culinary knowledge; only confident values), and \
        `photoBBox` — the printed photo of the dish on the page, as x/y/width/height \
        normalized to the photo with top-left origin, ONLY if such a photo exists, \
        else null.
        4. Also report the menu's language, that language's name written in \
        \(targetLanguage), and the restaurant name (null if not printed).
        """
    }

    private static func responseSchema() -> [String: Any] {
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
        let line: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "index": ["type": "integer"],
                "role": ["type": "string", "enum": ["section_title", "dish_name", "description", "price", "other"]],
                "translated": ["type": "string"],
            ],
            "required": ["index", "role", "translated"],
        ]
        let dish: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "originalName": ["type": "string"],
                "translatedName": ["type": "string"],
                "nameLine": ["type": "integer"],
                "descriptionLines": ["type": "array", "items": ["type": "integer"]],
                "translatedDescription": ["type": "string"],
                "price": ["type": ["string", "null"]],
                "sectionOriginal": ["type": ["string", "null"]],
                "sectionTranslated": ["type": ["string", "null"]],
                "sectionTitleLine": ["type": "integer"],
                "tags": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": ["vegan", "vegetarian", "gluten_free", "contains_lamb", "contains_seafood"],
                    ],
                ],
                "photoBBox": ["anyOf": [normalizedRect, ["type": "null"]]],
            ],
            "required": [
                "originalName", "translatedName", "nameLine", "descriptionLines",
                "translatedDescription", "price", "sectionOriginal", "sectionTranslated",
                "sectionTitleLine", "tags", "photoBBox",
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "sourceLanguage": ["type": "string"],
                "sourceLanguageChinese": ["type": "string"],
                "restaurantName": ["type": ["string", "null"]],
                "lines": ["type": "array", "items": line],
                "dishes": ["type": "array", "items": dish],
            ],
            "required": ["sourceLanguage", "sourceLanguageChinese", "restaurantName", "lines", "dishes"],
        ]
    }

    // MARK: - Wire types

    private struct WireLine: Decodable {
        let index: Int
        let role: String
        let translated: String
    }

    private struct WireDish: Decodable {
        let originalName: String
        let translatedName: String
        let nameLine: Int
        let descriptionLines: [Int]
        let translatedDescription: String
        let price: String?
        let sectionOriginal: String?
        let sectionTranslated: String?
        let sectionTitleLine: Int
        let tags: [String]
        let photoBBox: NormalizedRect?
    }

    private struct WireResponse: Decodable {
        let sourceLanguage: String
        let sourceLanguageChinese: String
        let restaurantName: String?
        let lines: [WireLine]
        let dishes: [WireDish]
    }

    // MARK: - Request

    func analyzeMenu(jpegData: Data, ocrLines: [OCRService.RecognizedLine]) async throws -> MenuDocument {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        let inventory = ocrLines.enumerated()
            .map { "\($0.offset): \($0.element.text)" }
            .joined(separator: "\n")

        // Identical request → cached result, no API call.
        let cacheKey = ResponseCache.key([
            jpegData,
            Data(inventory.utf8),
            Data("\(model)|\(targetLanguage)|\(Self.promptVersion)".utf8),
        ])
        if let cached = ResponseCache.load(cacheKey),
           let document = try? JSONDecoder().decode(MenuDocument.self, from: cached) {
            return document
        }

        let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": dataURL, "detail": "low"],
                        ],
                        [
                            "type": "text",
                            "text": "OCR lines (index: text):\n" + inventory,
                        ],
                    ],
                ],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "menu_lines",
                    "strict": true,
                    "schema": Self.responseSchema(),
                ],
            ],
        ]
        // Reasoning-family models only accept the default temperature.
        if !model.hasPrefix("gpt-5") && !model.hasPrefix("o") {
            payload["temperature"] = 0.2
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 240

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
        let wire = try JSONDecoder().decode(WireResponse.self, from: jsonData)
        let document = try Self.assemble(wire: wire, ocrLines: ocrLines)
        if let encoded = try? JSONEncoder().encode(document) {
            ResponseCache.store(cacheKey, encoded)
        }
        return document
    }

    // MARK: - Assembly (wire → MenuDocument, geometry from OCR only)

    private static func assemble(wire: WireResponse, ocrLines: [OCRService.RecognizedLine]) throws -> MenuDocument {
        func box(_ index: Int) throws -> NormalizedRect {
            guard ocrLines.indices.contains(index) else { throw ClientError.badLineIndex }
            return ocrLines[index].box
        }

        var roleByIndex: [Int: WireLine] = [:]
        for line in wire.lines where ocrLines.indices.contains(line.index) {
            roleByIndex[line.index] = line
        }
        let textLines: [TextLine] = ocrLines.indices.map { index in
            let wireLine = roleByIndex[index]
            return TextLine(
                role: wireLine?.role ?? "other",
                original: ocrLines[index].text,
                translated: wireLine?.translated ?? "",
                box: ocrLines[index].box
            )
        }

        // Dishes → sections (grouped by consecutive section titles).
        var sections: [MenuSection] = []
        var currentTitle: (original: String?, translated: String?, bbox: NormalizedRect?) = (nil, nil, nil)
        var currentItems: [MenuItemEntry] = []
        func flush() {
            guard !currentItems.isEmpty else { return }
            sections.append(MenuSection(
                originalTitle: currentTitle.original,
                chineseTitle: currentTitle.translated,
                bbox: currentTitle.bbox,
                items: currentItems
            ))
            currentItems = []
        }

        for dish in wire.dishes {
            guard ocrLines.indices.contains(dish.nameLine) else { continue }
            if dish.sectionOriginal != currentTitle.original {
                flush()
                currentTitle = (
                    dish.sectionOriginal,
                    dish.sectionTranslated,
                    ocrLines.indices.contains(dish.sectionTitleLine)
                        ? ocrLines[dish.sectionTitleLine].box : nil
                )
            }
            let descBoxes = dish.descriptionLines
                .filter { ocrLines.indices.contains($0) }
                .map { ocrLines[$0].box }
            let originalDescription = dish.descriptionLines
                .filter { ocrLines.indices.contains($0) }
                .map { ocrLines[$0].text }
                .joined(separator: " ")
            var hull: NormalizedRect?
            if let first = descBoxes.first {
                var rect = first.cgRect
                for b in descBoxes.dropFirst() { rect = rect.union(b.cgRect) }
                hull = NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            }
            currentItems.append(MenuItemEntry(
                originalName: dish.originalName,
                chineseName: dish.translatedName,
                price: dish.price,
                originalDescription: originalDescription.isEmpty ? nil : originalDescription,
                chineseDescription: dish.translatedDescription.isEmpty ? nil : dish.translatedDescription,
                bbox: try box(dish.nameLine),
                photoBBox: dish.photoBBox,
                descriptionBBox: hull,
                descriptionLines: descBoxes.isEmpty ? nil : descBoxes,
                tags: dish.tags.isEmpty ? nil : dish.tags
            ))
        }
        flush()

        return MenuDocument(
            sourceLanguage: wire.sourceLanguage,
            sourceLanguageChinese: wire.sourceLanguageChinese,
            restaurantName: wire.restaurantName,
            sections: sections,
            textLines: textLines
        )
    }
}
