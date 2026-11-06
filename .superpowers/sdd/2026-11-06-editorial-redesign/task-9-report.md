# Task 9 report: meeting detail (header, lanes player, tabs)

Status: DONE_WITH_CONCERNS

## Commits (branch editorial-redesign)
- a7b71f8 feat: add a bookmark after the call without a note, once per moment (Core, test first: `Pipeline.addBookmark(callID:offset:)`, `CallRecord.addBookmark(at:markerText:)`; no second bookmark within 1 s)
- c50c2ed feat: meeting detail as one band with the lanes player, and the summary, transcript, coach, and chat tabs in the label column

## What I built
- `App/MeetingDetailView.swift`: shell only. Band header + glass tabs centered on the band's bottom edge (offset 17), tab content below. Keeps seek requests (chat links, commitments), cloud audio fallback, LivePanel (untouched, Task 10), MeetingPeople, helpers. New: `SpeakerNamingPopover` (shared by lanes and transcript), `detailColumn()` (36 pt gutter, 980 max), `longClock()`.
- `MeetingPeople` now orders speakers like the lanes (owner first, then talk time) and uses `Palette.speaker(i)`, so one speaker has one hue in the lanes, transcript, and talk share. Adds `seconds`.
- `App/MeetingHeader.swift`: meta line (platform dot, "In person · Yesterday, 10:17 AM – 12:02 PM", kind chip, Named by Mossad, tags, "N voices need names" needs-you chip that opens Name voices), 26 pt title (Task 8 inline rename), length right in secondary, processing card / failure banner, then the player. Band = 3.5% ink tint + bottom hairline.
- `App/LanesPlayer.swift`: one Canvas per lane in a LazyVStack (tested with 137 voices, ~800 turns: smooth), 11 pt lanes, 3 pt gap, names + minutes in the 150 pt column (unnamed in accent; the speaking person in semibold; click a name to name/rename the voice), click or drag in a lane to seek. Over 12 lanes: scrolls inside, "+N more voices · scroll" on a fade that hides at the end. Ruler: hairline, quarter ticks, decision dots (hollow; the last passed one filled), accent bookmark flags; click seeks, hover shows the decision text / bookmark note. Playhead line through all lanes with the time bubble. Transport: −15, play/pause (Space), +15, Add bookmark (glass; adds at once via `AppController.addBookmark` → recorder while this call records, else Pipeline; then the note popover per Bookmark.dc.html: optional note, Return skips, Done, closes itself after 8 s with no text), speeds in a glass capsule. J/K/L kept.
- `App/SummaryTab.swift`: label column: In one line (headline, else first sentence), Decisions with times (click plays; current one in ink semibold; no time → no dot; meetings with no decision times drop the empty column), Bookmarks (flag + time + note or "Bookmark · no note"), Action items (ring + task + "· owner"), Summary, Topics (collapsible), Talk share (bar + "You 13% · Ben 47% · Patrick 12% · four others share the rest"), Invited.
- `App/TranscriptTab.swift`: tools row (find field 280×28 with match count and Cmd-G, "N turns · N words · follows playback" toggle, "Jump to Speaker X" cycles unnamed voices), turns in the label column, current turn on selection fill and kept in view while playing or seeking, "Name this voice ▾" on unnamed turns, bookmarks as accent marker lines, "Play from here" in each line's context menu, time under each turn plays. Blocks are cached, not rebuilt on every player tick.
- `App/CoachTab.swift`: The coach's read, Talk share, What worked (did well + strengths with times), What to change (improving + try next + improvements with times, say/try boxes, right/wrong rating kept), Open questions, Focus, then More from the coach (goals, meeting value, scorecard, talk to the coach, review again). Cards replaced by label column rows.
- `App/MeetingChatView.swift`: You asked / Answer rows, time links for this meeting are chips that seek the player in place (no tab switch); other links behave as before. Glass composer with accent send. `SharedUI/ChatMarkdown` gained `timeChips` (default off; iPhone unchanged and builds).
- `App/TagRow.swift`: tags are quiet `TagChip`s (fill, secondary), not accent.
- `App/MeetingsView.swift`: `MeetingActions` removed (header and calendar crumb bar). Share, Open note, and the rest are in the toolbar Export / More menus; Name voices is the needs-names chip; Name skipped voices is in More. Hook `MOSSAD_MEETING=<id>`.
- `AppController`: `addBookmark(callID:at:)`, `setBookmarkNote(callID:offset:note:)`; `String.nonEmpty` made internal.
- Preview hooks (only with --ui-preview): `MOSSAD_MEETING`, `MOSSAD_TAB=summary|transcript|coach|chat`, `MOSSAD_SEEK=<seconds>`.

## Captures (/private/tmp/claude-501/redesign-shots/)
- task9-inperson-summary-light.png, task9-inperson-summary-dark.png (in-person meeting, decision times and a bookmark note seeded in a temp copy of the call)
- task9-inperson-transcript-dark.png, task9-inperson-coach-light.png, task9-inperson-chat-dark.png (made-up chat in a temp root)
- task9-manyvoices-transcript-light.png (temp copy split into 137 voices: 12 lanes, scroll, "+132 more voices", Jump to Speaker D, Name this voice)
- task9-meet2-summary-light.png, task9-meet2-transcript-dark.png (2-person Meet call)
Temp roots: /private/tmp/claude-501/t9root, t9root2 (outside the repo; symlinks to real data except the copied call.json and one chat).

## Canvas differences kept, and why
- Real data: the in-person meeting has 7 voices, not 12, and no decision times yet (the backfill has not run on it), so the real-data capture shows no decision dots; the seeded copy shows them.
- The summary keeps the full overview ("Summary" row) and Invited; the canvas row "You committed to" shows action items (commitments are Task-other scope).
- The coach has no "group average" in the talk share line and no "Open David in People" footer: no data for them.
- Chat follow-up chips are only shown as examples on an empty chat (the agent returns no suggestions). Time chips are filled text runs with no-break spaces, not true capsules (SwiftUI Text cannot draw a capsule inline), and have no speaker dot.
- Transcript lines keep one paragraph per recognized line inside a turn, so a match or a context menu can address a line.
- Ruler ticks use h:mm for meetings of 10 min or more (as the canvas) and m:ss under that.
- The band and player stay fixed above the tab content (the canvas does not show scroll behavior); on a short window the content area gets small with 12 lanes.

## Concerns
- The fixed band takes about 400 pt with 12 lanes; on small windows the tab content is short. A collapse on scroll could come later.
- Skeleton (processing) still uses the old card look; ProcessingCard and LivePanel are Task 10.
- During a recording the detail shows LivePanel, so the player's Add bookmark path through the recorder is wired in AppController but only reachable once Task 10 shows the player live.
- Captures sometimes grab the menu bar when the window opens slowly; the script waits 12 s now.

## Build and test
- `swift test`: 611 tests, 0 failures (17 skipped). Mac (Mossad) and iPhone (MossadPhone) Debug builds succeed.

## Fix report (review round 1)

Changes:
1. Player during processing and with no speech: `MeetingHeader` shows `LanesPlayer` whenever status is not recording. With zero lanes it draws only the ruler, playhead, and transport, so the audio plays while the call is transcribed.
2. Lanes and people are cached: `DetailCache` (a class held in @State) keyed on the utterance count, the speaker names, the owner, the library size, and the attendees. `SpeakerLanes.make` and `MeetingPeople` now run once per change, not on every player tick.
3. Visible lanes adapt to the height: the detail is sized from its proposal (GeometryReader, top aligned, clipped), and shows 6 lanes under 760 pt, else 12. The rest scroll with "+N more voices".
4. The meta line wraps: it is a `FlowLayout`, and `TagRow` now returns separate views (no inner HStack), so many tags flow to a second line instead of clipping.
5. Bookmark note popover: a typed note is saved when the popover closes by a click outside (`onDisappear`), once.
6. `LaneRow` is Equatable (closures left out) and uses `.equatable()`, so a player tick redraws only the rows whose "current" state changes, not all 12 Canvases.
7. Transcript stats ("N turns · N words") are computed with the blocks, not on every tick.
- New preview hook: `MOSSAD_WINDOW_HEIGHT=<points>` (only with --ui-preview) sizes the window for captures.

Builds: `swift test` 611 tests, 0 failures (17 skipped). Mac and iPhone Debug builds succeed.

Captures (/private/tmp/claude-501/redesign-shots/):
- task9-fix-processing-light.png: a call in "Transcribing" (temp copy, no utterances). Processing card, then the ruler and transport with the playhead.
- task9-fix-short-window-dark.png: window 620 pt (652 with the title bar). 6 lanes, "+1 more voice · scroll", transcript under the tabs.
- task9-fix-manytags-light.png: 13 tags wrap to a second meta line. The title, length, and player stay in place.

Found while capturing (not from this task): at a 652 pt window the whole window's content is laid out about 64 pt taller than the window and centered. This happens on every page, the Log page too, so the sidebar items move up under the title bar. Some view in the shell (Task 8) seems to need more than the declared 600 pt minimum. The detail no longer adds to this, because it takes its proposed height.

## Fix report (review round 2)

Changes:
1. Window height overflow (`App/MainWindow.swift`): the root's `.frame(minWidth: 980, minHeight: 600)` is replaced by `.frame(minWidth: 980, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)`. The window's `contentMinSize` (980 × 600) still sets the limit. I first removed the frame completely, as suggested. Then the content's own minimum height held the window at 820 pt: a 600 pt resize ended at 820. A flexible frame aligned to the top lets the window reach 600 pt, and the sidebar stays below the title bar on every page.
2. Detail cache key: it now uses a hash of every voice profile's name and email, not the profile count. A rename or an email change in People now updates the open meeting's speakers and Invited list.
- The `MOSSAD_WINDOW_HEIGHT` hook now resizes the window at 0.5, 2, 4, and 6 s, so it also works after the window restores its saved frame.

Builds: Mac Debug build succeeds. `swift test` 611 tests, 0 failures (17 skipped). SharedUI did not change in this round.

Captures (/private/tmp/claude-501/redesign-shots/):
- task9-fix2-meetings-600-dark.png: Meetings at 600 pt. The sidebar is below the title bar. The detail shows 6 lanes and "+1 more voice · scroll", then the transcript.
- task9-fix2-log-600-dark.png: Log at 600 pt. The sidebar is below the title bar.

Remaining (Task 8): at 600 pt the sidebar's own content is taller than the window, so its permissions card falls below the bottom edge. The card is cut off; it does not overlap anything. The sidebar needs to compress or scroll at that height.
