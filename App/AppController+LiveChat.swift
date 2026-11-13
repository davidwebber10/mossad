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

    /// The live chat of a call, kept while the app runs so an answer survives a change of tab.
    func liveChatSession(_ callID: String) -> ChatSession {
        if let session = liveChatSessions[callID] { return session }
        let session = ChatSession(callID: callID)
        liveChatSessions[callID] = session
        session.load(chats)
        return session
    }

    /// The chosen provider's model for a question during a call: Sonnet in place of a larger model on Anthropic.
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

    /// What the chat knows of the call now: the invite, whether the live transcript runs, where it has gaps, and the
    /// names the voices got.
    func liveCallFacts(_ record: CallRecord, snapshot: LiveTranscript) -> LiveCallFacts {
        let invited = (record.invitees ?? []).filter { $0.isSelf != true }.compactMap { $0.name ?? $0.email }
        var facts = LiveCallFacts(callID: record.id, title: record.calendarTitle ?? record.title, platform: record.platform.displayName,
                                  start: record.start, invited: invited.isEmpty ? record.attendees.filter { $0 != ownerName } : invited,
                                  owner: ownerName)
        // The invite the live names use, matched again with the call's times so far.
        if let invite = liveInvite(callID: record.id) {
            facts.title = invite.title
            if !invite.people.isEmpty { facts.invited = invite.people }
        }
        let recorded = liveRecorded
        facts.room = record.platform == .inPerson
        facts.transcriptOff = liveOffReason
        facts.gaps = liveCoverage.gaps(now: recorded)
        facts.paused = isPaused
        facts.recorded = recorded
        facts.voices = snapshot.voiceNames
        // Also when the live page was never opened.
        refreshLivePoints(callID: record.id)
        facts.points = livePointFacts(callID: record.id)
        return facts
    }

    /// Answers off the main thread. The request goes at normal priority; capture runs on its own queue and comes
    /// first. Its cost is logged with the call. Nothing is written into the call's folder.
    func liveChatAnswer(_ question: String, history: [ChatMessage], record: CallRecord, earlier: [ChatActionRecord] = [],
                        onAction: (@Sendable (ChatActionRecord) -> Void)? = nil,
                        onStep: @escaping @Sendable (String) -> Void, onText: @escaping @Sendable (String) -> Void) async throws -> ChatReply {
        guard let llm = liveChatLLM else { throw MissingAPIKey(service: aiProvider.displayName) }
        let small = liveSummaryLLM ?? llm
        let snapshot = live.snapshot, owner = ownerName, records = meetings, paths = paths, cache = liveSummaries
        let personas = personasOn
        // Only the light actions during a call: points, tasks, this moment's bookmark. No sync until the call ends.
        let host = isInert ? nil : chatActionHost
        let facts = liveCallFacts(record, snapshot: snapshot)
        // Detached, so the stop button's cancel is passed on by hand.
        let work = Task.detached(priority: .medium) {
            try await UsageContext.$callID.withValue(facts.callID) {
                // A model with a small context (Apple's on this Mac) gets the newest lines that fit and no summary.
                var limits = LiveLimits.standard
                if let limited = llm as? any ContextLimitedModel { limits = .small(contextTokens: await limited.contextTokens()) }
                let entries = snapshot.entries(owner: owner)
                let summary = await cache.summary(for: facts.callID, entries: entries, owner: owner, llm: small, limits: limits,
                                                  voices: facts.voices)
                return try await LiveChatAgent(llm: llm, ownerName: owner).answer(
                    question, history: history, facts: facts, entries: entries, summary: summary, records: records,
                    paths: paths, personaTraits: personas, limits: limits, actions: host, earlier: earlier, onAction: onAction,
                    onStep: onStep, onText: onText)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// A skipped call takes its chats with it: they quote words whose audio is gone. The sync deletes them elsewhere.
    func forgetLiveChats(callID: String) {
        let removed = chats.deleteChats(forCall: callID)
        liveChatsToSummarize.subtract(removed)
        liveChatSessions[callID] = nil
        if !removed.isEmpty { chatsVersion += 1 }
    }

    /// Gives each live chat its short summary for later chats once its call has ended. A minute later, so a call
    /// that was too short to keep is gone by then: its chats go with it and are never sent anywhere.
    func summarizeLiveChats() {
        let ids = liveChatsToSummarize
        liveChatsToSummarize = []
        guard !ids.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(60))
            let store = chats, paths = paths
            let found = await Task.detached(priority: .utility) { store.all().filter { ids.contains($0.id) } }.value
            for chat in found {
                guard let callID = chat.callID else { continue }
                let kept = FileManager.default.fileExists(atPath: paths.callDirectory(callID).appendingPathComponent(CallRecord.fileName).path)
                if kept { summarizeChat(chat.id) } else { forgetLiveChats(callID: callID) }
            }
        }
    }
}
