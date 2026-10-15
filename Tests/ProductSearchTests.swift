import Foundation
import XCTest
@testable import FitFindCore

final class ProductSearchTests: XCTestCase {
    private var analysis: Analysis {
        Analysis(summary: "A black top with white sneakers", garments: [
            Garment(id: "top", category: .top, name: "Top", color: "Black", details: "Boxy cut", searchQuery: "black boxy top"),
            Garment(id: "shoes", category: .shoes, name: "Sneakers", color: "White", details: "Low top", searchQuery: "white low top sneakers")
        ], limitations: "Identity is unverified.")
    }

    private func listing(id: String, price: Int) -> ProductListing {
        ProductListing(id: id, title: "Black boxy top", merchant: "Example merchant", priceCents: price,
            currency: "USD", url: "https://shop.example/products/\(id)?color=black",
            imageURL: "https://encrypted-tbn0.gstatic.com/\(id).jpg", matchType: "similar",
            matchReason: "Listing text matches black, boxy and top.")
    }

    private func fixture(budget: Int? = 10_000, missingShoes: Bool = false) -> ProductSearchResponse {
        let targets = budget.map { Budget.allocate($0, garments: analysis.garments) }
        return ProductSearchResponse(currency: "USD", budgetCents: budget,
            searchedAt: "2026-10-12T17:55:00.123Z", garments: [
                GarmentProducts(garmentId: "top", targetCents: targets?[0], products: [listing(id: "p1", price: 3_900), listing(id: "p2", price: 4_000)]),
                GarmentProducts(garmentId: "shoes", targetCents: targets?[1], products: missingShoes ? [] : [listing(id: "p3", price: 5_700)])
            ], outfit: OutfitSelection(complete: !missingShoes, subtotalCents: missingShoes ? 3_900 : 9_600,
                selectedProductIds: missingShoes ? ["p1"] : ["p1", "p3"]),
            limitations: "Listing prices exclude tax and shipping; identity and stock are unverified.")
    }

    private func modified(_ mutate: (inout [String: Any]) -> Void) throws -> ProductSearchResponse {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(ProductSearchResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func modifiedListing(_ mutate: (inout [String: Any]) -> Void) throws -> ProductSearchResponse {
        try modified { object in
            var groups = object["garments"] as! [[String: Any]]
            var products = groups[0]["products"] as! [[String: Any]]
            mutate(&products[0])
            groups[0]["products"] = products
            object["garments"] = groups
        }
    }

    func testValidCappedResultsConserveAllocationsAndSubtotal() throws {
        let response = try fixture().validated(for: analysis, budgetCents: 10_000)
        XCTAssertTrue(response.outfit.complete)
        XCTAssertEqual(response.outfit.subtotalCents, 9_600)
        XCTAssertEqual(response.garments.compactMap { $0.targetCents }.reduce(0, +), 10_000)
        XCTAssertEqual(response.products(for: "top").count, 2)
        XCTAssertEqual(response.products(for: "unknown"), [])
        XCTAssertNotNil(response.searchedDate)
    }

    func testNoLimitHasNoTargetsButRetainsRealPrices() throws {
        let response = try fixture(budget: nil).validated(for: analysis, budgetCents: nil)
        XCTAssertNil(response.budgetCents)
        XCTAssertTrue(response.garments.allSatisfy { $0.targetCents == nil })
        XCTAssertEqual(response.outfit.subtotalCents, 9_600)
    }

    func testPartialResultDoesNotClaimCompleteOutfit() throws {
        let response = try fixture(missingShoes: true).validated(for: analysis, budgetCents: 10_000)
        XCTAssertFalse(response.outfit.complete)
        XCTAssertEqual(response.outfit.selectedProductIds, ["p1"])
        XCTAssertEqual(response.outfit.subtotalCents, 3_900)
        XCTAssertTrue(response.products(for: "shoes").isEmpty)
    }

    func testEmptyResultsNeedEveryGarmentGroupAndZeroSubtotal() throws {
        let targets = Budget.allocate(10_000, garments: analysis.garments)
        let response = ProductSearchResponse(currency: "USD", budgetCents: 10_000, searchedAt: "2026-10-12T17:55:00Z",
            garments: analysis.garments.enumerated().map {
                GarmentProducts(garmentId: $0.element.id, targetCents: targets[$0.offset], products: [])
            }, outfit: OutfitSelection(complete: false, subtotalCents: 0, selectedProductIds: []), limitations: "No listings found.")
        XCTAssertNoThrow(try response.validated(for: analysis, budgetCents: 10_000))
    }

    func testRejectsStaleOrInvalidBudgetAndCurrency() throws {
        XCTAssertThrowsError(try fixture().validated(for: analysis, budgetCents: 25_000))
        XCTAssertThrowsError(try fixture().validated(for: analysis, budgetCents: nil))
        XCTAssertThrowsError(try fixture(budget: nil).validated(for: analysis, budgetCents: 10_000))
        for cap in [-1, 0, 99, 1_000_001, Int.max] {
            let response = try modified { $0["budgetCents"] = cap }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: cap))
        }
        let currency = try modified { $0["currency"] = "EUR" }
        XCTAssertThrowsError(try currency.validated(for: analysis, budgetCents: 10_000))
    }

    func testRejectsOverBudgetOrNonPositiveListingPrices() throws {
        // Even an unselected alternative must fit the per-piece allocation.
        for price in [-1, 0, 4_168, 100_000_001, Int.max] {
            let response = try modifiedListing { $0["priceCents"] = price }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
        let response = try modified { object in
            var groups = object["garments"] as! [[String: Any]]
            var products = groups[0]["products"] as! [[String: Any]]
            products[1]["priceCents"] = 4_168
            groups[0]["products"] = products
            object["garments"] = groups
        }
        XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
    }

    func testRejectsMissingDuplicateOrUnknownGarmentGroups() throws {
        for mode in ["missing", "duplicate", "unknown"] {
            let response = try modified { object in
                var groups = object["garments"] as! [[String: Any]]
                if mode == "missing" { groups.removeLast() }
                if mode == "duplicate" { groups[1]["garmentId"] = "top" }
                if mode == "unknown" { groups[1]["garmentId"] = "hat" }
                object["garments"] = groups
            }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
    }

    func testRejectsWrongAllocationAndMoreThanThreeAlternatives() throws {
        for mode in ["wrongTarget", "missingTarget", "tooMany"] {
            let response = try modified { object in
                var groups = object["garments"] as! [[String: Any]]
                if mode == "wrongTarget" { groups[0]["targetCents"] = 4_200 }
                if mode == "missingTarget" { groups[0]["targetCents"] = NSNull() }
                if mode == "tooMany" {
                    let product = (groups[0]["products"] as! [[String: Any]])[0]
                    groups[0]["products"] = (0..<4).map { index -> [String: Any] in
                        var item = product; item["id"] = "extra\(index)"; return item
                    }
                }
                object["garments"] = groups
            }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
    }

    func testRejectsUnsafeProductAndImageURLs() throws {
        for value in ["http://shop.example/p", "javascript:alert(1)", "data:image/png;base64,abc",
                      "file:///tmp/a", "//shop.example/p", "/relative", "https://", "https://user:secret@shop.example/p", "https://127.0.0.1/p",
                      "https://[::1]/p", "https://shop.local/p", "https://shop.example:8080/p",
                      "https://shop.example/p?api_key=secret", "https://shop.example/p?access_token=secret",
                      "https://shop.local./p", "https://www.google.com./p", "https://0x7f.0.0.1/p"] {
            XCTAssertNil(ProductSearchResponse.secureURL(value))
            for key in ["url", "imageURL"] {
                let response = try modifiedListing { $0[key] = value }
                XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
            }
        }
        XCTAssertNotNil(ProductSearchResponse.secureURL("https://shop.example/p?id=a%26b#details"))
        let noImage = try modifiedListing { $0["imageURL"] = NSNull() }
        XCTAssertNoThrow(try noImage.validated(for: analysis, budgetCents: 10_000))
    }

    func testSuppressesUntrustedThumbnailsAndRejectsAggregatorLinks() throws {
        XCTAssertNotNil(ProductSearchResponse.thumbnailURL("https://encrypted-tbn0.gstatic.com/image.jpg"))
        XCTAssertNotNil(ProductSearchResponse.thumbnailURL("https://lh3.googleusercontent.com/image.jpg"))
        XCTAssertNil(ProductSearchResponse.thumbnailURL("https://images.merchant.example/image.jpg"))
        XCTAssertNil(ProductSearchResponse.thumbnailURL("https://gstatic.com.untrusted.example/image.jpg"))
        for url in ["https://www.google.com/search?q=shirt", "https://serpapi.com/search.json", "https://www.google.co.uk/shopping"] {
            let response = try modifiedListing { $0["url"] = url }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
        let suppressed = try modifiedListing { $0["imageURL"] = "https://images.merchant.example/image.jpg" }
        XCTAssertNoThrow(try suppressed.validated(for: analysis, budgetCents: 10_000))
        XCTAssertNil(suppressed.garments[0].products[0].thumbnail)
    }

    func testRejectsInvalidListingIdentityAndClaims() throws {
        for (key, value) in [("id", ""), ("id", "p3"), ("title", "  "), ("merchant", ""),
                             ("currency", "GBP"), ("matchType", "exact"), ("matchReason", "")] {
            let response = try modifiedListing { $0[key] = value }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
    }

    func testRejectsInvalidSelectedProductsSubtotalOrCompleteFlag() throws {
        for selected in [["p1"], ["p1", "p1", "p3"], ["p1", "p2", "p3"], ["unknown", "p3"], ["p2", "p3"]] {
            let response = try modified { object in
                var outfit = object["outfit"] as! [String: Any]
                outfit["selectedProductIds"] = selected
                object["outfit"] = outfit
            }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
        for subtotal in [-1, 0, 9_599, 10_001] {
            let response = try modified { object in
                var outfit = object["outfit"] as! [String: Any]
                outfit["subtotalCents"] = subtotal
                object["outfit"] = outfit
            }
            XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
        }
        let response = try modified { object in
            var outfit = object["outfit"] as! [String: Any]
            outfit["complete"] = false
            object["outfit"] = outfit
        }
        XCTAssertThrowsError(try response.validated(for: analysis, budgetCents: 10_000))
    }

    func testRejectsInvalidTimestampAndOversizedText() throws {
        let invalidDate = try modified { $0["searchedAt"] = "yesterday" }
        XCTAssertThrowsError(try invalidDate.validated(for: analysis, budgetCents: 10_000))
        let longTitle = try modifiedListing { $0["title"] = String(repeating: "a", count: 301) }
        XCTAssertThrowsError(try longTitle.validated(for: analysis, budgetCents: 10_000))
    }

    func testOptionalCurrencyExclusionCountIsValidated() throws {
        XCTAssertNil(fixture().excludedCurrencyCount)
        let response = try modified { $0["excludedCurrencyCount"] = 8 }
        XCTAssertEqual(try response.validated(for: analysis, budgetCents: 10_000).excludedCurrencyCount, 8)
        let invalid = try modified { $0["excludedCurrencyCount"] = -1 }
        XCTAssertThrowsError(try invalid.validated(for: analysis, budgetCents: 10_000))
    }

    func testExistingSavedLookWithoutBudgetStillDecodesAsUnlimited() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","createdAt":0,
         "analysis":{"summary":"Old look","garments":[],"limitations":""}}
        """.utf8)
        let saved = try JSONDecoder().decode(SavedLook.self, from: data)
        XCTAssertNil(saved.budgetCents)
        XCTAssertEqual(saved.analysis.summary, "Old look")
    }

    func testSavedLookDoesNotPersistEphemeralProductResults() throws {
        let saved = SavedLook(id: UUID(), createdAt: Date(), analysis: analysis, budgetCents: 10_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNil(object["products"])
        XCTAssertNil(object["productSearch"])
        XCTAssertEqual(Set(object.keys), Set(["id", "createdAt", "analysis", "budgetCents"]))
        let restored = try JSONDecoder().decode(SavedLook.self, from: JSONEncoder().encode(saved))
        XCTAssertNoThrow(try fixture().validated(for: restored.analysis, budgetCents: restored.budgetCents))
    }
}
