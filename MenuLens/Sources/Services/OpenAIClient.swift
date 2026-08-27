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
                return L("error.missingKey")
            case let .badHTTPStatus(code, body):
                return L("error.http", code, body)
            case .emptyResponse:
                return L("error.emptyResponse")
            case let .refusal(reason):
                return L("error.refusal", reason)
            case .badLineIndex:
                return L("error.badLineIndex")
            }
        }
    }

    var apiKey: String
    var model: String
    /// Language the menu gets translated into (prompt name, e.g. "Japanese").
    var targetLanguage: String = "Simplified Chinese"

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Bump when the prompt or schema changes so stale cache entries miss.
    private static let promptVersion = "v16"

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
        3. Group the dishes: for each dish report `originalName` — the dish name ALONE, \
        without its price and without bracketed dietary codes like [GF] or [VG] — and \
        `translatedName`, the translation ALONE (never append the source name in \
        parentheses). A translated name must stand on its own: when the printed \
        name omits the dish type ("Clásico", "Limeño" on a cebiche menu), name the \
        dish in the target language ("经典酸橘汁腌鱼"), don't transliterate. Also its name line index, its description \
        line indices (reading order; empty array if none), the price EXACTLY as printed \
        (null if absent), its section (original + translated title, and the section \
        title's line index, -1 when the menu has no section headings), dietary `tags` \
        (menu markings first, then culinary knowledge; mark every meat the dish \
        actually contains — pork, chicken, beef, lamb, seafood — since diners use \
        these to avoid what they don't eat), and \
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
                        "enum": [
                            "vegan", "vegetarian", "gluten_free",
                            "contains_pork", "contains_chicken", "contains_beef",
                            "contains_lamb", "contains_seafood",
                        ],
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

    /// `onProgress` reports how many text lines the model has translated so
    /// far (0 while it is still thinking), so the UI can show real movement
    /// instead of a single page counter stuck at 0/1.
    func analyzeMenu(
        jpegData: Data,
        ocrLines: [OCRService.RecognizedLine],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> MenuDocument {
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
            onProgress?(ocrLines.count)
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
            "stream": true,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "menu_lines",
                    "strict": true,
                    "schema": Self.responseSchema(),
                ],
            ],
        ]
        if model.hasPrefix("gpt-5") || model.hasPrefix("o") {
            // Reasoning models spend most of the wall clock thinking before
            // emitting a single token. Menu translation is a transcription
            // task, not a puzzle — low effort keeps the quality and cuts the
            // silent wait roughly in half.
            payload["reasoning_effort"] = "low"
        } else {
            // Only the reasoning family rejects a custom temperature.
            payload["temperature"] = 0.2
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // Reasoning models can spend minutes on a dense page. Streaming keeps
        // the connection busy (so idle timeouts stop firing) and, more
        // importantly, lets us count translated lines as they arrive.
        request.timeoutInterval = 420

        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    let refusal: String?
                }
                let delta: Delta
            }
            let choices: [Choice]
        }

        func streamContent() async throws -> String {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 500 { break } }
                throw ClientError.badHTTPStatus(http.statusCode, String(body.prefix(500)))
            }
            var content = ""
            var refusal = ""
            var reported = 0
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                      let delta = chunk.choices.first?.delta
                else { continue }
                if let text = delta.refusal { refusal += text }
                guard let text = delta.content else { continue }
                content += text
                // Each translated line object in the response carries one
                // "index" key — a free, honest progress counter.
                let seen = content.components(separatedBy: "\"index\"").count - 1
                if seen != reported {
                    reported = seen
                    onProgress?(min(seen, ocrLines.count))
                }
            }
            if !refusal.isEmpty { throw ClientError.refusal(refusal) }
            guard !content.isEmpty else { throw ClientError.emptyResponse }
            return content
        }

        var content = ""
        for attempt in 0 ..< 2 {
            do {
                content = try await streamContent()
                break
            } catch {
                // One retry for timeouts and dropped connections; anything
                // else (or a second failure) surfaces to the caller.
                let code = (error as? URLError)?.code
                let transient: Set<URLError.Code> = [
                    .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
                ]
                guard attempt == 0, let code, transient.contains(code) else { throw error }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard let jsonData = content.data(using: .utf8) else { throw ClientError.emptyResponse }

        let wire = try JSONDecoder().decode(WireResponse.self, from: jsonData)
        let document = try Self.assemble(wire: wire, ocrLines: ocrLines)
        if let encoded = try? JSONEncoder().encode(document) {
            ResponseCache.store(cacheKey, encoded)
        }
        return document
    }

    // MARK: - Sanitizers

    /// The name as printed often carries the price and dietary codes on the
    /// same OCR line ("TANDOORI PANEER [GF] [VG] $14.99"). The list shows
    /// price and tags in their own columns, so strip them from the name.
    private static func cleanName(_ raw: String) -> String {
        var text = raw
        for pattern in [
            #"[\[(（]\s?[A-Za-z]{1,4}\s?[\])）]"#,          // [GF] (VG)
            #"[$¥€£]\s?\d+(?:[.,]\d{1,2})?"#,             // $14.99
            #"\d+(?:[.,]\d{1,2})?\s?[€$¥£]"#,             // 12,50 €
            #"\s+\d{1,3}(?:[.,]\d{1,2})?\s*$"#,          // trailing " 34"
            #"\s{2,}"#,
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: pattern == #"\s{2,}"# ? " " : "",
                options: .regularExpression
            )
        }
        return text
            .trimmingCharacters(in: CharacterSet(charactersIn: " ·-–—:;,.、，"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Models sometimes echo the source inside the translation
    /// ("烤潘尼尔奶酪（Tandoori Paneer）"). The original is right there on the
    /// page, so drop any parenthetical that is essentially Latin text.
    private static func cleanTranslation(_ raw: String) -> String {
        var text = raw
        for pattern in [#"（[^（）]*[A-Za-z][^（）]*）"#, #"\([^()]*[A-Za-z][^()]*\)"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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

        // Dishes → sections. Grouped BY HEADING, not by adjacency: menus
        // interleave dishes under one heading across columns, and treating
        // each run as its own section duplicated the heading (and its
        // translation) two or three times.
        var sections: [MenuSection] = []
        var sectionIndexByKey: [String: Int] = [:]

        for dish in wire.dishes {
            guard ocrLines.indices.contains(dish.nameLine) else { continue }

            // The model can mis-index a line (a neighbouring column's text,
            // typically). Geometry is ours to check: a description line must
            // sit at/below its dish name, close by, and share the name's
            // column — otherwise the canvas would rewrite someone else's text.
            let nameBox = ocrLines[dish.nameLine].box.cgRect
            let plausible = dish.descriptionLines.filter { index in
                guard ocrLines.indices.contains(index) else { return false }
                let box = ocrLines[index].box.cgRect
                guard box.midY > nameBox.minY - 0.004, box.minY < nameBox.maxY + 0.16 else { return false }
                let overlap = min(box.maxX, nameBox.maxX + 0.10) - max(box.minX, nameBox.minX - 0.04)
                return overlap > 0.3 * min(box.width, max(nameBox.width, 0.05))
            }
            let descBoxes = plausible.map { ocrLines[$0].box }
            let originalDescription = plausible
                .map { ocrLines[$0].text }
                .joined(separator: " ")
            var hull: NormalizedRect?
            if let first = descBoxes.first {
                var rect = first.cgRect
                for b in descBoxes.dropFirst() { rect = rect.union(b.cgRect) }
                hull = NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            }

            // The model sometimes fills only the per-LINE translations and
            // leaves the dish-level description empty. Those lines are this
            // dish's description, so stitch them back together rather than
            // dropping the translation.
            let stitched = plausible
                .compactMap { roleByIndex[$0]?.translated }
                .filter { !$0.isEmpty }
                .joined()
            let translatedDescription = dish.translatedDescription.isEmpty ? stitched : dish.translatedDescription

            let item = MenuItemEntry(
                originalName: cleanName(dish.originalName),
                chineseName: cleanTranslation(dish.translatedName),
                price: dish.price,
                originalDescription: originalDescription.isEmpty ? nil : originalDescription,
                chineseDescription: translatedDescription.isEmpty ? nil : translatedDescription,
                bbox: try box(dish.nameLine),
                photoBBox: dish.photoBBox,
                descriptionBBox: hull,
                descriptionLines: descBoxes.isEmpty ? nil : descBoxes,
                tags: dish.tags.isEmpty ? nil : dish.tags
            )

            let key = dish.sectionOriginal ?? dish.sectionTranslated ?? "line\(dish.sectionTitleLine)"
            if let existing = sectionIndexByKey[key] {
                var section = sections[existing]
                sections[existing] = MenuSection(
                    originalTitle: section.originalTitle,
                    chineseTitle: section.chineseTitle,
                    bbox: section.bbox,
                    items: section.items + [item]
                )
                _ = section
            } else {
                sectionIndexByKey[key] = sections.count
                sections.append(MenuSection(
                    originalTitle: dish.sectionOriginal,
                    chineseTitle: dish.sectionTranslated,
                    bbox: ocrLines.indices.contains(dish.sectionTitleLine)
                        ? ocrLines[dish.sectionTitleLine].box : nil,
                    items: [item]
                ))
            }
        }

        return MenuDocument(
            sourceLanguage: wire.sourceLanguage,
            sourceLanguageChinese: wire.sourceLanguageChinese,
            restaurantName: wire.restaurantName,
            sections: sections,
            textLines: textLines
        )
    }
}
