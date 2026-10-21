# Mossad Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A zero-click macOS menu bar app that detects Zoom/Meet/Teams calls, records clean "me" and "them" tracks, and after the call writes a named, summarized Markdown transcript to `~/Mossad/Meetings/`.

**Architecture:** One menu-bar app process (`Mossad.app`, SwiftUI `MenuBarExtra`, `LSUIElement`). All logic lives in a local Swift package `MossadCore` so it is unit-tested with `swift test`; the app target is a thin shell (UI, permissions, wiring). System-facing code (Core Audio, AX, AppleScript, EventKit, network, FluidAudio) sits behind small protocols so the pure parts (detection state machine, merge, matching, Markdown) are tested with fakes.

**Tech Stack:** Swift 6.4, SwiftUI, Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, aggregate device), `AVAudioEngine` voice processing, ApplicationServices AX, `NSAppleScript`, EventKit, UserNotifications, `SMAppService`, URLSession, FluidAudio 0.17.7 (CoreML speaker embeddings), AssemblyAI v2 REST, Anthropic Messages API, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-20-mossad-rebuild-design.md`

## Global Constraints

- macOS deployment target 15.0. Not sandboxed. `LSUIElement = YES` (no Dock icon).
- Bundle ID `com.dwebber.mossad`. Signed with "Apple Development: David Webber (244F2ZV56K)" so TCC grants persist across rebuilds. Installed to `/Applications/Mossad.app`.
- No code from the old app is reused. The old targets are deleted in Task 1.
- Zero clicks: nothing may require user action to start or stop a recording. No window opens on its own; errors go to the log only.
- Paths: `~/Mossad/Meetings/` (Markdown), `~/Mossad/Audio/<callID>/` (audio + `call.json`), `~/Mossad/Voices/` (voice library), `~/Mossad/Logs/`.
- Keys: Keychain service `com.dwebber.mossad`, accounts `assemblyai` and `anthropic`. Source: Doppler `dispatch/prd` secrets `ASSEMBLYAI` and `ANTHROPIC_API_KEY_POLYWOOD_ANALYTICS`. Keys never in files, args, logs, or the repo.
- Detection tick: 2 s. Meeting-gone confirmation: 2 consecutive ticks. Mic-idle fallback end: 180 s (trailing silence trimmed). Minimum kept call: 60 s.
- Audio retention: 30 days. Voice clip for naming: 5 s.
- Owner name: "David Webber".
- Summary model: `claude-opus-5-5` (changed from claude-sonnet-5-5 during execution; see ledger).
- No AI attribution in commits, code, or comments.

## Review Focus

1. **Speaker bleed on laptop speakers** — remote speech that leaks into the mic must not appear twice or under "David Webber". Pinned by `TranscriptMergerTests.testDropsBleedDuplicates` (Task 8).
2. **Mute / device change mid-call** — mic released for <180 s while the meeting window stays must not split the call. Pinned by `CallDetectorTests.testMicReleaseWithWindowPresentDoesNotEnd` (Task 4).
3. **App quits, crashes, or Mac sleeps mid-pipeline** — a recorded call must resume processing on next launch, never be lost. Pinned by `ProcessingQueueTests.testResumesUnfinishedRecords` and `testRecoverInterruptedRecording` (Task 6).
4. **Network down / API error after a call** — audio kept, job retried with backoff. Pinned by `PipelineTests.testTranscriptionFailureKeepsAudioAndRetries` (Task 12).
5. **Non-call mic use in a browser** (YouTube, dictation, a non-meeting tab) — must not record. Pinned by `MeetingMatcherTests.testBrowserMicWithoutMeetingTabIsNotACall` (Task 3).

---

## File Structure

```
project.yml                         XcodeGen spec for Mossad.app
scripts/build.sh                    xcodegen + xcodebuild + install to /Applications
scripts/import-keys.sh              doppler run -- Mossad --import-keys
App/
  MossadApp.swift                   @main, MenuBarExtra, --import-keys mode
  AppController.swift               wires detector → recorder → pipeline, owns state
  MenuContent.swift                 menu items and status line
  MainWindow.swift                  Window scene: sidebar Meetings / Voices / Settings / Log
  MeetingsView.swift                list + search + transcript reader
  VoiceNamingView.swift             name unknown voices for one call (clips + fields)
  VoicesView.swift                  voice library: rename, merge, delete
  SettingsView.swift                folder, retention days, launch at login, key status
  LogView.swift                     tail of mossad.log
  Notifier.swift                    UserNotifications post-call notice
  Info.plist, Mossad.entitlements
Packages/MossadCore/
  Package.swift                     depends on FluidAudio 0.17.7
  Sources/MossadCore/
    Support/Paths.swift, Log.swift, Keychain.swift, Retention.swift
    Detection/Platform.swift, MeetingMatcher.swift, CallDetector.swift,
              MicUsageProbe.swift, BrowserTabProbe.swift, WindowTitleProbe.swift,
              DetectionService.swift
    Capture/ProcessTap.swift, MicCapture.swift, TrackWriter.swift, CallRecorder.swift
    Records/CallRecord.swift, ProcessingQueue.swift
    Transcription/AssemblyAIClient.swift, TranscriptMerger.swift
    Voices/VoiceLibrary.swift, EmbeddingProvider.swift, SpeakerIdentifier.swift, ClipExtractor.swift
    Calendar/CalendarMatcher.swift
    Summary/Summarizer.swift
    Output/MarkdownWriter.swift
    Pipeline/Pipeline.swift
  Tests/MossadCoreTests/            one test file per source file above that has logic
```

---

### Task 1: Tear down the old app and scaffold the new one

**Files:**
- Delete: `Mossad/`, `MossadService/`, `MossadShared/`, `MossadTests/`, `Mossad.xcodeproj/`, `Package.swift`, `Package.resolved`, `default.profraw`, `.build/`, `.swiftpm/`, old `project.yml`
- Create: `project.yml`, `scripts/build.sh`, `App/MossadApp.swift`, `App/Info.plist`, `App/Mossad.entitlements`, `Packages/MossadCore/Package.swift`, `Packages/MossadCore/Sources/MossadCore/Support/Paths.swift`, `Support/Log.swift`
- Modify: `.gitignore` (add `Mossad.xcodeproj/`, `.build/`, `build/`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/PathsTests.swift`

**Interfaces:**
- Produces: `struct Paths { init(root: URL); static let live: Paths /* ~/Mossad */; var meetings, audio, voices, logs: URL; func callDirectory(_ id: String) -> URL; func ensureDirectories() throws }`; `enum Log { static func info(_:), error(_:), debug(_:) }` writing to `os_log` subsystem `com.dwebber.mossad` and `logs/mossad.log` (rotate at 5 MB, keep 3).

- [ ] **Step 1:** `git rm -r` the old sources listed above; keep `docs/`.
- [ ] **Step 2:** Write `PathsTests.testLayoutUnderRoot` — with a temp root, `meetings == root/Meetings`, `audio == root/Audio`, `voices == root/Voices`, `logs == root/Logs`, `callDirectory("abc") == root/Audio/abc`; `ensureDirectories()` creates all four.
- [ ] **Step 3:** `cd Packages/MossadCore && swift test` → FAIL (no `Paths`).
- [ ] **Step 4:** Implement `Paths` and `Log`. `Package.swift`: platforms `.macOS(.v15)`, dependency `.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7")`.
- [ ] **Step 5:** `swift test` → PASS.
- [ ] **Step 6:** `project.yml`: one app target `Mossad`, sources `App/`, local package `Packages/MossadCore`, deployment 15.0, bundle ID `com.dwebber.mossad`, `CODE_SIGN_IDENTITY: "Apple Development"`, `DEVELOPMENT_TEAM` from the identity. `Info.plist`: `LSUIElement YES`, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSAppleEventsUsageDescription`. Entitlements: `com.apple.security.device.audio-input`, `com.apple.security.automation.apple-events`; no sandbox. `MossadApp` shows a `MenuBarExtra` with SF Symbol `waveform` and a Quit item.
- [ ] **Step 7:** `scripts/build.sh` runs `xcodegen generate`, `xcodebuild -scheme Mossad -configuration Release -derivedDataPath build build`, replaces `/Applications/Mossad.app`, and relaunches it. Run it → the waveform icon appears in the menu bar, no Dock icon.
- [ ] **Step 8:** Commit `chore: tear down old Mossad and scaffold rebuild`.

### Task 2: Keychain and key import

**Files:**
- Create: `Sources/MossadCore/Support/Keychain.swift`, `scripts/import-keys.sh`
- Modify: `App/MossadApp.swift`
- Test: `Tests/MossadCoreTests/KeychainTests.swift`

**Interfaces:**
- Produces: `enum APIKey: String { case assemblyai, anthropic }`; `struct Keychain { init(service: String = "com.dwebber.mossad"); func set(_ value: String, for: APIKey) throws; func get(_ key: APIKey) -> String? ; func delete(_ key: APIKey) }`; `func importKeys(from env: [String: String], into: Keychain) -> [APIKey]` (maps `ASSEMBLYAI` → `.assemblyai`, `ANTHROPIC_API_KEY_POLYWOOD_ANALYTICS` → `.anthropic`, returns which were stored).

- [ ] **Step 1:** Tests: `testRoundTrip` (service `com.dwebber.mossad.tests`, set/get/delete), `testImportKeysMapsDopplerNames` (env with both names → both stored, returns `[.assemblyai, .anthropic]`; empty env → `[]`, nothing stored).
- [ ] **Step 2:** `swift test --filter KeychainTests` → FAIL.
- [ ] **Step 3:** Implement with `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching` (generic password).
- [ ] **Step 4:** `swift test --filter KeychainTests` → PASS.
- [ ] **Step 5:** `MossadApp`: if `CommandLine.arguments.contains("--import-keys")`, call `importKeys(from: ProcessInfo.processInfo.environment, …)`, print only the key names stored, `exit(0)` before any UI. `scripts/import-keys.sh`: `doppler run --project dispatch --config prd -- /Applications/Mossad.app/Contents/MacOS/Mossad --import-keys`.
- [ ] **Step 6:** Build, run `scripts/import-keys.sh` → prints `assemblyai, anthropic`. Verify with `security find-generic-password -s com.dwebber.mossad -a assemblyai` (no `-w`).
- [ ] **Step 7:** Commit `feat: keychain storage and doppler key import`.

### Task 3: Meeting matcher rules

**Files:**
- Create: `Sources/MossadCore/Detection/Platform.swift`, `Detection/MeetingMatcher.swift`
- Test: `Tests/MossadCoreTests/MeetingMatcherTests.swift`

**Interfaces:**
- Produces: `enum Platform: String, Codable { case zoom, meet, teams }` (display names "Zoom", "Google Meet", "Microsoft Teams"); `enum AppKind { case zoomApp, teamsApp, browser(String) }`; `enum MeetingMatcher { static func appKind(bundleID: String) -> AppKind?; static func platform(forTabURL: String) -> Platform?; static func zoomWindowIsMeeting(_ title: String) -> Bool; static func teamsWindowIsMeeting(_ title: String) -> Bool; static func meetTabLeftMeeting(title: String) -> Bool }`

- [ ] **Step 1:** Tests with these exact values:
  - `appKind`: `us.zoom.xos` → `.zoomApp`; `com.microsoft.teams2` → `.teamsApp`; `com.google.Chrome`, `com.google.Chrome.helper`, `company.thebrowser.Browser`, `com.apple.Safari`, `com.apple.WebKit.GPU`, `com.microsoft.edgemac`, `com.brave.Browser` → `.browser(<base browser id>)`; `com.spotify.client` → `nil`.
  - `platform(forTabURL:)`: `https://meet.google.com/abc-defg-hij` → `.meet`; `https://meet.google.com/` and `https://meet.google.com/landing` → `nil`; `https://teams.microsoft.com/v2/` and `https://teams.cloud.microsoft/` with `/meetup-join/` or a `light-meetings` path → `.teams`; `https://app.zoom.us/wc/123456/join` and `https://us02web.zoom.us/wc/123/start` → `.zoom`; `https://www.youtube.com/watch?v=x` → `nil`.
  - `testBrowserMicWithoutMeetingTabIsNotACall`: a browser with only YouTube/Docs tabs yields no platform.
  - `zoomWindowIsMeeting`: "Zoom Meeting", "Zoom Webinar" → true; "Zoom Workplace", "Zoom" → false.
  - `meetTabLeftMeeting`: titles from a real post-call page (captured in Task 5 Step 6; start with "Meet" without a meeting code) → true; "Meet - abc-defg-hij" → false.
- [ ] **Step 2:** `swift test --filter MeetingMatcherTests` → FAIL.
- [ ] **Step 3:** Implement as pure string/URL rules. Teams window rule starts as: title contains "Meeting" or "Call" and ends with "| Microsoft Teams"; Task 5 replaces it with captured titles.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: meeting app and tab matching rules`.

### Task 4: Call detector state machine

**Files:**
- Create: `Sources/MossadCore/Detection/CallDetector.swift`
- Test: `Tests/MossadCoreTests/CallDetectorTests.swift`

**Interfaces:**
- Consumes: `Platform`, `AppKind` (Task 3).
- Produces:
  ```swift
  struct MeetingCandidate: Equatable { var platform: Platform; var bundleID: String; var micActive: Bool; var meetingPresent: Bool? }  // nil = unknown
  struct DetectionSnapshot { var time: Date; var candidates: [MeetingCandidate] }
  enum DetectorEvent: Equatable { case started(platform: Platform, bundleID: String, at: Date)
                                  case ended(at: Date, trimTo: Date?) }   // trimTo = last mic activity when ended by fallback
  struct CallDetector { init(config: Config = .init()); mutating func process(_ s: DetectionSnapshot) -> DetectorEvent?; var isInCall: Bool }
  struct Config { var goneConfirmTicks = 2; var micIdleFallback: TimeInterval = 180 }
  ```

- [ ] **Step 1:** Tests (snapshots 2 s apart):
  - `testStartsWhenMicActiveAndMeetingPresent` → `.started` on the first such tick.
  - `testDoesNotStartWhenMeetingPresentFalse` (browser mic, no meeting tab).
  - `testStartsWhenMeetingPresentUnknownAndMicActive` (Teams with no title match yet).
  - `testMicReleaseWithWindowPresentDoesNotEnd` — mic false for 170 s, `meetingPresent == true` → no event.
  - `testEndsAfterTwoGoneTicks` — `meetingPresent == false` for 1 tick → nil; 2nd tick → `.ended(trimTo: nil)`.
  - `testEndsByMicIdleFallback` — `meetingPresent` true/nil, mic false for 180 s → `.ended(trimTo: lastMicActiveTime)`.
  - `testCandidateDisappearsCountsAsGone` — the tracked bundle ID missing from the snapshot for 2 ticks → ended.
  - `testOnlyOneCallAtATime` — a second platform with mic active during a call → no event.
- [ ] **Step 2:** → FAIL.
- [ ] **Step 3:** Implement; track the call's `bundleID`, `lastMicActive`, `goneCount`.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: call detector state machine`.

### Task 5: Live detection probes

**Files:**
- Create: `Detection/MicUsageProbe.swift`, `Detection/BrowserTabProbe.swift`, `Detection/WindowTitleProbe.swift`, `Detection/DetectionService.swift`
- Modify: `App/AppController.swift` (create), `App/MenuContent.swift` (create)
- Test: `Tests/MossadCoreTests/DetectionServiceTests.swift`

**Interfaces:**
- Consumes: `MeetingMatcher`, `CallDetector`, `MeetingCandidate`.
- Produces:
  ```swift
  struct AudioProcess { var objectID: AudioObjectID; var pid: pid_t; var bundleID: String; var isRunningInput: Bool; var isRunningOutput: Bool }
  protocol MicUsageProbing { func processes() -> [AudioProcess] }          // kAudioHardwarePropertyProcessObjectList
  protocol BrowserTabProbing { func tabURLs(browserBundleID: String) -> [(url: String, title: String)] }  // NSAppleScript
  protocol WindowTitleProbing { func windowTitles(pid: pid_t) -> [String] }  // AXUIElement kAXWindowsAttribute/kAXTitleAttribute
  final class DetectionService { init(mic:, tabs:, windows:, detector:, tick: TimeInterval = 2); var onEvent: (DetectorEvent) -> Void; var audioProcessIDs: [AudioObjectID] /* processes of the current call's app, incl. helpers */; func start(); func stop(); func snapshot(at: Date) -> DetectionSnapshot }
  ```

- [ ] **Step 1:** Tests with fake probes: `testSnapshotGroupsBrowserHelpersUnderBaseBrowser` (Chrome helper with input → one Chrome candidate, `micActive` true); `testBrowserCandidateUsesMeetTab` (tabs include `meet.google.com/abc-defg-hij` → platform `.meet`, `meetingPresent` true); `testZoomCandidateFromWindowTitles` ("Zoom Meeting" present → true; only "Zoom Workplace" → false); `testBrowserTabsNotQueriedWithoutMicOrCall` (the tab probe is called only when that browser uses the mic or is the current call's app).
- [ ] **Step 2:** → FAIL.
- [ ] **Step 3:** Implement `snapshot(at:)` and the 2 s timer (`DispatchSourceTimer` on a utility queue). Live probes: Core Audio process objects (`kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID`, `kAudioProcessPropertyIsRunningInput/Output`); AppleScript per browser (`URL`/`title` of every tab of every window; Safari uses `name`); AX window titles (prompt for Accessibility once via `AXIsProcessTrustedWithOptions`).
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** `AppController` owns `DetectionService`; menu status line shows "Idle" or "In call: <Platform>". At `Log.debug` level, log every candidate's window titles and tab titles each tick while in a call.
- [ ] **Step 6:** Manual: build, join a real Meet (Chrome), Zoom (app), Teams (app), and Zoom web call; leave each. Copy the logged in-call and post-call titles into `MeetingMatcherTests` fixtures and fix `teamsWindowIsMeeting`/`meetTabLeftMeeting` to match. Expected: status flips to "In call" within ~2 s of joining and back to "Idle" within ~4 s of leaving.
- [ ] **Step 7:** `swift test` → PASS. Commit `feat: live call detection probes`.

### Task 6: Call records and processing queue

**Files:**
- Create: `Records/CallRecord.swift`, `Records/ProcessingQueue.swift`
- Test: `Tests/MossadCoreTests/ProcessingQueueTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum CallStatus: String, Codable { case recording, recorded, transcribed, identified, summarized, written, failed }
  struct Utterance: Codable, Equatable { var track: Track /* .me/.them */; var speakerLabel: String; var start: TimeInterval; var end: TimeInterval; var text: String }
  struct CallRecord: Codable { var id: String; var platform: Platform; var bundleID: String; var start: Date; var end: Date; var status: CallStatus; var attempts: Int; var nextAttempt: Date?
                               var calendarTitle: String?; var attendees: [String]; var utterances: [Utterance]; var speakerNames: [String: String] /* "them:A" → "Alex Rivera" */; var unknownSpeakers: [String]; var summary: String?; var actionItems: [String]; var markdownPath: String?
                               func save(to dir: URL) throws; static func load(from dir: URL) throws -> CallRecord }
  struct ProcessingQueue { init(paths: Paths); func pending(now: Date) -> [CallRecord] /* status not .written/.recording, nextAttempt <= now */; func recoverInterrupted() /* .recording → .recorded with end = start + me.caf duration, or delete the dir if < 60 s */; func markFailure(_ r: inout CallRecord, now: Date) /* attempts += 1; backoff 1m,5m,30m,2h, then every 6h */ }
  ```

- [ ] **Step 1:** Tests: `testRecordRoundTrip`; `testResumesUnfinishedRecords` (three call dirs: `.recorded`, `.summarized`, `.written` → pending returns the first two, oldest first); `testBackoffSchedule` (attempts 1…5 → 60, 300, 1800, 7200, 21600 s); `testNotDueYetIsSkipped`; `testRecoverInterruptedRecording` (a `.recording` dir with 90 s of audio → `.recorded`, end = start+90 s; one with 30 s → dir deleted).
- [ ] **Step 2:** → FAIL. **Step 3:** Implement. **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: call records and resumable processing queue`.

### Task 7: Audio capture (them tap + echo-cancelled mic)

**Files:**
- Create: `Capture/ProcessTap.swift`, `Capture/MicCapture.swift`, `Capture/TrackWriter.swift`, `Capture/CallRecorder.swift`
- Test: `Tests/MossadCoreTests/TrackWriterTests.swift`, `CallRecorderTests.swift`

**Interfaces:**
- Consumes: `Paths`, `DetectorEvent`, `DetectionService.audioProcessIDs`, `CallRecord`, `ProcessingQueue` (Task 6).
- Produces:
  ```swift
  final class TrackWriter { init(url: URL, sampleRate: Double = 16_000) throws; func append(_ buffer: AVAudioPCMBuffer) throws /* converts any format → mono Float32 16 kHz CAF */; func close(); var duration: TimeInterval }
  func trimAudioFile(_ url: URL, to duration: TimeInterval) throws
  protocol TrackSource { func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws; func stop() }
  final class ProcessTap: TrackSource { init(processObjectIDs: [AudioObjectID]) }   // CATapDescription(stereoMixdownOfProcesses:), private aggregate device; fallback CATapDescription(stereoGlobalTapButExcludeProcesses: [own process])
  final class MicCapture: TrackSource { init(voiceProcessing: Bool = true) }       // AVAudioEngine inputNode.setVoiceProcessingEnabled(true), voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
  final class CallRecorder { init(paths: Paths, makeThem: ([AudioObjectID]) -> TrackSource, makeMe: () -> TrackSource); func begin(platform: Platform, bundleID: String, processIDs: [AudioObjectID], at: Date) throws -> String /* callID */; func end(at: Date, trimTo: Date?) -> CallRecord?  /* nil when < 60 s: directory deleted */; func skip() /* stop and delete directory */ }
  ```
  Files per call: `Audio/<callID>/them.caf`, `me.caf`, `call.json`. `callID` = `yyyyMMdd-HHmmss` of the start.

- [ ] **Step 1:** Tests: `TrackWriterTests.testConvertsStereo48kToMono16k` (1 s 48 kHz stereo sine → file of 16 000 frames, 1 channel); `testTrimShortensFile`; `CallRecorderTests` with fake `TrackSource`s: `testShortCallIsDiscarded` (59 s → `nil`, directory gone), `testBeginWritesRecordWithStatusRecording`, `testEndWritesRecordWithStatusRecorded` (61 s → `call.json` with `.recorded`, both files exist), `testSkipDeletesEverything`, `testFallbackEndTrimsBothTracks` (`trimTo` = start+100 s → both tracks ≈100 s).
- [ ] **Step 2:** → FAIL.
- [ ] **Step 3:** Implement. Write buffers as they arrive (no in-memory accumulation). When the tap cannot be created for the process IDs, log and use the global tap. Re-resolve process IDs every tick while recording (browser audio helpers can restart) and rebuild the tap if the set changes.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5:** Wire into `AppController`: `.started` → `begin`, `.ended` → `end` then hand the record to the pipeline (Task 12). Menu icon becomes `waveform.circle.fill` (red tint) while recording. Add "Skip this call" menu item while recording.
- [ ] **Step 6:** Echo acceptance test on laptop speakers, no headphones: play a 2-minute Meet call where the other side talks while David is silent. Open `me.caf`: remote speech must be inaudible or near-inaudible. If it is clearly audible, set `MicCapture(voiceProcessing: false)` and add a WebRTC AEC3 stage that uses the them track as the reference (separate follow-up task; record the result in the commit message).
- [ ] **Step 7:** Commit `feat: process-tap and echo-cancelled mic capture`.

### Task 8: AssemblyAI client and transcript merge

**Files:**
- Create: `Transcription/AssemblyAIClient.swift`, `Transcription/TranscriptMerger.swift`
- Test: `Tests/MossadCoreTests/AssemblyAIClientTests.swift`, `TranscriptMergerTests.swift`

**Interfaces:**
- Consumes: `Utterance`, `Keychain`.
- Produces:
  ```swift
  protocol Transcribing { func transcribe(file: URL, track: Track) async throws -> [Utterance] }
  struct AssemblyAIClient: Transcribing { init(apiKey: String, session: URLSession = .shared, pollInterval: Duration = .seconds(5)) }
  enum TranscriptMerger { static func merge(me: [Utterance], them: [Utterance]) -> [Utterance] }
  ```
  API: `POST https://api.assemblyai.com/v2/upload` (body = file bytes, header `authorization`) → `upload_url`; `POST /v2/transcript` `{ "audio_url", "speaker_labels": true, "language_detection": false, "language_code": "en_us" }`; poll `GET /v2/transcript/{id}` until `status` is `completed` (map `utterances[]`: `speaker`, `start`/`end` ms → seconds, `text`) or `error` (throw with `error` text).

- [ ] **Step 1:** Client tests with a `URLProtocol` stub: `testUploadThenCreateThenPoll` (asserts request order, the auth header, `speaker_labels: true`, and mapping of `start: 4120` → `4.12`); `testErrorStatusThrows`; `testHTTP500Throws`.
- [ ] **Step 2:** Merger tests: `testInterleavesByStartTime`; `testDropsBleedDuplicates` — me utterance "we should ship the cushions friday" at 10.0–12.0 and them utterance "We should ship the cushions Friday." at 10.1–12.1 → the me copy is dropped (rule: drop a me utterance when a them utterance overlaps it by ≥50 % of its duration and normalized word-level similarity ≥ 0.8); `testKeepsCrossTalk` (overlapping but different text → both kept).
- [ ] **Step 3:** → FAIL. **Step 4:** Implement. **Step 5:** → PASS.
- [ ] **Step 6:** Commit `feat: AssemblyAI batch transcription and track merge`.

### Task 9: Voice library and speaker identification

**Files:**
- Create: `Voices/VoiceLibrary.swift`, `Voices/EmbeddingProvider.swift`, `Voices/SpeakerIdentifier.swift`, `Voices/ClipExtractor.swift`
- Test: `Tests/MossadCoreTests/VoiceLibraryTests.swift`, `SpeakerIdentifierTests.swift`, `ClipExtractorTests.swift`

**Interfaces:**
- Consumes: `Utterance`, `Paths.voices`, `TrackWriter` format (16 kHz mono CAF).
- Produces:
  ```swift
  struct VoiceProfile: Codable { var name: String; var isOwner: Bool; var embeddings: [[Float]] /* max 20, newest kept */ }
  final class VoiceLibrary { init(directory: URL); var profiles: [VoiceProfile]; func bestMatch(_ e: [Float]) -> (name: String, score: Float)?; func add(_ e: [Float], to name: String, isOwner: Bool = false) throws; var matchThreshold: Float /* 0.65 */ }
  protocol EmbeddingProvider { func embedding(for samples: [Float]) async throws -> [Float] }
  final class FluidEmbeddingProvider: EmbeddingProvider   // DiarizerModels.downloadIfNeeded() once, DiarizerManager.initialize, extractSpeakerEmbedding(from:)
  struct SpeakerIdentifier { init(library: VoiceLibrary, provider: EmbeddingProvider, ownerName: String = "David Webber")
       func identify(utterances: [Utterance], meURL: URL, themURL: URL) async throws -> (names: [String: String], unknown: [String], embeddings: [String: [Float]]) }
  enum ClipExtractor { static func clip(for key: String, utterances: [Utterance], source: URL, to: URL, seconds: TimeInterval = 5) throws }
  ```
  Speaker keys are `"me:A"`, `"them:B"`. Per key: collect that speaker's utterances ≥ 2 s, up to 60 s total, embed each, average, L2-normalize. Score = cosine similarity.

- [ ] **Step 1:** Library tests: `testBestMatchAboveThreshold` / `testBelowThresholdReturnsNil` (threshold 0.65); `testAddCapsAtTwentyEmbeddings`; `testPersistsAcrossInstances`.
- [ ] **Step 2:** Identifier tests with a fake provider returning fixed vectors per time range: `testOwnerEnrolledFromDominantMeSpeakerWhenLibraryHasNoOwner` (me:A talks most → named "David Webber", library now has an owner); `testOwnerMatchedByVoiceOnMeTrack`; `testSecondVoiceOnMeTrackIsUnknown`; `testThemSpeakerMatchesKnownColleague`; `testTwoLabelsSameVoiceGetSameName`; `testMatchedSpeakerAddsEmbeddingToProfile`; `testSpeakerWithUnderTwoSecondsIsUnknown`.
- [ ] **Step 3:** Clip test: `testClipTakesLongestUtteranceUpToFiveSeconds`.
- [ ] **Step 4:** → FAIL. **Step 5:** Implement. **Step 6:** → PASS.
- [ ] **Step 7:** Commit `feat: local voice library and speaker identification`.

### Task 10: Calendar matching

**Files:**
- Create: `Calendar/CalendarMatcher.swift`
- Test: `Tests/MossadCoreTests/CalendarMatcherTests.swift`

**Interfaces:**
- Produces: `struct CalendarEventInfo { var title: String; var start, end: Date; var attendees: [String]; var text: String /* location + notes + url */ }`; `protocol CalendarSource { func events(from: Date, to: Date) -> [CalendarEventInfo] }`; `struct EventKitCalendarSource: CalendarSource` (requests full access once); `enum CalendarMatcher { static func bestEvent(for platform: Platform, start: Date, end: Date, in events: [CalendarEventInfo]) -> CalendarEventInfo? }`

- [ ] **Step 1:** Tests: `testPicksOverlappingEventWithPlatformLink` (two overlapping events, one with `meet.google.com` → that one for `.meet`); `testFallsBackToLargestOverlap`; `testIgnoresAllDayAndNonOverlapping`; `testNoEventReturnsNil`. Platform link markers: `meet.google.com`, `zoom.us/j/`, `teams.microsoft.com`/`teams.cloud.microsoft`.
- [ ] **Step 2:** → FAIL. **Step 3:** Implement. **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: calendar event matching`.

### Task 11: Summary

**Files:**
- Create: `Summary/Summarizer.swift`
- Test: `Tests/MossadCoreTests/SummarizerTests.swift`

**Interfaces:**
- Produces: `protocol Summarizing { func summarize(transcript: String, title: String) async throws -> (summary: String, actionItems: [String]) }`; `struct ClaudeSummarizer: Summarizing { init(apiKey: String, model: String = "claude-sonnet-5-5", session: URLSession = .shared) }` — `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`; the prompt asks for a JSON object `{"summary": "...", "action_items": ["Owner: item", ...]}`; parse the first JSON object in the text reply.

- [ ] **Step 1:** Tests with a `URLProtocol` stub: `testSendsModelAndHeaders`; `testParsesSummaryAndActionItems`; `testMalformedReplyThrows`.
- [ ] **Step 2:** → FAIL. **Step 3:** Implement. **Step 4:** → PASS.
- [ ] **Step 5:** Commit `feat: Claude summary and action items`.

### Task 12: Markdown output and pipeline

**Files:**
- Create: `Output/MarkdownWriter.swift`, `Pipeline/Pipeline.swift`
- Test: `Tests/MossadCoreTests/MarkdownWriterTests.swift`, `PipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 6 and 8–11.
- Produces: `enum MarkdownWriter { static func fileName(for: CallRecord, title: String) -> String /* "2026-10-20 1430 - Weekly Ops Sync.md", "/" and ":" replaced by "-" */; static func render(_ r: CallRecord) -> String }`; `actor Pipeline { init(paths:, queue:, transcriber:, identifier:, calendar:, summarizer:, notify: @Sendable (_ record: CallRecord) -> Void); func process(_ id: String) async; func runPending() async; func applyNames(callID: String, names: [String: String]) async }`

  Markdown layout (front matter keys exactly):
  ```
  ---
  date: 2026-10-20
  start: "14:30"
  end: "15:02"
  duration_minutes: 32
  platform: Google Meet
  title: Weekly Ops Sync
  attendees: [..]
  speakers: [David Webber, Alex Rivera, Speaker B]
  audio: ~/Mossad/Audio/20261020-143000
  ---
  # Weekly Ops Sync
  ## Summary
  ## Action items
  - [ ] ...
  ## Transcript
  [00:04:12] Alex Rivera: ...
  ```
  Unknown speakers render as "Speaker A", "Speaker B" (letters by first appearance across both tracks). Title = calendar title, else "<Platform display name> call".

- [ ] **Step 1:** Writer tests: `testRenderGolden` (fixture record → exact expected string); `testFileNameSanitized`; `testUnknownSpeakersLettered`.
- [ ] **Step 2:** Pipeline tests with fakes: `testHappyPathWritesMarkdownAndNotifiesUnknowns` (status ends `.written`, file exists, `notify` called once when unknowns non-empty, not called when empty); `testTranscriptionFailureKeepsAudioAndRetries` (status stays `.recorded`, `attempts == 1`, audio files still exist); `testSummaryFailureStillWritesTranscript` (after 3 failed summary attempts, write the file without the summary sections and mark `.written`); `testApplyNamesRewritesFileAndLearnsVoices` (names applied, Markdown regenerated, summary regenerated, the library now matches that voice).
- [ ] **Step 3:** → FAIL. **Step 4:** Implement: steps run by status (`recorded` → transcribe both tracks → merge → `transcribed` → identify → `identified` → calendar + summary → `summarized` → write → `written`), saving `call.json` after each step.
- [ ] **Step 5:** → PASS. **Step 6:** Commit `feat: markdown output and processing pipeline`.

### Task 13: Menu bar app, app window, voice naming, settings, retention

**Files:**
- Create: `App/MainWindow.swift`, `App/MeetingsView.swift`, `App/VoiceNamingView.swift`, `App/VoicesView.swift`, `App/SettingsView.swift`, `App/LogView.swift`, `App/Notifier.swift`, `Sources/MossadCore/Support/Retention.swift`, `Sources/MossadCore/Records/MeetingIndex.swift`
- Modify: `App/AppController.swift`, `App/MenuContent.swift`, `App/MossadApp.swift`
- Test: `Tests/MossadCoreTests/RetentionTests.swift`, `MeetingIndexTests.swift`

**Interfaces:**
- Consumes: `Pipeline.applyNames`, `ClipExtractor`, `CallRecord.unknownSpeakers`, `CallRecord.attendees`.
- Produces: `enum Retention { static func sweep(audioRoot: URL, olderThan days: Int = 30, now: Date) }` — deletes `them.caf`/`me.caf`/clips in call dirs whose record is `.written` and `end` is older than `days`; keeps `call.json`.
  `struct MeetingIndex { init(paths: Paths); func all() -> [CallRecord] /* newest first */; func search(_ q: String) -> [CallRecord] /* case-insensitive over title + utterance text */ }`; `VoiceLibrary.rename(_ from: String, to: String)`, `merge(_ a: String, into b: String)`, `delete(_ name: String)`.

- [ ] **Step 1:** Retention tests: `testDeletesOldWrittenAudioKeepsJSON`; `testKeepsUnwrittenEvenIfOld`; `testKeepsRecent`. Index tests: `testAllNewestFirst`; `testSearchMatchesTitleAndText`. Library tests: `testRenameMergeDelete`.
- [ ] **Step 2:** → FAIL. **Step 3:** Implement. **Step 4:** → PASS.
- [ ] **Step 5:** `Notifier`: post exactly one notification per processed call with unknowns: title "Mossad", body "<n> new voice(s) in <title>". Clicking it opens the main window on that call's `VoiceNamingView`.
- [ ] **Step 6:** `MainWindow`: SwiftUI `Window` scene (id `main`) with `NavigationSplitView` sidebar Meetings / Voices / Settings / Log. Opening it calls `NSApp.activate`; while open the app may show a Dock icon (`NSApp.setActivationPolicy(.regular)`), returning to `.accessory` when it closes. `MeetingsView`: searchable list (`MeetingIndex`), reader with summary, action items, transcript, speakers, "Name voices" (if unknowns) and "Reveal in Finder". `VoiceNamingView`: one row per unknown speaker with a play button (5 s clip via `ClipExtractor`, `AVAudioPlayer`), a name `TextField` with attendee names as suggestions, Save → `applyNames`. `VoicesView`: list of profiles with rename / merge / delete. `LogView`: last 500 lines of `mossad.log`. `SettingsView`: retention days (default 30), launch at login (`SMAppService.mainApp`, on by default at first launch), key status for both keys.
- [ ] **Step 7:** Menu: status line (Idle / Recording "<title or platform>" mm:ss / Processing n), Meetings…, Name voices… (hidden if none pending), Skip this call (only while recording), Voices…, Settings…, Log…, Quit. Each "…" item opens the main window on that section. On launch: `Paths.ensureDirectories`, `queue.recoverInterrupted()`, `pipeline.runPending()`, `Retention.sweep`, then every hour `runPending` + `sweep`.
- [ ] **Step 8:** Build and run; check every menu item. Commit `feat: menu bar UI, voice naming panel, settings, retention`.

### Task 14: End-to-end acceptance

**Files:** none new (fixes go to the task that owns the code).

- [ ] **Step 1:** Fresh install with `scripts/build.sh` and `scripts/import-keys.sh`; grant Microphone, System Audio Recording, Accessibility, Automation (each browser), Calendars, Notifications once.
- [ ] **Step 2:** Run the spec's acceptance list and record pass/fail for each in `docs/superpowers/acceptance-2026-10.md`:
  1. Meet in Chrome, Zoom app, Teams app, and one web Zoom/Teams call each produce a Markdown file within a few minutes after hanging up, with no clicks.
  2. YouTube and browser dictation produce no file.
  3. On laptop speakers, David's lines contain only his words; no remote line is duplicated under his name.
  4. A colleague named once is labeled automatically in the next call.
  5. Muting for a minute does not split the call.
  6. Leaving the meeting ends the recording within a few seconds.
- [ ] **Step 3:** Commit `docs: acceptance results`.
