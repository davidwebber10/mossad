import AppKit
import MossadCore

/// The profiles in the app: the switch to another one, Add, Rename, and the server each profile owns. A process is
/// one profile from its first line to its last, so a switch starts a new instance and this one quits.
extension AppController {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var registryFile: URL { ProfileRegistry.fileURL(home: home) }
    static let unreadableProfiles = "The list of profiles could not be read. Mossad did not change it."

    /// This process's profile as the registry has it now (a rename shows at once); in a preview, the made-up
    /// registry's active one.
    var activeProfile: Profile {
        if AppIdentity.current.isPreview { return profiles.registry.activeProfile }
        return profiles.registry.profile(AppIdentity.current.profile.id) ?? AppIdentity.current.profile
    }

    /// The switcher's menu; nil with one profile.
    var profileMenu: ProfileMenu? { ProfileMenu(profiles.registry, active: activeProfile.id, recording: isRecording) }

    /// Only the real app changes the real registry: never a preview, an inert copy, or a run on a made-up registry.
    private var changesProfiles: Bool { !isInert && AppIdentity.current.mayChangeRegistry }

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
            var newInstance: NSRunningApplication?
            do {
                let app = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
                started = app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated
                if started { newInstance = app }
            } catch {
                Log.error("Profiles: the new instance did not start: \(error)")
            }
            switch ProfileSwitch.afterStart(started: started, saved: saved, was: was) {
            case .quit:
                // A call that started after the decision: the new instance goes, `active` comes back, no quit.
                if case .refused(let why) = ProfileSwitch.atQuit(recording: isRecording) {
                    newInstance?.terminate()
                    if saved {
                        var back = readProfiles()
                        back.registry.setActive(was)
                        if back.canSave { try? back.save(to: Self.registryFile) }
                    }
                    profiles = readProfiles()
                    profileProblem = why
                    return
                }
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
        let folder = profile.rootURL(home: Self.home)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
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
            // The folder this Add made goes again, only while it is still empty.
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
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

    /// This profile's server in the registry, as a hash. Only when a registry file exists and the hash changed. A
    /// newer or `partial` file, or an inert copy, saves nothing: that profile then has a server and no hash, and the
    /// rule of one server for each profile cannot see it until the file can be saved.
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

    // MARK: Delete

    /// The sheet's Delete: the rule, the profile's folder lock, then the entry is marked and the steps run.
    func deleteProfile(_ id: String, typed: String) {
        guard changesProfiles else { return }
        profileProblem = nil
        let read = readProfiles()
        guard read.canSave else { profileProblem = Self.unreadableProfiles; return }
        switch ProfileRemoval.start(id, in: read.registry, active: activeProfile.id, typed: typed, home: Self.home) {
        case .refused(let why):
            profileProblem = why
        case .go(let lock):
            var next = read
            next.registry.markRemoving(id)
            do { try next.save(to: Self.registryFile) } catch {
                Log.error("Profiles: the delete could not be saved: \(error)")
                profileProblem = Self.unreadableProfiles
                return
            }
            profiles = readProfiles()
            Log.info("Profiles: deleting one")
            finishRemovals(holding: [id: lock])
        }
    }

    /// The deletes that have not ended: after the sheet, and at each launch of a copy that is not inert. Never while
    /// a call records. Each ended step is saved with the entry, so a stop goes on at the next launch.
    func finishRemovals(holding locks: [String: InstanceLock?] = [:]) {
        guard changesProfiles, !isRecording else { return }
        let read = readProfiles()
        guard read.canSave else { return }
        let active = activeProfile.id
        let others = read.registry.live
        let iCloud = Self.hasICloud
        let file = Self.registryFile, home = Self.home
        for profile in read.registry.removing {
            var lock: InstanceLock? = locks[profile.id] ?? nil
            if lock == nil {
                switch InstanceLock.acquire(root: profile.rootURL(home: home)) {
                case .held(let held): lock = held
                case .taken:
                    Log.error("Profiles: a copy of Mossad has the deleted profile open; Mossad tries again at the next launch")
                    continue
                case .failed: break
                }
            }
            let done = Set(read.registry.removedSteps(of: profile.id))
            let actions = ProfileRemoval.Actions(
                sharedItems: { id in
                    guard iCloud else { return }
                    SharedAIKey.delete(profile: id)
                    ServerPairing.unshare(profile: id)
                },
                keys: { service in
                    let keychain = Keychain(service: service)
                    APIKey.allCases.forEach(keychain.delete)
                },
                settings: { suite in MacDefaults.store.removePersistentDomain(forName: suite) },
                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                zone: { name in if iCloud { try await CloudKitStore.deleteZone(named: name) } })
            let id = profile.id
            // The controller lives as long as the app; the steps run off the main thread, the saves on it.
            let controller = self
            Task.detached(priority: .utility) {
                let outcome = await ProfileRemoval.run(profile, home: home, others: others, done: done, active: active, actions: actions,
                                                       record: { step in await controller.noteRemoved(step, of: id, in: file) })
                withExtendedLifetime(lock) {}
                await controller.endRemoval(id, outcome: outcome, in: file)
            }
        }
    }

    private func noteRemoved(_ step: ProfileRemoval.Step, of id: String, in file: URL) {
        var read = readProfiles()
        guard read.canSave else { return }
        read.registry.noteRemoved(step, for: id)
        do { try read.save(to: file) } catch { Log.error("Profiles: the progress of a delete could not be saved: \(error)") }
    }

    private func endRemoval(_ id: String, outcome: ProfileRemoval.Outcome, in file: URL) {
        guard outcome.complete else {
            Log.error("Removing the profile stopped at \(outcome.failed?.rawValue ?? "its start"); Mossad tries again at the next launch")
            return
        }
        var read = readProfiles()
        guard read.canSave else { return }
        read.registry.remove(id)
        do { try read.save(to: file) } catch { Log.error("Profiles: the end of a delete could not be saved: \(error)") }
        profiles = readProfiles()
        Log.info("Profiles: a profile was deleted")
    }
}
