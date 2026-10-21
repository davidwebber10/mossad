# Mossad

Automatic meeting notes for your Mac. Mossad is a menu bar app that records your Zoom, Google Meet, and Microsoft Teams calls, transcribes them after the call ends, works out who said what, and saves a Markdown note for every meeting.

There are no buttons to press and no bot joins your call. You take your meetings as usual, and a searchable record of each conversation builds up in a folder on your Mac. Later you can point an AI agent at that folder and say "read Tuesday's planning call and build the tool we talked about."

> **Before you use it:** Mossad does not announce itself on the call, so telling people is your job. Let the people on your calls know that you record and transcribe them, and read [Recording consent](#recording-consent) first.

## Contents

- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [What a meeting note looks like](#what-a-meeting-note-looks-like)
- [Requirements](#requirements)
- [Setup](#setup)
- [Using it](#using-it)
- [Where your data lives](#where-your-data-lives)
- [Project layout](#project-layout)
- [Development](#development)
- [Recording consent](#recording-consent)
- [Status and known limits](#status-and-known-limits)
- [License](#license)

## What it does

- **Finds your calls on its own.** It notices when Zoom, Teams, or a Meet or Teams tab in your browser is using the microphone for a real meeting, and starts recording.
- **Knows when the call is over.** It watches for the meeting window or tab to close instead of guessing from a few seconds of silence.
- **Keeps you and them apart.** Your microphone and the call's audio are recorded as two separate tracks. When the other side comes out of your laptop speakers and your mic picks it up, Mossad finds those words in both tracks and drops them from yours, so they are not labeled as you.
- **Transcribes after the call.** Nothing is transcribed live. When the call ends, the audio goes to AssemblyAI in one batch.
- **Learns voices (optional).** Each speaker gets a voice fingerprint. Name a new voice once and Mossad recognizes that person on later calls. You can turn this off in Settings.
- **Summarizes.** Claude writes a short summary and a list of action items for each call.
- **Uses your calendar.** The meeting title and attendee list come from the matching event in the macOS Calendar app.
- **Asks for one thing at most.** If a call had voices it has never heard, you get a single notification to name them. That is the only time it asks for anything.

## How it works

```
 Call app uses the mic  ──►  Detection  ──►  Recording (two tracks)
                                                   │
                                          call ends│
                                                   ▼
 Markdown note  ◄──  Summary  ◄──  Speaker ID  ◄──  Transcription
```

1. **Detection.** Every two seconds Mossad checks which apps are using the microphone (Core Audio), reads Zoom and Teams window titles (Accessibility), and reads browser tab addresses (AppleScript). A call starts when a meeting app is on the mic and a meeting window or tab is open.
2. **Recording.** The "me" track comes from the raw microphone. The "them" track comes from a Core Audio process tap on the call app, so only the call's audio is captured, not your music or notifications. Both are saved as 16 kHz mono files.
3. **End of call.** The call ends when the meeting window or tab closes. If that signal is missing, a fallback ends it after three minutes with no mic activity. Calls shorter than one minute are thrown away.
4. **Processing.** Each track is uploaded to AssemblyAI with speaker labels. The two transcripts are merged by time, and any echo of the other side that leaked into your mic is removed.
5. **Speaker ID.** FluidAudio turns each speaker's audio into a voice embedding, which is compared against your saved voices.
6. **Summary and note.** Claude writes the summary and action items, and the note is saved to `~/Mossad/Meetings`.

Each step saves its result before the next one starts. If your Mac sleeps, the network drops, or the app quits halfway, processing picks up where it left off and retries with backoff.

## What a meeting note looks like

```markdown
---
date: 2026-10-20
start: "14:30"
end: "15:02"
duration_minutes: 32
platform: Google Meet
title: "Weekly Ops Sync"
attendees: ["Jamie Ortiz", "Amy Lee"]
speakers: ["David Webber", "Jamie Ortiz", "Speaker A"]
audio: ~/Mossad/Audio/20261020-143000
---
# Weekly Ops Sync

## Summary

The team confirmed the Friday cushion shipment.

## Action items

- [ ] Jamie Ortiz: confirm freight

## Transcript

[00:00:05] David Webber: Morning, everyone.
[00:04:12] Jamie Ortiz: Cushions ship Friday.
[01:02:05] Speaker A: Who owns freight?
```

Notes are named like `2026-10-20 1430 - Weekly Ops Sync.md`, so they sort by date in Finder and are easy for an agent to find.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Development signing certificate
- An [AssemblyAI](https://www.assemblyai.com) API key for transcription
- An [Anthropic](https://console.anthropic.com) API key for summaries (optional; without it, notes have a transcript but no summary)

## Setup

1. **Clone and set your signing team.** In `project.yml`, change `DEVELOPMENT_TEAM` to your own Apple team ID.

2. **Build and install.**

   ```sh
   scripts/build.sh
   ```

   This generates the Xcode project, builds a Release copy, installs it to `/Applications/Mossad.app`, and opens it. Pass `--no-launch` to skip opening it.

3. **Add your API keys.** Mossad reads its keys from the macOS Keychain. To store them, run the app once with the keys in its environment:

   ```sh
   ASSEMBLYAI_API_KEY=your-assemblyai-key \
   ANTHROPIC_API_KEY=your-anthropic-key \
   /Applications/Mossad.app/Contents/MacOS/Mossad --import-keys
   ```

   If you use Doppler, `scripts/import-keys.sh` does the same thing from a Doppler project. Set `MOSSAD_DOPPLER_PROJECT` and `MOSSAD_DOPPLER_CONFIG` to point it at yours.

4. **Turn on permissions.** Click the waveform icon in the menu bar, open **Settings**, and click each red row until it turns green. For Accessibility and System Audio Recording, a small panel appears under System Settings with the Mossad icon. Drag the icon into the list and flip the switch.

5. **Tell Mossad who you are.** In **Settings**, enter your name (it labels your side of each call) and, if you like, your company name (it gives the summaries context). Turn off **Recognize voices** if you do not want voice fingerprints stored.

That's it. Mossad starts at login and stays out of the way.

## Using it

Most days you will not touch it. When you do:

| Menu item | What it does |
| --- | --- |
| Status line | Shows "Idle" or what is being recorded |
| Skip this call | Stops the current recording and deletes it |
| Fix permissions | Appears only when a permission is missing |
| Meetings | Browse and search every call, read summaries, retry a failed one |
| Name voices | Put names on new voices from a recent call |
| Voices | Rename, merge, or delete saved voices |
| Settings | Permissions, your name and company, voice recognition, login item, how long to keep audio, folders, key status |
| Log | The last few hundred lines of the app log |

To name a voice, play its five second clip, type the name or pick someone from the meeting's attendee list, and save. The note and summary update right away, and that voice is recognized from then on.

## Where your data lives

Everything stays in your home folder.

| Path | Contents |
| --- | --- |
| `~/Mossad/Meetings/` | One Markdown note per call. Kept forever. |
| `~/Mossad/Audio/<call id>/` | The two audio tracks and `call.json` with the processing state. Audio is deleted after 30 days by default. |
| `~/Mossad/Voices/voices.json` | Saved voice fingerprints and names |
| `~/Mossad/Logs/mossad.log` | The app log, rotated at 5 MB |

Audio is sent to AssemblyAI for transcription, and the transcript is sent to Anthropic for the summary. Nothing else leaves your Mac.

## Project layout

```
App/                      SwiftUI and AppKit app: menu, window, settings, notifications
Packages/MossadCore/      All the logic, as a Swift package with its own tests
  Detection/              Which app is on the mic, meeting windows and tabs, start and end of calls
  Capture/                Process tap, microphone, and the audio file writer
  Records/                The call record and the processing queue
  Transcription/          AssemblyAI client and the two-track merge
  Voices/                 Voice library, embeddings, and speaker matching
  Calendar/               Matching a call to a calendar event
  Summary/                Claude summary and action items
  Output/                 Markdown writer
  Pipeline/               Runs a call through every step, resumes after failures
  Support/                Paths, logging, Keychain, retention, permissions
docs/superpowers/         Design specs and implementation plans
scripts/                  Build and key import scripts
project.yml               XcodeGen project definition
```

## Development

```sh
cd Packages/MossadCore && swift test
```

The tests cover detection, recording, merging, voice matching, the pipeline, and the Markdown output, all without network access. A separate set of live tests calls the real AssemblyAI and Anthropic APIs and is skipped unless the keys are in the environment.

Two hooks help when testing by hand:

- `MOSSAD_ROOT=/some/folder` makes the app use a different data folder instead of `~/Mossad`.
- `--open-window Settings` (or `Meetings`, `Voices`, `Log`) opens the window on launch.

The design is written up in [`docs/superpowers/specs/2026-10-20-mossad-rebuild-design.md`](docs/superpowers/specs/2026-10-20-mossad-rebuild-design.md). If you are an AI agent working in this repo, start with [`AGENTS.md`](AGENTS.md).

## Recording consent

Mossad records calls automatically and does not tell the other people on the call. You are responsible for using it lawfully.

- **Consent laws differ.** Some US states and many countries require the consent of every person on a call before it is recorded (for example California, Florida, Illinois, Maryland, Massachusetts, Pennsylvania, and Washington, and much of the EU under the GDPR). Other places require only one person's consent. On a call, the strictest law of any participant's location can apply.
- **Tell people.** Let the other participants know you record and transcribe calls, or get their consent. A line in your calendar invites or a quick mention at the start of the call works.
- **Employer and customer rules.** Company policies and contracts can forbid recording even where the law allows it.
- **Voice data.** Mossad stores voice fingerprints of the people it hears. Some laws treat voiceprints as biometric data with extra rules (for example the Illinois Biometric Information Privacy Act). Delete a person's voice in **Voices** if you do not have the right to keep it, use **Delete all saved voices** in Settings, or turn off **Recognize voices** so no fingerprints are stored at all.
- **Third-party services.** Audio goes to AssemblyAI and transcripts go to Anthropic.
- **Skip a call.** **Skip this call** in the menu stops the recording and deletes it.

This is not legal advice. If you are not sure, ask a lawyer.

## Status and known limits

Mossad is a personal tool and is still being tested on real calls.

- The Teams and Meet end-of-call rules are based on window and tab titles and still need tuning against real calls.
- Echo removal relies on Apple's voice processing. On laptop speakers in a loud room, some of the other side can still leak into your track.
- Only Zoom, Google Meet, and Microsoft Teams are detected. Supported browsers are Chrome, Safari, Arc, Edge, and Brave.

## License

Mossad is released under the [MIT License](LICENSE). It is provided "as is", without warranty of any kind, and the authors are not liable for how it is used. You are responsible for following the recording, privacy, and biometric laws that apply to you and to the people on your calls.
