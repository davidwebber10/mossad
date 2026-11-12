# Mossad

Meeting notes for your Mac, with no bot on the call. Mossad is a free, open source menu bar app. It notices your Zoom, Google Meet, and Microsoft Teams calls, records them on your Mac, and writes a Markdown note for each one: a summary, decisions, action items, and a transcript that knows who spoke.

There are no buttons to press. You take your meetings as usual, and a searchable record of each conversation builds up in a folder on your Mac. You choose who transcribes and who writes the notes, or keep it all on your Mac with local models. Later you can point an AI agent at that folder and say "read Tuesday's planning call and build the tool we talked about."

The website is [getmossad.app](https://getmossad.app). Its words are in [`website/content/site.json`](website/content/site.json).

> **Before you use it:** Mossad does not announce itself on the call, so telling people is your job. Let the people on your calls know that you record and transcribe them, and read [Recording consent](#recording-consent) and [Lawful use](#lawful-use) first.

## Contents

- [Screenshots](#screenshots)
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

## Screenshots

<!-- Screenshots go here: the meeting page with the lanes player, the Meetings list with the filter, a person's page, the Coach Findings deck, Analytics, and the iPhone app. -->

Screenshots are coming.

## What it does

**Capture**

- **Finds your calls on its own.** It notices when Zoom, Teams, or a Meet or Teams tab in Chrome, Arc, Safari, Edge, or Brave is in a real meeting, and starts recording. No bot joins the call.
- **Knows when the call is over.** It watches for the meeting window or tab to close instead of guessing from a few seconds of silence.
- **Keeps you and them apart.** Your microphone and the call's audio are two tracks. Echo of the other side that your mic picks up is removed from your track. When you mute in the call app, your track is silent for that time.
- **Stays out of the way.** Pause, stop, or skip a call from the menu bar, mark a meeting as do not record, or record a meeting in a room by hand. Shared screens are captured only if you turn it on.

**Notes and transcripts**

- **One Markdown note per call**, with a summary by topic, decisions with their times, action items, and the transcript.
- **Real titles** from the calendar invite, or from what was said. An optional live transcript shows the call as it happens.
- **A player with one lane per speaker**, bookmarks (Control-Option-B during a call), and a tab for shared screens.

**People and voices**

- **Learns voices.** Name a voice once and Mossad recognizes that person on later calls. If a call had voices it has never heard, you get one notification to name them. You can turn this off.
- **A page for each person** with your meetings, talk time, and their action items, an org chart from a CSV file, and a card on how to present to them after a few calls.

**Meetings, coach, and analytics**

- **Before each meeting**, a page with who is coming, what happened last time, and what you still owe them.
- **Filter and search** every meeting by person, date, topic, kind, size, or platform, and search everything with Command-K. The Tasks page keeps what you promised in your calls.
- **A coach** that gives at most one line of advice per call, always with a moment or a number to back it, plus a Findings deck, goals with a number, and a weekly review.
- **Analytics** for each meeting and for how you communicate over time, plus what each meeting cost.

**Chat, sharing, and sync**

- **Chat** with your meetings, or give Claude, ChatGPT, and other AI apps read access through MCP (`Mossad --mcp`, or your own server).
- **Share one meeting** with a link and an optional PIN, through your own server, and see who opened it.
- **An iPhone app** for your meetings, the coach, and recording meetings in a room. It syncs through iCloud or your own server.
- **Backups** of recordings to Cloudflare R2, Amazon S3, or your own server.
- **Connect Google** (optional, read only) for richer calendar details, your directory, and Gemini notes.

**Your providers**

- **Transcription:** AssemblyAI, Deepgram, ElevenLabs, or OpenAI with your key, or Parakeet, Whisper, Apple Speech, or Qwen3-ASR on your Mac.
- **Notes, chat, and coach:** Anthropic, OpenAI, OpenRouter, a local server such as Ollama or LM Studio, or Apple's on-device model.

Coming soon: recurring meetings with points for next time, a search in every list, person pages with tabs and more than one email, and voice recognition that reads the invite.

## How it works

```
 Call app uses the mic  ──►  Detection  ──►  Recording (two tracks)
                                                   │
                                          call ends│
                                                   ▼
 Markdown note  ◄──  Summary  ◄──  Speaker ID  ◄──  Transcription
```

1. **Detection.** Every two seconds Mossad checks which apps are using the microphone (Core Audio), reads Zoom and Teams windows (Accessibility), and reads browser tab addresses (AppleScript). A call starts when a meeting app is on the mic and a meeting window or tab is open.
2. **Recording.** The "me" track comes from the raw microphone. The "them" track comes from a Core Audio process tap on the call app, so only the call's audio is captured, not your music or notifications.
3. **End of call.** The call ends when the meeting window or tab closes. If that signal is missing, a fallback ends it after three minutes with no mic activity. Calls shorter than one minute are thrown away.
4. **Transcription.** Each track goes to the transcription provider you chose, or to a model on your Mac. The two transcripts are merged by time, and any echo of the other side that leaked into your mic is removed.
5. **Speaker ID.** FluidAudio turns each speaker's audio into a voice embedding on your Mac, which is compared against your saved voices.
6. **Summary and note.** The model you chose writes the summary, decisions, and action items, and the note is saved to `~/Mossad/Meetings`.

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

- macOS 26 or later on Apple silicon
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Development signing certificate
- For transcription, a key for [AssemblyAI](https://www.assemblyai.com), Deepgram, ElevenLabs, or OpenAI, or no key with a local model
- For notes, a key for [Anthropic](https://console.anthropic.com), OpenAI, or OpenRouter, or no key with a local server or Apple's on-device model (without any, notes have a transcript but no summary)

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
| People | Everyone Mossad knows by voice, with a profile for each: meetings, talk time, who they meet with, and their action items. Rename, merge, or delete a person here |
| Settings | Permissions, your name and company, voice recognition, login item, how long to keep audio, folders, key status |
| Log | The last few hundred lines of the app log |

To name a voice, play its five second clip, type the name or pick someone from the meeting's attendee list, and save. The note and summary update right away, and that voice is recognized from then on.

## Where your data lives

Everything stays in your home folder.

| Path | Contents |
| --- | --- |
| `~/Mossad/Meetings/` | One Markdown note per call. Kept forever. |
| `~/Mossad/Audio/<call id>/` | `recording.m4a` (both sides mixed, kept forever, about 14 MB an hour), the two raw tracks (deleted after 30 days by default), and `call.json` with the processing state. |
| `~/Mossad/Voices/voices.json` | Saved voice fingerprints and names |
| `~/Mossad/Logs/mossad.log` | The app log, rotated at 5 MB |

Audio goes to the transcription provider you chose, and the transcript goes to the AI provider you chose, unless you choose models that run on your Mac. Nothing else leaves your Mac unless you turn on sync, backup, sharing, Google, or the weekly email.

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
- `--open-window Settings` (or `Meetings`, `People`, `Log`) opens the window on launch.

### Releases

`scripts/release.sh <version> "notes"` builds, signs the update with the Sparkle key, and publishes a GitHub release with the appcast. The private Sparkle key lives in the login Keychain. A backup is in Doppler as `SPARKLE_PRIVATE_ED_KEY` (project `dispatch`, config `prd`). To restore it on a new Mac, run this once:

```sh
doppler secrets get SPARKLE_PRIVATE_ED_KEY --project dispatch --config prd --plain > /tmp/sparkle.key
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f /tmp/sparkle.key && rm -P /tmp/sparkle.key
```

Without this key, installed copies cannot accept new updates.

The design is written up in [`docs/superpowers/specs/2026-10-20-mossad-rebuild-design.md`](docs/superpowers/specs/2026-10-20-mossad-rebuild-design.md). If you are an AI agent working in this repo, start with [`AGENTS.md`](AGENTS.md).

## Recording consent

Mossad records calls automatically and does not tell the other people on the call. You are responsible for using it lawfully.

- **Consent laws differ.** Some US states and many countries require the consent of every person on a call before it is recorded (for example California, Florida, Illinois, Maryland, Massachusetts, Pennsylvania, and Washington, and much of the EU under the GDPR). Other places require only one person's consent. On a call, the strictest law of any participant's location can apply.
- **Tell people.** Let the other participants know you record and transcribe calls, or get their consent. A line in your calendar invites or a quick mention at the start of the call works.
- **Employer and customer rules.** Company policies and contracts can forbid recording even where the law allows it.
- **Voice data.** Mossad stores voice fingerprints of the people it hears. Some laws treat voiceprints as biometric data with extra rules (for example the Illinois Biometric Information Privacy Act). Delete a person's voice in **People** if you do not have the right to keep it, use **Delete all saved voices** in Settings, or turn off **Recognize voices** so no fingerprints are stored at all.
- **Third-party services.** Audio goes to AssemblyAI and transcripts go to Anthropic.
- **Skip a call.** **Skip this call** in the menu stops the recording and deletes it.

This is not legal advice. If you are not sure, ask a lawyer.

## Status and known limits

Mossad is a personal tool and is still being tested on real calls.

- The Teams and Meet end-of-call rules are based on window and tab titles and still need tuning against real calls.
- Echo removal relies on Apple's voice processing. On laptop speakers in a loud room, some of the other side can still leak into your track.
- Only Zoom, Google Meet, and Microsoft Teams are detected. Supported browsers are Chrome, Safari, Arc, Edge, and Brave.

## License

Mossad is free and open source software, released under the [MIT License](LICENSE). You may use, copy, change, and share it, including for commercial use, as the license describes.

## Disclaimer

Mossad is provided "as is", without warranty of any kind, express or implied, including the warranties of merchantability, fitness for a particular purpose, and non-infringement. The authors and contributors are not responsible or liable for any claim, damage, loss, or other liability that comes from the software or from its use, including lost or wrong recordings, transcripts, summaries, or notes, and costs charged by third-party services that you connect.

Mossad gives no legal, medical, or professional advice. Summaries, action items, coaching, and person notes are made by software and can be wrong; check them before you act on them.

## Lawful use

Use Mossad only in a lawful way. You alone are responsible for your use of it, including:

- **Consent to record.** Many places require the consent of one or of all people before a call is recorded. Tell the people on your calls, and get consent where the law requires it.
- **Privacy and biometric laws.** Voice fingerprints and notes about people can be personal or biometric data under laws such as the GDPR, CCPA, or BIPA. Follow the laws that apply to you and to the people you record.
- **Your organization's rules.** Follow your employer's policies and the terms of the services you connect (for example Zoom, Google, Microsoft, AssemblyAI, Anthropic, OpenAI, and Cloudflare).

Do not use Mossad to record people secretly, to harass or monitor anyone, or for any purpose that is against the law.

## Trademarks

Zoom, Google Meet, Gemini, Microsoft Teams, and other names in this project belong to their owners. Mossad is not affiliated with, endorsed by, or sponsored by any of them.
