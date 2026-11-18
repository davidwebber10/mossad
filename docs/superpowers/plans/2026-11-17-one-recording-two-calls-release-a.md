# One recording, two calls, release A: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two calls that follow each other in one recording become two meetings by themselves, with no audio lost,
and the meeting of 2026-11-17 can be repaired with one command.

**Architecture:** The recorder keeps one recording and writes a mark when the call changes. When the recording
ends, a pure rule (`CutPlan`) reads the marks and the calendar. A resumable step (`RecordingCut`, in the pattern of
`Pipeline.merge`) makes the parts before transcription; each part goes through the pipeline as its own call.

**Tech stack:** Swift 6, `Packages/MossadCore` (all logic and tests), AVFAudio for the ranged copy, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-17-one-recording-two-calls-design.md` (Parts 1, 2, 3, "A recording
marked for another profile", and the repair). Part 4 (the extension) is release B and is not in this plan.

## Global constraints

- Never lose audio: the original recording is removed only after every part is on disk and checked.
- A mark never ends a recording and never starts one. The one exception is the do-not-record rule on a sure mark.
- Unknown is not false. Never block the main thread. Each step saves before the next starts.
- Pure rules in MossadCore with table tests. Test first: see each new test fail before the code.
- New fields of `CallRecord` are optional and additive; `MovedRecord.fields` and `CutRecord.fields` give each a
  rule, and their tests must pass.
- No AI attribution, no em dashes, no real names in code, tests, or commits. Made-up names only.
- The call gate before each build or test, as its own command:
  `zsh /private/tmp/claude-501/-Users-davidwebber-Sites-mossad/870711b7-6021-48f5-a995-8342ff75601b/scratchpad/callgate.sh`.
- Builders never touch `~/Mossad*`, the real settings, the real Keychain, or the owner's browser, and never push.

## Review focus

1. A crash at each phase of the cut: after it, either the original is whole or every part is whole. Never neither.
2. The parts' audio adds up to the original's, sample for sample, for both tracks.
3. Two parts are never joined again (`cutFrom`), and a part is never cut again by its own old marks.
4. A recording with no mark, or with marks that the plan refuses, is processed exactly as today.
5. A mark that is not sure never ends a recording; a breakout room and a reload never cut one meeting.

---

### Task 1: the three fields

**Files:** `Records/CallRecord.swift`, `Profiles/MovedRecord.swift`, `Capture/CallRecorder.swift`;
tests `MovedRecordTests.swift`, a new `CallMarkTests.swift`, the recorder's tests.

**Produces (exact names, used by every later task):**
- `public struct PauseSpan: Codable, Equatable, Sendable { public var at: TimeInterval; public var from: Date; public var to: Date? }`
  (`at` is the second of the recording where the pause sits) and `CallRecord.pauses: [PauseSpan]?`.
- `public struct CallMark: Codable, Equatable, Sendable { public var at: TimeInterval; public var time: Date; public var link: String?; public var platform: Platform; public var source: Source; public var sure: Bool }`
  with `public enum Source: String, Codable, Sendable { case ext = "extension", tabs, title }`, and
  `CallRecord.callMarks: [CallMark]?`.
- `CallRecord.cutFrom: String?`.
- `CallRecorder.addCallMark(link: String?, platform: Platform, source: CallMark.Source, sure: Bool, at time: Date)`:
  writes the mark with the recorder's own second, through `edit`, like a bookmark. Nothing when no call records.
- `CallRecorder.pause` and `resume` write `pauses` (the open pause has `to == nil`; `end()` closes it).
- `MovedRecord.fields`: all three `.kept`.

- [ ] Tests first: a record with the three fields encodes and decodes; a record of an older build (no such keys)
  decodes with nil; the moved-record tests cover the three; the recorder writes a mark at its second and a pause
  span with both wall times.
- [ ] The code. The whole suite passes. Commit.

### Task 2: the cut of the audio and the frames

**Files:** new `Output/AudioCut.swift`, `Frames/FrameIndex.swift` (a `cut` beside `join` and `trim`); tests
`AudioCutTests.swift`, `FrameCutTests.swift`.

**Produces:**
- `enum AudioCut { static func copy(_ source: URL, from: TimeInterval, to: TimeInterval?, into target: URL) throws -> Int64 }`
  (returns the frames written; the same 16 kHz mono Int16 CAF as `TrackWriter` writes; streamed in buffers, never
  the whole file in memory; `to == nil` is the end) and `static func frames(_ url: URL) throws -> Int64`.
- `FrameStore.cut(in source: URL, from: TimeInterval, to: TimeInterval?, into target: URL) throws`: copies the
  frames of the range under names moved back by `from`, with their `frames.json`. The source is not changed.

- [ ] Tests first, with files made by the test: the frames of two ranges add up to the source's; the samples at a
  border are in exactly one part; a range past the end is refused; frames keep their text and move their offsets.
- [ ] The code. Commit.

### Task 3: what each part's record holds

**Files:** new `Records/CutRecord.swift`; `Capture/CallRecorder.swift` (make the rule of `freeCallID` usable as
`CallRecorder.freeID(for: Date, in: Paths) -> String`); tests `CutRecordTests.swift`.

**Consumes:** Task 1's fields. **Produces:**
- `enum CutRecord { enum Rule { case divided, same, first, cleared, special }; static let fields: [String: Rule] }`
  with a test, in the pattern of `MovedRecordTests.testEveryFieldOfARecordHasARule`, that every stored field of
  `CallRecord` has a rule.
- `struct Cut: Equatable, Sendable { var at: TimeInterval; var link: String? }`.
- `static func parts(of r: CallRecord, at cuts: [Cut], ids: [String], length: TimeInterval) -> [CallRecord]`: the
  spec's rules ("What each part gets" and "Details settled"): time fields divided and moved back, `start` and `end`
  from `pauses` (else start plus offset), `meetingID` of the first part kept and of a later part its cut's link,
  `cutFrom` the original's id, `status` `.recorded`, the owner's title and tags to the first part, everything
  derived cleared, `callMarks` and `pauses` divided so that a part never holds a mark at its own start.
- `static func refusal(_ r: CallRecord, cuts: [Cut], length: TimeInterval, hasTracks: Bool) -> String?`: the spec's
  "Refused when" list, in plain words.

- [ ] Tests first: one table of field, rule, before, and after for a record with every field set (reuse
  `fullRecord()` of the moved-record tests); a bookmark on the cut goes to the later part; a merged meeting's
  `parts`; a pause before, across, and after the cut; two cuts.
- [ ] The code. Commit.

### Task 4: the cut step

**Files:** `Pipeline/Pipeline.swift` (or a new `Pipeline+Cut.swift`), `Records/MeetingMerge.swift`,
`Records/ProcessingQueue.swift`, new `Records/CallForget.swift`, `Profiles/MoveRemoval.swift`; tests
`RecordingCutTests.swift`, `MeetingMergeTests.swift`.

**Consumes:** Tasks 1 to 3. **Produces:**
- `Pipeline.cut(callID: String, at cuts: [Cut]) async throws -> [String]` (the parts' ids) and
  `Pipeline.finishInterruptedCuts() async`, run where `finishInterruptedMerges` runs.
- The ledger `cut.json` in the original's folder: `CutLedger { ids, cuts, phase }` with phases `copying`,
  `checked`, `published`, `forgetting`, `removed`, saved before each phase's work starts.
- Parts are written to `Audio/<part id>.cutting/` and published by one rename each. `ProcessingQueue` never lists
  a `.cutting` folder, a folder with a ledger whose phase is before `removed` as pending, or a part before its
  original is gone.
- Before `published`: a stop rolls back (the `.cutting` folders go, the original is as it was). From `published`:
  a stop goes forward.
- `CallForget`: the removal steps of a written call that `MoveRemoval` runs today (voice samples of the call,
  coach, books, shares, backup, notes, folder), moved into one type that both use, with each step saved in the
  caller's ledger. For an original at `.recorded` only the folder step does work. The step for people is not run
  by a cut. The owner's ticks and live marks on points and the live chat go to the part in which they were made
  (`NextTimeBook`, `LivePointMarks`, `ChatStore`), by their time.
- **Delete uses it too** (the owner's decision: "yes delete removes"): `AppController.deleteMeeting` and the
  worker's mirror (`ProfileWorker.forget`) run `CallForget` for the deleted call, so its voice samples, tasks,
  points (the references of series and person points; a point for that one meeting goes), and chats go with it,
  beside what Delete removes today. No person is removed by Delete. The removal is resumable: a delete that a quit
  stops goes on at the next launch (a small ledger of deletes in progress, in the pattern of the move's ledger).
  Tests: after a delete, no sample, task, point reference, or chat of the call is left, and a person the call made
  is still there.
- `MeetingMerge.continues` never joins two spans with the same non-nil `cutFrom`.
- The copy runs through `HeavyWorkGate` (waits while a call records; background priority).

- [ ] Tests first, in temp folders (the pattern of the merge tests and `MoveTestSupport`): a cut of a recorded
  call gives two recorded parts whose tracks add up, and no original; a stop injected after each phase, then
  `finishInterruptedCuts`: before `published` the original is whole and no part exists, after it both parts are
  whole and the original is gone; a refused cut changes nothing; two parts with one link and `cutFrom` are not
  joined; a written original loses its tasks, chats of the call, voice samples of the call, and note, and a tick
  made after the cut time belongs to the second part.
- [ ] The code. The existing move tests still pass with `CallForget`. Commit.

### Task 5: the command

**Files:** `App/MossadApp.swift`, `Support/AppIdentity.swift` (`commands`), new `Records/CutCommand.swift` in
MossadCore for everything but the entry; tests `CutCommandTests.swift`.

**Produces:** `Mossad --cut <call id> --at <seconds>[,<seconds>…] [--dry-run]`. It takes the profile's folder lock
and refuses while Mossad is open (the words and the way of `--people-migration apply`). It prints the recording's
length, pauses, and merged parts, the parts it will make with their start times, and with `--dry-run` nothing
more. Without it, it runs `Pipeline.cut` and prints the parts' ids. The parts are processed at the next launch of
the app. `--profile <id>` as the other commands.

- [ ] Tests first for the argument parser and the printed plan (pure). The code. Commit.

### Task 6: the marks during a call

**Files:** new `Detection/CallLinkWatch.swift` and `Tests/…/CallLinkWatchTests.swift` taken from the branch
`fix/call-change` (commit b3aa65e: only the pure type and its tests, not the wiring), new
`Detection/CallTitleWatch.swift`, `Detection/DetectionService.swift`, `Detection/CallDetector.swift` only if an
event needs a place, `App/AppController.swift` (the event to the recorder); tests in `DetectionServiceTests`.

**Consumes:** Task 1's `addCallMark`. **Produces:**
- `CallLinkWatch.observe(_ tabs: [BrowserTab]?, at: Date) -> Decision`: as on the branch, plus the time: a pending
  change older than 10 s (`CallDetector.Config.goneReadingGap`) is forgotten. `Decision` is `none`,
  `adopt(String)`, `newCall(String, Platform)`.
- `CallTitleWatch.observe(_ titles: [String]?, at: Date) -> String?`: the new Meet title when the browser's
  windows showed one "Meet - …" title, now show another one, and did so on two readings within 10 s. Unknown
  changes nothing.
- A new event `DetectionEvent.marked(link: String?, platform: Platform, source: CallMark.Source, sure: Bool, at: Date)`.
  The service sends it for `newCall` (source `tabs`, sure) and for a title change (source `title`, not sure). The
  detector's state does not change: the call goes on. After a `newCall` the service's own link (`meetingID`, the
  mute target) follows the new link.
- The app hands the event to `recorder.addCallMark`.
- **Do not record:** on a sure mark the app asks the do-not-record gate for the new link, as at a start
  (`NoRecordGate`). When the gate says no, the recording ends by the normal end path. Not for a mark that is not
  sure.
- While a change waits, the tab cache is cleared at most once per tick; the probe's back-off holds.

- [ ] Tests first: the watch's table with times (the branch's cases, plus: two stray readings 3 minutes apart
  make no mark; unknown between two readings inside 10 s still marks); the title watch's table; the service: a
  new link marks and does NOT end the call, both links in a meeting marks nothing, a title change marks as not
  sure, a do-not-record link ends the recording at a sure mark and not at a title mark.
- [ ] The code. Commit.

### Task 7: the decision and the hook

**Files:** new `Records/CutPlan.swift`, `App/AppController.swift` (`endOfCall` and the launch recovery),
`Worker/ProfileWorker.swift` only if a worker can meet a recorded call with marks (it can: a profile that
recorded and was switched away), `Profiles/MoveAfterCall.swift` (held parts); tests `CutPlanTests.swift`.

**Consumes:** Tasks 1, 4, 6. **Produces:**
- `enum CutPlan { static func decide(_ r: CallRecord, events: [CalendarEventInfo], length: TimeInterval) -> (cuts: [Cut], reasons: [String]) }`:
  the spec's Part 3, pure.
- The hook: when a recording ends and before `process`, and for each `.recorded` record at launch that has
  `callMarks` and no `cutFrom`: `decide`, then `Pipeline.cut` when there are cuts, then `process` for each part.
  A failure of the cut leaves the original, logs one line, and processes it as one meeting. A part keeps no mark
  that its own cut used, so it is not cut again.
- A recording with `moveTo` and cuts: the cut runs first, and each part is held with the existing "Process here /
  Move to" row (the state of a guessed mark: read `MoveAfterCall.atEnd` and `MoveEnded.notSure`). Nothing of a
  held part is sent.
- The log line holds counts and reasons, never a title or a link.

- [ ] Tests first: the table of the spec (a sure mark cuts; back to the first link with no event for the other
  link is one meeting; a title mark cuts only with a calendar event that starts 10 minutes before to 15 minutes
  after it and with no return of the first title; marks near the start, the end, or each other; no mark; the
  replay of 2026-11-17 with made-up names and times).
- [ ] The code. The whole suite, the Mac build, the iPhone build. Commit.

### Task 8: words

- [ ] `AGENTS.md`: the rows for `.../Detection/`, `.../Records/`, `.../Pipeline/Pipeline.swift`, and the command
  in "Build and test", in the rows' own style.
- [ ] `website/content/site.json`: one detail on the recording feature in benefit words ("Two calls back to back
  become two meetings, each with its own notes"), with its source files. Not the home page.
- [ ] Commit.

## Order and builders

Task 1 first. Then two builders in parallel, each in its own worktree from Task 1's commit: tasks 2, 3, 4, 5 (the
cut), and task 6 (the marks). After both are reviewed and merged: tasks 7 and 8. Each group gets a Fable review
before its merge.
