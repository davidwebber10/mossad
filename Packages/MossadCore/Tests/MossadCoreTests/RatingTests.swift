import XCTest
@testable import MossadCore

final class RatingTests: XCTestCase {
    func testTranscriptionPriceLevelsFollowThePricePerHour() {
        XCTAssertEqual(Rating.priceLevel(perHour: 0.05), 1)
        XCTAssertEqual(Rating.priceLevel(perHour: 0.23), 2)
        XCTAssertEqual(Rating.priceLevel(perHour: 0.36), 3)
        XCTAssertEqual(Rating.priceLevel(perHour: 0.9), 4)
        XCTAssertEqual(TranscriptionProvider.assemblyai.rating.price, 2)
        XCTAssertEqual(TranscriptionProvider.openai.rating.price, 3)
    }

    func testOpenAITranscriptionHasNoWordTimesAndAssemblyAIIsMeasured() {
        XCTAssertEqual(TranscriptionProvider.openai.rating.stars["Word times"], 1)
        XCTAssertTrue(TranscriptionProvider.assemblyai.rating.basis.contains("your calls"))
        XCTAssertTrue(TranscriptionProvider.deepgram.rating.basis.contains("estimate"))
    }

    func testAIPriceLevelUsesATypicalCoachReview() {
        // 20k in and 3k out: Opus 5.5 costs 0.08 + 0.06 = 14 cents.
        XCTAssertEqual(Rating.priceLevel(inputPerMillion: 4, outputPerMillion: 20), 3)
        XCTAssertEqual(Rating.priceLevel(inputPerMillion: 0.1, outputPerMillion: 0.5), 1)
        XCTAssertEqual(Rating.priceLevel(inputPerMillion: 2, outputPerMillion: 10), 2)
        XCTAssertEqual(Rating.priceLevel(inputPerMillion: 10, outputPerMillion: 50), 4)
    }

    func testAIRatingsComeFromTheModelTier() {
        let opus = Rating.model("claude-opus-5-5", provider: .anthropic)
        XCTAssertEqual(opus?.stars["Quality"], 5)
        XCTAssertEqual(opus?.price, 3)
        let haiku = Rating.model("claude-haiku-5-5", provider: .anthropic)
        XCTAssertEqual(haiku?.stars["Speed"], 5)
        XCTAssertEqual(haiku?.price, 1)
        XCTAssertEqual(Rating.model("gpt-6-astra", provider: .openai)?.stars["Quality"], 5)
        XCTAssertEqual(Rating.model("gpt-6-luna", provider: .openai)?.price, 1)
        XCTAssertNil(Rating.model("mystery-model", provider: .openai))
    }

    func testOpenRouterModelsGetAPriceFromTheirListButStarsOnlyForKnownFamilies() {
        let list = ModelCatalog.parseOpenRouter(json(["data": [
            ["id": "acme/x", "name": "X", "supported_parameters": ["tools", "structured_outputs"],
             "pricing": ["prompt": "0.000004", "completion": "0.00002"]],
            ["id": "anthropic/claude-opus-5.5", "name": "Opus", "supported_parameters": ["tools", "structured_outputs"],
             "pricing": ["prompt": "0.000004", "completion": "0.00002"]],
        ]]))
        let acme = Rating.model(list[0], provider: .openrouter)
        XCTAssertEqual(acme?.price, 3)
        XCTAssertTrue(acme?.stars.isEmpty == true)
        XCTAssertEqual(Rating.model(list[1], provider: .openrouter)?.stars["Quality"], 5)
    }

    func testDollarSigns() {
        XCTAssertEqual(Rating(stars: [:], price: 2, basis: "").dollars, "$$")
    }
}
