import XCTest
@testable import MossadCore

final class MoveRulesTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private func record(_ status: CallStatus) -> CallRecord {
        CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 1800, status: status)
    }

    private func usage(_ purpose: UsageEvent.Purpose, call: String? = nil) -> UsageEvent {
        UsageEvent(date: t0, callID: call ?? id, service: .assemblyai, purpose: purpose, model: nil)
    }

    private func registry(home: URL) -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work"))
        var old = Profile(id: "5e6f7a8b", name: "Old", color: .green, root: "~/Mossad Old")
        old.removing = true
        r.profiles.append(old)
        return r
    }

    private func home() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveRulesTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWhatAProfileSentOfAMeeting() {
        XCTAssertEqual(MoveRules.sent(record(.written), hasLiveFile: false, usage: []), .all)
        XCTAssertEqual(MoveRules.sent(record(.failed), hasLiveFile: false, usage: []), .all)
        for s in [CallStatus.transcribed, .identified, .summarized] {
            XCTAssertEqual(MoveRules.sent(record(s), hasLiveFile: false, usage: []), .inWork)
        }
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: false, usage: []), .nothing)
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: true, usage: []), .live)
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: false, usage: [usage(.live)]), .live)
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: false, usage: [usage(.live, call: "20261102-090000")]), .nothing)
        var jobs = record(.recorded)
        jobs.transcriptionJobs = ["me": "j1"]
        XCTAssertEqual(MoveRules.sent(jobs, hasLiveFile: false, usage: []), .inWork)
        var track = record(.recorded)
        track.meUtterances = []
        XCTAssertEqual(MoveRules.sent(track, hasLiveFile: false, usage: []), .inWork)
        var tried = record(.recorded)
        tried.attempts = 1
        XCTAssertEqual(MoveRules.sent(tried, hasLiveFile: false, usage: []), .inWork)
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: true, usage: [usage(.transcription)]), .inWork)
    }

    func testTheOffer() {
        XCTAssertEqual(MoveRules.offer(record(.recording), busy: false, files: [], usage: [], move: nil), .hidden)
        var notes = record(.written)
        notes.source = CallRecord.geminiNotesSource
        XCTAssertEqual(MoveRules.offer(notes, busy: false, files: [], usage: [], move: nil), .refused(MoveWords.notesOnly))
        XCTAssertEqual(MoveRules.offer(record(.written), busy: true, files: [], usage: [], move: nil), .refused(MoveWords.inWork))
        XCTAssertEqual(MoveRules.offer(record(.written), busy: false, files: ["call.json", "merge.json"], usage: [], move: nil),
                       .refused(MoveWords.inWork))
        var unknown = record(.written)
        unknown.platform = .unknown
        XCTAssertEqual(MoveRules.offer(unknown, busy: false, files: [], usage: [], move: nil), .refused(MoveWords.inWork))
        XCTAssertEqual(MoveRules.offer(record(.written), busy: false, files: ["call.json", "notes.txt"], usage: [], move: nil),
                       .refused(MoveWords.unknownFile), "I6")
        XCTAssertEqual(MoveWords.unknownFile, "This meeting has a file that Mossad does not know, so it cannot move. The meeting stays here.")
        var waiting = MoveOut(callID: id, to: work, started: t0)
        waiting.state = .waiting
        XCTAssertEqual(MoveRules.offer(record(.written), busy: false, files: [], usage: [], move: waiting), .moving(to: work))
        var done = waiting
        done.state = .done
        XCTAssertEqual(MoveRules.offer(record(.written), busy: false, files: [], usage: [], move: done), .offer)
        var marked = record(.recorded)
        marked.moveTo = work
        XCTAssertEqual(MoveRules.offer(marked, busy: false, files: [], usage: [], move: nil), .moving(to: work))
        for r in [record(.written), record(.failed), record(.recorded)] {
            XCTAssertEqual(MoveRules.offer(r, busy: false, files: ["call.json", "me.caf"], usage: [], move: nil), .offer)
        }
        XCTAssertEqual(MoveRules.offer(record(.recorded), busy: false, files: ["call.json", "live.json"], usage: [], move: nil), .offer,
                       "only the live transcript went")
        XCTAssertEqual(MoveRules.offer(record(.transcribed), busy: false, files: [], usage: [], move: nil), .refused(MoveWords.inWork))
    }

    func testTheTargetsAreTheOtherLiveProfiles() {
        let r = registry(home: home())
        XCTAssertEqual(MoveRules.targets(r, active: Profile.defaultID).map(\.id), [work])
        XCTAssertEqual(MoveRules.targets(r, active: work).map(\.id), [Profile.defaultID])
        XCTAssertEqual(MoveRules.targets(ProfileRegistry(), active: Profile.defaultID), [])
    }

    func testWhoMayMove() {
        let h = home()
        let read = ProfileRegistry.Loaded(registry: registry(home: h), state: .read)
        let real = AppIdentity(bundleID: "com.dwebber.mossad", registry: read)
        XCTAssertTrue(MoveRules.mayMove(mode: .full, identity: real, registry: read))
        XCTAssertFalse(MoveRules.mayMove(mode: .inert, identity: real, registry: read))
        // A worker goes on with a move (`Duty.takeInMoved`) and never starts one.
        XCTAssertFalse(MoveRules.mayMove(mode: .worker, identity: real, registry: read))
        for state in [ProfileRegistry.State.none, .newer, .unreadable, .partial] {
            let other = ProfileRegistry.Loaded(registry: read.registry, state: state)
            XCTAssertFalse(MoveRules.mayMove(mode: .full, identity: real, registry: other), "\(state)")
        }
        let madeUp = AppIdentity(bundleID: "com.dwebber.mossad", arguments: ["--profile", work], registry: read, madeUpRegistry: true)
        XCTAssertFalse(MoveRules.mayMove(mode: .full, identity: madeUp, registry: read))
        let rehearsal = AppIdentity(bundleID: "com.dwebber.mossad.rehearsal", registry: read)
        XCTAssertFalse(MoveRules.mayMove(mode: .full, identity: rehearsal, registry: read))
        let preview = AppIdentity(bundleID: "com.dwebber.mossad", arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/made-up"],
                                  registry: read)
        XCTAssertFalse(MoveRules.mayMove(mode: .full, identity: preview, registry: read))
        let otherRoot = AppIdentity(bundleID: "com.dwebber.mossad", environment: ["MOSSAD_ROOT": "/tmp/made-up"], registry: read)
        XCTAssertFalse(MoveRules.mayMove(mode: .full, identity: otherRoot, registry: read))
    }

    /// I2: three answers. Only a registry read whole says "gone"; anything not known waits.
    func testTheTargetsFolder() throws {
        let h = home()
        let r = registry(home: h)
        let read = ProfileRegistry.Loaded(registry: r, state: .read)
        XCTAssertEqual(MoveRules.target(work, in: read, home: h), .unknown, "no folder now: not known, never gone")
        let folder = h.appendingPathComponent("Mossad Work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(MoveRules.target(work, in: read, home: h), .paths(Paths(root: folder)))
        XCTAssertEqual(MoveRules.target(work, in: read, home: h).plan, .live)
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Mossad Old"), withIntermediateDirectories: true)
        XCTAssertEqual(MoveRules.target("5e6f7a8b", in: read, home: h), .gone, "removing")
        XCTAssertEqual(MoveRules.target("9c9c9c9c", in: read, home: h), .gone, "not in a registry read whole")
        for state in [ProfileRegistry.State.none, .newer, .unreadable, .partial] {
            XCTAssertEqual(MoveRules.target(work, in: ProfileRegistry.Loaded(registry: r, state: state), home: h), .unknown, "\(state)")
            XCTAssertEqual(MoveRules.target("9c9c9c9c", in: ProfileRegistry.Loaded(registry: r, state: state), home: h), .unknown, "\(state)")
        }
        XCTAssertEqual(MoveRules.target(work, in: read, home: nil), .unknown, "no home: not known")
        XCTAssertEqual(MoveRules.target("5e6f7a8b", in: read, home: h).plan, .gone)
        XCTAssertEqual(MoveRules.target(work, in: read, home: nil).plan, .unknown)
        // A file in the folder's place is not a folder.
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        XCTAssertEqual(MoveRules.target(work, in: read, home: h), .unknown)
    }

    func testAMeetingThatFailedBeforeAnyUploadWasNotSent() {
        var early = record(.failed)
        early.failedStep = .recorded
        early.attempts = 3
        XCTAssertEqual(MoveRules.sent(early, hasLiveFile: false, usage: []), .nothing)
        XCTAssertEqual(MoveRules.sent(early, hasLiveFile: true, usage: []), .live)
        XCTAssertEqual(MoveRules.sent(early, hasLiveFile: false, usage: [usage(.transcription)]), .all)
        var jobs = early
        jobs.transcriptionJobs = ["me": "j1"]
        XCTAssertEqual(MoveRules.sent(jobs, hasLiveFile: false, usage: []), .all)
        var later = record(.failed)
        later.failedStep = .summarized
        XCTAssertEqual(MoveRules.sent(later, hasLiveFile: false, usage: []), .all)
        XCTAssertEqual(MoveRules.offer(early, busy: false, files: ["call.json", "me.caf"], usage: [], move: nil), .offer)
    }

    /// I7: the live title, chat, and points also send words; with a row of another purpose, more went.
    func testTheLiveSentenceSaysOnlyWhatIsKnown() {
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: true, usage: [usage(.live), usage(.question)]), .all)
        XCTAssertEqual(MoveRules.sent(record(.recorded), hasLiveFile: false, usage: [usage(.summary)]), .all)
    }

    func testThePaces() {
        XCTAssertEqual(MoveRules.look, 15)
        XCTAssertEqual(MoveRules.slowAfter, 60)
        XCTAssertEqual(MoveRules.resultShows, 8)
        XCTAssertEqual(MoveRules.refusalShows, 30)
    }

    func testTheWords() {
        XCTAssertEqual(MoveWords.menu, "Move to")
        XCTAssertEqual(MoveWords.confirm, "Move")
        XCTAssertEqual(MoveWords.cancelMove, "Cancel move")
        XCTAssertEqual(MoveWords.processHere, "Process here")
        XCTAssertEqual(MoveWords.notesOnly, "A meeting made from Gemini notes stays with its Google account.")
        XCTAssertEqual(MoveWords.inWork, "Mossad is working on this meeting. Move it when its notes are ready.")
        XCTAssertEqual(MoveWords.heldForGone, "This call was for a profile that is gone. Mossad does not process it until you choose.")
        XCTAssertEqual(MoveWords.title("Zebra budget", to: "Work"), "Move “Zebra budget” to “Work”?")
        XCTAssertEqual(MoveWords.sent(.all, from: "Mossad", to: "Work"),
                       "“Mossad” already sent this meeting to its transcription and notes services, and a move cannot take that back.")
        XCTAssertEqual(MoveWords.sent(.live, from: "Mossad", to: "Work"),
                       "The live transcript of this call went to the transcription service of “Mossad”. As far as Mossad knows, nothing else was sent.")
        XCTAssertEqual(MoveWords.sent(.nothing, from: "Mossad", to: "Work"),
                       "As far as Mossad knows, nothing of this meeting was sent from “Mossad”. “Work” does all the work with its own keys.")
        XCTAssertEqual(MoveWords.sent(.inWork, from: "Mossad", to: "Work"), MoveWords.inWork)
        XCTAssertEqual(MoveWords.leaves("Mossad"), "The meeting leaves “Mossad” with its tasks, its chats, and what Mossad learned from it.")
        XCTAssertEqual(MoveWords.row(to: "Work", waited: 5, copied: nil), "Moving to Work…")
        XCTAssertEqual(MoveWords.row(to: "Work", waited: 5, copied: 0.4), "Moving to Work… 40%")
        XCTAssertEqual(MoveWords.row(to: "Work", waited: 60, copied: nil), "Moving to Work… It arrives when “Work” is next open.")
        XCTAssertEqual(MoveWords.row(to: "Work", waited: 90, copied: 0.4), "Moving to Work… 40%")
        XCTAssertEqual(MoveWords.moved(to: "Work"), "Moved to Work")
        XCTAssertEqual(MoveWords.tooLate("Work"), "“Work” has the meeting already.")
        XCTAssertNil(MoveWords.refusal(.byOwner, target: "Work"))
        XCTAssertEqual(MoveWords.refusal(.targetGone, target: "Work"), "“Work” is no longer a profile. The meeting stays here.")
        XCTAssertEqual(MoveWords.refusal(.lost, target: "Work"), "The copy in “Work” is gone. The meeting stays here.")
        XCTAssertEqual(MoveWords.refusal(.refusedIDTaken, target: "Work"), "“Work” cannot take this meeting in. The meeting stays here.")
        XCTAssertEqual(MoveWords.refusal(.refusedUnreadable, target: "Work"), "“Work” could not read this meeting. The meeting stays here.")
        XCTAssertEqual(MoveWords.refusal(.refusedNotWhole, target: "Work"), "The copy in “Work” was not whole. The meeting stays here.")
        XCTAssertEqual(MoveWords.refusal(.noRoom, target: "Work"), "There is not enough room on this Mac to move the meeting. Nothing was moved.")
        XCTAssertEqual(MoveWords.refusal(.copyFailed, target: "Work"), "The copy did not match the meeting. Nothing was moved.")
        XCTAssertEqual(MoveWords.refusal(.backupFailed, target: "Work"),
                       "The recording is only in the backup, and Mossad could not get it. Nothing was moved.")
        for c in [MovePlan.Cancel.byOwner, .targetGone, .lost, .refusedIDTaken, .refusedUnreadable, .refusedNotWhole, .noRoom, .copyFailed,
                  .backupFailed] {
            XCTAssertFalse((MoveWords.refusal(c, target: "Work") ?? "").contains("—"), "no em dash")
        }
    }
}
