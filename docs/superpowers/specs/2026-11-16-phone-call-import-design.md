# Phone call import: design

Date: 2026-11-16. Status: approved by the owner on 2026-11-16.

## Intent

iOS can record a phone call and keeps the recording in Notes. The owner wants that call in Mossad as a meeting, with
the fewest taps iOS permits, and with nothing to type.

iOS gives no app a button on the call details or in the menu of a call recording. The shortest supported path is the
share sheet: the recording's menu, "Share Audio", "Mossad". This design builds that path and one screen behind it.

## Goals

- From a call recording in Notes: menu, "Share Audio", "Mossad", then one button. The meeting appears on the Mac and
  the iPhone like any other.
- The meeting says "Phone call", not "In person".
- When the owner names the other person on the import screen, Mossad names that voice with no question later.
- A Shortcuts action does the same import with no screen, for the owner's own automations.

## Non-goals

- No automatic import, and no read of Notes or of the Phone app.
- Apple's own transcript is not used. Mossad transcribes the audio as it does for every meeting.
- No notes made on the iPhone itself. The Mac makes the meeting, as for a room recording.
- No profile choice here. The profiles design (`2026-11-16-profiles-design.md`) adds one row to this screen.
- No import of audio on the Mac (a file dropped on the Mac app). It may come later.

## Anti-goals

- A recording that the screen said was added is never lost: it is in the phone's `Recordings` folder and in the
  outbox before the screen says so, and the outbox's rules send it again until the Mac has it.
- The import never changes or deletes the recording in Notes.
- The audio goes nowhere except the owner's own sync store (iCloud or the owner's server), as a room recording does.

## What exists today

- The room recorder: `PhoneApp/RoomRecorder.swift` and `PhoneStore` write parts, join them (`RoomAudio`), keep an
  entry in `Outbox`, and send the audio with `CloudSync.upload` as a record `rec-<id>` of type `Recording`
  (fields `start`, `end`, `title`, file `audio`). The Mac imports it with `CloudSync.importRecording` and
  `PhoneRecording.importAudio`: the audio becomes the `me` track, the `them` track is empty, and the record is
  `CallRecord(platform: .inPerson, bundleID: "iphone", status: .recorded)`. The phone deletes its copy only when
  the meeting comes back (`settleOutbox`).
- The phone app has no document types, no extension, and no App Group. It has the URL scheme `mossad`, handled in
  `MossadPhoneApp.swift` by `.onOpenURL`.
- `Platform` has `.inPerson` with `displayName` "In person"; the lists, the note's front matter, the Meetings filter,
  and Analytics read it.

## The design

### 1. Mossad in the share sheet

The phone app declares that it opens audio files: `CFBundleDocumentTypes` for `public.audio` in the `MossadPhone`
target (`project.yml`), not in place, so iOS hands the app its own copy. "Mossad" then shows in the share sheet of
any audio file, the call recording's "Share Audio" included.

The app opens with the file's URL. `.onOpenURL` tells a file URL from a `mossad://` link and shows the import
screen over whatever page was open.

This is the owner's choice of "a screen in the app". A share extension (a sheet over Notes) was considered and not
chosen: iOS gives an extension little memory, it needs an App Group to hand the file over, and the upload could not
start until the app next runs.

**To prove first, on a real iPhone, before the rest is built:** that "Mossad" shows in the share sheet of a call
recording's "Share Audio", and which file type and file name iOS hands over. No agent can do this check; the owner
does it with a build that has only the document type and a screen that shows the file's name, type, and dates. If
Mossad does not show for that file, stop and report: the fallback is a share extension, which is a different plan.

### 2. The import screen

`PhoneApp/CallImportScreen.swift`, with its rules in MossadCore (`CallImport`, pure, tested).

Rows, top to bottom:

- **Title.** The file's name without its extension. When that name says nothing ("Recording", "Audio", "New
  Recording", or only digits), the title is empty and the placeholder is "Phone call". The owner can type one.
- **When.** The call's start. From the audio file's own creation date in its metadata; else the file's creation
  date; the owner can change the day and the time. The row shows the length, read from the audio, and it is fixed.
- **Who was on the call.** Optional. One person at most: a pick from a search, or a new name as typed. With the
  owner's server as the sync, the search reads the saved people (`SyncedPeople`) and a pick carries the person's
  id. With iCloud, the phone has no saved people (`CloudSync.swift:195-200`): the search reads the named speakers
  of the meetings (`PhoneStore.personStats`), a pick carries only the name, and the Mac matches the whole name.
- **Add to Mossad.** The one button. Cancel is in the bar.

After the button: the file moves into `Recordings`, the outbox gets its entry, the upload starts, and the screen
closes to the Meetings list, where the row for a recording that waits already exists. If the upload cannot start
(no network), the entry stays due and goes later by the outbox's rules; the screen still closes.

There is no upload while the app does not run, as for a room recording today (`PhoneStore.swift:739-761`): the
upload has the app's time in front and the short time iOS gives after it. A recording that did not go waits in the
outbox until the owner opens Mossad. A background upload on both sync stores is not part of this design.

`settleOutbox` (`PhoneStore.swift:563-564`) counts only in-person meetings today. It must count a phone call too,
or the phone keeps its copy and sends the recording again.

The screen refuses, in plain words and with nothing saved:

- a file that `AVAudioFile` cannot read ("Mossad cannot read this audio file");
- audio shorter than the least length the Mac keeps (the Mac would drop it);
- a recording that the outbox or the meetings already have: the same start to the second and the same length to the
  second ("This recording is already in Mossad").

The app deletes its own copy in `Documents/Inbox` when the import is done or cancelled.

### 3. What travels

`PhoneRecording` gains optional fields, so an older payload still reads:

- `kind`: `room` (the default when absent) or `phoneCall`;
- `person`: the name as picked or typed; `personID`: the person's id when the owner picked a saved person.

`CloudSync.upload` sends them as fields of the `Recording` record, on both stores.

- **The owner's server** keeps a record's fields as one JSON text and returns them as they came
  (`server/src/api.ts:118-131`, `149-159`). No Worker change, no migration, and no deploy.
- **iCloud.** Each field is a key of the CloudKit record (`CloudKitStore.swift:27-33`), and a production container
  refuses a key its schema does not have. The owner adds `kind`, `person`, and `personID` to the `Recording` type
  in the CloudKit Console and deploys the schema to Production (one step, with the `NextTime` type that already
  waits there). Until then, and for any install where iCloud refuses the record, the phone sends the recording
  again without the three fields: it arrives and becomes a meeting that says "In person" with no person. A
  recording is never left waiting because of these fields.

The audio goes as iOS gave it when `AVAudioFile` reads it; the Mac converts on import as today. The builder may
convert on the phone to `PhoneRecording.settings` if a file is much larger than a room recording of that length.

### 4. On the Mac

- `Platform` gains `phoneCall`: `displayName` and `filterName` "Phone call", a phone symbol in the lists. The note's
  front matter says `platform: Phone call`. The filter and Analytics take the new platform through the paths they
  have.
- A build from before this change leaves a phone call out of its list and keeps every other meeting: `Platform`
  decodes strictly (`CallRecord.swift:381`), and the scan catches the error for each record
  (`ProcessingQueue.swift:29`, `RecordCache.swift:32-36`). An older Mac that gets the recording makes an "In person"
  meeting of it. The release notes say to update the Mac and the iPhone together. From this build on, `Platform`
  reads a value it does not know as a meeting with an unknown platform, so the next new platform hides nothing.
- **A phone call is processed as a room recording is**: one track with every voice, speakers apart by voice. The
  builder finds each rule that asks "is this in person?" (`InviteVoiceRules`, `MeetingAnalytics`, the Meetings
  filter's size, `NextTimeRules.ownerMissed`, the usage statistics' counts) and gives a phone call the same answer,
  except for its words and its symbol. `bundleID` stays `"iphone"`.
- **The person.** A phone call with a `person` is always a call whose invite is sure and has that one person, by
  every rule of `InviteVoiceRules`: when the owner's voice is found and exactly one other voice is left, that voice
  is the person (a provisional profile, firm later by the same rules); a provisional voice of that person names
  them on the next phone call with the same hint (`InviteVoiceRules.swift:319-324`); and a saved voice of anyone
  else needs 0.80 and a lead of 0.08 on that call and is not learned from. With a `personID`, the voice joins that
  saved person; with only a name, the naming of a voice decides as it does for a typed name
  (`PersonDirectory.existing`: the whole name joins a saved person, a guess joins nobody). How the hint is carried
  on `CallRecord` is the builder's choice; it must survive a restart between steps.
- **The calendar.** A room recording takes an overlapping calendar event with no call link as its meeting
  (`CalendarMatcher.swift:234-237`), and the event's title, attendees, and invitees replace the record's
  (`CallRecord.swift:324-329`). A phone call is narrower: it takes such an event only when the event invites
  exactly one person besides the owner, and, when the phone sent a person, only when that person is the invited
  one on a sure match. Else the phone call has no calendar event: a call during "Lunch" or a block of the owner's
  own never gets that title or those people. A title the owner typed on the phone is never replaced by the
  calendar's.
- The meeting's title, when the phone sent none and no event gave one, is the summary's, as for a room recording.

### 5. The Shortcuts action

An App Intent "Add recording to Mossad": one audio file, and optional title, start, and person name. It runs the
same rules as the screen with no screen, refuses the same files with the same words, and does not open the app. Its
result says "Added. Mossad sends it when you next open the app." when the upload did not finish in the time iOS
gave.

### 6. Words and the website

- `AGENTS.md`: the rows for `.../Sync/`, `.../Room/`, and `PhoneApp/` say what was added.
- `website/content/site.json`: one feature under the iPhone group, with its source files. The copy says what the
  owner gets, not how it works.

## Tests

Pure rules in `MossadCoreTests`: the title from a file name; the start from the dates given; the refusals; the
duplicate rule; `PhoneRecording` read from a payload without the new fields and written with them; the second
send without the fields after a refusal; `Platform` read from an unknown value; the person hint through
`InviteVoiceRules` (owner found and one voice left: named; two voices left: nobody; a provisional voice of the
person: named on the next call with the hint; another saved voice: only at 0.80 with the lead); the calendar rule
(an event with one other person who is the hint: taken; an event with two others, or with another person than the
hint: not taken; a typed title kept); `settleOutbox` with a phone call.

## Left to the builder

- The exact layout of the screen, with the phone app's existing parts and `Rhythm` tokens.
- Whether the import may run while the room recorder records.
- How the hint is stored on the record.
- Whether the phone converts the audio before the upload.
