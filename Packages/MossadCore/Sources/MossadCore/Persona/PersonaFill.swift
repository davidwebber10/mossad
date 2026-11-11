import Foundation

/// The first fill from the stored calls: `Mossad --persona-fill [--go] [--cap 1]`. Without `--go` it only prints
/// what it would send and what that costs. With `--go` it prints the same, then reads each call once and stops at
/// the cap. The requests are logged in the owner's usage log with the purpose "persona".
public enum PersonaFill {
    public static let defaultCap = 1.0

    /// `model` makes the provider's model with the usage log it writes to, and names the model for the price; nil
    /// when the provider cannot run the step (no key). `say` prints a line; a key is never printed.
    @MainActor
    public static func command(_ args: [String], paths: Paths, owner: String, model: (UsageLog) -> (llm: any LanguageModel, name: String, service: UsageEvent.Service)?,
                               say: @escaping (String) -> Void) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let cap = value("--cap").flatMap(Double.init) ?? defaultCap
        let usage = UsageLog(directory: paths.usage)
        guard let made = model(usage) else {
            say("The AI provider in Settings > AI has no key, or it cannot run this step. Nothing was sent.")
            return 1
        }
        let price: @Sendable (Int, Int) -> Double = { input, output in
            Pricing.cost(UsageEvent(date: Date(), callID: nil, service: made.service, purpose: .persona, model: made.name, inputTokens: input, outputTokens: output))
        }
        let e = PersonaRunner.estimate(paths: paths, owner: owner, since: nil, price: price)
        say("Model \(made.name). Calls to read: \(e.calls). Requests: about \(e.requests) (\(e.input) input and \(e.output) output tokens).")
        say(String(format: "Estimated cost: $%.2f. Cap: $%.2f.", e.dollars, cap))
        guard args.contains("--go") else {
            say("Nothing was sent. Add --go to start.")
            return 0
        }
        guard e.calls > 0 else { say("Each stored call is read already."); return 0 }
        let started = Date()
        let spent: @Sendable () -> Double = {
            usage.all().filter { $0.purpose == .persona && $0.date >= started }.reduce(0) { $0 + Pricing.cost($1) }
        }
        let runner = PersonaRunner(paths: paths, llm: made.llm, owner: owner)
        let report = await runner.run(since: nil, writeLimit: Int.max, isLive: { false }, canSpend: { spent() + $0 <= cap }, price: price)
        say(String(format: "Read %d calls with %d requests; sentences for %d people; $%.2f spent.", report.calls, report.requests, report.people, spent()))
        if let why = report.stopped { say("Stopped early: \(why). Run it again to go on; each call that was read stays read.") }
        return report.stopped == nil ? 0 : 2
    }
}
