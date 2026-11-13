import Foundation
import MossadCore

/// What the app's own chat can do: the writes of its action tools (`ChatActions`), the click on a card, Undo, and
/// the one writer of a chat's file while an answer comes. The points and the tasks are their files; a bookmark goes
/// through the recorder during a call and the pipeline after it. During a call nothing here starts a sync: the sync
/// after the call sends it.
extension AppController {
    /// The writes of one answer, made on the main actor and used off it. Each waits for its write, so a receipt says
    /// Done only after it.
    var chatActionHost: ChatActionHost {
        let recorder = self.recorder, pipeline = self.pipeline, paths = self.paths
        return ChatActionHost(
            paths: paths,
            liveMoment: { CaptureQueue.queue.sync { recorder.liveMoment } },
            bookmark: { callID, at, note in
                guard let pipeline else { return false }
                let done = Wait()
                Task.detached {
                    let ok = if let note = Self.words(note) { await pipeline.setBookmarkNote(callID: callID, offset: at, note: note) }
                        else { await pipeline.addBookmark(callID: callID, offset: at) }
                    done.finish(ok)
                }
                let ok = done.result(within: 10)
                Task { @MainActor in self.refresh() }
                return ok
            },
            bookmarkNow: { note in
                let at: TimeInterval? = CaptureQueue.queue.sync {
                    guard let at = recorder.bookmark() else { return nil }
                    if let note = Self.words(note) { recorder.setBookmarkNote(at: at, note) }
                    return at
                }
                if at != nil { Task { @MainActor in self.lastBookmark = Date(); self.refresh() } }
                return at
            },
            removeBookmark: { callID, at in
                // While its call records, the recorder holds the record: Undo waits for the end of the call.
                guard let pipeline, CaptureQueue.queue.sync(execute: { recorder.currentRecord?.id }) != callID else { return false }
                let done = Wait()
                Task.detached { done.finish(await pipeline.removeBookmark(callID: callID, offset: at)) }
                let ok = done.result(within: 10)
                Task { @MainActor in self.refresh() }
                return ok
            },
            changed: { what in
                Task { @MainActor in
                    switch what {
                    case .points: self.series.reload(self.paths)
                    case .tasks: self.commitmentsVersion += 1
                    case .meeting: self.refresh()
                    }
                    if !self.isRecording { self.syncNow() }
                }
            })
    }

    // MARK: The one writer of a chat while it answers

    /// A receipt or a card the moment its action exists, into the file's copy of the chat: it shows and can be
    /// undone whatever happens to the answer. `fallback` is the chat when the file is not there yet.
    func saveChatAction(_ record: ChatActionRecord, chat fallback: Chat, answer: UUID) -> Chat {
        changeChat(fallback.id, fallback: fallback) { ChatThreadEdits.record(record, in: &$0, answer: answer) } ?? fallback
    }

    /// The answer as it came, joined to the file's copy: a click saved meanwhile stays.
    func finishChatAnswer(_ message: ChatMessage, chat fallback: Chat) -> Chat {
        changeChat(fallback.id, fallback: fallback) { ChatThreadEdits.finish(message, in: &$0) } ?? fallback
    }

    /// The answer stopped or failed. The question stays when something was done; returns the chat as saved, and
    /// whether the question stays.
    func stopChatAnswer(chat fallback: Chat, answer: UUID, question: UUID, byOwner: Bool) -> (chat: Chat, kept: Bool) {
        var kept = false
        let chat = changeChat(fallback.id, fallback: fallback) { kept = ChatThreadEdits.stop(in: &$0, answer: answer, question: question, byOwner: byOwner) } ?? fallback
        return (chat, kept)
    }

    /// Every receipt and card of a chat, for the Retry rule.
    func chatActions(_ chat: Chat) -> [ChatActionRecord] { chat.messages.flatMap { $0.actions ?? [] } }

    // MARK: Cards and Undo

    /// "Do it" or "Not now" on a card: the chat file keeps the new state. A click that runs is marked at once, so a
    /// second click does nothing.
    func answerActionCard(chatID: UUID, messageID: UUID, actionID: UUID, doIt: Bool) {
        guard !isInert, !actionsInWork.contains(actionID), let action = chatAction(chatID, messageID, actionID), action.state == .proposed else { return }
        guard doIt else { return updateAction(chatID, messageID, actionID) { $0.state = .declined } }
        let request = action.request
        // The riskier class never runs during a call.
        if request.kind.needsClick, request.kind != .batch, isRecording { return }
        actionsInWork.insert(actionID)
        let host = chatActionHost, paths = paths, pipeline = pipeline
        let people = library.identity?.people.people ?? PeopleStore.peek(in: paths.people) ?? []
        Task {
            defer { actionsInWork.remove(actionID) }
            switch request.kind {
            case .batch:
                let now = Date()
                let done = await Task.detached(priority: .userInitiated) { (request.items ?? []).map { ($0, host.perform($0, now: now)) } }.value
                updateAction(chatID, messageID, actionID) { $0.state = done.allSatisfy { $0.1 != nil } ? .done : .failed }
                // Each one of the card gets its own receipt, with the card's words and its Undo.
                addActions(chatID, messageID, done.map { r, change in
                    ChatActionRecord(request: r, state: change == nil ? .failed : .done, summary: r.summary ?? Self.receiptWords(r), undo: change?.undo,
                                     after: change?.after, date: now)
                })
            case .nameVoice:
                // Exactly what the card showed: the voice still has its label and the person is still the one named.
                guard let callID = request.callID, let key = request.speakerKey,
                      let r = try? CallRecord.load(from: paths.callDirectory(callID)),
                      let target = NameVoiceTarget.check(request, record: r, people: people) else {
                    return updateAction(chatID, messageID, actionID) { $0.state = .failed; $0.summary += " (the meeting changed since the card; name the voice on the meeting)" }
                }
                await pipeline?.applyNames(callID: callID, names: [key: target.name], emails: target.email.map { [key: $0] } ?? [:])
                refresh()
                updateAction(chatID, messageID, actionID) { $0.state = .done }
            case .renameMeeting, .addTag, .removeTag:
                guard let callID = request.callID, let pipeline, let before = try? CallRecord.load(from: paths.callDirectory(callID)) else {
                    return updateAction(chatID, messageID, actionID) { $0.state = .failed }
                }
                var undo = ChatActionRequest(request.kind == .renameMeeting ? .renameMeeting : .addTag)
                undo.callID = callID
                if request.kind == .renameMeeting {
                    undo.text = before.customTitle
                    await pipeline.setTitle(callID: callID, request.text)
                } else {
                    let chosen = request.tags ?? []
                    let tags = request.kind == .addTag ? before.tags + chosen.filter { t in !before.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                        : before.tags.filter { t in !chosen.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                    undo.tags = before.tags
                    await pipeline.setTags(callID: callID, tags)
                }
                refresh()
                // The state and the target as the pipeline saved them, read from disk.
                guard let after = try? CallRecord.load(from: paths.callDirectory(callID)) else {
                    return updateAction(chatID, messageID, actionID) { $0.state = .failed }
                }
                updateAction(chatID, messageID, actionID) { a in
                    a.state = .done
                    a.undo = undo
                    a.after = ChatActionTarget.meeting(after)
                }
            case .setRecording:
                guard let id = request.upcomingID, let meeting = calendarUpcoming.first(where: { $0.id == id }),
                      let choice = request.choice.flatMap(RecordingChoice.init(rawValue:)) else {
                    return updateAction(chatID, messageID, actionID) { $0.state = .failed }
                }
                setRecording(choice, for: meeting)
                updateAction(chatID, messageID, actionID) { $0.state = .done }
            default:
                let now = Date()
                let change = await Task.detached(priority: .userInitiated) { host.perform(request, now: now) }.value
                updateAction(chatID, messageID, actionID) { a in
                    a.state = change == nil ? .failed : .done
                    a.summary = change == nil ? a.summary : (request.summary ?? Self.receiptWords(request))
                    a.undo = change?.undo
                    a.after = change?.after
                }
            }
        }
    }

    /// Undo of a receipt, while its target is as the action left it; else the receipt says it changed since, or why
    /// Undo did not work.
    func undoChatAction(chatID: UUID, messageID: UUID, actionID: UUID) {
        guard !isInert, !actionsInWork.contains(actionID), let action = chatAction(chatID, messageID, actionID), action.state == .done,
              let undo = action.undo else { return }
        actionsInWork.insert(actionID)
        let host = chatActionHost, paths = paths, pipeline = pipeline
        Task {
            defer { actionsInWork.remove(actionID) }
            switch undo.kind {
            case .renameMeeting, .addTag:
                // Read from disk, as the pipeline saved it: the list in memory can be a moment behind.
                guard let callID = undo.callID, let pipeline, let r = try? CallRecord.load(from: paths.callDirectory(callID)) else {
                    return updateAction(chatID, messageID, actionID) { $0.summary = Self.undoFailed($0.summary) }
                }
                guard ChatActionTarget.meeting(r) == action.after else {
                    return updateAction(chatID, messageID, actionID) { $0.summary = Self.changedSince($0.summary); $0.undo = nil }
                }
                if undo.kind == .renameMeeting { await pipeline.setTitle(callID: callID, undo.text) } else { await pipeline.setTags(callID: callID, undo.tags ?? []) }
                refresh()
                updateAction(chatID, messageID, actionID) { $0.state = .undone }
            default:
                let outcome = await Task.detached(priority: .userInitiated) { host.undo(action, now: Date()) }.value
                updateAction(chatID, messageID, actionID) { a in
                    switch outcome {
                    case .undone: a.state = .undone
                    case .changedSince: a.summary = Self.changedSince(a.summary); a.undo = nil
                    case .failed: a.summary = Self.undoFailed(a.summary)
                    }
                }
            }
        }
    }

    nonisolated static func words(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func changedSince(_ summary: String) -> String {
        summary.hasSuffix(ChatActionWords.changed) ? summary : summary + ChatActionWords.changed
    }

    static func undoFailed(_ summary: String) -> String {
        summary.hasSuffix(ChatActionWords.failed) ? summary : summary + ChatActionWords.failed
    }

    static func receiptWords(_ r: ChatActionRequest) -> String {
        switch r.kind {
        case .addPoint: "Saved " + (r.seriesTitle.map { "for the next \($0)" } ?? r.personName.map { "for \($0)" } ?? "") + ": \(r.text ?? "")"
        case .addTask: "Task added: \(r.text ?? "")"
        case .addBookmark: "Bookmarked \(r.callTitle ?? "the meeting")" + (r.text.map { ": \($0)" } ?? "")
        default: r.text ?? "Done"
        }
    }

    // MARK: The chat file

    private func chatAction(_ chatID: UUID, _ messageID: UUID, _ actionID: UUID) -> ChatActionRecord? {
        (try? chats.load(chatID))??.messages.first { $0.id == messageID }?.actions?.first { $0.id == actionID }
    }

    private func updateAction(_ chatID: UUID, _ messageID: UUID, _ actionID: UUID, _ change: (inout ChatActionRecord) -> Void) {
        _ = changeChat(chatID) { chat in
            guard let m = chat.messages.firstIndex(where: { $0.id == messageID }), let a = chat.messages[m].actions?.firstIndex(where: { $0.id == actionID }) else { return }
            change(&chat.messages[m].actions![a])
        }
    }

    private func addActions(_ chatID: UUID, _ messageID: UUID, _ more: [ChatActionRecord]) {
        guard !more.isEmpty else { return }
        _ = changeChat(chatID) { chat in
            guard let m = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
            chat.messages[m].actions = (chat.messages[m].actions ?? []) + more
        }
    }

    /// Reads the chat from its file, changes it, and saves it: the one writer. The open sessions show the result.
    @discardableResult
    private func changeChat(_ id: UUID, fallback: Chat? = nil, _ change: (inout Chat) -> Void) -> Chat? {
        guard var chat = ((try? chats.load(id)) ?? nil) ?? fallback else { return nil }
        change(&chat)
        chat.updated = Date()
        do { try chats.save(chat) } catch { Log.error("Saving the chat failed: \(error)") }
        chatsVersion += 1
        for session in [quickChat].compactMap({ $0 }) + Array(liveChatSessions.values) where session.chat?.id == id { session.show(chat) }
        return chat
    }
}

enum ChatActionWords {
    static let changed = " (changed since, so Undo is gone)"
    static let failed = " (Undo did not work now; try again after the call or later)"
}

/// The result of a write that runs on the pipeline, for a host function that must answer when it is written.
private final class Wait: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = false
    func finish(_ ok: Bool) { lock.withLock { value = ok }; done.signal() }
    func result(within seconds: Double) -> Bool {
        guard done.wait(timeout: .now() + seconds) == .success else { return false }
        return lock.withLock { value }
    }
}
