import AppKit
import MossadCore

/// The profiles in the app: the switch to another one, Add, Rename, and the server each profile owns. A process is
/// one profile from its first line to its last, so a switch starts a new instance and this one quits.
extension AppController {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var registryFile: URL { ProfileRegistry.fileURL(home: home) }
    static let unreadableProfiles = "The list of profiles could not be read. Mossad did not change it."

    /// This process's profile; in a preview, the made-up registry's active one.
    var activeProfile: Profile {
        AppIdentity.current.isPreview ? profiles.registry.activeProfile : AppIdentity.current.profile
    }

    /// The switcher's menu; nil with one profile.
    var profileMenu: ProfileMenu? { ProfileMenu(profiles.registry, active: activeProfile.id, recording: isRecording) }

    /// Only the real app changes the real registry: never a preview, an inert copy, or a run on a made-up registry.
    private var changesProfiles: Bool { !isInert && !AppIdentity.current.isPreview && !AppIdentity.current.madeUpRegistry }

    /// The file as it is now, read again before each change: another instance may have written it since launch.
    private func readProfiles() -> ProfileRegistry.Loaded {
        let read = ProfileRegistry.load(from: Self.registryFile, home: Self.home)
        profiles = read
        return read
    }

    func switchProfile(to id: String) {
        guard changesProfiles else { return }
        profileProblem = nil
        let read = readProfiles()
        switch ProfileSwitch.decide(to: id, registry: read, active: activeProfile.id, recording: isRecording, arguments: CommandLine.arguments) {
        case .stay: return
        case .refused(let why): profileProblem = why
        case .go(let save, let arguments):
            let was = read.registry.active
            if save {
                var next = read
                next.registry.setActive(id)
                do { try next.save(to: Self.registryFile) } catch {
                    Log.error("Profiles: the switch could not save the list: \(error)")
                    profileProblem = Self.unreadableProfiles
                    return
                }
            }
            startInstance(arguments: arguments, saved: save, was: was)
        }
    }

    /// Starts the new instance as `restartAsWorkingCopy` does, and quits only with proof of a new process.
    private func startInstance(arguments: [String], saved: Bool, was: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = arguments
        config.environment = ProcessInfo.processInfo.environment
        Log.info("Profiles: switching")
        Task {
            var started = false
            do {
                let app = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
                started = app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated
            } catch {
                Log.error("Profiles: the new instance did not start: \(error)")
            }
            switch ProfileSwitch.afterStart(started: started, saved: saved, was: was) {
            case .quit:
                NSApp.terminate(nil)
            case .restore(let active):
                var back = readProfiles()
                back.registry.setActive(active)
                if back.canSave { try? back.save(to: Self.registryFile) }
                profiles = readProfiles()
                profileProblem = "Could not switch. Mossad stays in \(activeProfile.name)."
            case .stay:
                profileProblem = "Could not switch. Mossad stays in \(activeProfile.name)."
            }
        }
    }

    func addProfile(name: String, color: ProfileColor) {
        guard changesProfiles else { return }
        profileProblem = nil
        if isRecording { profileProblem = ProfileSwitch.addRefusal; return }
        let read = readProfiles()
        guard read.canSave else { profileProblem = Self.unreadableProfiles; return }
        if let problem = ProfileRules.nameProblem(name, in: read.registry) { profileProblem = problem; return }
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: Self.home.path)) ?? []).map { $0.lowercased() })
        var next = read
        let profile = next.registry.add(name: name, color: color, takenFolders: taken)
        do {
            try FileManager.default.createDirectory(at: profile.rootURL(home: Self.home), withIntermediateDirectories: false)
        } catch {
            Log.error("Profiles: the folder of a new profile could not be made: \(error)")
            profileProblem = "The folder for this profile could not be made."
            return
        }
        // The first file of the Mac: this profile's server is named in it from the start.
        if let address = serverConnection?.address { next.registry.setServer(ProfileRules.serverHash(address), for: activeProfile.id) }
        do { try next.save(to: Self.registryFile) } catch {
            Log.error("Profiles: the list could not be saved: \(error)")
            profileProblem = Self.unreadableProfiles
            return
        }
        Log.info("Profiles: added one")
        // The first file of the Mac: this copy started with no Mac-wide lock. It takes it now, so the new instance
        // waits for it to quit, as after every later switch.
        if foregroundLock == nil, case .held(let lock) = InstanceLock.acquire(root: ProfileRegistry.folder(home: Self.home)) {
            foregroundLock = lock
        }
        switchProfile(to: profile.id)
    }

    func renameProfile(_ id: String, name: String, color: ProfileColor) {
        guard changesProfiles else { return }
        profileProblem = nil
        let read = readProfiles()
        guard read.canSave else { profileProblem = Self.unreadableProfiles; return }
        if let problem = ProfileRules.nameProblem(name, in: read.registry, renaming: id) { profileProblem = problem; return }
        var next = read
        next.registry.rename(id, name: name, color: color)
        do { try next.save(to: Self.registryFile) } catch {
            Log.error("Profiles: the list could not be saved: \(error)")
            profileProblem = Self.unreadableProfiles
            return
        }
        profiles = readProfiles()
    }

    /// Another profile of this Mac that already uses this server, or nil.
    func serverOwner(of address: URL) -> Profile? {
        ProfileRules.serverOwner(of: address, in: profiles.registry, except: activeProfile.id)
    }

    /// This profile's server in the registry, as a hash. Only when a registry file exists and the hash changed.
    func noteServer(_ address: URL?) {
        guard changesProfiles else { return }
        let read = readProfiles()
        guard read.state != .none, read.canSave else { return }
        let hash = address.map(ProfileRules.serverHash)
        guard read.registry.profile(activeProfile.id)?.server != hash else { return }
        var next = read
        next.registry.setServer(hash, for: activeProfile.id)
        do { try next.save(to: Self.registryFile) } catch { Log.error("Profiles: the server could not be noted: \(error)") }
        profiles = readProfiles()
    }
}
