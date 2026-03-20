# Mossad — Local Meeting Transcription App

## Overview

Mossad is a native macOS menu bar application that automatically detects when the user is on a Google Meet, Zoom, or Microsoft Teams call, captures the audio locally, streams it to AssemblyAI for real-time transcription with speaker diarization, and stores everything in a local SQLite database. The app includes a conversation browser with full-text search.

The goal is zero-effort transcription: the app runs in the background, and the user never has to think about recording or transcribing meetings.

## Architecture

### Two-Component Design

The app ships as a single `.app` bundle containing two components that communicate via XPC (Apple's native inter-process communication):

**1. Menu Bar App (SwiftUI)**
- Lives in the macOS menu bar
- Shows recording status (idle / recording with meeting name and elapsed time)
- Provides quick actions: pause recording, open conversation browser, settings
- Hosts the main conversation browser window (search + browse)
- Manages settings UI (AssemblyAI API key entry, etc.)

**2. Background XPC Service**
- Runs independently of the UI
- Process Monitor: polls every 3 seconds for active meeting apps
- Audio Capture: manages ScreenCaptureKit and AVAudioEngine streams
- AssemblyAI Client: maintains WebSocket connection for real-time transcription
- Calendar Sync: queries EventKit for meeting metadata
- Storage: reads/writes SQLite database
- Notifies the menu bar app of state changes via XPC callbacks

### Why XPC

XPC keeps audio capture and network I/O isolated from the UI process. The menu bar app stays responsive regardless of transcription load. The background service can survive UI restarts. Both components ship inside a single `.app` bundle — no separate installation.

## Call Detection

### Process Monitoring

The background service polls every 3 seconds for active meeting processes:

- **Zoom**: `zoom.us` process with an active audio session
- **Google Meet**: Chrome, Edge, Arc, or Safari tab with a `meet.google.com` URL (detected via Accessibility APIs or AppleScript to query browser tab URLs)
- **Microsoft Teams**: `Microsoft Teams` process with an active audio session

When a meeting process is detected with active audio, the service transitions to the "call detected" state.

### Calendar Matching

When a call is detected, the service queries EventKit for calendar events:

1. Query for events in a ±10 minute window around the current time
2. Extract meeting URLs from event notes, location, and structured URL fields
3. Match the meeting URL against the detected platform:
   - Zoom: match the meeting ID from the Zoom process against calendar event Zoom links
   - Google Meet: match the Meet link from the browser tab URL against calendar event Meet links
   - Teams: match the Teams meeting link against calendar event Teams links
4. If a match is found: attach the event title, attendee list, and organizer to the conversation
5. If no match: label the conversation as "Ad-hoc [Platform] Call" with a timestamp

### Edge Cases

- **Overlapping events**: URL matching disambiguates. If no URL match, use the event closest to the current time.
- **No calendar sync**: the app works without calendar access — conversations are just labeled as ad-hoc.
- **Multiple browsers**: check all known browsers for Google Meet tabs.

## Audio Capture

### ScreenCaptureKit (App Audio — What Others Say)

macOS 13+ ScreenCaptureKit can capture audio from specific applications without a virtual audio driver. The service:

1. Identifies the meeting app's process ID
2. Creates an `SCContentFilter` targeting that specific app
3. Configures an `SCStream` for audio-only capture (no screen recording needed)
4. Receives PCM audio buffers via the stream's delegate

### AVAudioEngine (Microphone — What You Say)

The user's microphone is captured via AVAudioEngine:

1. Install a tap on the input node
2. Receive PCM audio buffers

### Audio Mixing

The two streams (app audio + mic audio) are mixed into a single PCM stream for transcription. The service maintains awareness of which stream each audio segment came from — this is how the user ("me") is always auto-identified as a speaker.

### Audio Format

- Sample rate: 16kHz (AssemblyAI's preferred rate)
- Channels: mono
- Format: PCM 16-bit signed integer
- Both streams are resampled to this format before mixing

## Transcription

### AssemblyAI Real-Time Streaming

When a call starts:

1. Open a WebSocket connection to AssemblyAI's real-time endpoint
2. Stream mixed PCM audio chunks continuously
3. Receive partial transcripts (for potential live display)
4. Receive final transcripts with:
   - Transcribed text
   - Speaker labels (Speaker A, Speaker B, etc.)
   - Timestamps (start and end of each utterance)
5. Save each final utterance to SQLite immediately

When a call ends:

1. Close the WebSocket connection
2. Finalize the conversation record with end timestamp and duration

### Speaker Diarization

AssemblyAI assigns labels like "Speaker A", "Speaker B" to different voices. These labels are consistent within a single call but arbitrary across calls.

### API Configuration

- API key stored in macOS Keychain
- First-run setup: settings screen prompts for API key entry
- Key is retrieved from Keychain at service startup

## Speaker Identification

### Strategy: Mic/App Audio Separation + Calendar Attendees

Since we capture mic and app audio separately, we always know which utterances are the user's. For other speakers:

| Scenario | User | Others |
|---|---|---|
| 1:1 call + calendar match | Auto (mic audio) | Auto (only other attendee) |
| Group call + calendar match | Auto (mic audio) | Pick from attendee list after call |
| 1:1 ad-hoc call | Auto (mic audio) | Manual name entry |
| Group ad-hoc call | Auto (mic audio) | Manual name entry |

### Speaker Labeling Flow

After a call ends (for group calls or unmatched calls):

1. The app shows a notification or prompt in the conversation view
2. Unlabeled speakers appear as "Speaker B", "Speaker C", etc.
3. If calendar attendees are available, the user selects from a dropdown
4. Otherwise, the user types a name
5. Speaker records persist — if the same person appears in future calls and is labeled, their name carries forward in the speakers table

### "is_me" Flag

One speaker record is permanently flagged as `is_me = true`. All utterances from the mic audio stream are attributed to this speaker. This is set up during first-run configuration.

## Database

### Location

`~/Library/Application Support/Mossad/mossad.db`

### Schema

#### `conversations`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Primary key |
| title | TEXT | From calendar event or "Ad-hoc Zoom Call" |
| platform | TEXT | "zoom", "meet", or "teams" |
| started_at | DATETIME | When recording began |
| ended_at | DATETIME | When recording ended (nullable while in progress) |
| duration_seconds | INTEGER | Computed on finalization |
| calendar_event_id | TEXT | EventKit event identifier (nullable) |
| meeting_url | TEXT | The meeting link (nullable) |

#### `utterances`

| Column | Type | Description |
|---|---|---|
| id | INTEGER | Primary key, autoincrement |
| conversation_id | TEXT | FK → conversations.id |
| speaker_id | TEXT | FK → speakers.id |
| text | TEXT | Transcribed text |
| started_at | REAL | Seconds offset from conversation start |
| ended_at | REAL | Seconds offset from conversation start |

#### `speakers`

| Column | Type | Description |
|---|---|---|
| id | TEXT (UUID) | Primary key |
| name | TEXT | Display name or "Speaker B" |
| email | TEXT | From calendar attendee (nullable) |
| is_me | BOOLEAN | True for the user's own speaker record |

#### `conversation_speakers`

| Column | Type | Description |
|---|---|---|
| conversation_id | TEXT | FK → conversations.id |
| speaker_id | TEXT | FK → speakers.id |
| diarization_label | TEXT | AssemblyAI's label for this call ("A", "B", "C") |

Composite primary key on (conversation_id, speaker_id).

#### Full-Text Search

An FTS5 virtual table indexes utterance text:

```sql
CREATE VIRTUAL TABLE utterances_fts USING fts5(
    text,
    content='utterances',
    content_rowid='id'
);
```

Triggers keep the FTS index in sync with the utterances table on insert, update, and delete.

## UI

### Menu Bar Icon

- **Idle**: monochrome microphone or headphone icon
- **Recording**: red-tinted icon or red dot overlay, indicating active capture

### Menu Bar Popover

Clicking the menu bar icon opens a popover:

**Idle state:**
- Status: "No active call detected"
- "Open Conversations..." button
- "Settings..." button
- "Quit Mossad" button

**Recording state:**
- Meeting title (from calendar or "Ad-hoc [Platform] Call")
- Platform and elapsed time
- Speaker count
- "Pause Recording" button
- "Open Conversations..." button
- "Settings..." button

### Main Window — Conversation Browser

A separate window opened from the popover or via keyboard shortcut.

**Left sidebar (280px):**
- Search bar at top (FTS5 query)
- Chronological list of conversations
- Each entry shows: title, date/time, duration, platform, speaker count
- Selected conversation highlighted

**Right panel:**
- Header: meeting title, date, time range, platform, attendee names
- Transcript: sequential utterances with speaker name (color-coded), timestamp, and text
- Unlabeled speakers show as clickable "Speaker X" with option to assign a name

### Search

- Typing in the search bar queries the FTS5 index
- Results show matching utterances with:
  - Conversation title and date
  - Speaker name and timestamp
  - Matched text with search terms highlighted
- Clicking a result opens that conversation scrolled to the matching utterance

### Settings Window

- AssemblyAI API key entry (stored in Keychain)
- "Your name" configuration (for the is_me speaker record)
- Launch at login toggle
- Audio input device selection (defaults to system default)

## macOS Permissions

The app requires three system permissions, requested on first launch:

1. **Screen Recording** — required by ScreenCaptureKit to capture audio from other apps. The user grants this in System Settings > Privacy & Security > Screen Recording.
2. **Microphone** — required by AVAudioEngine for mic capture. Standard permission prompt.
3. **Calendar** — required by EventKit to read meeting metadata. Standard permission prompt.

The app should guide the user through granting these permissions on first launch with clear explanations of why each is needed.

## Conversation Lifecycle

1. Process monitor detects an active meeting app with audio
2. Calendar is queried for matching events (±10 min window, URL matching)
3. A new conversation record is created in SQLite
4. ScreenCaptureKit begins capturing app audio, AVAudioEngine captures mic
5. Audio is mixed and streamed to AssemblyAI via WebSocket
6. Final utterances are saved to SQLite as they arrive
7. Menu bar icon transitions to recording state
8. When the meeting app's audio session ends (or process exits):
   - WebSocket connection is closed
   - Conversation record is finalized (end timestamp, duration)
   - Menu bar returns to idle
   - If speaker labeling is needed, a prompt appears
9. The conversation is immediately browseable and searchable

**Leave and rejoin**: if the user leaves a call and comes back, the process monitor detects the audio session ending and starting again. Each session creates a separate conversation record. Calendar metadata links them (same event title/ID), but they are distinct entries.

## Technology Stack

- **Language**: Swift
- **UI Framework**: SwiftUI
- **Audio Capture**: ScreenCaptureKit (macOS 13+), AVAudioEngine
- **Calendar**: EventKit
- **Networking**: URLSessionWebSocketTask (for AssemblyAI WebSocket)
- **Database**: SQLite via swift-sqlite or GRDB.swift
- **Keychain**: Security framework
- **Process Monitoring**: NSWorkspace, NSRunningApplication
- **Minimum macOS Version**: 13.0 (Ventura) — required for ScreenCaptureKit audio capture
- **Build System**: Xcode / Swift Package Manager
