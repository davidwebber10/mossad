import AppKit
import MossadCore
import SwiftUI

/// The Google step's state: the parts the owner chose, who signs in, and the last Check. One for the app, so
/// setup and Settings show the same.
@MainActor
final class GoogleConnector: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Google's page is open in the browser.
        case signingIn
        case checking
        case done(GoogleCheck.Report)
        case failed(GoogleError)
    }

    @Published var phase: Phase = .idle
    /// The parts to ask for. All four to start; the owner turns each off here.
    @Published var scopes: Set<GoogleScope> {
        didSet { UserDefaults.standard.set(GoogleScope.allCases.filter(scopes.contains).map(\.rawValue), forKey: "googleScopes") }
    }
    @Published var audience: GoogleSetupGuide.Audience {
        didSet { UserDefaults.standard.set(audience.rawValue, forKey: "googleAudience") }
    }
    /// Counts sign-ins and sign-outs, so views read the session again.
    @Published private(set) var version = 0
    /// Old notes: how far back to look, the plan that was found, its cap in dollars, and the import's progress.
    @Published var pastDays = 90
    @Published var pastPlan: [GeminiImport.Item]?
    @Published var pastCap = 2.0
    @Published var pastSearching = false
    @Published var pastImport: (done: Int, total: Int)?
    @Published var pastResult: String?
    /// False when the calendar read for old notes stopped at its limit.
    @Published var pastComplete = true
    /// What the chosen notes model costs for an hour of meeting; nil when its price is not known.
    @Published var pastPerHour: Double?
    /// The sign-in that waits for the browser, for Cancel.
    var signIn: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "googleScopes")
        scopes = saved.map { Set($0.compactMap(GoogleScope.init(rawValue:))) } ?? Set(GoogleScope.allCases)
        audience = UserDefaults.standard.string(forKey: "googleAudience").flatMap(GoogleSetupGuide.Audience.init(rawValue:)) ?? .internal
        // Development hook for screenshots: MOSSAD_GOOGLE_SAMPLE shows a passed check with made-up values, and
        // MOSSAD_GOOGLE_SAMPLE=off shows no client and no sign-in.
        if Self.sample {
            phase = .done(GoogleCheck.Report(account: "owner@example.com", event: "Weekly design review",
                                             parts: [.calendar: GoogleError?.none, .docs: GoogleError?.none,
                                                                     .directory: GoogleError?.some(.apiDisabled(.people)), .contacts: GoogleError?.none]))
        }
    }

    var busy: Bool { phase == .signingIn || phase == .checking }

    /// The screenshot hook, in a Debug build only: a release build never shows a made-up account.
    private static var sampleValue: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["MOSSAD_GOOGLE_SAMPLE"]
        #else
        nil
        #endif
    }

    static var sample: Bool { sampleValue.map { $0 != "off" } ?? false }
    static var sampleOff: Bool { sampleValue == "off" }

    /// The line about the plan, with its cost and the cap, as the step shows it and the log keeps it.
    var pastLine: String? { pastPlan.map { GeminiImport.estimateLine($0, cap: pastCap, perHour: pastPerHour, complete: pastComplete) } }

    func changed() { version += 1 }
}

extension AppController {
    var googleConnected: Bool {
        _ = googleConnector.version
        if GoogleConnector.sampleOff { return false }
        return GoogleConnector.sample || google.isConnected
    }

    /// The client ID and the secret are both in the Keychain.
    var googleClientSaved: Bool {
        if GoogleConnector.sample { return true }
        if GoogleConnector.sampleOff { return false }
        return hasKey(.googleClientID) && hasKey(.googleClientSecret)
    }

    var googleAccount: String? {
        _ = googleConnector.version
        if GoogleConnector.sampleOff { return nil }
        return GoogleConnector.sample ? "owner@example.com" : google.account
    }

    /// Saves a typed client, signs in when the parts changed or no sign-in is saved, then reads one event and one of
    /// each other part. Never in a preview: it would reach Google.
    func checkGoogle(typedID: String? = nil, typedSecret: String? = nil) {
        let connector = googleConnector
        guard !connector.busy else { return }
        guard !CommandLine.arguments.contains("--ui-preview") else { return }
        let id = typedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = typedSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A new client cannot use the old client's sign-in: it signs in again.
        var newClient = false
        if !id.isEmpty || !secret.isEmpty {
            newClient = keychain.client?.id != id
            guard GoogleClient.looksLikeID(id), !secret.isEmpty else {
                connector.phase = .failed(id.isEmpty || secret.isEmpty ? .noClient : .invalidClient)
                return
            }
            do { try keychain.setClient(GoogleClient(id: id, secret: secret)) } catch {
                Log.error("Saving the Google client failed")
                connector.phase = .failed(.unexpectedAnswer)
                return
            }
            keysChanged()
        }
        guard let client = keychain.client else {
            connector.phase = .failed(.noClient)
            return
        }
        let scopes = connector.scopes, session = google
        connector.signIn = Task {
            do {
                if newClient, session.isConnected {
                    await session.signOut()
                    forgetDirectory([.directory, .contacts])
                }
                if !session.isConnected || session.scopes != scopes {
                    // Fewer parts than before: the old grant ends first, so Google forgets the parts turned off.
                    if session.isConnected {
                        await session.signOut()
                        forgetDirectory([.directory, .contacts])
                    }
                    connector.phase = .signingIn
                    _ = try await GoogleSignIn.run(client: client, scopes: scopes, session: session, loginHint: session.account) { url in
                        await MainActor.run { _ = NSWorkspace.shared.open(url) }
                    }
                    NSApp.activate()
                    connector.changed()
                }
                connector.phase = .checking
                let report = await GoogleCheck.run(session: session, scopes: scopes)
                connector.phase = .done(report)
                Log.info("Google: checked \(scopes.count) parts, \(report.passed ? "all work" : "some need you")")
            } catch is CancellationError {
                Log.info("Google: the sign-in was cancelled")
                connector.phase = .idle
            } catch {
                let g = GoogleError.from(error)
                Log.error("Google: the sign-in failed (\(g.logText))")
                connector.phase = .failed(g)
            }
            connector.signIn = nil
            connector.changed()
            googleChanged()
        }
    }

    /// Cancel while Google's page is open: the wait ends, and Check can open the page again.
    func cancelGoogleSignIn() {
        googleConnector.signIn?.cancel()
    }

    /// The parts on now: the session stops a part turned off at once, and its directory data goes.
    func googlePartsChanged(from old: Set<GoogleScope>) {
        let now = googleConnector.scopes
        google.choose(now)
        var gone: Set<GoogleProfile.Source> = []
        if old.contains(.directory), !now.contains(.directory) { gone.insert(.directory) }
        if old.contains(.contacts), !now.contains(.contacts) { gone.insert(.contacts) }
        if !gone.isEmpty { forgetDirectory(gone) }
    }

    /// Removes what the directory or the contacts gave: the copy on this Mac and the details on each person.
    func forgetDirectory(_ sources: Set<GoogleProfile.Source>) {
        let paths = paths, library = library, names = googleNames
        Task.detached(priority: .utility) {
            if let cache = GoogleDirectoryCache.load(paths) {
                let kept = GoogleDirectoryCache(profiles: cache.profiles.filter { !sources.contains($0.source) }, read: cache.read)
                if kept.profiles.isEmpty { GoogleDirectoryCache.remove(paths) } else { try? kept.save(paths) }
                names.set(kept.names)
            }
            if let store = library.identity?.people {
                do { try store.clearDirectory(sources) } catch { Log.error("Google People: the details were not removed: \(error)") }
            }
            Log.info("Google People: removed what \(sources.map(\.rawValue).sorted().joined(separator: " and ")) gave")
            await MainActor.run { UserDefaults.standard.removeObject(forKey: "googleDirectoryRead") }
        }
    }

    func signOutOfGoogle() {
        let session = google
        googleConnector.signIn?.cancel()
        forgetDirectory([.directory, .contacts])
        Task {
            await session.signOut()
            Log.info("Google: signed out")
            googleConnector.phase = .idle
            googleConnector.changed()
            googleChanged()
        }
    }

    /// Forgets the client too, for a new Google app.
    func forgetGoogleClient() {
        keychain.delete(.googleClientID)
        keychain.delete(.googleClientSecret)
        keysChanged()
        signOutOfGoogle()
    }

    /// The calendar reads Google again, and the people and notes follow the new sign-in.
    func googleChanged() {
        calendar.forget()
        refreshUpcoming()
        refreshGoogleDirectory(force: true)
    }

    /// The org chart's "Name, Title" lines for the AI provider, then the directory's titles for the names it lacks.
    nonisolated static func titleLines(for names: [String], paths: Paths, library: VoiceLibrary) -> [String] {
        let org = OrgChart.contextLines(for: names, paths: paths)
        return org + DirectoryMerge.contextLines(for: names, people: library.identity?.people.people ?? [], except: org)
    }

    /// Reads the directory and the contacts, at most once a day unless forced, and fills the saved people by their
    /// addresses. Off the main thread; nothing in a preview, Rehearsal, or a second copy.
    func refreshGoogleDirectory(force: Bool = false) {
        guard !isInert, google.has(.directory) || google.has(.contacts) else { return }
        let last = UserDefaults.standard.double(forKey: "googleDirectoryRead")
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return }
        let session = google, paths = paths, library = library, names = googleNames
        let signIn = googleConnector.version
        Task.detached(priority: .utility) {
            let fresh = await GooglePeopleAPI.fetch(session: session)
            guard !fresh.isEmpty else { return }
            // A sign-out or a new sign-in during the read: its answer belongs to a grant that is gone.
            guard await MainActor.run(body: { self.googleConnector.version == signIn && session.isConnected }) else { return }
            // A part that was not read keeps its old copy; nothing is made from a part of a list.
            let cache = (GoogleDirectoryCache.load(paths) ?? GoogleDirectoryCache(profiles: [], read: Date())).replacing(fresh, read: Date())
            do { try cache.save(paths) } catch { Log.error("Google People: the directory copy was not saved: \(error)") }
            names.set(cache.names)
            var changed = 0
            if library.identity?.people != nil {
                do { changed = try library.applyDirectory(fresh.values.flatMap { $0 }) } catch { Log.error("Google People: the people were not filled: \(error)") }
            }
            Log.info("Google People: read \(fresh.values.map(\.count).reduce(0, +)) entries; \(changed) people filled")
            await MainActor.run {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "googleDirectoryRead")
                if changed > 0 { self.refreshPeopleReferences() }
            }
        }
    }

    // MARK: Gemini notes

    /// Every 15 minutes, for the last 2 days: the notes of meetings that ended become notes-only meetings, or the
    /// second source of a recorded one. Never while a call records; nothing without Calendar and Docs.
    func runGeminiCheck() {
        guard !isInert, google.has(.calendar), google.has(.docs), !googleRunning, let pipeline else { return }
        let lastSeconds = UserDefaults.standard.object(forKey: "geminiLastCheck") as? Double
        guard GeminiImport.isDue(last: lastSeconds.map(Date.init(timeIntervalSince1970:)), now: Date(), recording: isRecording) else { return }
        googleRunning = true
        let runner = GeminiRunner(session: google, pipeline: pipeline, paths: paths)
        let owner = ownerName, ownerNames = library.identity?.people.ownerNames ?? []
        let lastGood = (UserDefaults.standard.object(forKey: "geminiLastGood") as? Double).map(Date.init(timeIntervalSince1970:))
        Task {
            defer { googleRunning = false }
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "geminiLastCheck")
            // Back to the last good check, so a weekend with the Mac closed is not lost.
            guard let read = await runner.events(from: GeminiImport.windowStart(lastGood: lastGood, now: now), to: now) else { return }
            let gone = RemovedNotes.load(paths)
            let items = GeminiImport.plan(events: read.events, records: meetings, now: now, noRecord: noRecord, removed: gone.ids, deleted: gone.meetings)
            // The window moves on only after a complete read and a run with nothing left to do.
            func good() { if read.complete { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "geminiLastGood") } }
            guard !items.isEmpty else { return good() }
            let outcome = await runner.run(items, ownerName: owner, ownerNames: ownerNames, isLive: { await MainActor.run { self.isRecording } })
            if !outcome.stopped, outcome.failed == 0 { good() }
            Log.info("Gemini notes: \(outcome.made) made, \(outcome.attached) added to recordings, \(outcome.failed) to try again\(outcome.stopped ? ", stopped for a call" : "")")
            refresh()
        }
    }

    /// The chosen notes model's price for an hour of meeting: the summary and the tasks; nil when not known.
    var notesPerHour: Double? { GeminiImport.perHour(hourCost) }

    /// Finds the past meetings with notes in the chosen days, and says what an import would cost.
    func findPastNotes() {
        let connector = googleConnector
        guard !isInert, google.has(.calendar), google.has(.docs), !connector.pastSearching, let pipeline else { return }
        connector.pastSearching = true
        connector.pastResult = nil
        connector.pastPerHour = notesPerHour
        let runner = GeminiRunner(session: google, pipeline: pipeline, paths: paths), days = connector.pastDays
        Task {
            let now = Date()
            let read = await runner.events(from: now.addingTimeInterval(-Double(days) * 86_400), to: now)
            connector.pastSearching = false
            guard let read else {
                connector.pastResult = "Mossad could not read your Google calendar. Press Check above."
                return
            }
            connector.pastComplete = read.complete
            let gone = RemovedNotes.load(paths)
            connector.pastPlan = GeminiImport.plan(events: read.events, records: meetings, now: now, noRecord: noRecord, removed: gone.ids, deleted: gone.meetings)
            if let line = connector.pastLine { Log.info("Gemini notes, last \(days) days: \(line)") }
        }
    }

    /// Imports the plan within the cap, the newest first, one meeting at a time. It stops at the cap by what the
    /// imported meetings really cost, and waits while a call records. The background check does not run meanwhile.
    func importPastNotes() {
        let connector = googleConnector
        guard let plan = connector.pastPlan, connector.pastImport == nil, !googleRunning, !isRecording, let pipeline else { return }
        let cap = connector.pastCap
        let items = GeminiImport.capped(plan, dollars: cap, perHour: connector.pastPerHour)
        guard !items.isEmpty else { return }
        Log.info("Gemini notes: importing \(items.count) of \(plan.count), about \(String(format: "$%.2f", GeminiImport.estimate(items, perHour: connector.pastPerHour)))")
        googleRunning = true
        let runner = GeminiRunner(session: google, pipeline: pipeline, paths: paths)
        let owner = ownerName, ownerNames = library.identity?.people.ownerNames ?? [], usage = usage
        // What the imported meetings cost so far, from the usage log.
        let spent: @Sendable ([String]) -> Double = { ids in
            let set = Set(ids)
            return usage.all().filter { $0.callID.map(set.contains) == true }.map(Pricing.cost).reduce(0, +)
        }
        connector.pastImport = (0, items.count)
        Task {
            defer { googleRunning = false }
            var total = GeminiRunner.Outcome(), made: [String] = []
            for (i, item) in items.enumerated() {
                var o = GeminiRunner.Outcome(stopped: true)
                // A call that starts waits for nothing: the item goes on after it, and is not left out.
                while o.stopped {
                    while isRecording { try? await Task.sleep(for: .seconds(30)) }
                    let ids = made
                    let soFar = await Task.detached { spent(ids) }.value
                    o = await runner.run([item], ownerName: owner, ownerNames: ownerNames, isLive: { await MainActor.run { self.isRecording } },
                                         spent: { _ in soFar }, cap: cap)
                    if o.stopped, !isRecording { break }
                }
                refresh()
                made += o.madeIDs
                total.made += o.made
                total.attached += o.attached
                total.failed += o.failed
                connector.pastImport = (i + 1, items.count)
                if o.stopped, !isRecording { total.stopped = true; break }
            }
            connector.pastImport = nil
            connector.pastPlan = nil
            connector.pastResult = "Imported \(total.made) \(total.made == 1 ? "meeting" : "meetings") and added notes to \(total.attached) recorded."
                + (total.failed > 0 ? " \(total.failed) could not be read now." : "")
                + (total.stopped ? " The cap was reached." : "")
            Log.info("Gemini notes: \(connector.pastResult ?? "")")
        }
    }

    /// What Google's directory says about a saved person, by the name the page shows.
    func directoryDetails(of name: String) -> DirectoryDetails? {
        guard let id = personID(of: name) else { return nil }
        return library.identity?.people.person(PersonID(rawValue: id))?.directory
    }

    /// The last read's names, at launch.
    func loadGoogleNames() {
        let paths = paths, names = googleNames
        Task.detached(priority: .utility) { names.set(GoogleDirectoryCache.load(paths)?.names ?? [:]) }
    }
}

/// The directory's names, read by the calendar from any thread.
final class GoogleNameBook: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    var value: [String: String] { lock.withLock { names } }
    func set(_ new: [String: String]) { lock.withLock { names = new } }
}
