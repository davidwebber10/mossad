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

    /// The server answered that it keeps recordings. A server from before that needs its update first.
    var serverKeepsRecordings: Bool { hasServer && serverRecordingLimit > 0 }

    /// Every place that is set up, with the chosen one for new recordings. A place stays readable after the owner
    /// chooses another, so the recordings in it can be played, moved, and deleted.
    var cloudArchive: CloudArchive? {
        let settings = backupSettings
        var places: [any ArchiveBackend] = []
        if settings.hasBucket, let config = settings.bucketConfig(secret: keychain.get(.cloudSecret)) { places.append(BucketArchive(config: config)) }
        if let c = serverConnection { places.append(ServerArchive(c, maxBytes: serverRecordingLimit > 0 ? Int64(serverRecordingLimit) : nil)) }
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
        if backupMovePending, choice != .server {
            // Another choice ends the move. What was copied and checked stays on the server; the rest stays where it is.
            backupMovePending = false
            backupMoveProgress = nil
            backupMoveResult = "The move stopped when you chose another place. Recordings that were copied are on your server; the others are still in \(bucketName)."
            backupMoveDate = Date().timeIntervalSince1970
            Log.info("Backup move: stopped, because the owner chose another place for backups")
        }
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

    /// Makes the server the backup and moves every recording that is in the bucket to it. Each copy is checked on
    /// the server (size and SHA-256) before its record changes; the old copies and the bucket's settings go only
    /// after the whole move is checked. The move goes on after a restart until it is done.
    func moveBackupsToServer() {
        guard canMoveBackups, serverConnection != nil else {
            Log.error("Backup move: not started. It needs a connected server, and the copy of Mossad that runs on your own data folder")
            return
        }
        if backupChoice.isBucket { cloudBucketKind = storage }
        storage = BackupChoice.server.rawValue
        backupMovePending = true
        backupMoveResult = ""
        Log.info("Backup move: started. New recordings go to your server, and the ones in \(bucketName) are copied there")
        refreshServerFacts { self.syncCloud() }
    }

    /// A hidden request for the move: `defaults write com.dwebber.mossad moveBackupsToServer -bool YES`. Read at
    /// launch and each hour, and used once. Nothing sets it by itself.
    func consumeBackupMoveRequest() {
        let key = "moveBackupsToServer"
        guard canMoveBackups, UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        guard serverConnection != nil else {
            Log.error("Backup move: asked for with the \(key) flag, but no server is connected. Nothing was changed")
            return
        }
        Log.info("Backup move: asked for with the \(key) flag")
        moveBackupsToServer()
    }

    func backupMoveWaitsForServer() {
        let line = "Your server needs an update before it can keep recordings. The move starts after the update."
        if backupMoveResult != line {
            backupMoveResult = line
            backupMoveDate = Date().timeIntervalSince1970
            Log.error("Backup move: " + line)
        }
        if !serverFactsChecked {
            serverFactsChecked = true
            refreshServerFacts { if self.serverKeepsRecordings { self.syncCloud() } }
        }
    }

    func finishBackupMove(_ report: CloudArchive.MoveReport) {
        let old = bucketName
        let line = report.summary(old: old, new: "your server")
        backupMoveProgress = nil
        backupMoveResult = line
        backupMoveDate = Date().timeIntervalSince1970
        if report.complete {
            Log.info("Backup move: done. " + line)
            backupMovePending = false
            // Nothing of Mossad's is in the bucket now, so its secret and its settings go from this Mac.
            keychain.delete(.cloudSecret)
            keysChanged()
            cloudEndpoint = ""
            cloudBucket = ""
            cloudAccessKeyID = ""
            cloudRegion = "us-east-1"
            cloudBucketKind = ""
            backupMoveResult = line + " The \(old) settings and secret are removed from this Mac."
            Log.info("Backup move: the \(old) settings and its secret were removed from this Mac")
        } else {
            Log.error("Backup move: not done yet. " + line + " Mossad tries again within the hour.")
        }
    }
}

/// Development hook for screenshots: `MOSSAD_SERVER_SAMPLE=1` in a preview shows a made-up server as connected,
/// so the pages that need one can be looked at without a real server or its secret. No call goes to it.
enum ServerSample {
    static let isOn = CommandLine.arguments.contains("--ui-preview") && ProcessInfo.processInfo.environment["MOSSAD_SERVER_SAMPLE"] != nil
    static let connection = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "sample")
}
