import Foundation

/// Dietary attributes of a dish. The model marks what it can, and a local
/// keyword pass fills the gaps — models forget, and scans made before a tag
/// existed would otherwise never carry it.
enum DietTag: String, CaseIterable, Identifiable {
    case vegan
    case vegetarian
    case glutenFree = "gluten_free"
    case pork = "contains_pork"
    case chicken = "contains_chicken"
    case beef = "contains_beef"
    case lamb = "contains_lamb"
    case seafood = "contains_seafood"

    var id: String { rawValue }

    /// Tags a diner can declare as "I don't eat this". Only ingredients we
    /// can detect POSITIVELY belong here — "gluten_free" marks a dish as
    /// safe, and its absence doesn't prove gluten is present, so offering it
    /// as a restriction would produce false alarms.
    static var avoidable: [DietTag] { [.pork, .chicken, .beef, .lamb, .seafood] }

    /// Short label used on member chips and warnings.
    var shortLabel: String {
        switch self {
        case .vegan: return "纯素"
        case .vegetarian: return "素"
        case .glutenFree: return "麸质"
        case .pork: return "猪肉"
        case .chicken: return "鸡肉"
        case .beef: return "牛肉"
        case .lamb: return "羊肉"
        case .seafood: return "海鲜"
        }
    }

    /// What a member's avoidance means in a sentence ("不吃猪肉" / "忌麸质").
    var avoidanceLabel: String {
        self == .glutenFree ? "忌麸质" : "不吃\(shortLabel)"
    }

    var badge: String {
        switch self {
        case .vegan: return "🌱"
        case .vegetarian: return "🥬"
        case .glutenFree: return "GF"
        case .pork: return "🐷"
        case .chicken: return "🐔"
        case .beef: return "🐄"
        case .lamb: return "🐑"
        case .seafood: return "🐟"
        }
    }

    /// Words that betray this ingredient in a menu's original or translated
    /// text. Kept deliberately specific — a false "contains beef" would send
    /// someone away from a dish they can eat.
    private var keywords: [String] {
        switch self {
        case .pork:
            return ["pork", "bacon", "ham ", "prosciutto", "chorizo", "pancetta", "lardo",
                    "猪", "培根", "火腿", "腊肠", "五花"]
        case .chicken:
            return ["chicken", "poulet", "pollo", "hähnchen", "鸡"]
        case .beef:
            return ["beef", "steak", "boeuf", "wagyu", "brisket", "tenderloin", "sirloin",
                    "牛肉", "牛排", "牛柳", "牛里脊", "肥牛"]
        case .lamb:
            return ["lamb", "mutton", "agneau", "cordero", "羊"]
        case .seafood:
            return ["fish", "shrimp", "prawn", "crab", "lobster", "squid", "octopus", "clam",
                    "mussel", "scallop", "oyster", "tuna", "salmon", "halibut", "anchov",
                    "seafood", "ceviche", "cebiche", "pescado", "鱼", "虾", "蟹", "龙虾",
                    "鱿鱼", "章鱼", "蛤", "贻贝", "扇贝", "生蚝", "海鲜"]
        case .vegan, .vegetarian, .glutenFree:
            return []
        }
    }

    /// Everything we know about a dish: the model's tags plus keyword hits.
    static func tags(for item: MenuItemEntry) -> Set<DietTag> {
        var result = Set((item.tags ?? []).compactMap(DietTag.init(rawValue:)))
        let haystack = [
            item.originalName, item.chineseName,
            item.originalDescription ?? "", item.chineseDescription ?? "",
        ].joined(separator: " ").lowercased()

        // A dish the menu itself calls vegetarian never gets a meat tag from
        // keywords ("beef-style tofu", "chicken-fried cauliflower").
        let declaredMeatless = result.contains(.vegan) || result.contains(.vegetarian)
        for tag in [DietTag.pork, .chicken, .beef, .lamb, .seafood] {
            guard !declaredMeatless else { break }
            if tag.keywords.contains(where: { haystack.contains($0) }) {
                result.insert(tag)
            }
        }
        return result
    }
}
