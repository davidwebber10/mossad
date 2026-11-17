# Phone Call Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A call recording shared from Notes to the iPhone app becomes a meeting on the Mac that says "Phone call", with the other person's voice named when the owner said who it was.

**Architecture:** The iPhone app declares that it opens audio files, so iOS hands it a copy. Pure rules in MossadCore (`CallImport`) decide the title, the start, the refusals, and the duplicates. The file goes into the room recorder's folder and outbox, and travels as a `Recording` record with three new optional fields. The Mac makes a `CallRecord` with `Platform.phoneCall`, processes it as a one-track recording, and reads the person as a sure invite of one.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, CloudKit, App Intents, XCTest. No new package.

**Spec:** `docs/superpowers/specs/2026-11-16-phone-call-import-design.md`. Read it whole before any task. Where this plan and the spec disagree, the spec wins, except for the points in "What the code contradicts".

**Branch:** `feature/phone-call-import`, made from `main`.

## Global Constraints

- Test first. Write the failing test, run it, then write the code.
- Pure logic goes in `Packages/MossadCore/`. The app targets hold views and wiring only.
- `cd Packages/MossadCore && swift test` must pass before every commit: the whole suite, not one file.
- No build, test, or preview while a call records. Before each `swift test`, `xcodebuild`, or preview, run the call gate script that your brief names. If it says a call records, wait.
- Never block the main thread: file reads, the hash, the copy, and the convert run off the main actor.
- No AI attribution, no em dashes, and no real names of people in commits, code, or tests. Use made-up names such as "Sam Carter".
- Secrets live only in the Keychain.
- `Mossad.xcodeproj` is generated from `project.yml`. Never edit or commit it.
- New Mac or iPhone view text sizes and gaps come from `SharedUI/Rhythm.swift` tokens where the code around them uses them.
- The website follows the app: `website/content/site.json` in the same branch, benefits and not mechanism.
- `AGENTS.md` rows are updated in the same branch.
- Never deploy `server/` from an agent session. This plan changes nothing in `server/`.
- Exact values from the spec: the words "Phone call"; the record fields `kind` (`room` or `phoneCall`), `person`, `personID`; `bundleID` stays `"iphone"`; the document type is `public.audio`, not in place; a saved voice of anyone else needs 0.80 and a lead of 0.08; the refusals "Mossad cannot read this audio file" and "This recording is already in Mossad" (shown with a period at the end, see "Choices"); the Shortcuts result "Added. Mossad sends it when you next open the app."
- Build checks (not verified by the plan's author, who could not build): Mac `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Debug -derivedDataPath build/dev build -quiet`; iPhone `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme MossadPhone -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone CODE_SIGNING_ALLOWED=NO build -quiet`. Expected for both: exit status 0 and no line with `error:`.
- Commit messages are one sentence in the repo's style, such as "A phone call recording keeps its kind and person on the way to the Mac".

## Review Focus

1. **A file whose only date is the share time.** The copy iOS hands over can have no date in its metadata and a file date of the moment of the share. Expected: the meeting never ends in the future, the screen says the time is not sure, and the owner can change it. Tests: `testAFileDateThatCannotBeTheStartIsReadAsTheShareTime`, `testAStartWhoseEndIsAfterNowMovesBack` (Task 2).
2. **The same file shared twice, and two recordings with one start second.** With dates that move, the spec's rule (same start, same length) does not catch a second share. And the Mac takes a second `rec-<id>` from the phone as already imported (`CloudSync.swift:497-503`), after which the phone deletes its audio. Expected: a second share is refused by content; another recording at a taken second still becomes its own meeting. Tests: `testTheSameFileSharedAgainIsRefusedWhateverItsDates`, `testAnotherRecordingAtATakenSecondStartsOneSecondLater` (Task 2).
3. **An import while the room recorder runs, or an app stopped in the middle of an import.** Expected: the recording in progress is not touched, the import is not recovered as an unfinished room recording, and a half copy is never a recording. Tests: `testAnImportedRecordingDoesNotTouchTheRecordingInProgress`, `testAdoptLeavesNothingInTheFolderWhenItFails` (Task 3).
4. **A store that refuses the new fields, against an upload that failed for another reason.** Both stores hide why a record was not saved (`CloudKitStore.swift:40-45`, `ServerStore.swift:180-182`). Expected: only a refusal of the fields sends the recording again without them; a dropped connection keeps the kind and the person for the next try. Tests: `testARefusalOfTheNewFieldsSendsTheRecordingAgainWithoutThem`, `testAnotherUploadFailureKeepsTheFields` (Task 4).
5. **A build that does not know phone calls, and a retried import.** An older Mac makes an "In person" meeting of the recording, and the phone must still settle it. A Mac import that failed is tried again from `PendingRecording.fields` (`SyncPayload.swift:128-134`), which today holds only start, end, and title. Expected: the phone deletes its copy when the in-person meeting comes back; a retried import is still a phone call with its person; a room recording from this build has no new keys. Tests: `testAPhoneCallThatAnOlderMacMadeInPersonStillSettles` (Task 8), `testAPhoneCallThatFailedToImportIsStillAPhoneCallOnTheRetry` (Task 6), `testARoomRecordingIsWrittenWithNoNewKeys` (Task 3).

## Choices made where the spec left one

- **The import may run while the room recorder records.** It writes its own file and its own outbox entry. The import screen shows over the recorder's screen.
- **The hint on the record:** `CallRecord.personHint` (`PersonHint`: `name`, `personID`), saved in `call.json`. The import also puts the person in `attendees` and `invitees`, so the note and the filter show who was on the call.
- **Convert on the phone** only when the file is not MPEG-4 audio, or when it is more than 4 times the bytes of a room recording of that length (more than 16,000 bytes a second). The Mac names every recording `.m4a` before it reads it (`CloudSync.swift:507`).
- **The screen:** a sheet with its own `NavigationStack`, built from `PhoneLabel`, `HairlineRow`, `PhoneFillButtonStyle`, `Space`, and `Rhythm`.
- **The phone's title is the owner's title:** it goes to `CallRecord.customTitle` for a phone call. A room recording keeps `calendarTitle` as today.
- **One track in the voice rules:** `InviteVoiceRules` counts only `them:` keys for the one voice left. A phone call has every voice on `me:`. The rules get a one-track mode. Nothing is inferred on the call that first enrols the owner: the voice that talks most can be the other person.
- **A phone call with no person** gets no invite for the voices, as a room recording.
- **An unknown platform** is `Platform.unknown`, shown as "Not known". It is no choice of the filter (`Platform.allCases` leaves it out).
- **Usage statistics:** a phone call counts in `inPerson`. The version 1 payload does not change.
- **A refusal is told from another failure** by a new `RecordStore.saveOne`, which throws the store's reason. For iCloud, the codes `invalidArguments` and `serverRejectedRequest`, or a message with "schema".
- **Duplicates also by content:** a SHA-256 of the handed file, kept in `Recordings/imported.json` while its recording is in the outbox or the meetings.
- **Words the spec does not fix:** the short-file refusal "This recording is shorter than a minute. Mossad does not keep a recording that short."; the two fixed refusals end with a period; the line for an unsure time "Check the time. The file does not say when the call started."
- **"Only digits"** in the title rule is read as "no letter", and a number after a say-nothing name is ignored ("New Recording 12").
- **The symbol:** the lists draw a dot, not a symbol. `PlatformDot` draws a small phone glyph for a phone call.
- **The Shortcuts action waits 20 seconds** for the upload before it gives its answer.
- **A room recording writes no `kind` key.** Absent means `room`.

## What the code contradicts

- The spec names `MeetingAnalytics`, the Meetings filter's size, and `NextTimeRules.ownerMissed` as rules that ask "is this in person?". None reads the platform (`NextTimeCheck.swift:108`). The real places are in Task 5.
- "By every rule of `InviteVoiceRules`" does not hold as written: `InviteVoiceRules.swift:344` and `:352-353` count only `them:` keys, and `Pipeline.swift:779-781` gives a one-track call no invite. Task 6 adds the mode.
- "A phone symbol in the lists": `SharedUI/Chip.swift:73-90` draws a dot for every platform, and `Platform.symbol` (`PhoneApp/Components.swift:5-12`) is used nowhere.
- "(the Mac would drop it)": the Mac import keeps a recording of any length (`PhoneRecording.swift:41-94`). The 60 s rule is at `CallRecorder.swift:446` and `ProcessingQueue.swift:68`. The phone still refuses under 60 s, as the room recorder does.
- "A title the owner typed on the phone is never replaced": today the phone's title is `calendarTitle` (`PhoneRecording.swift:87`), which `setInvite` replaces (`CallRecord.swift:327`).
- `CallRecord.swift:321` makes the untitled name from "\(platform.displayName) call", which would say "Phone call call".

## File structure

| File | Responsibility |
| --- | --- |
| `Packages/MossadCore/Sources/MossadCore/Room/CallImport.swift` (new) | The pure rules of an import: title, start, refusals, duplicates, convert, person choices, the plan. |
| `.../Room/CallImportFile.swift` (new) | `CallImport.File` and `CallImport.read`: what the phone reads of a handed file. |
| `.../Room/ImportMemory.swift` (new) | The content hashes of imported files. |
| `.../Room/Outbox.swift`, `.../Room/RoomAudio.swift` | `addFinished`, `arrived`; `adopt`. |
| `.../Sync/PhoneRecording.swift`, `RecordStore.swift`, `CloudKitStore.swift`, `CloudSync.swift`, `SyncPayload.swift` | The fields, `saveOne`, the second send, the retry. |
| `.../Detection/Platform.swift`, `.../Records/CallRecord.swift` | `phoneCall`, `unknown`, the words, `PersonHint`. |
| `.../Voices/InviteVoiceRules.swift`, `.../Calendar/CalendarMatcher.swift`, `.../Pipeline/Pipeline.swift` | The hint as an invite, the one-track mode, the narrower event rule. |
| `PhoneApp/CallImportScreen.swift` (new), `PhoneApp/AddRecordingIntent.swift` (new), `PhoneApp/PhoneStore+Import.swift` (new) | The screen, the Shortcuts action, the store's import. |

---

### Task 1: The proof on a real iPhone

The spec asks for this first. It is small: the document type, a reader of the file's values, and a bare screen. It ends with a STOP.

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Room/CallImport.swift` (only `public enum CallImport {}` with its doc comment)
- Create: `Packages/MossadCore/Sources/MossadCore/Room/CallImportFile.swift`
- Create: `PhoneApp/CallImportScreen.swift` (the check screen; Task 10 replaces its body)
- Modify: `project.yml` (the `MossadPhone` target, `info.properties`), `PhoneApp/Info.plist` (XcodeGen writes it), `PhoneApp/MossadPhoneApp.swift:39`, `PhoneApp/PhoneStore.swift` (one property)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/CallImportFileTests.swift`

**Interfaces:**
- Consumes: `RoomAudio.length(of url: URL) -> TimeInterval?`, `PhoneRecording.settings`.
- Produces:
  ```swift
  extension CallImport {
      public struct File: Equatable, Sendable {
          public var name: String              // the last path component
          public var typeIdentifier: String?   // the uniform type, such as "com.apple.m4a-audio"
          public var bytes: Int64?
          public var length: TimeInterval?     // nil when AVAudioFile cannot read it
          public var metadataDate: Date?       // the creation date in the audio's own metadata
          public var fileDate: Date?           // the file's creation date
          public init(name: String, typeIdentifier: String?, bytes: Int64?, length: TimeInterval?, metadataDate: Date?, fileDate: Date?)
      }
      /// Each value it cannot read is nil. Call it off the main actor.
      public static func read(_ url: URL) async -> File
  }
  struct IncomingAudio: Identifiable, Equatable { let url: URL; let id = UUID() }   // PhoneApp
  // PhoneStore: var incomingAudio: IncomingAudio?
  ```

- [ ] **Step 1: Write the failing tests** in `CallImportFileTests.swift`. The audio helper is the 3 second AAC file of `PhoneRecordingTests.phoneAudio()`, written to a folder as `Call with Sam Carter.m4a`.

```swift
func testAReadableFileGivesItsNameTypeSizeLengthAndFileDate() async throws {
    let f = await CallImport.read(url)
    XCTAssertEqual(f.name, "Call with Sam Carter.m4a")
    XCTAssertEqual(f.typeIdentifier, "com.apple.m4a-audio")
    XCTAssertGreaterThan(f.bytes ?? 0, 0)
    XCTAssertEqual(f.length ?? 0, 3, accuracy: 0.2)
    XCTAssertEqual(f.fileDate?.timeIntervalSinceNow ?? -999, 0, accuracy: 60)
    XCTAssertNil(f.metadataDate, "AVAudioFile writes no creation date: unknown is nil")
}
func testAFileThatIsNotAudioHasNoLength() async throws {   // the text "hello" saved as notes.m4a
    XCTAssertNil(f.length); XCTAssertEqual(f.bytes, 5); XCTAssertEqual(f.name, "notes.m4a")
}
func testAMissingFileGivesOnlyItsName() async {
    XCTAssertEqual(await CallImport.read(URL(fileURLWithPath: "/nonexistent/gone.m4a")),
                   CallImport.File(name: "gone.m4a", typeIdentifier: nil, bytes: nil, length: nil, metadataDate: nil, fileDate: nil))
}
```

- [ ] **Step 2: Run** `cd Packages/MossadCore && swift test --filter CallImportFileTests`. Expected: FAIL, "cannot find 'CallImport' in scope".

- [ ] **Step 3: Implement `CallImport.read`.** `typeIdentifier`, `bytes`, `fileDate` from `url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])`. `length` from `RoomAudio.length(of:)`. `metadataDate` from `AVURLAsset(url:).load(.creationDate)` and then its `.dateValue`.

- [ ] **Step 4: Run the filter again.** Expected: PASS, 3 tests.

- [ ] **Step 5: Declare the document type.** In `project.yml`, under `MossadPhone` > `info` > `properties`, add:

```yaml
        CFBundleDocumentTypes:
          - CFBundleTypeName: Audio
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.audio]
        LSSupportsOpeningDocumentsInPlace: false
```

Run `xcodegen generate --quiet` (it rewrites `PhoneApp/Info.plist`; it is not a build). Expected: `git status --short` lists only `project.yml`, `PhoneApp/Info.plist`, and this task's new files.

- [ ] **Step 6: The check screen.** `.onOpenURL` in `MossadPhoneApp.swift`: a file URL sets `store.incomingAudio = IncomingAudio(url: url)`; any other URL goes to `ChatLink.parse` as today. A `.sheet(item: $store.incomingAudio)` on the `TabView` shows `CallImportScreen(incoming:)`. `IncomingAudio` is declared in `PhoneApp/CallImportScreen.swift`. The screen reads the file with `CallImport.read` in a `.task` and shows seven lines, each with its label, selectable: Name, Type, Size (bytes), Length (seconds, one decimal), Metadata date, File date, Opened at (now). Dates show the day and the time with seconds; a nil value shows "None". A "Copy" button puts the seven lines on the pasteboard. "Done" deletes the file at `url` and closes. No unit test: the app targets have none.

- [ ] **Step 7: Run the whole suite and the iPhone build check.** Expected: `swift test` ends with "0 failures"; the build check exits 0.

- [ ] **Step 8: Commit.**

```bash
git add project.yml PhoneApp/Info.plist PhoneApp/CallImportScreen.swift PhoneApp/MossadPhoneApp.swift PhoneApp/PhoneStore.swift Packages/MossadCore
git commit -m "The iPhone app opens audio files and shows what iOS hands over"
```

- [ ] **Step 9: STOP. The owner checks on a real iPhone.** No agent can do this. Report that Task 1 is ready and give the owner "Owner steps, part 1" from the end of this plan. Do not start Task 2 before the owner's report.

**What the report decides.** No later task guesses these values.

| Reported value | Decides | Where |
| --- | --- | --- |
| "Mossad" does not show for "Share Audio" | The plan stops. The fallback is a share extension, which is a different plan. | |
| Type | Whether a call recording is copied or converted. `com.apple.m4a-audio` or `public.mpeg-4-audio`: copied. Any other: add nothing, `CallImport.converts` already converts it. | Task 2, Step 3 |
| Name | Whether the words of the name that are the same for every call join `CallImport.emptyNames`. | Task 2, Step 3 |
| Metadata date against the call's real start | `CallImport.metadataDate`: `.start` when it is the start, `.end` when it is the start plus the length, `.share` when it is the moment of the share. | Task 2, Step 3 |
| File date against the real start and "Opened at" | `CallImport.fileDate`, by the same three choices. | Task 2, Step 3 |
| The second share's dates | Nothing to set. The content rule of Task 2 holds either way. | |

---

### Task 2: `CallImport`, the rules of an import

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Room/CallImport.swift`
- Create: `Packages/MossadCore/Sources/MossadCore/Room/ImportMemory.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/CallImportTests.swift`

**Interfaces:**
- Consumes: `CallImport.File` (Task 1); `CallID.make(_:)`; `ProcessingQueue.minimumCallDuration` (60); `ListSearch`; `PersonNames.key(_:)`; `Person`.
- Produces (each struct has a public memberwise init):
  ```swift
  public enum CallImport {
      public static let placeholder = "Phone call"
      /// Lowercase names that say nothing.
      static let emptyNames: Set<String> = ["recording", "audio", "new recording"]
      public static func title(fileName: String) -> String            // "" when the name says nothing

      public enum DateMeaning: Sendable { case start, end, share }
      static let metadataDate: DateMeaning   // set from the owner's report; `.start` by the spec
      static let fileDate: DateMeaning       // set from the owner's report; `.start` by the spec
      public struct Start: Equatable, Sendable { public var date: Date; public var sure: Bool }
      public static func start(metadata: Date?, file: Date?, length: TimeInterval, now: Date,
                               metadataIs: DateMeaning = metadataDate, fileIs: DateMeaning = fileDate) -> Start

      public enum Refusal: Error, Equatable, Sendable { case unreadable, tooShort, duplicate; public var message: String }
      public struct Choice: Equatable, Sendable, Hashable { public var name: String; public var personID: String? }
      public struct Known: Equatable, Sendable { public var id: String; public var start: Date; public var end: Date }
      public struct Draft: Equatable, Sendable { public var file: File; public var title: String; public var start: Date; public var person: Choice? }
      /// What to save: a recording of whole seconds, with `title` nil when blank.
      public struct Plan: Equatable, Sendable {
          public var id: String; public var start: Date; public var end: Date
          public var title: String?; public var person: Choice?; public var convert: Bool
      }
      /// The one rule that the screen and the Shortcuts action run. `hash` is nil when the file could not be hashed.
      /// `outbox` and `meetings` are what the iPhone has: the recordings that wait, and the meetings from the Mac.
      public static func plan(_ draft: Draft, hash: String?, outbox: [Known], meetings: [Known],
                              memory: ImportMemory, now: Date) -> Result<Plan, Refusal>
      public static func converts(typeIdentifier: String?, bytes: Int64?, length: TimeInterval) -> Bool
      public static func choices(query: String, people: [Person], heard: [String], owner: String) -> [Choice]
      public static func typed(_ text: String, among choices: [Choice]) -> Choice?
      public static func resultWords(sent: Bool) -> String
  }
  public struct ImportMemory: Codable, Equatable, Sendable {
      public static let fileName = "imported.json"
      public init()
      public func id(of hash: String) -> String?
      public mutating func remember(hash: String, id: String)
      public mutating func keep(only ids: Set<String>)       // forgets a file whose recording is gone
      public static func hash(of url: URL) throws -> String   // SHA-256 as hex, read in chunks
      public static func load(from file: URL) -> ImportMemory // a missing or unreadable file is an empty memory
      public func save(to file: URL) throws
  }
  ```

- [ ] **Step 1: Write the failing tests** in `CallImportTests.swift`. `t0 = Date(timeIntervalSince1970: 1_800_000_000)`. `now = t0 + 10_000`. `file(_ length: TimeInterval? = 600, bytes: Int64 = 2_400_000, type: String? = "com.apple.m4a-audio")` makes a `File` named "Call.m4a". `draft(_ f: CallImport.File, title: String = "", start: Date = t0, person: CallImport.Choice? = nil)` makes a `Draft`. `plan(_ d: Draft, hash: String? = "h1", outbox: [CallImport.Known] = [], meetings: [CallImport.Known] = [], memory: ImportMemory = .init())` calls `CallImport.plan` with `now`. `start(metadata:file:metadataIs:fileIs:)` calls `CallImport.start` with `length: 600` and `now`.

```swift
func testTheTitleIsTheFileNameUnlessItSaysNothing() {
    for (name, title) in [("Call with Sam Carter.m4a", "Call with Sam Carter"), ("Recording.m4a", ""), ("audio.M4A", ""),
                          ("New Recording.m4a", ""), ("New Recording 12.m4a", ""), ("20261116 101500.m4a", ""),
                          ("+1 (555) 010-0199.m4a", ""), ("Budget v2.m4a", "Budget v2"), ("Sam.Carter.call.wav", "Sam.Carter.call"),
                          ("  Renewal terms .m4a", "Renewal terms"), ("", "")] {
        XCTAssertEqual(CallImport.title(fileName: name), title, name)
    }
    XCTAssertEqual(CallImport.placeholder, "Phone call")
}
// now = t0 + 10_000, length 600 in each start test
func testTheStartIsTheMetadataDateThenTheFileDate() {
    XCTAssertEqual(start(metadata: t0 + 0.7, file: t0 + 50, metadataIs: .start), .init(date: t0, sure: true))        // cut to the second
    XCTAssertEqual(start(metadata: t0 + 600, file: nil, metadataIs: .end), .init(date: t0, sure: true))
    XCTAssertEqual(start(metadata: nil, file: t0, fileIs: .start), .init(date: t0, sure: true))
    XCTAssertEqual(start(metadata: nil, file: t0 + 900, fileIs: .share), .init(date: t0 + 300, sure: false))
    XCTAssertEqual(start(metadata: nil, file: nil), .init(date: now - 600, sure: false))
}
func testAFileDateThatCannotBeTheStartIsReadAsTheShareTime() {   // Review Focus 1
    XCTAssertEqual(start(metadata: nil, file: now - 5, fileIs: .start), .init(date: now - 605, sure: false))
}
func testAnUnreadableOrShortFileIsRefusedWithItsWords() {
    XCTAssertEqual(plan(draft(file(nil))), .failure(.unreadable))
    XCTAssertEqual(plan(draft(file(59.4))), .failure(.tooShort))
    XCTAssertNotNil(try? plan(draft(file(60))).get())
    XCTAssertEqual(CallImport.Refusal.unreadable.message, "Mossad cannot read this audio file.")
    XCTAssertEqual(CallImport.Refusal.duplicate.message, "This recording is already in Mossad.")
    XCTAssertEqual(CallImport.Refusal.tooShort.message, "This recording is shorter than a minute. Mossad does not keep a recording that short.")
}
func testThePlanIsARecordingOfWholeSeconds() throws {
    let sam = CallImport.Choice(name: "Sam Carter", personID: "p1")
    XCTAssertEqual(try plan(draft(file(600.4), title: "  Renewal terms ", start: t0 + 0.6, person: sam)).get(),
                   .init(id: CallID.make(t0), start: t0, end: t0 + 600, title: "Renewal terms", person: sam, convert: false))
    XCTAssertNil(try plan(draft(file(), title: "  ")).get().title)
}
func testARecordingWithTheSameStartAndLengthIsADuplicate() {
    let same = CallImport.Known(id: CallID.make(t0), start: t0, end: t0 + 600)
    XCTAssertEqual(plan(draft(file(), start: t0 + 0.4), outbox: [same]), .failure(.duplicate))
    XCTAssertEqual(plan(draft(file()), meetings: [.init(id: "x", start: t0, end: t0 + 600)]), .failure(.duplicate))
}
func testTheSameFileSharedAgainIsRefusedWhateverItsDates() {   // Review Focus 2
    var memory = ImportMemory(); memory.remember(hash: "h1", id: "20270101-090000")
    let first = CallImport.Known(id: "20270101-090000", start: t0 - 5_000, end: t0 - 4_400)
    XCTAssertEqual(plan(draft(file()), outbox: [first], memory: memory), .failure(.duplicate))
    XCTAssertEqual(plan(draft(file()), meetings: [.init(id: "20270101-090000-iphone", start: t0 - 5_000, end: t0 - 4_400)], memory: memory), .failure(.duplicate))
    XCTAssertNotNil(try? plan(draft(file()), memory: memory).get(), "its recording is gone: the owner can add it again")
    XCTAssertNotNil(try? plan(draft(file()), hash: nil, outbox: [first], memory: memory).get(), "no hash, no content rule")
}
func testAnotherRecordingAtATakenSecondStartsOneSecondLater() throws {   // Review Focus 2
    let other = CallImport.Known(id: CallID.make(t0), start: t0, end: t0 + 90)
    let p = try plan(draft(file()), outbox: [other], meetings: [.init(id: CallID.make(t0 + 1) + "-iphone", start: t0 + 1, end: t0 + 31)]).get()
    XCTAssertEqual(p.start, t0 + 2); XCTAssertEqual(p.id, CallID.make(t0 + 2)); XCTAssertEqual(p.end, t0 + 602)
}
func testAStartWhoseEndIsAfterNowMovesBack() throws {   // Review Focus 1
    XCTAssertEqual(try plan(draft(file(), start: now - 10)).get().start, now - 600)
}
func testOnlyAFileThatIsNotMPEG4OrIsMuchLargerIsConverted() {
    XCTAssertFalse(CallImport.converts(typeIdentifier: "com.apple.m4a-audio", bytes: 2_400_000, length: 600))
    XCTAssertFalse(CallImport.converts(typeIdentifier: "public.mpeg-4-audio", bytes: 9_600_000, length: 600))   // 16,000 bytes a second
    XCTAssertTrue(CallImport.converts(typeIdentifier: "com.apple.m4a-audio", bytes: 12_000_000, length: 600))
    XCTAssertTrue(CallImport.converts(typeIdentifier: "com.microsoft.waveform-audio", bytes: 100_000, length: 600))
    XCTAssertTrue(CallImport.converts(typeIdentifier: nil, bytes: nil, length: 600))
}
func testThePersonChoices() {
    // people: Sam Carter (id "p1"), Sara Lund ("p2"), the owner Avery Webb, and "Samuel Carter" merged into p1
    XCTAssertEqual(CallImport.choices(query: "sa", people: people, heard: ["Jo Fenwick"], owner: "Avery Webb"),
                   [.init(name: "Sam Carter", personID: "p1"), .init(name: "Sara Lund", personID: "p2")])
    XCTAssertEqual(CallImport.choices(query: "", people: people, heard: [], owner: "Avery Webb").map(\.name), ["Sam Carter", "Sara Lund"])
    XCTAssertEqual(CallImport.choices(query: "carter s", people: people, heard: [], owner: "Avery Webb").map(\.name), ["Sam Carter"])
    // iCloud: no saved people on the phone, so the named speakers, without the owner and without an id
    XCTAssertEqual(CallImport.choices(query: "", people: [], heard: ["Sam Carter", "Avery Webb", "Jo Fenwick"], owner: "Avery Webb"),
                   [.init(name: "Jo Fenwick", personID: nil), .init(name: "Sam Carter", personID: nil)])
    let known = [CallImport.Choice(name: "Sam Carter", personID: "p1")]
    XCTAssertEqual(CallImport.typed("  sam carter ", among: known), known[0])
    XCTAssertEqual(CallImport.typed(" Mom ", among: known), .init(name: "Mom", personID: nil))
    XCTAssertNil(CallImport.typed("   ", among: known))
}
func testTheShortcutsResultWords() {
    XCTAssertEqual(CallImport.resultWords(sent: true), "Added to Mossad.")
    XCTAssertEqual(CallImport.resultWords(sent: false), "Added. Mossad sends it when you next open the app.")
}
func testTheImportMemory() throws {
    // remember, id(of:), keep(only:) forgets the others, save and load give the same value,
    // load of a file with the text "{" gives ImportMemory(), and two files with the same bytes have one hash
}
```

- [ ] **Step 2: Run** `swift test --filter CallImportTests`. Expected: FAIL, "type 'CallImport' has no member 'title'".

- [ ] **Step 3: Implement.** The rules that the tests do not fix:
  - `title`: drop the last extension and trim. Take away digits and punctuation, lowercase, and join the words with one space: when that is empty or in `emptyNames`, the title is "".
  - `start`: the metadata date when there is one, else the file date, each by its meaning (`.start`: the date; `.end`: the date minus the length; `.share`: the date minus the length, not sure). A `.start` date whose end is after `now` is read as `.share`. With no date: `now` minus the length, not sure. Cut to the whole second.
  - `plan`, in this order: `unreadable` (no length); `tooShort` (under `ProcessingQueue.minimumCallDuration`); cut the start to the second, round the length to whole seconds, move a start whose end is after `now` back to `now` minus the length; `duplicate` when the memory knows `hash` for an id that is in the outbox or the meetings (an id with "-iphone" counts as the id), or when a recording of the outbox or a meeting has the same start second and the same rounded length; then move the start forward one second at a time until `CallID.make(start)` is no id of the outbox or the meetings, with or without "-iphone". `convert` is `converts(typeIdentifier:bytes:length:)` of the draft's file.
  - `choices`: with `people` not empty, the live people who are not the owner, by `ListSearch(query).match(title: displayName, fields: [their addresses])`, by name; else `heard` without `owner`, by name, with no id.
  - **From the owner's report (Task 1):** set `metadataDate` and `fileDate`, and add the fixed words of the reported file name to `emptyNames` when the name is the same for every call. Write the reported values in a comment above the two constants.

- [ ] **Step 4: Run the filter, then the whole suite.** Expected: PASS; "0 failures".

- [ ] **Step 5: Commit** with `git add Packages/MossadCore` and the message "The rules of a phone call import: its title, its start, what is refused, and what is a duplicate".

---

### Task 3: `PhoneRecording` gains its fields; the outbox and the folder take an imported file

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Sync/PhoneRecording.swift:6-17`, `.../Room/Outbox.swift` (after `finish`, line 75), `.../Room/RoomAudio.swift`
- Test: `PhoneRecordingTests.swift`, `OutboxTests.swift`, `RoomAudioTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // PhoneRecording
  public enum Kind: String, Codable, Sendable { case room, phoneCall }
  public var kind: Kind?          // nil is a room recording, as every payload from before
  public var person: String?
  public var personID: String?
  public init(id: String, start: Date, end: Date, title: String?, kind: Kind? = nil, person: String? = nil, personID: String? = nil)
  public init(_ plan: CallImport.Plan)                    // a phone call, with the plan's person
  public var isPhoneCall: Bool
  static let newFields = ["kind", "person", "personID"]
  var fields: [String: StoredValue]                        // start, end, title, and the new ones that are set
  init?(id: String, fields: [String: StoredValue])        // nil without start or end
  // Outbox
  public mutating func addFinished(_ recording: PhoneRecording)   // an entry in `.waiting`, for audio that is whole on disk
  // RoomAudio
  public struct Taken: Error {}
  /// Puts a file from outside in the folder as `<id>.m4a`: a copy as it is, or with `convert` an AAC file by
  /// `PhoneRecording.settings`. It is written in the temporary folder and moved in whole. The source stays.
  @discardableResult public static func adopt(_ source: URL, as id: String, in dir: URL, convert: Bool) throws -> TimeInterval
  ```

- Consumes: `CallImport.Plan`, `CallImport.Choice` (Task 2).

- [ ] **Step 1: Write the failing tests.** `call` is `PhoneRecording(id: "20270115-090000", start: t0, end: t0 + 600, title: nil, kind: .phoneCall, person: "Sam Carter", personID: "p1")`.

```swift
// PhoneRecordingTests
func testAPlanBecomesAPhoneCallRecording() {
    let plan = CallImport.Plan(id: "20270115-090000", start: t0, end: t0 + 600, title: nil, person: .init(name: "Sam Carter", personID: "p1"), convert: false)
    XCTAssertEqual(PhoneRecording(plan), call)
}
func testAPayloadFromBeforeTheNewFieldsStillReads() throws {
    let p = try JSONDecoder().decode(PhoneRecording.self, from: Data(#"{"id":"20270115-090000","start":0,"end":3,"title":"Offsite planning"}"#.utf8))
    XCTAssertNil(p.kind); XCTAssertNil(p.person); XCTAssertNil(p.personID); XCTAssertFalse(p.isPhoneCall)
}
func testAPhoneCallIsWrittenWithItsKindAndPerson() throws {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as! [String: Any]
    XCTAssertEqual(json["kind"] as? String, "phoneCall"); XCTAssertEqual(json["person"] as? String, "Sam Carter"); XCTAssertEqual(json["personID"] as? String, "p1")
    XCTAssertEqual(try JSONDecoder().decode(PhoneRecording.self, from: JSONEncoder().encode(call)), call)
}
func testARoomRecordingIsWrittenWithNoNewKeys() throws {   // Review Focus 5
    let room = PhoneRecording(id: "a", start: t0, end: t0 + 3, title: "Offsite")
    XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as! [String: Any]).keys), ["id", "start", "end", "title"])
    XCTAssertEqual(Set(room.fields.keys), ["start", "end", "title"])
}
func testAKindThisBuildDoesNotKnowReadsAsARoomRecording() throws {   // "kind":"voicemail"
    XCTAssertNil(p.kind)
}
func testTheStoreFieldsRoundTrip() {
    XCTAssertEqual(Set(call.fields.keys), ["start", "end", "kind", "person", "personID"])   // `call` has no title
    XCTAssertEqual(call.fields["kind"], .string("phoneCall"))
    XCTAssertEqual(PhoneRecording(id: call.id, fields: call.fields), call)
    XCTAssertNil(PhoneRecording(id: "a", fields: ["end": .date(t0)]))
}
// OutboxTests
func testAnImportedRecordingWaitsToUploadAtOnce() {
    var o = Outbox(); o.addFinished(call)
    XCTAssertEqual(o[call.id]?.state, .waiting); XCTAssertEqual(o.due(store: "icloud", now: t0).map(\.id), [call.id])
}
func testAnImportedRecordingDoesNotTouchTheRecordingInProgress() {   // Review Focus 3
    var o = Outbox(); o.begin(rec("a")); o.addFinished(rec("b"))
    XCTAssertEqual(o["a"]?.state, .recording)
    XCTAssertEqual(o.needsRecovery(audioIDs: ["a", "b"], active: "a"), [])
    XCTAssertEqual(o.due(store: "icloud", now: t0).map(\.id), ["b"])
    XCTAssertFalse(o.canRemove("a", active: "a", busy: [])); XCTAssertTrue(o.canRemove("b", active: "a", busy: []))
}
// RoomAudioTests
func testAdoptCopiesAnMPEG4FileAsItIs() throws {
    // source: the 3 s AAC file. adopt(convert: false) returns 3 ± 0.2; finished(id) has the source's bytes;
    // ids(in:) == [id]; the source still exists
}
func testAdoptConvertsAnotherFormat() throws {
    // source: writeTestAudio(dir/"call.caf", seconds: 3, frequency: 440, sampleRate: 44_100). adopt(convert: true):
    // finished(id) reads with AVAudioFile, sample rate 16_000, length 3 ± 0.2
}
func testAdoptNeverReplacesARecording() throws {
    // a second adopt with the same id throws RoomAudio.Taken, and the first file's bytes do not change
}
func testAdoptLeavesNothingInTheFolderWhenItFails() throws {   // Review Focus 3
    // source: the text "hello" as call.m4a, convert: true. It throws, and ids(in: dir) == []
}
```

- [ ] **Step 2: Run** `swift test --filter "PhoneRecordingTests|OutboxTests|RoomAudioTests"`. Expected: FAIL, "extra arguments at positions #5, #6, #7 in call".

- [ ] **Step 3: Implement.** `PhoneRecording` gets its own `init(from:)` that reads `kind` as text and maps a value it does not know to nil. `adopt` with `convert` uses the private `append(_:to:)` of `RoomAudio` and throws `Unreadable` when the read stops before the end of the source, as `finish` does.

- [ ] **Step 4: Run the filter, then the whole suite.** Expected: PASS; "0 failures".

- [ ] **Step 5: Commit** with the message "A phone recording can say that it is a phone call and who was on it; the outbox and the folder take a file from outside".

- [ ] **Added step (from the plan's check): the Mac never crashes on a file it cannot convert.** `PhoneRecording.importAudio` force-unwraps `AVAudioConverter(from:to:)` (`PhoneRecording.swift:49`), and after this plan any audio file can reach that line. Test first in `PhoneRecordingTests`: `testAFileTheConverterCannotTakeFailsTheImportAndLeavesNoCallFolder` (an input whose format gives no converter: `XCTAssertThrowsError` with `ConversionFailed`, and no `call.json` in the call's folder). Then replace the unwrap with a `guard` that throws `ConversionFailed(reason:)`; the same for the two buffers made with `!` beside it. Run the filter and the whole suite, and put it in this task's commit.

---

### Task 4: `CloudSync` sends the fields, and sends again without them after a refusal

**Files:**
- Modify: `.../Sync/RecordStore.swift:51-75`, `.../Sync/CloudKitStore.swift:24-47`, `.../Sync/CloudSync.swift:286-294` and `:419-425` and `:489-510`, `.../Sync/SyncPayload.swift:113-135`
- Test: `SyncSafetyTests.swift`, `RecordStoreTests.swift` (also the `MemoryStore` in it)

**Interfaces:**
- Consumes: `PhoneRecording.fields`, `PhoneRecording.newFields`, `PhoneRecording.init?(id:fields:)` (Task 3).
- Produces:
  ```swift
  public enum StoreRefusal: Error, Equatable { case unknownField }      // RecordStore.swift
  // protocol RecordStore, a new requirement with a default in the extension:
  /// Saves one record and throws why the store did not take it.
  func saveOne(_ record: StoredRecord) async throws
  // default: `save([record])`, and `ServerError.http(0, "The recording did not upload.")` when the name is not saved
  // CloudKitStore
  static func isUnknownField(_ error: Error) -> Bool   // CKError .invalidArguments or .serverRejectedRequest, or a message with "schema"
  // PendingRecording: var kind: String?, var person: String?, var personID: String? (last, so the memberwise init keeps its call sites)
  ```
  `CloudSync.upload(_ p: PhoneRecording, audio: URL) async throws` keeps its signature.

- [ ] **Step 1: Write the failing tests.** `MemoryStore` gets `func refuseFields(_ keys: Set<String>)` and its own `saveOne`, which throws `StoreRefusal.unknownField` when the record has one of those keys. `call` is `PhoneRecording(id: "20270115-090000", start: t0, end: t0 + 3, title: "Offsite", kind: .phoneCall, person: "Sam Carter", personID: "p1")`.

```swift
func testAPhoneCallUploadsWithItsFields() async throws {
    let f = await store.entries["rec-20270115-090000"]?.record.fields
    XCTAssertEqual(f?["kind"], .string("phoneCall")); XCTAssertEqual(f?["person"], .string("Sam Carter")); XCTAssertEqual(f?["personID"], .string("p1"))
}
func testARefusalOfTheNewFieldsSendsTheRecordingAgainWithoutThem() async throws {   // Review Focus 4
    await store.refuseFields(["kind", "person", "personID"])
    try await sync.upload(call, audio: try phoneAudio())                              // does not throw
    XCTAssertEqual(Set(await store.entries["rec-20270115-090000"]!.record.fields.keys), ["start", "end", "title"])
    XCTAssertNotNil(await store.asset("rec-20270115-090000", "audio"))
}
func testAnotherUploadFailureKeepsTheFields() async throws {   // Review Focus 4
    await store.refuse("rec-20270115-090000")
    do { try await sync.upload(call, audio: try phoneAudio()); XCTFail("must throw") } catch {}
    XCTAssertNil(await store.entries["rec-20270115-090000"], "nothing went without its fields")
    await store.refuse(nil)
    try await sync.upload(call, audio: try phoneAudio())
    XCTAssertEqual(await store.entries["rec-20270115-090000"]?.record.fields["kind"], .string("phoneCall"))
}
func testARecordingThatFailedToImportKeepsItsNewFieldsForTheRetry() async throws {
    // upload `call`; store.fail("rec-20270115-090000", with: URLError(.timedOut)); macSync.pull(includeMeetings: false)
    let p = try SyncState.load(from: mac.sync).recordings?.first
    XCTAssertEqual(p?.kind, "phoneCall"); XCTAssertEqual(p?.person, "Sam Carter"); XCTAssertEqual(p?.personID, "p1")
    XCTAssertEqual(p?.fields["kind"], .string("phoneCall"))
}
// RecordStoreTests (import CloudKit)
func testOnlyASchemaRefusalCountsAsAnUnknownField() {
    XCTAssertTrue(CloudKitStore.isUnknownField(CKError(.invalidArguments)))
    XCTAssertTrue(CloudKitStore.isUnknownField(CKError(.serverRejectedRequest)))
    for code in [CKError.Code.networkFailure, .networkUnavailable, .quotaExceeded, .zoneBusy, .requestRateLimited] {
        XCTAssertFalse(CloudKitStore.isUnknownField(CKError(code)))
    }
    XCTAssertFalse(CloudKitStore.isUnknownField(URLError(.timedOut)))
}
```

- [ ] **Step 2: Run** `swift test --filter "SyncSafetyTests|RecordStoreTests"`. Expected: FAIL, "value of type 'MemoryStore' has no member 'refuseFields'" until the store has it, then the assertions on the fields.

- [ ] **Step 3: Implement.**
  - `CloudKitStore.saveOne`: one `modifyRecords` call with the one record; a failed result throws `StoreRefusal.unknownField` when `isUnknownField` says so, else the error itself. Take the record mapping of `save` out into `static func record(_ r: StoredRecord) -> CKRecord` and use it in both.
  - `CloudSync.upload`: `saveOne` with `p.fields`. On `StoreRefusal.unknownField`, when the record had one of `PhoneRecording.newFields`: log "The store does not know the phone call fields yet; the recording goes without them" and `saveOne` again without those keys. Any other error is thrown as it is.
  - `CloudSync.keep(_:after:)` copies `kind`, `person`, `personID` from the record's fields into a new `PendingRecording`, and `PendingRecording.fields` gives them back.
  - `CloudSync.importRecording` makes its `PhoneRecording` with `PhoneRecording(id:fields:)` and then sets the id it chose.

- [ ] **Step 4: Run the filter, then the whole suite.** Expected: PASS; "0 failures".

- [ ] **Step 5: Commit** with the message "A phone call recording keeps its kind and person on the way to the Mac, and goes without them when the store refuses them".

---

### Task 5: `Platform.phoneCall`, a platform this build does not know, and one track

**Files:**
- Modify (core): `.../Detection/Platform.swift`, `.../Records/CallRecord.swift:321`, `.../Records/MeetingFilter.swift:385-393`, `.../Records/ProcessingProgress.swift:58-59`, `.../Telemetry/UsageStats.swift:122-127`, `.../Calendar/CalendarMatcher.swift:211`, `.../Detection/MeetingMatcher.swift:84`, `.../Detection/MeetingWindow.swift:212`, `.../Detection/MuteState.swift:52`, `.../Detection/AccessibilityMuteProbe.swift:196`, `.../Pipeline/Pipeline.swift:660` and `:710`, `.../Voices/InviteVoiceRules.swift:60`, `.../Sync/PhoneRecording.swift:86-87`
- Modify (apps, so both targets still compile): `SharedUI/Tokens.swift:80-87`, `SharedUI/Chip.swift:73-90`, `PhoneApp/Components.swift:5-12`, `PhoneApp/PhoneChrome.swift:86-93`, `App/ProcessingCard.swift:14` and `:120`, `App/TranscribeAgainSheet.swift:18` and `:42`, `App/AppController.swift:1190` and `:1761`
- Test: `PlatformTests.swift` (new), `PhoneRecordingTests.swift`, `ProcessingProgressTests.swift:36-39`, `UsageStatsTests.swift`, `MarkdownWriterTests.swift`, `MeetingFilterTests.swift`, `PipelineTests.swift`

**Interfaces:**
- Consumes: `PhoneRecording.isPhoneCall` (Task 3).
- Produces:
  ```swift
  public enum Platform: String, Codable, Sendable, CaseIterable {
      case zoom, meet, teams, inPerson, phoneCall
      /// A platform of a newer build. The meeting still reads.
      case unknown
      public static let allCases: [Platform] = [.zoom, .meet, .teams, .inPerson, .phoneCall]
      public init(from decoder: Decoder) throws        // a text it does not know is `.unknown`
      public var displayName: String                    // "Phone call"; "Not known"
      /// One track holds every voice: a room recording or a phone call.
      public var isOneTrack: Bool
      /// "your mic", "the room audio", "the call recording"
      public var micTrackName: String
      /// The title of a meeting with no title: "Zoom call", "In person call", "Phone call", "Call".
      public var untitled: String
  }
  // ProcessingProgress: func trackLine(_ track: Track, service: String, platform: Platform) -> String?   (was `room: Bool`)
  ```

- [ ] **Step 1: Write the failing tests.**

```swift
// PlatformTests
func testThePhoneCallsWords() {
    XCTAssertEqual(Platform.phoneCall.displayName, "Phone call"); XCTAssertEqual(Platform.phoneCall.filterName, "Phone call")
    XCTAssertEqual(Platform.phoneCall.untitled, "Phone call"); XCTAssertEqual(Platform.inPerson.untitled, "In person call")
    XCTAssertEqual(Platform.zoom.untitled, "Zoom call"); XCTAssertEqual(Platform.unknown.untitled, "Call")
    XCTAssertEqual(Platform.unknown.displayName, "Not known")
    XCTAssertEqual(Platform.allCases.filter(\.isOneTrack), [.inPerson, .phoneCall]); XCTAssertFalse(Platform.unknown.isOneTrack)
    XCTAssertEqual([Platform.zoom, .inPerson, .phoneCall].map(\.micTrackName), ["your mic", "the room audio", "the call recording"])
}
func testAPlatformThisBuildDoesNotKnowStillReads() throws {
    XCTAssertEqual(try JSONDecoder().decode([Platform].self, from: Data(#"["zoom","fax","phoneCall"]"#.utf8)), [.zoom, .unknown, .phoneCall])
    XCTAssertEqual(Platform.allCases, [.zoom, .meet, .teams, .inPerson, .phoneCall])
}
func testAMeetingWithAnUnknownPlatformIsNotLeftOut() throws {
    // save a .meet record, replace "platform":"meet" with "platform":"fax" in call.json
    XCTAssertEqual(try CallRecord.load(from: dir).platform, .unknown); XCTAssertEqual(try CallRecord.load(from: dir).title, "Call")
    XCTAssertEqual(try ProcessingQueue(paths: paths).scan().unreadable, [])
}
func testAnUntitledPhoneCallIsNamedOnce() {
    XCTAssertEqual(CallRecord(id: "a", platform: .phoneCall, bundleID: "iphone", start: t0, end: t0, status: .recorded).title, "Phone call")
}
// PhoneRecordingTests
func testAPhoneCallBecomesAPhoneCallRecordWithTheOwnersTitle() throws {
    let r = try PhoneRecording.importAudio(try phoneAudio(), recording: PhoneRecording(id: "20270115-090000", start: t0, end: t0 + 3,
                                           title: "Renewal terms", kind: .phoneCall), into: paths)
    XCTAssertEqual(r.platform, .phoneCall); XCTAssertEqual(r.bundleID, "iphone"); XCTAssertEqual(r.status, .recorded)
    XCTAssertEqual(r.customTitle, "Renewal terms"); XCTAssertNil(r.calendarTitle)
}
// ProcessingProgressTests: the three old lines with `platform: .zoom` and `.inPerson`, and
XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", platform: .phoneCall), "Uploading the call recording · 42%")
// UsageStatsTests: one more record("f", daysAgo: 3, minutes: 20, platform: .phoneCall) in the week of the test at line 60;
// that test's meeting count grows by 1 and its minutes by 20, and the key set of line 47 does not change
XCTAssertEqual(s.platforms7, .init(zoom: 1, meet: 1, teams: 1, inPerson: 2, geminiNotes: 1))
// MarkdownWriterTests
XCTAssertTrue(MarkdownWriter.render(phoneCall).contains("\nplatform: Phone call\n"))
// MeetingFilterTests.testChipWords
XCTAssertEqual(label(.platform(.phoneCall)), "Phone call")
// PipelineTests
func testTranscribeAgainOnAPhoneCallSendsTheCountWithTheOneTrack() async throws {   // as the room test at line 516, with .phoneCall
    XCTAssertEqual(transcriber.speakers[.me], 12)
}
```

- [ ] **Step 2: Run** `swift test --filter "PlatformTests|PhoneRecordingTests|ProcessingProgressTests|UsageStatsTests"`. Expected: FAIL, "type 'Platform' has no member 'phoneCall'".

- [ ] **Step 3: Implement in MossadCore.** In every switch of the Files list, `.phoneCall` and `.unknown` take the answer of `.inPerson` (no link markers, no window, no mute state), except: `UsageStats` counts `.phoneCall` in `inPerson` and `.unknown` nowhere. `Pipeline.swift:660` and `:710` and `InviteVoiceRules.swift:60` ask `isOneTrack` in place of `== .inPerson`. `Pipeline.swift:779` and `CalendarMatcher.swift:234` stay for Tasks 6 and 7. `PhoneRecording.importAudio`: a phone call gets `platform: .phoneCall` and its title in `customTitle`; a room recording is as before.

- [ ] **Step 4: Implement in the apps.** `Palette.platform`: `.phoneCall` and `.unknown` take `inPerson`'s color. `PlatformDot`: for `.phoneCall`, `Image(systemName: hollow ? "phone" : "phone.fill")` at font size `size + 3` in that color, with the same frame and label. `Platform.symbol`: "phone.fill" and "questionmark". `shortName` on the phone: "Phone call" and "Not known". `ProcessingCard`, `AppController.swift:1190` and `:1761`: `isOneTrack` and `trackLine(platform:)`. `TranscribeAgainSheet.swift:42`: "in the room" only for `.inPerson`; a phone call says "on the call, you included", and its count goes with the one track as a room's does.

- [ ] **Step 5: Run the whole suite and both build checks.** Expected: "0 failures"; both builds exit 0.

- [ ] **Step 6: Commit** with the message "A phone call is a platform of its own, and a platform this build does not know hides no meeting".

---

### Task 6: The person hint through `InviteVoiceRules`

**Files:**
- Modify: `.../Records/CallRecord.swift` (a property near line 303, one line in `init(from:)`, the struct near `GeminiNotesRef`), `.../Sync/PhoneRecording.swift:86-88`, `.../Voices/InviteVoiceRules.swift` (`CallInvite`, `InviteRoster.label`, `decide`), `.../Pipeline/Pipeline.swift:776-781`
- Test: `InviteVoiceRulesTests.swift`, `PipelineTests.swift`, `PhoneRecordingTests.swift`, `SyncSafetyTests.swift`

**Interfaces:**
- Consumes: `Platform.phoneCall`, `Platform.isOneTrack` (Task 5); `PhoneRecording.person`, `.personID` (Task 3).
- Produces:
  ```swift
  /// The one other person of a phone call, as the owner said on the iPhone.
  public struct PersonHint: Codable, Equatable, Sendable {
      public var name: String
      public var personID: String?
      public init(name: String, personID: String? = nil)
  }
  // CallRecord: public var personHint: PersonHint?      (decodeIfPresent)
  // CallInvite.Guest: public var byOwner: Bool          (a last init parameter, default false)
  // CallInvite: public var oneTrack = false
  //             public init(hint: PersonHint)           // one guest, byOwner, sure, oneTrack
  // InviteRoster: public var oneTrack: Bool             // from the invite
  ```
  `InviteVoiceRules.decide` and `SpeakerIdentifier.identify` keep their signatures.

- [ ] **Step 1: Write the failing tests.** In `InviteVoiceRulesTests`, `let sam = CallInvite(hint: PersonHint(name: "Sam Carter"))`.

```swift
func testThePhoneCallsPersonIsTheOneVoiceLeftBesideTheOwner() {
    let d = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [("Dale Fenwick", 0.3)])], sam)
    XCTAssertEqual(d.verdicts["me:B"], .inferred("Sam Carter", learn: true))
    XCTAssertEqual(d.inferred?.source, .owner); XCTAssertEqual(d.fromInvite, ["me:B"])
}
func testTwoVoicesLeftOnAPhoneCallNameNobody() {
    let d = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", []), voice("me:C", [])], sam)
    XCTAssertNil(d.inferred); XCTAssertEqual(d.verdicts["me:B"], .unknown); XCTAssertEqual(d.verdicts["me:C"], .unknown)
}
func testNothingIsInferredWhenTheOwnersVoiceIsNotFound() {   // also the call that first enrols the owner
    XCTAssertNil(decide([voice("me:B", [("Dale Fenwick", 0.3)])], sam).inferred)
}
func testAProvisionalVoiceOfThePersonIsNamedOnTheNextCallWithTheHint() {
    let all = profiles + [profile("Sam Carter")], made = ["Sam Carter": "call-1"]
    let voices = [voice("me:A", [(owner, 0.95)]), voice("me:B", [("Sam Carter", 0.7)])]
    XCTAssertEqual(decide(voices, sam, profiles: all, provisional: made).verdicts["me:B"], .named("Sam Carter", score: 0.7, learn: false))
    XCTAssertEqual(decide(voices, nil, profiles: all, provisional: made).verdicts["me:B"], .withheld(suggestion: VoiceScore(name: "Sam Carter", score: 0.7)))
}
func testAnotherSavedVoiceOnAPhoneCallNeedsTheStrongScoreAndTheLead() {
    let weak = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [("Dale Fenwick", 0.79), ("Mira Stone", 0.2)]), voice("me:C", [])], sam)
    XCTAssertEqual(weak.verdicts["me:B"], .withheld(suggestion: VoiceScore(name: "Dale Fenwick", score: 0.79)))
    let strong = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [("Dale Fenwick", 0.85), ("Mira Stone", 0.2)])], sam)
    XCTAssertEqual(strong.verdicts["me:B"], .named("Dale Fenwick", score: 0.85, learn: false)); XCTAssertNil(strong.inferred)
}
func testAPickedPersonGivesTheVoiceThatSavedPersonsName() {
    let p = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
    let d = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [])], CallInvite(hint: PersonHint(name: "Sam", personID: "p1")), people: [p])
    XCTAssertEqual(d.verdicts["me:B"], .inferred("Sam Carter", learn: true)); XCTAssertEqual(d.inferred?.source, .voiceNaming)
}
func testANameAsTypedIsUsedAsTypedAndAGuessJoinsNobody() {
    let mom = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [])], CallInvite(hint: PersonHint(name: "Mom")))
    XCTAssertEqual(mom.verdicts["me:B"], .inferred("Mom", learn: true))
    let mira = decide([voice("me:A", [(owner, 0.95)]), voice("me:B", [("Mira Stone", 0.7)])], CallInvite(hint: PersonHint(name: "Mira")))
    XCTAssertEqual(mira.verdicts["me:B"], .named("Mira Stone", score: 0.7, learn: false)); XCTAssertNil(mira.inferred)
}
// PhoneRecordingTests
func testThePhoneCallsPersonIsKeptOnTheRecord() throws {   // kind .phoneCall, person "Sam Carter", personID "p1"
    XCTAssertEqual(r.personHint, PersonHint(name: "Sam Carter", personID: "p1"))
    XCTAssertEqual(r.attendees, ["Sam Carter"]); XCTAssertEqual(r.invitees, [Invitee(name: "Sam Carter", email: nil, personID: "p1")])
    XCTAssertEqual(try CallRecord.load(from: dir).personHint, r.personHint, "it survives a restart between steps")
    // and a room recording with a person field (an older phone cannot send one, a wrong store can): personHint == nil
}
// SyncSafetyTests
func testAPhoneCallThatFailedToImportIsStillAPhoneCallOnTheRetry() async throws {   // Review Focus 5
    // as testAPhoneRecordingThatFailedIsTriedAgain...: upload `call` of Task 4, fail, pull, clear, advance 301, pull
    let r = try CallRecord.load(from: mac.callDirectory("20270115-090000"))
    XCTAssertEqual(r.platform, .phoneCall); XCTAssertEqual(r.personHint, PersonHint(name: "Sam Carter", personID: "p1"))
}
// PipelineTests: one track with two voices, the owner's voice saved
func testAPhoneCallWithAPersonNamesTheOneOtherVoice() async throws {
    try library.add([1, 0, 0, 0], to: "Avery Lane", isOwner: true)
    transcriber.result = [.me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Hello."),
                                Utterance(track: .me, speakerLabel: "B", start: 11, end: 35, text: "Hello, it is me.")], .them: []]
    // makeRecord(); then me.caf = writeSegments(total: 40, [(0, 10, 200), (11, 35, 400)]), them.caf = writeSegments(total: 40, []);
    // the record: platform .phoneCall, bundleID "iphone", personHint PersonHint(name: "Sam Carter")
    await pipeline().process(id)
    let r = try load(id)
    XCTAssertEqual(r.speakerNames, ["me:A": "Avery Lane", "me:B": "Sam Carter"]); XCTAssertEqual(r.fromInvite, ["me:B"])
    XCTAssertEqual(library.provisional["Sam Carter"], id)
}
func testAPhoneCallWithNoPersonKeepsTheRulesOfBefore() async throws {   // the same call, personHint nil
    XCTAssertNil(r.speakerNames["me:B"]); XCTAssertEqual(r.unknownSpeakers, ["me:B"]); XCTAssertNil(r.fromInvite)
}
```

- [ ] **Step 2: Run** `swift test --filter "InviteVoiceRulesTests|PipelineTests|PhoneRecordingTests"`. Expected: FAIL, "cannot find 'PersonHint' in scope".

- [ ] **Step 3: Implement.**
  - `PhoneRecording.importAudio`: for a phone call with a person that is not blank, set `personHint`, `attendees = [name]`, and `invitees = [Invitee(name: name, email: nil, personID: personID)]`.
  - `InviteRoster.label(of:among:)`: after the two rules that give a saved person's name, a `byOwner` guest gets its name as typed (trimmed) with the source `.owner`.
  - `InviteVoiceRules.decide`, when `roster.oneTrack`: the other people are on every key, so the two `hasPrefix("them:")` tests (lines 344 and 353) pass every key; and the rule of the one voice left runs only when one verdict is `.named` with the owner's name.
  - `Pipeline.identify` (line 779): `onCall` is `!r.platform.isOneTrack && !r.isNotesOnly`. The invite is `CallInvite(record:sure:)` on a call as today, `CallInvite(hint:)` for a phone call with a `personHint`, and nil otherwise.

- [ ] **Step 4: Run the filter, then the whole suite.** Expected: PASS; "0 failures". The tests of two-track calls in `InviteVoiceRulesTests` and `LiveVoiceRulesTests` pass with no change.

- [ ] **Step 5: Commit** with the message "The person the owner named for a phone call names the one other voice, by the rules of an invite".

---

### Task 7: The narrower calendar rule and the typed title

**Files:**
- Modify: `.../Calendar/CalendarMatcher.swift` (a new function after `match`, line 245; `:234` for `.phoneCall`), `.../Voices/InviteVoiceRules.swift:169` (`addresses(of:)` loses `private`), `.../Pipeline/Pipeline.swift:822-828`
- Test: `CalendarMatcherTests.swift`, `PipelineTests.swift`

**Interfaces:**
- Consumes: `PersonHint`, `CallRecord.personHint` (Task 6); `PersonDirectory.existing(name:email:among:)`; `InviteRoster.addresses(of:)`.
- Produces:
  ```swift
  extension CalendarMatcher {
      /// The event of a phone call: an overlapping event with no call link that invites exactly one person besides
      /// the owner, and, with a hint, only when that person is the hint's on a sure match. Nil otherwise.
      public static func phoneCallEvent(start: Date, end: Date, in events: [CalendarEventInfo], hint: PersonHint?, people: [Person]) -> CalendarEventInfo?
  }
  ```

- [ ] **Step 1: Write the failing tests.** `me = Invitee(name: "Avery Webb", email: "avery@example.com", isSelf: true)`, `sam = Invitee(name: "Sam Carter", email: "sam@example.com")`, `jo = Invitee(name: "Jo Fenwick", email: nil)`. `event(_ people: [Invitee], text: String = "")` is a timed event over the call. `found(_ e:, hint:, people: = [])` is `phoneCallEvent(...) != nil`.

```swift
func testAPhoneCallTakesOnlyAnEventWithItsOnePerson() {
    XCTAssertTrue(found(event([me, sam]), hint: PersonHint(name: "Sam Carter")))
    XCTAssertTrue(found(event([me, sam]), hint: PersonHint(name: "Carter, Sam")))
    XCTAssertTrue(found(event([me, sam]), hint: nil))
    XCTAssertTrue(found(event([me, sam, Invitee(name: "Room 4B", email: nil, kind: "room")]), hint: nil))
    XCTAssertFalse(found(event([me, sam, jo]), hint: PersonHint(name: "Sam Carter")), "two others")
    XCTAssertFalse(found(event([me, sam]), hint: PersonHint(name: "Jo Fenwick")), "another person than the hint")
    XCTAssertFalse(found(event([me, sam]), hint: PersonHint(name: "Sam")), "a guess joins nobody")
    XCTAssertFalse(found(event([]), hint: nil), "the owner's own block, such as Lunch")
    XCTAssertFalse(found(event([me]), hint: nil))
    XCTAssertFalse(found(event([me, sam], text: "https://meet.google.com/abc-defg-hij"), hint: nil), "a call with a link is another meeting")
}
func testAPickedPersonIsFoundByTheirAddress() {
    var p = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
    p.addEmail("sam@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
    let hint = PersonHint(name: "Sam", personID: "p1")
    XCTAssertTrue(found(event([me, Invitee(name: nil, email: "sam@example.com")]), hint: hint, people: [p]))
    XCTAssertFalse(found(event([me, Invitee(name: nil, email: "other@example.com")]), hint: hint, people: [p]))
}
func testTheInPersonRuleDoesNotChange() {   // the room event of line 97, with attendees: []
    XCTAssertEqual(CalendarMatcher.bestEvent(for: .inPerson, meetingID: nil, start: start, end: start.addingTimeInterval(1800), in: [room])?.title, "Budget review")
    XCTAssertNil(CalendarMatcher.bestEvent(for: .phoneCall, meetingID: nil, start: start, end: start.addingTimeInterval(1800), in: [room]),
                 "the general rule never gives a phone call an event")
}
// PipelineTests: makeRecord(), then the record as `importAudio` makes a phone call: platform .phoneCall, bundleID "iphone",
// customTitle "Renewal terms", personHint Sam Carter, attendees ["Sam Carter"]
func testAPhoneCallTakesTheEventOfItsOnePersonAndKeepsTheTypedTitle() async throws {
    // the calendar: "Sam and Avery" over the call, participants [Avery Lane (isSelf), Sam Carter], text ""
    XCTAssertEqual(r.calendarTitle, "Sam and Avery"); XCTAssertEqual(r.title, "Renewal terms"); XCTAssertEqual(r.invitees?.count, 2)
}
func testAPhoneCallDuringTheOwnersOwnBlockGetsNoEvent() async throws {   // the calendar: "Lunch", no participants
    XCTAssertNil(r.calendarTitle); XCTAssertEqual(r.attendees, ["Sam Carter"]); XCTAssertEqual(r.title, "Renewal terms")
}
```

- [ ] **Step 2: Run** `swift test --filter "CalendarMatcherTests|PipelineTests"`. Expected: FAIL, "type 'CalendarMatcher' has no member 'phoneCallEvent'".

- [ ] **Step 3: Implement.**
  - The candidates are those of the in-person rule (timed, overlap above 0, no call link of `Platform.callApps`). The guests are `participants` that are not the owner's own entry and are a person (`isPerson`); there must be exactly one. An event with no `participants` is never taken: its people are not known apart.
  - The sure match of a hint. With a `personID`: the live person of that id (follow `mergedInto`) has the guest's address among `InviteRoster.addresses(of:)`, or the guest has that `personID`, or `PersonDirectory.existing(name: guest.name, email: nil, among: [that person's display name])` is not nil. With a name only: `PersonDirectory.existing(name: hint.name, email: nil, among: [the guest's name])` is not nil.
  - Of several, the one with the most overlap.
  - `CalendarMatcher.match` gives a `.phoneCall` and an `.unknown` no candidates.
  - `Pipeline.matchInvite`: for a phone call, `phoneCallEvent` with `r.personHint` and `library.identity?.people.people ?? []`; on an event, `setInvite` and true; else false.

- [ ] **Step 4: Run the filter, then the whole suite.** Expected: PASS; "0 failures".

- [ ] **Step 5: Commit** with the message "A phone call takes a calendar event only when it invites its one person, and keeps the title the owner gave".

---

### Task 8: `settleOutbox` counts a phone call

**Files:**
- Modify: `.../Room/Outbox.swift` (beside `settle`, line 125), `PhoneApp/PhoneStore.swift:561-565`
- Test: `OutboxTests.swift`

**Interfaces:**
- Consumes: `Platform.isOneTrack` (Task 5).
- Produces: `public static func arrived(_ meetings: [CallRecord]) -> Set<String>` on `Outbox`: the ids of the meetings whose platform is one track.

- [ ] **Step 1: Write the failing tests.** `meeting(_ id: String, _ platform: Platform)` is a written `CallRecord` with `bundleID: "iphone"`.

```swift
func testAPhoneCallThatCameBackSettlesItsEntry() {
    var o = Outbox(); o.addFinished(call)                                   // id "20270115-090000", kind .phoneCall
    XCTAssertEqual(o.settle(arrived: Outbox.arrived([meeting("20270115-090000", .zoom)])), [], "a Mac call of the same second is another meeting")
    XCTAssertEqual(o.settle(arrived: Outbox.arrived([meeting("20270115-090000", .phoneCall)])), ["20270115-090000"])
    XCTAssertEqual(o.entries, [])
}
func testAPhoneCallThatAnOlderMacMadeInPersonStillSettles() {   // Review Focus 5
    var o = Outbox(); o.addFinished(call)
    XCTAssertEqual(o.settle(arrived: Outbox.arrived([meeting("20270115-090000-iphone", .inPerson)])), ["20270115-090000"])
}
```

- [ ] **Step 2: Run** `swift test --filter OutboxTests`. Expected: FAIL, "type 'Outbox' has no member 'arrived'".

- [ ] **Step 3: Implement `arrived`, and use it** in `PhoneStore.settleOutbox` in place of the filter on `.inPerson`. Change the comment above it to say "an in-person meeting or a phone call".

- [ ] **Step 4: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0.

- [ ] **Step 5: Commit** with the message "The iPhone deletes its copy of a phone call when its meeting comes back".

---

### Task 9: The iPhone store imports a file

**Files:**
- Create: `PhoneApp/PhoneStore+Import.swift`
- Modify: `PhoneApp/PhoneStore.swift` (`launch`, `joining`, and `saveOutbox` lose `private` for the extension; `static let shared`), `PhoneApp/MossadPhoneApp.swift:9`

**Interfaces:**
- Consumes: `CallImport.read`, `CallImport.plan`, `CallImport.Known`, `CallImport.choices`, `CallImport.typed`, `ImportMemory` (Tasks 1 and 2); `PhoneRecording.init(_ plan:)`, `RoomAudio.adopt`, `Outbox.addFinished` (Task 3).
- Produces (all on `PhoneStore`, main actor):
  ```swift
  static let shared = PhoneStore()                       // the App and the Shortcuts action use the one store
  var importMemoryFile: URL { recordingsFolder.appendingPathComponent(ImportMemory.fileName) }
  func importChoices(_ query: String) -> [CallImport.Choice]            // `people`, `personStats.keys`, `owner`
  /// A refusal the screen can show before the owner taps anything; nil when the file can be added.
  func importRefusal(_ draft: CallImport.Draft, from url: URL) async -> CallImport.Refusal?
  /// Adds the file. Returns the recording's id once the audio and the outbox entry are saved; the upload starts after.
  func importCall(_ draft: CallImport.Draft, from url: URL) async -> Result<String, CallImport.Refusal>
  func discardIncoming(_ url: URL)                                       // deletes the app's copy of the handed file
  /// Waits for the upload of one recording, at most `seconds`.
  func sent(_ id: String, within seconds: TimeInterval) async -> Bool
  ```

- [ ] **Step 1: Implement `importCall`.** No unit test: the app targets have none, and every rule it calls is tested in Tasks 2 and 3. The order is the contract:
  1. `await launch?.value`, so the outbox and the meetings are read.
  2. Off the main actor: `ImportMemory.hash(of: url)` (nil on a failure) and `ImportMemory.load(from:)`.
  3. `CallImport.plan(draft, hash:, outbox:, meetings:, memory:, now: Date())`, where `outbox` is each entry and `meetings` each meeting as a `CallImport.Known` (id, start, end). A refusal returns here with nothing saved. `importRefusal` is steps 1 to 3 alone.
  4. `joining.insert(plan.id)`, so the launch recovery leaves the new file alone; remove it at the end with `defer`.
  5. Off the main actor at `.utility`: `RoomAudio.adopt(url, as: plan.id, in: recordingsFolder, convert: plan.convert)`. A throw returns `.failure(.unreadable)`.
  6. `outbox.addFinished(PhoneRecording(plan))`, `saveOutbox()`.
  7. Remember the hash, call `keep(only:)` with the ids of the outbox and the meetings when `loaded`, and save the memory. A failed save is logged and does not fail the import.
  8. `discardIncoming(url)`.
  9. `Task { await sendOutbox() }`, and return `.success(id)`.
- [ ] **Step 2: Implement the rest.** `sent(_:within:)` runs `sendOutbox()` against a sleep and returns `outbox[id]?.isSent == true`. At launch, after `readOutbox`, a detached task deletes files in `Documents/Inbox` that are older than 24 hours. `MossadPhoneApp` holds `@State private var store = PhoneStore.shared`.
- [ ] **Step 3: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 4: Commit** with the message "The iPhone store adds a shared audio file to the recordings and the outbox".

---

### Task 10: The import screen

**Files:**
- Modify: `PhoneApp/CallImportScreen.swift` (replace the check screen of Task 1), `PhoneApp/MossadPhoneApp.swift` (the sheet), `PhoneApp/MeetingsListView.swift:110-116` (the row's title and day) and `:82` (the flag), `PhoneApp/RoomRecorder.swift:333` (`RecordingView` takes the sheet too), `PhoneApp/PhoneStore.swift` (`var recorderScreenOpen = false`)

**Interfaces:**
- Consumes: Task 9's `PhoneStore` members; `CallImport.title(fileName:)`, `CallImport.start(...)`, `CallImport.placeholder`, `CallImport.Draft`, `CallImport.Refusal.message` (Task 2); `duration(_:)` in `PhoneApp/Components.swift`.
- Produces: `struct CallImportScreen: View { init(incoming: IncomingAudio) }`; `extension View { func callImportSheet(when shows: Bool) -> some View }`; the hook `MOSSAD_IMPORT=<path to an audio file>` (through `PhoneStore.hook`), which opens the screen in the simulator.

- [ ] **Step 1: Build the screen.** No unit test: the screen holds no rule of its own. A `NavigationStack` in the sheet, title "Add call", "Cancel" in the bar (`.cancellationAction`), which calls `store.discardIncoming` and closes. Rows, top to bottom:
  - **Title:** `TextField(CallImport.placeholder, text: $title)`, first filled with `CallImport.title(fileName:)`.
  - **When:** a `DatePicker` for the day and the time, `in: ...Date()`, first set to `CallImport.start(metadata:file:length:now:).date`. Under it the length with `duration(_:)`, fixed. When the start is not sure, one more line in `.textRole(.secondary)` and `Palette.secondary`: "Check the time. The file does not say when the call started."
  - **Who was on the call:** shows the picked name, or "Optional". It pushes a list with `.searchable`: the rows of `store.importChoices(query)`, a first row `Use "<text>"` when `CallImport.typed(query, among:)` is no listed choice, and "Nobody" to clear it. One person at most.
  - **Add to Mossad:** `PhoneFillButtonStyle(wide: true)`. It calls `store.importCall`; while that runs the button is off and shows a `ProgressView`. On success the sheet closes, `store.tab = .meetings`, `store.path = []`. A refusal shows in the page in place of the rows, with one button "Close".
  - On appear the screen reads the file (`CallImport.read`), then asks `store.importRefusal` and shows a refusal at once, with nothing saved.
- [ ] **Step 2: Present it.** `callImportSheet(when:)` is `.sheet(item:)` on `store.incomingAudio`, bound only while `shows` is true. `MossadPhoneApp` uses it on the `TabView` with `!store.recorderScreenOpen`; `RecordingView` uses it with `true`. `MeetingsListView` sets `store.recorderScreenOpen` from its `recording` state with `.onChange(of: recording, initial: true)`. Another open sheet (Settings, Findings) delays the screen until it closes; the file waits in `store.incomingAudio`.
- [ ] **Step 3: The waiting row.** In the outbox list, a phone call with no title says "Phone call" in place of "In-person meeting", and a recording of another day than today shows its day before the time.
- [ ] **Step 4: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0. With the gate clear, a simulator run with `MOSSAD_ROOT` on a made-up folder and `MOSSAD_IMPORT` on a 3 second test file must show the refusal "This recording is shorter than a minute. Mossad does not keep a recording that short."
- [ ] **Step 5: Commit** with the message "The import screen: a shared call recording becomes a meeting with one button".

---

### Task 11: The Shortcuts action

**Files:**
- Create: `PhoneApp/AddRecordingIntent.swift`

**Interfaces:**
- Consumes: `PhoneStore.shared`, `importCall`, `importChoices`, `sent(_:within:)` (Task 9); `CallImport.read`, `title(fileName:)`, `start(...)`, `typed(_:among:)`, `resultWords(sent:)`, `Refusal.message` (Task 2).
- Produces:
  ```swift
  struct AddRecordingIntent: AppIntent {
      static let title: LocalizedStringResource = "Add recording to Mossad"
      static let openAppWhenRun = false
      @Parameter(title: "Audio", supportedContentTypes: [.audio]) var audio: IntentFile
      @Parameter(title: "Title") var title: String?
      @Parameter(title: "Start") var start: Date?
      @Parameter(title: "Person") var person: String?
      @MainActor func perform() async throws -> some IntentResult & ProvidesDialog
  }
  ```

- [ ] **Step 1: Implement `perform`.** No unit test: its words and its rules are tested in Task 2 (`testTheShortcutsResultWords`, the plan tests). Write `audio.data` to a new folder in the temporary directory under `audio.filename`, so the title rule sees the name. Read it with `CallImport.read`. The title is the parameter, else `CallImport.title(fileName:)`. The start is the parameter, else `CallImport.start(...).date`. The person is `CallImport.typed(person, among: store.importChoices(person))`, so a whole saved name carries its id. Call `importCall`. A refusal throws an error whose `localizedStringResource` is `refusal.message`. On success, `let sent = await store.sent(id, within: 20)` and the dialog is `CallImport.resultWords(sent: sent)`. No `AppShortcutsProvider`: the action shows in Shortcuts without one.
- [ ] **Step 2: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 3: Commit** with the message "A Shortcuts action adds a recording to Mossad with no screen".

---

### Task 12: Words: `AGENTS.md` and the website

**Files:**
- Modify: `AGENTS.md` (the rows `.../Sync/`, `.../Room/`, `PhoneApp/`, `.../Voices/`, `.../Detection/`, and "Reading meeting notes"), `website/content/site.json` (the `iphone` group, line 685, and the FAQ answer at line 1044)

- [ ] **Step 1: `AGENTS.md`.** Add, in the rows' own style:
  - `.../Sync/`: `PhoneRecording` has `kind`, `person`, `personID`; a phone call becomes a `CallRecord` with `Platform.phoneCall`, the title in `customTitle`, and `personHint`; `CloudSync.upload` sends the fields and, on `StoreRefusal.unknownField` from `RecordStore.saveOne`, sends again without them; `PendingRecording` keeps them for a retry.
  - `.../Room/`: `CallImport` (pure: title, start, refusals, duplicates, convert, person choices, `plan`), `ImportMemory`, `RoomAudio.adopt`, `Outbox.addFinished` and `Outbox.arrived`.
  - `PhoneApp/`: `CallImportScreen` (opens for an audio file shared to Mossad; the document type is in `project.yml`), `PhoneStore+Import.swift`, `AddRecordingIntent`; the hook `MOSSAD_IMPORT`.
  - `.../Voices/`: a phone call with a `personHint` is a sure invite of that one person on one track (`CallInvite.init(hint:)`, `oneTrack`); nothing is inferred when the owner's voice is not found.
  - `.../Detection/`: `Platform.phoneCall`, `Platform.unknown`, `isOneTrack`; `CalendarMatcher.phoneCallEvent`.
  - "Reading meeting notes": a phone call has `platform: Phone call`, and every voice is on one track.
- [ ] **Step 2: `site.json`.** One feature in the `iphone` group, after `room-recorder`:

```json
{
  "id": "phone-call-import",
  "title": "Your phone calls, too",
  "body": "Share a call recording from Notes to Mossad, and the call becomes a meeting with its note.",
  "details": [
    "Say who was on the call, and Mossad names their voice",
    "A Shortcuts action adds a recording with no screen"
  ],
  "icon": "phone",
  "comingSoon": false,
  "sources": ["PhoneApp/CallImportScreen.swift", "PhoneApp/AddRecordingIntent.swift", "Packages/MossadCore/Sources/MossadCore/Room/CallImport.swift", "Packages/MossadCore/Sources/MossadCore/Sync/PhoneRecording.swift"]
}
```

  The group's `intro` becomes "Your meetings on your phone, a recorder for the meetings in a room, and your phone calls as meetings." The FAQ answer at line 1044 gains "and it turns a recorded phone call into a meeting".
- [ ] **Step 3: Check.** `python3 -m json.tool website/content/site.json > /dev/null` exits 0. Run the whole suite. Expected: "0 failures".
- [ ] **Step 4: Commit** with the message "AGENTS.md and the website say what the phone call import adds".

---

## Owner steps

**Part 1, after Task 1: the check on a real iPhone.**

1. On the Mac, in the repository on the branch `feature/phone-call-import`: run `xcodegen generate`. Open `Mossad.xcodeproj`. Choose the scheme `MossadPhone` and your iPhone. Run.
2. On the iPhone, record a short call (longer than one minute), or use one that iOS recorded. From Phone > Recents, write down the time the call started and its length.
3. Close Mossad on the iPhone. In Notes, open the note of the call. Open the menu of the recording and tap "Share Audio".
4. Look for "Mossad" in the row of apps. Look under "More" too.
5. Tap "Mossad". The screen "Import check" opens. Tap "Copy". Tap "Done".
6. With Mossad still open in the background, share the same recording again. Tap "Copy" again. Tap "Done".
7. Report these items:
   - Does "Mossad" show for "Share Audio"? Where (the row, or "More")?
   - The seven lines of the first share and of the second share: Name, Type, Size, Length, Metadata date, File date, Opened at.
   - The time the call started and its length, from Phone > Recents.
   - Did the screen open when Mossad was closed, and when it was open?

**Part 2, the CloudKit Console.**

1. In the CloudKit Console, container `iCloud.com.dwebber.mossad`, schema, record type `Recording`: add the fields `kind`, `person`, and `personID`, each a String.
2. Deploy the schema changes to Production. The `NextTime` type that waits there goes in the same step.
- If the iPhone app that Xcode runs uses the Development environment, the first phone call adds the three fields there by itself. Then only the deploy remains.
- Before this step, everything works with your own server as the sync. With iCloud, a phone call still arrives: the iPhone sends it again without the three fields, and the meeting says "In person" with no person.
- To check the fallback before the step: import one call with iCloud as the sync. The meeting must arrive as "In person". If the row on the iPhone says it could not send, report the error text: the code of that refusal must join `CloudKitStore.isUnknownField`.

**Part 3, the release.**

- Update the Mac and the iPhone app together. A Mac from before this change makes an "In person" meeting of a phone call. An iPhone from before this change leaves a phone call out of its list and keeps every other meeting.
- Put this sentence in the release notes: "Update the Mac and the iPhone app together."
- After the update, do one whole run: share a call recording, pick the person, tap "Add to Mossad", and read the meeting on the Mac. Do one more share of the same recording: the screen must say "This recording is already in Mossad."

## Self-review

- **Spec coverage.** Section 1: Task 1. Section 2: Tasks 2, 3, 8, 9, 10. Section 3: Tasks 3, 4. Section 4: Tasks 5, 6, 7. Section 5: Task 11. Section 6: Task 12. Each test of the spec's "Tests" list has a named test in Tasks 2 to 8. The profile row is a non-goal and has no task.
- **Not done on purpose.** No upload while the app does not run. No Worker change. No import on the Mac. The quiet mark "Named from the invite" keeps its words for a phone call.
- **Type consistency.** `PersonHint`, `CallImport.Choice`, `CallImport.Known`, `CallImport.Draft`, `CallImport.Plan`, `ImportMemory`, `StoreRefusal.unknownField`, `saveOne`, `addFinished`, `arrived`, `adopt`, `isOneTrack`, `micTrackName`, `untitled`, `phoneCallEvent`, and `trackLine(platform:)` have one spelling in every task.
- **Review Focus.** Each of the five lines names its tests, and each test is in the task that owns the code.
- **Proportion.** The plan is about five times as long as the spec. About half of its lines are test names with their assertions and the signatures between tasks; no step holds a function body.
- **Open risk.** The build check commands and the CloudKit refusal codes were not run by the plan's author. Task 1's STOP and Owner steps, part 2, are the checks for them.
