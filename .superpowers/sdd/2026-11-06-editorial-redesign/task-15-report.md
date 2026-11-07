# Task 15 report: Settings, server setup, Log, Welcome, menu bar

Status: DONE_WITH_CONCERNS

## Commits
- 43744f8 Settings as a second column, pages in the label column, org chart in General, sync radio rows, server setup sheet.
- 8c9912d Menu bar panel, Log, Welcome, talk-share (MossadCore, test first), preview hooks.
  Note: 43744f8 alone does not build (it uses the new `TurnOffMenu { label }` from CallControls in 8c9912d). The pair builds.

## Build and test
- Mac Debug build: BUILD SUCCEEDED.
- `swift test`: 634 tests, 0 failures (17 skipped). New: `LiveTalkShareTests` (3), written first and seen to fail.

## Files
- New: App/SettingsParts.swift (SettingsGroup, rows, 24 pt fill controls, FillPicker, RadioRow, KeyStatus, CopyField, StatusLine),
  SettingsGeneral.swift, SettingsRecording.swift, SettingsAI.swift, SettingsCoach.swift, ServerSetupSheet.swift, PanelPreview.swift,
  MossadCore Transcription/LiveTalkShare.swift (+ tests).
- Rewritten: SettingsView.swift (shell, list, SettingsPage, KeySheet), SyncSettings.swift, StorageSettings.swift, LogView.swift,
  WelcomeView.swift, MenuContent.swift. CallControls.swift: `showsStop`, compact controls keep full labels; PowerControl removed,
  TurnOffMenu takes a label.

## Preview hooks added (preview only)
- `--open-window MenuPanel`: the panel content in its own window on a desktop-like ground.
- `--show-recording` now reads `MOSSAD_RECORDING_PLATFORM` (inPerson|zoom|teams|meet) and `MOSSAD_RECORDING_SECONDS`. Nothing records.
- `MOSSAD_WELCOME_STEP=1|2|3` with `--welcome-inline`.

## Captures (/private/tmp/claude-501/redesign-shots/)
task15-{general,recording,ai,sync,coach}-{light,dark}.png, task15-server-setup-dark.png, task15-log-{light,dark}.png (log from a temp
MOSSAD_ROOT with made-up lines), task15-welcome-light.png, task15-welcome2-dark.png, task15-welcome3-light.png,
task15-panel-waiting-light.png, task15-panel-recording-{dark,light}.png (room with 5 voices; Zoom muted). Keys show only as "Key set".

## Every old setting and where it lives now
General
- [x] On/off, Turn off for 1 h / until tomorrow / 3 days / 1 week / until I turn it on, Turn on: General › Mossad
- [x] Your name, Company (optional), Open Mossad at login: General › You
- [x] Permissions with live state and fix button (Grant… / Open browser / Open Settings…), "N need attention": General › Permissions
- [x] Recording consent note: under Permissions
- [x] Version, Check for Updates…, check automatically, download and install automatically: General › Updates
- [x] NEW Org chart: file name, people and level counts, import date, Replace… / Import… (OrgImportSheet, OrgState loaded on appear), Open org chart (People in org mode)
Recording
- [x] Live transcript while recording (help text kept): Recording › Recording
- [x] Delete recordings after a period + Keep audio for N days: Recording › Recording
- [x] Recognize voices, Delete all saved voices… (confirmation kept): Recording › Voices
- [x] Calendars grouped by account with checkboxes, empty note: Recording › Calendars
- [x] Storage: Keep recordings in (This Mac / R2 / S3), Endpoint, Bucket, Region (S3), Access key ID, Secret access key (Keychain, Save), Keep a local copy for N days, Test connection with result: Recording › Storage
- [x] Folders Meetings / Audio / Voices with Open: Recording › Folders
AI
- [x] Transcription provider, model (when several), note, ratings; its key row: AI › Providers
- [x] AI provider, model picker (OpenRouter field + Choose), ratings; its key row; AssemblyAI key row when live transcript uses it: AI › Providers
- [x] Key sheet (Keychain only, never shown): shared KeySheet
- [x] Claude Code and Claude Desktop MCP snippets with Copy: AI › Use your meetings in other AI apps
Sync & Server
- [x] iCloud / Your server / Don't sync as radio rows with status: Sync › Sync to
- [x] Finish setting up (Set up…): Sync › Your server
- [x] Server host, description, menu: Copy secret, Change server…, Disconnect… (confirmation kept); Sync now row with last sync / failure (offline line per States): Sync › Your server
- [x] iPhone pairing (Show code opens the QR card with a countdown, hides after a minute), Also send through iCloud Keychain, Use my AI key on my iPhone: Sync › Your iPhone
- [x] iCloud: Sync now and Use my AI key on my iPhone: Sync › iPhone
- [x] ChatGPT and other AI apps: address with Copy, how-tos, Copy secret: Sync › ChatGPT and other AI apps
- [x] Share links: open meeting, details and stats, Copy link, Stop sharing (confirmation kept): Sync › Share links
- [x] Server setup sheet, all four steps and checks, iPhone-through-server switch, progress, Try again: ServerSetupSheet
Coach
- [x] Review each call (turns the coach on), Voice: Coach › Communication coach
- [x] Proposed focus (Accept, Edit/Save, Not now) or active focus with dots and chances: Coach › Proposed focus / Your focus
- [x] "Is this right?" (Yes, Not quite… with note, No, open the moment): under the focus
- [x] Questions you answered (disclosure): Coach › Questions you answered
- [x] What the coach knows (each kind, Remove, Add) and coaching preferences (Remove): Coach › What the coach knows about you
- [x] Email: Turn on the coach, weekly, monthly, Send to (one-address warning), Send from, provider, Mailgun domain, EU region, SES region and access key ID, provider key, Send now (week / month): Coach › Email
Menu bar panel
- [x] Status (off / waiting / recording, paused), Turn on, Turn off menu, Record a meeting in person, Stop
- [x] Pause/Resume, Bookmark, Skip and delete (confirm), muted banner, talk-share strip (new), processing row, cloud upload row, coach moment
- [x] Next with Join, Recent 3 with needs-names chip, Open Mossad ⌘O, Name voices (count), Settings (dot; opens General when permissions need you), Check for updates…, Quit ⌘Q

## Concerns
- Menu bar: the old Meetings, People, and Log rows and the separate permissions row are gone, per the 3d canvas. Open Mossad reaches every section; the Settings dot and its tooltip and VoiceOver value carry the permissions. Put them back if the owner uses them.
- Welcome step 3 now also offers company and the two provider keys (optional fields; empty is fine), per Welcome.dc.html. When it shows is unchanged.
- The pairing QR now shows in a popover card from Show code, not inside the tile.
- The server setup preview hook draws the sheet without the dimmed ground behind it.
- Previews against ~/Mossad append "Mossad started" to its log, as before this task.
- Theme aliases are not used in the files touched; Theme.swift itself is unchanged (other screens still use it).

## Fix round (review)
- One speaker, one color: MossadCore `LiveTranscript.voice(of:owner:)`, `hue(of:owner:)` (owner 0, A is 1, B is 2; a named voice keeps the hue of the label it was first heard under; a voice named as the owner is the owner) and `talkShares(owner:)` with `hue`. The live transcript's names (LiveViews) and the panel's strip both use it. Tests first: `LiveVoiceHueTests` (3), seen failing.
- Log error ground is the new token `Palette.errorWash`; day groups have a unique id (first line index).
- Previews write no log lines: `Log.writesFile` (false under `--ui-preview`) and `Log.flush()`; test first: `LogFileTests`. `--show-recording` and `--show-muted` only work in a preview.
- RadioRow dims when disabled ("Not in this build").
- General's list line: "On/off, you, permissions, org chart".
- Server setup footer: Cancel / Continue (Continue runs the open step's check, or starts the sync); Done only once the last step started.
- Builds: Mac and iPhone BUILD SUCCEEDED at HEAD. `swift test`: 638 tests, 0 failures (17 skipped).
- Recaptured: task15-fix-panel-recording-dark.png (room voices A to E keep hues 1 to 5, none takes the owner's), task15-fix-log-dark.png, task15-fix-server-setup-light.png, task15-fix-general-light.png.
