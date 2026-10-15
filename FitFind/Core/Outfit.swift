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

// Provider-retrieved listings remain alternatives, never identity or stock verification.
struct ProductListing: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let merchant: String
    let priceCents: Int
    let currency: String
    let url: String
    let imageURL: String?
    let matchType: String
    let matchReason: String

    var destination: URL? { ProductSearchResponse.merchantURL(url) }
    var thumbnail: URL? { imageURL.flatMap(ProductSearchResponse.thumbnailURL) }
}

struct GarmentProducts: Codable, Equatable {
    let garmentId: String
    let targetCents: Int?
    let products: [ProductListing]
}

struct OutfitSelection: Codable, Equatable {
    let complete: Bool
    let subtotalCents: Int
    let selectedProductIds: [String]
}

struct ProductSearchResponse: Codable, Equatable {
    let currency: String
    let budgetCents: Int?
    let searchedAt: String
    let garments: [GarmentProducts]
    let outfit: OutfitSelection
    let limitations: String
    var excludedCurrencyCount: Int? = nil

    static func secureURL(_ value: String) -> URL? {
        guard value.count <= 4_096,
              let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let url = components.url else { return nil }
        let host = rawHost.lowercased()
        guard host.contains("."), !host.contains(":"), !host.hasPrefix("["), !host.hasSuffix("."),
              let topLevel = host.split(separator: ".").last,
              !topLevel.allSatisfy({ $0.isNumber }), !topLevel.hasPrefix("0x"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !["localhost", "local", "internal", "test", "invalid"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              !(components.queryItems ?? []).contains(where: {
                  ["api_key", "apikey", "access_token", "authorization"].contains($0.name.lowercased())
              }) else { return nil }
        return url
    }

    static func merchantURL(_ value: String) -> URL? {
        guard let url = secureURL(value), let host = url.host?.lowercased(),
              host.range(of: "(?:^|\\.)(google\\.[a-z.]+|serpapi\\.com|googleusercontent\\.com|gstatic\\.com)$", options: .regularExpression) == nil else { return nil }
        return url
    }

    // Provider thumbnails can be displayed without contacting arbitrary merchants automatically.
    static func thumbnailURL(_ value: String) -> URL? {
        guard let url = secureURL(value), let host = url.host?.lowercased(),
              ["gstatic.com", "googleusercontent.com", "serpapi.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    var searchedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: searchedAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: searchedAt)
    }

    func products(for garmentID: String) -> [ProductListing] {
        garments.first { $0.garmentId == garmentID }?.products ?? []
    }

    func validated(for analysis: Analysis, budgetCents requestedBudget: Int?) throws -> ProductSearchResponse {
        _ = try analysis.validated()
        guard currency == "USD", budgetCents == requestedBudget,
              requestedBudget.map({ (100...1_000_000).contains($0) }) ?? true,
              searchedDate != nil, limitations.count <= 1_000,
              excludedCurrencyCount.map({ (0...1_000_000).contains($0) }) ?? true,
              garments.count == analysis.garments.count,
              Set(garments.map { $0.garmentId }) == Set(analysis.garments.map { $0.id }),
              Set(garments.map { $0.garmentId }).count == garments.count else {
            throw ProductSearchError.invalidResponse
        }
        let allocations = requestedBudget.map { Budget.allocate($0, garments: analysis.garments) }
        var allIDs = Set<String>()
        var selectedIDs = Set<String>()
        var subtotal = 0
        let requestedIDs = Set(outfit.selectedProductIds)
        guard requestedIDs.count == outfit.selectedProductIds.count else { throw ProductSearchError.invalidResponse }

        for (index, garment) in analysis.garments.enumerated() {
            guard let group = garments.first(where: { $0.garmentId == garment.id }),
                  group.targetCents == allocations?[index], group.products.count <= 3 else {
                throw ProductSearchError.invalidResponse
            }
            var groupSelected = 0
            for product in group.products {
                guard !product.id.isEmpty, product.id.count <= 80, allIDs.insert(product.id).inserted,
                      !product.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, product.title.count <= 300,
                      !product.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, product.merchant.count <= 160,
                      product.currency == "USD", (1...100_000_000).contains(product.priceCents),
                      group.targetCents.map({ product.priceCents <= $0 }) ?? true,
                      product.destination != nil,
                      product.imageURL.map({ Self.secureURL($0) != nil }) ?? true,
                      product.matchType == "similar", !product.matchReason.isEmpty, product.matchReason.count <= 300 else {
                    throw ProductSearchError.invalidResponse
                }
                if requestedIDs.contains(product.id) {
                    groupSelected += 1
                    selectedIDs.insert(product.id)
                    // A bounded listing count and price keep this sum safely below Int.max.
                    subtotal += product.priceCents
                }
            }
            guard groupSelected == (group.products.isEmpty ? 0 : 1),
                  group.products.first.map({ requestedIDs.contains($0.id) }) ?? true else {
                throw ProductSearchError.invalidResponse
            }
        }
        let isComplete = !garments.isEmpty && garments.allSatisfy { !$0.products.isEmpty }
        guard selectedIDs == requestedIDs, outfit.complete == isComplete,
              outfit.subtotalCents == subtotal,
              requestedBudget.map({ subtotal <= $0 }) ?? true else {
            throw ProductSearchError.invalidResponse
        }
        return self
    }
}

enum ProductSearchError: Error, LocalizedError {
    case invalidResponse
    var errorDescription: String? { "The product response could not be verified. Try searching again, or search manually below." }
}
