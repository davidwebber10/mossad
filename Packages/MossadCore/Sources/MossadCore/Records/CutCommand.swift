import Foundation

/// `Mossad --cut <call id> --at <seconds>[,<seconds>…] [--dry-run]`: cuts one recording into meetings, for support
/// and for the repair of a recording that held two calls. It runs the pipeline's own cut (`Pipeline.cut`) with the
/// profile's folder lock, so it is refused while Mossad is open; the parts are processed at the next launch.
public enum CutCommand {
    public static let usage = "Usage: Mossad --cut <call id> --at <seconds>[,<seconds>…] [--dry-run] [--profile <id>]"

    public struct Arguments: Equatable, Sendable {
        public var callID: String
        public var times: [TimeInterval]
        public var dryRun: Bool

        public init(callID: String, times: [TimeInterval], dryRun: Bool) {
            self.callID = callID
            self.times = times
            self.dryRun = dryRun
        }
    }

    public struct ParseError: Error, Equatable {
        public var text: String
    }

    /// The command's own words, nothing else: an unknown flag or a value that is not a time refuses.
    public static func parse(_ arguments: [String]) -> Result<Arguments, ParseError> {
        func fail(_ why: String) -> Result<Arguments, ParseError> { .failure(ParseError(text: why + "\n" + usage)) }
        var callID: String?, times: [TimeInterval]?, dryRun = false
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--cut":
                guard callID == nil, i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return fail("--cut needs one call id.") }
                callID = arguments[i + 1]
                i += 2
            case "--at":
                guard times == nil, i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return fail("--at needs the cut times in seconds.") }
                let parts = arguments[i + 1].split(separator: ",", omittingEmptySubsequences: false)
                let values = parts.map { TimeInterval(String($0).trimmingCharacters(in: .whitespaces)) }
                guard !values.isEmpty, values.allSatisfy({ $0.map { $0.isFinite && $0 > 0 } == true }) else {
                    return fail("\(arguments[i + 1]) is not a list of seconds.")
                }
                times = values.compactMap { $0 }
                i += 2
            case "--dry-run":
                dryRun = true
                i += 1
            case "--profile":
                i += 2
            default:
                return fail("\(a) is not a word of this command.")
            }
        }
        guard let callID else { return fail("--cut needs one call id.") }
        guard MovePaths.isID(callID) else { return fail("\(callID) is not a call id.") }
        guard let times else { return fail("--at needs the cut times in seconds.") }
        return .success(Arguments(callID: callID, times: times, dryRun: dryRun))
    }

    /// What the cut would make: the recording's length, its pauses, its merged parts, and each part with its times.
    public static func planText(record r: CallRecord, length: TimeInterval, parts: [CallRecord], cuts: [Cut], timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func seconds(_ t: TimeInterval) -> String { "\(Int(t.rounded())) s" }
        func span(_ t: TimeInterval) -> String {
            let s = Int(t.rounded())
            return "\(s / 60) min \(s % 60) s"
        }
        func clock(_ t: TimeInterval) -> String {
            let s = Int(t.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
        var lines = ["Meeting \(r.id) (\(r.status.rawValue)): \(span(length)) of audio."]
        let pauses = r.pauses ?? []
        lines.append(r.pauses == nil ? "Pauses: not known (recorded by an older version)." : pauses.isEmpty ? "Pauses: none." : "Pauses (\(pauses.count)): " + pauses.enumerated().map { n, p in
            "\(n + 1). At \(seconds(p.at)) (\(clock(p.at))), from \(f.string(from: p.from)) to \(p.to.map(f.string) ?? "the end")."
        }.joined(separator: " "))
        lines.append(r.parts.count < 2 ? "Merged parts: none." : "Merged parts (\(r.parts.count)): " + r.parts.enumerated().map { n, p in
            "\(n + 1). From \(seconds(p.offset)), \(f.string(from: p.start)) to \(f.string(from: p.end))."
        }.joined(separator: " "))
        guard !parts.isEmpty else { return lines.joined(separator: "\n") }
        let sorted = cuts.map(\.at).sorted()
        let borders = [0] + sorted + [length]
        lines.append("Parts to make: \(parts.count).")
        for (k, p) in parts.enumerated() where k + 1 < borders.count {
            let from = borders[k], to = borders[k + 1]
            lines.append("  \(k + 1). \(p.id): \(seconds(from)) to \(seconds(to)) (\(span(to - from))), \(f.string(from: p.start)) to \(f.string(from: p.end)).")
        }
        for (k, at) in sorted.enumerated() where k + 1 < parts.count {
            lines.append("Cut \(k + 1) at \(seconds(at)) of the audio, \(f.string(from: parts[k + 1].start)) on the clock.")
        }
        return lines.joined(separator: "\n")
    }

    /// The whole command. Returns the text to print and the exit code: 0 done, 1 refused or failed, 2 a usage error.
    public static func run(_ arguments: [String], paths: Paths, ownerName: String) async -> (text: String, status: Int32) {
        let args: Arguments
        switch parse(arguments) {
        case let .failure(error): return (error.text, 2)
        case let .success(a): args = a
        }
        let cuts = args.times.map { Cut(at: $0, link: nil) }
        if args.dryRun {
            // Reads only: the app may be open.
            let pipeline = makePipeline(paths: paths, library: VoiceLibrary(directory: paths.voices), ownerName: ownerName)
            let plan = await pipeline.cutPlan(callID: args.callID, at: cuts)
            return text(plan, cuts: cuts, dryRun: true)
        }
        // One writer: the app holds these files in memory while it runs.
        switch InstanceLock.acquire(root: paths.root) {
        case .taken: return ("Mossad is open. Quit Mossad first: it holds these files.", 1)
        case .failed(let code): return ("Could not lock \(paths.root.path): \(String(cString: strerror(code)))", 1)
        case .held(let lock):
            defer { withExtendedLifetime(lock) {} }
            let library = VoiceLibrary(directory: paths.voices)
            // The people and the voice samples, as at a launch of the app, so the samples of a written meeting can go.
            // Without them the cut still makes the parts; the rest of the removal goes on at the next launch.
            if let identity = PeopleMigration.runAtLaunch(paths: paths, library: library, ownerName: ownerName, notDuplicates: []) {
                library.identity = identity
            }
            let pipeline = makePipeline(paths: paths, library: library, ownerName: ownerName)
            // A cut that a quit stopped earlier ends first, as at a launch.
            await pipeline.finishInterruptedCuts()
            let plan = await pipeline.cutPlan(callID: args.callID, at: cuts)
            if plan.refusal != nil { return text(plan, cuts: cuts, dryRun: false) }
            do {
                let ids = try await pipeline.cut(callID: args.callID, at: cuts)
                let left = FileManager.default.fileExists(atPath: paths.callDirectory(args.callID).path)
                return (text(plan, cuts: cuts, dryRun: false).0 + "\nMade the parts: \(ids.joined(separator: ", ")). Mossad processes them at its next launch."
                    + (left ? "\nThe removal of \(args.callID) waits for a step; Mossad goes on with it at its next launch." : ""), 0)
            } catch {
                return (text(plan, cuts: cuts, dryRun: false).0 + "\n" + error.localizedDescription, 1)
            }
        }
    }

    private static func text(_ plan: (refusal: String?, record: CallRecord?, length: TimeInterval, parts: [CallRecord]), cuts: [Cut], dryRun: Bool) -> (String, Int32) {
        var out = plan.record.map { planText(record: $0, length: plan.length, parts: plan.parts, cuts: cuts) } ?? ""
        if let why = plan.refusal { return ((out.isEmpty ? "" : out + "\n") + "Refused: \(why) Nothing was changed.", 1) }
        if dryRun { out += "\nNothing was changed (--dry-run)." }
        return (out, 0)
    }

    /// The pipeline of the cut alone: it transcribes nothing, reads no calendar, and makes no voice.
    private static func makePipeline(paths: Paths, library: VoiceLibrary, ownerName: String) -> Pipeline {
        Pipeline(paths: paths, transcriber: NoTranscriber(), library: library, embeddings: NoEmbeddings(), calendar: NoCalendar(),
                 summarizer: nil, notify: { _ in }, ownerName: ownerName, heavy: HeavyWorkGate())
    }

    private struct NotHere: Error {}

    private struct NoTranscriber: Transcribing {
        var serviceName: String { "none" }
        var runsOnThisDevice: Bool { true }
        func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] { throw NotHere() }
        func transcribe(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] { throw NotHere() }
    }

    private struct NoEmbeddings: EmbeddingProvider {
        func embedding(for samples: [Float]) async throws -> [Float] { throw NotHere() }
    }

    private struct NoCalendar: CalendarSource {
        func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
        func canRead() async -> Bool { false }
    }
}
