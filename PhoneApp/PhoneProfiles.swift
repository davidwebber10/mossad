import Foundation
import MossadCore
import SwiftUI

/// The app's one object for its profiles: the phone's list, one uploader for each profile for the app's life, the
/// one room recorder, the inbox of shared files, and the store of the profile that shows. A switch closes the old
/// store before the new one is built. With no `profiles` item and no code, this is the first profile alone, with
/// the folder, Keychain service, settings, zone, and outbox of before, and nothing new is saved.
@Observable
@MainActor
final class PhoneProfiles {
    static let shared = PhoneProfiles()

    private(set) var book: PhoneProfileBook
    /// The profile that shows.
    private(set) var store: PhoneStore
    /// The app's one recorder: a switch cannot leave a second one.
    let recorder = RoomRecorder()
    /// An audio file that iOS handed over from the share sheet, shown in the import screen until it closes.
    var incomingAudio: IncomingAudio? = PhoneStore.hook("MOSSAD_IMPORT_AFTER") == nil
        ? PhoneStore.hook("MOSSAD_IMPORT").map { IncomingAudio(url: URL(fileURLWithPath: $0)) } : nil
    /// The last refusal of a switch.
    var problem: String?

    @ObservationIgnored private let uploaders: ProfileUploaders
    /// A switch the recorder held back: tried again at the next refresh.
    @ObservationIgnored private var switching = false

    /// `MOSSAD_ROOT` points the simulator at a sample folder: nothing syncs and the Keychain item is not read.
    private static var offline: Bool { ProcessInfo.processInfo.environment["MOSSAD_ROOT"] != nil }

    private init() {
        var book = PhoneProfileBook.load(.standard)
        #if DEBUG
        // `MOSSAD_PHONE_PROFILES=<file>` is the item's JSON in place of the Keychain read, and `MOSSAD_PHONE_PROFILE=<id>`
        // the active profile, both only with `MOSSAD_ROOT`.
        if let path = PhoneStore.hook("MOSSAD_PHONE_PROFILES"), let data = FileManager.default.contents(atPath: path),
           let item = ProfilesItem.decode(data) {
            book.take(.found(item), now: Date())
        }
        if let id = PhoneStore.hook("MOSSAD_PHONE_PROFILE") { book.active = id == Profile.defaultID ? nil : id }
        // Kept for the next launch, so a list that drops a profile shows it as one that left.
        if PhoneStore.hook("MOSSAD_PHONE_PROFILES") != nil { book.save(to: .standard) }
        #endif
        let uploaders = ProfileUploaders(make: Self.makeUploader)
        for profile in book.listed + book.leaving {
            let u = uploaders.uploader(for: profile)
            u?.sends = profile.gone == nil
        }
        // The first profile always opens: its settings are the standard ones.
        let active = book.activeProfile
        let uploader = uploaders.uploader(for: active) ?? uploaders.uploader(for: book.listed[0])!
        self.book = book
        self.uploaders = uploaders
        store = PhoneStore(context: uploader.context, uploader: uploader, recorder: recorder)
        store.inProfiles = book.showsProfiles
        // Every profile's outbox is read at launch, so the Profile screen and the passes see its recordings.
        Task { for u in uploaders.all { await u.ready() } }
        #if DEBUG
        // `MOSSAD_IMPORT_AFTER=<seconds>` hands the `MOSSAD_IMPORT` file over later, as a share while a sheet is open.
        if let after = PhoneStore.hook("MOSSAD_IMPORT_AFTER").flatMap(Double.init), let path = PhoneStore.hook("MOSSAD_IMPORT") {
            Task {
                try? await Task.sleep(for: .seconds(after))
                incomingAudio = IncomingAudio(url: URL(fileURLWithPath: path))
            }
        }
        #endif
        clearOldInbox()
    }

    /// A profile's uploader from its id alone. Nil when its settings cannot be made: it never gets the first one's.
    private static func makeUploader(_ profile: PhoneProfile) -> ProfileUploader? {
        guard let context = PhoneProfileContext(id: profile.id) else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let settings = context.settings(standard: .standard, makeSuite: { UserDefaults(suiteName: $0) }) else {
            Log.error("Profiles: the settings of a profile could not be made")
            return nil
        }
        return ProfileUploader(context: context, paths: context.paths(documents: URL.documentsDirectory, environment: environment),
                               settings: settings, listed: profile.sync, offline: offline, parts: .live(context),
                               background: { name in
                                   let time = BackgroundTime(name)
                                   return { time.end() }
                               })
    }

    func uploader(for profile: PhoneProfile) -> ProfileUploader? { uploaders.uploader(for: profile) }

    /// Any profile has a recording that waits: the app looks now and then while it is open.
    var waits: Bool {
        store.waitsForTheMac || uploaders.all.contains { $0 !== store.uploader && $0.waits(active: nil) }
    }

    /// Reads the Mac's item off the main actor and takes it: renames, new profiles, gone ones. A folder of a gone
    /// profile goes only by `PhoneProfileBook.cleanup`.
    func refresh() async {
        guard !Self.offline else { return }
        let read = await Task.detached(priority: .utility) { ProfilesItem.read() }.value
        book.take(read, now: Date())
        book.save(to: .standard)
        for profile in book.listed {
            let u = uploaders.uploader(for: profile)
            u?.listed = profile.sync
            u?.sends = true
        }
        for profile in book.leaving { uploaders.uploader(for: profile)?.sends = false }
        for u in uploaders.all { await u.ready() }
        store.inProfiles = book.showsProfiles
        if book.activeProfile.id != store.context.id { await switchTo(book.activeProfile.id) }
        await cleanUp()
    }

    /// Removes the folder of a profile that left, only by the rule: a week gone, nothing waiting, nothing running.
    func cleanUp() async {
        let now = Date(), environment = ProcessInfo.processInfo.environment, documents = URL.documentsDirectory
        for profile in book.leaving {
            guard let context = PhoneProfileContext(id: profile.id) else { continue }
            let u = uploaders.uploader(for: profile)
            let dir = context.paths(documents: documents, environment: environment).root.appendingPathComponent("Recordings")
            let audio = await Task.detached(priority: .utility) { RoomAudio.ids(in: dir)?.count }.value
            let busy = u.map { $0.isImporting || !$0.uploading.isEmpty || !$0.joining.isEmpty } ?? false
            guard PhoneProfileBook.cleanup(profile, outbox: u?.outbox.entries.count, audio: audio, busy: busy, now: now) == .remove else { continue }
            let root = context.root(documents: documents, environment: environment)
            guard context.mayRemove(root, documents: documents, environment: environment), context.id != store.context.id else { continue }
            let removed = await Task.detached(priority: .utility) { () -> Bool in
                (try? FileManager.default.removeItem(at: root)) != nil || !FileManager.default.fileExists(atPath: root.path)
            }.value
            guard removed else { continue }
            if let suite = context.settingsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
            Keychain(service: context.keychainService).delete(.serverSecret)
            uploaders.drop(profile.id)
            book.forget(profile.id)
            book.save(to: .standard)
            Log.info("Profiles: the folder of a profile that left was removed")
        }
    }

    /// The switch: refused while the recorder runs or an import is added; else the old store closes, the choice is
    /// saved, and the new store is built on that profile's own uploader.
    func switchTo(_ id: String) async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        let decision = PhoneProfileSwitch.decide(to: id, book: book, active: store.context.id,
                                                 recording: recorder.busy || store.recorderScreenOpen,
                                                 importing: uploaders.all.contains(where: \.isImporting))
        switch decision {
        case .stay: return
        case .refused(let why): problem = why
        case .go(let next):
            guard let profile = book.listed.first(where: { $0.id == next }), let uploader = uploaders.uploader(for: profile) else {
                problem = PhoneProfileWords.cannotOpen
                return
            }
            problem = nil
            await store.close()
            book.active = next == Profile.defaultID ? nil : next
            book.save(to: .standard)
            store = PhoneStore(context: uploader.context, uploader: uploader, recorder: recorder)
            store.inProfiles = book.showsProfiles
            Task { await pass() }
        }
    }

    /// The store's sync, then a pass of every other profile that has something to send.
    func pass() async {
        await store.sync()
        for u in uploaders.all where u !== store.uploader { await u.pass() }
    }

    /// The recordings that wait in profiles the Mac no longer has, by profile, for Meetings and Settings.
    var leavingWithRecordings: [(profile: PhoneProfile, uploader: ProfileUploader)] {
        book.leaving.compactMap { p in uploaders.uploader(for: p).flatMap { $0.outbox.entries.isEmpty ? nil : (p, $0) } }
    }

    /// A scanned code: an old server code connects the first profile; a profile code adds that profile (or changes
    /// it), and with a server its secret goes only to that profile's own Keychain service. The code is never stored
    /// or logged. Returns the words of what it did, or why not.
    /// What a scanned code did, in words, or why not.
    enum Applied { case done(String), failed(FriendlyError) }

    func apply(_ parsed: ProfileCode.Parsed) async -> Applied {
        switch parsed {
        case .notMossad, .damaged, .newer:
            return .failed(Self.problem(parsed.problem ?? PhoneProfileWords.cannotOpen))
        case .server(let c):
            if let problem = await Self.check(c) { return .failed(problem) }
            let first = book.listed[0]
            guard let u = uploaders.uploader(for: first) else { return .failed(Self.problem(PhoneProfileWords.cannotOpen)) }
            u.connect(c)
            return .done(PhoneProfileWords.connected(name: first.name, host: c.address.host ?? c.address.absoluteString))
        case .profile(let code):
            if let c = code.connection, let problem = await Self.check(c) { return .failed(problem) }
            book.add(code, now: Date())
            book.save(to: .standard)
            guard let profile = book.listed.first(where: { $0.id == code.id }), let u = uploaders.uploader(for: profile) else {
                return .failed(Self.problem(PhoneProfileWords.cannotOpen))
            }
            u.sends = true
            u.listed = profile.sync
            store.inProfiles = book.showsProfiles
            if let c = code.connection {
                u.connect(c)
                return .done(PhoneProfileWords.connected(name: profile.name, host: c.address.host ?? c.address.absoluteString))
            }
            u.choose(.icloud)
            return .done(PhoneProfileWords.added(profile.name))
        }
    }

    /// The owner's "Remove from this iPhone" of a profile from a code. Its folder goes by the cleanup rule.
    func remove(_ id: String) {
        book.removeFromPhone(id, now: Date())
        book.save(to: .standard)
        if let gone = book.leaving.first(where: { $0.id == id }) { uploaders.uploader(for: gone)?.sends = false }
        store.inProfiles = book.showsProfiles
        Task { await cleanUp() }
    }

    /// The server answers and takes the secret, as the screen that connects a server checks it.
    private static func check(_ c: ServerConnection) async -> FriendlyError? {
        do {
            let hello = try await ServerClient(c).hello()
            return hello.authorized ? nil : FriendlyError(kind: .wrongSecret, context: .connectingServer)
        } catch {
            Log.error("Checking the server failed: \(error)")
            return FriendlyError(error, context: .connectingServer, service: "your server")
        }
    }

    private static func problem(_ sentence: String) -> FriendlyError {
        FriendlyError(kind: .other, context: .connectingServer, said: sentence, retries: false)
    }

    func remember(importTarget id: String) {
        book.importTarget = id == Profile.defaultID ? nil : id
        book.save(to: .standard)
    }

    /// Deletes the app's own copy of a handed file. A file outside the app's folders is never touched.
    func discardIncoming(_ url: URL) {
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Files that iOS handed over and the app never took, by `CallImport.clearsFromInbox`: added a day ago or more,
    /// and not the file the screen shows or an import of any profile reads.
    func clearOldInbox() {
        let reading = uploaders.all.flatMap(\.importing)
        let inUse = Set([incomingAudio?.url.standardizedFileURL.path].compactMap { $0 } + reading.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
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
}
