# One recording, two calls: design

Date: 2026-11-17. Status: approved by the owner on 2026-11-17 ("design looks fine"). The owner answered the question about Delete on the same day: "yes delete removes".

## Intent

On 2026-11-17 the owner had a 1:1 in Google Meet and then a group call in Google Meet, each with its own link and
its own calendar event. Mossad recorded both as one meeting of 146 minutes with the title of a third event that the
owner did not join. The note of the group call then held the 1:1.

The owner's words: "I just don't want it to combine meetings. Fix this meeting manually and then make sure it
doesn't happen again." The owner also wants a Chrome extension, designed with this work, that tells Mossad for sure
which call the browser is in and whether the microphone is muted, also when the tab is hidden.

## Why it happened (from the log and the code)

1. While a browser call records, `DetectionService.browserCandidate` counts any tab of the call's platform as "the
   call is present". The link of the call is read only at the start. The microphone stayed in use, so the second
   link was the same call to the detector.
2. Two copies of Chrome ran (one was a test browser of another tool). `BrowserTabProbe` reaches one copy only, and
   `MeetingMatcher.trustedTabs` makes a list with no meeting "unknown" when more than one copy runs. The recording
   started from the window title and has no `meetingID`, so even a link rule on the tab list could not have seen
   the change.

## What was tried and rejected

Branch `fix/call-change` ended the first recording when the link changed and let the normal start begin a second
one. The review found that the second start is a separate decision that can fail, so a whole call can have no
recording, and that a reload, a breakout room, or a waiting update can cut or lose audio of a live call. A change
in the detector that can lose a call is worse than the defect. Its pure type `CallLinkWatch` is kept as an observer.

## Goals

- Two calls that follow each other in one recording become two meetings, each with its own title, people, summary,
  and note, with no action by the owner.
- No audio is lost: not at the change, not by a wrong guess, not by a crash in the middle of the work.
- During a call, nothing new can stop a recording.
- With one call in a recording, Mossad is exactly as today.
- The meeting of 2026-11-17 is repaired.

## Non-goals

- No "Split" command in the app. The owner did not ask for one.
- No change for the Zoom and Teams desktop apps in the first version: they give no link. (A later version can use
  the window title and the calendar for them.)
- No join of two meetings by hand.

## Anti-goals

- A cut in the wrong place of one real meeting (a breakout room, a reload, a second tab) is a failure. When the
  evidence is not good enough, Mossad does not cut.
- The extension must never be needed. Without it, everything works as well as the probes allow.

## The design in one paragraph

The recorder keeps one recording, as today. When Mossad sees that the call changed, it writes a **mark** into the
record with the time and the new link. It does not stop anything. When the recording ends, a pure rule reads the
marks and the calendar and decides where the recording is cut, if at all. A resumable **cut** step then makes two
recordings from one, before transcription, and each goes through the pipeline as its own call. The Chrome
extension is the sure source of marks and of the mute state; the tab list and the window title are the sources
without it.

## Part 1: the cut

`RecordingCut` in MossadCore (`.../Records/`), with a pure plan and a step in `Pipeline` that follows the pattern of
`merge` and `finishInterruptedMerges`.

**Input.** A call id and one or more cut times in seconds of the recording's own timeline (the timeline of
`me.caf` and `them.caf`, which leaves paused time out).

**Refused when:** the call records now or is in work, it is notes-only or a phone call, `moveTo` is set and a move
has started, `mutedAudioPending` is true (the silence is written first), a merge or a cut is in progress, the raw
tracks are gone (after retention only `recording.m4a` is left) or are only in the backup, or a part would be
shorter than `ProcessingQueue.minimumCallDuration`.

**Result.** For N cut times, N+1 new recordings at status `recorded`. The original is removed only when every part
is safely on disk.

**Ids.** Each part gets a new id from its own start by `CallRecorder.callID(for:)` and `freeCallID`. The original's
id is never used again in this profile.

**Steps, each saved in a ledger `cut.json` in the original's folder:**
1. `copying`: each part is written to `Audio/<part id>.cutting/`: both tracks by a ranged copy of 16 kHz samples,
   the frames of its time range under new offset names with their `frames.json`, and its `call.json`.
2. `checked`: the frame counts of the parts add up to the original's for each track, and each file is synced.
3. `published`: one rename per part to `Audio/<part id>/`. Each part has `cutFrom` (the original's id).
4. `forgetting`: everything Mossad derived from the original is forgotten (see below).
5. `removed`: the original's folder and note are gone; the ledger moves to the first part and is deleted last.

A stop before `published` rolls back (the `.cutting` folders are removed, the original is untouched). A stop after
it goes forward at the next launch (`finishInterruptedCuts`, run where `finishInterruptedMerges` runs). The cut
waits while a call records (`HeavyWorkGate`), and its copy runs at background priority.

**What each part gets.** One table, `CutRecord.fields`, gives every stored field of `CallRecord` a rule, and a test
proves that no field is without one (the pattern of `MovedRecord.fields`). The rules:
- Divided by time, with the offsets of a later part moved back by the cut time: `markers` (bookmarks and their
  notes too), `muteSpans`, `screens`, `screenGaps`, `deletedScreens`, `parts`, and the call marks.
- `start` and `end`: the wall time of the cut. A new optional field `pauses` (each pause with its place in the
  recording and its two wall times) gives it from now on. An older record has no such map: the wall time is then
  the start plus the cut time, which is right for a call with no pause.
- `meetingID`: the first part keeps the original's; a later part takes the link of its mark.
- The same in each part: `platform`, `bundleID`, `speakersExpected`.
- Cleared, because the pipeline makes them again for each part: the lines, the speaker names and fingerprints, the
  summary and everything from it, the invite and calendar fields (so each part is matched with its own event by
  its own times), the titles, the backup fields (the old copy goes to the delete list), the jobs, the failure.
- The owner's title and tags of the original go to the first part only.
- `moveTo`: see "A recording marked for another profile".

**Files that are not carried:** `recording.m4a` (made again), `coach.json`, `findings.json`, `live.json`,
`call.previous.json`, voice clips.

**Never joined again.** `MeetingMerge.continues` never joins two recordings with the same `cutFrom`.

**What is forgotten of an original that was already written** (the repair case): the steps that a move's removal
runs in the first profile, in the same order and resumable: the voice samples of that call, the coach's memory and
review, the tasks, the points' references to the call, the chats of the call, the share links, the backup copy, the
note, and the folder. The owner's ticks and live marks on points, and the live chat, go to the part in which they
were made (by their time). A person whom only that call made stays: the parts make the same person again.

For a recording that is cut right after the call (the normal case) nothing is derived yet, so this step is empty.

## Part 2: marks during the call

A new optional field `CallRecord.callMarks`: each mark has the second of the recording, the wall time, the new
link (when known), the platform, the source (`extension`, `tabs`, `title`), and whether the source was sure. The
recorder writes it as it writes a bookmark (`CallRecorder.edit`), so a pause, a crash, and a recovery keep it.

Sources, in the order of trust:
1. **The extension** (Part 4): "left the call of link A" and "joined the call of link B". Sure.
2. **The tab list** when it is sure: `CallLinkWatch` as an observer, with a time limit on its count (two readings
   within 10 s, the rule of `goneReadingGap`). A call with no link adopts the link of the one meeting tab.
3. **The window title** (Accessibility, every copy of the browser answers): the selected tab's title changes from
   one "Meet - …" title to another one, and stays for two readings. Not sure by itself.

Rules:
- A mark never ends a recording and never starts one.
- **Do not record (changed after the review of the marks, 2026-11-17):** a mark never ends a recording, also not
  for a meeting under a do-not-record rule. The review found that this one exception could end a live call of the
  owner by a wrong mark. So in release A a do-not-record meeting that follows a recorded call with no gap is
  recorded and, after the cut, is its own meeting, which the owner can delete. Before this work it was joined to
  the first call. Release B looks at this again, with the extension's sure signal.
- While a change waits for its second reading, the tabs are read at most once per tick, and the probe's own
  back-off holds.
- The live page, the Now card, and the live transcript go on unchanged after a mark. (The title in the window
  stays the first call's until the call ends. This is accepted for the first version.)

## Part 3: the decision after the call

`CutPlan` (pure, table tests). It runs once when a recording ends, before the first pipeline step, with the
record's marks and the calendar events from `start - 10 min` to `end + 10 min`.

- A **sure** mark to another link is a cut, unless the recording goes back to the first link later and no calendar
  event holds the other link. That is a breakout room or a short visit: one meeting.
- A mark from the **window title** is a cut only when the calendar agrees: another event than the first part's
  starts within 10 minutes before or 15 minutes after the mark, and the first title does not come back.
- Marks closer than `minimumCallDuration` to the start, the end, or each other make no cut.
- With no mark, there is no cut. The calendar alone never cuts: it cannot say where.

The plan logs its decision in counts and reasons, never a title or a link.

**Replay of 2026-11-17:** no tab list (the other copy answered), but the window title changed at 16:02:16 to the
second meeting's, the "Kickoff" event started at 16:00, and the first title did not come back. Result: one cut at
5290 s. With the extension: a sure mark at the same place.

## A recording marked for another profile

"This call is for <profile>" marks the whole recording today. With a cut, each part must be decided alone, and
Mossad does not know for which call the owner made the choice. So: the cut runs first, in the first profile, and
each part is **held** with the existing row "Process here / Move to" (the state that a guessed mark has today).
Nothing of a held part is sent. No new screen is needed.

## Part 4: the Chrome extension

**What it gives Mossad:** for each Meet tab, the meeting code, the state (waiting page, in the call, left), and the
mute state of the microphone, also when the tab is hidden or the window is behind others. Later the same for Teams
and Zoom in the browser.

**Parts:**
- `extension/` in the repository: a Manifest V3 extension. A content script on `meet.google.com` reads the page;
  a service worker sends each change, and a heartbeat, to the native host. Permissions: the Meet site and
  `nativeMessaging`. It reads no page text besides the call controls and sends nothing to any server.
- The native host: `Mossad --browser-host`, started by Chrome, speaking Chrome's length-prefixed messages on
  stdio. It takes no lock and reads no meeting. It writes what it hears to
  `~/Library/Application Support/Mossad/Browser/<host pid>.json` (atomic, mode 0600): the tabs with code, state,
  mute, and the time. The file holds no title and no name.
- The app reads those files on the detection tick and the mute timer, by modification time. A file is used only
  while its host lives and its time is fresh; otherwise it is "unknown" and the probes decide as today.
- The mute state from the extension takes the place of `AccessibilityMuteProbe`'s reading for that call when it is
  there. `MuteTracker` and the recorder's rule do not change.
- Setup: Settings > General gets one row "Browser extension" with its state (Connected, Not installed) and "Set
  up…", which opens a sheet with the steps. The app writes the host's manifest file for Chrome (and for Edge,
  Brave, and Arc when they are installed). The steps are in the sheet, not in Settings.

**How people get it.** First version: the extension folder ships inside the app, and the sheet shows how to load it
in Chrome ("Load unpacked"). Chrome shows its own notice about developer-mode extensions at each start. The Chrome
Web Store (one account, a review) is the next step and needs the owner's word.

**Two copies of the browser.** Each copy with the extension has its own host and file. A copy without it reports
nothing, and for that copy the probes decide. A call that the extension reported is known by its own reports, so a
second copy cannot hide its end.

## The repair of the meeting of 2026-11-17

A command for this one use: `Mossad --cut <call id> --at <seconds>` (in `AppIdentity.commands`, with the folder
lock, refused while Mossad is open, like `--people-migration apply`). It runs the same cut step, with the
"forgetting" step for a written meeting. The parts are transcribed and summarized again; the cost is one more
transcription of 146 minutes. Cut time: 5292 s (16:02:18), found from the line times: one voice ends at 5290 s and
four new voices start at 5294 s. Part 1 is the 1:1, part 2 the kickoff.

The command stays in the app as a tool for support. It has no menu item.

## Order of work

1. **Release A:** the cut (Part 1), the command, the marks from the tab list and the window title (Part 2), the
   decision (Part 3), and the held parts for a marked recording. Then the repair.
2. **Release B:** the extension, the host, the setup sheet, and the mute state from the extension (Part 4).

Each release: Opus builders, a Fable review, the website with the release.

## Decisions that are mine, for the owner to check

- A written meeting that is cut is transcribed again. The other way (divide the old transcript) keeps the cost at
  zero but needs a rule for every derived store, and a line that crosses the cut.
- The parts of a recording marked for another profile are held for the owner, not moved.
- The window title cuts only with the calendar's agreement.
- The first version of the extension is loaded by hand.
- The host hands its facts to the app through small files, the pattern the workers use. No socket.

## Details settled after a builder's read of this design

- **Times.** A mark and a cut time are seconds of the recording's own timeline, taken from the recorder's clock
  when the mark is written. Wall time is used only to match the calendar.
- **A merged meeting.** `parts` (the map of a meeting that was joined from two recordings) is divided by its
  offsets; a part that the cut crosses becomes two, each with wall times from its own start and offset.
- **Ids.** A part's id comes from its own start. While the original's folder exists, the first part cannot take
  the original's id (the rule of `freeCallID`, which the cut makes usable from outside the recorder). After the
  removal no recorder can make that id again, because it is a past second.
- **A sure mark needs no calendar.** The calendar only decides the breakout case and the window-title case.
- **A first part with no link** keeps no link. A later part takes its mark's link.
- **A bookmark exactly on the cut** goes to the later part.
- **The repair command** prints the recording's length, its pauses, and its merged parts, and refuses a time that
  is not inside the audio. The meeting of 2026-11-17 has no pause, no merged part, and a copy in the backup.
- **The extension's id** is fixed by a `key` in its manifest, so the host's manifest can name it in
  `allowed_origins`.
- **The host's manifest** goes to the standard `NativeMessagingHosts` folder of each Chromium browser that is
  installed. A browser that is not installed gets nothing.
- `CallLinkWatch` comes from the branch `fix/call-change`, as the pure type and its tests only. The wiring of that
  branch (`linkChanged`, `nextCall`) is not taken.

## Delete removes everything of the meeting (the owner's decision)

The code read found that Delete of a meeting left the voice samples learned from it, its tasks, its points, and its
chats. The owner decided: Delete removes them. Delete now runs the same full removal as the cut and the move
(`CallForget`): the voice samples of that call, the coach's memory of it, its tasks, the points' references to it
and the points that were for that one meeting, its chats, its share links, its backup copy, its note, and its
folder. A person stays, also one whom only that meeting made: the owner deletes a person on the People page.

## Left to the builder

The exact names, the split of files, the audio copy's buffer sizes, the layout of the setup sheet, and the tests
beyond the tables named here.
