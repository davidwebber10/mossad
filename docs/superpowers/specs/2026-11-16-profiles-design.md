# Profiles: design

Date: 2026-11-16. Status: approved by the owner on 2026-11-16.

Note, 2026-11-19: Profiles moved out of Settings > General to its own page, Settings > Profiles, right after
General. Read "Settings > General > Profiles" below as Settings > Profiles. "Manage profiles…" opens that page. With
one profile the page shows that profile and "Add profile…". The page also lists what each profile keeps apart and
what all profiles on the Mac share (`ProfileSettingsWords.apart` and `shared`).

## Intent

The owner takes work calls and personal calls (a consulting client, for example) on the same Mac and iPhone. The
two must never mix: different keys, different settings, different people and voices, a different coach, a different
sync, a different MCP connector. The owner still wants both kept, and wants to change from one to the other with
one click.

## What the owner decided

- A switcher at the bottom left of the Mac window; on the iPhone, in Settings.
- "Add profile" walks through the whole setup again, with different keys and everything.
- Each profile has its own MCP.
- On the Mac, a call that starts is recorded by the profile that is active. Nothing asks.
- A meeting can move to another profile, in case it went to the wrong one.
- The profile that is not active still finishes its own meetings and syncs in the background, with no recording.
  (A personal phone call sent from the iPhone gets its notes while the Mac stays in the work profile.)
- The iPhone's import screen for a phone call picks the profile (see `2026-11-16-phone-call-import-design.md`).

## Goals

- With one profile, Mossad is exactly as today: the same folder, keys, settings, sync zone, and MCP command. Nothing
  migrates, and no new control shows except "Add profile" in Settings.
- Nothing of one profile is readable from another: not in a list, a search, a chat, the coach, the MCP, the sync,
  the backup, or the weekly mail.
- A switch takes about two seconds and never loses audio.

## Non-goals

- No automatic choice of a profile for a call (by calendar, app, or person).
- No shared people, voices, or coach memory between profiles, and no copy of settings or keys from one to another.
- No move of a meeting from the iPhone, and no move of a notes-only meeting (it belongs to that profile's Google
  account).
- Rehearsal, previews (`--ui-preview`), and a run with `MOSSAD_ROOT` have no profiles and behave as today.

## Anti-goals

- A personal meeting that shows in a work place (the work MCP, the work server, the work mail, the work coach).
- A connector that follows the switch: an AI app set up for one profile must never read the other.
- Two processes that write one profile's files.
- Lost audio in a switch or a move.

## The model: one profile for each process

A process of Mossad is one profile from its first line to its last. Three things make a profile, and
`AppIdentity` already gives each of them to Rehearsal and to previews:

| | The first profile (id `default`) | Any other profile (id: 8 random hex characters) |
| --- | --- | --- |
| Data folder | `~/Mossad` | `~/Mossad <Name>` as named at creation, unique, kept in the registry; a rename does not move it |
| Keychain service | `com.dwebber.mossad` | `com.dwebber.mossad.profile.<id>` |
| Settings | the app's standard domain | the suite `com.dwebber.mossad.profile.<id>`, put in place of `UserDefaults.standard` before anything reads a setting, as `isolateDefaults()` does for a preview, but never emptied |

So the 199 reads of settings, the 5 reads of the Keychain service, and `Paths.live` do not change.

**The registry.** `~/Library/Application Support/Mossad/profiles.json`: `version`, the profiles (`id`, `name`,
`color`, `root`), and `active`. A newer file is read and never saved. With no file there is one profile, `default`,
named "Mossad". The registry is written only by the foreground app, in one atomic write.

**Which profile a process is.** `--profile <id>` when given. With none: the window app (a click, the login item, a
restart after an update) is the registry's `active`; every command (`--mcp`, `--people-migration`, `--persona-fill`,
`--persona-eval`, `--import-keys`) is `default`, always. An unknown id prints one line on stderr and does not start.

**Mac-wide, not of a profile:** the permissions, the login item (it starts the profile that was last active), the
updates (Sparkle and its settings), the downloaded models in `~/Library/Application Support/Mossad/Models`, the
registry, and the usage statistics (one install id, one switch, at most one report a day for the Mac, sent by the
foreground app with the facts of the profile active then). The builder keeps these in the standard domain, read
past the swap, and proves in a test that Sparkle and the login item do not read a profile's suite.

Sparkle takes `[NSUserDefaults standardUserDefaults]` when it makes its host (`SUHost.m:66`), and the app makes the
updater after the swap today (`AppController.swift:225`), so as the code stands Sparkle would read a profile's
suite. The plan must give Sparkle the real standard domain in every profile (its host made before the swap, or the
real domain kept and handed to it); the owner's update settings are never copied.

**Not recording is Mac-wide too (the owner's decision, 2026-11-16).** The Off switch
(`offUntil`, `AppController.swift:188`) and the do-not-record choices (`NoRecordBook`, a file in each data folder)
would be of a profile after the swap: "Off until 3:00" would be on again after a switch, and a meeting the owner
refused in one profile would be recorded by the other. So: one Off switch for the Mac, kept in the
standard domain; and the gate of the active profile reads the do-not-record file of every profile. That file holds
only the keys of events and series (links and ids), never a title or a person, and no page of another profile
shows it. A refusal the owner makes is saved in the active profile.

**Risk to prove first.** The swap of `UserDefaults.standard` has only served previews. Before the rest is built,
the builder proves with a signed build on a made-up registry that `@AppStorage`, `ToolSettings.read(.standard)`,
and the commands read and write the profile's suite and never the standard domain, across a restart.

## Part 1: profiles on the Mac

### Add a profile

Settings > General > Profiles lists the profiles (name, color, folder) with Add, Rename, and Delete. Add asks for a
name and a color, makes the registry entry and the empty folder, and restarts Mossad as the new profile. Its
settings are empty, so the setup window starts as for a new user: owner name, keys, providers, calendars, Google,
the server. Steps that are Mac-wide (the permissions, the login item) show as done. Nothing is copied from another
profile. A setup left unfinished resumes the next time that profile is active, as setup does today.

Delete is for a profile that is not `default` and not active. It asks for the profile's name, then removes the
registry entry, the profile's Keychain items and settings, its two iCloud Keychain items, and its iCloud zone, and
moves the folder to the Trash. It says that a server, if the profile had one, is the owner's to remove.

### The switcher

With two or more profiles: a control at the bottom of the sidebar, at the leading edge, with the active profile's
color and name. Its menu lists the profiles, then "Add profile…" and "Manage profiles…" (Settings > General). The
menu bar icon carries the active profile's color as a small mark, and the menu bar panel names the profile in its
first line, so the owner sees which profile will record before a call. With one profile, none of this shows.

A switch: Mossad refuses while a call records ("A call is recording. Switch when it ends."). Else it saves `active`,
tells its background runs to stop, starts a new instance as the other profile (as `restartAsWorkingCopy` does), and
quits. A step of the pipeline that was running is resumed by that profile's background run. The new instance waits
up to 10 seconds for the profile's folder lock before it reads "Another copy of Mossad is running".

Only the foreground app registers the hot keys, owns the notifications, checks for updates, and shows a window.

### The note's audio line

A note says `audio: ~/Mossad/Audio/<id>` today, and `MarkdownWriter.isNote` matches that exact line. The line
names the profile's real folder, and `isNote` takes any folder that ends in `/Audio/<id>`.

### MCP for each profile

`Mossad --mcp --profile <id>` serves that profile and no other; `Mossad --mcp` serves `default`. Settings > AI of a
profile other than `default` shows the command with `--profile <id>` and the server name `mossad-<name in lower
case, letters and digits>`; `serverInfo` says the same name. The other commands take `--profile` too, and
`--persona-fill` asks whether that profile's folder is locked, not whether any Mossad runs.

The server's MCP is one Worker for one owner. A profile that uses a server needs its own Worker (its own address,
secret, database, and bucket). The server setup sheet of a second profile says so, and the Mac refuses to pair a
profile with an address that another profile of the registry already uses.

### Sync and backup apart

- **iCloud:** `default` keeps the zone `Mossad`. Another profile uses the zone `Mossad-<id>` in the same container.
  Record names and types do not change, so the production schema does not change.
- **The iCloud Keychain items** (`SharedAIKey` account `ai`, `ServerPairing` account `server`): `default` keeps the
  accounts; another profile uses `ai.<id>` and `server.<id>`. A process writes or deletes only its own.
- **The recording backup:** a profile other than `default` writes under `profiles/<id>/` in a bucket, so two
  profiles on one bucket never meet. A server is already one profile's.

## Part 2: the background run

`Mossad --profile <id> --worker`: no window, no menu bar item, no Dock icon. The foreground app starts one for each
other profile when its launch is done and stops them when it quits or switches. A worker ends by itself when the
foreground app is gone, and holds its profile's folder lock while it runs.

A worker needs a third mode between "inert" and "full" (today `inert` is the only switch, `AppController.swift:636`).

| A worker does | A worker never does |
| --- | --- |
| Recovers interrupted work, runs the processing queue to "written" | Detects or records a call |
| Pulls and pushes its own sync store (the phone's recordings come in here), the digest, the server's config | Imports Gemini notes, writes the calendar snapshot, shows upcoming meetings |
| Reads the calendar only to match the invite of a meeting it finishes (`Pipeline.matchInvite`, `Pipeline.swift:779-781`, `:833`), with its profile's calendars and Google tokens | |
| The recording backup of its meetings | Registers hot keys, the login item, or the updater |
| What follows each meeting today (`track()`): the coach's review, commitments, the next-time check, personas | Owns the notification center or posts a notification |
| Takes in a meeting moved to it (Part 4) | Sends the weekly mail or usage statistics, runs retention |
| | Asks for a permission |

A worker matches the invite because the rules that name a voice from the invite need a sure invite
(`InviteVoiceRules.swift:350`), and a phone or room recording gets its title and people from it. The builder
proves first that a worker, as a process of the same signed app, has the Mac's Calendar permission; where it
cannot read, the answer is unknown, never "no invite", and the meeting is finished as a call with no sure invite.

What a worker leaves undone (the weekly mail, retention, Gemini notes) runs when that profile is next active, by
the rules of today. These limits are the designer's choice: "finish its meetings and sync" and nothing the owner
could be surprised by.

**No heavy work during a call, across processes.** While the foreground app records, each worker follows
`HeavyWorkPlan` as if that call were its own: the join of tracks and voice identification at background priority,
full-call encodes and a model on this Mac held until the call ends. How the foreground tells the workers is the
builder's choice; a worker that cannot tell must assume a call records.

**What the owner sees.** The switcher's menu shows, for each other profile, "2 meetings in work" or the kind of its
last failure, from a small status file the worker writes in its own folder. Nothing else reports a worker.

## Part 3: the iPhone

- **How the phone knows the profiles.** The Mac's foreground app writes a third iCloud Keychain item (account
  `profiles`, the same group): each profile's id, name, color, and whether it syncs by iCloud or a server. Where
  iCloud Keychain is off, the phone adds a profile from a profile code. Today a code exists only for a server
  (`ServerPairing.swift:9-12`, `App/PhonePairing.swift:65`). The new code is for any profile: its id, name, color,
  how it syncs, and for a server the address and the secret. Settings > General > Profiles on the Mac shows it
  ("Show code for iPhone"), and the phone's Profile row has "Add a profile" that scans it. An old server code
  still pairs `default`.
- **Apart on the phone.** `default` keeps `Documents/Mossad`, its settings keys, and its Keychain service. Another
  profile has `Documents/Mossad Profiles/<id>`, its own `syncWith` and server address, its own secret, its own
  recent searches, and its own outbox. View choices (the Analytics period, the People sort) may stay shared.
- **The phone is one process**, so `PhoneStore` takes its profile (folder, Keychain, settings, sync store) as a
  value, and the app builds a new store on a switch. Settings starts with a Profile row; with two or more profiles
  the Meetings title carries the profile's color.
- **The room recorder** records into the phone's active profile.
- **The import screen** (built first, by the phone call import design, with one outbox) gains a Profile row (the
  last one chosen; the first time, the active one). This part makes the outbox one for each profile. A recording
  for any profile is sent at once, whichever profile shows: each profile's outbox is sent on its own sync store.
- The phone never moves a meeting and never shows two profiles in one list.

## Part 4: moving a meeting

On the Mac, in a meeting's context menu and the Meeting menu: "Move to ▸ <profile>". For a meeting that is written
or failed, or one that is recorded and not yet sent to any provider; never the call that records now.

1. The foreground app copies the call folder into the target's folder as `Incoming/<id>` with a marker file, and
   checks each file's size and SHA-256 (as `ArchiveMove` does). `Incoming` is a new folder beside `Audio`, because
   `ProcessingQueue.scan()` and `Retention.sweep` read every folder in `Audio`, hidden ones too
   (`ProcessingQueue.swift:24-30`, `Retention.swift:15`). The foreground app touches nothing else of the target.
   A recording that is only in the backup (`CloudArchive.swift:100-104`) is downloaded and checked first; when
   that fails, the move is refused and nothing changes.
2. The record it writes there has no person ids (`speakerPeople`, `Invitee.personID`, `ActionItem.ownerID`,
   `Commitment.toID`; the names stay as labels), no backup place, and no share. The chats of that call go with it.
   `coach.json` and `findings.json` do not: they stand on the first profile's memory and goals.
3. The target's process (its worker, or the foreground app after a switch) takes the folder in: moves it to
   `Audio/<id>` (`<id>-moved` when the id is taken), names the voices again with its own voice library, keeps the
   transcript and the summary, and makes a new summary only where its naming changed a name, by the rule of today
   for a named voice. It compares the fingerprints the record keeps for each voice (`CallRecord.swift:233`), not
   the raw tracks: retention removes those after 30 days, so `identify` cannot run on an old meeting. A voice the
   target knows gets the target's name. A voice it does not know, which had a name in the first profile, keeps
   that name: the target makes the person and learns the voice from the record's fingerprint, as when the owner
   names a voice there, because the move is the owner's own act. A voice with no name stays "Speaker A". From there the meeting is a new meeting of that profile: its note, its sync, its backup, and,
   when that profile's coach is on, its review. It marks the folder taken.
4. Only then the first profile removes the meeting: what delete removes today (`Pipeline.remove`, `forget`: the
   note, the folder, the backup copy, the share links, the coach's memory of that call, the persona evidence, the
   sync copies), and also what delete leaves today: the tasks and commitments of that call, its chats, and the
   coach runner's entry. A point for next time that the call closed is open again (`NextTimeBook.reopen(doneIn:)`).
   It also removes what that call taught the first profile's voices: each sample learned from the call
   (`VoiceLibrary.forget(callID:speakerKey:from:voice:)`, `VoiceLibrary.swift:176`), and a person whom that call
   made and who then has no other meeting and no other sample, as the People page's delete does. A person with
   any other meeting stays. The usage log keeps the call's rows: that cost was the first profile's.

A stop at any step leaves the meeting whole in the first profile or in both, never in neither; the next launch
finishes the move from the marker. Moving back is the same move the other way.

A written meeting was already sent to the first profile's providers. The menu item's confirmation says so in one
sentence; a move cannot take that back.

**"Move after the call."** (The designer's addition.) While a call records, the menu bar panel offers "This call
is for ▸ <profile>". From that choice on, the live transcript, the live chat, and the live points stop for that
call (they send to the active profile's providers), and at the call's end the recording moves as "recorded": the
first profile sends nothing of it to any provider, and the other profile does all the work with its own keys.

## Order of the work

The phone call import (its own design) is built first. Then each part here ships by itself, in this order, and
the app is whole after each:

1. Profiles on the Mac (the registry, the identity, Add and Switch, MCP, sync and backup apart). The owner already
   has the separation, by a switch.
2. The background run.
3. The iPhone, with the import screen's Profile row.
4. Moving a meeting.

## Tests

Pure rules in `MossadCoreTests`: the registry (read, a newer version, an unknown id, a name's folder made unique);
`AppIdentity` with a profile (folder, service, suite; `default` equals today; commands without `--profile` are
`default`; Rehearsal, a preview, and `MOSSAD_ROOT` ignore the registry); the zone, the Keychain accounts, and the
backup prefix of a profile; the worker's mode (the table above as one table test); the move's plan (each step, a
stop after each step, the id that is taken, the fields a moved record loses); the MCP server name; `isNote` with
another folder.

## Words and the website

`AGENTS.md` gets a row for profiles and the changed rows. `website/content/site.json` gets the feature when Part 1
ships, and its details grow with each part. `README.md` shows the MCP command with `--profile`.

## Left to the builder

- How the foreground app and its workers talk (a pipe, a file, a signal).
- The layout of the switcher and of Settings > General > Profiles, with the sidebar's and Settings' existing parts.
- The exact colors offered for a profile.
- How the phone keeps a profile's settings (a suite or prefixed keys).
