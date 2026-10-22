import Foundation
import MossadCore

/// The phone's copy of the meetings: pulled from iCloud into the app's folder, then read with the same code
/// the Mac uses.
@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var profile = CoachProfile()
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var error: String?
    /// The meetings open in the Meetings tab, for `mossad://call/<id>` links.
    @Published var path: [String] = []

    let paths = Paths.live
    private lazy var cloud = CloudSync(paths: paths)

    init() {
        reload()
        // Development hook: `MOSSAD_OPEN=<call id>` opens a meeting at launch, for screenshots.
        if let id = ProcessInfo.processInfo.environment["MOSSAD_OPEN"] { path = [id] }
    }

    /// The owner: the name most often on the mic track, which is the Mac owner's own.
    var owner: String {
        var counts: [String: Int] = [:]
        for r in meetings { for (key, name) in r.speakerNames where key.hasPrefix("me:") { counts[name, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        // `MOSSAD_ROOT` points the simulator at a sample folder; there is nothing to pull then.
        if ProcessInfo.processInfo.environment["MOSSAD_ROOT"] == nil {
            do {
                try await cloud.pull()
                error = nil
                lastSync = Date()
            } catch {
                self.error = "Could not reach iCloud: \(error.localizedDescription)"
            }
        }
        reload()
    }

    func reload() {
        meetings = MeetingIndex(paths: paths).all()
        profile = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
    }

    func coach(_ id: String) -> CoachReview? { CoachReview.load(in: paths.callDirectory(id)) }
}
