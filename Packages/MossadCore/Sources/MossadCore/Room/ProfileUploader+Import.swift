import Foundation

/// A call recording shared to the app, added to one profile: its folder, its outbox, its import memory, its people,
/// and its store. The rules are `CallImport`'s; the order of the writes is this file's, moved from the phone's store.
extension ProfileUploader {
    var importMemoryFile: URL { recordingsFolder.appendingPathComponent(ImportMemory.fileName) }

    public var isImporting: Bool { !importing.isEmpty }

    /// This profile's saved people (the owner's server sends them), read off the main actor.
    public func loadPeople() async {
        let dir = paths.people
        people = await Task.detached(priority: .utility) { PeopleStore.peek(in: dir) ?? [] }.value
    }

    /// The people the owner can pick for a call: this profile's saved people, else the names given.
    public func importChoices(_ query: String, heard: [String], owner: String) -> [CallImport.Choice] {
        CallImport.choices(query: query, people: people, heard: heard, owner: owner)
    }

    /// A refusal the screen can show before the owner taps anything; nil when the file can be added.
    public func importRefusal(_ draft: CallImport.Draft, from url: URL) async -> CallImport.Refusal? {
        if case .failure(let refusal) = await importPlan(draft, from: url).plan { return refusal }
        return nil
    }

    /// Adds the file. Returns the recording's id once the outbox entry and the audio are saved; the upload starts
    /// after. The entry is saved first and the id is held in `joining` while the audio is added, so a stop in the
    /// middle is never taken for a room recording. On a failure nothing is added. The caller deletes the handed file.
    public func importCall(_ draft: CallImport.Draft, from url: URL) async -> Result<String, CallImport.Refusal> {
        await loadPeople()
        var draft = draft
        // A person id goes only with a person of this profile: an id of another profile would name a stranger.
        if let person = draft.person, let id = person.personID, !people.contains(where: { $0.id.rawValue == id }) {
            draft.person = CallImport.Choice(name: person.name, personID: nil)
        }
        let (planned, hash, _) = await importPlan(draft, from: url)
        let plan: CallImport.Plan
        switch planned {
        case .failure(let refusal): return .failure(refusal)
        case .success(let p): plan = p
        }
        joining.insert(plan.id)
        importing.insert(url.path)
        // A long convert must not stop when the owner goes back to Notes: the entry would lose its audio.
        let release = background("Add the shared recording")
        defer {
            joining.remove(plan.id)
            importing.remove(url.path)
            release()
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
            let ids = Set(outbox.entries.map(\.id) + (await meetings()).map(\.id))
            do {
                try await writes.run {
                    var memory = ImportMemory.load(from: file)
                    memory.remember(hash: hash, id: id)
                    memory.keep(only: ids)
                    try memory.save(to: file)
                }
            } catch {
                Log.error("Saving the imported files failed: \(error)")
            }
        }
        Log.info("Added the shared recording \(id)")
        Task { await sendOutbox() }
        return .success(id)
    }

    /// Waits for the upload of one recording, at most `seconds`.
    public func sent(_ id: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        Task { await sendOutbox() }
        while Date() < deadline {
            if outbox[id]?.isSent == true { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return outbox[id]?.isSent == true
    }

    /// The meetings of the store that shows, else this profile's folder, read off the main actor.
    private func meetings() async -> [CallImport.Known] {
        if let known { return known() }
        let paths = paths
        return await Task.detached(priority: .utility) {
            MeetingIndex(paths: paths).all().map { CallImport.Known(id: $0.id, start: $0.start, end: $0.end) }
        }.value
    }

    /// The plan, with the file's hash and the memory it was checked against. Waits for the outbox.
    private func importPlan(_ draft: CallImport.Draft, from url: URL) async -> (plan: Result<CallImport.Plan, CallImport.Refusal>, hash: String?, memory: ImportMemory) {
        await ready()
        let file = importMemoryFile
        let (hash, memory) = await Task.detached(priority: .utility) {
            ((try? ImportMemory.hash(of: url)), ImportMemory.load(from: file))
        }.value
        let outbox = self.outbox.entries.map { CallImport.Known(id: $0.id, start: $0.recording.start, end: $0.recording.end) }
        let meetings = await meetings()
        return (CallImport.plan(draft, hash: hash, outbox: outbox, meetings: meetings, memory: memory, now: Date()), hash, memory)
    }
}
