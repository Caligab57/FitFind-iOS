import XCTest
@testable import FitFindCore

final class BudgetTests: XCTestCase {
    func garments(_ categories: [GarmentCategory]) -> [Garment] {
        categories.enumerated().map { Garment(id: String($0.offset), category: $0.element,
            name: "Garment", color: "Black", details: "Visible", searchQuery: "black garment") }
    }
    func testConservesEveryCentAcrossBudgetsAndCategories() {
        for categories: [GarmentCategory] in [[.top, .bottoms, .shoes], [.dress], [.top, .top, .bag, .accessory]] {
            for cents in [100, 101, 9999, 25000, 50000, 1000000] {
                let result = Budget.allocate(cents, garments: garments(categories))
                XCTAssertEqual(result.count, categories.count)
                XCTAssertEqual(result.reduce(0, +), cents)
                XCTAssertTrue(result.allSatisfy { $0 >= 0 })
            }
        }
    }
    func testInvalidAndEmptyBudgets() {
        XCTAssertEqual(Budget.allocate(0, garments: garments([.top])), [])
        XCTAssertEqual(Budget.allocate(100, garments: []), [])
        XCTAssertEqual(Budget.allocate(1000001, garments: garments([.top])), [])
        for text in ["", "0", "-1", "1.25", "1,000", "1e3", "10001", "99999999999999999999"] {
            XCTAssertNil(Budget.parseDollars(text))
        }
        XCTAssertEqual(Budget.parseDollars(" 250 "), 25000)
    }
    func testInvalidRecognitionAndShoppingEncoding() throws {
        let duplicate = garments([.top])[0]
        XCTAssertThrowsError(try Analysis(summary: "Look", garments: [duplicate, duplicate], limitations: "").validated())
        let garment = Garment(id: "a", category: .top, name: "Shirt", color: "White",
            details: "Cotton-like", searchQuery: "shirt & pants # sale")
        let url = try XCTUnwrap(garment.shoppingURL(budgetCents: 5000))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(query, "shirt & pants # sale under $50")
    }

    func testNoLimitSearchPreservesQueryWithoutAddingPrice() throws {
        let garment = Garment(id: "a", category: .top, name: "Shirt", color: "Black",
            details: "Boxy cut", searchQuery: "black boxy shirt & layered tee # outfit")
        let url = try XCTUnwrap(garment.shoppingURL(budgetCents: nil))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, garment.searchQuery)
        XCTAssertEqual(items.first { $0.name == "tbm" }?.value, "shop")
    }

    func testNoLimitDoesNotFallBackToCustomBudget() {
        for custom in ["250", "", "invalid", "10001"] {
            XCTAssertNil(BudgetTier.unlimited.resolvedCents(customDollars: custom))
            XCTAssertTrue(BudgetTier.unlimited.isValid(customDollars: custom))
            XCTAssertEqual(BudgetTier.balanced.resolvedCents(customDollars: custom), 25000)
        }
        XCTAssertFalse(BudgetTier.custom.isValid(customDollars: ""))
        XCTAssertFalse(BudgetTier.custom.isValid(customDollars: "10001"))
        XCTAssertTrue(BudgetTier.custom.isValid(customDollars: "250"))
        XCTAssertEqual(BudgetTier.custom.resolvedCents(customDollars: "250"), 25000)
    }

    func testLegacySavedBudgetDecodes() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","createdAt":0,
         "analysis":{"summary":"Saved look","garments":[],"limitations":""},"budgetCents":25000}
        """.utf8)
        let look = try JSONDecoder().decode(SavedLook.self, from: data)
        XCTAssertEqual(look.budgetCents, 25000)
        XCTAssertEqual(look.analysis.summary, "Saved look")
    }

    func testSavedLooksRetainUnlimitedAndCappedBudgets() throws {
        let analysis = Analysis(summary: "Preview look", garments: garments([.top, .shoes]), limitations: "")
        let original = [nil, 100, 25000, 1000000].map { cents in
            SavedLook(id: UUID(), createdAt: Date(), analysis: analysis, budgetCents: cents)
        }
        let restored = try JSONDecoder().decode([SavedLook].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.map { $0.budgetCents }, original.map { $0.budgetCents })
        XCTAssertEqual(restored.map { $0.id }, original.map { $0.id })
        XCTAssertEqual(restored.first?.analysis, analysis)
    }
}
