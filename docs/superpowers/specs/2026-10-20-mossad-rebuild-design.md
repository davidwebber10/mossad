# Mossad Rebuild — Design

Date: 2026-10-20
Status: Awaiting approval
Replaces: `2026-03-20-mossad-design.md` (the old app is torn down; no code is reused)

## Intent

David has remote calls on Zoom, Google Meet, and Microsoft Teams with work
colleagues. He wants a permanent, searchable record of what was said in every
call, so that afterwards he can tell Claude Code "review this morning's meeting
and build the thing Josh mentioned" (or research it, or implement changes).

The old Mossad was never used because it transcribed live (poor quality), call
detection was unreliable and felt buggy, and speaker audio bled into the laptop
mic so "me" and "them" were mixed up.

The single most important quality is **invisibility**: no clicks, nothing to
remember. David must never think about it. He also explicitly does not want a
Granola-style "click every time" flow — he forgets, so the data is lost.

This is a personal tool for one user on one Mac. It is not distributed.

## Goals (step 1)

1. Detect the start and end of every Zoom / Meet / Teams call automatically,
   with no user action.
2. Capture two clean audio tracks: **me** (microphone, echo-cancelled) and
   **them** (the meeting app's output audio, tapped before it reaches the
   speakers).
3. After the call ends, transcribe in batch (not live) with AssemblyAI.
4. Put real names on speakers. "Me" is known from the mic track. Other voices
   are identified by a local voice-fingerprint library that learns each person
   once and recognises them in every later call.
5. Write one Markdown file per call to a folder that agents can read directly.

## Non-goals (step 1)

- Live transcription or a live transcript view.
- An MCP server (a plain folder of Markdown is enough for Claude Code now).
- Analysis of people, speech style, sentiment, etc. (likely later steps).
- Screen-vision speaker identification. Voice fingerprints come first; screen
  vision (e.g. reading the active-speaker highlight) is a possible later
  fallback only if fingerprints prove too inaccurate.
- iOS. (David called it an "iPhone app"; it was and stays a macOS app.)
- Distribution, App Store, notarisation for others, multi-user support.

## Anti-goals (failure even if it "works")

- Any prompt, click, or confirmation needed to start or stop a recording.
- Error dialogs or windows appearing on their own. Failures go to a log.
- Missed calls because detection was flaky.
- Speaker audio leaking into the "me" track so the transcript attributes
  someone else's words to David (or doubles them).
- Recording things that are not calls (a YouTube video, a voice memo, a
  dictation in the browser).

## Prior art: what Granola does (reverse-engineered from the installed app)

Inspected `/Applications/Granola.app` v7.668.0 (bundle, entitlements, native
module imports and strings). Findings that shape this design:

- **"Them" audio:** a Core Audio **process tap** (`AudioHardwareCreateProcessTap`)
  attached to a private **aggregate device** (`AudioHardwareCreateAggregateDevice`,
  named "Granola-Aggregate-Audio-Device" / "Granola-Audio-Tap"), read with
  `AudioDeviceCreateIOProcIDWithBlock`. ScreenCaptureKit (`SCStream`) is kept
  only as a fallback. Info.plist has `NSAudioCaptureUsageDescription`.
- **"Me" audio:** a raw `AudioUnit` on the mic, then **WebRTC AEC3** echo
  cancellation using the tapped system output as the reference signal. It
  has a flag `disableEchoCancellationOnHeadphones`.
- **Call detection:** two signals combined.
  - Core Audio process objects: which app (by bundle ID) is currently using
    the mic (`macos_mic_apps_with_devices`).
  - Accessibility API (`AXUIElement…`) reading window titles / browser tab
    URLs to confirm a meeting: Zoom ("Zoom Meeting", "Zoom Workplace"),
    `com.microsoft.teams2`, `teams.microsoft.com`, `teams.cloud.microsoft`, and
    browser tabs for Meet.
- **Diarization / voice embeddings:** a local helper binary built on
  **FluidAudio** (Swift, CoreML; open source) with speaker embeddings,
  agglomerative clustering, and "voice embedding JSON".

## Design

### Platform and shape

- Native macOS app in Swift / SwiftUI. Menu bar only (`LSUIElement`), no Dock
  icon. Launches at login (`SMAppService.mainApp`).
- Minimum macOS: 15 (process taps need 14.4+; David runs macOS 27).
- One process. No XPC service (the old two-process design added complexity
  with no benefit for a personal tool).
- Built from the command line (Xcode 27 is installed); project generator is
  the builder's call.
- Signed with David's local development identity so that TCC permissions
  (Microphone, System Audio Recording, Accessibility, Calendars,
  Notifications) persist across rebuilds.

### Call detection (no clicks)

- Poll Core Audio every ~2 s for process objects
  (`kAudioHardwarePropertyProcessObjectList`) and read each one's bundle ID and
  `kAudioProcessPropertyIsRunningInput`.
- A call **starts** when a meeting app is using the mic **and** the meeting is
  confirmed:
  - Zoom (`us.zoom.xos`): mic in use and a Zoom meeting window exists (AX).
  - Teams (`com.microsoft.teams2`): mic in use and a meeting window exists (AX).
  - Browsers (Chrome, Arc, Safari, Edge, Brave): mic in use and a window or
    tab indicates a meeting on any of the three platforms: Google Meet
    (`meet.google.com`), Teams web (`teams.microsoft.com`,
    `teams.cloud.microsoft`), or the Zoom web client (`app.zoom.us`,
    `*.zoom.us/wc/`) (AX window titles / tab URL).
  - Other call apps (Slack huddles, Webex, FaceTime) are out of scope; David
    does not use them for work calls.
- A call **ends** primarily when the meeting itself is gone (checked every
  ~2 s via AX): the Zoom or Teams meeting window closes, or the browser
  meeting tab closes or navigates away from the meeting. Meet's post-call
  page ("You left the meeting", same URL) counts as gone — detect it by the
  window/tab title. (David found a pure mic-idle timeout too aggressive;
  confirmed.)
- Mic activity alone never ends a call while the meeting window/tab is
  still present. Mutes, headset changes, and device switches do not split a
  call.
- Fallback: if the meeting window lingers but the meeting app has not used
  the mic for 3 minutes, the call ends, and trailing silence is trimmed from
  both tracks.
- Recordings shorter than ~60 s are discarded (accidental mic checks).
- Only one call is recorded at a time.

### Audio capture

- **Them track:** a Core Audio process tap on the detected meeting app's
  process(es) (for browsers, the browser's audio helper processes), via a
  private aggregate device, written to disk as it arrives. Mono, 16 kHz or
  higher. Fall back to a global system-output tap if the per-process tap
  cannot be created.
- **Me track:** microphone through echo cancellation, written to disk.
  Preferred approach: Apple voice processing (`AVAudioEngine` input node
  `setVoiceProcessingEnabled(true)`) — simplest, and it is what FaceTime uses.
  If testing shows bleed from laptop speakers is still audible in the me
  track, switch to WebRTC AEC3 with the them-track as the reference, as
  Granola does. Which one ships is decided by a quick test on David's
  MacBook with laptop speakers (see Acceptance).
  Outcome (2026-10-21): with Chrome in a Meet call, Apple voice processing gave
  Mossad's mic silence for the whole call. The me track is now the raw mic, and
  the transcript echo rule in `TranscriptMerger` removes speaker bleed.
- Both tracks share one start timestamp so they can be aligned.
- Audio is written incrementally so a crash or sleep loses at most a few
  seconds, and a partially recorded call is still processed on next launch.

### Transcription (after the call)

- When the call ends, upload both tracks to AssemblyAI (batch API).
  - Me track: also transcribed with speaker labels. The speaker whose voice
    matches David's fingerprint is "David Webber"; any other voice on the mic
    (someone in the same room) goes through the voice library like any other
    speaker. (Builder's call, settled during review.)
  - Them track: transcribed with speaker labels (diarization).
- Merge both transcripts by timestamp into one conversation.
- If the network is down, queue and retry later. Never lose audio.

### Speaker identity (voice library)

- For each diarized speaker in the them track, compute a voice embedding
  locally with a CoreML speaker-embedding model (FluidAudio is the expected
  choice, as Granola uses it). No audio leaves the Mac for this step.
- Compare against a local voice library (name → one or more embeddings). If
  the similarity is above a threshold, apply the name automatically. Each
  confirmed match adds to that person's embeddings, so recognition improves
  over time.
- Unknown voices: after the call, show **one** macOS notification, e.g. "2 new
  voices in Weekly Ops Sync". Clicking it opens a small panel with, per
  unknown voice, a ~5 s audio clip, a name field, and the calendar attendees
  as suggestions. Saving updates the library and rewrites the Markdown file.
- If ignored, the file keeps "Speaker B" etc. The menu bar menu offers "Name
  voices…" for recent calls with unknown speakers, so it can be done later.
- If AssemblyAI splits one person into two labels, both map to the same name.

### Meeting metadata

- David's work calendar syncs to the macOS Calendar app (confirmed), so
  EventKit is the only calendar source needed.
- Read the Mac's calendars (EventKit) for an event overlapping the call. If
  one matches (prefer one whose meeting link matches the platform), use its
  title and attendee list. Otherwise title it "<Platform> call".

### Summary

- After transcription and naming, send the transcript to Claude (key from
  Doppler `ANTHROPIC_API_KEY`) for a short summary and a
  list of action items/requests, placed at the top of the file.
- If renaming speakers later, the summary is regenerated.

### Output

- Folder: `~/Mossad/Meetings/`.
- One Markdown file per call: `YYYY-MM-DD HHMM - <Title>.md`.
- YAML front matter: date, start, end, duration, platform, calendar title,
  attendees, speakers, audio path, status.
- Body: `## Summary`, `## Action items`, then `## Transcript` with lines like
  `[00:04:12] Alex Rivera: …`.
- Audio files live in `~/Mossad/Audio/` and are deleted after 30 days.
- The voice library lives in `~/Mossad/Voices/` (embeddings, not raw audio,
  plus one short reference clip per person).

### Secrets

- AssemblyAI key: Doppler `ASSEMBLYAI` (project `dispatch`, config `prd`).
  Anthropic key: Doppler `ANTHROPIC_API_KEY`.
- The app reads keys from the macOS Keychain. A one-time setup step copies
  them from Doppler into the Keychain. Keys are never written to files or the
  repo.

### Menu bar

- A small, monochrome icon. It changes (e.g. filled / red dot) while
  recording, and shows a subtle state while processing.
- Menu: status line (Idle / Recording "Weekly Ops Sync" 12:34 / Processing),
  "Open Meetings Folder", "Name voices…" (if any pending), "Skip this call"
  (stops recording and deletes all audio for the current call; nothing is
  uploaded — builder's call, settled during review), Settings (output folder, audio retention days, launch at
  login), "View log", Quit.
- Menu items open a normal app **window** (only when David clicks; it never
  opens on its own). The window has a sidebar with:
  - **Meetings:** list of calls (newest first, with a search field over title
    and transcript text) and a reader for the selected transcript (summary,
    action items, transcript, speakers). Unknown speakers can be named from
    here, and "Reveal in Finder" opens the Markdown file.
  - **Voices:** the voice library — rename, merge, or delete a person.
  - **Settings:** output folder, audio retention days, launch at login,
    key status (set / missing).
  - **Log:** recent log lines.
  (Added by David after design approval.)
- Clicking the post-call notification opens the window on that meeting's
  voice-naming view. No windows open on their own.

### Errors and logging

- All errors go to `os_log` and a rotating log file in `~/Mossad/Logs/`.
- A failed step (upload, transcription, summary) is retried with backoff and
  never deletes audio.

### Consent and scope of recording

- Indiana is a one-party-consent state and David is a party to every call.
  No in-call announcement is added.
- No exclusions: every detected call is recorded (confirmed). "Skip this
  call" is the only manual control.
- The mic is recorded for the whole call, including while David is muted in
  the meeting app (confirmed acceptable). The app does not read mute state.

## Acceptance (how David will know it works)

1. Join a Meet call in Chrome, a Zoom call, and a Teams call without touching
   Mossad. Each produces a Markdown file within a few minutes of hanging up.
2. A YouTube video or browser dictation does not produce a file.
3. On laptop speakers (no headphones), David's lines contain only his words,
   and other people's words are not duplicated under his name.
4. After naming a colleague once, the next call with them labels them
   automatically.
5. Muting for a minute mid-call does not split the call into two files.
6. Leaving the meeting (closing the window or tab, or Meet's "You left the
   meeting" page) ends the recording within a few seconds.

## Decided by David

- Batch transcription after the call, not live.
- Zero clicks, invisible, menu bar icon only.
- Voice fingerprints learned once per person, auto-applied later.
- One notification after a call with new voices is acceptable.
- Step 1 is capture quality; agents read the results later.
- Fresh rebuild; old app is torn down.
- Menu bar options open an app window with Meetings, Voices, Settings, Log.
- Calendar comes from the macOS Calendar app (EventKit).
- Recording while muted in the meeting app is fine.
- Platforms: Zoom, Meet, Teams — native apps and each one in a browser.
- No exclusions.

## Left to the builder

- Project generation tool, folder layout, and dependency management.
- Exact similarity threshold and embedding model (tune with real calls).
- Voice processing vs. WebRTC AEC3 (decide by the acceptance test above).
- Audio formats and sample rates.
- Which Claude model produces the summary and the prompt wording.
