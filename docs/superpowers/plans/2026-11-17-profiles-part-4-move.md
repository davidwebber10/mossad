# Profiles Part 4 (moving a meeting) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A meeting that went to the wrong profile moves to the right one, whole, and leaves nothing of itself in the first one; and during a call the owner can say that the call is for another profile.

**Architecture:** A move has two halves, and each profile's own process does its own half. The first profile copies the call folder into `<target>/Incoming/<id>` and checks every file; the target's process (its worker or its window app) claims the folder with one rename, names the voices again from the record's fingerprints, and moves the folder into its `Audio`; only when the marker says `taken` does the first profile remove its meeting, in ordered steps that each can run twice. The state of the first half is one small file in the first profile's own `Moves` folder; the state of the second half is the marker in `Incoming/<id>`. All rules are pure code in MossadCore (`Profiles/Move*.swift`), in the style of `ProfileRemoval` and `ArchiveMove`.

**Tech Stack:** Swift 6, Foundation (`FileManager`, `FileHandle`, `rename`), CryptoKit through the existing `FileHash`, XCTest. No new package.

**Spec:** `docs/superpowers/specs/2026-11-16-profiles-design.md`. Read it whole before any task. This plan covers only "Part 4: moving a meeting" (the four steps, the rules after them, and "Move after the call"). Where this plan and the spec disagree, the spec wins, except for the points in "What the code contradicts".

**Branch:** `feature/profiles-move`, made from the branch that holds Part 2 whole (its Tasks 9 to 12).

**Code read for this plan:** `feature/profiles-worker` at b7c3769 (Part 1 whole, Part 2 through its Task 8). Every `file:line` below is of that commit. Find each place again by its text before you edit.

## Global Constraints

- Test first. Write the failing test, run it, then write the code.
- Pure logic goes in `Packages/MossadCore/`. The app target holds views and wiring only.
- `cd Packages/MossadCore && swift test` (the whole suite) must pass before every commit.
- Build checks for app changes. Mac: `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Debug -derivedDataPath build/dev build -quiet`. iPhone (it compiles MossadCore too): `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme MossadPhone -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone CODE_SIGNING_ALLOWED=NO build -quiet`. Expected for both: exit status 0 and no line with `error:`.
- No build, test, or run while a call records. Before each `swift test`, `xcodebuild`, or run of the app, run the call gate script that your brief names. If it says a call records, wait.
- Never block the main thread. The copy, the hashes, the download, the take-in, and the removal run off the main actor. A long copy reports its progress, and the row shows it.
- Unknown is not false. A marker that cannot be read is not "taken" and not "refused": the first profile waits and keeps its meeting.
- Resumable steps. Each step of a move saves its state before the next one starts, and each step can run twice.
- DO NOT LOSE AUDIO. The first profile removes its meeting only after the marker says `taken`, and the target says `taken` only after the whole folder is in its `Audio`. No other path deletes audio.
- No AI attribution, no em dashes, and no real names of people in commits, code, or tests. Use made-up names such as "Sam Carter". Profile names such as "Work" and "Personal" are fine.
- Secrets live only in the Keychain. Never log them. The marker and the ledger hold ids, speaker keys, sizes, hashes, and file names, never a title, a name, or an address.
- `Mossad.xcodeproj` is generated from `project.yml`. Never edit or commit it.
- Never restart or signal a process that you did not start. No `killall`, no `pkill`.
- The website follows the app: `website/content/site.json` in the same branch, benefits and not mechanism.
- `AGENTS.md` rows are updated in the same branch.
- With ONE profile nothing changes: no menu item, no `Incoming` folder, no `Moves` folder, no new file, no new key in any saved file, and every existing test passes unchanged. Add new test files or new test methods; do not edit an existing test.
- Never deploy `server/` from an agent session. This plan changes nothing in `server/`.
- New Mac view text sizes and gaps come from `SharedUI/Rhythm.swift` tokens.
- Exact values: the folders `Incoming` and `Moves` beside `Audio`; the marker `move.json`, renamed `claimed.json` by the target; the part name `<id>.part`; the taken name `<id>-moved`; the look at `Incoming` and `Moves` every 15 s, in a worker and in the app; "It arrives when … is next open." after 60 s; "Moved to …" for 8 s; a refusal shows for 30 s; and every sentence of `MoveWords` in Task 3 and of `MoveAfterCall` in Task 12.
- Commit messages are one sentence in the repo's style.

## Review Focus

1. **A meeting in neither profile.** A stop, a crash, a full disk, or a deleted target at any moment of a move. Expected: the meeting is whole in the first profile or in both. Tests: `testOnlyATakenMarkerLetsTheSourceRemove` (Task 1), `testAHalfCopyIsNeverPublished` (Task 4), `testTheMeetingIsNeverInNeitherProfileAtAnyStop` (Task 9), and proof runs 2 and 3.
2. **A meeting in both profiles for good, with both syncing it.** The first profile never learns "taken"; a cancel races a take-in; a removal stops half way and is never taken up again. Expected: one rename decides between a claim and a cancel; a removal that started goes on without the target. Tests: `testOneRenameDecidesBetweenAClaimAndACancel`, `testARemovalGoesOnWithoutTheTarget` (Task 1), `testAStopAfterAnyStepOnEitherSideEndsWithTheMeetingInExactlyOneProfile`, `testACancelNeverLeavesTheMeetingInBoth` (Task 9).
3. **A person or a voice of the personal call left in the work profile.** Expected: every voice sample of that call goes; a person whom only that call made goes, with the coach's notes on them; the record that leaves holds no id of the first profile. Tests: `testTheMovedRecordHasNoIDOfTheFirstProfile` (Task 2), `testEveryVoiceSampleOfTheCallIsForgotten`, `testAPersonOnlyThatCallMadeIsDeletedAndOneWithAnotherMeetingStays` (Task 8).
4. **The first profile's providers get a call that the owner marked for the other profile.** The pipeline starts at the call's end; the live transcript starts again after a pause or a lost connection; the live chat answers; a launch after a crash processes the call. Expected: nothing is sent after the choice. Tests: `testAMarkedCallIsNeverProcessedHere` (Task 4), `testNothingIsSentAfterTheChoice`, `testACrashKeepsTheChoice`, `testEachLiveSendAsksTheGate` (Task 12).
5. **The first profile's coach, tasks, or points still cite the moved meeting**, or get it back from the iPhone at the next sync. Expected: no book of the first profile holds a word of the meeting, and a merge does not bring one back. Tests: `testAForgottenCallDoesNotComeBackInAMerge` (Task 7), `testNoBookOfTheFirstProfileHasAWordOfTheCallAfterTheRemoval` (Task 8).

## Decisions the owner already made

Do not reopen these.

- "Move to ▸ <profile>" on the Mac, in a meeting's context menu and the Meeting menu, only with two or more profiles. For a meeting that is written or failed, or one that is recorded and not yet sent to any provider; never the call that records now; never a notes-only meeting (it belongs to that profile's Google account). The iPhone never moves a meeting.
- Step 1: the foreground app copies the call folder into the target's folder as `Incoming/<id>` with a marker file, and checks each file's size and SHA-256. `Incoming` is a new folder beside `Audio`. The foreground app touches nothing else of the target. A recording that is only in the backup is downloaded and checked first; when that fails, the move is refused and nothing changes.
- Step 2: the record written there has no person ids (`speakerPeople`, `Invitee.personID`, `ActionItem.ownerID`, `Commitment.toID`; the names stay as labels), no backup place, and no share. The chats of that call go with it. `coach.json` and `findings.json` do not.
- Step 3: the target's process (its worker, or its window app after a switch) takes the folder in: moves it to `Audio/<id>` (`<id>-moved` when the id is taken), names the voices again by comparing the fingerprints that the record keeps with its own voice library (never the raw tracks), keeps the transcript and the summary, and makes a new summary only where its naming changed a name. A voice the target knows gets the target's name. A voice it does not know, which had a name in the first profile, keeps that name: the target makes the person and learns the voice from the record's fingerprint, as when the owner names a voice there. A voice with no name stays "Speaker A". From there it is a new meeting of that profile. It marks the folder taken.
- Step 4: only then the first profile removes the meeting: what delete removes today, and also the tasks and commitments of that call, its chats, the coach runner's entry; a point for next time that the call closed is open again; each voice sample learned from the call; and a person whom that call made and who then has no other meeting and no other sample, as the People page's delete does. The usage log keeps the call's rows.
- A stop at any step leaves the meeting whole in the first profile or in both, never in neither; the next launch finishes the move from the marker. Moving back is the same move the other way.
- A written meeting was already sent to the first profile's providers: the confirmation says so in one sentence.
- "Move after the call": while a call records, the menu bar panel offers "This call is for ▸ <profile>". From that choice on, the live transcript, the live chat, and the live points stop for that call, and at the call's end the recording moves as "recorded": the first profile sends nothing of it to any provider after the choice. The choice can be taken back during the call; the live transcript does not start again for that call, and the call is processed here.
- The first profile never reads or writes anything of the target except `Incoming/<id>` (it writes it) and the marker's state (it reads it). The target never reads the first profile's folder.
- The first profile adds the moved meeting to `RemovedNotes` as a delete does.
- A profile marked `removing`, an inert copy, a second copy, a preview, Rehearsal, a `MOSSAD_ROOT` run, and a made-up registry move nothing. A made-up registry may run the move only for a proof, through a DEBUG hook, between made-up folders.

## Choices made where the spec left one

- **Two files, each with one writer.** The first profile's own state is `<its folder>/Moves/<id>.json` (`MoveOut`). The marker in `Incoming/<id>` is written by the first profile as `move.json`; the target takes it over by renaming it to `claimed.json` and then writes its own state into it. The spec says "a marker file"; this is that one file, under two names, so that no file ever has two writers.
- **One rename decides a race.** The target claims with `rename(move.json, claimed.json)`. The owner's Cancel takes the marker back with `rename(move.json, cancelled.json)`. Only one can succeed. After a claim a cancel is refused: "“Work” has the meeting already."
- **A half copy has another name.** The copy goes to `Incoming/<id>.part`; `move.json` is written into it last; then one rename makes it `Incoming/<id>`. A target ignores every `.part` and every folder with no `move.json`.
- **The record carries the mark.** `CallRecord.moveTo` (the target's profile id) is set when a move starts, by the menu or by "This call is for". The pipeline and the queue leave a marked call alone. It is the only new key in `call.json`, and it is written only for a move.
- **An id that left a profile is never used there again.** A profile's `Moves` folder keeps each finished move as a small file (ids and dates). The target counts those ids as taken. So a meeting that comes back is `<id>-moved`, and the commitment book's `checked` list, the sync state, and the usage rows of the first stay of that id never meet the second one. The rule "`<id>-moved` when the id is taken" is applied to the id that arrives, so `<id>-moved` can become `<id>-moved-moved`. A refusal needs both names taken.
- **`Duty.takeInMoved` is both halves that run with no window:** taking in, and going on with a removal. A new `Duty` case would change Part 2's table test. Starting a move is the foreground app's alone (`MoveRules.mayMove`).
- **The first profile's worker finishes a removal.** After a switch the first profile is in the background; its worker reads the marker and removes the meeting, so the meeting is not in both profiles until the next switch. A worker marks a share link as stopping and leaves the tell to the server for the window app, as Part 2 chose.
- **How fast.** A worker looks at `Incoming` and at its own `Moves` every 15 s: two folder listings, and both folders are absent until the first move. The foreground app does the same look every 15 s, off the main actor, only when the registry has two or more profiles, and also at launch, on its housekeeping, and when the switcher's line of a profile changes. A look that finds nothing reads no record and writes nothing.
- **A worker goes on with a move, and never starts one.** A switch can end the window app in the middle of a copy. The first profile's worker then makes the copy again and finishes the move, as "the next launch finishes the move" asks. Only the foreground app starts a move (and the DEBUG proof).
- **What "sent to a provider" is, from what the code keeps.** `MoveRules.sent`: a written or failed meeting was sent. A recorded one is in work when it has a transcription job, a finished track, a failed try, or a usage row for a transcription. It had only the live transcript when `live.json` is in its folder or the usage log has a `live` row for it. Else nothing is known to be sent, and the sentence says "As far as Mossad knows". A recorded meeting whose live transcript ran can still move; its sentence says what went.
- **A meeting in work cannot move:** in flight in the pipeline, at `transcribed`, `identified`, or `summarized`, recorded with a failed try, in a merge, or of a platform this build does not know. One sentence: "Mossad is working on this meeting. Move it when its notes are ready."
- **While a move waits the meeting is still the first profile's:** it shows, plays, and syncs. Its own commands that change it are off (the pipeline refuses a marked call), so no edit is lost.
- **Voices: the record's own invite, never sure.** The target compares each fingerprint with `VoiceLibrary.ranked` and decides with `InviteVoiceRules.decide`, the function `identify` uses, with the same `matchThreshold` (0.65), `learnThreshold` (0.8), `uninvitedScore` (0.80), and `uninvitedMargin` (0.08). The roster is the record's invite with `sure: false`: the invite came from the first profile's calendar, so nothing is inferred from it.
- **The owner.** The speaker keys that were the owner in the first profile are in the marker (`ownerKeys`), found by `OwnerIdentity.speakerKeys(in:)` before the ids are taken off. In the target those keys are the owner, under the target's "Your name": both profiles have one owner. The target's own owner voice can also name a key. The target never enrols its owner voice from a moved meeting: the mark is another library's word, and a voice becomes the owner's only on a call this profile heard itself, as a phone call never enrols it (`Pipeline.swift:794`, `SpeakerIdentifier.swift:81`).
- **A name from the first profile that was only "Named from the invite"** (the key is in `fromInvite`) stays a label and is learned as `inviteInference` with 20 s of clear speech or more, so it is provisional in the target too. Every other kept name is learned as `ownerNamed`.
- **Two voices with one kept name:** both keep the name; only the one with more clear speech teaches the library. A kept name that the target's own library gave to another voice of the same meeting teaches nothing.
- **A name that is an address** joins the saved person with that address, else the voice has no name. No person is ever named by an address.
- **No echo is dropped and no line changes** at a take-in. The first profile's pipeline did that; the transcript stays.
- **The Gemini reference of a recording does not move** (`CallRecord.gemini`): it is a link into the first profile's Google account.
- **Chats arrive with new ids** and without their receipts (`ChatMessage.actions`): a receipt offers Undo on a point or a task of the first profile. A `mossad://call/<id>` link in an answer follows the id the meeting gets.
- **The books forget for good.** A commitment of the call becomes an empty deleted marker. The points and the coach's memory get one new optional list, `movedCalls`, joined in every merge, so the phone's copy cannot bring a mention, a rated point, an answered question, or an answer to a card back. A "never again" that the owner gave on a card of the moved meeting goes with it.
- **The person who goes.** Nothing says which call made a person. The rule: a live person who is not the owner, who is a voice of that meeting, whose record was made at or after the meeting's start, whose origin is not the org chart, Google's directory or contacts, or the migration, who has no voice sample left after the call's samples went, and who is in no other meeting (not as a voice, and not as an invited person with their id). The coach's notes, facts, and guidance about that person go too.
- **What stays in the first profile, and why.** The usage rows (ids and costs: that cost was the first profile's). `Moves/<id>.json` (ids and dates). The mark in `Google/removed-notes.json` (the calendar title and the times, on this Mac only), as a delete leaves it. The lines of `People/people-log.jsonl` (on this Mac only), as the People page's delete leaves them. A share link in `Shares/shares.json` until the server is told to stop it.
- **A call for a profile that is gone at the call's end** is not processed here by itself: the owner did not want it sent from here. Its row says so and offers "Process here" and "Move to".
- **The DEBUG hooks for the proofs** run both halves in two workers of made-up profiles, so no window ever opens.

## What the code contradicts

- **"Recorded and not yet sent to any provider."** Nothing on a record says that an upload started: the job is saved only when the service gives its id (`Pipeline.swift:464-471`, `:686-693`). And the live transcript sends the audio of a call while it records (`AppController.swift:1413-1426`), and the pipeline removes `live.json` as its first act (`Pipeline.swift:621`). Plan: `MoveRules.sent` (see "Choices"), with the usage log as the second proof.
- **"What delete removes today (`Pipeline.remove`, `forget`)."** `remove(callID:keepNotes:)` refuses every status but written and failed (`Pipeline.swift:602-604`), so it cannot remove a recorded meeting. `forget` is `AppController.swift:1132-1150` and `deleteMeeting` is `:1761`. Plan: `Pipeline.removeMoved`.
- **"The tasks and commitments of that call."** They are one store, `CommitmentBook` (`Commitment.swift:53-58`); the Tasks page is the commitments page (`AppController.swift:1744`). A deleted commitment is a marker that keeps its words and its meeting's title (`Commitment.swift:24-25`, `:98-100`), and the book syncs both ways. Plan: an empty marker.
- **"A point … that the call closed is open again (`NextTimeBook.reopen(doneIn:)`)."** `reopen` (`NextTime.swift:246-250`) clears only `done`. `carried` (`:57`), `reopened` (`:59`), `mentions` with the quote (`:62`), and `checked` (`:124`) also name the call, and `merged` joins the mentions of both copies (`:290`, `:307-311`). Plan: `forget(callID:)` and `movedCalls`.
- **"The coach's memory of that call."** `CoachProfile.forget(callID:)` (`CoachProfile.swift:439-447`) leaves the rated points, which hold the meeting's title (`:142-150`), the answered questions, and the answers to cards; `merged` takes them from the other copy again (`:325-333`). Plan: `forgetMoved(callID:)` and `movedCalls`.
- **"A person whom that call made."** A person has `origin` and `created` and no call (`Person.swift:250-251`); `PeopleStore.ensure` logs "create" with no call (`PeopleStore.swift:236-249`). No page makes a person by hand. Plan: the rule in "Choices".
- **"As the People page's delete does."** That delete is two calls in a view (`PeopleView.swift:96-97`). It leaves the coach's notes on the person (`CoachProfile.people`). Plan: the same two calls, and `CoachProfile.forget(person:)`.
- **"The chats of that call go with it."** A chat deleted here is deleted on the other device by its id (`ChatStore.swift:129-139`, `CloudSync.swift:560-561`), so a chat that came back with its old id would be deleted again. Plan: new ids.
- **The owner's "own mark on the record".** There is none: the owner is found by name or by id (`OwnerIdentity.swift:24-28`). Plan: `ownerKeys` in the marker.
- **The person ids the spec lists are not all.** `PersonHint.personID` (`CallRecord.swift:483`) and `organizer.personID` (`CallRecord.swift:217`, `CalendarMatcher.swift:12`) hold one too, and `PersonReferences.withoutIDs` clears neither (`PersonReferences.swift:277-283`). `Commitment.toID` is in the book, not in the record. A share is in `Shares/shares.json` by call id (`MeetingLink.swift:269-275`), not in the record.
- **A moved record must not name a file of the first profile.** `markdownPath` is an absolute path (`CallRecord.swift:265`), and `Pipeline.write` deletes the file at the old path when the new one differs (`Pipeline.swift:1017`). A record that kept it would make the target delete the first profile's note. Plan: cleared, with a test.
- **"`CallRecord.swift:233`".** The fingerprints are `speakerEmbeddings` at `:237`, with `speakerSamples` at `:240`. A meeting has none when "voice fingerprints" is off (`Pipeline.swift:766-779`) or after a failed "Transcribe again" (`:318`). Then nothing is compared and the names stay as labels.
- **"Downloaded and checked first."** The only download is an internal helper of a backup place (`ArchiveBackend.swift:90`), used by `ArchiveMove` (`ArchiveMove.swift:240`). Plan: `CloudArchive.fetch`.
- **`ReferenceBackup.forget(callID:)` leaves the copy of the note** (`ReferenceBackup.swift:24-26`, and `keep(note:)` at `:18-21`). Plan: `forget(note:)`.
- **"At each pass."** A worker's passes are the queue every 3600 s and the sync every 300 s (`WorkerPace.swift:7`), and the tests of `WorkerPace.due` pin its numbers. Plan: a look of its own in `ProfileWorker.run()`.
- **"The live transcript, the live chat, and the live points stop."** Three more things send a live call's words: the live title (`AppController.swift:1437-1465`), the summary of the live chats a minute after the call (`AppController+LiveChat.swift:103`), and `live.json`, which `current_call` gives to the app's chat and to other AI apps. Plan: all six ask one gate, and `live.json` is deleted at the choice.
- **The checked facts hold.** `ProcessingQueue.scan()` and `Retention.sweep` read every folder in `Audio` (`ProcessingQueue.swift:24-30`, `Retention.swift:15`), and so do `Pipeline.finishInterruptedMerges` (`Pipeline.swift:1288`) and `CloudSync.push` (`CloudSync.swift:119`). The local-copy rule is `CloudArchive.swift:99-104`. `VoiceLibrary.forget(callID:speakerKey:from:voice:)` is `VoiceLibrary.swift:176`. `identify` reads the raw tracks (`Pipeline.swift:795-797`). `Duty.takeInMoved` is in the table for the app in front and a worker (`RunMode.swift:31`, `:45-46`). The sync deletes a meeting in the store when its folder is gone (`CloudSync.swift:114-143`). `UsageLog` has no way to remove a row.

## What Part 2 still adds

These are in the Part 2 plan (Tasks 9 to 12) and not in the code read for this plan. Read them on the branch before the task that uses them.

- `AppController.mode: RunMode`, and the gates that ask `mode.does(_:)` in place of `isInert` (Part 2, Task 9). Used by Tasks 11 and 12.
- `AppController.workers: WorkerManager` and `@Published var workerLines: [String: String]` (Part 2, Task 9). Used by Task 11.
- The switcher's second line (Part 2, Task 11) and the `AGENTS.md` row for the worker (Part 2, Task 12). Used by Task 13.

## The move on one page

**The files.** `A` is the first profile, `B` the target, `<id>` the call id.

| File | Writer | What it holds |
| --- | --- | --- |
| `A/Audio/<id>/call.json`, key `moveTo` | A | The target's profile id. Set when the move starts, cleared by a cancel. |
| `A/Moves/<id>.json` (`MoveOut`) | A | `version`, `callID`, `to`, `state`, `started`, `afterCall`, `removed` (the removal steps that ended), `cancel` (why, while it cancels). |
| `B/Incoming/<id>.part/` | A | The copy while it is made. |
| `B/Incoming/<id>/move.json` (`MoveMarker`) | A | `version`, `callID`, `from`, `to`, `made`, `files` (path, size, SHA-256), `ownerKeys`. |
| `B/Incoming/<id>/call/…`, `B/Incoming/<id>/chats/<chat id>.json` | A | The prepared record, the audio, the frames, the chats. |
| `B/Incoming/<id>/claimed.json` | B | The same marker after B's rename, with `intake`, `finalID`, `refusal`, `chatIDs`. |
| `B/Incoming/<id>/call/arrival.json` | B | The record as it will arrive, until it takes the place of `call.json`. |

**The states.** A: `copying`, `copied`, `waiting`, `removing`, `done`, and `cancelling`. B: incoming (`move.json` is there), taking in (`claimed.json` with `intake` nil or `takingIn`), `taken`, `refused`.

**A stop after each state, and the next launch.** This table is `testTheSourcesNextStepForEachStateMarkerAndTarget` and `testTheTargetsNextStep` (Task 1), and Task 9 runs it on real folders.

| The stop comes after | In A | In B | Next launch of A | Next launch of B |
| --- | --- | --- | --- | --- |
| A saved `copying` | whole, marked | nothing, or a half `<id>.part` | removes the part, copies again | ignores a part |
| A saved `copied` | whole | `<id>.part` whole, checked, with `move.json` | renames it to `<id>` | ignores a part |
| A renamed the part (ledger still `copied`) | whole | `<id>` with `move.json` | saves `waiting` | may claim |
| A saved `waiting` | whole | `<id>` with `move.json` | waits, reads the marker | claims |
| B claimed | whole | `<id>` with `claimed.json` | waits; a cancel is refused | decides the id, or refuses |
| B saved `takingIn` | whole | the same | waits | writes `arrival.json`, learns the voices, writes the chats |
| B put `arrival.json` in place of `call.json` | whole | the prepared folder in `Incoming` | waits | moves the folder to `Audio/<final id>` |
| B moved the folder (marker still `takingIn`) | whole | whole in `Audio` | waits | saves `taken` |
| B saved `taken` | whole | whole | saves `removing` | its pipeline, as for any meeting |
| A saved `removing`, and k of its 8 steps | the folder until the last step | whole | goes on at step k+1 | nothing |
| A removed the folder | gone | whole | removes `B/Incoming/<id>`, saves `done` | nothing |
| A saved `done` | `Moves/<id>.json` only | whole | nothing | nothing |
| B saved `refused` | whole | `<id>` untouched | cancels: removes `B/Incoming/<id>`, takes the mark off, deletes its ledger | nothing |
| A saved `cancelling` | whole, marked | its own leftovers | finishes the cancel | nothing: no `move.json` |

A newer `move.json`, `claimed.json`, or `Moves/<id>.json` is read and never acted on: A waits, B does nothing.

**The removal, in order** (`MoveOut.Step`). Each step reads the record from the call folder, so the folder goes last. A step that ended is in `removed`; a folder that is gone counts every step as done.

| Step | What goes | The function |
| --- | --- | --- |
| `voices` | Each voice sample that this call taught, the owner's too | `VoiceLibrary.forget(callID:speakerKey:from:voice:)` |
| `people` | A person whom only this call made; their read; the coach's notes on them | `MoveRemoval.peopleToRemove`, the People page's two calls (`forgetPersona`, `VoiceLibrary.delete`), `CoachProfile.forget(person:name:at:)` |
| `coach` | The coach's memory of the call; the runner's entry; the persona evidence | `CoachProfile.forgetMoved(callID:at:)`, `CoachRunner.forget(_:paths:)`, `PersonaStore.forget(callID:)` |
| `books` | The tasks of the call; the points it closed, carried, or mentioned; its chats | `CommitmentBook.forget(callID:at:)`, `NextTimeBook.forget(callID:at:)`, `ChatStore.deleteChats(forCall:)` |
| `shares` | Its share links, stopped | `ShareBook.markStopping(callID:)`, in the app `stopSharing(callID:)` |
| `backup` | The backup copy and its older copies | `CloudArchive.delete(_:)`, else `CloudArchive.rememberDeletes(of:paths:)` |
| `notes` | Its Gemini notes never come again | `RemovedNotes.add(_:paths:)` |
| `folder` | The note, its two reference backups, the call folder | `Pipeline.removeMoved(callID:)` |

After `folder`: `B/Incoming/<id>` is removed, `done` is saved, and the app refreshes its list (the search index follows) and syncs (the store deletes a meeting whose folder is gone). The usage log is never touched.

## The record and the files that go

**Every stored field of `CallRecord`** (`MovedRecord.fields`, tested by `testEveryFieldOfARecordHasARule`, which fails when a field is added with no rule):

| Rule | Fields | Why |
| --- | --- | --- |
| Kept | `id`, `platform`, `bundleID`, `start`, `end`, `status`, `failedStep`, `meetingID`, `calendarTitle`, `generatedTitle`, `customTitle`, `plannedStart`, `plannedEnd`, `attendees`, `calendarSeriesID`, `utterances`, `meUtterances`, `themUtterances`, `speakerNames`, `unknownSpeakers`, `speakerEmbeddings`, `speakerSamples`, `fromInvite`, `summary`, `topics`, `kind`, `tags`, `tagsSetByOwner`, `summaryVersion`, `hasOutcomes`, `decisions`, `decisionTimes`, `headline`, `parts`, `markers`, `summaryMissing`, `speakersExpected`, `muteSpans`, `mutedAudioPending`, `screens`, `screenGaps`, `deletedScreens`, `source` | The meeting itself. Names are labels. The target sets `id` and `status` when it takes the folder in. `mutedAudioPending` must travel: the silence is still to be written before anything is sent. |
| Changed | `invitees` and `organizer` (each `personID` nil), `actionItems` (each `ownerID` nil), `personHint` (`personID` nil); `moveTo` (the target's id) | An id of the first profile's people: the name and the address stay. `moveTo` says "on its way" until the target takes the folder in and clears it, so the target can tell a record that arrived from one that has not, and no pipeline ever processes a record on its way. |
| Cleared | `speakerPeople`; `markdownPath`; `cloudKey`, `cloudSize`, `cloudBackend`, `cloudServer`, `cloudHash`, `cloudLeftovers`; `transcriptionJobs`; `gemini`; `attempts` (0), `nextAttempt`, `failureReason`, `inviteUnknown` | Ids; a file of the first profile; its backup; a job in its provider's account; a document of its Google account; the count and the words of its failed tries. |

**Every file a call folder can hold** (`MovedFiles.rule`):

| File | Rule | Why |
| --- | --- | --- |
| `call.json` | prepared | The table above. |
| `me.caf`, `them.caf`, `recording.m4a` | as it is | The audio. A recording that is only in the backup is fetched to `A/Moves/<id>.download/` and copied from there; A's folder does not change. |
| `frames.json`, `frames/` | as it is | The screens go with the meeting. |
| `call.previous.json` | never | The Undo copy of "Transcribe again": an older transcript with the first profile's ids. |
| `coach.json`, `findings.json` | never | They stand on the first profile's memory and goals. |
| `live.json`, `live-points.json` | never | Names that were not final; the points are the first profile's. |
| `upload-me.m4a`, `upload-them.m4a`, `clip-*.caf`, a `.caf` with a UUID name, any other name | never | Leftovers and files made again on demand. Only the names above are copied. |
| `call.quiet.json`, `call.merged.json`, `merge.json`, `premerge-*`, `joined-*`, `frames.merged.json` | in work | A run or a merge is not finished: the move is refused. |

The chats: each file of `A/Chats` whose `callID` is the meeting's, with `actions` taken off each message.

## Proof runs

A proof run is two workers of the debug build on a made-up registry. Each one obeys all of these:

1. Run the call gate script that your brief names. Go on only when it says the Mac is idle.
2. Use the debug build of this worktree, `build/dev/Build/Products/Debug/Mossad.app` (the build check makes it). Never the app in /Applications.
3. A made-up registry with two made-up profiles and made-up folders under `build/proof/` of this worktree.
4. No window: a worker has none. Never start the window app for a proof. Nothing takes the keyboard.
5. End each process that you started by its own pid, within 90 s.
6. Read and write nothing under `~/Mossad` or `~/Library/Application Support/Mossad`.
7. Clean up after: `rm -rf build/proof; defaults delete com.dwebber.mossad.profile.aaaa1111 2>/dev/null; defaults delete com.dwebber.mossad.profile.bbbb2222 2>/dev/null`.

The setup that each proof starts with:

```sh
APP="$PWD/build/dev/Build/Products/Debug/Mossad.app/Contents/MacOS/Mossad"
P="$PWD/build/proof"; A="$P/A"; B="$P/B"; rm -rf "$P"; mkdir -p "$A" "$B"
printf '{"version":1,"active":"aaaa1111","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"aaaa1111","name":"Proof A","color":"blue","root":"%s"},{"id":"bbbb2222","name":"Proof B","color":"green","root":"%s"}]}' "$A" "$B" > "$P/profiles.json"
export MOSSAD_PROFILES="$P/profiles.json"
for id in aaaa1111 bbbb2222; do defaults write com.dwebber.mossad.profile.$id welcomeDone -bool true; done
fg() { printf '{"version":1,"pid":%s,"recording":%s,"stopping":%s}' "$1" "$2" "$3" > "$P/fg.tmp" && mv "$P/fg.tmp" "$P/foreground.json"; }
say -o "$P/call.aiff" "This is a made-up meeting for a proof. One, two, three, four, five, six, seven, eight, nine, ten."
list() { ( cd "$P" && find A B -type f ! -path '*/Logs/*' ! -path '*/Worker/*' | sort ); }
sums() { find "$P" -name 'recording.m4a' -exec shasum -a 256 {} \; | awk '{print $1}' | sort -u; }
```

The DEBUG hooks (Task 10), on a made-up registry only, in a worker only:

- `MOSSAD_PROOF_MEETING=<audio file>`: in an empty folder, one made-up meeting: the file imported as a room recording (`PhoneRecording.importAudio`, which gives `me.caf`), then set to `summarized` with two voices (the profile's "Your name" on `me:A`, "Sam Carter" on `me:B`), a fingerprint of 8 numbers for each, six lines, a summary, and a chat. The worker's first pass makes `recording.m4a` and writes the note.
- `MOSSAD_PROOF_MOVE=<profile id>`: after `MOSSAD_PROOF_MOVE_AFTER` seconds (20 when not given), moves the one written meeting of this folder to that profile.
- `MOSSAD_PROOF_MOVE_STOP=copied`: the worker ends (exit 0) right after its ledger says `copied`.
- `MOSSAD_PROOF_INTAKE_STOP=takingIn`: the worker ends (exit 0) right after it saved `takingIn`.

## File structure

| File | Responsibility |
| --- | --- |
| `Packages/MossadCore/Sources/MossadCore/Profiles/MoveMarker.swift` (new) | `MoveMarker` (the file in `Incoming/<id>`) and `MoveOut` (the first profile's ledger). |
| `.../Profiles/MovePlan.swift` (new) | The next step of each side, the id that is taken, the target's decision. Pure. |
| `.../Profiles/MovedRecord.swift` (new) | The record and the chat that leave, the rule of each file, the arrival status. Pure. |
| `.../Profiles/MoveRules.swift` (new) | What may move, the targets, who may move, the paces, and `MoveWords`. Pure. |
| `.../Profiles/MoveCopy.swift` (new) | The copy into `<id>.part` with its checks, and the rename. |
| `.../Profiles/MovedVoices.swift` (new) | The names of the voices in the target, and what is learned. |
| `.../Profiles/MoveIntake.swift` (new) | The target's half, one step at a time. |
| `.../Profiles/MoveRemoval.swift` (new) | The first profile's removal, one step at a time, and the rule of the person who goes. |
| `.../Profiles/MoveSource.swift` (new) | The first profile's half, one step at a time: start, advance, cancel. |
| `.../Profiles/MoveAfterCall.swift` (new) | "This call is for": the choice, the gate of every send, the panel's menu, the end of the call. Pure. |
| `.../Profiles/MoveProof.swift` (new, `#if DEBUG`) | The made-up meeting of the proofs. |
| `.../Support/Paths.swift` | `incoming`, `moves`. Not in `ensureDirectories`. |
| `.../Records/CallRecord.swift`, `.../Records/ProcessingQueue.swift`, `.../Pipeline/Pipeline.swift`, `.../Capture/CallRecorder.swift` | `moveTo`; the guards; `setMoveTarget`, `isBusy`, `removeMoved`. |
| `.../Cloud/CloudArchive.swift` | `fetch`. |
| `.../Commitments/Commitment.swift`, `.../Series/NextTime.swift`, `.../Coach/CoachProfile.swift`, `.../People/ReferenceBackup.swift` | The books forget a call for good. |
| `.../Chat/AskPanel.swift` | Two more reasons in `LiveOffReason`. |
| `.../Worker/ProfileWorker.swift`, `App/WorkerEntry.swift` | The worker's two hooks and its look; the DEBUG hooks. |
| `App/AppController+Moves.swift` (new) | The moves in the app: start, cancel, check, resume, and "This call is for". |
| `App/MoveViews.swift` (new) | "Move to" in the two menus, the confirmation, the row's line, the panel's row. |

---

### Task 1: The marker, the ledger, and the plan of both sides

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveMarker.swift`, `.../Profiles/MovePlan.swift`
- Modify: `.../Support/Paths.swift` (two lines after `worker`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MovePlanTests.swift` (new)

**Interfaces:**
- Consumes: `Paths`, `CallRecord`, `Platform.unknown`.
- Produces:

```swift
// Paths: made by the first move, never by ensureDirectories
public var incoming: URL { get }     // root/Incoming
public var moves: URL { get }        // root/Moves

public struct MoveMarker: Codable, Equatable, Sendable {
    public static let fileName = "move.json", claimedName = "claimed.json", cancelledName = "cancelled.json"
    public static let partSuffix = ".part", callFolder = "call", chatsFolder = "chats", arrivalName = "arrival.json", currentVersion = 1
    public static let allowedKeys: Set<String> = ["version", "callID", "from", "to", "made", "files", "path", "size", "sha256",
                                                  "ownerKeys", "intake", "finalID", "refusal", "chatIDs"]
    public struct File: Codable, Equatable, Sendable { public var path: String; public var size: Int64; public var sha256: String }
    public enum Intake: String, Codable, Sendable { case takingIn, taken, refused }
    public enum Refusal: String, Codable, Sendable { case idTaken, unreadable, notWhole }
    public var version: Int, callID: String, from: String, to: String, made: Date
    public var files: [File]                 // paths under Incoming/<id>: "call/call.json", "chats/<uuid>.json"
    public var ownerKeys: [String]
    public var intake: Intake?, finalID: String?, refusal: Refusal?   // the target's half
    public var chatIDs: [String: String]?    // the chat id of the first profile to the id it gets here
    public init(callID: String, from: String, to: String, made: Date, files: [File], ownerKeys: [String])
    public enum Look: Equatable, Sendable { case missing, incoming(MoveMarker), claimed(MoveMarker), unknown }
    public static func folder(_ callID: String, in target: Paths) -> URL
    public static func look(_ folder: URL) -> Look     // reads move.json or claimed.json and nothing else
    public func save(in folder: URL, claimed: Bool) throws
    public static func claim(_ folder: URL) -> Bool      // rename move.json to claimed.json
    public static func takeBack(_ folder: URL) -> Bool   // rename move.json to cancelled.json
}
public struct MoveOut: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public enum State: String, Codable, CaseIterable, Sendable { case copying, copied, waiting, removing, cancelling, done }
    public enum Step: String, Codable, CaseIterable, Sendable { case voices, people, coach, books, shares, backup, notes, folder }
    public var version: Int, callID: String, to: String, state: State, started: Date, afterCall: Bool, removed: [String]
    public var cancel: MovePlan.Cancel?                    // why, saved with the state .cancelling
    public init(callID: String, to: String, started: Date, afterCall: Bool = false)      // state .copying
    public var nextStep: Step? { get }                    // the first of Step.allCases not in `removed`
    public static func url(_ callID: String, paths: Paths) -> URL                       // Moves/<id>.json
    public static func load(_ callID: String, paths: Paths) -> MoveOut?                 // nil: no file, not readable, or newer
    public static func all(_ paths: Paths) -> (moves: [MoveOut], unknown: [String])     // unknown: ids of files this build does not act on
    public static func leftIDs(_ paths: Paths) -> Set<String>                           // every id with a file in Moves, readable or not
    public static func hasWork(_ paths: Paths) -> Bool                                  // a move that is not done
    public func save(_ paths: Paths) throws                                             // one atomic write; makes Moves
    public static func delete(_ callID: String, paths: Paths)
}
public enum MovePlan {
    public enum Target: Equatable, Sendable { case live, gone }
    public enum Cancel: String, Codable, Equatable, Sendable {
        case byOwner, targetGone, lost, refusedIDTaken, refusedUnreadable, refusedNotWhole, noRoom, copyFailed, backupFailed
    }
    public enum SourceStep: Equatable, Sendable { case copy, publish, wait, remove, cleanUp, cancel(Cancel), finishCancel, nothing }
    public static func source(_ state: MoveOut.State, marker: MoveMarker.Look, part: Bool, target: Target) -> SourceStep
    public enum TargetStep: Equatable, Sendable { case claim, decide, takeIn(as: String), markTaken, refuse(MoveMarker.Refusal), wait, nothing }
    public static func target(_ look: MoveMarker.Look, callFolder: Bool, audio: Set<String>, ownRemoval: Bool) -> TargetStep
    public static func finalID(_ id: String, taken: Set<String>) -> String?
    public static func decide(record: CallRecord?, sizesMatch: Bool, id: String, taken: Set<String>) -> (intake: MoveMarker.Intake, finalID: String?, refusal: MoveMarker.Refusal?)
}
```

`look`: no folder, or a folder with neither file, is `.missing`; a file that does not decode or has a `version` above `currentVersion` is `.unknown`. `Target.gone` is a profile that is not in the registry, is marked `removing`, or has no folder. `decide`: a record that is nil or has the platform `.unknown` is `refused`, `unreadable`; `sizesMatch` false is `notWhole`; `finalID` nil is `idTaken`; else `takingIn`. `taken` is the folder names of the target's `Audio` joined with `MoveOut.leftIDs`.

`source`:

| `state` | `target` | `marker` | `part` | Step |
| --- | --- | --- | --- | --- |
| `copying` | live | any | any | `copy` |
| `copying`, `copied` | gone | any | any | `cancel(.targetGone)` |
| `copied` | live | `missing` | true | `publish` |
| `copied` | live | `missing` | false | `copy` |
| `copied` | live | `incoming`, `claimed`, `unknown` | any | `wait` |
| `waiting` | any | `claimed`, `intake` `taken` | any | `remove` |
| `waiting` | any | `claimed`, `intake` `refused` | any | `cancel` with `refusedIDTaken`, `refusedUnreadable`, or `refusedNotWhole` |
| `waiting` | live | `incoming`; `claimed` with `intake` nil or `takingIn`; `unknown` | any | `wait` |
| `waiting` | live | `missing` | any | `cancel(.lost)` |
| `waiting` | gone | anything that is not `taken` or `refused` | any | `cancel(.targetGone)` |
| `removing` | any | any | any | `remove` |
| `cancelling` | any | any | any | `finishCancel` |
| `done` | any | `missing` | any | `nothing` |
| `done` | any | any other | any | `cleanUp` |

`target`:

| `look` | Condition | Step |
| --- | --- | --- |
| `missing`, `unknown` | | `nothing` |
| `incoming` | `ownRemoval` (this profile still removes this id) | `wait` |
| `incoming` | else | `claim` |
| `claimed`, `intake` nil | | `decide` |
| `claimed`, `takingIn`, `finalID` f | `callFolder`, and `audio` does not hold f | `takeIn(as: f)` |
| `claimed`, `takingIn`, `finalID` f | no `callFolder`, and `audio` holds f | `markTaken` |
| `claimed`, `takingIn`, `finalID` f | `callFolder`, and `audio` holds f (the id was taken since) | `decide` |
| `claimed`, `takingIn` | no `callFolder`, and `audio` does not hold f | `refuse(.notWhole)` |
| `claimed`, `taken` or `refused` | | `nothing` |

- [ ] **Step 1: Write the failing tests**

```swift
func testTheMarkerHoldsIDsSizesAndHashesOnly() throws {
    // A marker for "20261101-100000" from "default" to "1a2b3c4d", files "call/call.json" and "chats/<uuid>.json", ownerKeys ["me:A"],
    // with intake .taken, finalID, and chatIDs: every key at every level of its JSON is in MoveMarker.allowedKeys, and the text has no "@".
}
func testANewerFileIsReadAndNeverActedOn() throws {
    // move.json with "version": 2: look is .unknown; MovePlan.target(.unknown, callFolder: true, audio: [], ownRemoval: false) is .nothing;
    // MovePlan.source(.waiting, marker: .unknown, part: false, target: .live) is .wait.
    // Moves/20261101-100000.json with "version": 2: MoveOut.load is nil; all(paths).unknown is ["20261101-100000"]; leftIDs holds it.
}
func testOneRenameDecidesBetweenAClaimAndACancel() throws {
    // A folder with move.json: claim() true, then takeBack() false, and look is .claimed.
    // A second folder: takeBack() true, then claim() false, and look is .missing.
}
func testTheSourcesNextStepForEachStateMarkerAndTarget()   // every row of the table above
func testOnlyATakenMarkerLetsTheSourceRemove() {
    // For state in [.copying, .copied, .waiting], each look of [missing, incoming, claimed(nil), claimed(.takingIn), claimed(.refused), unknown],
    // part in [false, true], target in [.live, .gone]: the step is never .remove and never .cleanUp.
    // source(.waiting, claimed(.taken), part: false, target: .live) and the same with .gone are .remove.
}
func testARemovalGoesOnWithoutTheTarget()                  // .removing with every look, both parts, both targets: .remove
func testTheTargetsNextStep()                              // every row of the second table
func testTheIDThatIsTaken() {
    XCTAssertEqual(MovePlan.finalID("20261101-100000", taken: []), "20261101-100000")
    XCTAssertEqual(MovePlan.finalID("20261101-100000", taken: ["20261101-100000"]), "20261101-100000-moved")
    XCTAssertEqual(MovePlan.finalID("20261101-100000-moved", taken: ["20261101-100000", "20261101-100000-moved"]), "20261101-100000-moved-moved")
    XCTAssertNil(MovePlan.finalID("20261101-100000", taken: ["20261101-100000", "20261101-100000-moved"]))
}
func testTheTargetsDecision() {
    // record nil: (.refused, nil, .unreadable). A record with the platform .unknown: the same. sizesMatch false: (.refused, nil, .notWhole).
    // Both names taken: (.refused, nil, .idTaken). Else (.takingIn, the final id, nil).
}
func testTheLedgerKeepsItsStepsAndTheIDsThatLeft() throws {
    // save, load: equal. removed ["voices", "people"]: nextStep is .coach; all eight: nil.
    // A done move and a waiting move in Moves: leftIDs has both; hasWork is true; with only the done one, false.
}
func testWithOneProfileNoFolderIsMade() throws {
    // Paths(root: temp).ensureDirectories(): neither Incoming nor Moves exists; MoveOut.all is ([], []); leftIDs is empty; hasWork false;
    // MoveMarker.look of a folder that is not there is .missing.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter MovePlanTests`. Expected: the build fails with "cannot find 'MoveMarker' in scope".
- [ ] **Step 3: Write the two files and the two lines of `Paths`.** `claim` and `takeBack` use `rename(2)` (through `FileManager.moveItem`, which fails when the source is gone). `save` writes atomically. Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A move has a marker in the target's Incoming folder, a ledger in the first profile, and one table for the next step of each side"`

---

### Task 2: The record, the chat, and the files that go

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MovedRecord.swift`
- Modify: `.../Records/CallRecord.swift` (one stored field after `personHint`, one line in `init(from:)`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MovedRecordTests.swift`, `MoveTestSupport.swift` (new)

**Interfaces:**
- Consumes: `CallRecord`, `Chat`, `OwnerIdentity.speakerKeys(in:)`, `PersonReferences.withoutIDs`, `Pipeline.previousFileName`, `Recording.fileName`, `LiveTranscript.fileName`, `LivePointMarks.fileName`, `CoachReview.fileName`, `CallFindings.fileName`.
- Produces:

```swift
// CallRecord
/// The profile this meeting leaves for. Set when a move starts; the pipeline and the queue leave a marked call alone.
public var moveTo: String?

public enum MovedRecord {
    public enum Rule: String, Sendable { case kept, changed, cleared }
    public static let fields: [String: Rule]                       // every JSON key of CallRecord, as in "The record and the files that go"
    public static func prepared(_ r: CallRecord, to target: String) -> CallRecord
    public static func ownerKeys(_ r: CallRecord, owner: OwnerIdentity) -> [String]     // sorted
    public static func prepared(_ chat: Chat) -> Chat              // no actions on any message
    public static func arrival(status: CallStatus, failedStep: CallStatus?, namesChanged: Bool) -> CallStatus
}
public enum MovedFiles {
    public enum Rule: Equatable, Sendable { case asIs, prepared, never, inWork }
    public static func rule(_ name: String) -> Rule                // the first path component of a file in a call folder
    public static func inWork(_ names: [String]) -> Bool
    public static func list(in dir: URL) -> [String]               // the relative paths that go as they are, sorted
}
// MoveTestSupport.swift (tests)
func fullRecord(id: String = "20261101-100000") -> CallRecord       // every stored field set to a value that is not its default
func writtenCall(in paths: Paths, id: String = "20261101-100000") throws -> CallRecord
```

`arrival`: `(.recorded, _, _)` is `.recorded`; `(.failed, nil, _)` is `.recorded`; `(.failed, .recorded, _)` is `.recorded`; `(.failed, .transcribed, _)` is `.transcribed`; `(.failed, .identified, _)` is `.identified`; `(.written, _, changed)` and `(.failed, .summarized, changed)` are `.identified` when `changed`, else `.summarized`.

`writtenCall` makes a written meeting on disk: the customTitle "Zebra budget", the calendarTitle "Weekly sync", `speakerNames` `["me:A": "Avery Webb", "them:A": "Sam Carter"]`, the unnamed voice `them:B` in `unknownSpeakers`, a fingerprint of 8 numbers and a `speakerSamples` entry (30 s) for each of the three, six lines with "the zebra crossing is closed", a summary that says "Sam Carter" and "Speaker B", one action item of "Speaker B", `me.caf` and `them.caf` (`writeSegments`), a small `recording.m4a`, `frames.json` with `frames/000012000.heic`, `call.previous.json`, `coach.json`, `findings.json`, `live-points.json`, the note in `Meetings` with `markdownPath`, and one chat in `Chats` with a receipt and the answer "See [12:04](mossad://call/20261101-100000?t=724)".

- [ ] **Step 1: Write the failing tests**

```swift
func testEveryFieldOfARecordHasARule() throws {
    // The keys of the JSON of fullRecord() are exactly Set(MovedRecord.fields.keys): 62 keys with moveTo.
}
func testTheFieldsOfAMovedRecord() throws {
    // before = JSON of fullRecord() (its moveTo is "5e6f7a8b"), after = JSON of MovedRecord.prepared(fullRecord(), to: "1a2b3c4d"),
    // fresh = JSON of a new CallRecord(id:platform:bundleID:start:end:status:).
    // .kept: after[key] equals before[key]. .cleared: after[key] equals fresh[key] (absent, or 0 for attempts). .changed: after[key] differs from before[key].
    // Counts: 43 kept, 5 changed, 14 cleared.
}
func testTheMovedRecordHasNoIDOfTheFirstProfile() {
    // speakerPeople nil; each invitee has personID nil and its name and email; organizer.personID nil; each action item has ownerID nil
    // and its owner; personHint.personID nil and its name. The JSON of the prepared record has none of the three person ids of fullRecord().
}
func testTheMovedRecordNamesNoPlaceOfTheFirstProfile() {
    // markdownPath, cloudKey, cloudSize, cloudBackend, cloudServer, cloudHash, cloudLeftovers, gemini, transcriptionJobs,
    // nextAttempt, failureReason, inviteUnknown are nil; attempts is 0; mutedAudioPending and muteSpans are as they were.
    // moveTo is "1a2b3c4d", the target's id.
}
func testTheFilesOfACallFolder() throws {
    // rule: "call.json" .prepared; "me.caf", "them.caf", "recording.m4a", "frames.json", "frames" .asIs;
    // "call.previous.json", "coach.json", "findings.json", "live.json", "live-points.json", "upload-me.m4a", "upload-them.m4a",
    // "clip-them-A.caf", "3F2504E0-4F89-11D3-9A0C-0305E82C3301.caf", "notes.txt" .never;
    // "call.quiet.json", "call.merged.json", "merge.json", "premerge-me.caf", "joined-them.caf", "frames.merged.json" .inWork.
    // list(in:) of the folder of writtenCall: ["frames.json", "frames/000012000.heic", "me.caf", "recording.m4a", "them.caf"].
    // inWork(["call.json", "merge.json"]) true; inWork(["call.json", "me.caf"]) false.
}
func testAMovedChatHasNoReceipts()         // the id, title, callID, summary, and each message's text and steps are equal; every `actions` is nil
func testTheOwnersKeysComeFromTheFirstProfile() {
    // speakerPeople ["me:A": "p1"], OwnerIdentity(name: "A. Webb", id: "p1"): ["me:A"], by the id though the name differs.
    // No ids, OwnerIdentity(name: "Avery Webb"): ["me:A"]. A record with no line of the owner: [].
}
func testTheArrivalStatus()                // the eight cases above
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MovedRecordTests`. Expected: the build fails with "cannot find 'MovedRecord' in scope".
- [ ] **Step 3: Write the code.** `prepared(_:to:)` starts from `PersonReferences.withoutIDs`. Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A record that leaves a profile has no id, no backup place, and no file path of that profile, and each file of a call folder has its rule"`

---

### Task 3: What may move, and the words

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveRules.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveRulesTests.swift` (new)

**Interfaces:**
- Consumes: `MoveOut`, `MovePlan.Cancel`, `MovedFiles.inWork`, `ProfileRegistry`, `ProfileRegistry.Loaded`, `Profile.rootURL(home:)`, `RunMode`, `AppIdentity` (`mayChangeRegistry`), `UsageEvent`.
- Produces:

```swift
public enum MoveRules {
    public enum Sent: Equatable, Sendable { case nothing, live, inWork, all }
    public static func sent(_ r: CallRecord, hasLiveFile: Bool, usage: [UsageEvent]) -> Sent
    public enum Offer: Equatable, Sendable { case hidden, offer, moving(to: String), refused(String) }
    public static func offer(_ r: CallRecord, busy: Bool, files: [String], usage: [UsageEvent], move: MoveOut?) -> Offer
    public static func targets(_ registry: ProfileRegistry, active: String) -> [Profile]
    public static func mayMove(mode: RunMode, identity: AppIdentity, registry: ProfileRegistry.Loaded) -> Bool
    public static func targetPaths(_ id: String, in registry: ProfileRegistry.Loaded, home: URL?) -> Paths?
    public static let look: TimeInterval = 15, slowAfter: TimeInterval = 60, resultShows: TimeInterval = 8, refusalShows: TimeInterval = 30
}
public enum MoveWords {
    public static let menu = "Move to", confirm = "Move", cancelMove = "Cancel move", processHere = "Process here"
    public static let notesOnly = "A meeting made from Gemini notes stays with its Google account."
    public static let inWork = "Mossad is working on this meeting. Move it when its notes are ready."
    public static let heldForGone = "This call was for a profile that is gone. Mossad does not process it until you choose."
    public static func title(_ meeting: String, to target: String) -> String
    public static func sent(_ sent: MoveRules.Sent, from active: String, to target: String) -> String
    public static func leaves(_ active: String) -> String
    public static func row(to target: String, waited: TimeInterval, copied: Double?) -> String
    public static func moved(to target: String) -> String
    public static func tooLate(_ target: String) -> String
    public static func refusal(_ why: MovePlan.Cancel, target: String) -> String?
}
```

`sent`: written or failed is `.all`. `transcribed`, `identified`, `summarized`, or recorded with `transcriptionJobs`, `meUtterances`, `themUtterances`, `attempts` above 0, or a usage row of this call whose purpose is `.transcription`, is `.inWork`. Recorded with `hasLiveFile`, or with a usage row of this call whose purpose is `.live`, is `.live`. Else `.nothing`.

`offer`, the first that applies: status `recording` is `.hidden`; a `move` that is not `done`, or a `moveTo` on the record, is `.moving(to:)`; a notes-only meeting is `.refused(notesOnly)`; `busy`, `MovedFiles.inWork(files)`, the platform `.unknown`, or `sent` `.inWork` is `.refused(inWork)`; else `.offer`. `files` is the names in the call folder; `hasLiveFile` is whether `live.json` is one of them.

`targets`: the live profiles other than `active`, in the registry's order; none with one profile. `mayMove`: `mode == .full`, `identity.mayChangeRegistry`, and `registry.state == .read`. `targetPaths`: nil unless the state is `.read`, the profile is live, and its folder is a folder on disk.

The words. `title`: "Move “Zebra budget” to “Work”?". `sent`: `.all` "“Mossad” already sent this meeting to its transcription and notes services, and a move cannot take that back."; `.live` "The live transcript of this call went to the transcription service of “Mossad”. Nothing else was sent."; `.nothing` "As far as Mossad knows, nothing of this meeting was sent from “Mossad”. “Work” does all the work with its own keys."; `.inWork` is `inWork`. `leaves`: "The meeting leaves “Mossad” with its tasks, its chats, and what Mossad learned from it." `row`: "Moving to Work…"; with `copied` 0.4, "Moving to Work… 40%"; with `waited` of 60 or more and no `copied`, "Moving to Work… It arrives when “Work” is next open." `moved`: "Moved to Work". `tooLate`: "“Work” has the meeting already." `refusal`: `byOwner` nil; `targetGone` "“Work” is no longer a profile. The meeting stays here."; `lost` "The copy in “Work” is gone. The meeting stays here."; `refusedIDTaken` "“Work” cannot take this meeting in. The meeting stays here."; `refusedUnreadable` "“Work” could not read this meeting. The meeting stays here."; `refusedNotWhole` "The copy in “Work” was not whole. The meeting stays here."; `noRoom` "There is not enough room on this Mac to move the meeting. Nothing was moved."; `copyFailed` "The copy did not match the meeting. Nothing was moved."; `backupFailed` "The recording is only in the backup, and Mossad could not get it. Nothing was moved."

- [ ] **Step 1: Write the failing tests**

```swift
func testWhatAProfileSentOfAMeeting() {
    // written and failed: .all. transcribed, identified, summarized: .inWork.
    // recorded with nothing: .nothing. recorded with hasLiveFile: .live. recorded with a usage row (callID of the call, purpose .live): .live;
    // the same row for another call: .nothing. recorded with transcriptionJobs ["me": "j1"], or meUtterances [], or attempts 1, or a
    // usage row of purpose .transcription: .inWork.
}
func testTheOffer() {
    // recording: .hidden. notes-only and written: .refused(MoveWords.notesOnly). written and busy: .refused(MoveWords.inWork).
    // written with files ["call.json", "merge.json"]: .refused(inWork). platform .unknown: .refused(inWork).
    // written with MoveOut(to: "1a2b3c4d") in .waiting: .moving(to: "1a2b3c4d"); in .done: .offer.
    // recorded with moveTo "1a2b3c4d" and no ledger: .moving(to: "1a2b3c4d").
    // written, failed, recorded with nothing sent, recorded with only the live transcript: .offer.
}
func testTheTargetsAreTheOtherLiveProfiles() {
    // default, Work (1a2b3c4d), Old (5e6f7a8b, removing). active default: [Work]. active 1a2b3c4d: [default]. One profile: [].
}
func testWhoMayMove() {
    // true: .full, the real Mac app with a registry in state .read. false: .inert, .worker, the states .none, .newer, .unreadable, .partial,
    // a made-up registry, Rehearsal, a preview, a MOSSAD_ROOT run.
}
func testTheTargetsFolder() throws {
    // a live profile whose folder exists: its Paths. removing: nil. An id that is not there: nil. A folder that is not there: nil. State .newer: nil.
}
func testTheWords()   // each string above, exactly
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveRulesTests`. Expected: the build fails with "cannot find 'MoveRules' in scope".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "One rule says which meeting may move and to which profile, and the words of a move are in one place"`

---

### Task 4: The first profile copies, and leaves a marked call alone

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveCopy.swift`
- Modify: `.../Records/ProcessingQueue.swift:36-40` (`pending`); `.../Pipeline/Pipeline.swift` (`processSteps` after the load at `:165`, `regenerateSummary` `:236`, `transcribeAgain` `:295`, `restorePreviousTranscript` `:336`, `attachNotes` `:567`, `remove` `:602`, `applyNames` `:1029`, `merge` `:1127`; two new functions); `.../Cloud/CloudArchive.swift` (one function after `playbackURL`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveCopyTests.swift` (new)

**Interfaces:**
- Consumes: `MoveMarker`, `MovedRecord`, `MovedFiles`, `FileHash.sha256(of:)`, `ChatStore`, `OwnerIdentity`, `CloudArchive.place(of:)`, the backend's `download(_:session:)`, `FakeArchive` of `ArchiveMoveTests`, `writtenCall`.
- Produces:

```swift
public enum MoveCopy {
    public struct Source: Equatable, Sendable { public var from: URL; public var path: String }   // path under Incoming/<id>: "call/me.caf"
    public struct Plan: Equatable, Sendable {
        public var to: String                               // the target's profile id
        public var record: CallRecord                       // prepared
        public var ownerKeys: [String]
        public var files: [Source]
        public var chats: [Chat]                            // prepared
        public var bytes: Int64
    }
    /// `fetched`: the recording from the backup, when this Mac has no audio of the call.
    public static func plan(_ callID: String, in paths: Paths, to target: String, owner: OwnerIdentity, fetched: URL?) throws -> Plan
    public static func needsFetch(_ r: CallRecord, in dir: URL) -> Bool
    public typealias FileCopy = @Sendable (URL, URL, @Sendable (Int64) -> Void) throws -> (size: Int64, sha256: String)
    public static let file: FileCopy                        // chunks of 1 MB; the hash of what was read
    public static func room(for bytes: Int64, at folder: URL) -> Bool?       // nil: not known
    /// Makes Incoming/<id>.part whole, checks each file, and writes move.json into it last. On any failure it removes the part and throws.
    public static func write(_ plan: Plan, from: String, incoming: URL, now: Date, copy: FileCopy = file,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> MoveMarker
    public static func publish(_ callID: String, incoming: URL) throws       // rename <id>.part to <id>
    public struct NotTheSame: Error {}
}
// CloudArchive
/// The archived recording of a record as a file in `folder`, checked: the size the record names, and its SHA-256 when the record has one.
/// Nil when the place is not set up here, does not answer, or gave another file. The caller removes the file.
public func fetch(_ r: CallRecord, into folder: URL) async -> URL?
// Pipeline
public func isBusy(_ id: String) -> Bool                                  // in flight
/// Marks a meeting as leaving for a profile, or takes the mark off (nil). False for a call in flight, a call that records,
/// a record that cannot be read, or one already marked for another profile.
@discardableResult public func setMoveTarget(callID: String, _ profile: String?) -> Bool
```

`needsFetch`: the folder has no `recording.m4a`, no `me.caf`, and no `them.caf`, and the record has a `cloudKey`. `write` checks: for a file that goes as it is, the size and the SHA-256 of the copy (read again from the copy) equal the source's; for `call.json` and each chat, the written file decodes to the value that was written. A difference throws `NotTheSame`.

The guards. `ProcessingQueue.pending` leaves out a record with `moveTo`. `Pipeline.processSteps` returns right after its load when `r.moveTo != nil`. `regenerateSummary`, `transcribeAgain`, `restorePreviousTranscript`, `attachNotes`, `remove(callID:keepNotes:)`, `applyNames`, and `merge` (for any of its ids) do nothing for a record with `moveTo`.

- [ ] **Step 1: Write the failing tests**

```swift
func testACopyIsWholeAndChecked() throws {
    // A and B are temp Paths. writtenCall(in: A). plan, write, publish:
    // B/Incoming/20261101-100000/move.json decodes; its paths are exactly "call/call.json", "call/frames.json", "call/frames/000012000.heic",
    // "call/me.caf", "call/recording.m4a", "call/them.caf", "chats/<the chat's id>.json"; each file has the listed size and FileHash.sha256;
    // the hash of call/recording.m4a equals A's. ownerKeys is ["me:A"]. B holds nothing but the Incoming folder.
    // Under B there is no call.previous.json, coach.json, findings.json, live.json, or live-points.json.
    // call/call.json equals MovedRecord.prepared(A's record, to: "1a2b3c4d"). A's folder is byte for byte as before.
}
func testAHalfCopyIsNeverPublished() throws {
    // A `copy` that throws at its third file: write throws; B/Incoming has no entry.
    // A `copy` that writes one byte less into the copy and reports the source's hash: write throws NotTheSame; no entry.
    // A part left by hand with every file and no move.json: MoveMarker.look(part) is .missing.
}
func testAFullDiskLeavesNoPart() throws      // a `copy` that throws CocoaError(.fileWriteOutOfSpace): write throws it; no entry in B/Incoming
func testARecordingOnlyInTheBackupIsFetchedAndChecked() async throws {
    // A record with cloudKey, cloudSize 2048, cloudHash, and no audio on this Mac: needsFetch is true; with me.caf there: false.
    // CloudArchive with a FakeArchive that holds that object: fetch gives a file of 2048 bytes with that hash, and plan(fetched:) lists
    // "call/recording.m4a" from it; A's folder still has no recording.m4a.
    // The fake holds another size: fetch is nil. The fake does not answer: nil. No place set up for the record's kind: nil.
}
func testAMarkedCallIsNeverProcessedHere() async throws {
    // A recorded call with moveTo "1a2b3c4d": ProcessingQueue.pending(now:) does not hold it. After process, retry, and runPending the
    // record is .recorded and the FakeTranscriber has 0 calls.
    // A written call with moveTo: regenerateSummary, transcribeAgain, applyNames(names: ["them:B": "Mira Stone"]), merge with another
    // meeting, delete, and attachNotes change nothing on disk, and the FakeSummarizer has 0 calls.
}
func testAMarkIsRefusedForACallInWork() async throws {
    // During a run that waits in its transcriber: setMoveTarget is false and isBusy is true. For a .recording record: false.
    // A written record: true, and call.json has moveTo. A second profile while marked: false. nil: true, and the key is gone.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveCopyTests`. Expected: the build fails with "cannot find 'MoveCopy' in scope".
- [ ] **Step 3: Write the code.** `setMoveTarget` goes through the pipeline's `edit` and `store`. Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A meeting is copied into the target's Incoming folder under a part name, checked file by file, and a marked call is never processed here"`

**From the review (group R4).** What the code of this task must do that the pure rules cannot:
- Publish with `rename(2)`, not `FileManager.moveItem` (it tests the target first and replaces an empty folder). On `EXDEV` (`Incoming` on another volume) refuse the move: nothing changes.
- The part has the move's token in its name, `Incoming/<id>.<token>.part`, so two moves of one id never share a part. `MovePlan.source` gets `part: true` only for this move's own part, whole, with its marker.
- The copy is three steps: every file, then `move.json` last (with `MoveOut.token`), then the ledger `copied`. `F_FULLFSYNC` each copied file, `move.json`, and the part folder before the publish. Read each copy's hash back from the disk after the sync, not from memory.
- `MovedFiles.list` throws on a folder or a file that does not read: the move is refused. `MovedFiles.unknown` names refuse it with `MoveWords.unknownFile`.
- The chats: `MovedChats.split`. Only `moved` go. `deleted` are counted in the confirmation (`MoveWords.chatsDeleted`) and are deleted in this profile at the `books` step.
- One advance for each id at a time in a process (the timer, the launch, the housekeeping).

---

### Task 5: The names of the voices in the target

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MovedVoices.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MovedVoicesTests.swift` (new)

**Interfaces:**
- Consumes: `VoiceLibrary` (`ranked`, `owner`, `provisional`, `matchThreshold`, `existingName(name:email:)`, `name(forEmail:)`, `add(_:to:isOwner:source:)`, `identity`), `InviteVoiceRules.decide`, `InviteVoiceRules.Voice`, `InviteVoiceRules.inferenceSpeech`, `InviteRoster`, `CallInvite(record:sure:)`, `SpeakerIdentifier.learnThreshold`, `VoiceSampleSource`, `VoiceSample.Origin`, `OwnerIdentity`, `CallRecord.replaceSpeakerLabels`, `MarkdownWriter.displayNames`.
- Produces:

```swift
public enum MovedVoices {
    public enum Learn: Equatable, Sendable { case none, autoMatch(Float), ownerNamed, inviteInference }
    public struct Naming: Equatable, Sendable {
        public var names: [String: String]          // speaker key to the name in this profile
        public var learn: [String: Learn]
        public var unknown: [String]
        public var fromInvite: [String]
        public var renamed: [String: String]        // what the summary says now ("Speaker B", "Sam Carter") to the new name
        public var changed: Bool { get }            // renamed is not empty
    }
    /// Reads the library and changes nothing. `record` is the record as the first profile wrote it.
    public static func decide(_ record: CallRecord, ownerKeys: Set<String>, library: VoiceLibrary, ownerName: String, fingerprints: Bool = true) -> Naming
    /// Puts the names into the record, swaps the changed names in the summary's words, and teaches the library. `callID` is the id here.
    public static func apply(_ naming: Naming, to record: inout CallRecord, callID: String, library: VoiceLibrary) throws
}
```

`decide`, in this order:

1. A key in `ownerKeys` gets `ownerName`. It learns `.autoMatch(score)` only when this library has an owner voice and the key's fingerprint is that voice at 0.8 or more; else `.none`. The library's owner is never made here.
2. Every other key with a fingerprint goes through `InviteVoiceRules.decide` with `Voice(key:scores: library.ranked(fingerprint), fingerprint: true, seconds:)`, the roster `InviteRoster(invite: CallInvite(record: record, sure: false), profiles: library.profiles, people: library.identity?.people.people ?? [])` (nil with no invite), `owner: library.owner?.name`, `provisional: library.provisional`, `matchThreshold: library.matchThreshold`, `learnThreshold: SpeakerIdentifier.learnThreshold`. `.named(name, score, learn)` gives the name, with `.autoMatch(score)` when `learn`. A voice named as the library's owner gets `ownerName`.
3. A key that step 2 did not name and that has a name in the record keeps it. The name is `library.existingName(name: was, email: nil) ?? was`. A name with "@" is `library.name(forEmail: was)`, and with none the key has no name. A name that is one of the owner's (`OwnerIdentity(name: ownerName, also: [library.owner?.name])`) on a key that is not in `ownerKeys` gives no name. It learns `.ownerNamed`; a key in the record's `fromInvite` learns `.inviteInference` with 20 s or more of clear speech, else `.none`, and stays in `fromInvite`. Of two keys that keep one name, only the one with more seconds learns. A kept name that step 2 gave to another key learns `.none`. A key with no fingerprint learns `.none`.
4. `unknown` is the record's `unknownSpeakers` without the keys that have a name now.
5. `renamed`: for each key whose name differs from `MarkdownWriter.displayNames(record)[key]`, that old text to the new name.

With `fingerprints` false: steps 1 and 3 only, and every `learn` is `.none`.

`apply`: `speakerNames`, `unknownSpeakers`, `fromInvite`, then `replaceSpeakerLabels(renamed)`, then for each `learn` that is not `.none` `library.add(fingerprint, to: name, source: VoiceSampleSource(callID: callID, speakerKey: key, recorded: record.start, seconds:, quality:, origin:))`. No line of the transcript changes.

- [ ] **Step 1: Write the failing tests.** Each uses a temp `VoiceLibrary` with its `VoiceIdentity`, and fingerprints of 8 numbers made so that the cosine is the number in the comment.

```swift
func testAVoiceTheTargetKnowsGetsTheTargetsName()
    // The library has "Samuel Carter" with the fingerprint of them:A (cosine 1.0); the record says "Sam Carter":
    // names["them:A"] is "Samuel Carter", learn .autoMatch(1.0), renamed ["Sam Carter": "Samuel Carter"].
func testAVoiceItDoesNotKnowKeepsItsNameAndIsLearnedAsTheOwnersNaming() throws
    // A library with only the owner: "Sam Carter", learn .ownerNamed, renamed has no "Sam Carter". After apply(callID: "20261101-100000-moved"):
    // the library has "Sam Carter" with that fingerprint; samples.json has one sample of them with callID "20261101-100000-moved",
    // speakerKey "them:A", origin .ownerNamed; people.json has a live "Sam Carter" with origin .voiceNaming; library.provisional is empty.
func testAWholeSavedNameJoinsThatPersonAndAGuessJoinsNobody()
    // The library has "Sam Carter" with another voice (cosine 0.2). The record says "Carter, Sam": the name is "Sam Carter", learn .ownerNamed.
    // The record says "Sam": the name is "Sam" (a new voice), learn .ownerNamed.
func testANameFromTheInviteStaysProvisional() throws
    // "them:A" is in fromInvite with 25 s: learn .inviteInference; after apply library.provisional["Sam Carter"] is the call id, and the
    // record's fromInvite is ["them:A"]. With 12 s: learn .none and the name stays.
func testTheOwner() throws
    // No owner voice here, ownerKeys ["me:A"], ownerName "Avery Webb": names["me:A"] "Avery Webb", learn .none; after apply library.owner is nil.
    // An owner voice that me:A is (cosine 0.9): learn .autoMatch(0.9). An owner voice that me:A is not (0.1): still "Avery Webb", learn .none.
    // The first profile called the owner "A. Webb": renamed ["A. Webb": "Avery Webb"].
    // "them:C" is not in ownerKeys and the record names it "Avery Webb": it has no name and is in unknown.
func testTwoVoicesWithOneName()
    // them:A (30 s) and them:C (12 s) are both "Sam Carter" and the library knows neither: both keep the name; learn[them:A] .ownerNamed,
    // learn[them:C] .none. With them:A named "Sam Carter" by the library (0.9) and them:C kept: learn[them:C] .none.
func testANameThatIsAnAddress()
    // The record says "sam@example.com". The library has "Sam Carter" with that address: "Sam Carter". No such person: no name, and
    // apply makes no person and no voice.
func testAVoiceWithNoNameStaysALetter()
    // them:B has no name and matches nobody: no entry in names; in unknown as before. A skipped voice (no name, not in unknownSpeakers) stays skipped.
func testTheThresholdsOfIdentify()
    // A saved voice that the record's invite does not name: 0.79 gives no name; 0.85 with the next voice at 0.80 gives none; 0.85 with
    // the next at 0.70 gives the name with learn .none. A saved voice whose address is in the record's invitees: 0.66 gives the name with
    // learn .none; 0.81 gives learn .autoMatch(0.81). 0.64 gives none. A provisional voice of this library gives none.
func testNoLineOfTheTranscriptChanges() throws        // utterances, meUtterances, themUtterances, markers after apply equal before
func testAChangedNameChangesTheWordsOfTheSummary() throws
    // them:B gets "Mira Stone" from the library: the summary and the action item's owner say "Mira Stone" in place of "Speaker B".
    // them:A becomes "Samuel Carter": the summary says "Samuel Carter". changed is true. With no name changed: changed false, summary equal.
func testWithFingerprintsOffNothingIsComparedOrLearned() // the kept names and the owner's keys; every learn .none; the library is not read for ranks
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MovedVoicesTests`. Expected: the build fails with "cannot find 'MovedVoices' in scope".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A moved meeting's voices are named again from the fingerprints its record keeps, by the rules of a call's own naming"`

---

### Task 6: The target takes the folder in

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveIntake.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveIntakeTests.swift` (new)

**Interfaces:**
- Consumes: `MoveMarker`, `MovePlan.target`, `MovePlan.decide`, `MoveOut.leftIDs`, `MoveOut.load`, `MovedVoices`, `MovedRecord.arrival`, `ChatStore`, `MoveCopy` (in the tests).
- Produces:

```swift
public struct MoveIntake: Sendable {
    public init(paths: Paths, library: VoiceLibrary, ownerName: @escaping @Sendable () -> String, voiceFingerprints: @escaping @Sendable () -> Bool)
    public static func hasWork(_ paths: Paths) -> Bool     // Incoming has a folder with move.json, or a claimed.json that is not taken or refused
    public func waiting() -> [String]                      // those folders' names
    /// Does the one step that `MovePlan.target` names for this folder, and returns it.
    public func step(_ callID: String) -> MovePlan.TargetStep
    /// Each waiting folder to its end. Returns the ids the meetings have here.
    public func run() -> [String]
}
```

What each step does, as one durable change:

- `wait` also when fingerprints are on and `library.identity` is nil: the people store is not in step yet.
- `claim`: `MoveMarker.claim`.
- `decide`: reads `call/call.json`; `sizesMatch` is true when every file of the marker is there with its size (the first profile checked the hashes after its copy); saves `claimed.json` with `intake`, `finalID`, `refusal`, and for `takingIn` a new UUID in `chatIDs` for each chat of the marker.
- `takeIn(as:)`, while `call/call.json` still has a `moveTo` (it has not arrived): `MovedVoices.decide` and `apply` on the record of `call/call.json`; then `id` is the final id, `status` is `MovedRecord.arrival`, and `moveTo` is nil. Each chat is saved in `Chats` under its id of `chatIDs`, with `callID` the final id and each `mossad://call/<the marker's id>` in a message's text as `mossad://call/<the final id>`. Last, the record is written as `call/arrival.json` and takes the place of `call.json` in one rename. A record at `recorded` or `transcribed` gets no naming: its pipeline here names the voices from the audio.
- `takeIn(as:)`, when `call/call.json` has no `moveTo` (it arrived): one rename of `Incoming/<id>/call` to `Audio/<final id>`.
- `markTaken`: saves `intake` `taken`.
- `refuse`: saves `intake` `refused` with the reason.

So `takeIn` takes two calls of `step`, and a stop between them, or in the middle of the first, is finished by the next run: the names are decided again from the untouched `call.json`, a fingerprint that the library has is not added twice, and the chats are written again under the same ids.

- [ ] **Step 1: Write the failing tests.** `arrive()` is a helper: `writtenCall(in: A)`, then `MoveCopy.plan`, `write`, `publish` into `B/Incoming`.

```swift
func testATakenMeetingIsWholeInAudio() throws {
    // arrive(); intake.run() is ["20261101-100000"]. B/Audio/20261101-100000 holds call.json, me.caf, them.caf, recording.m4a, frames.json,
    // frames/000012000.heic, and nothing else; the audio hashes equal A's. B/Incoming/20261101-100000 holds only claimed.json, with
    // intake "taken" and that finalID. The record: its id, status .summarized (no name changed), markdownPath nil, speakerPeople nil, moveTo nil.
    // B/Chats has one chat: a new id, callID the meeting's, no actions, the same text.
}
func testTheIDThatIsTakenGetsMoved() throws {
    // B has Audio/20261101-100000 already: run() is ["20261101-100000-moved"]; the record's id and the chat's callID are that; the chat's
    // answer says "mossad://call/20261101-100000-moved?t=724"; the meeting that was there is untouched.
    // B has Moves/20261101-100000.json in .done and no such folder: the same final id.
    // Both names taken: claimed.json has intake "refused" and refusal "idTaken"; Incoming/20261101-100000/call is as it arrived; B/Audio and
    // B/Chats did not change; run() is [].
}
func testARecordThisBuildCannotReadIsRefused() throws {
    // call/call.json with "platform": "holo": refused, "unreadable". A call.json that does not decode: the same.
    // call/recording.m4a one byte shorter than the marker says: refused, "notWhole".
}
func testAStopAtAnyStepOfTheIntakeIsFinishedByTheNextRun() throws {
    // For n in 1...6: fresh folders, arrive(), n calls of step() on one MoveIntake, then a new MoveIntake and run().
    // Each time: B/Audio has one folder of the meeting; the record equals the record of the first test; B/Chats has one chat of the call;
    // the library has "Sam Carter" once with one fingerprint; samples.json has one sample of the call for them; claimed.json says taken.
}
func testTheNewSummaryIsTheTargetsOwnStep() async throws {
    // B's library knows them:A as "Samuel Carter". After run(): the record is .identified and B's FakeSummarizer has 0 calls.
    // After B's Pipeline(paths: B, ...).runPending(): 1 call; the record is .written; the note is in B/Meetings and its audio line
    // names B's folder. A's FakeSummarizer has 0 calls. No file under A changed.
}
func testARecordedMeetingArrivesForTheTargetsOwnPipeline() async throws
    // A recorded call: after run() it is .recorded in B/Audio with no name; after B's runPending it is .written and B's FakeTranscriber was called.
func testTheIntakeWaits() throws {
    // library.identity nil: step is .wait and nothing under B changed.
    // B has Moves/20261101-100000.json in .removing: step for that id is .wait; a second folder with another id is taken in.
}
func testAPartOrAFolderWithNoMarkerIsNeverTakenIn() throws
    // Incoming/x.part with everything, Incoming/y with no move.json, Incoming/z with cancelled.json: hasWork false, waiting() [], run() [].
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveIntakeTests`. Expected: the build fails with "cannot find 'MoveIntake' in scope".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "The target claims a moved meeting with one rename, names its voices, and moves the folder into its Audio in steps that a stop cannot break"`

**From the review (group R4).** What the code of this task must do that the pure rules cannot:
- Claim only a marker addressed to this profile for the folder's id (`MovePlan.target(_:folder:me:...)`), and wait while `MovePlan.ownRemoval` of this profile's own ledger of that id is true.
- The take-in is two halves: first `arrival.json`, the voices (`MovedVoices.decide(..., fingerprints:, callID: <final id>)`), the people, and the chats; then one `rename(2)` of the call folder into `Audio/<final id>`. On `EXDEV` refuse. A refusal after the first half first undoes this profile's own half (the samples learned with the final id, the people it made, the chats it wrote), then writes `refused`.
- `(true, true)` gives `.decide`: decide the id again and write `arrival.json` again with the new id.
- Before `taken`: read every file of `Audio/<final id>` and the chats back from the disk, compare them with `marker.files` (`MovePlan.held`), `F_FULLFSYNC` the files and the folder, and write `taken` with `count` (the files checked). `claimed.json` keeps the first profile's `token`. With `held` nil the target waits; with false it refuses `notWhole`.
- With "voice fingerprints" off, `MovedVoices.apply` clears them from the record.

---

### Task 7: The books forget a call for good

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Commitments/Commitment.swift` (one function after `delete`, `:98-100`); `.../Series/NextTime.swift` (`NextTimeBook`: one field, its key, `forget`, and `merged` at `:283-305`); `.../Coach/CoachProfile.swift` (one field, two functions after `forget(callID:)` at `:439`, and `merged` near `:296-338`); `.../People/ReferenceBackup.swift` (one function)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveBooksTests.swift` (new)

**Interfaces:**
- Produces:

```swift
// CommitmentBook
/// The tasks of a meeting that left this profile: each becomes a deleted marker with no word of the meeting. Returns how many.
@discardableResult public mutating func forget(callID: String, at date: Date = Date()) -> Int
// NextTimeBook
/// Calls that left this profile: no point names one, and a merge with an older copy does not bring one back. Nil when there are none.
public var movedCalls: [String]?
@discardableResult public mutating func forget(callID: String, at date: Date = Date()) -> Bool
// CoachProfile
public var movedCalls: [String]?
public mutating func forgetMoved(callID: String, at date: Date = Date())
public mutating func forget(person id: String, name: String, at date: Date = Date())
// ReferenceBackup
public static func forget(note path: String, paths: Paths)
```

`CommitmentBook.forget`: each item with that `callID` gets `deleted` true, `text` "", and `to`, `toID`, `callTitle`, `quote`, `at`, `due` nil, with `updated` the date. `checked` stays (the id never comes back, see "Choices").

`NextTimeBook.forget`: `reopen(doneIn:)`; the id goes out of each point's `carried`, `reopened`, and `mentions` (an empty list becomes nil, and a changed point gets `updated`); out of `checked`; into `movedCalls`. `merged`: `movedCalls` is the union of both; then the same cleaning runs over the joined points and `checked` for every id in it. The key is written only when the list is not nil; `version` stays 1.

`CoachProfile.forgetMoved`: `forget(callID:)`, and `rated`, `questions` (any status), and `answers` of that call go; the id goes into `movedCalls`. `merged`: `movedCalls` is the union, and no `rated`, `questions`, `answers`, `observations`, `history`, or `advice` of such a call is in the result. `forget(person:name:)`: `people[name]` and each entry of `people` whose `person` is the id go; each fact and guidance whose `person` is the id goes, and its lowercased text gets the date in `forgotten`, so a merge does not bring it back.

- [ ] **Step 1: Write the failing tests**

```swift
func testACommitmentOfTheCallKeepsNoWord() throws {
    // Two items of call X ("Send the zebra budget", to "Sam Carter", callTitle "Zebra budget", a quote) and one of call Y.
    // forget(callID: "X", at: d) is 2: both are deleted, text "", to, toID, callTitle, quote, at, due nil, updated d. Y's is equal.
    // book.merged(with: before) and before.merged(with: book): X's two are the empty markers. The JSON has no "zebra" and no "Sam Carter".
}
func testAPointTheCallClosedIsOpenAndNoPointNamesTheCall() throws {
    // p1 done in X with a quote; p2 carried ["W", "X"]; p3 mentions of X and Y; p4 reopened ["X"]; checked ["X", "Y"].
    // After forget(callID: "X"): p1.isOpen; p2.carried ["W"]; p3.mentions has only Y; p4.reopened nil; checked ["Y"]; movedCalls ["X"].
    // In the JSON, "X" is only in movedCalls.
}
func testAForgottenCallDoesNotComeBackInAMerge() throws {
    // The points: after.merged(with: before) and before.merged(with: after) both equal `after` in points, checked, and movedCalls.
    // The coach: a rated point of X (callTitle "Zebra budget"), a confirmed question of X, an answer of X with the verdict .never, an
    // observation, a history entry, and the same of Y. After forgetMoved(callID: "X"): nothing of X; movedCalls ["X"]; Y's are equal.
    // after.merged(with: before, ...) for each side that coaches: nothing of X.
}
func testABookWithNoMovedCallIsSavedAsToday() throws
    // A NextTimeBook and a CoachProfile with no forget: their JSON has no "movedCalls", and decodes of files with no such key read nil.
func testTheCoachForgetsAPerson() throws {
    // people["Sam Carter"], a fact and a guidance with person "p1", and the same for "p2".
    // After forget(person: "p1", name: "Sam Carter", at: d): none of p1; forgotten has both lowercased texts with d; p2's are equal.
    // merged(with: before) has none of p1.
}
func testTheReferenceBackupOfANoteGoes() throws
    // ReferenceBackup.keep(note: path, paths:) then forget(note: path, paths:): Backups/people-references/notes has no such file.
    // forget of a note with no copy does nothing.
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveBooksTests`. Expected: the build fails with "value of type 'CommitmentBook' has no member 'forget'".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures (the merge tests of today pass unchanged).
- [ ] **Step 4: Commit.** `git commit -m "The tasks, the points, and the coach's memory can forget a call for good, so that a sync does not bring its words back"`

---

### Task 8: The first profile's removal

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveRemoval.swift`
- Modify: `.../Pipeline/Pipeline.swift` (one function after `remove(callID:keepNotes:)`, `:602-616`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveRemovalTests.swift` (new)

**Interfaces:**
- Consumes: Task 7; `MoveOut.Step`; `VoiceLibrary.forget(callID:speakerKey:from:voice:)`, `VoiceLibrary.delete(_:)`, `VoiceIdentity` (`people`, `samples`), `PeopleStore.delete(_:)`, `OwnerIdentity.read(name:paths:)`, `CoachRunner.forget(_:paths:)`, `PersonaStore.forget(callID:)`, `ChatStore.deleteChats(forCall:)`, `NextTimeBook.change(in:_:)`, `CommitmentBook.load`/`save`, `RemovedNotes.add(_:paths:)`, `ReferenceBackup.forget(callID:paths:)`.
- Produces:

```swift
// Pipeline
/// Removes a meeting that the target has taken in: the note, its two reference backups, and the call folder. Only a record
/// marked with `moveTo` that is not in flight; any status. Returns the record as it was.
public func removeMoved(callID: String) -> CallRecord?

public enum MoveRemoval {
    public struct Actions: Sendable {
        public var forgetPersona: @Sendable (String) -> Void                                   // by person id, as the People page's delete
        public var coach: @Sendable (@Sendable (inout CoachProfile) -> Void) throws -> Void    // through the one writer of the coach's memory
        public var stopShares: @Sendable (String) -> Void
        public var backup: @Sendable (CallRecord) async -> Void
        public var removeFolder: @Sendable (String) async -> Bool
        public init(forgetPersona:, coach:, stopShares:, backup:, removeFolder:)
    }
    /// One step. True when it ended, also when the call folder is gone already. False stops the removal until the next run.
    public static func run(_ step: MoveOut.Step, callID: String, paths: Paths, library: VoiceLibrary, ownerName: String,
                           actions: Actions, now: Date) async -> Bool
    /// The people whom only this meeting made. Asked after the `voices` step.
    public static func peopleToRemove(_ r: CallRecord, people: [Person], samples: [VoiceSample], others: [CallRecord]) -> [Person]
}
```

`run`, by step, as the table in "The move on one page". `voices`: for each key of the record with a name and a fingerprint, `library.forget(callID:speakerKey:from:voice:)`; for a key of the owner (`OwnerIdentity.read(name: ownerName, paths:).speakerKeys(in:)`) the name is `library.owner?.name`. A throw returns false. `people`: for each of `peopleToRemove`, `actions.forgetPersona(id)`, then `library.delete(displayName)`, then `people.delete(id)` when the person is still live (a person with no voice left), then `actions.coach { $0.forget(person:name:at:) }`. `coach`: `actions.coach { $0.forgetMoved(callID:at:) }`, `CoachRunner.forget`, `PersonaStore(paths:).forget(callID:)`. `books`: the three calls. `shares`, `backup`, `folder`: the action. `notes`: `RemovedNotes.add`.

`peopleToRemove`: a person is in the list when all of these hold: they are a voice of `r` (their id is a value of `speakerPeople`, or their `displayName` is a value of `speakerNames`); `isLive`; not `isOwner`; `created >= r.start`; `origin` is not `.orgChart`, `.googleDirectory`, `.googleContacts`, or `.migration`; no sample in `samples` has their id; and in no record of `others` are they a voice (by id or by name) or an invitee with their id.

- [ ] **Step 1: Write the failing tests**

```swift
func testTheOrderOfTheRemoval() {
    XCTAssertEqual(MoveOut.Step.allCases, [.voices, .people, .coach, .books, .shares, .backup, .notes, .folder])
}
func testEveryVoiceSampleOfTheCallIsForgotten() async throws {
    // "Sam Carter" has two samples: one of this call (them:A) and one of call Y. The owner has one of this call (me:A) and two others.
    // After .voices: "Sam Carter" has one fingerprint (Y's); the owner has two; samples.json has no sample with this call's id.
    // Run again: nothing changes, and the step is true.
}
func testTheRuleOfThePersonWhoGoes() {
    // Sam Carter: made after the call's start, origin .voiceNaming, no sample, no other meeting: in the list.
    // Mira Stone: the same, and a voice of meeting Y: not. Lee Park: the same, and an invitee of Y with his id: not.
    // Ana Ruiz: made a day before the call: not. Kim Dale: origin .googleDirectory: not. Noa Berg: one sample of meeting Y left: not.
    // The owner: not. A person who is not a voice of the meeting: not.
}
func testAPersonOnlyThatCallMadeIsDeletedAndOneWithAnotherMeetingStays() async throws {
    // After .voices and .people: the library has no "Sam Carter"; in people.json the record of his id has `deleted` set and no name;
    // forgetPersona got his id; the coach action removed people["Sam Carter"] and the fact about him.
    // Mira Stone is live with her voice profile. Run .people again: nothing changes.
}
func testARecordedMeetingIsRemovedToo() async throws {
    // removeMoved of a .recorded record with moveTo: the folder is gone and the record comes back.
    // A record with no moveTo: nil, and the folder stays. A call in flight: nil.
}
func testNoBookOfTheFirstProfileHasAWordOfTheCallAfterTheRemoval() async throws {
    // writtenCall(in: A) with: a commitment of the call, a point done in it with the quote "the zebra crossing is closed", a point with a
    // mention of it, a coach history entry and a rated point of it, persona evidence, a reference backup of its record and of its note,
    // two usage rows, and "Sam Carter" as a person whom this call made. moveTo is set. Run the eight steps.
    // No file under A has "Zebra budget", "zebra crossing", or "Sam Carter", except People/people-log.jsonl.
    // "Weekly sync" is only in Google/removed-notes.json. The call's id is only in Usage/usage.jsonl, Commitments/commitments.json,
    // NextTime/next-time.json, and Coach/profile.json. A has no folder in Audio, no note, no chat of the call.
}
func testTheUsageLogKeepsTheCallsRows() async throws        // the two rows of the call are there after the removal, equal
func testTheGeminiNotesOfAMovedMeetingAreNotImportedAgain() async throws
    // A record with gemini (docID "d1", eventID "e1"): after .notes, RemovedNotes.load(A).ids holds "d1" and "e1", and one mark covers the meeting's event.
func testAStepOfAFolderThatIsGoneIsDone() async throws      // with no call folder each of the eight steps returns true and changes nothing
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveRemovalTests`. Expected: the build fails with "cannot find 'MoveRemoval' in scope".
- [ ] **Step 3: Write the code.** `removeMoved` removes the note (`markdownPath`), `ReferenceBackup.forget(callID:)`, `ReferenceBackup.forget(note:)`, the folder, and calls `heavy.forget`. Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A meeting that moved away is removed in eight steps that each can run twice, with its voices, the person it made, and every word the books kept"`

**From the review (group R4).** What the code of this task must do that the pure rules cannot:
- The `folder` step renames the call folder out of `Audio` first (into `Moves/`), then deletes it. A half folder with no `call.json` counts as done.
- The `coach` step uses `CoachProfile.forgetMoved(callID:)`, which also drops what the call's answers and questions made; the person who goes uses `CoachProfile.forget(person:name:)`, which writes the id into `movedPeople` and no words into `forgotten`.
- The `books` step also deletes the chats that `MovedChats.split` did not move.
- A damaged local book (set aside, empty) loses the forget: at each launch, run the books' forget again for each `done` ledger (each forget can run twice). See `testADamagedLocalBookHasNoListToCleanWith`.
- One advance for each id at a time.

---

### Task 9: The first profile's half, and both halves end to end

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveSource.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveEndToEndTests.swift` (new)

**Interfaces:**
- Consumes: Tasks 1 to 8.
- Produces:

```swift
public struct MoveSource: Sendable {
    public struct Setup: Sendable {
        public var paths: Paths
        public var profileID: String
        public var pipeline: Pipeline
        public var library: VoiceLibrary
        public var ownerName: @Sendable () -> String
        public var target: @Sendable (String) -> Paths?                 // MoveRules.targetPaths with the registry as it is now
        public var fetch: @Sendable (CallRecord, URL) async -> URL?     // CloudArchive.fetch; nil with no backup set up
        public var room: @Sendable (Int64, URL) -> Bool? = MoveCopy.room
        public var copy: MoveCopy.FileCopy = MoveCopy.file
        public var usage: @Sendable (String) -> [UsageEvent]
        public var actions: MoveRemoval.Actions
        public var progress: @Sendable (String, Double) -> Void = { _, _ in }
        public var now: @Sendable () -> Date = Date.init
    }
    public enum Start: Equatable, Sendable { case started, refused(String) }
    public enum Event: Equatable, Sendable { case working, waiting, moved(to: String), cancelled(MovePlan.Cancel) }
    public init(_ setup: Setup)
    public func start(_ callID: String, to target: String, afterCall: Bool = false) async -> Start
    public func advance(_ callID: String) async -> Event       // one step of MovePlan.source
    public func run(_ callID: String) async -> Event           // advance while it is .working
    public func runAll() async -> [String: Event]              // every move of Moves that is not done
    public func cancel(_ callID: String) async -> Bool         // false: the target has the marker
}
```

`start`: the target's folder (`setup.target`), else `.refused(MoveWords.refusal(.targetGone, …))`; `MoveRules.offer` must be `.offer`, or `.moving` to this same target with no ledger (a call marked during its recording); `pipeline.setMoveTarget`; then the ledger at `copying`. A refusal returns its sentence and changes nothing.

`advance` does the step that `MovePlan.source` names, and each is one durable change:

- `copy`: removes `<id>.part` and `Moves/<id>.download`; `MoveCopy.needsFetch` then `fetch` into `Moves/<id>.download` (nil is `cancel(.backupFailed)`); `room` false is `cancel(.noRoom)`; `MoveCopy.plan` and `write` (out of space is `.noRoom`, any other throw `.copyFailed`); the download folder is removed; the ledger says `copied`.
- `publish`: `MoveCopy.publish`.
- `wait`: a ledger at `copied` is saved as `waiting`; the event is `.waiting`.
- `remove`: a ledger at `waiting` is saved as `removing` (one call). Then one call for each step: `MoveRemoval.run` for `nextStep`, and the step joins `removed`; a false is `.waiting`. With no step left: `B/Incoming/<id>` is removed when the target is live, the ledger says `done`, and the event is `.moved(to:)`.
- `cleanUp`: removes `B/Incoming/<id>`.
- `cancel(why)`: for a marker that is `incoming`, `MoveMarker.takeBack` first, and a false is `.waiting` (the target has it now). Then the ledger says `cancelling` with `cancel` set to `why`.
- `finishCancel`: removes the download folder and, when `setup.target` still gives the target's folder, `<id>.part` and `Incoming/<id>` there (a profile that is going is not touched); `pipeline.setMoveTarget(callID, nil)`; deletes the ledger; the event is `.cancelled(why)`. The reason is the ledger's `cancel`, saved with `cancelling`, so a stop in the middle keeps it. A move with `afterCall` keeps the record's mark when the reason is not `byOwner`: the call stays unprocessed, and the next look tries the move again or holds it (Tasks 11 and 12).

`cancel`: allowed at `copying`, `copied`, and at `waiting` while the marker is `incoming` and `takeBack` succeeds.

- [ ] **Step 1: Write the failing tests.** Two temp `Paths`, A and B, each with its `VoiceLibrary`, `VoiceIdentity`, and `Pipeline` with the fakes of `PipelineTests`. `whole(P)` is true when `P/Audio` has a folder of the meeting (its id, or its id with `-moved`) whose `call.json` decodes and whose audio files have the first hashes.

```swift
func testAMeetingMovesFromAToBAndIsThenANewMeetingOfB() async throws {
    // start, run A to .waiting, B's intake.run(), run A to .moved(to: "1a2b3c4d"), B's pipeline.runPending().
    // B: the meeting is .written with its note in B/Meetings, its chat, "Sam Carter" in B's library. A: no folder, no note, no chat of
    // the call; Moves/20261101-100000.json says done; B/Incoming is empty. The audio hashes in B equal the first.
}
func testTheMeetingIsNeverInNeitherProfileAtAnyStop() async throws
func testAStopAfterAnyStepOnEitherSideEndsWithTheMeetingInExactlyOneProfile() async throws {
    // Both tests share one loop. A's steps: start, copy, publish, wait, removing, eight removal steps, the end (14 calls of advance after start).
    // B's steps: 6 calls of step(). For every i in 0...14 and j in 0...6: fresh folders; i calls of A's advance and j calls of B's step, each in
    // the order the marker allows; after every single call XCTAssertTrue(whole(A) || whole(B)).
    // Then new MoveSource and MoveIntake values (the next launch), and both run to the end:
    // whole(B); !whole(A); A has no note; A's ledger says done; B/Incoming has no entry; B/Audio has one folder of the meeting.
}
func testACancelNeverLeavesTheMeetingInBoth() async throws {
    // Before a claim: cancel is true; B/Incoming has no entry; A's record has no moveTo; A/Moves has no file; B's intake takes nothing in.
    // After B's claim: cancel is false; the move goes on and ends as in the first test.
    // A stop right after the ledger said cancelling: a new MoveSource's advance ends the cancel the same way.
}
func testTheTargetIsDeletedWhileAFolderWaits() async throws {
    // `target` gives nil while A waits and the marker is incoming: run is .cancelled(.targetGone); whole(A); no moveTo; no ledger.
    // B took the folder in, and B's whole folder is renamed away before A read the marker (so `target` gives nil): .cancelled(.targetGone); whole(A).
    // `target` still gives B's folder and only B/Incoming/<id> is gone: .cancelled(.lost); whole(A).
}
func testTheTargetRefuses() async throws
    // B has both names taken: A's run is .cancelled(.refusedIDTaken); whole(A); no moveTo; B/Incoming has no entry; B's other meetings are untouched.
func testTheSameMeetingCannotMoveTwice() async throws
    // start to B, then start to a third profile C: .refused(MoveWords.inWork); C/Incoming does not exist. After the cancel: start to C is .started.
func testAMoveBack() async throws {
    // A to B, then B to A with B's own MoveSource and A's own MoveIntake: A has "20261101-100000-moved", whole, with the first hashes;
    // B has no folder of the meeting; A's library has "Sam Carter" again, with a sample of "20261101-100000-moved" and the origin .ownerNamed.
    // A move back while A's removal is not done (A made 3 removal steps): A's intake step is .wait; after A's run ends, A takes it in.
}
func testAFailedRemovalStepStopsAndGoesOn() async throws
    // The `coach` action throws once: run is .waiting with removed ["voices", "people"]; whole(B), and A still has its folder. The next run ends at .moved.
func testAMoveOfACallMarkedDuringItsRecording() async throws
    // A recorded call with moveTo "1a2b3c4d" and no ledger: start(afterCall: true) is .started; it ends in B at .recorded, and A's
    // FakeTranscriber and FakeSummarizer have 0 calls. With `target` nil: start is .refused, and the record keeps its mark.
    // A copy that fails (.copyFailed), and a stop right after the ledger said cancelling, then a new MoveSource: the event is
    // .cancelled(.copyFailed), the record still has moveTo, and A's FakeTranscriber has 0 calls after runPending().
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveEndToEndTests`. Expected: the build fails with "cannot find 'MoveSource' in scope".
- [ ] **Step 3: Write `MoveSource.swift`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A move is whole in the first profile or in both at every stop, and ends with the meeting in exactly one"`

**From the review (group R4).** What the real-folder runs must hold:
- The four rules of `MoveModelTests` (never in neither; a removal starts only from a live target that holds this move's meeting whole; no removal of an `Incoming/<id>` that the target may take in; no take-in of an id while this profile's own move of it is not done), with the same cases: a third profile that moves a meeting with the same id, a move back, a target that goes and comes back, a registry that cannot be read, a marker with no ledger, a ledger with no marker.
- `MoveRules.target` gives three answers; `unknown` waits and never cancels.
- `finishCancel` deletes the ledger last and removes `Incoming/<id>` only when the rule says `removeIncoming` (this move's taken-back or refused marker).
- `F_FULLFSYNC` before the publish and before `taken`; one advance for each id at a time.

---

### Task 10: The worker takes in, finishes a removal, and the proofs

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveProof.swift` (`#if DEBUG`)
- Modify: `.../Worker/ProfileWorker.swift` (`Setup`: two properties with defaults, not in its `init`; `start()` at `:143-168`; `pass(_:)` at `:172-185`; `run()` at `:311-338`); `App/WorkerEntry.swift` (step 4 at `:58-63`, and the `Setup` it makes)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveWorkerTests.swift` (new)

**Interfaces:**
- Consumes: `MoveSource`, `MoveIntake`, `MoveOut.hasWork`, `MoveRules.look`, `MoveRules.targetPaths`, `RunMode.worker.runs(.takeInMoved, madeUpRegistry:)`, `AppIdentity.macWideLockFolder(home:environment:)` (the folder of the registry in use), `PhoneRecording.importAudio`.
- Produces:

```swift
// ProfileWorker.Setup (properties with defaults, so the existing init and its tests do not change)
public var target: @Sendable (String) -> Paths? = { _ in nil }
public var proofStop: String? = nil                 // DEBUG proofs: "copied" or "takingIn"
// ProfileWorker
/// The duty `takeInMoved`: goes on with this profile's own moves, then takes in what waits. True when a meeting came in or left.
func moves() async -> Bool
#if DEBUG
public func proofMove(to profile: String) async     // the one written meeting of this folder
enum MoveProof { static func makeWritten(audio: URL, paths: Paths, ownerName: String, now: Date) throws -> String }
#endif
```

The hooks, exactly:

1. `start()`: after the `.people` block and before `writeStatus()`: `if await moves() { ran.insert(.takeInMoved) }`.
2. `pass(_:)`: right after `let before = …`: `let moved = await moves()`; when true, `pass.ran.insert(.takeInMoved)`, and the queue duties run in this pass also when `.queue` was not asked.
3. `run()`: the one `Task.sleep` at the loop's end becomes sleeps of `MoveRules.look` (15 s) at most. After each, when `MoveIntake.hasWork(paths) || MoveOut.hasWork(paths)`: `if await moves() { let done = await pass([.queue]); if done.changed { pace.changed() } }`. A move that only waits costs one read of its marker at each look and writes nothing. `WorkerPace` does not change.

`moves()` returns false at once unless `runs(.takeInMoved)` and `referencesReady`. It first runs `MoveSource.runAll()` (its own removals come before any take-in), then `MoveIntake.run()`. The worker's `MoveRemoval.Actions`: `forgetPersona` deletes the files of `PersonaStore(paths:)` for the id; `coach` loads, changes, and saves `CoachProfile` as `ProfileWorker.forget` does (`:359-378`); `stopShares` is `ShareBook.markStopping(callID:)` and its save; `backup` is `archive.delete` when `runs(.backup)` and there is an archive, else `CloudArchive.rememberDeletes`; `removeFolder` is `pipeline.removeMoved`. `fetch` is the archive's `fetch` when `runs(.backup)` and there is an archive, else it gives nil. A worker goes on with a move that its profile's window app started (a copy that a switch stopped is made again), and it never starts one, except for the DEBUG proof. A look that finds nothing puts no duty into `ran`.

`App/WorkerEntry.swift`: `setup.target = { MoveRules.targetPaths($0, in: ProfileRegistry.load(from: <the registry file in use>, home: <nil on a made-up registry>), home: …) }`. In a debug build on a made-up registry: `MOSSAD_PROOF_MEETING` (in an empty folder, before the setup check) calls `MoveProof.makeWritten`; `MOSSAD_PROOF_MOVE` starts `Task { try? await Task.sleep(for: .seconds(after)); await worker.proofMove(to: id) }`; the two stop hooks fill `proofStop`. With `proofStop` "copied" the worker calls `Log.flush()` and `exit(0)` when a move's ledger says `copied`; with "takingIn", when a `claimed.json` says `takingIn`.

- [ ] **Step 1: Write the failing tests.** The file makes its own `ProfileWorker.Setup` with fakes, as `ProfileWorkerTests` does.

```swift
func testAWorkerTakesInWhatWaitsAndFinishesIt() async throws {
    // B's worker, started. arrive() into B. pass([]): ran has .takeInMoved and .queue; B's record is .written; the note is in B/Meetings;
    // WorkerStatus.peek(root: B) has inWork 0.
}
func testAWorkerWithNothingWaitingStartsNoMoveDuty() async throws
    // start() and pass([.queue, .sync]): no .takeInMoved in either; B has no Incoming and no Moves folder.
func testAWorkerFinishesTheRemovalOfItsOwnProfile() async throws
    // A's ledger is .waiting and B's marker says taken: A's worker pass([]) has .takeInMoved; A has no folder of the call; the ledger says done.
func testAWorkerRemovesBeforeItTakesIn() async throws
    // A has a ledger at .removing for X and an Incoming/X from B: after one pass A's Audio has "X-moved" and no "X".
func testOnAMadeUpRegistryAMoveStaysInTheFolders() async throws
    // madeUpRegistry true: a take-in and a removal run; the store got nothing; the fake archive got no delete (the delete is remembered in
    // Sync/backup-deletes.json); the calendar fake was not asked.
func testTheWorkerLooksEvery15Seconds() throws {
    XCTAssertEqual(MoveRules.look, 15)
    // MoveIntake.hasWork: false with no folder; false with only x.part; true with x/move.json; true with x/claimed.json at takingIn; false at taken.
}
func testAnInertCopyAndASecondCopyTakeNothingIn() {
    XCTAssertFalse(RunMode.inert.does(.takeInMoved))
    XCTAssertFalse(RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false).does(.takeInMoved))
    XCTAssertTrue(RunMode.worker.does(.takeInMoved)); XCTAssertTrue(RunMode.full.does(.takeInMoved))
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter MoveWorkerTests`. Expected: the build fails with "value of type 'ProfileWorker.Setup' has no member 'target'".
- [ ] **Step 3: Write the code in MossadCore.** Run the filter, then `swift test`. Expected: PASS, then 0 failures (`ProfileWorkerTests`, `WorkerPaceTests`, and `WorkerSourceTests` pass unchanged).
- [ ] **Step 4: `App/WorkerEntry.swift`.** Run the Mac build check. Expected: exit status 0.
- [ ] **Step 5: Proof run 1: a made-up written meeting moves from A to B end to end** (under "Proof runs")

```sh
sleep 85 & FG=$!; fg $FG false false
MOSSAD_PROOF_MEETING="$P/call.aiff" MOSSAD_PROOF_MOVE=bbbb2222 "$APP" --profile aaaa1111 --worker & WA=$!
"$APP" --profile bbbb2222 --worker & WB=$!
sleep 12; echo BEFORE; list; sums
sleep 55; echo AFTER; list; sums
grep -c '"state":"done"' "$A"/Moves/*.json; kill $WA $WB; wait $WA $WB; kill $FG
```

Expected. BEFORE: under `A/Audio/<id>/` the files `call.json`, `me.caf`, and `recording.m4a`; one note in `A/Meetings`; one chat in `A/Chats`; no file under `B/Audio`, `B/Meetings`, `B/Chats`, or `B/Incoming`; one hash. AFTER: no file under `A/Audio` or `A/Meetings`, and in `A/Chats` only `deleted.json`; `A/Moves/<id>.json`; under `B/Audio/<id>/` the files `call.json`, `me.caf`, and `recording.m4a`; one note in `B/Meetings`; one chat in `B/Chats`; no file under `B/Incoming`; the same one hash. Then `1`. Also run `grep -c "Sam Carter" "$B/Voices/voices.json"`: expected `1` (the target learned the voice that it did not know). The proof's first profile has no voice library of its own, so the removal of voices and people is pinned by the unit tests of Task 8, not here. Write the two listings into the commit's body.

- [ ] **Step 6: Proof run 4: a move back.** Right after proof run 1, with the same folders:

```sh
sleep 85 & FG=$!; fg $FG false false
MOSSAD_PROOF_MOVE=aaaa1111 MOSSAD_PROOF_MOVE_AFTER=5 "$APP" --profile bbbb2222 --worker & WB=$!
"$APP" --profile aaaa1111 --worker & WA=$!
sleep 50; list; sums; kill $WA $WB; wait $WA $WB; kill $FG
```

Expected: `A/Audio/<id>-moved/` with `call.json`, `me.caf`, and `recording.m4a`, a note in `A/Meetings`; no file under `B/Audio`; `B/Moves/<id>.json`; the same one hash as in proof run 1.

- [ ] **Step 7: Proof run 2: a stop of the first profile right after the copy.** Run the setup again.

```sh
sleep 85 & FG=$!; fg $FG false false
MOSSAD_PROOF_MEETING="$P/call.aiff" MOSSAD_PROOF_MOVE=bbbb2222 MOSSAD_PROOF_MOVE_STOP=copied "$APP" --profile aaaa1111 --worker; echo "exit $?"
list | grep -c 'Incoming/.*\.part/'; ls "$A/Audio" | wc -l
"$APP" --profile aaaa1111 --worker & WA=$!; "$APP" --profile bbbb2222 --worker & WB=$!
sleep 45; list; sums; kill $WA $WB; wait $WA $WB; kill $FG
```

Expected: `exit 0`; a count of 3 or more (the part is there, with `move.json` in it); `1` (A still has its meeting); then the AFTER listing of proof run 1 and one hash.

- [ ] **Step 8: Proof run 3: a stop of the target in the middle of taking in.** Run the setup again.

```sh
sleep 85 & FG=$!; fg $FG false false
MOSSAD_PROOF_MEETING="$P/call.aiff" MOSSAD_PROOF_MOVE=bbbb2222 MOSSAD_PROOF_MOVE_AFTER=8 "$APP" --profile aaaa1111 --worker & WA=$!
MOSSAD_PROOF_INTAKE_STOP=takingIn "$APP" --profile bbbb2222 --worker; echo "exit $?"
grep -c '"intake":"takingIn"' "$B"/Incoming/*/claimed.json; ls "$A/Audio" | wc -l; ls "$B/Audio" 2>/dev/null | wc -l
"$APP" --profile bbbb2222 --worker & WB=$!
sleep 40; list; sums; kill $WA $WB; wait $WA $WB; kill $FG
```

Expected: `exit 0` (within about 30 s); `1`; `1` (A has it); `0` (B does not yet); then the AFTER listing of proof run 1 and one hash. If a worker does not end within 60 s, end it by its pid, stop, and report. Then clean up.

- [ ] **Step 9: Commit.** `git commit -m "A worker takes in a meeting moved to its profile and finishes the removal of one that left it, and four proof runs move a made-up meeting between made-up profiles"`

---

### Task 11: "Move to" in the app

**Files:**
- Create: `App/AppController+Moves.swift`, `App/MoveViews.swift`
- Modify: `App/AppController.swift` (the `@Published` properties; `finishLaunch` after `finishRemovals()` at `:890`; `runHousekeeping` first line at `:2096`; the `didSet` of `workerLines`); `App/MeetingsView.swift:418-463` (`MeetingMenuItems`) and `:88-97` (beside the delete dialog); `App/Commands.swift:33-56` (the Meeting menu); `App/MeetingBadge.swift:5`; `App/MeetingList.swift` (one line above the first group); `App/DevHooks.swift`

**Interfaces:**
- Consumes: `MoveSource`, `MoveIntake`, `MoveRules`, `MoveWords`, `MoveOut.all`, `MovePlan.Cancel`; `mode`, `workers`, `workerLines` (Part 2); `pipeline`, `library`, `cloudArchive`, `usage`, `profiles`, `activeProfile`, `changeCoachProfile`, `forgetPersona(_:)`, `stopSharing(callID:)`, `refresh()`, `syncNow()`, `processPending()`.
- Produces:

```swift
// AppController
@Published var moves: [String: MoveOut] = [:]             // this profile's moves that are not done, by call id
@Published var moveProgress: [String: Double] = [:]
@Published var moveLine: (text: String, since: Date)?     // "Moved to Work", or the sentence of a refusal
var moveSource: MoveSource!                               // one for the life of the app, made after the pipeline
var moveIntake: MoveIntake!
var moveTargets: [Profile] { get }                        // MoveRules.targets, none unless MoveRules.mayMove
func moveOffer(_ r: CallRecord) -> MoveRules.Offer
func moveSent(_ r: CallRecord) -> MoveRules.Sent
func moveMeeting(_ callID: String, to profileID: String)
func cancelMove(_ callID: String)
func processHere(_ callID: String)                        // takes the mark off a held call, then processPending()
func checkMoves()                                         // off the main actor: a start that was cut short, MoveSource.runAll(), then MoveIntake.run()
// MoveViews.swift
struct MoveMenu: View { let record: CallRecord; @Binding var moving: MoveRequest? }
struct MoveRequest: Identifiable { let record: CallRecord; let target: Profile }
```

Nothing in this task is a new rule: `MoveRules`, `MoveWords`, and `MovePlan` are tested in Tasks 1, 3, and 9.

- [ ] **Step 1: `AppController+Moves.swift`.** `moveSource` and `moveIntake` are made once, after the pipeline. The app's `MoveRemoval.Actions`: `forgetPersona` is `forgetPersona(_:)` on the main actor; `coach` is `changeCoachProfile`; `stopShares` is `stopSharing(callID:)`; `backup` is what `forget(_:)` does for the archive (`AppController.swift:1133-1141`); `removeFolder` is `pipeline.removeMoved`. `fetch` is `cloudArchive?.fetch`. `target` reads the registry file again at each call (`MoveRules.targetPaths`). `progress` fills `moveProgress` on the main actor.
  - `moveMeeting`: only when `MoveRules.mayMove(mode:identity:registry:)` with the registry read now; `moveSource.start`, and a refusal's sentence goes to `moveLine`; then `checkMoves()`. `moveSent` and `moveOffer` read the call folder's file names and `usage.events(forCall:)`.
  - `checkMoves()`: one run at a time, and a call during a run asks for one more. It returns unless `mode.does(.takeInMoved)` and the library has its identity. Off the main actor it first asks `MoveOut.hasWork(paths)`, `MoveIntake.hasWork(paths)`, and whether a meeting of the list has a `moveTo`; with three times no it ends there. Else, in this order: (1) for each written or failed record with `moveTo` and no ledger (a start that a stop cut short), `moveSource.start(_:to:)` again; Task 12 adds the recorded ones; (2) `moveSource.runAll()`: each `.moved(to:)` sets `moveLine` to `MoveWords.moved(to:)`, clears the selection of that meeting, and calls `refresh()`, `syncNow()`, and `coachVersion += 1`; each `.cancelled(why)` sets `moveLine` to `MoveWords.refusal`; (3) `moveIntake.run()`, and `processPending()` when it took something in. `moves` is read again from `MoveOut.all`.
  - A timer of `MoveRules.look` (15 s) calls `checkMoves()`. It is made only when `moveTargets` is not empty, so with one profile there is no timer.
  - `cancelMove`: `moveSource.cancel`; a false sets `moveLine` to `MoveWords.tooLate`.
- [ ] **Step 2: The hooks.** `finishLaunch`, in the block that is not inert, after `finishRemovals()`: `checkMoves()` and the timer. `runHousekeeping()`, first line: `checkMoves()`. The `didSet` of `workerLines`: `checkMoves()` when the value changed. With no `Moves` folder, no `Incoming` folder, and no marked meeting, `checkMoves()` reads two folder names and ends.
- [ ] **Step 3: The menus.** In `MeetingMenuItems`, before the `Divider()` above "Delete…", and in the Meeting menu after "Share…": only when `controller.moveTargets` is not empty, by `controller.moveOffer(record)`: `.offer` is a `Menu(MoveWords.menu)` with one button for each target (its name), which sets `moving`; `.moving` is a button `MoveWords.cancelMove`; `.refused(text)` is the menu, disabled, with the text as its help; `.hidden` is nothing. A held call (`moveTo` of a profile that is not in `moveTargets`, status `recorded`) also gets `MoveWords.processHere`. With one profile no item shows.
- [ ] **Step 4: The confirmation.** Beside the delete dialog in `MeetingsView`: a `confirmationDialog` with the title `MoveWords.title(record.title, to: target.name)`, the message `MoveWords.sent(controller.moveSent(record), from: active name, to: target.name)` and, on a new line, `MoveWords.leaves(active name)`, and the buttons `MoveWords.confirm` and Cancel.
- [ ] **Step 5: The row and the line.** `MeetingBadge` gets `moving`. A row whose meeting has a move, or a `moveTo`, shows `MoveWords.row(to:waited:copied:)` in the place of its second line, at `Rhythm.secondarySize` in `Palette.secondary`; a held call shows `MoveWords.heldForGone`. `moveLine` shows as one quiet line above the list's first group, for `MoveRules.resultShows` (8 s) after a move and `MoveRules.refusalShows` (30 s) after a refusal. It is text only: nothing in it opens the other profile.
- [ ] **Step 6: The preview hooks.** `App/DevHooks.swift`, in a preview: `MOSSAD_MOVE=<call id>=moving|slow|held` puts that state on that meeting's row (through a made-up `MoveOut` in `moves`, `started` 0 s or 120 s ago); `MOSSAD_MOVE_LINE=<text>` fills `moveLine`; `MOSSAD_MOVE_SHEET=<call id>` opens the confirmation for the first target of `MOSSAD_PROFILES`. In a preview `moveMeeting`, `cancelMove`, and `processHere` do nothing. Add the three to the comment at the top of the hooks.
- [ ] **Step 7: Run both build checks, then look at it in a preview under the rules of your brief**, with a made-up registry of two profiles: the menu "Move to" with the other profile; the confirmation's two sentences for a written meeting; the row's "Moving to Work…" and the slow form; the line "Moved to Work"; light and dark. With no `MOSSAD_PROFILES`: no item in either menu. Expected builds: exit status 0.
- [ ] **Step 8: Check.** `grep -rn "MoveSource(\|MoveIntake(" App | grep -v "AppController+Moves.swift\|WorkerEntry.swift"`: no output. `grep -n "Incoming\|Moves/" App/*.swift`: no output (the app names no folder of a move by hand).
- [ ] **Step 9: Commit.** `git commit -m "A meeting moves to another profile from its context menu and the Meeting menu, with a confirmation that says what the first profile already sent"`

---

### Task 12: "This call is for"

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/MoveAfterCall.swift`
- Modify: `.../Capture/CallRecorder.swift` (one function after `setGeneratedTitle`, `:616-619`); `.../Chat/AskPanel.swift:5-35` (`LiveOffReason`: two cases); `App/AppController+Moves.swift`; `App/AppController.swift` (`startLive` `:1370-1378`, `startLiveTitling` `:1437`, the three ends of a call at `:1186-1209`, `:1984-1999`, and the launch); `App/AppController+LivePoints.swift:176` (`hearPoints`); `App/AppController+LiveChat.swift:65`, `:103`; `App/MenuContent.swift:275-320` (`RecordingStatus`); `App/DevHooks.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MoveAfterCallTests.swift`, `MoveGateSourceTests.swift` (new)

**Interfaces:**
- Consumes: `MoveRules.targets`, `ProfileRegistry`, `ProfileColor`, `CallRecord.moveTo`, `ProcessingQueue.recoverInterrupted`, `MoveSource.start(_:to:afterCall:)`.
- Produces:

```swift
public enum MoveAfterCall {
    public enum Choice: Equatable, Sendable { case here, other(String), backHere }
    public enum Send: String, CaseIterable, Sendable { case liveTranscript, liveTitle, livePoints, liveChat, currentCall, chatSummary, pipeline }
    public static func allows(_ send: Send, _ choice: Choice) -> Bool
    public static func liveOff(_ choice: Choice) -> LiveOffReason?
    public static func next(_ choice: Choice, picked profile: String, active: String) -> Choice
    public struct Menu: Equatable, Sendable {
        public struct Row: Equatable, Sendable, Identifiable { public let id: String; public let name: String; public let color: ProfileColor; public let chosen: Bool }
        public static let title = "This call is for"
        public let rows: [Row]
        public let note: String?
    }
    public static func menu(_ registry: ProfileRegistry, active: String, choice: Choice) -> Menu?
    public enum AtEnd: Equatable, Sendable { case process, move(to: String), hold, nothing }
    public static func atEnd(_ record: CallRecord?, targets: [String]) -> AtEnd
}
// LiveOffReason
case forOtherProfile, afterOtherProfile
// CallRecorder
/// The profile the call that records now is for, or nil for this one. Saved at once, so a crash keeps it.
public func setMoveTarget(_ profile: String?, forCall id: String)
// AppController
@Published var callChoice: (callID: String, choice: MoveAfterCall.Choice)?
func setCallProfile(_ profileID: String)
/// The choice of a call: `callChoice` while that call records; after it, `.other(moveTo)` when its record is marked, else `.here`.
func choice(forCall callID: String) -> MoveAfterCall.Choice
```

`allows`: with `.here` every send is allowed. With `.other` none is. With `.backHere`: `chatSummary` and `pipeline` are allowed; `liveTranscript`, `liveTitle`, `livePoints`, `liveChat`, and `currentCall` are not. `next`: a pick of another profile is `.other(id)`; a pick of the active one is `.backHere` when the choice was `.other` or `.backHere`, else `.here`. `menu`: nil with one live profile; the live profiles in the registry's order, the active one chosen for `.here` and `.backHere`. The note: nil for `.here`; for `.other`, "“Work” writes the notes. Nothing more of this call is sent from “Mossad”."; for `.backHere`, "The live transcript stays off for the rest of this call." `atEnd`: a nil record (a skipped call, or one too short to keep) is `.nothing`; no `moveTo` is `.process`; a `moveTo` in `targets` is `.move(to:)`; else `.hold`.

`LiveOffReason`: `forOtherProfile` has the text "This call is for another profile, so nothing of it is sent from here." and the panel text "This call is for another profile, so Mossad cannot answer during the call. The recording is safe, and that profile writes the notes."; `afterOtherProfile` has "The live transcript stays off for the rest of this call." and "The live transcript stays off for the rest of this call, so Mossad cannot answer during the call. The recording is safe, and the full notes come after the call." `fix` is nil for both.

Every send of a call between the choice and its end, and its gate:

| Send | Where | Gate |
| --- | --- | --- |
| The two live streams to the transcription service | `startLive` (`AppController.swift:1370`), also after a pause (`:1366`) and a lost connection (`:1529`) | `.liveTranscript`, first line after the status guard; the reason goes to `liveOff` |
| The live title | `startLiveTitling` (`:1437`) | `.liveTitle` |
| The check of a point | `hearPoints` (`AppController+LivePoints.swift:176`) | `.livePoints` |
| An answer of the live chat, and its summary of the older lines | `liveChatAnswer` (`AppController+LiveChat.swift:65`) | `.liveChat`: throws, and the panel shows the reason |
| `live.json`, read by `current_call` in the app's chat and in other AI apps | the call folder | `.currentCall`: the file is deleted at the choice, and `live.fileURL` stays nil |
| The summary of the live chats a minute after the call | `summarizeLiveChats` (`:103`) | `.chatSummary`, for the chats of that call, by the mark on its record |
| The pipeline: the upload, the summary, and all that follows a written meeting | the detector's end (`AppController.swift:1998`), `stopCurrentCall` (`:1203`), and the launch after a quit or a crash | `.pipeline` by `atEnd`; and the guards of Task 4 |

The sync, the backup, the coach, the tasks, the points check, and the reads of people take only a written meeting, so the guards of Task 4 cover them. The read of the calendar for the call's title sends nothing of the call.

- [ ] **Step 1: Write the failing tests**

```swift
func testNothingIsSentAfterTheChoice() {
    for send in MoveAfterCall.Send.allCases {
        XCTAssertTrue(MoveAfterCall.allows(send, .here)); XCTAssertFalse(MoveAfterCall.allows(send, .other("1a2b3c4d")))
    }
    let back = MoveAfterCall.Send.allCases.filter { MoveAfterCall.allows($0, .backHere) }
    XCTAssertEqual(Set(back), [.chatSummary, .pipeline])
}
func testTheChoiceCanBeTakenBack() {
    // next(.here, picked: "1a2b3c4d", active: "default") is .other("1a2b3c4d"); next(.other("1a2b3c4d"), picked: "default", active: "default")
    // is .backHere; next(.backHere, picked: "default", ...) is .backHere; next(.here, picked: "default", ...) is .here;
    // next(.backHere, picked: "1a2b3c4d", ...) is .other("1a2b3c4d").
}
func testTheReasonTheLiveTranscriptIsOff()   // nil, .forOtherProfile, .afterOtherProfile; the four strings; `fix` nil
func testThePanelsMenu() {
    // One profile: nil. default "Mossad", Work (1a2b3c4d), Old (removing), active default, .here: rows Mossad (chosen) and Work; note nil.
    // .other("1a2b3c4d"): Work chosen; the note names “Work” and “Mossad” as above. .backHere: Mossad chosen; the second note.
}
func testTheEndOfAMarkedCall() {
    // atEnd(nil, targets: ["1a2b3c4d"]) is .nothing. No moveTo: .process. moveTo "1a2b3c4d": .move(to: "1a2b3c4d").
    // moveTo "9f9f9f9f" with targets ["1a2b3c4d"]: .hold. moveTo with no target at all: .hold.
}
func testTheRecorderKeepsTheChoiceOnTheRecord() throws
    // A manual recording as the recorder's tests begin one. setMoveTarget("1a2b3c4d", forCall: id): call.json on disk has moveTo.
    // Another call's id: no change. nil: the key is gone. After end(at:trimTo:byPerson:) the record is .recorded with the moveTo it had.
func testACrashKeepsTheChoice() throws
    // A folder with status .recording, moveTo "1a2b3c4d", and tracks of 90 s: after recoverInterrupted() it is .recorded with moveTo,
    // and pending(now:) does not hold it.
// MoveGateSourceTests: reads the app's sources beside this test file, as WorkerSourceTests does.
func testEachLiveSendAsksTheGate() throws {
    // In App/AppController.swift: the body of startLive has "MoveAfterCall.allows(.liveTranscript"; startLiveTitling has ".liveTitle".
    // In App/AppController+LivePoints.swift: hearPoints has ".livePoints". In App/AppController+LiveChat.swift: liveChatAnswer has
    // ".liveChat" and summarizeLiveChats has ".chatSummary". "MoveAfterCall.atEnd(" is in App/AppController.swift at least 2 times
    // (the detector's end and stopCurrentCall) and in App/AppController+Moves.swift (the launch).
    // Each line of App/AppController.swift with "pipeline.process(record.id)" has "case .process" on it or on one of the 3 lines before it.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter "MoveAfterCallTests|MoveGateSourceTests"`. Expected: the build fails with "cannot find 'MoveAfterCall' in scope".
- [ ] **Step 3: Write `MoveAfterCall.swift`, the two cases, and `CallRecorder.setMoveTarget`.** Run `swift test --filter MoveAfterCallTests`, then `swift test`. Expected: PASS for `MoveAfterCallTests`; `testEachLiveSendAsksTheGate` still fails until Step 5.
- [ ] **Step 4: `setCallProfile(_:)` in `App/AppController+Moves.swift`.** Only while a call records and `MoveRules.mayMove`. `choice = MoveAfterCall.next(...)`. In this order: (1) on the capture queue, `recorder.setMoveTarget(<the id, or nil for the active profile>, forCall:)`, so the record has it first; (2) `callChoice`; (3) for `.other`: `stopLive()`, which ends the streams, the live title, the live names, and the check of points; then the file `live.json` of the call folder is deleted; the answer of a live chat in flight is stopped through its `ChatSession`; (4) `liveOff = MoveAfterCall.liveOff(choice)`. For `.backHere` nothing starts again. The owner's ticks of points still work; the removal reopens them when the meeting leaves.
- [ ] **Step 5: The gates.** Each place of the table asks `MoveAfterCall.allows(_, choice(forCall:))`. The summary of the live chats runs a minute after the call, when `callChoice` is gone, so `choice(forCall:)` then reads the record's `moveTo`. The two ends of a call switch on `MoveAfterCall.atEnd(record, targets: moveTargets.map(\.id))`: `.process` is today's line; `.move(to:)` is `Task { _ = await moveSource.start(record.id, to:, afterCall: true); checkMoves() }`; `.hold` and `.nothing` do nothing more. `endCallForQuit` does not change. In `checkMoves()` (Task 11), part (1) now also takes each recorded call with `moveTo` and no ledger through `MoveAfterCall.atEnd`: `.move(to:)` starts its move with `afterCall: true`, and `.hold` leaves it. That is the launch after a quit or a crash, and the next try after a copy that failed. `forgetLiveCall()` clears `callChoice`. Run `swift test --filter MoveGateSourceTests`. Expected: PASS.
- [ ] **Step 6: The panel and the live page.** In `RecordingStatus` (`App/MenuContent.swift`), under `CallControls`: when `moveTargets` is not empty and `MoveAfterCall.menu(...)` is not nil, a `Menu(MoveAfterCall.Menu.title)` whose rows are the profiles with their color dot and a check on the chosen one, each calling `setCallProfile`; under it the note, at `Rhythm.secondarySize` in `Palette.secondary`. The live page's transcript shows `liveOffReason` as it does for the reasons of today. The quick panel shows the reason's panel text through `AskPanelRules`, with no code of its own.
- [ ] **Step 7: The preview hook.** `App/DevHooks.swift`, in a preview that shows a made-up live call (`MOSSAD_ASK_CALL`): `MOSSAD_CALL_FOR=<profile id>|back` fills `callChoice` and `liveOff`. Add it to the comment at the top of the hooks.
- [ ] **Step 8: Run both build checks, then look at it in a preview under the rules of your brief:** the menu bar panel's row and its note for each of the two choices, and the quick panel's words. With no `MOSSAD_PROFILES`: no row. Expected builds: exit status 0.
- [ ] **Step 9: Commit.** `git commit -m "During a call the owner can say that it is for another profile: nothing more of it is sent from here, and that profile writes the notes"`

---

### Task 13: The words

**Files:**
- Modify: `AGENTS.md`, `website/content/site.json`

- [ ] **Step 1: `AGENTS.md`.** A new row for `.../Profiles/Move*.swift`, `App/AppController+Moves.swift`, `App/MoveViews.swift`: a move is two halves, and each profile's own process does its own; the folders `Incoming` and `Moves` (made by the first move, never by `ensureDirectories`); the marker `move.json`, which the target renames to `claimed.json`, and the one rename that decides between a claim and a cancel; `MoveOut` and its states; `MovePlan` is the one table of the next step of each side; `MovedRecord.fields` gives every field of `CallRecord` a rule, and a new field needs one; `MovedFiles`; `CallRecord.moveTo` and the guards in `ProcessingQueue.pending` and the pipeline; `MovedVoices` (the fingerprints, `InviteVoiceRules.decide` with the record's invite never sure, the owner's keys from the marker, no enrolment of the owner); `MoveIntake` and its steps; the eight steps of `MoveRemoval` in their order and why the folder is last; `movedCalls` in the points and the coach's memory, and the empty marker of a task; an id that left a profile is never used there again; `MoveRules.sent`; what stays in the first profile; `MoveAfterCall` and the table of gates: a new send of a live call asks `MoveAfterCall.allows`; the look every 15 s in a worker and in the app; the preview hooks `MOSSAD_MOVE`, `MOSSAD_MOVE_LINE`, `MOSSAD_MOVE_SHEET`, `MOSSAD_CALL_FOR`, and the DEBUG proof hooks. Change the rows it touches: `.../Records/` (`moveTo`), `.../Pipeline/Pipeline.swift` (a marked call, `removeMoved`), `.../Series/` and `.../Coach/` (`movedCalls`, `forgetMoved`), `.../Commitments/` (`forget(callID:)`), `.../Cloud/` (`fetch`), `.../People/` (`ReferenceBackup.forget(note:)`), the profiles row and the worker's row (the duty `takeInMoved`), and `.../Chat/` (the two reasons of `LiveOffReason`).
- [ ] **Step 2: `website/content/site.json`.** In the feature `separate-profiles`, two more details: "A meeting that went to the wrong profile moves to the right one, with its recording and its notes" and "During a call you can say that it is for the other profile, and that profile writes the notes". Add `Packages/MossadCore/Sources/MossadCore/Profiles/MovePlan.swift` and `Packages/MossadCore/Sources/MossadCore/Profiles/MoveAfterCall.swift` to its `sources`. Say nothing of a folder, a marker, or a worker.
- [ ] **Step 3: Check.** Run: `python3 -m json.tool website/content/site.json > /dev/null && cd Packages/MossadCore && swift test`. Expected: exit status 0 and 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "AGENTS and the website say that a meeting can move to another profile"`

---

## Owner steps

After the release, with the real app and two profiles:

1. Record a short test call in one profile. When its note is written, use "Move to" on it. The row says "Moving to …", then the line "Moved to …" shows. Switch: the meeting is in the other profile with its note, its recording, and its chat.
2. In the first profile, look at People, Tasks, the points, and Coach: nothing of that call is there. In Analytics its cost is still counted: that is by design.
3. Move it back. It has a new id (its folder ends in `-moved`); nothing else differs.
4. During a test call, choose "This call is for ▸ <the other profile>" in the menu bar panel. The live transcript stops. After the call the meeting shows in the other profile, and this profile's Log has no upload of it.
5. Know the limits. A meeting in work cannot move until its notes are ready. A meeting made from Gemini notes never moves. What the first profile's services already got of a meeting stays with them. A share link of a moved meeting is stopped; make a new one in the other profile. With a profile whose setup is not finished, or with Mossad quit, a moved meeting waits and arrives when that profile is next open.
6. On the Mac only, three things of a moved meeting stay in the first profile: its cost rows, the calendar title in the list that keeps its Gemini notes away, and the lines of the people log.

## Self-review

- **Spec coverage.** "Move to" in the two menus, for the meetings the spec names, never the live call or a notes-only one: Tasks 3 and 11. Step 1 (the copy, the checks, `Incoming` beside `Audio`, the backup's download, the refusal): Tasks 1 and 4. Step 2 (no ids, no backup place, no share, the chats, not `coach.json` or `findings.json`): Tasks 2 and 4. Step 3 (the take-in, `<id>-moved`, the voices from the fingerprints, the summary only where a name changed, a new meeting of that profile, the mark): Tasks 5, 6, and 10. Step 4 (what delete removes, what it leaves, the points, the voices, the person, the usage log): Tasks 7 and 8. "Never in neither" and "the next launch finishes the move": Tasks 1 and 9, and proof runs 2 and 3. Moving back: Task 9 and proof run 4. The one sentence of the confirmation: Tasks 3 and 11. "Move after the call": Task 12. The spec's tests "the move's plan (each step, a stop after each step, the id that is taken, the fields a moved record loses)": Tasks 1, 2, and 9. Words and the website: Task 13. Not covered, by the brief: Parts 1 to 3.
- **Types.** `MoveMarker.Look` is what `MovePlan.source` and `MovePlan.target` take and `MoveMarker.look` gives. `MoveOut.Step` is what `MoveRemoval.run` takes and `MoveOut.nextStep` gives. `MovePlan.Cancel` is in `MoveSource.Event.cancelled` and in `MoveWords.refusal`. `MoveCopy.FileCopy` is `MoveSource.Setup.copy`. `MoveRemoval.Actions` is `MoveSource.Setup.actions`, filled by the worker (Task 10) and the app (Task 11). `MovedVoices.Naming.changed` is the `namesChanged` of `MovedRecord.arrival`. `MoveRules.Sent` is what `MoveWords.sent` takes. `MoveAfterCall.Choice` is `AppController.callChoice`'s value, and `MoveAfterCall.atEnd` reads the `moveTo` that `CallRecorder.setMoveTarget` and `Pipeline.setMoveTarget` write. `ProfileWorker.Setup.target` and `MoveSource.Setup.target` are both `MoveRules.targetPaths`.
- **Proportion.** The spec's Part 4 is half a page because it leaves the mechanism to the plan. This plan is long where the brief asked for a rule with a test (the two tables of steps, the fields, the voices, the removal, the gates) and short where the code is a call (Tasks 10 to 13). Bodies are left to the builder; the tables are the decisions.
