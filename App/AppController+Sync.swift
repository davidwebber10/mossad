import AppKit
import Foundation
import MossadCore
import Security

/// What the Storage & Sync page shows about the last sync.
struct SyncActivity: Equatable {
    var running = false
    var last: Date?
    /// The problem to show: a single dropped connection is retried quietly, shows only when it repeats, and does
    /// not clear a problem already shown.
    var status = SyncStatus()
    /// During the first sync to a new store: meetings sent so far, of how many.
    var progress: (done: Int, total: Int)?

    static func == (a: SyncActivity, b: SyncActivity) -> Bool {
        a.running == b.running && a.last == b.last && a.status == b.status && a.progress?.done == b.progress?.done && a.progress?.total == b.progress?.total
    }
}

extension SyncActivity {
    var error: FriendlyError? { status.shown }
}

extension AppController {
    /// Whether this build may use iCloud: CloudKit stops the app when the entitlement is missing.
    static let hasICloud: Bool = {
        guard !Rehearsal.isOn, let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }()

    /// Puts the chosen AI provider, model, and key in iCloud Keychain for the iPhone, or removes them.
    func updateSharedAIKey() {
        guard Self.hasICloud else { return }
        // A local model is on this Mac, where the iPhone cannot reach it.
        guard shareAIKey, !aiProvider.isLocal, let apiKey = aiProvider.key, let key = keychain.get(apiKey) else {
            SharedAIKey.delete()
            return
        }
        let shared = SharedAIKey(provider: aiProvider.rawValue, model: aiProvider.resolvedModel(aiModel), key: key)
        guard SharedAIKey.load() != shared else { return }
        do { try shared.save() } catch { Log.error("Sharing the AI key with the iPhone failed: \(error)") }
    }

    // MARK: The server

    /// The owner's server, when an address and a secret are both set.
    var serverConnection: ServerConnection? {
        if ServerSample.isOn { return ServerSample.connection }
        guard let address = ServerConnection.address(from: serverAddress), let secret = keychain.get(.serverSecret) else { return nil }
        return ServerConnection(address: address, secret: secret)
    }

    /// Saves a checked server and makes it the sync store.
    func connectServer(_ c: ServerConnection, hello: ServerClient.Hello, syncThere: Bool) {
        serverMCP = hello.mcp?.absoluteString ?? ""
        serverHasChat = hello.chat
        serverShares = hello.shares
        serverRecordingLimit = Double(hello.recordingLimit ?? 0)
        // Another server has another id: the recordings on the old one are then not "in the backup" any more.
        let previous = serverID
        serverID = hello.id ?? ""
        if backupMovePending, !previous.isEmpty, previous != serverID {
            noteBackupMove("The move paused, because you connected another server. It goes on with the new server.")
        }
        do { try keychain.set(c.secret, for: .serverSecret) } catch { Log.error("Saving the server secret failed") }
        keysChanged()
        serverAddress = c.address.absoluteString
        if syncThere || syncWith == .off || !Self.hasICloud { syncWith = .server }
        syncEngine = nil
        mirrorEngine = nil
        updateSharedServer()
        let owner = ownerName
        // Rehearsal never writes to a server: a setup walkthrough must not change the owner's real one.
        let personas = personasInServerMCP
        if !Rehearsal.isOn { Task { try? await ServerClient(c).putConfig(owner: owner, personasInMCP: personas) } }
        syncNow()
    }

    /// Goes back to iCloud; the server and its data stay as they are.
    func disconnectServer() {
        if backupMovePending { noteBackupMove("The move paused, because no server is connected.") }
        keychain.delete(.serverSecret)
        keysChanged()
        serverAddress = ""
        serverMCP = ""
        serverShares = 0
        serverRecordingLimit = 0
        serverID = ""
        if syncWith == .server { syncWith = Self.hasICloud ? .icloud : .off }
        syncEngine = nil
        mirrorEngine = nil
        ServerPairing.unshare()
        syncActivity = SyncActivity()
    }

    func chooseSync(_ choice: SyncChoice) {
        guard choice != syncWith else { return }
        syncWith = choice
        syncEngine = nil
        syncActivity = SyncActivity()
        updateSharedServer()
        syncNow()
    }

    /// The server's address and secret in iCloud Keychain for the iPhone, when the owner wants that.
    func updateSharedServer() {
        guard Self.hasICloud else { return }
        if serverOnPhone, syncWith == .server, let c = serverConnection {
            if ServerPairing.shared() != c { try? ServerPairing.share(c) }
        } else {
            ServerPairing.unshare()
        }
    }

    // MARK: Sync

    private var currentSync: CloudSync? {
        let key: String
        let store: (any RecordStore)?
        switch syncWith {
        case .icloud:
            key = "icloud"
            store = Self.hasICloud ? CloudKitStore() : nil
        case .server:
            let c = serverConnection
            key = "server:\(c?.address.absoluteString ?? "")"
            store = c.map { ServerStore($0) }
        case .off:
            return nil
        }
        if let engine = syncEngine, engine.key == key { return engine.sync }
        guard let store else { return nil }
        let sync = CloudSync(paths: paths, store: store)
        syncEngine = (key, sync)
        return sync
    }

    /// The server's copy of the meetings while iCloud syncs: only pushes, so the MCP has the meetings.
    private var mirrorSync: CloudSync? {
        guard syncWith == .icloud, let c = serverConnection else { return nil }
        let key = c.address.absoluteString
        if let m = mirrorEngine, m.key == key { return m.sync }
        let sync = CloudSync(paths: paths, store: ServerStore(c))
        mirrorEngine = (key, sync)
        return sync
    }

    /// The key of the last digest whose every part arrived at the server, this launch (`DigestPlan`).
    static var digestSent: String?

    /// What the server's MCP was told, this launch: a send that failed is tried again at the next sync.
    static var serverConfig = ServerConfigState()

    /// The coach's reads of people go to other AI apps through the owner's server by the same switch as `--mcp`.
    var personasInServerMCP: Bool { MCPServer.showsPersonas(coachEnabled: coachEnabled, personaEnabled: personaEnabled, personaInMCP: personaInMCP) }

    /// Uploads new and changed meetings and pulls what the iPhone changed. One sync at a time; a sync asked for
    /// during one runs again after it.
    func syncNow() {
        guard !isInert, !AppIdentity.current.isPreview else { return }
        let mirror = mirrorSync
        let main = currentSync
        // No store to pull from: a file that was set aside has no other copy to wait for.
        if main == nil { CloudSync.nothingToMerge(paths: paths) }
        // The config again when the owner's name or the switch of the reads for other AI apps changed.
        let config = "\(ownerName)|\(personasInServerMCP)"
        // Also with sync off: a connected server must hear that the reads went off.
        if Self.serverConfig.needsSend(config), let c = serverConnection {
            let first = !serverConfigSent
            serverConfigSent = true
            Self.serverConfig.sending(config)
            let owner = ownerName, personas = personasInServerMCP
            Task {
                do {
                    try await ServerClient(c).putConfig(owner: owner, personasInMCP: personas)
                    Self.serverConfig.arrived(config)
                } catch {
                    Self.serverConfig.failed()
                    Log.error("Telling your server the owner's name and the switch of the reads failed; it is tried again at the next sync: \(error)")
                }
            }
            // Once a launch: a server that was updated may keep recordings now.
            if first {
                let kept = serverKeepsRecordings
                refreshServerFacts { if self.serverKeepsRecordings != kept { self.syncCloud() } }
            }
        }
        guard let cloud = main ?? mirror else { return }
        if syncRunning { syncAgain = true; return }
        syncRunning = true
        syncActivity.running = true
        let place = syncWith == .server ? "your server" : "iCloud"
        // The reduced copy of the reads for the phone's card: shown traits and pointers, no words. None before the
        // reads were read once, so a sync at launch does not empty the phone's copy; an empty one when they are off.
        let personas: SyncedPersonas? = !personasOn ? SyncedPersonas([]) : personaReadsMade ? SyncedPersonas(Array(personaReads.values)) : nil
        let calling = isRecording
        let recorder = self.recorder, connection = serverConnection, owner = ownerName, personasHere = personasInServerMCP
        let serverIsMain = syncWith == .server
        // A call that starts during a long copy stops it at the next batch.
        let callStarted: @Sendable () -> Bool = { CaptureQueue.queue.sync { recorder.isRecording } }
        // The digest for the server's MCP (`ServerDigest`): only with a server, never during a call or before the
        // meetings are read, and made again only when the meetings, the coach, the tasks, the switch, or the day
        // changed since the last digest that arrived whole. Made after the meetings went, off the main thread.
        let digestKey = DigestPlan.key(meetings: meetingsVersion, coach: coachVersion, commitments: commitmentsVersion, personas: personasHere, day: Date())
        let makesDigest = DigestPlan.makes(server: serverConnection != nil, calling: calling, meetingsLoaded: meetingsLoaded, key: digestKey, sent: Self.digestSent)
        let digestRecords = makesDigest ? meetings : nil
        let digestDir = paths.sync, digestPaths = paths, facts = MeetingAnalyticsStore.shared.facts
        Task.detached(priority: .utility) {
            var digest: [SharedPayload]?
            var digestMade = false
            // From the app's own rules; a month is made again only when its meetings changed, and a call stops it.
            func makeDigest() -> [SharedPayload]? {
                guard let records = digestRecords, !digestMade else { return digest }
                digestMade = true
                let tools = ChatTools(records: records, owner: owner, paths: digestPaths, personaTraits: personasHere)
                digest = ServerDigest.parts(tools, personasInMCP: personasHere, cache: DigestCache(directory: digestDir), facts: facts, stop: callStarted)
                return digest
            }
            var received = 0
            var failure: FriendlyError?
            var waiting: [PendingRecording] = []
            if cloud !== mirror {
                do {
                    let changed = try await cloud.push()
                    received = try await cloud.pull(includeMeetings: false)
                    let shared = try await cloud.pushShared(people: true, personas: personas, stop: callStarted, digest: serverIsMain ? makeDigest() : nil)
                    if changed + shared > 0 { Log.info("Sync: \(changed + shared) changes sent to \(place)") }
                    // The server's tools read what time the Mac last sent everything: never the age of one record.
                    if serverIsMain, let connection { try? await ServerClient(connection).putConfig(owner: owner, personasInMCP: personasHere, syncedAt: Date()) }
                    if received > 0 { Log.info("Sync: \(received) changes from your other devices") }
                } catch {
                    failure = FriendlyError(error, context: .syncing, service: place)
                    Log.error("Sync with \(place) failed: \(error)")
                }
                waiting = (try? await cloud.recordingNotices()) ?? []
            }
            if let mirror {
                do {
                    let copied = try await mirror.push()
                    if copied > 0 { Log.info("Server: \(copied) meetings copied for ChatGPT and share links") }
                    // What the server's MCP reads besides the meetings, one way, by the same allowed-field lists:
                    // never during a call, when the disk and the network belong to the recording.
                    if !calling {
                        let shared = try await mirror.pushShared(people: true, personas: personas, mirror: true, stop: callStarted, digest: makeDigest())
                        if shared > 0 { Log.info("Server: \(shared) people, tasks, points, coach, and chat records copied") }
                        if !callStarted(), let connection {
                            try? await ServerClient(connection).putConfig(owner: owner, personasInMCP: personasHere, syncedAt: Date())
                        }
                    }
                } catch {
                    Log.error("Copying meetings to your server failed: \(error)")
                }
            }
            // The digest counts as sent only when every part arrived; else it is made again (mostly from its cache)
            // and sent at the next sync.
            let server = serverIsMain ? cloud : mirror
            var digestArrived = false
            if let digest, let server { digestArrived = (try? await server.holds(digest)) == true }
            await MainActor.run {
                if digestArrived { Self.digestSent = digestKey }
                // Chats, ratings, and memories from the phone show here at once.
                if received > 0 {
                    self.coachVersion += 1; self.chatsVersion += 1; self.commitmentsVersion += 1
                    // A commitment saved by a phone that does not know the ids gets its person's id back.
                    self.linkCommitmentPeople(self.library.identity?.people.people ?? [], records: self.meetings)
                    // A room recording from the iPhone is a new call to process, also while another call is
                    // processed: the pipeline takes each call once, and the hourly run would be a long wait.
                    self.processPending()
                }
                self.syncRunning = false
                // A sync the app stopped itself is neither a success nor a failure.
                var status = self.syncActivity.status
                if let failure { status.failed(failure) } else { status.succeeded() }
                // A phone recording that has not arrived for a day: said one time, here and as a notification.
                for p in waiting {
                    let text = Notifier.recordingText(p)
                    Log.error(text.title + ". " + text.body)
                    status.show(FriendlyError(reason: text.title + ". " + text.body, context: .syncing))
                    self.announceWaitingRecording(p)
                }
                self.announceSetAsideFiles()
                self.syncActivity = SyncActivity(running: false, last: failure == nil ? Date() : self.syncActivity.last, status: status)
                self.retryShareStops()
                if self.syncAgain {
                    self.syncAgain = false
                    self.syncNow()
                }
            }
        }
    }

    /// The recording on this Mac, or a copy from the cloud archive when the local one was removed.
    func recordingFile(_ r: CallRecord) async throws -> URL? {
        let local = Recording.url(in: paths.callDirectory(r.id))
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let remote = cloudArchive?.playbackURL(for: r) else { return nil }
        let (file, response) = try await URLSession.shared.download(from: remote)
        // An error page is not the recording: it must not go out as the audio of a share.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw ArchiveError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return file
    }

    func hasRecording(_ r: CallRecord) -> Bool {
        FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(r.id)).path) || r.cloudKey != nil
    }
}
