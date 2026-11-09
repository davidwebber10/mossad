import AppKit
import Foundation
import MossadCore
import Security

/// What the Sync & Server page shows about the last sync.
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
        guard let address = ServerConnection.address(from: serverAddress), let secret = keychain.get(.serverSecret) else { return nil }
        return ServerConnection(address: address, secret: secret)
    }

    /// Saves a checked server and makes it the sync store.
    func connectServer(_ c: ServerConnection, hello: ServerClient.Hello, syncThere: Bool) {
        serverMCP = hello.mcp?.absoluteString ?? ""
        serverHasChat = hello.chat
        do { try keychain.set(c.secret, for: .serverSecret) } catch { Log.error("Saving the server secret failed") }
        serverAddress = c.address.absoluteString
        if syncThere || syncWith == .off || !Self.hasICloud { syncWith = .server }
        syncEngine = nil
        mirrorEngine = nil
        updateSharedServer()
        let owner = ownerName
        Task { try? await ServerClient(c).putConfig(owner: owner) }
        syncNow()
    }

    /// Goes back to iCloud; the server and its data stay as they are.
    func disconnectServer() {
        keychain.delete(.serverSecret)
        serverAddress = ""
        serverMCP = ""
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

    /// Uploads new and changed meetings and pulls what the iPhone changed. One sync at a time; a sync asked for
    /// during one runs again after it.
    func syncNow() {
        guard !Rehearsal.isOn else { return }
        let mirror = mirrorSync
        guard let cloud = currentSync ?? mirror else { return }
        if syncRunning { syncAgain = true; return }
        if !serverConfigSent, let c = serverConnection {
            serverConfigSent = true
            let owner = ownerName
            Task { try? await ServerClient(c).putConfig(owner: owner) }
        }
        syncRunning = true
        syncActivity.running = true
        let place = syncWith == .server ? "your server" : "iCloud"
        Task.detached(priority: .utility) {
            var received = 0
            var failure: FriendlyError?
            if cloud !== mirror {
                do {
                    let changed = try await cloud.push()
                    received = try await cloud.pull(includeMeetings: false)
                    let shared = try await cloud.pushShared()
                    if changed + shared > 0 { Log.info("Sync: \(changed + shared) changes sent to \(place)") }
                    if received > 0 { Log.info("Sync: \(received) changes from your other devices") }
                } catch {
                    failure = FriendlyError(error, context: .syncing, service: place)
                    Log.error("Sync with \(place) failed: \(error)")
                }
            }
            if let mirror {
                do {
                    let copied = try await mirror.push()
                    if copied > 0 { Log.info("Server: \(copied) meetings copied for ChatGPT and share links") }
                } catch {
                    Log.error("Copying meetings to your server failed: \(error)")
                }
            }
            await MainActor.run {
                // Chats, ratings, and memories from the phone show here at once.
                if received > 0 {
                    self.coachVersion += 1; self.chatsVersion += 1; self.commitmentsVersion += 1
                    // A room recording from the iPhone is a new call to process.
                    if self.processing == 0 { self.processPending() }
                }
                self.syncRunning = false
                // A sync the app stopped itself is neither a success nor a failure.
                var status = self.syncActivity.status
                if let failure { status.failed(failure) } else { status.succeeded() }
                self.syncActivity = SyncActivity(running: false, last: failure == nil ? Date() : self.syncActivity.last, status: status)
                if self.syncAgain {
                    self.syncAgain = false
                    self.syncNow()
                }
            }
        }
    }

    // MARK: Share links

    /// Makes or updates the link for a meeting with these options, and returns it.
    func share(_ record: CallRecord, options: ShareOptions, existing: MeetingLink?) async throws -> MeetingLink {
        guard let c = serverConnection else { throw ServerError.wrongSecret }
        let now = Date()
        var link = existing ?? MeetingLink(token: MeetingLink.newToken(), callID: record.id, title: record.title, options: options, created: now)
        link.options = options
        link.title = record.title
        link.expires = options.days.map { (existing?.created ?? now).addingTimeInterval(Double($0) * 86_400) }
        let model = aiProvider == .anthropic ? aiProvider.resolvedModel(aiModel) : nil
        let meeting = SharedMeeting(MeetingView(record), owner: ownerName, options: options, expires: link.expires, model: model)
        let audio = options.recording ? try await recordingFile(record) : nil
        try await ServerClient(c).putShare(link, meeting: meeting, audio: audio)
        shareBook.put(link)
        saveShares()
        return link
    }

    func stopSharing(_ link: MeetingLink) async throws {
        if let c = serverConnection { try await ServerClient(c).deleteShare(link) }
        shareBook.remove(link.token)
        saveShares()
    }

    func shareURL(_ link: MeetingLink) -> URL? { serverConnection.map { link.url(on: $0.address) } }

    private func saveShares() {
        do { try shareBook.save(to: paths.shares) } catch { Log.error("Saving share links failed: \(error)") }
    }

    /// The recording on this Mac, or a copy from the cloud archive when the local one was removed.
    private func recordingFile(_ r: CallRecord) async throws -> URL? {
        let local = Recording.url(in: paths.callDirectory(r.id))
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let remote = cloudArchive?.playbackURL(for: r) else { return nil }
        let (file, _) = try await URLSession.shared.download(from: remote)
        return file
    }

    func hasRecording(_ r: CallRecord) -> Bool {
        FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory(r.id)).path) || r.cloudKey != nil
    }
}
