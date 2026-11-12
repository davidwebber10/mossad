import Foundation
import MossadCore

/// The chat with the call that records now: questions answered from the live transcript, the invite, and the
/// owner's history, on the meeting's live page.
extension AppController {
    /// The menu's "Ask about this call…" and ⌥⌘K: the live meeting's Chat tab with the field focused.
    func askAboutCall() {
        guard case .recording(_, let since) = status else { return }
        let id = CallRecorder.callID(for: since)
        liveChatFocus = id
        openMeeting(id)
    }

    /// The chosen provider's model for a question during a call: Sonnet in place of Opus on Anthropic.
    private var liveChatLLM: (any LanguageModel)? {
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard key != nil || !aiProvider.requiresKey, !(aiModel.isEmpty && aiProvider.defaultModel.isEmpty) else { return nil }
        return aiProvider.model(aiProvider.liveChatModel(aiModel), apiKey: key, usage: usage, serverURL: localServerBase)
    }

    /// The small model for the summary of a long call's older part, as the live title uses.
    private var liveSummaryLLM: (any LanguageModel)? {
        guard let small = aiProvider.smallModel else { return liveChatLLM }
        let key = aiProvider.key.flatMap { keychain.get($0) }
        return aiProvider.model(small, apiKey: key, usage: usage, serverURL: localServerBase)
    }

    /// Answers off the main thread. The request goes at normal priority; capture runs on its own queue and comes
    /// first. Its cost is logged with the call. Nothing is written into the call's folder.
    func liveChatAnswer(_ question: String, history: [ChatMessage], record: CallRecord,
                        onStep: @escaping @Sendable (String) -> Void, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let llm = liveChatLLM else { throw MissingAPIKey(service: aiProvider.displayName) }
        let small = liveSummaryLLM ?? llm
        let snapshot = live.snapshot, owner = ownerName, records = meetings, paths = paths, cache = liveSummaries
        let personas = personasOn
        let invited = (record.invitees ?? []).filter { $0.isSelf != true }.compactMap { $0.name ?? $0.email }
        let facts = LiveCallFacts(callID: record.id, title: record.calendarTitle ?? record.title, platform: record.platform.displayName,
                                  start: record.start, invited: invited.isEmpty ? record.attendees : invited, owner: owner)
        return try await Task.detached(priority: .medium) {
            try await UsageContext.$callID.withValue(facts.callID) {
                let entries = snapshot.entries(owner: owner)
                let summary = await cache.summary(for: facts.callID, entries: entries, owner: owner, llm: small)
                return try await LiveChatAgent(llm: llm, ownerName: owner).answer(
                    question, history: history, facts: facts, entries: entries, summary: summary, records: records,
                    paths: paths, personaTraits: personas, onStep: onStep, onText: onText)
            }
        }.value
    }

    /// Gives each live chat its short summary for later chats, once its call has ended.
    func summarizeLiveChats() {
        let ids = liveChatsToSummarize
        liveChatsToSummarize = []
        for id in ids { summarizeChat(id) }
    }
}
