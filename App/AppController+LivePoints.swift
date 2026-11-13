import Foundation
import MossadCore

/// The owner's points on the page of the call that records now: which points (the prep page's rule), what Mossad
/// heard, and the owner's ticks. The marks are saved next to call.json, so a restart during the call keeps them.
@MainActor
final class LivePointsModel: ObservableObject {
    @Published private(set) var marks = LivePointMarks()
    /// The call's series and saved people, made off the main thread.
    @Published private(set) var series: MeetingSeries?
    @Published private(set) var people: [String] = []
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
        Task.detached(priority: .utility) {
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
        let key = h.finalize()
        guard key != madeFor else { return }
        madeFor = key
        making?.cancel()
        making = Task {
            let made = await Task.detached(priority: .userInitiated) { () -> (MeetingSeries?, [String]) in
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
    /// Makes the call's list when something it reads changed. Cheap to call from a view's task.
    func refreshLivePoints(_ record: CallRecord) {
        refreshSeries()
        livePoints.open(record.id, paths: paths)
        let heard = Array(Set(live.transcript.names.values)).sorted()
        livePoints.refresh(.init(record: record, all: series.all, records: meetings, owner: ownerName, profiles: library.profiles,
                                 ownerEmail: UserDefaults.standard.string(forKey: "ownerEmail") ?? "", aliases: SeriesCatalog.aliases(calendarEvents),
                                 refs: series.people, heard: heard), version: meetingsVersion)
    }

    func livePointList() -> [NextTimePoint] { livePoints.points(series.book, refs: series.people) }

    /// The owner's tick: raised now, at this second of the recording. A second tick takes it back.
    func toggleLivePoint(_ p: NextTimePoint, callID: String) {
        if p.done?.callID == callID {
            changeNextTime { $0.toggleDone(p.id) }
        } else {
            let at: TimeInterval? = isRecording ? liveRecorded : nil
            changeNextTime { $0.update(p.id) { $0.done = .init(callID: callID, at: at, quote: nil, date: Date(), byOwner: true) } }
        }
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
        refreshLivePoints(record)
        series.reload(paths)
        let points = livePointList()
        guard !points.isEmpty, let llm = livePointsLLM else { return }
        let snapshot = live.snapshot, owner = ownerName, marks = livePoints.marks, now = liveRecorded
        let due = await Task.detached(priority: .utility) {
            LivePointRules.due(points, entries: snapshot.entries(owner: owner), marks: marks, now: now, transcriptOn: true)
        }.value
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
