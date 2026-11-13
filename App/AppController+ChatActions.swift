import Foundation
import MossadCore

/// What the app's own chat can do: the writes of its action tools (`ChatActions`), the click on a card, and Undo.
/// The points and the tasks are their files; a bookmark goes through the recorder during a call and the pipeline
/// after it, as the hotkey and the player do. During a call nothing here starts a sync: the sync after the call
/// sends it.
extension AppController {
    /// The writes of one answer, made on the main actor and used off it.
    var chatActionHost: ChatActionHost {
        let recorder = self.recorder, pipeline = self.pipeline, paths = self.paths
        return ChatActionHost(
            paths: paths,
            liveMoment: { CaptureQueue.queue.sync { recorder.liveMoment } },
            bookmark: { callID, at, note in
                Task {
                    if let note = Self.words(note) { await pipeline?.setBookmarkNote(callID: callID, offset: at, note: note) } else { await pipeline?.addBookmark(callID: callID, offset: at) }
                    await MainActor.run { self.refresh() }
                }
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
                guard CaptureQueue.queue.sync(execute: { recorder.currentRecord?.id }) != callID else { return false }
                Task {
                    await pipeline?.removeBookmark(callID: callID, offset: at)
                    await MainActor.run { self.refresh() }
                }
                return true
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

    /// "Do it" or "Not now" on a card, and Undo on a receipt: the chat file keeps the new state.
    func answerActionCard(chatID: UUID, messageID: UUID, actionID: UUID, doIt: Bool) {
        guard let action = chatAction(chatID, messageID, actionID), action.state == .proposed else { return }
        guard doIt else { return updateAction(chatID, messageID, actionID) { $0.state = .declined } }
        let request = action.request
        if request.kind.needsClick, isRecording, request.kind != .batch {
            // The riskier class never runs during a call.
            return
        }
        let host = chatActionHost
        switch request.kind {
        case .batch:
            let now = Date()
            Task {
                let done = await Task.detached(priority: .userInitiated) { (request.items ?? []).map { ($0, host.perform($0, now: now)) } }.value
                updateAction(chatID, messageID, actionID) { $0.state = done.allSatisfy { $0.1 != nil } ? .done : .failed }
                // Each one of the card gets its own receipt, with its Undo.
                addActions(chatID, messageID, done.compactMap { r, change in
                    change.map { ChatActionRecord(request: r, state: .done, summary: Self.receiptWords(r), undo: $0.undo, after: $0.after, date: now) }
                })
            }
        case .nameVoice:
            guard let callID = request.callID, let key = request.speakerKey, let name = request.text else { return }
            applyNames(callID: callID, names: [key: name], emails: request.email.map { [key: $0] } ?? [:])
            updateAction(chatID, messageID, actionID) { $0.state = .done }
        case .renameMeeting:
            guard let callID = request.callID, let title = request.text else { return }
            let before = meetings.first { $0.id == callID }?.customTitle
            setTitle(callID: callID, title)
            updateAction(chatID, messageID, actionID) { a in
                a.state = .done
                var undo = ChatActionRequest(.renameMeeting)
                undo.callID = callID
                undo.text = before
                a.undo = undo
                var after = ChatActionTarget()
                after.title = title
                a.after = after
            }
        case .addTag, .removeTag:
            guard let callID = request.callID, let r = meetings.first(where: { $0.id == callID }) else { return }
            let chosen = request.tags ?? []
            let tags = request.kind == .addTag ? r.tags + chosen.filter { t in !r.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                : r.tags.filter { t in !chosen.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
            setTags(callID: callID, tags)
            updateAction(chatID, messageID, actionID) { a in
                a.state = .done
                var undo = ChatActionRequest(.addTag)
                undo.callID = callID
                undo.tags = r.tags
                a.undo = undo
                var after = ChatActionTarget()
                after.tags = tags
                a.after = after
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
            Task {
                let change = await Task.detached(priority: .userInitiated) { host.perform(request, now: now) }.value
                updateAction(chatID, messageID, actionID) { a in
                    a.state = change == nil ? .failed : .done
                    a.undo = change?.undo
                    a.after = change?.after
                }
            }
        }
    }

    /// Undo of a receipt, while its target is as the action left it; else the receipt says it changed since.
    func undoChatAction(chatID: UUID, messageID: UUID, actionID: UUID) {
        guard let action = chatAction(chatID, messageID, actionID), action.state == .done, let undo = action.undo else { return }
        switch undo.kind {
        case .renameMeeting, .addTag:
            guard let callID = undo.callID, let r = meetings.first(where: { $0.id == callID }) else { return }
            let now = undo.kind == .renameMeeting ? ChatActionTarget.title(r.customTitle) : ChatActionTarget.tags(r.tags)
            guard now == action.after else { return updateAction(chatID, messageID, actionID) { $0.summary = Self.changedSince($0.summary); $0.undo = nil } }
            if undo.kind == .renameMeeting { setTitle(callID: callID, undo.text) } else { setTags(callID: callID, undo.tags ?? []) }
            updateAction(chatID, messageID, actionID) { $0.state = .undone }
        default:
            let host = chatActionHost
            Task {
                let outcome = await Task.detached(priority: .userInitiated) { host.undo(action, now: Date()) }.value
                updateAction(chatID, messageID, actionID) { a in
                    switch outcome {
                    case .undone: a.state = .undone
                    case .changedSince: a.summary = Self.changedSince(a.summary); a.undo = nil
                    case .failed: break
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
        chats.all().first { $0.id == chatID }?.messages.first { $0.id == messageID }?.actions?.first { $0.id == actionID }
    }

    private func updateAction(_ chatID: UUID, _ messageID: UUID, _ actionID: UUID, _ change: (inout ChatActionRecord) -> Void) {
        changeChat(chatID) { chat in
            guard let m = chat.messages.firstIndex(where: { $0.id == messageID }), let a = chat.messages[m].actions?.firstIndex(where: { $0.id == actionID }) else { return }
            change(&chat.messages[m].actions![a])
        }
    }

    private func addActions(_ chatID: UUID, _ messageID: UUID, _ more: [ChatActionRecord]) {
        guard !more.isEmpty else { return }
        changeChat(chatID) { chat in
            guard let m = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
            chat.messages[m].actions = (chat.messages[m].actions ?? []) + more
        }
    }

    private func changeChat(_ id: UUID, _ change: (inout Chat) -> Void) {
        guard var chat = chats.all().first(where: { $0.id == id }) else { return }
        change(&chat)
        chat.updated = Date()
        do { try chats.save(chat) } catch { Log.error("Saving the chat failed: \(error)") }
        chatsVersion += 1
        // The open sessions show the same chat.
        for session in [quickChat].compactMap({ $0 }) + Array(liveChatSessions.values) where session.chat?.id == id { session.adopt(chat) }
        if !isRecording { syncNow() }
    }
}

enum ChatActionWords {
    static let changed = " (changed since, so Undo is gone)"
}

extension ChatActionTarget {
    static func title(_ t: String?) -> ChatActionTarget { var x = ChatActionTarget(); x.title = t; return x }
    static func tags(_ t: [String]) -> ChatActionTarget { var x = ChatActionTarget(); x.tags = t; return x }
}
