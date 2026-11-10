import Foundation
import MossadCore

/// The recording backup: the places that are set up, the choice for new recordings, and the move of every backup
/// from a bucket to the owner's server.
extension AppController {
    var backupSettings: BackupSettings {
        BackupSettings(choice: storage, bucketKind: cloudBucketKind, endpoint: cloudEndpoint, bucket: cloudBucket,
                       region: cloudRegion, accessKeyID: cloudAccessKeyID)
    }

    var backupChoice: BackupChoice { backupSettings.choice }

    /// The server answered that it keeps recordings, and named itself. A server from before that needs its update
    /// first: without its id, a recording on it cannot be told from one on another server.
    var serverKeepsRecordings: Bool { hasServer && serverRecordingLimit > 0 && !serverID.isEmpty }

    /// Every place that is set up, with the chosen one for new recordings. A place stays readable after the owner
    /// chooses another, so the recordings in it can be played, moved, and deleted.
    var cloudArchive: CloudArchive? {
        let settings = backupSettings
        var places: [any ArchiveBackend] = []
        if settings.hasBucket, let config = settings.bucketConfig(secret: keychain.get(.cloudSecret)) { places.append(BucketArchive(config: config)) }
        if let c = serverConnection {
            places.append(ServerArchive(c, id: serverID.isEmpty ? nil : serverID, maxBytes: serverRecordingLimit > 0 ? Int64(serverRecordingLimit) : nil))
        }
        guard !places.isEmpty else { return nil }
        let target = settings.choice == .server && !serverKeepsRecordings ? nil : settings.choice.target
        return CloudArchive(target: target, places: places, paths: paths)
    }

    func chooseBackup(_ choice: BackupChoice) {
        guard choice != backupChoice else { return }
        // What the bucket fields describe is remembered, for the recordings that stay in the bucket.
        if backupChoice.isBucket { cloudBucketKind = storage }
        storage = choice.rawValue
        if choice.isBucket { cloudBucketKind = choice.rawValue }
        backupReport = CloudArchive.Report()
        // Another choice ends a move, also one that still waits for the server.
        if backupMovePending || backupMoveRequested { stopBackupMove() }
        if choice == .server { refreshServerFacts { self.syncCloud() } } else { syncCloud() }
    }

    /// For an owner who chose a bucket before the choice of place was remembered apart from it.
    func rememberBucketKind() {
        if backupChoice.isBucket, cloudBucketKind != storage { cloudBucketKind = storage }
    }

    /// Asks the server what it can do: its AI address, its chat, and whether it keeps recordings. A server that
    /// was updated since the last launch is noticed here. The answer is also the status that Settings shows.
    func refreshServerFacts(then done: (@MainActor () -> Void)? = nil) {
        if ServerSample.isOn { serverCheck = .passed }
        guard !Rehearsal.isOn, !ServerSample.isOn, let c = serverConnection else { done?(); return }
        if serverCheck != .passed { serverCheck = .checking }
        Task {
            do {
                let hello = try await ServerClient(c).hello()
                if hello.authorized {
                    if let mcp = hello.mcp?.absoluteString, mcp != serverMCP { serverMCP = mcp }
                    if hello.chat != serverHasChat { serverHasChat = hello.chat }
                    let limit = Double(hello.recordingLimit ?? 0)
                    if limit != serverRecordingLimit { serverRecordingLimit = limit }
                    if let id = hello.id, id != serverID { serverID = id }
                    serverCheck = .passed
                } else {
                    serverCheck = .failed("Your server does not accept the secret that Mossad has. Use Change server to enter the secret again.")
                }
            } catch {
                serverCheck = .failed(FriendlyError(error, context: .syncing, service: "your server").message)
            }
            done?()
        }
    }

    /// The Check button: asks the server again, and with the recording backup on it, sends a small test file too.
    func checkServer() {
        guard serverConnection != nil, !ServerSample.isOn else { return }
        serverCheck = .checking
        refreshServerFacts {
            guard self.serverCheck == .passed, self.backupChoice == .server, self.serverKeepsRecordings, let archive = self.cloudArchive else { return }
            self.serverCheck = .checking
            Task {
                let ok = await archive.check(.server)
                self.serverCheck = ok ? .passed : .failed("Your server answers, but it did not take a test recording. Deploy the newest server, then check again.")
                if ok { self.syncCloud() }
            }
        }
    }

    /// Keeps what an upload pass could not do, and says a new problem once in the log.
    func note(_ report: CloudArchive.Report) {
        guard report != backupReport else { return }
        if report.tooLarge != backupReport.tooLarge, !report.tooLarge.isEmpty {
            Log.error("Backup: \(report.tooLarge.count) recordings are larger than the backup takes and stay on this Mac: \(report.tooLarge.joined(separator: ", "))")
        }
        backupReport = report
    }

    // MARK: The move to the server

    /// A copy that was started by hand on another data folder shares the settings and the Keychain of the real app,
    /// but not its meetings. To that copy every bucket looks empty, so it must never run the move or end it.
    var canMoveBackups: Bool { !isInert && ProcessInfo.processInfo.environment["MOSSAD_ROOT"]?.isEmpty != false }

    /// The name of the bucket's service, for sentences: "Cloudflare R2".
    var bucketName: String { backupSettings.bucketFlavor.title }

    /// Whether a run of the move may go on, asked before each copy and each delete. The owner ends a move with
    /// another choice in the picker; a call that records gets the network and the disk for itself.
    var backupMoveMayRun: Bool { backupMovePending && backupChoice == .server && canMoveBackups && !isRecording }

    /// Asks for the move of every backup from the bucket to the server. Nothing changes yet: the backup choice
    /// stays as it is until the server says that it keeps recordings, so new recordings keep their place.
    func moveBackupsToServer() {
        guard canMoveBackups, hasServer else {
            Log.error("Backup move: not started. It needs a connected server, and the copy of Mossad that runs on your own data folder")
            return
        }
        backupMoveRequested = true
        backupMoveMissing = 0
        backupMoveResult = ""
        startRequestedMove()
    }

    /// Starts a move that was asked for, once the server answers that it keeps recordings. Then the server
    /// becomes the backup, and each recording in the bucket is copied and checked (size and SHA-256) before its
    /// record changes. The old copies and the bucket's settings go only after the whole move is checked. Asked
    /// again in each upload pass while the server is not ready.
    func startRequestedMove() {
        guard backupMoveRequested, canMoveBackups else { return }
        guard hasServer else {
            noteBackupMove("No server is connected. The move starts when one is.")
            return
        }
        refreshServerFacts {
            guard self.backupMoveRequested else { return }
            if self.serverCheck == .passed, self.serverKeepsRecordings {
                self.backupMoveRequested = false
                if self.backupChoice.isBucket { self.cloudBucketKind = self.storage }
                self.storage = BackupChoice.server.rawValue
                self.backupMovePending = true
                self.backupMoveResult = ""
                Log.info("Backup move: started. New recordings go to your server, and the ones in \(self.bucketName) are copied there")
                self.syncCloud()
            } else {
                self.noteBackupMove(self.serverNotReady)
            }
        }
    }

    /// Ends a move that the owner does not want any more. The run that may be in progress asks before each copy and
    /// each delete, so it ends at once; and its end changes no setting. What was copied and checked stays on the
    /// server, and the rest stays where it is.
    func stopBackupMove() {
        // A copy on another data folder shares these settings with the real app, and must not end its move.
        guard canMoveBackups, backupMovePending || backupMoveRequested else { return }
        let started = backupMovePending
        backupMovePending = false
        backupMoveRequested = false
        backupMoveProgress = nil
        backupMoveResult = started ? "You stopped the move. Recordings that were copied are on your server; the others are still in \(bucketName). No setting was removed."
            : "You stopped the move before it started. Nothing was changed."
        backupMoveDate = Date().timeIntervalSince1970
        Log.info("Backup move: stopped by the owner")
    }

    /// Why the server cannot take the move now: it did not answer, or it is from before it kept recordings.
    private var serverNotReady: String {
        if case .failed(let why) = serverCheck { return "The move waits for your server. \(why) Mossad asks again within the hour." }
        return "Your server needs an update before it can keep recordings. The move starts after the update."
    }

    private func noteBackupMove(_ line: String) {
        guard backupMoveResult != line else { return }
        backupMoveResult = line
        backupMoveDate = Date().timeIntervalSince1970
        Log.error("Backup move: " + line)
    }

    /// A hidden request for the move: `defaults write com.dwebber.mossad moveBackupsToServer -bool YES`. Read at
    /// launch and each hour. Nothing sets it by itself. It is removed when it is used; with no server connected it
    /// stays, and waits for one.
    func consumeBackupMoveRequest() {
        let key = "moveBackupsToServer"
        guard canMoveBackups, UserDefaults.standard.bool(forKey: key) else { return }
        // As a launch argument (`-moveBackupsToServer YES`) the flag cannot be removed, so it counts once a launch.
        let fromArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
        if fromArguments, backupMoveRequestSeen { return }
        guard hasServer else {
            if !backupMoveRequestSeen { Log.error("Backup move: asked for with the \(key) flag, but no server is connected. The request waits for one") }
            backupMoveRequestSeen = true
            return
        }
        backupMoveRequestSeen = true
        if !fromArguments { UserDefaults.standard.removeObject(forKey: key) }
        Log.info("Backup move: asked for with the \(key) flag")
        moveBackupsToServer()
    }

    /// A move that is in progress, and a server that cannot take it now (disconnected, changed, or no answer yet).
    /// Asked again in each upload pass.
    func backupMoveWaitsForServer() {
        guard hasServer else {
            noteBackupMove("No server is connected. The move goes on when one is.")
            return
        }
        refreshServerFacts {
            if self.serverKeepsRecordings { self.syncCloud() } else { self.noteBackupMove(self.serverNotReady) }
        }
    }

    func finishBackupMove(_ report: CloudArchive.MoveReport) {
        backupMoveProgress = nil
        let old = bucketName
        let missing = backupMoveMissing + report.missing.count
        // Asked at this moment: the run's own answer is some seconds old, and the owner may have ended the move
        // during it. A run that is not asked for any more changes no setting and removes no secret.
        let end = CloudArchive.moveEnd(report, stillAsked: backupMovePending && backupChoice == .server && canMoveBackups,
                                       nothingLeftNow: CloudArchive.nothingLeft(in: paths, from: .bucket), missing: missing)
        guard end != .ignored else {
            Log.info("Backup move: a run ended after the move was stopped. Nothing more was changed")
            return
        }
        backupMoveMissing = missing
        var line = report.summary(old: old, new: "your server")
        if !report.tooLarge.isEmpty {
            let names = report.tooLarge.prefix(3).map { id in meetings.first { $0.id == id }?.title ?? id }
            line += " Too large: \(names.joined(separator: ", "))\(report.tooLarge.count > 3 ? ", and \(report.tooLarge.count - 3) more" : "")."
        }
        switch end {
        case .ignored:
            return
        case .forgetOldPlace:
            backupMovePending = false
            removeBucketSettings()
            line += " The \(old) settings and secret are removed from this Mac."
            Log.info("Backup move: done. " + line)
        case .doneKeepSettings:
            // A recording that should have been in the bucket was not. The owner decides when the bucket is forgotten.
            backupMovePending = false
            line += " The \(old) settings stay on this Mac, because \(missing == 1 ? "a recording was" : "\(missing) recordings were") not where the records said. Remove the settings here when you are sure."
            Log.error("Backup move: done, with recordings that were missing. " + line)
        case .rests:
            // Another run changes nothing, so the hourly runs end. What is left in the bucket still plays from there.
            backupMovePending = false
            line += " The move rests here, and the \(old) settings stay on this Mac."
            Log.error("Backup move: ended with work that needs you. " + line)
        case .paused:
            line += " It goes on after the call."
            Log.info("Backup move: paused. " + line)
        case .again:
            line += " Mossad tries again within the hour."
            Log.error("Backup move: not done yet. " + line)
        }
        backupMoveDate = Date().timeIntervalSince1970
        backupMoveResult = line
    }

    /// Forgets the bucket: its secret in the Keychain and its settings. Only when no meeting names a copy in it.
    @discardableResult
    func removeBucketSettings() -> Bool {
        guard canMoveBackups, !backupMovePending, !backupChoice.isBucket, CloudArchive.nothingLeft(in: paths, from: .bucket) else { return false }
        let old = bucketName
        keychain.delete(.cloudSecret)
        keysChanged()
        cloudEndpoint = ""
        cloudBucket = ""
        cloudAccessKeyID = ""
        cloudRegion = "us-east-1"
        cloudBucketKind = ""
        Log.info("Backup: the \(old) settings and its secret were removed from this Mac")
        return true
    }
}

/// Development hook for screenshots: `MOSSAD_SERVER_SAMPLE=1` in a preview shows a made-up server as connected,
/// so the pages that need one can be looked at without a real server or its secret. No call goes to it.
enum ServerSample {
    static let isOn = CommandLine.arguments.contains("--ui-preview") && ProcessInfo.processInfo.environment["MOSSAD_SERVER_SAMPLE"] != nil
    static let connection = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "sample")
}
