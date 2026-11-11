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

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "googleScopes")
        scopes = saved.map { Set($0.compactMap(GoogleScope.init(rawValue:))) } ?? Set(GoogleScope.allCases)
        audience = UserDefaults.standard.string(forKey: "googleAudience").flatMap(GoogleSetupGuide.Audience.init(rawValue:)) ?? .internal
        // Development hook for screenshots: MOSSAD_GOOGLE_SAMPLE shows a passed check with made-up values.
        if ProcessInfo.processInfo.environment["MOSSAD_GOOGLE_SAMPLE"] != nil {
            phase = .done(GoogleCheck.Report(account: "owner@example.com", event: "Weekly design review",
                                             parts: [.calendar: GoogleError?.none, .docs: GoogleError?.none,
                                                                     .directory: GoogleError?.some(.apiDisabled(.people)), .contacts: GoogleError?.none]))
        }
    }

    var busy: Bool { phase == .signingIn || phase == .checking }

    /// The line about the plan, with its cost and the cap, as the step shows it and the log keeps it.
    var pastLine: String? { pastPlan.map { GeminiImport.estimateLine($0, cap: pastCap) } }

    func changed() { version += 1 }
}

extension AppController {
    var googleConnected: Bool {
        _ = googleConnector.version
        return ProcessInfo.processInfo.environment["MOSSAD_GOOGLE_SAMPLE"] != nil || google.isConnected
    }

    var googleAccount: String? {
        _ = googleConnector.version
        return ProcessInfo.processInfo.environment["MOSSAD_GOOGLE_SAMPLE"] != nil ? "owner@example.com" : google.account
    }

    /// Saves a typed client, signs in when the parts changed or no sign-in is saved, then reads one event and one of
    /// each other part. Never in a preview: it would reach Google.
    func checkGoogle(typedID: String? = nil, typedSecret: String? = nil) {
        let connector = googleConnector
        guard !connector.busy else { return }
        guard !CommandLine.arguments.contains("--ui-preview") else { return }
        let id = typedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = typedSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !id.isEmpty || !secret.isEmpty {
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
        Task {
            do {
                if !session.isConnected || session.scopes != scopes {
                    // Fewer parts than before: the old grant ends first, so Google forgets the parts turned off.
                    if session.isConnected { await session.signOut() }
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
            } catch {
                let g = GoogleError.from(error)
                Log.error("Google: the sign-in failed (\(g.logText))")
                connector.phase = .failed(g)
            }
            connector.changed()
            googleChanged()
        }
    }

    func signOutOfGoogle() {
        let session = google
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
        Task.detached(priority: .utility) {
            guard let profiles = await GooglePeopleAPI.fetch(session: session) else { return }
            let cache = GoogleDirectoryCache(profiles: profiles, read: Date())
            do { try cache.save(paths) } catch { Log.error("Google People: the directory copy was not saved: \(error)") }
            names.set(cache.names)
            var changed = 0
            if let store = library.identity?.people {
                do { changed = try store.applyDirectory(profiles) } catch { Log.error("Google People: the people were not filled: \(error)") }
            }
            Log.info("Google People: read \(profiles.count) entries; \(changed) people filled")
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
        Task {
            defer { googleRunning = false }
            let now = Date()
            guard let events = await runner.events(from: now.addingTimeInterval(-GeminiImport.recentWindow), to: now) else { return }
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "geminiLastCheck")
            let items = GeminiImport.plan(events: events, records: meetings, now: now)
            guard !items.isEmpty, !isRecording else { return }
            let outcome = await runner.run(items, ownerName: owner, ownerNames: ownerNames)
            Log.info("Gemini notes: \(outcome.made) made, \(outcome.attached) added to recordings, \(outcome.failed) to try again")
            refresh()
        }
    }

    /// Finds the past meetings with notes in the chosen days, and says what an import would cost.
    func findPastNotes() {
        let connector = googleConnector
        guard !isInert, google.has(.calendar), google.has(.docs), !connector.pastSearching, let pipeline else { return }
        connector.pastSearching = true
        connector.pastResult = nil
        let runner = GeminiRunner(session: google, pipeline: pipeline, paths: paths), days = connector.pastDays
        Task {
            let now = Date()
            let events = await runner.events(from: now.addingTimeInterval(-Double(days) * 86_400), to: now)
            connector.pastSearching = false
            guard let events else {
                connector.pastResult = "Mossad could not read your Google calendar. Press Check above."
                return
            }
            connector.pastPlan = GeminiImport.plan(events: events, records: meetings, now: now)
            if let line = connector.pastLine { Log.info("Gemini notes, last \(days) days: \(line)") }
        }
    }

    /// Imports the plan within the cap, the newest first, one meeting at a time. Not while a call records.
    func importPastNotes() {
        let connector = googleConnector
        guard let plan = connector.pastPlan, connector.pastImport == nil, !isRecording, let pipeline else { return }
        let items = GeminiImport.capped(plan, dollars: connector.pastCap)
        guard !items.isEmpty else { return }
        Log.info("Gemini notes: importing \(items.count) of \(plan.count), about \(String(format: "$%.2f", GeminiImport.estimate(items)))")
        let runner = GeminiRunner(session: google, pipeline: pipeline, paths: paths)
        let owner = ownerName, ownerNames = library.identity?.people.ownerNames ?? []
        connector.pastImport = (0, items.count)
        Task {
            var total = GeminiRunner.Outcome()
            for (i, item) in items.enumerated() {
                // A call that starts waits for nothing: the rest goes on after it.
                while isRecording { try? await Task.sleep(for: .seconds(30)) }
                let o = await runner.run([item], ownerName: owner, ownerNames: ownerNames)
                total.made += o.made
                total.attached += o.attached
                total.failed += o.failed
                connector.pastImport = (i + 1, items.count)
                refresh()
            }
            connector.pastImport = nil
            connector.pastPlan = nil
            connector.pastResult = "Imported \(total.made) \(total.made == 1 ? "meeting" : "meetings") and added notes to \(total.attached) recorded."
                + (total.failed > 0 ? " \(total.failed) could not be read now." : "")
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
