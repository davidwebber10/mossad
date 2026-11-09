import XCTest
@testable import MossadCore

/// Summarizes a short sample meeting with a real local model. Opt in:
/// `MOSSAD_LOCAL_SERVER_TEST=1` for a running Ollama or LM Studio (`MOSSAD_LOCAL_SERVER_URL`, `MOSSAD_LOCAL_SERVER_MODEL`),
/// `MOSSAD_APPLE_FM_TEST=1` for Apple's on-device model (`MOSSAD_APPLE_FM_LONG=1` adds a long meeting, in parts).
final class LocalModelLiveTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    static let sample = """
    [00:00:04] Dana Reyes: Thanks for joining. Two things today: the freight model and the Q3 budget.
    [00:00:11] Sam Patel: Sure. On freight, the new carrier rates came in eight percent higher than we planned.
    [00:00:19] Dana Reyes: Eight percent across the board, or only on the West Coast lanes?
    [00:00:24] Sam Patel: Mostly West Coast. East Coast is flat. I think we can move about a third of the volume to rail.
    [00:00:33] Dana Reyes: Okay. Can you model the rail option and send it to me by Friday?
    [00:00:37] Sam Patel: Yes, I'll have it by Friday.
    [00:00:41] Lee Chen: If we go to rail, the warehouse in Reno needs two more receiving slots in the morning.
    [00:00:49] Dana Reyes: Lee, can you check with the Reno team if that's possible?
    [00:00:52] Lee Chen: I'll ask them tomorrow.
    [00:01:02] Dana Reyes: On the budget, finance wants our Q3 number by the 15th.
    [00:01:08] Sam Patel: The freight increase alone adds about 120 thousand dollars to the quarter.
    [00:01:15] Dana Reyes: Then we keep the marketing line flat and absorb it. We agreed on that last month.
    [00:01:21] Lee Chen: Agreed. Let's keep marketing flat.
    [00:01:25] Dana Reyes: Good. I'll send finance the number on Monday. Thanks, everyone.
    """

    private func run(_ llm: any LanguageModel, transcript: String, label: String) async throws {
        let start = Date()
        let s = try await LLMSummarizer(llm: llm, ownerName: "Dana Reyes").summarize(transcript: transcript, title: "Freight and budget")
        let seconds = Date().timeIntervalSince(start)
        print("""
        [\(label)] \(String(format: "%.1f", seconds)) s
        Title: \(s.title ?? "-")
        Headline: \(s.headline ?? "-")
        Kind: \(s.kind ?? "-")  Tags: \(s.tags.joined(separator: ", "))
        Summary: \(s.summary)
        Topics: \(s.topics.map(\.title).joined(separator: " | "))
        Action items: \(s.actionItems.map(\.text).joined(separator: " | "))
        Decisions: \(s.decisions.map(\.text).joined(separator: " | "))
        """)
        XCTAssertFalse(s.summary.isEmpty)
    }

    func testALocalServerSummarizesASampleMeeting() async throws {
        try XCTSkipUnless(env["MOSSAD_LOCAL_SERVER_TEST"] == "1", "Set MOSSAD_LOCAL_SERVER_TEST=1 with Ollama or LM Studio running")
        let base = env["MOSSAD_LOCAL_SERVER_URL"].flatMap(LocalServer.url(from:)) ?? LocalServer.ollama
        let models = try await ModelCatalog.fetch(.localServer, apiKey: nil, serverURL: base)
        let model = try XCTUnwrap(env["MOSSAD_LOCAL_SERVER_MODEL"] ?? models.first?.id, "the server lists no models")
        try await run(LocalServerModel(baseURL: base, model: model, apiKey: nil), transcript: Self.sample, label: "\(base.absoluteString) \(model)")
    }

    func testAppleOnDeviceSummarizesASampleMeeting() async throws {
        try XCTSkipUnless(env["MOSSAD_APPLE_FM_TEST"] == "1", "Set MOSSAD_APPLE_FM_TEST=1 on a Mac with Apple Intelligence")
        if let reason = AppleModelInfo.unavailableReason() { throw XCTSkip(reason.description) }
        let llm = AIProvider.apple.model("", apiKey: nil, usage: nil)
        try await run(llm, transcript: Self.sample, label: "Apple on-device, short")
        guard env["MOSSAD_APPLE_FM_LONG"] == "1" else { return }
        // About an hour of talk: the sample's lines again and again, with the clock moving on.
        let lines = Self.sample.split(separator: "\n").map(String.init)
        let long = (0..<40).flatMap { round in
            lines.enumerated().map { i, line in
                let seconds = round * 90 + i * 6
                let stamp = String(format: "[%02d:%02d:%02d]", seconds / 3600, seconds / 60 % 60, seconds % 60)
                return stamp + line.dropFirst(10)
            }
        }.joined(separator: "\n")
        let tokens = await (llm as! any ContextLimitedModel).tokenCount(long)
        print("[Apple on-device, long] \(lines.count * 40) lines, \(tokens) tokens, context \(await (llm as! any ContextLimitedModel).contextTokens())")
        try await run(llm, transcript: long, label: "Apple on-device, long")
    }
}
