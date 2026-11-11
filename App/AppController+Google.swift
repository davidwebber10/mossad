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
