import AppKit
import MossadCore
import SwiftUI

/// Settings › Storage & Sync: where the meetings live, by job. What stays on this Mac and for how long, the sync
/// with the iPhone, the backup of the recordings, and the owner's own server.
struct StorageSyncSettings: View {
    @EnvironmentObject var controller: AppController
    @State private var settingUp = false

    var body: some View {
        LabelColumnStack {
            ThisMacGroup().id("On this Mac")
            PhoneSyncGroup(settingUp: $settingUp).id("Sync with your iPhone")
            BackupGroup(settingUp: $settingUp).id("Recording backup")
            ServerGroup(settingUp: $settingUp).id("Your server")
        }
        .sheet(isPresented: $settingUp) { ServerSetupSheet() }
        .task { controller.refreshServerFacts() }
        // Development hook for screenshots: MOSSAD_SERVER_SETUP shows the setup steps over the page.
        .overlay(alignment: .top) {
            if ProcessInfo.processInfo.environment["MOSSAD_SERVER_SETUP"] != nil {
                ServerSetupSheet()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            }
        }
    }
}

// MARK: 1. On this Mac

/// How long audio stays on this Mac. Notes and transcripts always stay.
private struct ThisMacGroup: View {
    @EnvironmentObject var controller: AppController

    private var backedUp: Bool { controller.backupChoice != .none }

    var body: some View {
        SettingsGroup(label: "On this Mac") {
            SettingsRow(title: "Notes, transcripts, and summaries", detail: "Every meeting is always on this Mac. Only audio goes, by the rules below.") {
                Text("Always kept").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            SettingsRow(title: "Raw tracks",
                        detail: "Your microphone and the call as two separate tracks. “Transcribe again” needs them. They go after this time, once the recording exists.") {
                DaysField(title: "Days to keep the raw tracks", value: $controller.rawTracksDays, range: 1...3650)
            }
            if backedUp {
                SettingsRow(title: "Local copy of a recording",
                            detail: "Once a recording is in your backup, this Mac keeps its copy for this time. After that, the recording plays from the backup.") {
                    DaysField(title: "Days to keep a local copy", value: $controller.cloudKeepLocalDays, range: 0...3650)
                }
                Toggle(isOn: $controller.deleteRecordings) {
                    SettingsRowText(title: "Delete every local recording after a time",
                                    detail: "Also a recording that no backup has, and the pictures of shared screens with it. The backup keeps its copies. A time shorter than the one above wins.")
                }
                .toggleStyle(TrailingCheckboxStyle())
                .padding(.vertical, 9)
                if controller.deleteRecordings {
                    SettingsRow(title: "Delete them after") {
                        DaysField(title: "Days to keep recordings", value: $controller.recordingDays, range: 1...3650)
                    }
                }
            } else {
                SettingsRow(title: "Recordings",
                            detail: "The file you listen to, about 14 MB an hour, and the pictures of shared screens with it. With a recording backup, Mossad can free the local copy and still play it.") {
                    HStack(spacing: Space.s) {
                        FillPicker(title: "Keep recordings", selection: $controller.deleteRecordings,
                                   choices: [(false, "Keep always"), (true, "Delete after")])
                        if controller.deleteRecordings {
                            DaysField(title: "Days to keep recordings", value: $controller.recordingDays, range: 1...3650)
                        }
                    }
                }
            }
        }
    }
}

// MARK: 2. Sync with your iPhone

private struct PhoneSyncGroup: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool

    var body: some View {
        SettingsGroup(label: "Sync with your iPhone", footer: footer) {
            RadioRow(title: "iCloud", detail: "Your Apple devices, through your private iCloud. Nothing to set up.",
                     selected: controller.syncWith == .icloud) { controller.chooseSync(.icloud) } trailing: {
                StatusLine(model: iCloudStatus)
            }
            .disabled(!AppController.hasICloud)
            RadioRow(title: "Your server", detail: controller.serverConnection == nil ? "Your own Cloudflare account. Set it up under Your server."
                        : "Through \(controller.serverConnection?.address.host ?? "your server"). Only your devices have the secret.",
                     selected: controller.syncWith == .server) {
                if controller.serverConnection == nil { settingUp = true } else { controller.chooseSync(.server) }
            } trailing: {
                StatusLine(model: serverStatus)
            }
            RadioRow(title: "Don’t sync", detail: controller.syncWith == .off
                        ? "Your meetings stay on this Mac, and the iPhone app does not get them." : "Keep everything on this Mac.",
                     selected: controller.syncWith == .off) { controller.chooseSync(.off) } trailing: { EmptyView() }
            switch controller.syncWith {
            case .icloud:
                SyncNowRow()
                AIKeyToggle()
            case .server where controller.serverConnection != nil:
                SyncNowRow()
                PhonePairingRows()
            case .server:
                SettingsRow(title: "Finish setting up your server", detail: "Four short steps. Mossad checks each one.") {
                    Button("Set up…") { settingUp = true }.buttonStyle(.settingsAccent)
                }
            case .off:
                EmptyView()
            }
        }
    }

    private var footer: String? {
        switch controller.syncWith {
        case .icloud: "Finished meetings, their summaries and transcripts, and the coach’s notes go to your private iCloud, where Mossad for iPhone reads them. Audio does not sync. Your points for next time stay on this Mac: they sync only through your own server."
        case .server: "Finished meetings, their summaries and transcripts, and the coach’s notes sync through your server, with your points for next time. Audio does not sync."
        case .off: nil
        }
    }

    private var iCloudStatus: StatusLine.Model {
        guard AppController.hasICloud else { return .init(text: "Not in this build", color: Palette.ring) }
        guard controller.syncWith == .icloud else { return .init(text: "Available", color: Palette.ring) }
        return activityStatus
    }

    private var serverStatus: StatusLine.Model {
        guard controller.serverConnection != nil else { return .init(text: "Not set up", color: Palette.ring) }
        guard controller.syncWith == .server else { return .init(text: "Available", color: Palette.ring) }
        return activityStatus
    }

    private var activityStatus: StatusLine.Model {
        let a = controller.syncActivity
        if a.running { return .init(text: "Syncing…", color: Palette.ring, busy: true) }
        if let error = a.error { return .init(text: error.title, color: Palette.accentFill) }
        if let last = a.last { return .init(text: "Synced \(last.formatted(.relative(presentation: .named)))", color: Palette.ok) }
        return .init(text: "On", color: Palette.ok)
    }
}

/// When it last synced and Sync now; after a failure, the reason and that Mossad tries again by itself.
private struct SyncNowRow: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        if let error = controller.syncActivity.error {
            // Also when trying again as it is cannot work: after the owner fixes the cause, this is the way to sync now.
            ErrorCard(error: error, retryTitle: "Sync now", retry: controller.syncActivity.running ? nil : { controller.syncNow() },
                      note: controller.syncActivity.last.map { "Last synced \($0.formatted(.relative(presentation: .named)))." })
                .padding(.vertical, 9)
        } else {
            SettingsRow(title: controller.syncActivity.last.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet",
                        detail: "Mossad syncs after each meeting and every five minutes.") {
                HStack(spacing: Space.s) {
                    if controller.syncActivity.running { ProgressView().controlSize(.small) }
                    Button("Sync now") { controller.syncNow() }.buttonStyle(.settings).disabled(controller.syncActivity.running)
                }
            }
        }
    }
}

// MARK: 3. Recording backup

/// Where a second copy of each recording goes: nowhere, the owner's server, or a bucket. With the server chosen
/// and recordings still in a bucket, the move of all of them is one action here.
private struct BackupGroup: View {
    @EnvironmentObject var controller: AppController
    @Binding var settingUp: Bool
    @State private var confirmMove = false
    @State private var confirmForget = false
    @State private var showBucket = false

    private static let updateGuide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#update-your-server")!

    /// Counted off the main thread: it looks at each meeting's folder.
    @State private var counted = BackupCounts([])

    private var counts: BackupCounts { BackupSample.counts ?? counted }
    private var choice: BackupChoice { controller.backupChoice }
    private var connected: Bool { controller.hasServer }
    /// Recordings, or old copies of them, that a move would still take out of the bucket.
    private var inBucket: Int { counts.inBucket + counts.bucketLeftovers }

    var body: some View {
        SettingsGroup(label: "Recording backup", footer: footer) {
            SettingsRow(title: "Back up recordings to",
                        detail: "A second copy of each meeting’s recording, about 14 MB an hour, sent after the note is written. Notes and transcripts are not part of it.") {
                FillPicker(title: "Back up recordings to",
                           selection: Binding(get: { choice }, set: { controller.chooseBackup($0) }),
                           choices: BackupChoice.offered(serverConnected: connected, current: choice).map { ($0, $0.title) })
            }
            if choice != .none, choice != .server || controller.serverKeepsRecordings { statusRow }
            switch choice {
            case .none:
                if inBucket > 0 || counts.onServer > 0 { leftBehind }
                if moving { moveRows }
            case .server:
                serverRows
                if inBucket > 0 || moving { moveRows }
            case .r2, .s3:
                BucketFields()
                if controller.hasServer { moveRows }
            }
            if !result.isEmpty { moveResult }
            // The bucket's settings while another place is chosen: to repair them during a move, or to remove them after it.
            if !choice.isBucket, controller.backupSettings.hasBucket || (inBucket > 0 && connected) { bucketRows }
        }
        .task(id: CountKey(meetings: controller.meetings.count, busy: controller.cloudSyncing, choice: choice)) {
            let records = controller.meetings, paths = controller.paths
            let server = controller.serverID.isEmpty ? nil : controller.serverID
            counted = await Task.detached(priority: .utility) {
                BackupCounts(records, serverID: server) { FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory($0)).path) }
            }.value
        }
        .confirmationDialog("Remove the \(controller.bucketName) settings?", isPresented: $confirmForget) {
            Button("Remove settings", role: .destructive) { if controller.removeBucketSettings() { showBucket = false } }
        } message: {
            Text("Mossad forgets the bucket: its address, its key, and its secret. No meeting on this Mac names a recording there. The bucket itself stays as it is in \(controller.bucketName).")
        }
        .confirmationDialog("Move every backup to your server?", isPresented: $confirmMove) {
            Button("Move to your server") { controller.moveBackupsToServer() }
        } message: {
            Text("New recordings go to your server from now on. Mossad copies each recording that is in \(controller.bucketName), and checks its size and its hash on your server. When all of them are there, it removes them from \(controller.bucketName), and then removes the \(controller.bucketName) settings and secret from this Mac. You can quit Mossad at any time; the move goes on at the next start.")
        }
    }

    private var footer: String? {
        switch choice {
        case .none: nil
        case .server: "Your server keeps the recordings in its own storage, in your Cloudflare account. There is no other key to make."
        case .r2, .s3: "Use a key that can only read and write this one bucket."
        }
    }

    /// Whether the chosen place is set up, from what Settings already knows, without reading a secret.
    private var canBackUp: Bool {
        switch choice {
        case .none: false
        case .server: controller.serverKeepsRecordings
        case .r2, .s3: controller.hasBucket
        }
    }

    private var result: String { BackupSample.result ?? controller.backupMoveResult }

    private var moving: Bool { controller.backupMovePending || controller.backupMoveRequested || BackupSample.progress != nil }

    /// How many recordings are backed up, and the pass that runs now.
    private var statusRow: some View {
        let waiting = counts.notBackedUp
        let total = counts.onServer + counts.inBucket
        var parts = ["\(total) backed up"]
        if counts.onServer > 0, counts.inBucket > 0 { parts = ["\(counts.onServer) on your server", "\(counts.inBucket) in \(controller.bucketName)"] }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        // After a change of server: those recordings are not in reach, and go to this server from their local copies.
        if counts.onOtherServer > 0 { parts.append("\(counts.onOtherServer) on a server that is not connected") }
        let large = controller.backupReport.tooLarge.count
        var detail = waiting > 0 ? "Mossad sends the waiting ones after each meeting and every hour."
            : total > 0 ? "Every finished recording has its second copy." : "Mossad sends each recording after its note is written."
        if choice == .server, let limitText { detail += " One recording can be up to \(limitText), about \(Int((controller.serverRecordingLimit / 1_048_576 / 14).rounded())) hours." }
        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: parts.joined(separator: " · "), detail: detail) {
                HStack(spacing: Space.s) {
                    if controller.cloudSyncing { ProgressView().controlSize(.small) }
                    Button("Back up now") { controller.syncCloud() }.buttonStyle(.settings)
                        .disabled(controller.cloudSyncing || !canBackUp)
                }
            }
            if large > 0, let limitText {
                note("\(large == 1 ? "1 recording is" : "\(large) recordings are") larger than your server takes (\(limitText)). \(large == 1 ? "It stays" : "They stay") on this Mac.")
            }
        }
    }

    private var limitText: String? {
        controller.serverRecordingLimit > 0 ? "\(Int(controller.serverRecordingLimit / 1_048_576)) MB" : nil
    }

    /// With the server chosen, only what stops the backup shows here. The connection itself is under Your server.
    @ViewBuilder
    private var serverRows: some View {
        if !connected {
            SettingsRow(title: "No server is connected", detail: "Nothing is backed up now. Set up your server, or choose another place.") {
                Button("Set up…") { settingUp = true }.buttonStyle(.settingsAccent)
            }
        } else if !controller.serverKeepsRecordings {
            SettingsRow(title: "Your server needs an update", detail: "It is from before servers kept recordings. Nothing is backed up until you update it and check again.") {
                HStack(spacing: Space.m) {
                    SettingsHelpLink(title: "How to update", url: Self.updateGuide)
                    Button("Check again") { controller.checkServer() }.buttonStyle(.settingsAccent)
                        .disabled(controller.serverCheck == .checking)
                }
            }
        }
    }

    /// The move of every backup from the bucket to the server: the offer, the progress, and the action.
    @ViewBuilder
    private var moveRows: some View {
        let bucket = controller.bucketName
        if moving {
            let p = BackupSample.progress ?? controller.backupMoveProgress
            let waits = controller.backupMoveRequested
            SettingsRow(title: waits ? "The move waits for your server" : p.map { "Moving to your server · \($0.done) of \($0.total) copied" } ?? "Moving to your server",
                        detail: waits ? "Nothing has changed yet: new recordings keep their place until your server is ready. To end the move, click Stop."
                            : "Each copy is checked on your server. The copies in \(bucket) go only when all of them are there. You can quit Mossad; the move goes on at the next start.") {
                HStack(spacing: Space.s) {
                    if let p, p.total > 0, controller.cloudSyncing || BackupSample.progress != nil {
                        MoveProgressBar(fraction: Double(p.done) / Double(p.total))
                    } else if controller.cloudSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Try now") { controller.syncCloud() }.buttonStyle(.settings)
                    }
                    Button("Stop") { controller.stopBackupMove() }.buttonStyle(.settings)
                        .accessibilityLabel("Stop the move")
                        .help("Ends the move. What was copied stays on your server, and no setting is removed.")
                }
            }
        } else if choice == .server {
            SettingsRow(title: "\(inBucket == 1 ? "1 recording is" : "\(inBucket) recordings are") still in \(bucket)",
                        detail: "They play from there, and nothing moves by itself. A move copies each one to your server, checks it, and then removes it from \(bucket).") {
                Button("Move to your server…") { confirmMove = true }.buttonStyle(.settings)
            }
        } else if controller.serverKeepsRecordings {
            SettingsRow(title: "Use your server instead",
                        detail: "Your server can keep the recordings, with no other key. A move copies each one there, checks it, and then removes it from \(bucket).") {
                Button("Move to your server…") { confirmMove = true }.buttonStyle(.settings)
            }
        }
    }

    /// The bucket's settings while it is not the chosen place: closed by default, with what they are still for.
    @ViewBuilder
    private var bucketRows: some View {
        let bucket = controller.bucketName
        SettingsRow(title: "\(bucket) settings",
                    detail: inBucket > 0 ? "Mossad needs them to read and move the \(inBucket == 1 ? "recording that is" : "\(inBucket) recordings that are") still there."
                        : "No meeting on this Mac names a recording there now. You can remove them.") {
            HStack(spacing: Space.s) {
                if inBucket == 0, !moving {
                    Button("Remove…") { confirmForget = true }.buttonStyle(.settings)
                        .accessibilityLabel("Remove the \(bucket) settings")
                }
                Button(showBucket ? "Hide" : "Show") { showBucket.toggle() }.buttonStyle(.settings)
                    .accessibilityLabel(showBucket ? "Hide the \(bucket) settings" : "Show the \(bucket) settings")
            }
        }
        if showBucket { BucketFields() }
    }

    private var moveResult: some View {
        let date = controller.backupMoveDate > 0 ? Date(timeIntervalSince1970: controller.backupMoveDate).formatted(.dateTime.month(.abbreviated).day().hour().minute()) : nil
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(moving ? "State of the move" : "Last move")\(date.map { " · \($0)" } ?? "")").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text(result).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            if !moving {
                Button("Dismiss") { controller.backupMoveResult = "" }
                    .buttonStyle(SettingsTextButtonStyle())
                    .accessibilityLabel("Dismiss the result of the last move")
            }
        }
        .padding(.vertical, 9)
    }

    /// With no backup chosen, the copies that exist stay where they are and still play.
    private var leftBehind: some View {
        var places: [String] = []
        if counts.onServer > 0 { places.append("\(counts.onServer) on your server") }
        if inBucket > 0 { places.append("\(inBucket) in \(controller.bucketName)") }
        return SettingsRow(title: "Earlier backups stay: " + places.joined(separator: ", "),
                           detail: "They still play from there, and go when you delete their meeting. New recordings stay on this Mac only.")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.accent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 9)
    }
}

/// When to count again: a new meeting, the end of an upload pass, or another choice.
private struct CountKey: Equatable {
    let meetings: Int
    let busy: Bool
    let choice: BackupChoice
}

/// How far the move is: the accent on the fill, like the app's other bars.
private struct MoveProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule().fill(Palette.fill)
            .frame(width: 96, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.accentFill).frame(width: max(6, 96 * min(max(fraction, 0), 1)))
            }
            .accessibilityElement()
            .accessibilityLabel("Recordings copied")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// The bucket's address, its key, and a check of the connection.
private struct BucketFields: View {
    @EnvironmentObject var controller: AppController
    @State private var secret = ""
    @State private var replacing = false
    @State private var check = SettingsCheck.idle

    private var r2: Bool { controller.backupSettings.bucketFlavor == .r2 }
    private var keysPage: URL {
        URL(string: r2 ? "https://developers.cloudflare.com/r2/api/tokens/" : "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html")!
    }

    var body: some View {
        field("Endpoint", text: $controller.cloudEndpoint,
              prompt: r2 ? "https://<account id>.r2.cloudflarestorage.com" : "https://s3.us-east-1.amazonaws.com")
        field("Bucket", text: $controller.cloudBucket, prompt: "mossad-recordings")
        if !r2 { field("Region", text: $controller.cloudRegion, prompt: "us-east-1") }
        field("Access key ID", text: $controller.cloudAccessKeyID, prompt: "")
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Secret access key").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                SettingsHelpLink(title: r2 ? "Make an R2 API token" : "Make an access key", url: keysPage)
            }
            Spacer(minLength: Space.m)
            if controller.hasKey(.cloudSecret), !replacing {
                Text("Saved in the Keychain").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Button("Change") { replacing = true; secret = "" }.buttonStyle(.settings)
                    .accessibilityLabel("Change the secret access key")
            } else {
                SecureField("Secret access key", text: $secret, prompt: Text("Paste the secret"))
                    .textFieldStyle(SettingsFieldStyle(width: 240, monospaced: true))
                    .onSubmit(saveSecret)
                Button("Save", action: saveSecret).buttonStyle(.settingsAccent)
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 9)
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Connection", detail: controller.hasBucket ? "Mossad uploads a small test file and removes it." : "Fill in the fields above, then check.") {
                SettingsCheckButton(state: check, passed: "Connected", action: runCheck).disabled(!controller.hasBucket)
            }
            SettingsCheckFailure(state: check)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        SettingsRow(title: title) {
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(SettingsFieldStyle(width: 300, monospaced: true))
        }
    }

    private func saveSecret() {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try controller.keychain.set(value, for: .cloudSecret) } catch { Log.error("Saving the cloud secret failed") }
        secret = ""
        replacing = false
        check = .idle
        controller.keysChanged()
    }

    private func runCheck() {
        guard let archive = controller.cloudArchive else { return }
        check = .checking
        Task {
            let ok = await archive.check(.bucket)
            check = ok ? .passed : .failed("The bucket did not take a test file. Check the endpoint, the bucket name, and that the key can write to it.")
            if ok { controller.syncCloud() }
        }
    }
}

/// Development hook for screenshots: `MOSSAD_BACKUP_SAMPLE` in a preview shows made-up numbers, since the made-up
/// meetings have no backup. "counts" for recordings in two places, "moving" for a move in progress.
enum BackupSample {
    private static let value = CommandLine.arguments.contains("--ui-preview") ? ProcessInfo.processInfo.environment["MOSSAD_BACKUP_SAMPLE"] : nil

    static var counts: BackupCounts? {
        guard let value else { return nil }
        var c = BackupCounts([])
        c.onServer = value == "bucket" ? 0 : value == "large" ? 225 : 212
        c.inBucket = value == "server" ? 0 : value == "bucket" ? 226 : value == "large" ? 1 : 14
        c.notBackedUp = value == "server" || value == "large" ? 0 : 3
        return c
    }

    /// `MOSSAD_MOVE_RESULT` in a preview: the line of a last move, to look at the row that shows it.
    static var result: String? {
        guard CommandLine.arguments.contains("--ui-preview"), let line = ProcessInfo.processInfo.environment["MOSSAD_MOVE_RESULT"], !line.isEmpty else { return nil }
        return line
    }

    static var progress: (done: Int, total: Int)? { value == "moving" ? (37, 214) : nil }
}
