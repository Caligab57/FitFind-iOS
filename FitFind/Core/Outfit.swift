import Foundation

enum BudgetTier: String, CaseIterable, Identifiable, Codable {
    case value, balanced, premium, custom, unlimited
    var id: String { rawValue }
    var title: String { self == .unlimited ? "No limit" : rawValue.capitalized }
    var cents: Int? {
        switch self {
        case .value: return 10_000
        case .balanced: return 25_000
        case .premium: return 50_000
        case .custom, .unlimited: return nil
        }
    }

    func resolvedCents(customDollars: String) -> Int? {
        self == .custom ? Budget.parseDollars(customDollars) : cents
    }

    func isValid(customDollars: String) -> Bool {
        self == .unlimited || resolvedCents(customDollars: customDollars) != nil
    }
}

enum GarmentCategory: String, Codable, CaseIterable {
    case top, bottoms, shoes, outerwear, dress, bag, accessory
    var weight: Int {
        switch self {
        case .top: return 25
        case .bottoms: return 30
        case .shoes: return 35
        case .outerwear, .dress: return 45
        case .bag: return 25
        case .accessory: return 10
        }
    }
    var symbol: String {
        switch self {
        case .top: return "tshirt"
        case .bottoms: return "figure.walk"
        case .shoes: return "shoeprints.fill"
        case .outerwear: return "jacket"
        case .dress: return "figure.stand.dress"
        case .bag: return "bag"
        case .accessory: return "sparkles"
        }
    }
}

struct Garment: Codable, Identifiable, Equatable {
    let id: String
    let category: GarmentCategory
    let name: String
    let color: String
    let details: String
    let searchQuery: String

    func shoppingURL(budgetCents: Int?) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "tbm", value: "shop"),
            URLQueryItem(name: "q", value: searchQuery + (budgetCents.map { " under \(usd($0))" } ?? ""))
        ]
        return components?.url
    }
}

struct Analysis: Codable, Equatable {
    let summary: String
    let garments: [Garment]
    let limitations: String

    func validated() throws -> Analysis {
        guard !summary.isEmpty, summary.count <= 600, limitations.count <= 600,
              garments.count <= 12, Set(garments.map { $0.id }).count == garments.count,
              garments.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.searchQuery.isEmpty &&
                  $0.name.count <= 120 && $0.color.count <= 80 &&
                  $0.details.count <= 400 && $0.searchQuery.count <= 200 }) else {
            throw AnalysisError.invalidResponse
        }
        return self
    }
}

enum AnalysisError: Error, LocalizedError {
    case invalidResponse
    var errorDescription: String? { "The recognition response was incomplete. Please try a clearer photo." }
}

enum Budget {
    static func parseDollars(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let dollars = Int(value), (1...10_000).contains(dollars) else { return nil }
        return dollars * 100
    }

    // Largest-remainder allocation preserves every cent, even with repeated categories.
    static func allocate(_ cents: Int, garments: [Garment]) -> [Int] {
        guard cents > 0, cents <= 1_000_000, !garments.isEmpty else { return [] }
        let weights = garments.map { $0.category.weight }
        let total = weights.reduce(0, +)
        var result = weights.map { cents * $0 / total }
        let remaining = cents - result.reduce(0, +)
        let order = weights.indices.sorted {
            let lhs = cents * weights[$0] % total
            let rhs = cents * weights[$1] % total
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        for index in order.prefix(remaining) { result[index] += 1 }
        return result
    }
}

func usd(_ cents: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = Locale(identifier: "en_US")
    formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
    return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "$0"
}

struct SavedLook: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let analysis: Analysis
    // A missing cap means no limit. Existing saves with an integer still decode unchanged.
    let budgetCents: Int?
}
