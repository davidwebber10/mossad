# MCP coverage: everything the app shows, readable by other AI apps

Date: 2026-11-13. Branch: `feature/mcp-everything` (from 2.23.0).

The owner asked: "Does Mossad also provide people details? Basically everything in the app needs to be
available via MCP." This document lists every surface of the app, what a person can read there, and the tool
that gives it today in the local MCP (`Mossad --mcp`, the same tools as Chat) and in the server MCP (the owner's
Worker, for ChatGPT and claude.ai). For each gap it decides: add (and where), or leave out (and why).

Rules that every new tool keeps:

- A read only. The one write stays `add_next_time_point`.
- The same facts as the app: each tool calls the app's own pure function (no second rule).
- A person is matched only on a sure match (an id, an address, or a whole saved name); two who fit is nobody.
- Unknown is not false: a number the app cannot give says so; it is never 0.
- Never: API keys, tokens, share tokens, share PINs, voice fingerprints, raw audio, screen pictures (the local
  `get_screen` keeps its opt-in picture), the Log.
- The persona card and traits only where the app would show them: the coach on, the reads on, "Show in other AI
  apps" on, and never for a person with `doNotProfile`.

Legend: **L** = local MCP and Chat, **S** = server MCP. "missing" = no tool gives it today.

## Inventory

### Meetings

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Meetings list | title, date, length, people, tags, headline | find_meetings | find_meetings | have |
| Meetings filter facets | size (just me, 1:1, small, large), platform, kind, coach's rating, has action items / decisions / screens, length, weekday | missing (only query, people, dates, tag) | missing | L: add the filter choices to `find_meetings` through `MeetingFilter` and `MeetingFacets` (the app's rule), with the counts on request (`facets: true`). S: later, with the meeting digest (below). |
| Upcoming meetings (list and calendar) | the invites of the next 45 days, people, series, Join | missing | missing | L: add `upcoming_meetings`. The MCP process cannot read the calendar itself (no calendar permission of its own, and Google's tokens stay in the app), so the app writes `Calendar/upcoming.json` (`CalendarSnapshot`, an allowed-field list of the events it read) and the tool runs `UpcomingMeeting.from` over it. S: not offered (see the server section). |
| Summary tab | in one line, summary, topics, decisions with times, action items with owners, bookmarks, talk share, invited, your points discussed and carried, source (recorded or Gemini notes) | read_meeting (no bookmarks, no points, no source) | read_meeting (same gap) | L: extend `read_meeting` with the source, platform, kind, bookmarks, and "your points" (`NextTimeBook.discussed`, `carried`, `mentioned`). S: source and kind come with the view; points come from the next-time book the server has. |
| Transcript tab | timestamped transcript | read_meeting, search_transcripts | read_meeting, search_transcripts | have |
| Screens tab | shared screens, their text, presenter | list_screens, get_screen | missing | have (L). S: leave out: frames never sync. |
| Coach tab | the one line, the scorecard, the cards of the call | read_coach_review (no cards) | missing | L: the cards of a call through `coach_findings` with `call_id`. S: `read_coach_review` from the coach asset each meeting already syncs. |
| Analytics tab | talk time, turns, cut-ins, overlaps, answers, silence, delivery, outcomes, cost, what stood out against the history | missing | missing | L: add `meeting_analytics` (`MeetingAnalytics`, `MeetingBaselines`, `MeetingFindings`). S: later, with the meeting digest. |
| Chat tab of a meeting | the chats about the meeting | past_chats, read_chat | missing | have (L). S: add `past_chats` and `read_chat` from the chats the server already holds. |
| Bookmarks page | every bookmark, its note, its time, what was said | missing | missing | L: add `bookmarks` (`BookmarkIndex.groups`). S: later (bookmarks are in the record asset; the digest carries them). |
| Screens page | every kept screen of all meetings | list_screens per meeting | missing | L: have per meeting; `find_meetings` with `has: ["screens"]` finds the meetings. S: leave out (frames never sync). |
| Shares page | each link: meeting, created, expiry in words, PIN on or off, state, views | missing | missing | L: add `shares` from `ShareBook` and the server's last counts as the Shares page keeps them; never the token, the link, or the PIN. S: add `shares` from the server's own `shares` table (no token: the table holds only its hash; no PIN hash). |
| Gemini notes source | the "Gemini notes" mark, the document link | missing | missing | L: in `read_meeting` and `find_meetings` ("source: Gemini notes"). The document's link stays out (it opens the owner's Google account; not needed to answer). |

### Upcoming and prep

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| "Before this meeting" (prep page) | invited people with last met, how often, one fact; last time with decisions and action items; your open tasks for these people; your points; the series in numbers; the coach's note | missing | missing | L: add `prep` (`MeetingPrep` over the calendar snapshot, the records, the tasks, and the facts). S: not offered (the server has no calendar). |

### Recurring

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Series list | each series: title, schedule ("Tue 10:00"), next date, usual people, open items | missing | missing | L: add `recurring` (`SeriesCatalog`, `SeriesSchedule`, `SeriesReport.line`). |
| Series page band and Next time tab | the one line, schedule, your points (open, discussed with quote, carried, mentions in notes-only meetings) | missing | missing | L: add `read_series`. |
| History tab | each meeting: date, length, late, over, your share, people, headline | missing | missing | L: in `read_series` (`SeriesReport.rows`). |
| People tab | who comes, how often, trend (joined, dropped off), talk share | missing | missing | L: in `read_series` (`SeriesReport.attendees`). |
| Stats tab | meetings, since, median length, planned, ran over, started late, skipped | missing | missing | L: in `read_series`. |
| Open items tab | your tasks of the series, others' items of the last meeting, open decisions | missing | missing | L: in `read_series` (`SeriesReport.openItems`). |
| Suggestions | the coach's suggested points with their source | missing | missing | L: in `read_series` (`SeriesSuggestion.make`, filtered by `SuggestionTraining`, as the page). |
| Next time points (all) | open and done points for series and people | missing (only the write) | missing | L: add `next_time_points`. S: add `next_time_points` from the next-time book the server already holds. |

S for the series surfaces: the server cannot run `SeriesCatalog` (a Swift rule) and must not get a second copy of it. Design: the series digest payload (below), not built in this branch.

### People

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| People list | name, meetings, talk, last heard, coach's note, persona | people | missing | L: extend `people` with each person's id and job title, and `duplicates: true` for the possible duplicates (`PeopleDuplicates.find`, minus the pairs the owner marked as not duplicates). S: add `people` from `SyncedPeople` and the meetings' person ids. |
| Person band | names and written forms, addresses, job title and team, org place, meetings / met / only invited / from notes, last met, cadence, time together | missing | missing | L: add `read_person` (`PersonMeetings.Together`, `Person.forms`, `emails`, `directory`). Org place: leave out for now: the org chart is HR data that stays on the Mac and is not in a file the MCP can read without the app's import state; the directory's job and team are given. S: `read_person` with names, addresses, job, team, and the meetings with that person id. |
| Overview tab | "Next time I see", the coach's read (persona card, or the older brief), By the numbers, Together, Topics, Often with | people (part) | missing | L: `read_person` (`NextTimeBook.points(forPerson:)`, `PersonaSummary.card`, `PersonBrief`, `PersonStats`, `PersonRelation`). S: next-time points and the persona card (when allowed) in `read_person`. |
| Meetings tab | every meeting with them, spoke or only invited | missing | missing | L: `read_person` section `meetings` (`PersonMeetings.rows`). |
| Tasks tab | their action items, your items from the 1:1s, your promises to them | missing | missing | L: `read_person` section `tasks` (`PersonRelation.theirItems`, `myItems`, `myCommitments`). S: your promises to them from the commitments book. |
| Analytics tab | talk balance 1:1 and group, who starts, questions, cut-ins, reply times, ratings, calls a week | missing | missing | L: `read_person` section `analytics` (`PersonRelation`). |
| Knowledge tab | what you confirmed, how they think with each trait's confidence, never again | people (traits only) | missing | L: `read_person` section `knowledge`. |
| Voice tab | number of samples, where each came from, provisional | missing | missing | L: `read_person` section `voice`: counts, dates, origins only; never a fingerprint. S: leave out (voices never sync). |
| Duplicates sheet | pairs that may be one person, and why | missing | missing | L: `people` with `duplicates: true`. Only a list: Mossad never merges by itself. |

### Tasks

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Tasks page | your promises: overdue, by date, by person, done | commitments | missing | have (L). `tasks` is not needed: the Tasks page is the commitments book. S: add `commitments` from the book the server holds. |
| Action items | items from summaries | action_items | action_items | have |

### Coach

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Findings deck | the cards that wait: kind, text, why, the moment, the number with its usual value | missing | missing | L: add `coach_findings` (`FindingRules.deck`, with the trait cards of `PersonaFindings` when reads are allowed). |
| Goals | the goal, its target, progress over the 1:1s, call by call, learned, ended, not taken | coach_profile (focus line only) | missing | L: add `coach_goals` (`goalHistory`, `GoalProgress`). |
| Weekly review | the digest written and not sent | missing | missing | L: in `coach_goals`? No: in `coach_profile` with `section: "weekly"` (`WeeklyDigest.waiting`). |
| Knowledge | questions waiting, answered, what you confirmed, guidance, rules from your answers, never again, about people | coach_profile (facts, guidance, focus, patterns, people notes, ratings) | missing | L: extend `coach_profile` with open questions, why-rules, and never-again. S: add `coach_profile` from the coach memory the server holds. |
| Advice log | which skills got a line and when | missing | missing | L: in `coach_profile` (the last 15 entries). |
| Coach reviews | per meeting | coach_reviews, read_coach_review | missing | have (L). S: `read_coach_review`. |
| Coach settings | on or off, email | missing | missing | L: in `app_status`. |

### Analytics page

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Period report | calls, hours, scheduled share, talk share, value hours, topics, people, delivery, cost | stats | missing | have (L). |
| How you communicate | talk share, questions, cut-ins, pace: weekly line, usual band, the sentence that says a change | missing | missing | L: extend `stats` with the trend sentences (`CommunicationTrends`). |
| Outcomes, workday | items and decisions an hour, back to back, call-free days | missing | missing | L: extend `stats` with `AnalyticsReport` outcomes and workday numbers. |
| Costs | API cost by purpose and day | stats (total) | missing | L: `stats` gives the total and the parts by purpose. |

S for analytics: later, with the meeting digest (the numbers are Swift rules).

### Chat, live call, settings, log

| Surface | What a person reads there | L today | S today | Decision |
| --- | --- | --- | --- | --- |
| Chat history | earlier chats | past_chats, read_chat | missing | have (L). S: add both. |
| Live call | transcript so far | current_call | missing | have (L). |
| Live "Your points" | the open points for this call, ticked, raised | missing | missing | L: extend `current_call` with "Your points" (`LivePoints.series(ofLive:)`, `LivePoints.list`, `live-points.json`). S: leave out: the server never has the live call. |
| Settings | providers by name, what is on (coach, persona reads, live transcript, screen capture, sync, backup, Google parts, MCP reads), version | missing | missing | L: add `app_status`: names and switches only; never a key, a secret, a server address, a bucket, or an email address. S: leave out: the Mac's settings are not on the server. |
| Log | the app's log | missing | missing | Leave out: diagnostic, can name files and errors; not a fact about meetings. |
| Voice samples | fingerprints | missing | missing | Leave out: biometric; only counts and origins in `read_person`. |
| Raw audio, screen pictures | | | | Leave out (pictures: local `get_screen` with `include_image` only, as today). |
| Keys, tokens, PINs | | | | Leave out: secret. |

## Count

- 49 surfaces in the tables above.
- Before this branch, local: 10 fully covered, 9 in part, 26 missing, 4 left out on purpose (the Log, voice
  fingerprints, raw audio and screen pictures, keys and secrets).
- Before this branch, server: 3 fully covered (the list, the transcript, action items) and 1 in part (the Summary).
- After this branch, local: every surface but the 4 left out and the org chart's place on a person's page (HR data
  that the MCP process cannot read without the app's import state; the directory's job and team are given).
- After this branch, server: people, a person (without the Mac's numbers), points, tasks, the coach's memory and
  reviews, chats, and shares. The rest is the digest design below.

## Local MCP and Chat: the tools

New (12): `read_person`, `upcoming_meetings`, `prep`, `recurring`, `read_series`, `next_time_points`, `bookmarks`,
`meeting_analytics`, `coach_findings`, `coach_goals`, `shares`, `app_status`.

Extended (6): `people` (ids, job title, duplicates), `find_meetings` (filter choices and facets), `read_meeting`
(source, kind, bookmarks, your points), `stats` (trends, outcomes, workday, cost parts), `coach_profile` (open
questions, rules from answers, never again, advice log, weekly review), `current_call` (your points).

Each list takes `limit` (and caps it). Each result names the ids that other tools take: `call_id`, `person_id`,
`series_id`, `upcoming_id`, `point_id`.

The upcoming list needs the calendar. The MCP process has no calendar permission of its own and never holds
Google's tokens, so the app writes `~/Mossad/Calendar/upcoming.json` after each read of the calendar:
`CalendarSnapshot`, a version and an allowed-field list of each event (title, times, invited people with their
answers, the call link, series id, iCalendar UID, source, all-day, repeats), never the notes, the organizer's
details beyond the invite list, the attachments, or the calendar account. The tools say how old it is.

The iPhone's Chat gets the tools that work from what the phone has (people, series from the records,
next-time points, coach); the calendar, shares, screens, and app status are Mac only.

## Server MCP

### What the server has (checked in `CloudSync.push`, `pushShared`, `ServerStore`)

Before the review of this branch, the table held only when the Mac synced through the server. With iCloud as the
sync, the server was a copy of the meetings only (`push`). Now the copy also gets `pushShared(mirror: true)`: the
people, the reads, the points, the tasks, the coach's memory, the review notes, and the chats, by the same
allowed-field lists, off the main thread, never during a call, without touching the main sync's notes of deleted
chats. The coach's memory leaves the Mac without what it learned about a person who keeps no read
(`CoachProfile.withoutCoachData`), an overwrite at each sync.

| Record (R2 `records/<name>/<asset>`) | From | Holds |
| --- | --- | --- |
| `<call id>/view` (also in D1 `meetings`, `lines`) | Mac | `MeetingView`: title, times, people, person ids, summary, topics, decisions, action items, lines |
| `<call id>/record` | Mac | the slim `CallRecord` (no fingerprints, words, tracks, screens) |
| `<call id>/coach` | Mac | the `CoachReview` |
| `people/data` | Mac | `SyncedPeople` (allowed fields; no samples, org data, note, photo) |
| `personas/data` | Mac | `SyncedPersonas` (shown traits and card only; no evidence; never a `doNotProfile` person) |
| `next-time/data` | both | `NextTimeBook` |
| `commitments/data` | both | `CommitmentBook` |
| `coach-profile/data` | both | `CoachProfile` |
| `chat-<uuid>/data` | both | one `Chat` |
| `notes-<call id>/data` | both | the owner's ratings and conversation on a review |
| D1 `shares` | Mac | each share by the hash of its token; title, expiry, views (no token, PIN only as a hash) |

### Tools added in this branch (no new payload, no D1 migration)

- `people`, `read_person`: from `people/data`; the meetings with a person by their id in each view (`persons`,
  `speakerId`, `ownerId`), by the server's existing find rule. The persona card from `personas/data` only when
  the Mac said so (`config.mcpPersonas = "1"`, which the Mac sends with the owner's name from
  `MCPServer.showsPersonas`) and never for a person whose `doNotProfile` is set (checked again on the server).
  Absent means off: an older Mac never turns it on.
- `next_time_points`: from `next-time/data`.
- `commitments`: from `commitments/data`.
- `coach_profile`: from `coach-profile/data`.
- `read_coach_review`: from `<call id>/coach`.
- `past_chats`, `read_chat`: from the `Chat` records, newest 60 by their change.
- `shares`: from D1 `shares`.
- `search` and `fetch` cover people (`person:<id>`), tasks (`task:<uuid>`), and meetings (a bare call id, or
  `meeting:<id>`), so older ChatGPT links keep working.

The config key is additive in the `config` table (no migration). No D1 migration is needed for these tools.

### What the server does not offer, and why

- The live call: it is only on the Mac while it records.
- Upcoming meetings and the prep page: the calendar is read on the Mac. A small upcoming list could sync, but the
  prep page is `MeetingPrep` (a Swift rule over every record, the tasks, and the history of talk), and invites
  name people outside the owner's company; the owner should choose that first. Proposed below as part of the
  digest, off by default.
- Screens and voices: never leave the Mac.
- App status: the Mac's settings are not on the server.

### The digest (built in `feature/mcp-digest`, after 2.25.0)

The owner said yes to the recurring meetings, a meeting's numbers, the Analytics page, the coach's cards and goal,
and the bookmarks on the server, and no to upcoming meetings: the calendar never goes to the server, so
`upcoming_meetings` and `prep` stay on the Mac, and the live call too. Series, meeting numbers, period analytics,
trends, findings, goals, and bookmarks are Swift rules; the Mac computes them (`ServerDigest`) and the Worker only
finds, pages, and writes them out (`server/src/digest.ts`).

- Parts, each its own shared record (`kind: .digest`, type `Digest`), sent only when its content changed, each with
  `version: 1` and `made` (when its content last changed), from allowed-field lists (`ServerDigest.allowedKeys`,
  with a test that fails on any other key):
  - `digest-series`: each series that still meets, made from the meetings alone (`SeriesCatalog` with no
    calendar): `id`, `keys` (as a point saves them), `title`, `schedule`, `usualPeople`, `line`, the newest 12
    `rows`, `attendees` (20 at most), `stats`, `openItems` (20 at most). No next date and no invite; no suggestions.
  - `digest-meetings-YYYY-MM`: each meeting of that month (by its call id) with the Analytics tab's numbers
    (`MeetingAnalytics`, the sentences of `MeetingFindings`). A month is made again only when its meetings, their
    reviews, or the meetings before them changed (`DigestCache`, `~/Mossad/Sync/digest-cache.json`, never synced).
  - `digest-bookmarks`: every bookmark (2,000 at most) with its note and the line said then.
  - `digest-analytics`: the Analytics page for 7, 30, 90, and 365 days (`AnalyticsReport`, `CommunicationTrends`).
  - `digest-coach`: the deck's cards (`ChatTools.findingCards`: never a card about a person who keeps no read, trait
    cards only with the switch for other AI apps on) and the goals (`GoalProgress`).
- Sizes, measured by `ServerDigestTests.testTheSizesStayBounded` (1,500 meetings over two years, 60 series, a
  bookmark on each tenth meeting): series 233 KB (an extreme case: 19 people per series), each month at most
  66 KB (25 months, 1.5 MB in all, sent once and then only a changed month), bookmarks 23 KB, analytics 6 KB,
  coach a few KB. Each part is under `ServerDigest.maxPartBytes` (400 KB).
- When: with the server's copy (server sync or the iCloud mirror), after meetings are written, never during a call
  (a call that starts stops the upload at its next batch), off the main thread, made again only when the meetings,
  the coach, or the tasks changed, or an hour passed. Not to iCloud.
- Deletes: an ended series leaves `digest-series`, a removed bookmark leaves `digest-bookmarks`, an expired card
  leaves `digest-coach` (each an overwrite), and a month with no meeting left is deleted (`pushShared(digest:)`
  deletes each `digest:` key it holds that was not made again; with no digest made, nothing is deleted).
- Server: R2 reads, no D1 migration. The 2.25.0 Worker stores the new records and has no tool that reads them; the
  new Worker with the 2.25.0 app says "This server has no recurring meetings from your Mac yet". New tools:
  `recurring`, `read_series`, `bookmarks`, `meeting_analytics`, `analytics`, `coach_findings`, `coach_goals`;
  `search` and `fetch` add `series:<id>` and `bookmark:<call id>#<second>`. Each answer says when the Mac made it,
  and a series says that its next date is only known on the Mac.

## Chat actions (added later in this branch, the app's own chat only)

The owner then asked for a chat that can act ("add a note to my and Jeff's next meeting to discuss X"). Those
tools are in the app's Chat page, a meeting's Chat tab, the live Chat tab, and the quick panel, never in either
MCP: the local MCP keeps its one write (`add_next_time_point`) and the server MCP stays read only. See the Chat row
of `AGENTS.md` (`ChatAction`, `ChatActionRules`, `ChatActionTools`, `AppController+ChatActions`).
