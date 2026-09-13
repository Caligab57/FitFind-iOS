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
}
