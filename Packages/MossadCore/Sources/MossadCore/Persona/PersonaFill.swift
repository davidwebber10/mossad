import Foundation

/// The first fill from the stored calls. The app runs it by itself once after the update (`AppController+Personas`),
/// in the background, never during a call, with a hard cap of $1. The command `Mossad --persona-fill` prints the
/// estimate; with `--go` it runs the same fill while the app is quit.
public enum PersonaFill {
    /// The cap of the fill that the app starts by itself.
    public static let defaultCap = 1.0
    /// The most a typed `--cap` may be.
    public static let maxCap = 5.0
    /// The calls of one run of the app's fill.
    public static let callsPerRun = 10

    /// The dollars of a request's tokens for a model, and whether the price is known: a model on the owner's own
    /// server or Mac costs nothing; a cloud model with no list price is not known.
    public static func price(service: UsageEvent.Service, model: String) -> (known: Bool, cost: @Sendable (Int, Int) -> Double) {
        let cost: @Sendable (Int, Int) -> Double = { input, output in
            Pricing.cost(UsageEvent(date: Date(), callID: nil, service: service, purpose: .persona, model: model, inputTokens: input, outputTokens: output))
        }
        return (service == .local || cost(1_000_000, 0) > 0, cost)
    }

    /// `plan` names the model and its service with no key; `makeModel` makes it, with the usage log it writes to,
    /// only after `--go`. A key is never read for the estimate and never printed.
    @MainActor
    public static func command(_ args: [String], paths: Paths, owner: String, plan: (name: String, service: UsageEvent.Service)?,
                               makeModel: (UsageLog) -> (any LanguageModel)?, say: @escaping (String) -> Void) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard let plan else {
            say("The AI provider in Settings > AI has no model for this step. Nothing was sent.")
            return 1
        }
        let typed = value("--cap").flatMap(Double.init)
        if let typed, !(typed.isFinite && typed > 0 && typed <= maxCap) {
            say(String(format: "The cap must be a number above $0 and at most $%.2f.", maxCap))
            return 1
        }
        let cap = typed ?? defaultCap
        let price = Self.price(service: plan.service, model: plan.name)
        let e = PersonaRunner.estimate(paths: paths, owner: owner, since: nil, price: price.cost)
        say("Model \(plan.name). Calls to read: \(e.calls). Requests: about \(e.requests) (\(e.input) input and \(e.output) output tokens).")
        say(price.known ? String(format: "Estimated cost: $%.2f. Cap: $%.2f.", e.dollars, cap)
                        : "The price of \(plan.name) is not known, so no cap in dollars can hold. Add --calls <number> to read that many calls at most.")
        guard args.contains("--go") else {
            say("Nothing was sent. Add --go to start.")
            return 0
        }
        guard e.calls > 0 else { say("Each stored call is read already."); return 0 }
        let calls = value("--calls").flatMap(Int.init)
        guard price.known || (calls ?? 0) > 0 else { say("Nothing was sent."); return 1 }
        let usage = UsageLog(directory: paths.usage)
        guard let llm = makeModel(usage) else {
            say("The AI provider in Settings > AI has no key. Nothing was sent.")
            return 1
        }
        let started = PersonaBudget.second(Date())
        let spent: @Sendable () -> Double = {
            usage.all().filter { $0.purpose == .persona && $0.date >= started }.reduce(0) { $0 + Pricing.cost($1) }
        }
        let report = await PersonaRunner(paths: paths, llm: llm, owner: owner)
            .run(since: nil, callLimit: calls, newestFirst: true, writeLimit: Int.max, isLive: { false }, canSpend: { spent() + $0 <= cap }, price: price.cost)
        // The spend counts in the budget of older calls, so the app does not spend the same dollar again.
        var budget = PersonaBudget.load(from: PersonaStore(paths: paths).directory)
        budget.record(dollars: spent(), calls: report.handled, model: plan.name, now: Date())
        budget.save(to: PersonaStore(paths: paths).directory)
        say(String(format: "Read %d calls with %d requests; sentences for %d people; $%.2f spent.", report.calls, report.requests, report.people, spent()))
        if let why = report.stopped { say("Stopped early: \(why). Run it again to go on; each call that was read stays read.") }
        return report.stopped == nil ? 0 : 2
    }
}
