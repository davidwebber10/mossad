import Foundation
import Observation

/// One profile's room recordings on the iPhone: its outbox, its sync choice and store, and its uploads. Moved out of
/// the phone's store as it was; one uploader for each profile lives for the app's life, and the store of the profile
/// that shows uses the same object, so a switch never makes a second sender.
@MainActor @Observable
public final class ProfileUploader {
    /// What the uploader asks of the world. `live` is the phone's; a test gives made-up stores and a secret in a box.
    public struct Parts: Sendable {
        public var icloud: @Sendable (_ zone: String) -> any RecordStore
        public var server: @Sendable (ServerConnection) -> any RecordStore
        /// This profile's own server secret.
        public var secret: @Sendable () -> String?
        public var setSecret: @Sendable (String?) -> Void
        /// The server the Mac shared for this profile through iCloud Keychain.
        public var pairedServer: @Sendable () -> ServerConnection?

        public init(icloud: @escaping @Sendable (String) -> any RecordStore, server: @escaping @Sendable (ServerConnection) -> any RecordStore,
                    secret: @escaping @Sendable () -> String?, setSecret: @escaping @Sendable (String?) -> Void,
                    pairedServer: @escaping @Sendable () -> ServerConnection?) {
            self.icloud = icloud
            self.server = server
            self.secret = secret
            self.setSecret = setSecret
            self.pairedServer = pairedServer
        }

        /// The profile's own zone, Keychain service, and shared server item: never another profile's.
        public static func live(_ context: PhoneProfileContext) -> Parts {
            let keychain = Keychain(service: context.keychainService)
            let id = context.id
            return Parts(icloud: { CloudKitStore(zone: $0) }, server: { ServerStore($0) },
                         secret: { keychain.get(.serverSecret) },
                         setSecret: { secret in
                             if let secret {
                                 do { try keychain.set(secret, for: .serverSecret) } catch { Log.error("Saving the server secret failed: \(error)") }
                             } else {
                                 keychain.delete(.serverSecret)
                             }
                         },
                         pairedServer: { ServerPairing.shared(profile: id) })
        }
    }

    public let context: PhoneProfileContext
    public let paths: Paths
    @ObservationIgnored public let settings: UserDefaults
    /// Every write to a file that a pull also writes, and the pull itself, one at a time.
    @ObservationIgnored public let writes = SerialQueue()
    @ObservationIgnored private let parts: Parts
    @ObservationIgnored private let offline: Bool
    @ObservationIgnored let background: @MainActor (String) -> @MainActor () -> Void
    /// The app's one recorder's id: a pass that a change of store starts asks it, as every other caller does.
    @ObservationIgnored public let liveRecording: @MainActor () -> String?

    /// Room recordings made here, and shared calls, that the Mac has not turned into meetings yet.
    public internal(set) var outbox = Outbox()
    /// Recordings uploading now: one upload per recording at a time.
    public internal(set) var uploading: Set<String> = []
    /// Recordings whose parts are being joined, or whose shared audio is being added.
    public internal(set) var joining: Set<String> = []
    /// The handed files that an import reads now.
    public internal(set) var importing: Set<String> = []
    /// Why each recording waits, and the last problem of a pass.
    public var syncStatus = SyncStatus()
    /// What the Mac says of this profile's sync; a change is taken at once.
    public var listed: SyncChoice? {
        didSet { if listed != oldValue { refreshSync() } }
    }
    /// False for a profile the Mac no longer has: it keeps its recordings and sends nothing.
    public var sends = true {
        didSet { if sends != oldValue { engine = nil } }
    }
    /// The profile shows: its store pulls and settles, so `pass` does nothing.
    public var shown = false
    /// The store-only part of a change of store (the store that shows starts its own sync).
    @ObservationIgnored public var onStoreChange: (@MainActor () -> Void)?
    /// The meetings of the store that shows, for an import's duplicates; nil reads this profile's folder. The list is
    /// nil while the store has not read its meetings: then the import memory is not cut.
    @ObservationIgnored public var known: (@MainActor () -> [CallImport.Known]?)?
    /// Reads the meetings of this profile's folder; nil when they cannot be read. A test holds it to make two imports
    /// meet in one place.
    @ObservationIgnored public var readMeetings: @Sendable (Paths) async -> [CallImport.Known]? = { paths in
        await Task.detached(priority: .utility) {
            (try? ProcessingQueue(paths: paths).scan().records)?.map { CallImport.Known(id: $0.id, start: $0.start, end: $0.end) }
        }.value
    }
    /// Lists the recordings folder; nil when it cannot be listed. A test holds it to start a recording during the wait.
    @ObservationIgnored public var listAudio: @Sendable (URL) async -> Set<String>? = { dir in
        await Task.detached { RoomAudio.ids(in: dir) }.value
    }
    /// This profile's saved people, for an import's person choices.
    public internal(set) var people: [Person] = []
    /// Nil: not known, so nothing is sent.
    public private(set) var syncWith: SyncChoice?
    /// The number of entries in the outbox; nil until the outbox on disk was read, so a count is never 0 by mistake.
    public var outboxCount: Int? { outboxReadDone ? outbox.entries.count : nil }

    @ObservationIgnored private var engine: (key: String, sync: CloudSync)?
    @ObservationIgnored private var outboxRead: Task<Void, Never>?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var outboxReadDone = false
    /// A profile that does not show is recovered once, at its first pass.
    @ObservationIgnored private var recovered = false

    public init(context: PhoneProfileContext, paths: Paths, settings: UserDefaults, listed: SyncChoice?, offline: Bool, parts: Parts,
                active: @escaping @MainActor () -> String?,
                background: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} }) {
        liveRecording = active
        self.context = context
        self.paths = paths
        self.settings = settings
        self.listed = listed
        self.offline = offline
        self.parts = parts
        self.background = background
        syncWith = context.sync(saved: settings.string(forKey: "syncWith"), listed: listed)
    }

    private func refreshSync() {
        let next = context.sync(saved: settings.string(forKey: "syncWith"), listed: listed)
        guard next != syncWith else { return }
        syncWith = next
        storeChanged()
    }

    // MARK: The store

    /// Whether this profile has a server, read off the main actor: each read is a Keychain read.
    public func hasServer() async -> Bool {
        let parts = parts, address = settings.string(forKey: "serverAddress").flatMap(ServerConnection.address(from:))
        return await Task.detached(priority: .utility) { (address != nil && parts.secret() != nil) || parts.pairedServer() != nil }.value
    }

    /// The server this profile uses: the one set up here, or the one the Mac shared for it through iCloud Keychain.
    public var server: ServerConnection? {
        if let text = settings.string(forKey: "serverAddress"), let address = ServerConnection.address(from: text), let secret = parts.secret() {
            return ServerConnection(address: address, secret: secret)
        }
        return parts.pairedServer()
    }

    /// "iCloud" or "your server", for messages.
    public var place: String { syncWith == .server ? "your server" : "iCloud" }

    /// The store in use and its name, which the outbox keeps for each upload. Today's keys, so an outbox of before
    /// reads as sent to the same store.
    public var cloud: (key: String, sync: CloudSync)? {
        guard !offline, sends else { return nil }
        let key: String
        let make: () -> any RecordStore
        switch syncWith {
        case .icloud?:
            key = "icloud"
            let zone = context.cloudZone, parts = parts
            make = { parts.icloud(zone) }
        case .server?:
            guard let c = server else { return nil }
            key = "server:\(c.address.absoluteString)"
            let parts = parts
            make = { parts.server(c) }
        case .off?, nil: return nil
        }
        if let engine, engine.key == key { return engine }
        // The iPhone moves no meeting: nothing of it is ever leaving.
        let sync = CloudSync(paths: paths, store: make(), leaving: { [] })
        engine = (key, sync)
        return engine
    }

    public func choose(_ choice: SyncChoice) {
        guard choice != syncWith else { return }
        use(choice)
    }

    /// Moves to a store (also to another server): the old one is let go, and the new one is used at once.
    private func use(_ choice: SyncChoice) {
        settings.set(choice.rawValue, forKey: "syncWith")
        syncWith = context.sync(saved: choice.rawValue, listed: listed)
        storeChanged()
    }

    private func storeChanged() {
        engine = nil
        syncStatus.show(nil)
        if let onStoreChange { onStoreChange() } else { Task { await pass(active: liveRecording) } }
    }

    /// Keeps a checked server for this profile and syncs with it. The secret goes to this profile's own service.
    public func connect(_ c: ServerConnection) {
        parts.setSecret(c.secret)
        settings.set(c.address.absoluteString, forKey: "serverAddress")
        use(.server)
    }

    /// The first profile goes back to iCloud, as before. Another profile has no choice of its own after this: it
    /// syncs as the Mac lists it, so a disconnect never saves "icloud" for a profile whose Mac uses its server.
    public func disconnectServer() {
        parts.setSecret(nil)
        settings.removeObject(forKey: "serverAddress")
        guard !context.isDefault else { return choose(.icloud) }
        settings.removeObject(forKey: "syncWith")
        let next = context.sync(saved: nil, listed: listed)
        guard next != syncWith else { return storeChanged() }
        syncWith = next
        storeChanged()
    }

    // MARK: The outbox

    public var recordingsFolder: URL { paths.root.appendingPathComponent("Recordings") }
    private var outboxFile: URL { recordingsFolder.appendingPathComponent(Outbox.fileName) }

    /// The first read of the outbox, once. A new recording and a sync wait for it.
    public func ready() async {
        if outboxRead == nil {
            let file = outboxFile
            outboxRead = Task {
                let (box, aside) = await Task.detached { Outbox.loadOrSetAside(from: file) }.value
                if let aside { Log.error("The outbox could not be read; it is kept as \(aside.lastPathComponent)") }
                outbox = box
                outboxReadDone = true
            }
        }
        await outboxRead?.value
    }

    /// Returns false when the write failed. A room recording's entry exists from its start, so a lost write is
    /// repaired by the next launch's scan; an import must know, as the scan would make it a room recording.
    @discardableResult
    func saveOutbox() -> Bool {
        defer { syncStatus.keepUploads(for: Set(outbox.entries.filter { !$0.isSent }.map(\.id))) }
        do {
            try outbox.save(to: outboxFile)
            return true
        } catch {
            Log.error("Saving the outbox failed: \(error)")
            return false
        }
    }

    /// An imported recording's entry, saved before its audio is in the folder. False when it could not be saved:
    /// then the entry is gone again.
    func addImported(_ recording: PhoneRecording) -> Bool {
        outbox.addFinished(recording)
        guard outbox[recording.id]?.recording == recording, saveOutbox() else {
            if outbox[recording.id]?.recording == recording { outbox.remove(recording.id) }
            return false
        }
        return true
    }

    /// Takes back an imported recording whose audio could not be added.
    func dropImported(_ id: String) {
        outbox.remove(id)
        saveOutbox()
    }

    /// Removes recordings whose meeting has arrived from the Mac, with their audio. Only a one-track meeting from the
    /// iPhone counts: ids are start times, and a call on the Mac can start in the same second as a recording.
    public func settle(arrived: Set<String>) {
        let done = outbox.settle(arrived: arrived)
        guard !done.isEmpty else { return }
        let dir = recordingsFolder
        for id in done { RoomAudio.delete(id, in: dir) }
        saveOutbox()
    }

    /// An entry besides the one recording now: the app then looks now and then without a pull to refresh.
    public func waits(active: String?) -> Bool {
        outbox.entries.contains { $0.id != active } && !offline && syncWith != nil && syncWith != .off && sends
    }

    // MARK: The room recorder

    public func begin(_ recording: PhoneRecording) {
        outbox.begin(recording)
        saveOutbox()
    }

    /// Keeps the name the owner types in the entry, so a recording that the app never finishes still has it.
    public func keepTitle(_ id: String, _ title: String?) {
        guard let entry = outbox[id] else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kept = t.isEmpty ? nil : t
        guard entry.recording.title != kept else { return }
        outbox.retitle(id, kept)
        saveOutbox()
    }

    /// What a stop does after the recorder stopped: keeps the recording unless it is short (or the owner discarded a
    /// short one), joins its parts into one file, and sends it, with background time.
    public func finish(_ id: String, end: Date, counted: TimeInterval, title: String?, discard: Bool) {
        let dir = recordingsFolder
        outbox.retitle(id, title)
        joining.insert(id)
        Task {
            let release = background("Finish the room recording")
            defer { release() }
            let deleted = await Task.detached { () -> Bool in
                let measured = RoomAudio.length(of: id, in: dir)
                if RoomRecording.keep(measured: measured, counted: counted, discard: discard) { return false }
                // The owner's own "Discard" is enough. Without it, a part that did not open may hold more than the
                // count says, so the files must also be short by every measure.
                guard discard || RoomAudio.isSurelyShort(id, in: dir, minimum: ProcessingQueue.minimumCallDuration) else { return false }
                RoomAudio.delete(id, in: dir)
                return true
            }.value
            if deleted {
                joining.remove(id)
                outbox.remove(id)
                saveOutbox()
                return
            }
            await join(id, end: end, title: nil)
            await sendOutbox()
        }
    }

    /// Finishes each recording that the app never finished, and each audio file with no entry, as the Mac does for
    /// its own calls after a crash. It runs at launch, and again after a sync while a recording is not saved.
    /// `active` is asked at each use: a recording can start while this pass waits for the disk.
    public func recover(active: @escaping @MainActor () -> String?) async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }
        let dir = recordingsFolder
        guard let audio = await listAudio(dir) else {
            // Unknown is not empty: no entry is removed because the folder would not list.
            Log.error("The recordings folder could not be listed; recovery waits")
            return
        }
        for id in outbox.withoutAudio(audioIDs: audio, active: active()) where !joining.contains(id) {
            Log.error("The room recording \(id) has no audio on this iPhone; its entry is removed")
            outbox.remove(id)
            saveOutbox()
        }
        for id in outbox.needsRecovery(audioIDs: audio, active: active()) {
            // Looked at again: the Stop path may have finished it while this pass joined another one, and a recording
            // may have started since the list.
            guard id != active(), !joining.contains(id), outbox[id].map({ $0.state == .recording }) ?? true else { continue }
            joining.insert(id)
            let found = await Task.detached { () -> (short: Bool, end: Date?) in
                // Once the parts are joined, the file's date is the join's, not the meeting's end.
                (RoomAudio.isSurelyShort(id, in: dir, minimum: ProcessingQueue.minimumCallDuration),
                 RoomAudio.parts(of: id, in: dir).isEmpty ? nil : RoomAudio.lastWrite(of: id, in: dir))
            }.value
            // The owner may have started this very recording while the files were read.
            guard id != active() else {
                joining.remove(id)
                continue
            }
            if found.short {
                // Short by every measure: each part opened, and its bytes agree.
                RoomAudio.delete(id, in: dir)
                outbox.remove(id)
                saveOutbox()
                joining.remove(id)
                continue
            }
            if outbox[id] == nil {
                let start = RoomAudio.start(of: id) ?? found.end ?? Date()
                outbox.begin(PhoneRecording(id: id, start: start, end: start, title: nil))
            }
            await join(id, end: found.end, title: nil)
        }
    }

    /// Tries again for recordings that could not be saved, without waiting for the next launch.
    public func retryUnfinished(active: @escaping @MainActor () -> String?) {
        let now = active()
        guard !recovering, outbox.entries.contains(where: { $0.state == .recording && $0.id != now && !joining.contains($0.id) })
        else { return }
        Task {
            await recover(active: active)
            await sendOutbox()
        }
    }

    /// Joins a stopped recording's parts into the file to send, and puts it in line. The caller has put the id in
    /// `joining`. A part that cannot be read does not hold back the rest: what reads is joined and sent, the bad
    /// part stays on the iPhone under its own name, and the row says so. Any other failure (a full disk) keeps
    /// every part, and the next sync tries again.
    private func join(_ id: String, end: Date?, title: String?) async {
        defer { joining.remove(id) }
        let dir = recordingsFolder
        let result = await Task.detached { () -> Result<RoomAudio.Joined, any Error> in
            do {
                return .success(try RoomAudio.finish(id, in: dir))
            } catch is RoomAudio.Unreadable {
                return Result { try RoomAudio.finish(id, in: dir, salvage: true) }
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let joined):
            let start = outbox[id]?.recording.start ?? Date()
            outbox.finish(id, end: end ?? start.addingTimeInterval(joined.length), title: title)
            if joined.setAside.isEmpty {
                Log.info("Saved the room recording \(id) (\(Int(joined.length)) s)")
            } else {
                Log.error("The room recording \(id) was saved without parts that could not be read; they stay as \(joined.setAside.joined(separator: ", "))")
                outbox.setTrouble(id, .partUnreadable)
            }
        case .failure(let error):
            // The parts stay, and the entry stays `recording`. Logged once, not at each try.
            if outbox[id]?.trouble != .notSaved { Log.error("Saving the room recording \(id) failed: \(error)") }
            outbox.setTrouble(id, .notSaved)
        }
        saveOutbox()
    }

    /// Whether a row offers "Remove".
    public func canRemove(_ id: String, active: String?) -> Bool {
        outbox.canRemove(id, active: active, busy: uploading.union(joining))
    }

    /// The owner's "Remove": the row, its audio, and any parts set aside. Nothing else deletes a recording that the
    /// Mac does not have.
    public func remove(_ id: String, active: String?) {
        guard canRemove(id, active: active) else { return }
        RoomAudio.delete(id, in: recordingsFolder, setAside: true)
        outbox.remove(id)
        saveOutbox()
        Log.info("The owner removed the room recording \(id)")
    }

    /// The owner's "Send again" on a recording whose meeting has not come back.
    public func sendAgain(_ id: String) {
        outbox.sendAgain(id)
        saveOutbox()
        Task { await sendOutbox() }
    }

    // MARK: Sending

    /// Uploads what the store does not have yet, and again what it took long ago with no meeting back, or what
    /// another store took. The audio stays here until the meeting comes back from the Mac.
    public func sendOutbox() async {
        guard let engine = cloud else { return }
        let key = engine.key, cloud = engine.sync
        let dir = recordingsFolder
        for listed in outbox.due(store: key, now: Date()) {
            // Looked at again here: another pass may have sent it while this one uploaded the one before. An import
            // whose audio is still being added waits in `joining`.
            guard !uploading.contains(listed.id), !joining.contains(listed.id),
                  let entry = outbox.due(store: key, now: Date()).first(where: { $0.id == listed.id }) else { continue }
            uploading.insert(entry.id)
            let release = background("Upload the room recording")
            do {
                try await cloud.upload(entry.recording, audio: RoomAudio.finished(entry.id, in: dir))
                outbox.markSent(entry.id, store: key, at: Date())
                saveOutbox()
                syncStatus.uploaded(entry.id)
            } catch {
                Log.error("Uploading the room recording failed: \(error)")
                syncStatus.uploadFailed(entry.id, FriendlyError(error, context: .uploadingAudio, service: place))
            }
            release()
            uploading.remove(entry.id)
        }
    }

    /// For a profile that does not show: pulls its store only while a sent recording waits, settles by the meetings
    /// of its own folder, then sends. A profile that shows leaves this to its store.
    public func pass(active: @escaping @MainActor () -> String?) async {
        guard !shown else { return }
        // A profile that does not show is read only here: its outbox on disk first, then what a crash left.
        await ready()
        guard !shown else { return }
        if !recovered || outbox.entries.contains(where: { $0.state == .recording && !joining.contains($0.id) }) {
            recovered = true
            await recover(active: active)
        }
        // With nothing to send no store is made.
        guard !shown, !outbox.entries.isEmpty, let engine = cloud else { return }
        if outbox.entries.contains(where: \.isSent) {
            let sync = engine.sync, place = place
            do {
                _ = try await writes.run { try await TransientRetry.run { try await sync.pull(includeMeetings: true) } }
            } catch is CancellationError {
            } catch {
                Log.error("Sync with \(place) failed: \(error)")
                syncStatus.failed(FriendlyError(error, context: .syncing, service: place))
            }
            let ids = outbox.entries.map(\.id), paths = paths
            let records = await Task.detached { Self.arrivals(of: ids, paths: paths) }.value
            settle(arrived: Outbox.arrived(records))
        }
        await sendOutbox()
    }

    /// The meetings of these recordings in this folder only: `<id>` and `<id>-iphone`. No list, no index.
    nonisolated static func arrivals(of ids: [String], paths: Paths) -> [CallRecord] {
        ids.flatMap { [$0, $0 + "-iphone"] }.compactMap { try? CallRecord.load(from: paths.callDirectory($0)) }
    }
}

/// One uploader for each profile, for the app's life.
@MainActor
public final class ProfileUploaders {
    private let make: @MainActor (PhoneProfile) -> ProfileUploader?
    private var made: [String: ProfileUploader] = [:]
    private var order: [String] = []

    public init(make: @escaping @MainActor (PhoneProfile) -> ProfileUploader?) {
        self.make = make
    }

    /// The same object for an id, whatever its name or color. A profile that could not open is asked again.
    public func uploader(for profile: PhoneProfile) -> ProfileUploader? {
        if let u = made[profile.id] { return u }
        guard let u = make(profile) else { return nil }
        made[profile.id] = u
        order.append(profile.id)
        return u
    }

    public var all: [ProfileUploader] { order.compactMap { made[$0] } }

    public func drop(_ id: String) {
        made[id] = nil
        order.removeAll { $0 == id }
    }
}
