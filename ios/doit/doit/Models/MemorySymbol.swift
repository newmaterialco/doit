import UIKit

enum MemorySymbol {
    static let defaultSymbol = "menucard"

    private static let keywordRules: [(keywords: [String], symbol: String)] = [
        (["contact", "phone", "associate", "wife", "husband", "partner", "manager", "coworker", "full name"], "person.crop.circle"),
        (["flight", "travel", "airport", "relocation", "relocate", "london move", "trip"], "airplane"),
        (["hik", "yellowstone", "outdoor", "trail", "mountain", "camp"], "figure.hiking"),
        (["email", "inbox", "signoff", "sign-off", "sign off"], "envelope.fill"),
        (["address", "san francisco", "redwood", "storage", "apartment", "home"], "house.fill"),
        (["company", "client", "business", "consultancy", "new material"], "building.2.fill"),
        (["fish", "fishing", "fly fishing"], "fish.fill"),
        (["coffee", "tea", "latte", "drink"], "cup.and.saucer.fill"),
        (["calendar", "schedule", "weekday"], "calendar"),
        (["research", "subreddit", "reddit"], "magnifyingglass"),
        (["ai", "robotics", "training data", "niche"], "cpu"),
    ]

    static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, cleaned != ".", cleaned.count <= 80 else { return nil }
        return cleaned
    }

    static func infer(title: String, body: String) -> String {
        let haystack = "\(title) \(body)".lowercased()
        for rule in keywordRules {
            if rule.keywords.contains(where: { haystack.contains($0) }) {
                return rule.symbol
            }
        }
        return defaultSymbol
    }

    static func resolve(stored: String?, title: String, body: String) -> String {
        if let stored = sanitize(stored) {
            return stored
        }
        return infer(title: title, body: body)
    }

    static func passbookSymbol(stored: String?, title: String, body: String) -> String {
        let candidate = resolve(stored: stored, title: title, body: body)
        if UIImage(systemName: candidate) != nil {
            return candidate
        }
        if UIImage(systemName: defaultSymbol) != nil {
            return defaultSymbol
        }
        return "circle.fill"
    }
}

extension AgentMemory {
    var effectiveSymbolName: String {
        MemorySymbol.passbookSymbol(stored: symbol_name, title: title, body: body)
    }
}
