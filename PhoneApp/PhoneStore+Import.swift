import Foundation
import MossadCore

/// A call recording shared to the app: the rules are `CallImport`'s, the order of the writes is this file's.
extension PhoneStore {
    var importMemoryFile: URL { recordingsFolder.appendingPathComponent(ImportMemory.fileName) }

    /// The people the owner can pick for a call: the saved people, else the named speakers of the meetings.
    func importChoices(_ query: String) -> [CallImport.Choice] {
        CallImport.choices(query: query, people: people, heard: Array(personStats.keys), owner: owner)
    }

    /// A refusal the screen can show before the owner taps anything; nil when the file can be added.
    func importRefusal(_ draft: CallImport.Draft, from url: URL) async -> CallImport.Refusal? {
        if case .failure(let refusal) = await importPlan(draft, from: url).plan { return refusal }
        return nil
    }

    /// Adds the file. Returns the recording's id once the outbox entry and the audio are saved; the upload starts
    /// after. The entry is saved first and the id is held in `joining` while the audio is added, so a stop in the
    /// middle is never taken for a room recording. On a failure nothing is added and the handed file stays.
    func importCall(_ draft: CallImport.Draft, from url: URL) async -> Result<String, CallImport.Refusal> {
        let (planned, hash, _) = await importPlan(draft, from: url)
        let plan: CallImport.Plan
        switch planned {
        case .failure(let refusal): return .failure(refusal)
        case .success(let p): plan = p
        }
        joining.insert(plan.id)
        importing.insert(url.path)
        // A long convert must not stop when the owner goes back to Notes: the entry would lose its audio.
        let time = BackgroundTime("Add the shared recording")
        defer {
            joining.remove(plan.id)
            importing.remove(url.path)
            time.end()
        }
        guard addImported(PhoneRecording(plan)) else { return .failure(.notSaved) }

        let dir = recordingsFolder, id = plan.id, convert = plan.convert
        let adopted = await Task.detached(priority: .utility) { () -> CallImport.Refusal? in
            do {
                try RoomAudio.adopt(url, as: id, in: dir, convert: convert)
                return nil
            } catch is RoomAudio.Unreadable {
                return .unreadable
            } catch {
                Log.error("Adding the shared recording \(id) failed: \(error)")
                return .notSaved
            }
        }.value
        if let adopted {
            dropImported(id)
            return .failure(adopted)
        }

        if let hash {
            // Read again just before the write, one write at a time: an import that overlapped keeps its hash.
            let file = importMemoryFile
            let ids: Set<String>? = loaded ? Set(outbox.entries.map(\.id) + meetings.map(\.id)) : nil
            do {
                try await writes.run {
                    var memory = ImportMemory.load(from: file)
                    memory.remember(hash: hash, id: id)
                    if let ids { memory.keep(only: ids) }
                    try memory.save(to: file)
                }
            } catch {
                Log.error("Saving the imported files failed: \(error)")
            }
        }
        discardIncoming(url)
        Log.info("Added the shared recording \(id)")
        Task { await sendOutbox() }
        return .success(id)
    }

    /// Deletes the app's own copy of a handed file. A file outside the app's folders is never touched.
    func discardIncoming(_ url: URL) {
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Waits for the upload of one recording, at most `seconds`.
    func sent(_ id: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        Task { await sendOutbox() }
        while Date() < deadline {
            if outbox[id]?.isSent == true { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return outbox[id]?.isSent == true
    }

    /// Files that iOS handed over and the app never took, by `CallImport.clearsFromInbox`: added a day ago or more,
    /// and not the file the screen shows or an import reads.
    func clearOldInbox() {
        let inUse = Set([incomingAudio?.url.standardizedFileURL.path].compactMap { $0 } + importing.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        Task.detached(priority: .utility) {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let inbox = docs.appendingPathComponent("Inbox")
            let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.addedToDirectoryDateKey])) ?? []
            let now = Date()
            for f in files {
                let added = try? f.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
                guard CallImport.clearsFromInbox(added: added, now: now, inUse: inUse.contains(f.standardizedFileURL.path)) else { continue }
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// The plan, with the file's hash and the memory it was checked against. Waits for the outbox and the meetings.
    private func importPlan(_ draft: CallImport.Draft, from url: URL) async -> (plan: Result<CallImport.Plan, CallImport.Refusal>, hash: String?, memory: ImportMemory) {
        await launch?.value
        let file = importMemoryFile
        let (hash, memory) = await Task.detached(priority: .utility) {
            ((try? ImportMemory.hash(of: url)), ImportMemory.load(from: file))
        }.value
        let outbox = self.outbox.entries.map { CallImport.Known(id: $0.id, start: $0.recording.start, end: $0.recording.end) }
        let meetings = self.meetings.map { CallImport.Known(id: $0.id, start: $0.start, end: $0.end) }
        return (CallImport.plan(draft, hash: hash, outbox: outbox, meetings: meetings, memory: memory, now: Date()), hash, memory)
    }
}
