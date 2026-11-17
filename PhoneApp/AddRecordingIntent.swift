import AppIntents
import Foundation
import MossadCore

/// "Add recording to Mossad": the import with no screen, by the same rules as the import screen. It does not open
/// the app. A title goes only when the owner gives one, as on the screen.
struct AddRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Add recording to Mossad"
    static let description = IntentDescription("Adds a call recording to Mossad. Your Mac writes its note.")
    static let openAppWhenRun = false

    @Parameter(title: "Audio", supportedContentTypes: [.audio]) var audio: IntentFile
    @Parameter(title: "Title") var title: String?
    @Parameter(title: "Start") var start: Date?
    @Parameter(title: "Person") var person: String?
    /// A profile by its name; else the last one chosen, else the one that shows.
    @Parameter(title: "Profile") var profile: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profiles = PhoneProfiles.shared
        let target: PhoneProfile
        if let name = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let fits = profiles.book.profiles(named: name)
            guard fits.count == 1 else {
                throw ImportWords(text: fits.isEmpty ? PhoneProfileWords.noneNamed(name, choices: profiles.book.listed.map(\.name))
                                                     : PhoneProfileWords.manyNamed(name, choices: fits.map(\.name)))
            }
            target = fits[0]
        } else {
            target = profiles.book.importDefault
        }
        guard let uploader = profiles.uploader(for: target) else { throw ImportWords(text: PhoneProfileWords.cannotOpen) }
        // The file under its own name, so the rules see what the share gave.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = (audio.filename as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name.isEmpty ? "Recording.m4a" : name)
        let data = audio.data
        try await Task.detached(priority: .userInitiated) { try data.write(to: url) }.value
        // A launch in the background reads the outbox and the people first, so a whole saved name keeps its id.
        await uploader.ready()
        await uploader.loadPeople()
        await profiles.store.launch?.value

        let file = await Task.detached { await CallImport.read(url) }.value
        let begin = start ?? CallImport.start(metadata: file.metadataDate, file: file.fileDate, length: file.length ?? 0, now: Date()).date
        let who = person.flatMap { CallImport.typed($0, among: profiles.importChoices($0, for: target)) }
        let draft = CallImport.Draft(file: file, title: title ?? "", start: begin, person: who)
        switch await profiles.importCall(draft, from: url, for: target) {
        case .failure(let refusal):
            throw ImportRefused(refusal: refusal)
        case .success(let id):
            if profile != nil { profiles.remember(importTarget: target.id) }
            let sent = await uploader.sent(id, within: 20)
            return .result(dialog: IntentDialog(stringLiteral: CallImport.resultWords(sent: sent)))
        }
    }
}

/// A refusal in the words of the import screen.
struct ImportRefused: Error, CustomLocalizedStringResourceConvertible {
    let refusal: CallImport.Refusal
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: refusal.message) }
}

/// A refusal of the action in plain words, such as a profile name that fits none.
struct ImportWords: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}
