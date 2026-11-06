# Editorial Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the editorial redesign on Mac and iPhone, with generated meeting titles, decisions with times, bookmark notes, the Paylocity org chart, the new People sort, and a backfill that brings old meetings up to date.

**Architecture:** New data and logic go in `Packages/MossadCore` with tests first (titles, decisions, bookmark notes, org chart, sort, lanes, backfill). The look is one token set and a few layout components in `SharedUI/` (both apps compile it), then each page is rebuilt against the design canvases. Old `call.json` files must still decode.

**Tech Stack:** Swift 6, SwiftUI with Liquid Glass (macOS 26, iOS 26), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-06-editorial-redesign-design.md`

**Design canvases (outside the repo, private data):**
- `~/Mossad-design/redesign/Mossad Redesign.dc.html`: section 1 is the design system (tokens, type, glass rules, components); section 2 is every page, light and dark; section 3d is the menu bar. Rendered tiles: `~/Mossad-design/redesign/t00.png`…`t07.png`.
- `~/Mossad-design/missing-screens/*.dc.html`: one file per screen (processing, live calls, sheets, setup, welcome, org import and chart, titles, states, lanes with 30 voices, and `Phone-*.dc.html` for the iPhone). Open a file in a browser through a local server (`python3 -m http.server` in that folder) to see it; read its HTML for exact sizes and colors.

## Global Constraints

- macOS 26 and iOS 26 only; SF Pro and SF Symbols; system materials (`.glassEffect`, `GlassEffectContainer`). No custom fonts, no web-only effects.
- Never put real names, emails, company names, or the org file in the repo, tests, previews, or commit messages. Tests use made-up names (Dana Lee, Sam Park, Alex Rivera).
- No AI attribution in commits or code. Comments explain why, not what. Small focused files.
- Test first for every change in `Packages/MossadCore`. `cd Packages/MossadCore && swift test` must pass before every commit.
- Old records must decode: every new field is optional or has a default, decoded with `decodeIfPresent`.
- `MarkdownWriterTests` golden test is the note contract; change it only where the spec changes the note (decision times, bookmark notes) and say so in the commit.
- Never install or restart the app while `grep -l '"status" : "recording"' ~/Mossad/Audio/*/call.json` finds a file.
- Check UI work with the preview hook, behind other windows: `MOSSAD_ROOT=$HOME/Mossad <dev build>/Mossad --ui-preview --open-window <Section>` and a capture by window ID (see `scripts` or the session's `shot.sh` pattern). Never open windows that interrupt the owner.
- Work on the branch `editorial-redesign`. Commit after each task. Do not push or release until the final task.
- Build: `xcodegen generate -q && xcodebuild -project Mossad.xcodeproj -scheme Mossad -configuration Debug -derivedDataPath build/dev build` (Mac) and the `MossadPhone` scheme for a generic iOS destination.

## Review Focus

1. Old meetings: a `call.json` with `decisions: [String]`, no titles, and markers without notes must load, render, and sync unchanged.
2. Many speakers: a meeting with 137 voices (one exists) must not grow the header, the lanes, or the talk time past their limits; lanes scroll after 12.
3. Dark mode and Reduce Transparency / Increase Contrast: every text role keeps 4.5:1; glass falls back to the opaque surface.
4. Titles: a custom title is never replaced by a generated one; a calendar title still wins over a generated one; Analytics "scheduled" still means `calendarTitle != nil`.
5. Org file: duplicate full names, a supervisor not in the file, a blank supervisor, and nicknames (Ben/Benjamin) must not crash or mis-match silently.

---

### Task 1: Meeting titles (core)

**Files:** Modify `Records/CallRecord.swift`, `Summary/Summarizer.swift`, `Pipeline/Pipeline.swift`, `Output/MarkdownWriter.swift` (if it reads `title`); create `Summary/LiveTitler.swift`. Tests: `CallRecordTitleTests.swift`, `SummarizerTests.swift`, `PipelineTests.swift`.

**Interfaces:**
- Produces: `CallRecord.generatedTitle: String?`, `CallRecord.customTitle: String?`, `CallRecord.titleSource: TitleSource` (`.custom`, `.calendar`, `.generated`, `.platform`), `title` = custom ?? calendar ?? generated ?? "<Platform> call". `MeetingSummary.title: String?`. `Pipeline.setTitle(callID:_:)` (nil or blank clears the custom title) rewrites the note. `LiveTitler.title(transcript: String) async -> String?` (cheap model, one line, ≤60 characters).

- [ ] Tests: precedence (all four sources); `apply(_ summary)` sets `generatedTitle` and never touches `customTitle`/`calendarTitle`; the summary schema has `title`; `setTitle` renames the note file; an old record decodes with both nil.
- [ ] Run, watch fail, implement, run, pass. Summarizer prompt: "Write a title of at most 60 characters that names the topic; for a meeting of two or three people, add who it was with, by first name." The live title (AppController, after 5 minutes of live transcript, once per call) is stored in `generatedTitle` and replaced by the summary's.
- [ ] Commit `feat: meetings get a generated title, and a title you set wins`.

### Task 2: Decisions with times (core)

**Files:** `Summary/Summarizer.swift`, `Records/CallRecord.swift`, `Output/MarkdownWriter.swift`, `Sync/MeetingView.swift`, server `server/src/tools.ts` only if it reads decisions. Tests: `SummarizerTests`, `MarkdownWriterTests`, `CallRecordTests`.

**Interfaces:** Produces `struct Decision: Codable, Equatable, Sendable { text: String; at: TimeInterval? }`; `CallRecord.decisions: [Decision]` decodes both `["text"]` (old) and `[{"text","at"}]`. Summary schema: `decisions: [{text, at_seconds (nullable)}]`.

- [ ] Tests: old string array decodes; new form round-trips; the note writes `- [00:52:08] text` when `at` is known, else `- text` (update the golden test); `replaceSpeakerLabels` still swaps names in decision text.
- [ ] Implement; update every reader (`rg -n "\.decisions"` across App, PhoneApp, SharedUI, Chat tools, MCP, server) to use `.text`.
- [ ] Commit `feat: decisions carry the time they were made`.

### Task 3: Bookmark notes (core)

**Files:** `Records/CallRecord.swift` (`TranscriptMarker.note: String?`), `Capture/CallRecorder.swift`, `Pipeline/Pipeline.swift`, `Output/MarkdownWriter.swift`, summarizer prompt input. Tests in `CallRecorderTests`, `PipelineTests`, `MarkdownWriterTests`.

**Interfaces:** `CallRecorder.bookmark() -> TimeInterval?` (the offset); `CallRecorder.setBookmarkNote(at offset:, _ note:)` during a recording; `Pipeline.setBookmarkNote(callID:, offset:, note:)` after (adds a bookmark when none is at that offset, so the player can bookmark afterwards); the note shows in the note's transcript marker line and goes to the summary as "Bookmark at 0:52: <note>".

- [ ] Tests first, implement, commit `feat: a bookmark can carry an optional note`.

### Task 4: Org chart from a Paylocity export (core)

**Files:** create `People/OrgChart.swift`, `People/Nicknames.swift`, `People/OrgMatches.swift`; `Support/Paths.swift` (`people` = `~/Mossad/People`). Tests: `OrgChartTests.swift` with an inline made-up CSV.

**Interfaces:** `OrgChart.parse(csv: String) throws -> OrgChart` (columns `Last Name, First Name, Position Title, Supervisor`, supervisor "Last, First", BOM tolerated, quoted fields); `OrgChart.Person { id: String /* "last, first" lowercased */, first, last, title, managerID: String? }`; `chart.person(matching name: String, overrides: OrgMatches) -> Match?` where `Match { person, how: .exact | .nickname | .manual }`; `chart.manager(of:)`, `reports(of:)`, `peers(of:)`, `chain(of:)`; `OrgMatches` (`org-matches.json`: saved name → person id or "outside"); `OrgChart.load(paths:)`/`import(from url:, paths:)` copies the file to `~/Mossad/People/org.csv`. Nicknames: a fixed table of common English short forms both ways (Ben/Benjamin, Zach/Zachary, Jim/James, Bill/William, Bob/Robert, Mike/Michael, Matt/Matthew, Chris/Christopher, Kate/Katherine, …).
- [ ] Tests: parse with BOM and quotes; duplicate full names return no automatic match; nickname match; manual override wins; "outside" marks a person outside; missing supervisor; supervisor not in file.
- [ ] Give titles to the summarizer and the coach as context lines ("Sam Park, VP Planning") for speakers who match.
- [ ] Commit `feat: org chart from an HR export, matched to saved people by name`.

### Task 5: People sort and lanes data (core)

**Files:** `Voices/PersonStatistics.swift` or a new `Voices/PeopleSort.swift`; create `Output/SpeakerLanes.swift`. Tests: `PeopleSortTests.swift`, `SpeakerLanesTests.swift`.

**Interfaces:** `enum PeopleSort { recent, mostMet, talkTime, newest, name }`, `PeopleSort.order(_ profiles:, stats:) -> [VoiceProfile]` (owner first always), `needsVoiceSample` filter = profiles with no embeddings. `SpeakerLanes.make(_ record:, names:) -> [Lane]` where `Lane { key, name, seconds, segments: [ClosedRange<TimeInterval>] }`, owner first, then by talk time; adjacent segments under 1 s apart join (fast with 1,000 utterances).
- [ ] Tests, implement, commit `feat: people sort options and lane data for the player`.

### Task 6: Backfill old meetings (core)

**Files:** create `Pipeline/SummaryBackfill.swift`. Tests: `SummaryBackfillTests.swift`.

**Interfaces:** `SummaryBackfill.due(_ records:) -> [CallRecord]` (written, has utterances, `generatedTitle == nil` or any decision without `at`), newest first; `Pipeline.backfill(_ id)` = the summary step again keeping names, owner-set tags, custom title, and calendar title. App runs it once after the update (UserDefaults flag `summaryBackfill2026-11`), one meeting at a time, at utility priority, and logs "Updated N meetings".
- [ ] Tests, implement, commit `feat: old meetings get titles and decision times once`.

### Task 7: Design tokens and components (SharedUI)

**Files:** rewrite `App/Theme.swift` into `SharedUI/Tokens.swift` (colors with light/dark, 12 speaker hues from the canvas, platform dots, accent ink vs fill, spacing, radii, type roles), `SharedUI/LabelColumn.swift` (the 150 pt label column row), `SharedUI/Hairline.swift`, `SharedUI/Chip.swift`, `SharedUI/Glass.swift` (glass modifiers with Reduce Transparency fallback). Keep `Theme` names as thin aliases until later tasks remove their uses.

- [ ] Read section 1 of the redesign canvas and copy exact values (hex for light and dark, sizes, radii). Build Mac and iPhone. Commit `feat: editorial design tokens and layout components`.

### Task 8: Window shell, Meetings list, calendar

**Files:** `App/MainWindow.swift`, `App/MeetingsView.swift`, `App/CalendarPane.swift`, `App/UpcomingViews.swift`, `App/Cards.swift`. Canvas: section 2 Meetings (list), Meetings · Calendar; `Titles.dc.html`.

- [ ] Sidebar as glass with counts and the permissions card at the bottom; toolbar controls (list/calendar toggle, search, export, more) as glass. Groups Upcoming/Today/Yesterday/weekday; rows with title, platform dot, time, length, "needs names" text, "Named by Mossad" in detail only. Inline title edit (calls `setTitle`). Capture light and dark previews and compare with the canvas. Commit.

### Task 9: Meeting detail: header, lanes player, tabs

**Files:** `App/MeetingDetailView.swift` (split into `MeetingHeader.swift`, `LanesPlayer.swift`, `SummaryTab.swift`), `App/TranscriptTab.swift`, `App/CoachTab.swift`, `App/MeetingChatView.swift`, `App/AudioPlayer.swift`. Canvas: section 2 Meetings Summary/Transcript/Coach/Chat; `Lanes-many.dc.html`; `Bookmark.dc.html`.

- [ ] Header (meta line, title, length at right). LanesPlayer from `SpeakerLanes`: 12 lanes visible, scroll after, "+N more voices" fade, playhead and time bubble, decision dots and bookmark flags on the ruler, click to seek; transport row (−15, play, +15, Add bookmark with the note popover, speeds). Summary tab in the label column: In one line, Decisions with times (click seeks), Bookmarks, Action items, topics, talk share, invited. Transcript follows playback with find and "Jump to Speaker X". Coach: the coach's read, talk share bar, what worked with times. Chat as in the canvas with time chips. Commit.

### Task 10: Processing card, live views, and states

**Files:** `App/ProcessingCard.swift`, the `LivePanel`/`LiveTranscriptView` in `MeetingDetailView.swift` (move to `LiveViews.swift`), `App/CallControls.swift`, `App/LiveWaveform.swift`. Canvas: `Main.dc.html` (processing), `Live-Teams.dc.html`, `Live-Room.dc.html`, `States.dc.html`.
- [ ] Rebuild; keep behavior (upload percent, room transcript, muted banner). Commit.

### Task 11: Sheets

**Files:** `App/VoiceNamingView.swift`, `App/ShareSheet.swift`, `App/TranscribeAgainSheet.swift`, `App/PeopleDuplicatesSheet.swift`, the merge sheet in `MeetingsView.swift`. Canvas: `Name-voices`, `Share`, `Transcribe-again`, `Duplicates`, `Merge`.
- [ ] Rebuild each to its artboard; sheets are the opaque window color, popovers and menus glass. Commit.

### Task 12: Commitments and Chat pages

**Files:** `App/CommitmentsView.swift`, `SharedUI/CommitmentParts.swift`, `App/ChatView.swift`, `SharedUI/ChatMarkdown.swift`. Canvas: Commitments, Chat (empty and answer).
- [ ] Overdue first in accent, then grouped by the person promised, Open/Done toggle, "Pick a new date" / "Add a date". Chat empty state with four example questions; the composer is the only glass. Commit.

### Task 13: People: list, profile, org chart

**Files:** `App/PeopleView.swift`, `App/PersonProfileView.swift`, `App/PersonRelationViews.swift`; create `App/OrgChartView.swift`, `App/OrgImportSheet.swift`. Canvas: People, People · Org chart, `Org-import.dc.html`, `Org-chart.dc.html`, `Duplicates.dc.html`.
- [ ] Sort menu (Task 5) and "Needs a voice sample" filter; duplicates banner kept above the list. Profile in the label column with the coach's read first, title and manager from the org chart. List/Org chart toggle; import sheet with match review (search a person in the file, or Outside the company). Commit.

### Task 14: Analytics

**Files:** `App/AnalyticsView.swift`, `App/DateRangeButton.swift`, `SharedUI/PeriodChoice.swift`. Canvas: Analytics full page.
- [ ] Each section opens with a sentence that states the finding; date picker with presets and compare switch; who you meet with table; how you communicate sparklines; outcomes; costs. Keep every number that exists today. Commit.

### Task 15: Settings, server setup, Log, Welcome, menu bar

**Files:** `App/SettingsView.swift`, `App/SyncSettings.swift`, `App/StorageSettings.swift`, `App/LogView.swift`, `App/WelcomeView.swift`, `App/MenuContent.swift`. Canvas: Settings pages, `Server-setup.dc.html`, Log, `Welcome.dc.html`, section 3d menu bar.
- [ ] Settings as a second column like the meeting list; each page in the label column; keep every setting that exists. Org chart import lives in Settings › General too. Menu bar panel per 3d (status row, live talk-share strip while recording, Next, Recent, actions). Commit.

### Task 16: iPhone app

**Files:** `PhoneApp/*.swift`, `SharedUI/*`. Canvas: `Phone-*.dc.html` (Meetings, Meeting, Room, Chat, Chat answer, People, Person, Commitments, Analytics, Settings, Connect).
- [ ] Floating glass tab bar (Meetings, Commitments, Chat, People, Analytics), Settings from a gear on Meetings. Same tokens and lanes (about 10 visible, scroll). Build for a generic iOS device. Commit.

### Task 17: Final pass, backfill, release

- [ ] Full `swift test`; Mac and iPhone builds; light/dark/Reduce Transparency/Increase Contrast captures of every page compared with the canvases; fix gaps.
- [ ] Merge `editorial-redesign` into `main`, push, `scripts/release.sh 2.8.0 "<notes>"`, install when no call records; the backfill runs on the owner's Mac.
