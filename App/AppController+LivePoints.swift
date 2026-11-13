import Foundation
import MossadCore

/// The owner's points on the page of the call that records now: which points (the prep page's rule), what Mossad
/// heard, and the owner's ticks. The marks are saved next to call.json for the check after the call. One model for
/// the live page and the quick panel; the views that read it through the controller redraw with it.
@MainActor
final class LivePointsModel: ObservableObject {
    @Published private(set) var marks = LivePointMarks() { willSet { owner?.objectWillChange.send() } }
    /// The call's series and saved people, made off the main thread.
    @Published private(set) var series: MeetingSeries? { willSet { owner?.objectWillChange.send() } }
    @Published private(set) var people: [String] = [] { willSet { owner?.objectWillChange.send() } }
    weak var owner: AppController?
    /// One write at a time, in order, so an older copy never replaces a newer one.
    private let saves = DispatchQueue(label: "com.dwebber.mossad.live-points-save", qos: .utility)
    /// Said once for each call: the automatic marks are off with a model on this Mac.
    var saidLocal: String?
    private(set) var callID: String?
    private var madeFor: Int?
    private var making: Task<Void, Never>?
    var hearing: Task<Void, Never>?

    /// The call's points: the series' first, then each person's, with the ones this call closed.
    func points(_ book: NextTimeBook, refs: PersonReferences) -> [NextTimePoint] {
        guard let callID else { return [] }
        return LivePoints.list(book, series: series, people: people, callID: callID, canonical: { refs.canonical($0) })
    }

    /// Reads the call's marks once when the page or the hearing starts on a new call.
    func open(_ id: String, paths: Paths) {
        guard callID != id else { return }
        callID = id
        series = nil
        people = []
        madeFor = nil
        marks = LivePointMarks.load(from: paths.callDirectory(id)) ?? LivePointMarks()
    }

    func change(_ paths: Paths, _ change: (inout LivePointMarks) -> Void) {
        guard let id = callID else { return }
        change(&marks)
        let copy = marks, dir = paths.callDirectory(id)
        saves.async {
            do { try copy.save(to: dir) } catch { Log.error("Saving the live marks of the points failed: \(error)") }
        }
    }

    struct Inputs: Sendable {
        let record: CallRecord
        let all: [MeetingSeries]
        let records: [CallRecord]
        let owner: String
        let profiles: [VoiceProfile]
        let ownerEmail: String
        let aliases: [String: String]
        let refs: PersonReferences
        let heard: [String]
        /// When the people file changed: a late read of it makes the list again.
        let peopleStamp: Date?
    }

    /// The series and the people again when the catalog, the invite, or the names heard changed.
    func refresh(_ inputs: Inputs, version: Int) {
        var h = Hasher()
        h.combine(version)
        h.combine(inputs.record.id)
        h.combine(inputs.record.calendarTitle)
        h.combine(inputs.record.calendarSeriesID)
        h.combine(inputs.record.attendees)
        h.combine(inputs.all.map(\.id))
        h.combine(inputs.heard)
        h.combine(inputs.peopleStamp)
        let key = h.finalize()
        guard key != madeFor else { return }
        madeFor = key
        making?.cancel()
        making = Task {
            let made = await Task.detached(priority: .utility) { () -> (MeetingSeries?, [String]) in
                let s = LivePoints.series(ofLive: inputs.record, in: inputs.all, records: inputs.records, owner: inputs.owner,
                                          directory: PersonDirectory(profiles: inputs.profiles), ownerEmails: [inputs.ownerEmail], aliases: inputs.aliases)
                return (s, LivePoints.personIDs(attendees: inputs.record.attendees, heard: inputs.heard, people: inputs.refs))
            }.value
            guard !Task.isCancelled, callID == inputs.record.id else { return }
            if series?.id != made.0?.id || series?.keys != made.0?.keys { series = made.0 }
            if people != made.1 { people = made.1 }
        }
    }
}

extension AppController {
    /// Makes the call's list when something it reads changed, from the record as it is now (its invite comes a
    /// moment after the call starts). Only for the call that records now; a preview shows its made-up one.
    func refreshLivePoints(callID: String) {
        guard isLiveCall(callID) || DevHooks.preview, let record = meetings.first(where: { $0.id == callID }) else { return }
        livePoints.owner = self
        refreshSeries()
        livePoints.open(record.id, paths: paths)
        let heard = Array(Set(live.transcript.names.values)).sorted()
        let peopleFile = paths.people.appendingPathComponent(PeopleStore.fileName)
        livePoints.refresh(.init(record: record, all: series.all, records: meetings, owner: ownerName, profiles: library.profiles,
                                 ownerEmail: UserDefaults.standard.string(forKey: "ownerEmail") ?? "", aliases: SeriesCatalog.aliases(calendarEvents),
                                 refs: series.people, heard: heard,
                                 peopleStamp: (try? FileManager.default.attributesOfItem(atPath: peopleFile.path))?[.modificationDate] as? Date),
                           version: meetingsVersion)
    }

    /// The call that records now.
    func isLiveCall(_ callID: String) -> Bool {
        if case .recording(_, let since) = status { return CallRecorder.callID(for: since) == callID }
        return false
    }

    func livePointList() -> [NextTimePoint] { livePoints.points(series.book, refs: series.people) }

    /// The owner's tick: raised now, at this second of the recording, or at the moment Mossad heard it when the
    /// tick confirms a mark. A second tick takes it back.
    func toggleLivePoint(_ p: NextTimePoint, callID: String) {
        guard isLiveCall(callID) || DevHooks.preview else { return }
        if p.done?.callID == callID {
            // Taken back as the page shows it, whatever another writer did a moment before.
            changeNextTime { $0.update(p.id) { if $0.done?.callID == callID { $0.done = nil } } }
        } else {
            let at = LivePointRules.tickTime(heard: livePoints.marks.mark(for: p.id)?.at, recording: liveRecorded, live: isLiveCall(callID))
            changeNextTime { $0.update(p.id) { $0.done = .init(callID: callID, at: at, quote: nil, date: Date(), byOwner: true) } }
        }
    }

    /// "Not raised": the owner says Mossad's mark is wrong. The point is open again, and that line never marks it.
    func rejectLivePoint(_ p: NextTimePoint) {
        livePoints.change(paths) { $0.reject(p.id) }
    }

    /// The points as the live chat reads them.
    func livePointFacts(callID: String) -> [LivePointFact] {
        guard livePoints.callID == callID else { return [] }
        return LivePointFact.from(livePointList(), marks: livePoints.marks, callID: callID)
    }

    /// The chosen provider's model for a question during a call, by the live chat's rule.
    private var livePointsLLM: (any LanguageModel)? {
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard key != nil || !aiProvider.requiresKey, !(aiModel.isEmpty && aiProvider.defaultModel.isEmpty) else { return nil }
        return aiProvider.model(aiProvider.liveChatModel(aiModel), apiKey: key, usage: usage, serverURL: localServerBase)
    }

    /// While the live transcript runs: every 20 s, the owner's new lines against the open points, and a small
    /// request only for a point that may have come up, within `LivePointRules`' bounds. Stopped with the live
    /// transcript, so a pause, a call without it, or Settings' switch sends nothing.
    func startLiveHearing(callID: String) {
        livePoints.hearing?.cancel()
        livePoints.open(callID, paths: paths)
        livePoints.hearing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                guard case .recording(_, let since) = self.status, CallRecorder.callID(for: since) == callID else { return }
                await self.hearPoints(callID: callID)
            }
        }
    }

    func stopLiveHearing() {
        livePoints.hearing?.cancel()
        livePoints.hearing = nil
    }

    private func hearPoints(callID: String) async {
        guard !isPaused, liveOffReason == nil, liveTranscriptEnabled, let record = meetings.first(where: { $0.id == callID }) else { return }
        // No open point at all: nothing to make or to read.
        series.reload(paths)
        guard series.book.points.contains(where: \.isOpen) else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard LivePointRules.hears(modelOnThisMac: aiProvider.isLocal, hot: thermal == .serious || thermal == .critical) else {
            if aiProvider.isLocal, livePoints.saidLocal != callID {
                livePoints.saidLocal = callID
                Log.info("Your points: no automatic marks in \(callID), the model runs on this Mac and waits for the call's end")
            }
            return
        }
        refreshLivePoints(callID: callID)
        let points = livePointList()
        guard !points.isEmpty else { return }
        let snapshot = live.snapshot, owner = ownerName, marks = livePoints.marks, now = liveRecorded, start = record.start
        let due = await Task.detached(priority: .utility) {
            LivePointRules.due(points, entries: snapshot.entries(owner: owner), marks: marks, now: now, transcriptOn: true, callStart: start)
        }.value
        guard !due.isEmpty, let llm = livePointsLLM else { return }
        let confirmer = LivePointConfirmer(llm: llm)
        for d in due {
            guard !Task.isCancelled, livePoints.callID == callID else { return }
            // Counted before it is sent: a failed request still counts against the bounds.
            livePoints.change(paths) { $0.asks.append(.init(point: d.point.id, at: now, through: d.through)) }
            do {
                let mark = try await Task.detached(priority: .utility) {
                    try await UsageContext.$callID.withValue(callID) { try await confirmer.confirm(d) }
                }.value
                if let mark, livePoints.callID == callID { livePoints.change(paths) { $0.add(mark) } }
            } catch {
                Log.error("Hearing a point in \(callID) failed: \(error)")
            }
        }
    }
}
