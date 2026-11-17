# Profiles Part 2 (the background run) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The profile that is not active still finishes its meetings, syncs, and backs up, in a process with no window, while the Mac stays in the other profile.

**Architecture:** A worker is a second process of the same signed app, `Mossad --profile <id> --worker`, started by the foreground app as a child process. It never makes an `AppController` or an `NSApplication`: `MossadEntry.main()` hands it to `ProfileWorker` in MossadCore before `MossadApp.main()`, as `--mcp` is handed over today. The foreground app writes one small file beside the registry (`foreground.json`: its pid, whether a call records, whether the workers must stop); each worker reads it every 2 s and watches that pid. One table in MossadCore (`Duty` by `RunMode`) says what each kind of process does.

**Tech Stack:** Swift 6, Foundation (`Process`, Dispatch sources), EventKit (status and read only), CloudKit, Security (Keychain), XCTest. No new package.

**Spec:** `docs/superpowers/specs/2026-11-16-profiles-design.md`. Read it whole before any task. This plan covers only "Part 2: the background run". Where this plan and the spec disagree, the spec wins, except for the points in "What the code contradicts".

**Branch:** `feature/profiles-worker`, made from `feature/profiles-mac` after Part 1's Tasks 8 to 10 and its lock fix are in (see "What Part 1 still adds").

**Code read for this plan:** `feature/profiles-mac` at b6444df (Part 1 through Task 7). Every `file:line` below is of that commit. Find each place again by its text before you edit: Part 1's last tasks move lines.

## Global Constraints

- Test first. Write the failing test, run it, then write the code.
- Pure logic goes in `Packages/MossadCore/`. The app target holds views and wiring only.
- `cd Packages/MossadCore && swift test` (the whole suite) must pass before every commit.
- No build, test, or run while a call records. Before each `swift test`, `xcodebuild`, or run of the app, run the call gate script that your brief names. If it says a call records, wait.
- Never block the main thread. Each wait in this plan (a worker's folder lock, a file write) runs off the main actor.
- Unknown is not false. A calendar that a worker cannot read is "not known", never "no invite". A foreground file that a worker cannot read means "a call records".
- Resumable steps. A worker's stop is the end of its process at any moment; the step in flight starts again from the last saved `call.json`.
- Do not lose audio. A worker never deletes a recording, a track, or a local copy.
- No AI attribution, no em dashes, and no real names of people in commits, code, or tests. Use made-up names such as "Sam Carter". Profile names such as "Work" and "Personal" are fine.
- Secrets live only in the Keychain. Never log them and never put them in arguments or in the two new files. A worker's arguments are `--profile <id> --worker` and nothing else.
- `Mossad.xcodeproj` is generated from `project.yml`. Never edit or commit it.
- Never restart or signal a process that you did not start. No `killall`, no `pkill`. (The app signals only its own child processes, through their `Process` objects.)
- The website follows the app: `website/content/site.json` in the same branch, benefits and not mechanism.
- `AGENTS.md` rows are updated in the same branch.
- With ONE profile nothing changes: no worker, no new file, no new folder, no new process, and every existing test passes unchanged. Add new test files or new test methods; do not edit an existing test.
- Never deploy `server/` from an agent session. This plan changes nothing in `server/`.
- Exact values: the argument `--worker`; the files `foreground.json` (beside the registry) and `<data folder>/Worker/status.json`; the check of the foreground file every 2 s; sync every 300 s, then 600, 1200, 2400, and 3600 s at most after failures in a row; the queue every 3600 s; the wait for a worker's folder at a switch or a delete: 5 s; a worker's restarts after 5, 30, and 120 s, then none; the exit codes 0 (stopped), 2 (refused), 3 (no foreground app), 4 (no folder lock), 5 (setup not finished); the sentence "Mossad could not stop the background work of “<name>”. Try again in a moment."; the lines "1 meeting in work", "2 meetings in work", "Could not transcribe 1 meeting", and the others in Task 7.
- Build check for app changes: `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Debug -derivedDataPath build/dev build -quiet`. Expected: exit status 0 and no line with `error:`.
- Commit messages are one sentence in the repo's style.

## Review Focus

1. **Two writers of one profile.** The window app and a worker of the same profile live at one time: after a crash of the foreground app and a fast start, in a switch to a profile that has a worker, or a worker started by hand. Expected: a worker runs only while it holds its folder lock; a switch stops the target's worker and sees the lock free before the new window app starts. Tests: `testAWorkerNeverRunsWithoutItsFolderLock` (Task 8), `testASwitchStopsTheWorkerAndWaitsForItsFolderBeforeTheNewInstanceStarts` (Task 10), `testAStoppedWorkerIsNotStartedAgain` (Task 9).
2. **Heavy work in a worker during a live call.** The foreground app records; the worker starts an encode or a model on this Mac; or the worker cannot read the foreground file and goes on as if no call records. Expected: `HeavyWorkPlan` as if the call were the worker's own; an unreadable file means a call records. Tests: `testAWorkerFollowsTheForegroundsCallAsItsOwn`, `testAWorkersGateHoldsAnEncodeWhileTheFlagIsUp` (Task 4), `testAFileThatCannotBeReadMeansACallRecords` (Task 3), `testWhileACallRecordsTheWorkerDoesNotSyncOrEncode` (Task 8), and proof run 4.
3. **The life of the processes.** A worker that stays after Mossad quit or crashed; a worker that fails at each start and is started for ever; a switch that hangs, or that leaves no window app, because a worker did not stop. Expected: a worker ends within seconds when the foreground's pid is gone or the file says stop; three failed starts end the tries; a worker that does not stop in 5 s refuses the switch and the old window app stays. Tests: `testAWorkerEndsWhenTheForegroundAppIsGoneOrSaysStop`, `testAReusedPidIsNotTheForegroundApp` (Task 3), `testAWorkerThatKeepsFailingIsGivenUp` (Task 9), `testAWorkerThatDoesNotStopRefusesTheSwitchAndTheOldAppStays`, `testAFailedStartBringsTheWorkersBack` (Task 10), and proof runs 2 and 3.
4. **A worker that shows itself or asks.** A notification, a permission prompt, a Dock icon, a hot key, the weekly mail. Expected: none, ever. Tests: `testTheModeTableIsTheSpecsTable` (Task 2), `testTheWorkersCodeCannotAskPostOrShow` (Task 8), and proof run 5 (the status read never asks).
5. **The invite of a meeting that a worker finishes.** A phone recording never gets its title and people because the worker could not read the calendar; "could not read" is taken as "no invite"; or a worker reads every calendar of the Mac for a profile that never chose its calendars, and a work meeting names a personal recording. Expected: the meeting is finished with no sure invite and marked; the next time its profile is active the invite is matched; a worker reads only the calendars its profile chose. Tests: `testAMeetingFinishedWithAnUnreadableCalendarIsMarkedAndStillWritten`, `testTheNextActiveLaunchMatchesAMarkedMeeting`, `testAWorkerReadsTheMacsCalendarsOnlyWithPermissionAndAChoice`, `testAnUnreadableMacCalendarIsNeverAsked` (Task 6).

## Decisions the owner already made

Do not reopen these.

- A worker is `Mossad --profile <id> --worker`: no window, no menu bar item, no Dock icon.
- The spec's table is the worker's whole job. It does: recover interrupted work; run the queue to "written"; pull and push its own sync store (the phone's recordings come in here); the digest and the server's config; the recording backup; what follows each meeting (the coach's review, commitments, the next-time check, personas); take in a meeting moved to it (Part 4; this plan leaves only the seam). It reads the calendar only to match the invite of a meeting it finishes, with its profile's calendars and Google tokens.
- It never: detects or records; imports Gemini notes; writes the calendar snapshot; shows upcoming meetings; registers hot keys, the login item, or the updater; owns the notification center or posts a notification; sends the weekly mail or usage statistics; runs retention; asks for a permission.
- Where a worker cannot read the calendar the answer is unknown, never "no invite": the meeting is finished as a call with no sure invite.
- No heavy work during a call, across processes. A worker that cannot tell assumes a call records.
- The owner sees one thing: the switcher's menu shows, for each other profile, "2 meetings in work" or the kind of its last failure, from a small status file that the worker writes in its own folder.
- The foreground app starts one worker for each other profile when its launch is done, and stops them when it quits or switches. A worker ends by itself when the foreground app is gone. A second copy and an inert copy start no worker.
- A profile whose setup is not finished gets no worker.
- Rehearsal, `--ui-preview`, a `MOSSAD_ROOT` run, and a made-up registry start no real worker. For proof runs only, a worker may run on a made-up registry against made-up folders.

## Choices made where the spec left one

- **A headless runner, not `AppController` in a third mode.** Reasons from the code: (1) `AppController` makes, as stored properties, four things a worker must never have, before any gate can run: `GlobalHotKeys()` (`AppController.swift:383`), `DetectionService` (`:436`), `Notifier()`, whose `init` takes the notification center's delegate (`:450`, `Notifier.swift:24-27`), and the recorder (`:453`). (2) The menu bar item is a scene of `MossadApp` (`MossadApp.swift:115`), and `App/Info.plist` has no `LSUIElement`, so a second `NSApplication` of the bundle is a second Dock icon and a second app that a click on Mossad can reach. (3) MossadCore imports no UserNotifications, ServiceManagement, or Sparkle, so a runner there cannot post, register, or update: the "never" column holds by what the code can reach. (4) The commands already run this way (`MossadApp.swift:42-104`). The cost is the wiring, so Task 5 moves the wiring into MossadCore and the app uses the same code.
- **The worker is a child process.** The foreground app starts it with `Process` (`Bundle.main.executableURL`, the arguments `--profile <id> --worker`, its own environment, no stdin, stdout, or stderr, `qualityOfService = .utility`). A child of the app is charged to the app by macOS, which is what the calendar permission needs (Task 1), and it is never an app instance of its own for the Dock or for `open`.
- **The signal is a file, with the pid as the parent watch.** `foreground.json` beside the registry: `version`, `pid`, `started` (the foreground's start time, so a reused pid is not taken for it), `recording`, `stopping`. Why a file: it is state, not an event, so it survives a crash of either side. A worker that starts late or missed a change reads the truth at its next check; a foreground app that crashed leaves a file whose pid is gone, and the worker ends. A pipe carries no state for a worker that the builder starts by hand in a proof run; a Darwin notification is lost by a process that is not there when it is posted. A stop also sends SIGTERM to the child, so a stop does not wait for the next check.
- **A worker never looks at a lock by taking it.** `InstanceLock.waitUntilFree` takes the lock for a moment (`InstanceLock.swift:43-51`), and the window app tries the Mac-wide lock once (`AppController.swift:652`): a worker that looked at that moment would make the window app a second copy. So the parent watch is the pid: an exit source on it (no polling) and one `sysctl` for that one pid at each 2 s check.
- **A stop is the app's Quit.** The worker starts no new step and its process ends (exit 0). It does not cancel the pipeline's task: a cancelled request would count as a failed try with a back-off (`Pipeline.swift:212-223`). Every record and file write is atomic, and an encode writes under a temporary name (`Recording.swift:64-66`), so the end of the process at any moment leaves each meeting at its last saved step. A request to a provider that was in flight is sent again by the next run, as after a Quit today.
- **The order of a switch:** stop the workers, wait for the target's folder lock (5 s at most), save `active`, start the new instance, quit. The spec says "saves `active`, tells its background runs to stop"; the stop comes first here so that a refusal leaves the registry as it was.
- **A worker decides by itself that setup is not finished.** The foreground app starts a worker for each other live profile; a worker whose profile would open setup at launch (`Onboarding.opensAtLaunch`: not finished and no meetings) exits with code 5 at once and is not started again by this foreground app. So the foreground app reads no setting of another profile.
- **A made-up registry:** a worker started by hand with `MOSSAD_PROFILES` runs, for proofs. It does only what stays in its folder (`Duty.leavesTheFolder`): recover, the people store, the queue, its status file. No sync, backup, calendar, or request for the coach, and it reads `foreground.json` beside the made-up registry.
- **The Mac's calendars in a worker.** Read only when the status is "full access" and the profile's window app has saved its choice of calendars (`calendarIDs`). A profile that never chose would read every calendar of the Mac (`CalendarMatcher.swift:302`), and a meeting of the other profile could name its recording. No permission, or no choice yet, is "unknown".
- **Unknown is remembered.** A meeting whose invite was looked for while the calendar could not be read gets `inviteUnknown` in its record. The next launch of that profile's window app matches such meetings (the last 30 days): the title and the people from the invite, the note written again; the summary and the names of the voices stay. With one profile the field is never written.
- **The next-time check in a worker** takes the upcoming meetings from the calendar snapshot (`Calendar/upcoming.json`), as `--mcp` does, and never from the calendar. With no snapshot it takes none, as the window app does before its first read.
- **The backup in a worker uploads and removes nothing local.** `CloudArchive.sync(keepLocalDays: nil, ...)`: the removal of old local copies waits for the window app, like retention. A worker never starts or goes on with a move of the backups.
- **What a worker leaves for the window app, beside the spec's list:** the iCloud Keychain items for the iPhone (a worker changes no key); the older "person brief" (`AppController+Coach.swift:60-61`); the reads of people for the phone (`personas: nil` in the sync, so the phone's copy stays as it is); the one-time backfills; the Google directory; the tell of the server about a stopped share (the worker only marks the link).
- **Sync in a worker:** the window app's rule and pace (every 300 s, never while a call records, and after a pass that changed something), with a back-off of 600, 1200, 2400, and 3600 s after failed syncs in a row. Between two syncs a worker with nothing to do sleeps; its only wake is the 2 s check of the foreground file (one `stat`, and a read only when the file changed).
- **CPU and memory.** A worker's heavy steps always run at background priority and one at a time (the new plan `.behindApp`, through the gate's one lane), because the window app is in front. A model on this Mac waits while a call records, as the spec says; with no call it runs behind the app, and `ModelLease` frees it after 180 s without use and at once when memory is short. No lock joins two workers: with two profiles there is one worker.
- **The status file:** `<data folder>/Worker/status.json`, a new folder made at the first write. The switcher shows a line only for a profile whose worker this foreground app has running, so an old file is never shown. One more line, "Not running", comes from the foreground app itself when it gave up on a worker.
- **Provider keys.** A worker reads its own profile's Keychain service (`Keychain.app`, which `AppIdentity` names for the process). A missing key is the pipeline's usual wait for that meeting: no failed try, no notification, and the meeting is tried again at the next pass. The status file says `key`.
- **Failures that the status counts** come from the records, so they survive a restart: a meeting in work whose next step needs a key that is missing; a meeting in work with failed tries; a meeting that failed in the last 7 days.
- **The words of a refusal** are the same for a switch and a delete: "Mossad could not stop the background work of “<name>”. Try again in a moment."
- **Debug hooks for the proofs**, in a debug build only: `--probe` (prints the calendar status of the process and of one child) and `MOSSAD_PROOF_CALL=<audio file>` on a made-up registry (makes one recorded call in an empty folder).

## What the code contradicts

- **"Where it cannot read, the answer is unknown, never 'no invite'."** The code cannot tell the two apart. `CalendarSource` has one method that returns a list (`CalendarMatcher.swift:201-203`); `EventKitCalendarSource.events` returns `[]` with no permission (`:315-316`); `Pipeline.matchInvite` returns `false` for both (`Pipeline.swift:822-828`); and a record with no invite is an ad-hoc call that "keeps the rules of before" (`InviteVoiceRules.swift:34-37`). Plan (Task 6): `canRead()` on the source, true for every source of today; the worker's source answers for real; the record keeps `inviteUnknown`. The naming rules do not change: a call with no sure invite and no guests is named by the rules of an ad-hoc call, as it is today for an owner with no Calendar permission.
- **"What follows each meeting today (`track()`): the coach's review, commitments, the next-time check, personas."** `track()` also makes missing recordings and runs the backup and the sync (`AppController.swift:2024-2037`), and personas are not in it: they run inside `runCoach` (`AppController+Coach.swift:58`), which also writes the older person briefs (`:60-61`) and sends the weekly mail (`:64`). So a worker cannot call the same function. Plan: `ProfileWorker.pass()` runs the parts one by one.
- **"Reads the calendar only to match the invite."** The next-time check reads the calendar's events for its catalog (`AppController+Series.swift:213-218`). Plan: the snapshot file (see "Choices").
- **"The recording backup" against "never runs retention".** The backup pass itself deletes local recordings older than "keep a local copy for N days" (`CloudArchive.swift:99-104`). Plan: `keepLocalDays: nil` in a worker.
- **"Today `inert` is the only switch, `AppController.swift:636`."** The line is `:675-677` now, and `inert` is not the only switch: `track()` reads `isSecondCopy` alone (`:2025`), and `refreshPeopleReferences` reads both (`:1036`).
- **"No Dock icon."** Mossad is not an agent app: `App/Info.plist` has no `LSUIElement`. Any process that starts `NSApplication` shows in the Dock. Plan: the worker never does.
- **The Part 1 plan's seam "a worker can watch the Mac-wide lock to end when the foreground app is gone."** Looking takes the lock (`InstanceLock.swift:43-51`). Plan: the pid (see "Choices").
- **The spec's order of a switch** ("saves `active`, tells its background runs to stop, starts a new instance"). `switchProfile` saves, then starts (`AppController+Profiles.swift:36-48`). Plan: the stop and the wait come before the save.
- **A stop "at a step boundary".** The pipeline has no way to stop between steps, and a cancelled step is a failed try (`Pipeline.swift:212-223`). Plan: the end of the process, as Quit does today.
- **`scripts/build.sh`.** It ends only the process whose command line ends in `Mossad` (`:33`, `:46`), so an install does not end the workers: they end by themselves within seconds, but the bundle is replaced at once (`:53`). Plan (Task 9): the script waits for them. Also found, and Part 1's to fix, not this plan's: its call check reads only `~/Mossad/Audio` (`:14`), so it does not see a call that another profile records.
- **The checked facts hold.** `rebuildPipeline()` runs before the mode is known (`AppController.swift:636`) and the two iCloud Keychain updates wait for `launchDecided` (`AppController+Sync.swift:34`); the commands are handed over before `MossadApp.main()` (`MossadApp.swift:36-106`); `matchInvite` is called from `identify` (`Pipeline.swift:780`) and `summarize` (`:833`) and nowhere else, and it is the only reader of the pipeline's calendar (`:824`); `HeavyWorkGate` asks one closure in one process (`HeavyWork.swift:148`, `AppController.swift:779-780`); sync is a 300 s timer plus each job (`AppController.swift:795-798`, `:2034`); a phone recording comes in through `CloudSync.pull` and `importRecording`, then `processPending()` (`CloudSync.swift:304`, `:489`, `AppController+Sync.swift:290`).

## What Part 1 still adds

These are in the Part 1 plan and not in the code read for this plan. Read them on the branch before the task that uses them.

- `deleteProfile(_:typed:)` and `finishRemovals()` in `App/AppController+Profiles.swift` (Part 1, Task 8). Used by Task 10.
- `ProfileSwitcher` in `App/ProfileSwitcher.swift`, which draws `controller.profileMenu` (Part 1, Task 9). Used by Task 11.
- The `AGENTS.md` row for profiles and the `site.json` feature `separate-profiles` (Part 1, Task 10). Used by Task 12.
- The review fix: a window app that finds its folder lock taken by another process lets the Mac-wide lock go and is a second copy (a pure rule for which locks a copy holds). This plan relies on it for one case only: a worker of the profile that still lives when the window app starts by a click and not by a switch.

## Proof runs

A proof run is a worker of the debug build on a made-up registry. Each one obeys all of these:

1. Run the call gate script that your brief names. Go on only when it says the Mac is idle.
2. Use the debug build of this worktree, `build/dev/Build/Products/Debug/Mossad.app` (the build check makes it). Never the app in /Applications.
3. A made-up registry and made-up folders under `build/proof/` of this worktree.
4. No window: a worker has none. Never start the window app for a proof.
5. End each process that you started by its own pid, within 90 s.
6. Read and write nothing under `~/Mossad` or `~/Library/Application Support/Mossad`.
7. Clean up after: `rm -rf build/proof; defaults delete com.dwebber.mossad.profile.feedc0de 2>/dev/null`.

The setup that each proof starts with:

```sh
APP="$PWD/build/dev/Build/Products/Debug/Mossad.app/Contents/MacOS/Mossad"
P="$PWD/build/proof"; R="$P/Mossad Proof"; rm -rf "$P"; mkdir -p "$R"
printf '{"version":1,"active":"feedc0de","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"feedc0de","name":"Proof","color":"blue","root":"%s"}]}' "$R" > "$P/profiles.json"
export MOSSAD_PROFILES="$P/profiles.json"
fg() { printf '{"version":1,"pid":%s,"recording":%s,"stopping":%s}' "$1" "$2" "$3" > "$P/fg.tmp" && mv "$P/fg.tmp" "$P/foreground.json"; }
```

`fg <pid> <recording> <stopping>` writes the foreground file in one rename. A `sleep 80 &` of your own stands in for the foreground app.

## File structure

| File | Responsibility |
| --- | --- |
| `Packages/MossadCore/Sources/MossadCore/Worker/WorkerLaunch.swift` (new) | The argument, the refusals, the exit codes, the child process, which profiles get a worker, the restart rule, the steps of a switch. |
| `.../Worker/ForegroundState.swift` (new) | The foreground file, `ProcessFacts`, and the pure watch rule. |
| `.../Worker/ForegroundWatcher.swift` (new) | The 2 s check, the exit source, the signals. |
| `.../Worker/ServiceSettings.swift` (new) | The settings a process builds its services from, and the factories. Used by the app and the worker. |
| `.../Sync/SyncPass.swift` (new) | One sync pass, moved out of `AppController.syncNow`. Used by both. |
| `.../Worker/WorkerCalendar.swift` (new) | The calendar that a worker's pipeline reads, and what "unknown" is. |
| `.../Worker/WorkerStatus.swift` (new) | The status file and the switcher's line. |
| `.../Worker/ProfileWorker.swift` (new) | The worker's run: the duties in order. |
| `.../Worker/WorkerPace.swift` (new) | When a sync and a queue pass are due. |
| `.../Support/RunMode.swift` | `worker`, `Duty`, and the table. |
| `.../Support/HeavyWork.swift` | `.behindApp` and a worker's gate. |
| `App/WorkerEntry.swift` (new) | The entry of a worker process: the checks, the lock, the wiring. No `AppController`. |
| `App/WorkerManager.swift` (new) | The foreground app's side: start, tell, stop, and the lines for the switcher. |
| `App/CloudEntitlement.swift` (new) | Whether this build may use iCloud, for the app and the worker. |

## Seams for Parts 3 and 4

- **`Duty.takeInMoved`** is in the table (full and worker). Part 4 adds the step to `ProfileWorker.start()` between the people store and the first pass, and to the window app's launch. This plan adds no code for it.
- **`WorkerStatus`** has a `version`; a newer file is not read. Part 4 can add a count of meetings that wait in `Incoming`.
- **`ForegroundState`** has a `version`. Part 4's "This call is for ▸ <profile>" can add a field; an older worker then reads the file as unreadable and assumes a call records, which is the safe side.
- **`ServiceSettings` and `SyncPass`** take the settings and the stores as values, which is what the phone's one process needs in Part 3.

---

### Task 1: The proof first: a headless `--worker` that refuses, and what it sees of the Mac's calendar

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/WorkerLaunch.swift`, `App/WorkerEntry.swift`
- Modify: `App/MossadApp.swift:33` (one block after the `mismatch` line); `Packages/MossadCore/Sources/MossadCore/Calendar/CalendarMatcher.swift:339-342` (one more static)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/WorkerLaunchTests.swift` (new)

**Interfaces:**
- Consumes: `AppIdentity` (`takesProfiles`, `profile`, `madeUpRegistry`), `Profile`, `AppIdentity.commands`.
- Produces:

```swift
public enum WorkerLaunch {
    public static let argument = "--worker"
    public enum Exit: Int32, Sendable { case stopped = 0, refused = 2, noForeground = 3, lockNotHeld = 4, setupNotDone = 5 }
    public static func isWorker(_ arguments: [String]) -> Bool
    public static func refusal(_ identity: AppIdentity, arguments: [String]) -> String?
    public static func arguments(for profile: Profile) -> [String]          // ["--profile", id, "--worker"]
    #if os(macOS)
    public static func process(executable: URL, profile: Profile, environment: [String: String]) -> Process
    #endif
}
extension EventKitCalendarSource {
    /// The Mac's answer for this process: "fullAccess", "writeOnly", "denied", "restricted", or "notDetermined". It never asks.
    public static var permissionName: String { get }
}
// App/WorkerEntry.swift
enum WorkerEntry { static func run(_ identity: AppIdentity) -> Never }
```

- [ ] **Step 1: Write the failing tests**

```swift
private let main = AppIdentity.mainBundleID
private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")
private func registry() -> ProfileRegistry.Loaded   // default and `work`, state .read, as ProfileProofTests makes it
func testAWorkerNeedsProfilesAndItsOwnProfile() {
    let ok = ["Mossad", "--profile", "1a2b3c4d", "--worker"]
    XCTAssertNil(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: ok, registry: registry()), arguments: ok))
    let bare = ["Mossad", "--worker"]
    XCTAssertEqual(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: bare, registry: registry()), arguments: bare),
                   "Mossad: --worker needs --profile <id>; not starting.")
    for id in [AppIdentity(bundleID: AppIdentity.rehearsalBundleID, arguments: ok, registry: registry()),
               AppIdentity(bundleID: main, arguments: ok, environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: registry()),
               AppIdentity(bundleID: main, arguments: ok + ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: registry())] {
        XCTAssertEqual(WorkerLaunch.refusal(id, arguments: ok), "Mossad: a worker needs profiles; not starting.")
    }
    let both = ok + ["--mcp"]
    XCTAssertEqual(WorkerLaunch.refusal(AppIdentity(bundleID: main, arguments: both, registry: registry()), arguments: both),
                   "Mossad: --worker cannot run with a command; not starting.")
}
func testTheChildProcessOfAWorker() {
    let p = WorkerLaunch.process(executable: URL(fileURLWithPath: "/tmp/Mossad"), profile: work, environment: ["A": "b"])
    XCTAssertEqual(p.arguments, ["--profile", "1a2b3c4d", "--worker"])
    XCTAssertEqual(p.environment, ["A": "b"])
    XCTAssertEqual(p.qualityOfService, .utility)
    XCTAssertEqual(p.executableURL?.path, "/tmp/Mossad")
}
func testTheStatusReadHasAName() {
    XCTAssertTrue(["fullAccess", "writeOnly", "denied", "restricted", "notDetermined"].contains(EventKitCalendarSource.permissionName))
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter WorkerLaunchTests`. Expected: the build fails with "cannot find 'WorkerLaunch' in scope".
- [ ] **Step 3: Write `WorkerLaunch.swift` and `permissionName`.** `refusal` asks in this order: profiles, a command, `--profile`. `process` gives the child `FileHandle.nullDevice` as its stdin, stdout, and stderr. `permissionName` reads `EKEventStore.authorizationStatus(for: .event)` and nothing else. Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: The entry.** In `App/MossadApp.swift`, after the `mismatch` line (`:33`) and before `--import-keys`: `if WorkerLaunch.isWorker(CommandLine.arguments) { WorkerEntry.run(identity) }`. `WorkerEntry.run`: (1) `WorkerLaunch.refusal`: one line on stderr, `exit(2)`. (2) In a debug build only (`#if DEBUG`), with `--probe`: print `calendar <permissionName> pid <pid>`; unless `--probe-child` is there too, start one child with `WorkerLaunch.process(executable: Bundle.main.executableURL!, profile: identity.profile, environment: ProcessInfo.processInfo.environment)`, with `--probe --probe-child` added to its arguments and its stdout set to this process's, and wait for it; `exit(0)`. (3) Else print "Mossad: no foreground app; the worker does not start." on stderr and `exit(3)`. Task 8 puts the real start in place of (3). The probe touches no data folder.
- [ ] **Step 5: Run the build check.** Expected: exit status 0.
- [ ] **Step 6: Proof run 5: the calendar status, read only** (under "Proof runs")

```sh
"$APP" --profile feedc0de --worker --probe & W=$!; ( sleep 20; kill $W 2>/dev/null ) & wait $W; echo "exit $?"
"$APP" --worker; echo "exit $?"
```

Expected: two lines `calendar <status> pid <n>` with the same status and two different pids; `exit 0`; no prompt on the screen at any time; then `Mossad: --worker needs --profile <id>; not starting.` and `exit 2`. What this proves: the read never asks, and a child made by `WorkerLaunch.process` has its parent's answer. What it cannot prove: the status itself. A process started from a shell is charged to the shell's app, not to Mossad, so the value here is not the installed app's. The installed app has "full access" when the owner gave it (it reads calendars today), and its child then has the same; the worker logs its status at each start (Task 8), and "Owner steps" checks that line. The plan works in both outcomes: Task 6 reads the Mac's calendars only with "fullAccess" and never calls a request. Write the two statuses you saw in the commit's body. If the two lines differ, or a prompt shows, stop and report.

- [ ] **Step 7: Commit.** `git commit -m "A worker process refuses without profiles or its own profile, and a debug build shows what it sees of the calendar permission"`

---

### Task 2: The mode table

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Support/RunMode.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/RunModeTests.swift` (new)

**Interfaces:**
- Produces:

```swift
public enum RunMode: Equatable, Sendable {
    case full, inert, worker
    public static func decide(preview: Bool, rehearsal: Bool, secondCopy: Bool, madeUpRegistry: Bool, worker: Bool = false) -> RunMode
    public func does(_ duty: Duty) -> Bool
    /// `does`, and on a made-up registry only what stays in the folder.
    public func runs(_ duty: Duty, madeUpRegistry: Bool) -> Bool
}
public enum Duty: String, CaseIterable, Sendable {
    case recover, people, queue, inviteMatch, sync, digest, serverConfig, backup, coach, commitments, nextTime, personas, takeInMoved, statusFile
    case detect, record, geminiNotes, calendarSnapshot, upcoming, hotKeys, loginItem, updater, notifications, weeklyMail, usageStats, retention, askPermission
    case window, sharedItems, upkeep, registry, startWorkers
    public var leavesTheFolder: Bool
}
```

`decide` with `worker: true` is `.worker`, whatever the other values are. `leavesTheFolder` is true for `inviteMatch`, `sync`, `digest`, `serverConfig`, `backup`, `coach`, `commitments`, `nextTime`, `personas`. `people` is the people store brought in step at each start; `upkeep` is the one-time backfills, the older person briefs, and the Google directory; `sharedItems` is the iCloud Keychain items for the iPhone; `window` is a window, a menu bar item, and a Dock icon.

- [ ] **Step 1: Write the failing tests.** The table is the spec's table, with the rows the spec leaves to the builder at the end.

```swift
func testTheModeTableIsTheSpecsTable() {
    // duty: (full, worker, inert). A second copy is inert.
    let table: [Duty: (Bool, Bool, Bool)] = [
        .recover: (true, true, false), .people: (true, true, false), .queue: (true, true, false),
        .inviteMatch: (true, true, false), .sync: (true, true, false), .digest: (true, true, false),
        .serverConfig: (true, true, false), .backup: (true, true, false), .coach: (true, true, false),
        .commitments: (true, true, false), .nextTime: (true, true, false), .personas: (true, true, false),
        .takeInMoved: (true, true, false), .statusFile: (false, true, false),
        .detect: (true, false, false), .record: (true, false, false), .geminiNotes: (true, false, false),
        .calendarSnapshot: (true, false, false), .upcoming: (true, false, true), .hotKeys: (true, false, false),
        .loginItem: (true, false, false), .updater: (true, false, false), .notifications: (true, false, true),
        .weeklyMail: (true, false, false), .usageStats: (true, false, false), .retention: (true, false, false),
        .askPermission: (true, false, false),
        .window: (true, false, true), .sharedItems: (true, false, false), .upkeep: (true, false, false),
        .registry: (true, false, false), .startWorkers: (true, false, false),
    ]
    XCTAssertEqual(Set(table.keys), Set(Duty.allCases))
    let second = RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false)
    for (duty, row) in table {
        XCTAssertEqual(RunMode.full.does(duty), row.0, "full \(duty)")
        XCTAssertEqual(RunMode.worker.does(duty), row.1, "worker \(duty)")
        XCTAssertEqual(RunMode.inert.does(duty), row.2, "inert \(duty)")
        XCTAssertEqual(second.does(duty), row.2, "second copy \(duty)")
    }
}
func testAWorkerIsItsOwnMode() {
    for madeUp in [false, true] {
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: madeUp, worker: true), .worker)
    }
}
func testAWorkerOnAMadeUpRegistryStaysInItsFolder() {
    let stays: Set<Duty> = [.recover, .people, .queue, .takeInMoved, .statusFile]
    for duty in Duty.allCases { XCTAssertEqual(RunMode.worker.runs(duty, madeUpRegistry: true), stays.contains(duty), "\(duty)") }
    for duty in Duty.allCases { XCTAssertEqual(RunMode.worker.runs(duty, madeUpRegistry: false), RunMode.worker.does(duty)) }
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter RunModeTests`. Expected: the build fails with "cannot find type 'Duty' in scope".
- [ ] **Step 3: Write `Duty`, `does`, `runs`, and the new `decide`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures (`testAMadeUpRegistryRunsInert` in `ProfileProofTests` passes unchanged).
- [ ] **Step 4: Commit.** `git commit -m "One table says what the foreground app, a worker, and an inert copy each do"`

---

### Task 3: The foreground file and the watch

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/ForegroundState.swift`, `.../Worker/ForegroundWatcher.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ForegroundWatchTests.swift` (new)

**Interfaces:**
- Consumes: `ProfileRegistry.folder(home:)`.
- Produces:

```swift
public struct ForegroundState: Codable, Equatable, Sendable {
    public static let fileName = "foreground.json"
    public static let currentVersion = 1
    public var version: Int
    public var pid: Int32
    public var started: Date?        // the pid's start time; nil in a file written by hand: then only the pid is asked
    public var recording: Bool
    public var stopping: Bool
    public init(pid: Int32, started: Date?, recording: Bool, stopping: Bool = false)
    /// Beside the registry in use: the real folder, or the folder of the `MOSSAD_PROFILES` file.
    public static func url(home: URL, environment: [String: String]) -> URL
    public enum Read: Equatable, Sendable { case state(ForegroundState), missing, unreadable }
    public static func read(_ file: URL) -> Read      // a newer version is unreadable
    public func write(to file: URL) throws             // one atomic write; makes the folder
}
public enum ProcessFacts {
    public static func startTime(of pid: Int32) -> Date?              // `sysctl` for this one pid; nil when no such process
    public static func isAlive(pid: Int32, started: Date?) -> Bool    // the pid lives, and its start time is within 1 s of `started` when given
}
public struct ForegroundWatch: Equatable, Sendable {
    public enum Stop: String, Sendable { case told, foregroundGone, noForeground }
    public enum Order: Equatable, Sendable { case work(callRecords: Bool), stop(Stop) }
    public private(set) var known: ForegroundState?                   // the last good read
    public init()
    public mutating func next(_ read: ForegroundState.Read, alive: (ForegroundState) -> Bool) -> Order
}
public final class ForegroundWatcher: @unchecked Sendable {
    public static let every: TimeInterval = 2
    public init(file: URL, every: TimeInterval = ForegroundWatcher.every,
                alive: @escaping @Sendable (ForegroundState) -> Bool = { ProcessFacts.isAlive(pid: $0.pid, started: $0.started) },
                signals: Bool = true, onStop: @escaping @Sendable (ForegroundWatch.Stop) -> Void)
    public var callRecords: Bool { get }           // true until a read says no
    public func first() -> ForegroundWatch.Order   // the read at start, before the worker touches its folder
    public func start()                            // the timer, an exit source on the known pid, and SIGTERM and SIGINT as `.told`
}
```

The rule of `next`, which is also the test:

| Read | `known` before | `alive` | Order |
| --- | --- | --- | --- |
| a state with `stopping` | any | not asked | `stop(.told)` |
| a state | any | false | `stop(.foregroundGone)` |
| a state | any | true | `work(callRecords: state.recording)`; `known` is the state |
| missing | nil | not asked | `stop(.noForeground)` |
| missing | a state | not asked | `stop(.foregroundGone)` |
| unreadable | nil | not asked | `stop(.noForeground)` |
| unreadable | a state | false (asked of `known`) | `stop(.foregroundGone)` |
| unreadable | a state | true | `work(callRecords: true)`; `known` stays |

`ForegroundWatcher` reads the file at each tick only when its modification date or size changed, asks `alive` at each tick, and calls `onStop` once. The exit source (`DispatchSource.makeProcessSource(identifier:eventMask: .exit)`) is made again when the known pid changes.

- [ ] **Step 1: Write the failing tests**

```swift
func testAWorkerEndsWhenTheForegroundAppIsGoneOrSaysStop()   // the 8 rows of the table, each with XCTAssertEqual on the order and on `known`
func testAFileThatCannotBeReadMeansACallRecords() {
    var w = ForegroundWatch()
    XCTAssertEqual(w.next(.state(.init(pid: 10, started: nil, recording: false)), alive: { _ in true }), .work(callRecords: false))
    XCTAssertEqual(w.next(.unreadable, alive: { _ in true }), .work(callRecords: true))
    XCTAssertEqual(w.next(.unreadable, alive: { _ in true }), .work(callRecords: true))   // it keeps checking
    XCTAssertEqual(w.next(.state(.init(pid: 10, started: nil, recording: false)), alive: { _ in true }), .work(callRecords: false))
}
func testTheFileIsReadAndWritten() throws {
    // write then read gives the same state; `{"version":1,"pid":12,"recording":true,"stopping":false}` reads with started nil;
    // `{"version":2,...}` and "not json" are .unreadable; no file is .missing.
}
func testTheFileIsBesideTheRegistryInUse() {
    let home = URL(fileURLWithPath: "/Users/someone")
    XCTAssertEqual(ForegroundState.url(home: home, environment: [:]).path, "/Users/someone/Library/Application Support/Mossad/foreground.json")
    XCTAssertEqual(ForegroundState.url(home: home, environment: ["MOSSAD_PROFILES": "/tmp/x/profiles.json"]).path, "/tmp/x/foreground.json")
}
func testAReusedPidIsNotTheForegroundApp() {
    let me = ProcessInfo.processInfo.processIdentifier
    let started = try XCTUnwrap(ProcessFacts.startTime(of: me))
    XCTAssertTrue(ProcessFacts.isAlive(pid: me, started: started))
    XCTAssertTrue(ProcessFacts.isAlive(pid: me, started: nil))
    XCTAssertFalse(ProcessFacts.isAlive(pid: me, started: started.addingTimeInterval(-60)))
    XCTAssertFalse(ProcessFacts.isAlive(pid: 0x7FFF_FFF0, started: nil))
}
func testTheWatcherStopsWhenTheFileSaysSo() throws {
    // A temp file with this test's pid. A watcher with every: 0.05, signals: false. `first()` is .work(callRecords: false).
    // Write the file again with stopping true: onStop(.told) within 1 s, and one time only.
}
func testTheWatcherAssumesACallWhileTheFileCannotBeRead() throws {
    // After a good first read, write "not json": within 1 s callRecords is true and onStop was not called.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter ForegroundWatchTests`. Expected: the build fails with "cannot find 'ForegroundWatch' in scope".
- [ ] **Step 3: Write the two files.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "The foreground app's file says who it is, whether a call records, and when the workers stop, and a worker's watch reads it"`

---

### Task 4: Heavy work across processes

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Support/HeavyWork.swift:43-58, 148-153, 187-191`; `.../Pipeline/Pipeline.swift:925-940`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/HeavyWorkPlanTests.swift` (new methods)

**Interfaces:**
- Produces:

```swift
public enum HeavyWorkPlan { case run, behindCall, wait, behindApp }   // behindApp: no call records, but this is a worker
public static func plan(for step: HeavyStep, callRecording: Bool, released: Bool, worker: Bool = false) -> HeavyWorkPlan
public var priority: TaskPriority   // .run is .utility; every other plan is .background
public var duringCall: Bool         // .behindCall and .wait, as today
public var usesLane: Bool           // .behindCall and .behindApp: one heavy job at a time
// HeavyWorkGate
public init(pollInterval: Duration = .seconds(5), isCallRecording: (@Sendable () async -> Bool)? = nil, worker: Bool = false,
            log: @escaping @Sendable (String) -> Void = { Log.info($0) })
```

With `worker: true` and no call, `plan` is `.behindApp`; with a call it is what it is today. `Pipeline.runHeavy` goes through `heavy.lane` when `plan.usesLane` and writes its "During a call" line only when `plan.duringCall`.

- [ ] **Step 1: Write the failing tests**

```swift
func testAWorkerRunsEachHeavyStepBehindTheAppWhenNoCallRecords() {
    for step in HeavyStep.allCases {
        let plan = HeavyWorkPlan.plan(for: step, callRecording: false, released: false, worker: true)
        XCTAssertEqual(plan, .behindApp, "\(step)")
        XCTAssertEqual(plan.priority, .background)
        XCTAssertTrue(plan.usesLane)
        XCTAssertFalse(plan.duringCall)
    }
}
func testAWorkerFollowsTheForegroundsCallAsItsOwn() {
    for step in HeavyStep.allCases {
        XCTAssertEqual(HeavyWorkPlan.plan(for: step, callRecording: true, released: false, worker: true),
                       HeavyWorkPlan.plan(for: step, callRecording: true, released: false), "\(step)")
    }
}
func testAWorkersGateHoldsAnEncodeWhileTheFlagIsUp() async {
    // A flag in a Mutex, true. gate = HeavyWorkGate(pollInterval: .milliseconds(20), isCallRecording: { flag }, worker: true, log: { _ in })
    // await gate.plan(.uploadEncode, callID: "c") == .wait; .onDeviceTranscription == .wait; .voiceIdentification == .behindCall
    // Set the flag false after 100 ms: await gate.waitForClearance(.uploadEncode, callID: "c") == .behindApp
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter HeavyWorkPlanTests`. Expected: the build fails with "extra argument 'worker' in call".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures (the five existing tests of the file pass unchanged).
- [ ] **Step 4: Commit.** `git commit -m "A worker's heavy steps run one at a time behind the app in front, and wait for a call as the app's own do"`

---

### Task 5: One wiring of the services

The worker needs the transcriber, the model, the summary, the backup, and the sync stores that the app builds from `@AppStorage` values. Two copies of that wiring would drift, and a worker would then transcribe with another model than the window app of the same profile. So the wiring moves to MossadCore and the app calls it. Nothing changes in what the app does.

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/ServiceSettings.swift`, `.../Sync/SyncPass.swift`, `App/CloudEntitlement.swift`
- Modify: `Packages/MossadCore/Sources/MossadCore/Pipeline/Pipeline.swift:1405-1409` (`MissingKeyTranscriber` moves in beside `MissingAPIKey`, public); `.../People/OrgChart.swift` (`titleLines`); `App/AppController.swift:997-1001, 1063-1070, 2231-2238`; `App/AppController+Backup.swift:7-30`; `App/AppController+Sync.swift:27-31, 52-56, 130-159, 225-275`; `App/AppController+Onboarding.swift:79-82`; `App/AppController+Google.swift:221-225`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ServiceSettingsTests.swift`, `SyncPassTests.swift` (new)

**Interfaces:**
- Consumes: `TranscriptionProvider.transcriber(model:apiKey:usage:)`, `AIProvider.model(_:apiKey:usage:serverURL:)`, `LLMSummarizer(llm:ownerName:organization:)`, `BackupSettings`, `BucketArchive`, `ServerArchive`, `CloudArchive(target:places:paths:)`, `CloudKitStore()`, `ServerStore(_:)`, `ServerConnection.address(from:)`, `CloudSync` (`push`, `pull(includeMeetings:)`, `pushShared`, `holds`, `recordingNotices`), `ServerClient.putConfig`, `MCPServer.showsPersonas`, `OnboardingProgress.resume(from:)`.
- Produces:

```swift
public struct ServiceSettings: Equatable, Sendable {
    public enum MissingKey: String, Sendable { case transcription, notes }
    public struct SyncStores { public var main: (key: String, store: any RecordStore)?; public var mirror: (key: String, store: any RecordStore)?
                               public var place: String; public var serverIsMain: Bool }
    // one stored value for each row of the table below
    public static func read(_ defaults: UserDefaults, fullUserName: String) -> ServiceSettings
    public func transcriber(key: (APIKey) -> String?, usage: UsageLog?) -> Transcribing
    public func languageModel(key: (APIKey) -> String?, usage: UsageLog?) -> (any LanguageModel)?
    public func summarizer(key: (APIKey) -> String?, usage: UsageLog?) -> Summarizing?
    public func configuration(key: (APIKey) -> String?, usage: UsageLog?) -> Pipeline.Configuration
    public func serverConnection(key: (APIKey) -> String?) -> ServerConnection?
    public func archive(key: (APIKey) -> String?, paths: Paths) -> CloudArchive?
    public func syncStores(key: (APIKey) -> String?, hasICloud: Bool) -> SyncStores
    public func missingKeys(key: (APIKey) -> String?) -> Set<MissingKey>
    public var personasInMCP: Bool { get }
}
public struct MissingKeyTranscriber: Transcribing { public init(service: String) }
extension OrgChart { public static func titleLines(for names: [String], paths: Paths, library: VoiceLibrary) -> [String] }
public enum SyncPass {
    public struct Inputs: Sendable {
        public var main: CloudSync?, mirror: CloudSync?
        public var serverIsMain: Bool, place: String
        public var connection: ServerConnection?
        public var owner: String, personasInMCP: Bool
        public var personas: SyncedPersonas?
        public var calling: Bool
        public var callStarted: @Sendable () -> Bool
        public var makeDigest: (@Sendable () -> [SharedPayload]?)?     // nil: no digest in this pass
    }
    public struct Result: Sendable {
        public var received = 0
        public var failure: Error?
        public var waiting: [PendingRecording] = []
        public var digest: [SharedPayload]?
        public var digestArrived = false
    }
    public static func run(_ inputs: Inputs) async -> Result
}
// App/CloudEntitlement.swift
enum CloudEntitlement { static let hasCloudKit: Bool }     // the body of AppController.hasICloud, which now returns this
```

The settings, with the same keys and defaults as the `@AppStorage` lines of `AppController.swift:116-131, 469-543`:

| Value | Key | When not set |
| --- | --- | --- |
| `ownerName` | `ownerName` | `fullUserName`, also when blank |
| `organization` | `organization` | "" (trimmed) |
| `voiceFingerprints` | `voiceFingerprints` | true |
| `transcriptionProvider`, `transcriptionModel` | the same names | `.assemblyai`, "" |
| `aiProvider`, `aiModel`, `localServerURL` | the same names | `.anthropic`, "", `LocalServer.ollama.absoluteString` |
| `syncWith` | `syncWith` | `.icloud`; `.off` when `iCloudSync` is false (`AppController.swift:619-621`) |
| `serverAddress`, `serverID`, `serverRecordingLimit` | the same names | "", "", 0 |
| `backup: BackupSettings` | `storage`, `cloudBucketKind`, `cloudEndpoint`, `cloudBucket`, `cloudRegion`, `cloudAccessKeyID` | "local", "", "", "", "us-east-1", "" |
| `coachEnabled`, `coachSince` | the same names | false, 0 |
| `personaEnabled`, `personaInMCP`, `personaSince` | the same names | true, true, 0 |
| `commitmentsSince` | `commitmentsSince` | 0 |
| `calendarIDs: [String]?` | `calendarIDs` | nil (never chosen) |
| `googleScopes: Set<GoogleScope>` | `googleScopes` | every scope |
| `ownerEmail`, `notDuplicates` | `ownerEmail`, `peopleNotDuplicates` (one for each line) | "", [] |
| `setupDone` | `welcomeDone`, or `completed` of `OnboardingProgress.resume(from:)` for the data at `onboardingProgress` (`AppController+Onboarding.swift:79-82`) | false |

Each factory is the expression the app has today, moved: `transcriber` and `summarizer` from `AppController.swift:1063-1070`, `languageModel` from `:997-1001`, `archive` from `AppController+Backup.swift:20-30` (with `serverKeepsRecordings` as `:16`), `serverConnection` from `AppController+Sync.swift:54-55`, `syncStores` from `:130-159` (the keys "icloud" and "server:<address>"; the app keeps its two cached engines and makes a `CloudSync` when a key changes). `missingKeys`: `.transcription` when the provider has a key and the Keychain has none; `.notes` when `languageModel` is nil.

`SyncPass.run` is the body of the detached task of `syncNow` (`AppController+Sync.swift:226-275`), in the same order: for a `main`, `push`, `pull(includeMeetings: false)`, `pushShared(people: true, personas:, stop:, digest:)` with the digest only when the server is the main store, `putConfig(syncedAt:)` then, `recordingNotices`; for a `mirror`, `push`, and only when not `calling`, `pushShared(mirror: true, ...)` and `putConfig(syncedAt:)`; last, `holds(digest)`. It logs the lines it logs today. It touches no view.

- [ ] **Step 1: Write the failing tests**

```swift
// ServiceSettingsTests. Settings: UserDefaults(suiteName: "service-settings-\(UUID().uuidString)"), removed in tearDown.
func testAnEmptyProfileReadsTheAppsDefaults() {
    let s = ServiceSettings.read(empty, fullUserName: "Avery Webb")
    XCTAssertEqual(s.ownerName, "Avery Webb"); XCTAssertEqual(s.transcriptionProvider, .assemblyai); XCTAssertEqual(s.aiProvider, .anthropic)
    XCTAssertEqual(s.syncWith, .icloud); XCTAssertEqual(s.backup, BackupSettings(choice: "local", region: "us-east-1"))
    XCTAssertTrue(s.voiceFingerprints); XCTAssertFalse(s.coachEnabled); XCTAssertTrue(s.personaEnabled); XCTAssertTrue(s.personaInMCP)
    XCTAssertEqual(s.localServerURL, LocalServer.ollama.absoluteString); XCTAssertNil(s.calendarIDs)
    XCTAssertEqual(s.googleScopes, Set(GoogleScope.allCases)); XCTAssertFalse(s.setupDone)
}
func testEachKeyIsRead()   // set every key of the table to a value that is not its default; each field has it. `iCloudSync` false with no `syncWith` is .off.
func testWithNoKeyTheTranscriberWaitsForAKey() async {
    let s = ServiceSettings.read(empty, fullUserName: "Avery Webb")
    do { _ = try await s.transcriber(key: { _ in nil }, usage: nil).transcribe(file: file, track: .me, progress: { _ in }); XCTFail() }
    catch { XCTAssertTrue(error is MissingAPIKey) }
    XCTAssertNil(s.languageModel(key: { _ in nil }, usage: nil))
    XCTAssertEqual(s.missingKeys(key: { _ in nil }), [.transcription, .notes])
    XCTAssertEqual(s.missingKeys(key: { _ in "k" }), [])
}
func testTheStoresFollowTheSyncChoice() {
    // .icloud with hasICloud: main key "icloud", no mirror, place "iCloud". With a server address and secret too: a mirror.
    // .icloud without hasICloud: no main. .server with address "https://notes.example.com" and a secret: main key
    // "server:https://notes.example.com", serverIsMain, place "your server". .off: no main and no mirror.
}
// SyncPassTests, with `MemoryStore` of RecordStoreTests and a temp `Paths`:
func testAPassSendsAndTakesAndNeverPullsMeetings() async   // one written meeting on disk; after run the store has its record, failure is nil, received is 0
func testAMirrorAloneOnlyPushes() async                     // main nil, mirror set: the store has the meeting; nothing was pulled
func testAStoreThatFailsIsAFailureInTheResult() async       // a store whose `changes` throws: failure is not nil, the pass returns
func testNoDigestIsMadeWithoutAServerAsMain() async         // makeDigest counts its calls: 0 with serverIsMain false and no mirror
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter "ServiceSettingsTests|SyncPassTests"`. Expected: the build fails with "cannot find 'ServiceSettings' in scope".
- [ ] **Step 3: Write `ServiceSettings.swift`, `SyncPass.swift`, `MissingKeyTranscriber`, and `OrgChart.titleLines`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: The app calls them.** `AppController` gets `var services: ServiceSettings { .read(.standard, fullUserName: NSFullUserName()) }`. `languageModel`, `cloudArchive`, `serverConnection` (the `ServerSample` line stays first), `currentSync`, `mirrorSync`, `onboardingFinished`, and the transcriber and the summarizer of `rebuildPipeline` return what the factories give, with `key: { keychain.get($0) }`. `syncNow` builds `SyncPass.Inputs` where its detached task starts and reads the `Result` in its `MainActor.run` block, which stays as it is. `AppController.hasICloud` returns `CloudEntitlement.hasCloudKit`; `AppController.titleLines` returns `OrgChart.titleLines`. The `@AppStorage` properties stay: the views bind to them. Delete the struct at `AppController.swift:2231-2238`.
- [ ] **Step 5: Run the build check.** Expected: exit status 0. Then read the diff of `AppController+Sync.swift` beside `SyncPass.swift`: each call of the old body is in the new one, in the same order.
- [ ] **Step 6: Commit.** `git commit -m "The services of a profile are built by one piece of code, which the app uses now and a worker will"`

---

### Task 6: The calendar in a worker

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/WorkerCalendar.swift`
- Modify: `.../Calendar/CalendarMatcher.swift:201-203`; `.../Records/CallRecord.swift` (one optional field beside `failureReason`, `:224`, and its line in `init(from:)`, `:379`); `.../Pipeline/Pipeline.swift:822-828` and one new public function; `App/AppController.swift` (one call in `finishLaunch`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/WorkerCalendarTests.swift` (new), `PipelineTests.swift` (new methods)

**Interfaces:**
- Consumes: `EventKitCalendarSource` (`choose`, `events`), `GoogleCalendarSource`, `MergedCalendarSource` (`lastGoogleRead`), `CalendarSnapshot.Access.Read` (`.macCalendar`), `GoogleSession(secrets:chosen:)`.
- Produces:

```swift
public protocol CalendarSource: Sendable {
    func events(from: Date, to: Date) async -> [CalendarEventInfo]
    /// False when a calendar that this source should read could not be read: then "no event" is not known.
    func canRead() async -> Bool
}
extension CalendarSource { public func canRead() async -> Bool { true } }
// CallRecord
public var inviteUnknown: Bool?      // the calendar could not be read when the invite was looked for; never written as false
// Pipeline
/// Looks again for the invite of each written meeting marked `inviteUnknown` that ended in the last `days` days. Returns how many it matched.
public func matchUnknownInvites(newerThan days: Int = 30) async -> Int
public final class WorkerCalendar: CalendarSource, @unchecked Sendable {
    public enum Mac: Equatable, Sendable { case readable, none, unknown }
    public static func mac(authorized: Bool, chosen: [String]?, madeUpRegistry: Bool) -> Mac
    public static func known(mac: Mac, google: CalendarSnapshot.Access.Read) -> Bool
    public init(mac: Mac, macSource: CalendarSource, google: GoogleCalendarSource?)
    public func events(from: Date, to: Date) async -> [CalendarEventInfo]
    public func canRead() async -> Bool
}
```

Rules. `mac`: `.unknown` on a made-up registry, with no permission, or with `chosen` nil; `.none` with `chosen` empty (the owner chose no Mac calendar: nothing to read, and that is known); else `.readable`. `known` is false when `mac` is `.unknown` or `google` is `.failed`. `WorkerCalendar.events` is a `MergedCalendarSource` of the Mac's source (asked only when `.readable`) and Google; `canRead` is `known` with that merge's `lastGoogleRead`. The object goes to `Pipeline(calendar:)` and to nothing else. It never calls `requestAccess`.

`matchInvite`: with no match, `r.inviteUnknown = true` when `canRead()` is false, else nil; with a match, nil. `matchUnknownInvites`: nothing when `canRead()` is false; else for each marked meeting, a match sets the invite (`setInvite`), clears the mark, and writes the note again through `edit` and `save`, as `setTitle` does (`:1275-1279`); no match only clears the mark. The summary and the names of the voices stay.

The window app calls `matchUnknownInvites()` once in `finishLaunch`, in full mode, only when `CalendarSnapshot.Access.Read.macCalendar == .yes || google.has(.calendar)`, then `refresh()` when the count is above 0.

- [ ] **Step 1: Write the failing tests**

```swift
func testAWorkerReadsTheMacsCalendarsOnlyWithPermissionAndAChoice() {
    XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: ["a"], madeUpRegistry: false), .readable)
    XCTAssertEqual(WorkerCalendar.mac(authorized: false, chosen: ["a"], madeUpRegistry: false), .unknown)
    XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: nil, madeUpRegistry: false), .unknown)   // never chosen: every calendar would come in
    XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: [], madeUpRegistry: false), .none)
    XCTAssertEqual(WorkerCalendar.mac(authorized: true, chosen: ["a"], madeUpRegistry: true), .unknown)
}
func testUnknownIsNotNoInvite() {
    for (mac, google, known) in [(WorkerCalendar.Mac.readable, CalendarSnapshot.Access.Read.yes, true), (.readable, .no, true), (.none, .no, true),
                                 (.none, .yes, true), (.readable, .failed, false), (.unknown, .yes, false), (.unknown, .no, false)] {
        XCTAssertEqual(WorkerCalendar.known(mac: mac, google: google), known)
    }
}
func testAnUnreadableMacCalendarIsNeverAsked() async {
    // macSource counts its calls. WorkerCalendar(mac: .unknown, macSource: counting, google: nil):
    // events(from:to:) is [], the count is 0, canRead() is false. With mac: .readable the count is 1 and canRead() is true.
}
// PipelineTests, with a calendar fake that has `events` and `readable`:
func testAMeetingFinishedWithAnUnreadableCalendarIsMarkedAndStillWritten() async {
    // events [], readable false: after runPending the record is .written, inviteUnknown is true, and its speaker names
    // are the ones the same call gets with FakeCalendar() (no invite).
}
func testTheNextActiveLaunchMatchesAMarkedMeeting() async {
    // The same folder, a new Pipeline whose calendar has the event "Budget review" with Alex Rivera and Sam Carter at the call's time:
    // matchUnknownInvites() is 1; calendarTitle is "Budget review"; attendees are the two names; inviteUnknown is nil;
    // the summary is the one from before; a note named "… - Budget review.md" exists. A second call returns 0.
}
func testAReadableCalendarNeverMarksAMeeting() async {
    // FakeCalendar() (canRead is true by default): inviteUnknown is nil, and call.json has no "inviteUnknown" key.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter "WorkerCalendarTests|PipelineTests"`. Expected: the build fails with "cannot find 'WorkerCalendar' in scope".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: The one call in `finishLaunch`, and the build check.** Expected: exit status 0.
- [ ] **Step 5: Commit.** `git commit -m "A calendar that could not be read is unknown, not empty: the meeting is finished and marked, and its invite is found when its profile is next active"`

---

### Task 7: The status file and its line

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/WorkerStatus.swift`
- Modify: `.../Support/Paths.swift` (one line: `worker` is `root/Worker`; not in `ensureDirectories`); `.../Profiles/ProfileRules.swift:101-139` (`ProfileMenu`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/WorkerStatusTests.swift` (new), `ProfileRulesTests.swift` (one new method)

**Interfaces:**
- Consumes: `CallRecord` (`status`, `attempts`, `failedStep`, `end`), `ProcessingStep(status:)`, `UsageStats.Step(failedAt:)`, `ServiceSettings.MissingKey`.
- Produces:

```swift
public struct WorkerStatus: Codable, Equatable, Sendable {
    public static let fileName = "status.json", currentVersion = 1
    public static let allowedKeys: Set<String> = ["version", "written", "inWork", "failure", "kind", "count"]
    public enum Kind: String, Codable, CaseIterable, Sendable { case key, transcribe, identify, summarize, write, backup, sync }
    public struct Failure: Codable, Equatable, Sendable { public var kind: Kind; public var count: Int }
    public var version: Int, written: Date, inWork: Int, failure: Failure?
    public static func make(records: [CallRecord], missing: Set<ServiceSettings.MissingKey>, backupFailed: Int, syncFailed: Bool, now: Date) -> WorkerStatus
    public static func url(root: URL) -> URL                 // <root>/Worker/status.json
    public static func peek(root: URL) -> WorkerStatus?      // nil: no file, not readable, or a newer version. It reads this one file.
    public func save(root: URL) throws                       // one atomic write; makes <root>/Worker
}
public enum WorkerStatusLine {
    public static func text(_ status: WorkerStatus?, running: Bool, gaveUp: Bool) -> String?
}
// ProfileMenu
public struct Row { ...; public let status: String?
    public init(id: String, name: String, color: ProfileColor, active: Bool, status: String? = nil) }
public init?(_ registry: ProfileRegistry, active: String, recording: Bool, status: [String: String] = [:])   // by profile id; never for the active row
```

`make`. `inWork` is the count of records with a `ProcessingStep` (recorded, transcribed, identified, summarized). `failure` is the first of these that applies: (1) `key`: the count of records at `recorded` when `.transcription` is missing plus the records at `identified` when `.notes` is missing, when above 0; (2) the meetings that fail: a record in work with `attempts` above 0 (kind from `UsageStats.Step(failedAt: status)`), or a record with status `failed`, a `failedStep`, and an `end` in the last 7 days (kind from `failedStep`); the kind is the one of the newest such record by `end`, the count is the records of that kind; (3) `backup` with `backupFailed` when above 0; (4) `sync` with count 0 when `syncFailed`.

The lines of `text`: "Not running" when `gaveUp`; nil when not `running` or with no status; else by the failure: `key` "1 meeting waits for a key" / "2 meetings wait for a key"; `transcribe` "Could not transcribe 1 meeting" / "… 2 meetings"; `identify` "Could not name the voices of 1 meeting" / "… of 2 meetings"; `summarize` "Could not summarize 1 meeting" / "… 2 meetings"; `write` "Could not write the note of 1 meeting" / "Could not write the notes of 2 meetings"; `backup` "Could not back up 1 recording" / "… 2 recordings"; `sync` "Could not sync"; with no failure, "1 meeting in work" / "2 meetings in work" when `inWork` is above 0; else nil.

- [ ] **Step 1: Write the failing tests**

```swift
func testTheStatusCountsMeetingsInWorkAndNamesTheNewestFailure()
    // records: 2 at .recorded (one with attempts 2, ended 2 hours ago), 1 at .identified, 3 at .written,
    // 1 .failed with failedStep .transcribed that ended yesterday, 1 .failed that ended 30 days ago.
    // missing []: inWork 3; failure is Failure(kind: .transcribe, count: 1), the newest failing record's kind. Without that record's
    // attempts: Failure(kind: .identify, count: 1), from the meeting that failed yesterday; the one of 30 days ago never counts.
    // missing [.transcription]: failure is Failure(kind: .key, count: 2). missing [.notes]: Failure(kind: .key, count: 1).
    // No failing record, backupFailed 2: Failure(kind: .backup, count: 2). Only syncFailed: Failure(kind: .sync, count: 0). Nothing: failure nil.
func testTheStatusFileHoldsCountsAndAKindOnly() throws {
    // A record titled "Budget review" with the speaker "Sam Carter" and an invitee address. Encode make(...) and read the JSON:
    // every key at every level is in WorkerStatus.allowedKeys, and the text has no "Budget", "Sam", or "@".
}
func testTheLineOfEachState() {
    func line(_ inWork: Int, _ f: WorkerStatus.Failure?, running: Bool = true, gaveUp: Bool = false) -> String? { /* text(...) of that status */ }
    XCTAssertNil(line(0, nil)); XCTAssertEqual(line(1, nil), "1 meeting in work"); XCTAssertEqual(line(2, nil), "2 meetings in work")
    XCTAssertEqual(line(3, .init(kind: .transcribe, count: 1)), "Could not transcribe 1 meeting")
    XCTAssertEqual(line(3, .init(kind: .key, count: 2)), "2 meetings wait for a key")
    XCTAssertEqual(line(0, .init(kind: .sync, count: 0)), "Could not sync")
    XCTAssertEqual(line(0, .init(kind: .write, count: 2)), "Could not write the notes of 2 meetings")
    XCTAssertNil(line(2, nil, running: false)); XCTAssertEqual(line(2, nil, running: false, gaveUp: true), "Not running")
    XCTAssertNil(WorkerStatusLine.text(nil, running: true, gaveUp: false))
}
func testTheFileIsReadOnlyWhenThisBuildKnowsIt() throws   // save then peek is equal; "version": 2 is nil; no file is nil; the file is <root>/Worker/status.json
// ProfileRulesTests
func testTheSwitcherShowsTheLineOfAnotherProfileOnly() {
    // registry of default and 1a2b3c4d, active default, status ["1a2b3c4d": "2 meetings in work", "default": "x"]:
    // rows[0].status is nil (active), rows[1].status is "2 meetings in work". With no status argument, both are nil.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter "WorkerStatusTests|ProfileRulesTests"`. Expected: the build fails with "cannot find 'WorkerStatus' in scope".
- [ ] **Step 3: Write the code.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "A worker's status is counts and one kind of failure, and the switcher's line is made from it"`

---

### Task 8: The worker's run

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Worker/ProfileWorker.swift`, `.../Worker/WorkerPace.swift`
- Modify: `.../Worker/WorkerLaunch.swift` (two functions); `App/WorkerEntry.swift` (the real start)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileWorkerTests.swift`, `WorkerPaceTests.swift`, `WorkerSourceTests.swift` (new); `WorkerLaunchTests.swift` (new methods)

**Interfaces:**
- Consumes: everything Tasks 2 to 7 produce; `ProcessingQueue` (`recoverInterrupted`, `allRecords`, `scan`), `Pipeline` (`init` with `heavy:`, `runPending`, `continueSplitMeetings`, `refreshLabels`), `VoiceLibrary(directory:)`, `FluidEmbeddingProvider()`, `ScreenStep(reader: VisionScreenReader())`, `PeopleMigration.runAtLaunch`, `OrgMatches.linkPeople`, `PersonReferences`, `ReferenceBackup.keep`, `CommitmentBook`, `CoachProfile` (`linkPeople`, `forget`), `CoachPeople`, `Recording.missing` and `makeIfMissing`, `CloudArchive.sync` and `rememberDeletes`, `ShareBook.markStopping(callID:)`, `PersonaStore.forget`, `CoachRunner`, `LLMCoach`, `PersonaExtractor.model`, `PersonaBacklog.run`, `PersonaRunner`, `CommitmentRunner`, `CommitmentFinder`, `NextTimeRunner`, `NextTimeChecker`, `CalendarSnapshot.load`, `UpcomingMeeting.from`, `SeriesCatalog.aliases`, `PersonDirectory`, `ChatTools`, `ServerDigest.parts`, `DigestCache`, `DigestPlan`, `MeetingFactsCache`, `GoogleDirectoryCache.load`, `UsageLog`, `InstanceLock.acquire`, `Onboarding.opensAtLaunch`.
- Produces:

```swift
// WorkerLaunch
public static func afterLock(_ attempt: InstanceLock.Attempt) -> Exit?        // nil only for .held
public static func setupDone(finished: Bool, hasMeetings: Bool) -> Bool       // !Onboarding.opensAtLaunch(...)
public struct WorkerPace: Equatable, Sendable {
    public enum Work: Equatable, Sendable { case queue, sync }
    public static let syncEvery: TimeInterval = 300, queueEvery: TimeInterval = 3600, syncMost: TimeInterval = 3600, callLook: TimeInterval = 5
    public var lastSync: Date?, lastQueue: Date?, syncFailures = 0
    public init()
    public static func syncWait(failures: Int) -> TimeInterval          // 300 × 2^failures, 3600 at most
    public func due(now: Date, callRecords: Bool) -> (work: [Work], sleep: TimeInterval)
    public mutating func synced(ok: Bool, at: Date)
    public mutating func queued(at: Date)
}
public actor ProfileWorker {
    public struct Setup: Sendable {
        public var paths: Paths
        public var settings: ServiceSettings
        public var key: @Sendable (APIKey) -> String?
        public var google: any GoogleSecrets
        public var remember: @Sendable (String, Double) -> Void        // a setting the worker saves: "personaSince", "commitmentsSince"
        public var hasICloud: Bool
        public var madeUpRegistry: Bool
        public var macCalendarAuthorized: @Sendable () -> Bool
        public var callRecords: @Sendable () -> Bool
        public var now: @Sendable () -> Date
    }
    public struct Services: Sendable {                                  // a test gives fakes; the worker builds them from `settings`
        public var transcriber: Transcribing, summarizer: Summarizing?, embeddings: EmbeddingProvider, calendar: CalendarSource
        public var llm: (any LanguageModel)?, main: CloudSync?, mirror: CloudSync?, archive: CloudArchive?
    }
    public struct Pass: Equatable, Sendable { public var ran: Set<Duty>; public var changed: Bool; public var received: Int }
    public init(_ setup: Setup, services: Services? = nil)
    public func start() async -> Set<Duty>      // recover, then the people store
    public func pass(_ work: [WorkerPace.Work]) async -> Pass
    public func run() async                      // start, then passes by WorkerPace, for the life of the process
}
```

`due`: `queue` is due when `lastQueue` is nil or 3600 s old; `sync` is due when no call records and `lastSync` is nil or `syncWait(failures:)` old; `sleep` is the time to the next of the two, 1 s at least, and 5 s when a sync is due but a call records. A pass that changed something makes the sync due at once.

Every duty asks `RunMode.worker.runs(duty, madeUpRegistry:)` first. `Pass.ran` holds the duties that were allowed and that the pass started. A pass with `.queue` runs the queue, the backup, the coach, the personas, the commitments, and the next-time check; a pass with `.sync` runs the sync, and the `.queue` duties one more time when the sync received something. The status file ends each pass. What each duty is, in the order of a pass:

| Duty | What the worker does | The app's code it mirrors |
| --- | --- | --- |
| `recover` (in `start`) | `ProcessingQueue.recoverInterrupted()`, then `pipeline.continueSplitMeetings()` | `AppController.swift:824`, `:875` |
| `people` (in `start`) | `PeopleMigration.runAtLaunch` into `library.identity`; `pipeline.refreshLabels()`; `OrgMatches.linkPeople`; the commitment book's ids; with the coach on, `CoachProfile.linkPeople` | `:1012-1047`, `AppController+Commitments.swift:42-49`, `AppController+Findings.swift:123-133` |
| `queue` | `pipeline.runPending()` | `:2042` |
| `backup` | Not while a call records: `Recording.makeIfMissing` for each of `Recording.missing`, a look at `callRecords` before each. Then `archive.sync(keepLocalDays: nil, pipeline:)` | `:2047-2066`, `:1782` |
| `coach` | With the coach on and a model: `CoachRunner(paths:coach:owner:since:titles:facts:).run` | `AppController+Coach.swift:53-57` |
| `personas` | With the coach and the reads on, no call recording: `PersonaBacklog.run(... callsPerRound: 10, isLive: callRecords)`; a `personaSince` of 0 is set to now through `remember` | `AppController+Personas.swift:82-95` |
| `commitments` | With a model: `CommitmentRunner.run`; a `commitmentsSince` of 0 is set to 14 days back through `remember` | `AppController+Commitments.swift:11-25` |
| `nextTime` | No call recording, a model, and an open point: `NextTimeRunner.run` with the upcoming meetings and the aliases of `CalendarSnapshot.load(from: paths.calendar)` (none without it), `recording: callRecords` | `AppController+Series.swift:205-225` |
| `sync`, `digest`, `serverConfig` | No call recording: `SyncPass.run` with `personas: nil`, the digest by `DigestPlan` (the worker's own count of changes as the three versions; `sent` and `pending` in the actor), and `putConfig` once in a run when a server is connected. With no main store, `CloudSync.nothingToMerge`. When it received something: one more `queue` | `AppController+Sync.swift:174-312` |
| `statusFile` | `WorkerStatus.make(...).save(root:)` after `start`, after each save of a record (the pipeline's `onStep`), and after each pass | new |

The pipeline is made once: `notify`, `onDetail`, `onProgress`, and `onFailure` do nothing; `onStep` writes the status; `heavy` is `HeavyWorkGate(isCallRecording: callRecords, worker: true)`; `calendar` is the `WorkerCalendar` of Task 6 (`mac` from `macCalendarAuthorized`, `settings.calendarIDs`, and `madeUpRegistry`; `EventKitCalendarSource` with `choose(Set(calendarIDs))`; Google through `GoogleSession(secrets: google, chosen: settings.googleScopes)` and the names of `GoogleDirectoryCache.load`), or the test's `Services.calendar`; where `inviteMatch` does not run (a made-up registry), the pipeline gets `WorkerCalendar(mac: .unknown, macSource: <that source>, google: nil)`, which asks nothing and says that it cannot read; `titles` is `OrgChart.titleLines`; `onDiscard` does the four parts of `AppController.forget` (`AppController.swift:1104-1123`) without the views: the backup copy (`archive.delete`, else `CloudArchive.rememberDeletes`), `ShareBook.markStopping(callID:)` and its save, `CoachProfile.forget(callID:)`, `PersonaStore.forget(callID:)`.

`run()` logs, with ids and counts only: "Worker: started for <profile id>", "Worker: Mac calendars: readable", "… not readable (<permissionName>)", "… none chosen", or "… not chosen yet", and one line for each pass that did something.

- [ ] **Step 1: Write the failing tests**

```swift
// WorkerPaceTests
func testTheSyncWaitGrowsToAnHour() {
    XCTAssertEqual([0, 1, 2, 3, 4, 9].map(WorkerPace.syncWait), [300, 600, 1200, 2400, 3600, 3600])
}
func testWhatIsDue() {
    var pace = WorkerPace(); let t = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(pace.due(now: t, callRecords: false).work, [.queue, .sync])
    XCTAssertEqual(pace.due(now: t, callRecords: true).work, [.queue])                      // no sync while a call records
    pace.queued(at: t); pace.synced(ok: true, at: t)
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(299), callRecords: false).work, [])
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(299), callRecords: false).sleep, 1)
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(10), callRecords: false).sleep, 290)
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(300), callRecords: false).work, [.sync])
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(300), callRecords: true).sleep, 5)
    pace.synced(ok: false, at: t); pace.synced(ok: false, at: t)
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(1199), callRecords: false).work, [])
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(1200), callRecords: false).work, [.sync])
    XCTAssertEqual(pace.due(now: t.addingTimeInterval(3600), callRecords: false).work, [.queue, .sync])
}
// WorkerLaunchTests
func testAWorkerNeverRunsWithoutItsFolderLock() throws {
    let dir = /* a temp folder */, other = /* a second temp folder; both exist */
    guard case .held(let first) = InstanceLock.acquire(root: dir) else { return XCTFail() }
    XCTAssertEqual(WorkerLaunch.afterLock(InstanceLock.acquire(root: dir)), .lockNotHeld)   // the window app has it
    XCTAssertEqual(WorkerLaunch.afterLock(.failed(EACCES)), .lockNotHeld)                   // the window app goes on here; a worker never does
    withExtendedLifetime(first) {}
    XCTAssertNil(WorkerLaunch.afterLock(InstanceLock.acquire(root: other)))
}
func testAProfileThatWouldOpenSetupGetsNoWorker() {
    XCTAssertFalse(WorkerLaunch.setupDone(finished: false, hasMeetings: false))
    XCTAssertTrue(WorkerLaunch.setupDone(finished: true, hasMeetings: false))
    XCTAssertTrue(WorkerLaunch.setupDone(finished: false, hasMeetings: true))
}
// ProfileWorkerTests: a temp `Paths`, one recorded call made as PipelineTests makes one, the fakes of PipelineTests, a MemoryStore.
func testAPassMovesARecordedCallToWrittenAndWritesTheStatus() async {
    // start() is [.recover, .people]. pass([.queue, .sync]): the record is .written; ran has .queue, .sync, and .statusFile;
    // WorkerStatus.peek(root:) has inWork 0 and no failure; the store has the meeting.
}
func testWithNoKeyTheCallStaysAndTheStatusNamesTheKind() async {
    // transcriber MissingKeyTranscriber(service: "AssemblyAI"), settings with no key: the record stays .recorded with attempts 0;
    // the status is inWork 1, failure Failure(kind: .key, count: 1).
}
func testWhileACallRecordsTheWorkerDoesNotSyncOrEncode() async {
    // callRecords true, a call at .identified: after pass([.queue, .sync]) the record is .written, no recording.m4a is in its folder,
    // ran has no .sync and no .backup, and the store got nothing.
}
func testOnAMadeUpRegistryNothingLeavesTheFolder() async {
    // madeUpRegistry true: start() and a pass run only duties of [.recover, .people, .queue, .statusFile]; the store, the archive,
    // and the calendar fake (which counts) were never called.
}
func testAWorkerDoesOnlyWhatTheTableSays() async {
    // With everything set up (coach on, a model, a store): every duty in start() and in the pass's `ran` has RunMode.worker.does(duty).
}
// WorkerSourceTests: reads the sources beside this test file (`#filePath`).
func testTheWorkersCodeCannotAskPostOrShow() throws {
    // No file of Sources/MossadCore/Worker has: "import AppKit", "UserNotifications", "ServiceManagement", "Sparkle", "requestAccess",
    // "requestFullAccess", "requestAuthorization", "NSApplication", "WeeklyEmail", "Retention.sweep", "GeminiRunner",
    // "CalendarSnapshot.write", "UsageReportPlan", "SharedAIKey", "ServerPairing.share".
    // App/WorkerEntry.swift has none of them, and no "AppController" and no "Notifier".
}
func testTheCalendarIsReadOnlyToMatchAnInvite() throws {
    // In Sources/MossadCore/Worker, ".events(from:" is only in WorkerCalendar.swift.
    // In Pipeline.swift, "calendar.events(" is on one line, inside matchInvite; "calendar.canRead()" is only in matchInvite and matchUnknownInvites.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter "ProfileWorkerTests|WorkerPaceTests|WorkerSourceTests|WorkerLaunchTests"`. Expected: the build fails with "cannot find 'ProfileWorker' in scope".
- [ ] **Step 3: Write `WorkerPace.swift`, the two functions of `WorkerLaunch`, and `ProfileWorker.swift`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: The real start in `App/WorkerEntry.swift`**, in place of Task 1's line (3), in this order:
  1. `let file = ForegroundState.url(home:environment:)`; a `ForegroundWatcher(file:)` whose `onStop` logs "Worker: stops (<reason>)", calls `Log.flush()`, and `exit(0)`. `first()` is a stop: "Mossad: no foreground app; the worker does not start." on stderr, `exit(3)`. Nothing of the data folder is touched before this.
  2. `WorkerLaunch.afterLock(InstanceLock.acquire(root: Paths.live.root))`: an exit code is "Mossad: this profile is open in another copy; the worker does not start." and that code. Keep the lock for the life of the process.
  3. `try? Paths.live.ensureDirectories()`; `Log.directory = Paths.live.logs`; `_ = NetworkPath.shared`.
  4. In a debug build, on a made-up registry, with `MOSSAD_PROOF_CALL=<file>` and no folder in `Audio`: `PhoneRecording.importAudio(file, recording: PhoneRecording(id: CallID.make(start), start: start, end: start + the file's length, title: nil), into: .live)` with `start` two hours ago.
  5. `let settings = ServiceSettings.read(.standard, fullUserName: NSFullUserName())`. `WorkerLaunch.setupDone(finished: settings.setupDone, hasMeetings: <Audio has a folder>)` false: log "Worker: setup is not finished", `exit(5)`.
  6. `watcher.start()`. `ProfileWorker(Setup(paths: .live, settings:, key: { Keychain.app.get($0) }, google: Keychain.app, remember: { UserDefaults.standard.set($1, forKey: $0) }, hasICloud: CloudEntitlement.hasCloudKit, madeUpRegistry: identity.madeUpRegistry, macCalendarAuthorized: { CalendarSnapshot.Access.Read.macCalendar == .yes }, callRecords: { watcher.callRecords }, now: Date.init))`. `Task { await worker.run() }`, then `dispatchMain()`.
- [ ] **Step 5: Run the build check.** Expected: exit status 0.
- [ ] **Step 6: Proof runs 1, 4, and 2** (under "Proof runs"; one worker serves the three)

```sh
say -o "$P/call.aiff" "This is a made-up call for a proof. One, two, three, four, five, six, seven, eight, nine, ten."
sleep 80 & FG=$!; fg $FG true false
MOSSAD_PROOF_CALL="$P/call.aiff" "$APP" --profile feedc0de --worker & W=$!
sleep 12; grep -c "the upload encode of .* waits until it ends" "$R/Logs/mossad.log"
fg $FG false false; sleep 15
grep -c "waits for an API key" "$R/Logs/mossad.log"; cat "$R/Worker/status.json"; echo; ls "$P"
START=$(date +%s); kill $W; wait $W; echo "worker exit $? after $(( $(date +%s) - START )) s"; kill $FG
```

Expected, in order: `1` (proof 4: the flag held the encode); a count of 1 or more (proof 1: the call went as far as it can with no key); a status with `"inWork":1` and `"failure":{"count":1,"kind":"key"}` and no other key than the allowed ones; `ls` shows only `Mossad Proof`, `call.aiff`, `foreground.json`, `profiles.json` (the worker wrote in its own folder only); `worker exit 0 after 0 s` or `1 s` (proof 2). The first line of the log names the profile `feedc0de`, and the log has "Mac calendars: not readable" or "not chosen yet", never "readable".

- [ ] **Step 7: Proof run 3 and the stop by the file**

```sh
sleep 80 & FG=$!; fg $FG false false
"$APP" --profile feedc0de --worker & W=$!; sleep 5
START=$(date +%s); kill $FG; wait $W; echo "worker exit $? after $(( $(date +%s) - START )) s"
grep -c "Worker: stops (foregroundGone)" "$R/Logs/mossad.log"
sleep 80 & FG=$!; fg $FG false false
"$APP" --profile feedc0de --worker & W=$!; sleep 5
START=$(date +%s); fg $FG false true; wait $W; echo "worker exit $? after $(( $(date +%s) - START )) s"; kill $FG
rm "$P/foreground.json"; "$APP" --profile feedc0de --worker; echo "exit $?"
```

Expected: `worker exit 0 after` 3 s or less (the stale file ended it by itself); `1`; `worker exit 0 after` 3 s or less (the file said stop); `Mossad: no foreground app; the worker does not start.` and `exit 3`. If a `wait` does not return in 20 s, end that worker by its pid, stop, and report. Then clean up.

- [ ] **Step 8: Commit.** `git commit -m "A worker finishes its profile's meetings, syncs, and backs up with no window, and ends when the foreground app is gone or says stop"`

---

### Task 9: The foreground app starts, tells, and stops its workers

**Files:**
- Create: `App/WorkerManager.swift`
- Modify: `Packages/MossadCore/Sources/MossadCore/Worker/WorkerLaunch.swift` (three functions); `App/AppController.swift:79, 398, 605, 675-687, 824, 864-890, 1036, 1766, 2041, 2048, 2071-2076, 2165-2167`; `App/AppController+Sync.swift:34, 175`; `App/AppController+Coach.swift:49, 112`; `App/AppController+Commitments.swift:12, 42`; `App/AppController+Findings.swift:124`; `App/AppController+Series.swift:206`; `App/AppController+Personas.swift:83`; `App/AppController+Google.swift:229, 260, 291`; `App/AppController+Profiles.swift:17, 21`; `App/AppController+UsageStats.swift:10`; `App/MossadApp.swift:237` (the delegate); `scripts/build.sh:52`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/WorkerLaunchTests.swift` (new methods)

**Interfaces:**
- Consumes: `WorkerLaunch.process`, `ForegroundState`, `ProcessFacts.startTime`, `WorkerStatus.peek`, `WorkerStatusLine.text`, `RunMode`, `Duty`, `AppIdentity.otherProfiles`.
- Produces:

```swift
// WorkerLaunch
public static func profiles(_ identity: AppIdentity, mode: RunMode) -> [Profile]     // identity.otherProfiles when mode.does(.startWorkers), else none
public enum Restart: Equatable, Sendable { case after(TimeInterval), never, gaveUp }
public static let restartWaits: [TimeInterval] = [5, 30, 120]
/// `failures`: the failed starts in a row before this exit. A worker that ran 600 s or more makes it 0.
public static func restart(exit: Int32, failures: Int, stopping: Bool) -> Restart
// App/WorkerManager.swift
@MainActor final class WorkerManager {
    init(identity: AppIdentity, mode: RunMode, onLines: @escaping @MainActor ([String: String]) -> Void)
    func start(recording: Bool)                       // the file first, then one child for each profile of WorkerLaunch.profiles
    func setRecording(_ recording: Bool)
    func stopAll(waitingFor id: String, seconds: TimeInterval) async -> Bool   // true when that profile's folder lock is free
    func stop(_ id: String, seconds: TimeInterval) async -> Bool
    func resume(recording: Bool)                      // `stopping` false in the file, and the workers start again
    func quit()                                       // `stopping` in the file and SIGTERM to each child; no wait
}
// AppController
private(set) var mode: RunMode = .inert      // set where `inert` is computed today; `isInert` becomes `mode == .inert`
var workers: WorkerManager!                  // made right after `mode` is set
@Published var workerLines: [String: String] = [:]
```

`restart`: `.never` when `stopping`, or when the exit is 2 or 5; `.after(restartWaits[failures])` while `failures` is under 3; else `.gaveUp`. The manager writes the file through one serial queue, in order, off the main actor; a stop sets `stopping`, calls `terminate()` on the children, and looks at a folder lock with `InstanceLock.waitUntilFree` in a detached task. While a worker runs, the manager reads `WorkerStatus.peek(root:)` of each other profile every 10 s off the main actor (that one file and nothing else of the folder) and gives the lines of `WorkerStatusLine.text` to `onLines` when they change. With no profile to start, `start` writes no file and starts no timer.

- [ ] **Step 1: Write the failing tests**

```swift
func testEachOtherProfileGetsAWorkerAndOnlyFromTheForegroundApp() {
    // registry: default, Work (1a2b3c4d), and one profile with removing true.
    func ids(_ identity: AppIdentity, _ mode: RunMode) -> [String] { WorkerLaunch.profiles(identity, mode: mode).map(\.id) }
    XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: registry()), .full), ["1a2b3c4d"])
    // After a switch the process is Work: the profile that was active gets the worker.
    XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: registry()), .full), ["default"])
    XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "default"], registry: registry()), .inert), [])   // a second copy too
    XCTAssertEqual(ids(AppIdentity(bundleID: main), .full), [])                                                   // one profile: nothing
    XCTAssertEqual(ids(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: registry(), madeUpRegistry: true), .full), [])
    XCTAssertEqual(ids(AppIdentity(bundleID: AppIdentity.rehearsalBundleID, registry: registry()), .full), [])
}
func testAStoppedWorkerIsNotStartedAgain() {
    for code: Int32 in [0, 3, 4, 9, 11] { XCTAssertEqual(WorkerLaunch.restart(exit: code, failures: 0, stopping: true), .never) }
    XCTAssertEqual(WorkerLaunch.restart(exit: 5, failures: 0, stopping: false), .never)     // setup not finished
    XCTAssertEqual(WorkerLaunch.restart(exit: 2, failures: 0, stopping: false), .never)
}
func testAWorkerThatKeepsFailingIsGivenUp() {
    XCTAssertEqual([0, 1, 2, 3, 7].map { WorkerLaunch.restart(exit: 4, failures: $0, stopping: false) },
                   [.after(5), .after(30), .after(120), .gaveUp, .gaveUp])
    XCTAssertEqual(WorkerLaunch.restart(exit: 11, failures: 0, stopping: false), .after(5))   // a crash
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter WorkerLaunchTests`. Expected: the build fails with "type 'WorkerLaunch' has no member 'profiles'".
- [ ] **Step 3: Write the three functions.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Write `App/WorkerManager.swift`.**
- [ ] **Step 5: The app's gates read the table.** In `AppController.init`: `precondition(!WorkerLaunch.isWorker(CommandLine.arguments))` as the first line; `mode = RunMode.decide(...)` where `inert` is computed today (`:675`); `isInert` is `mode == .inert`. The launch blocks at `:686`, `:687`, and `:864` read `mode == .inert` and `mode == .full`, with one comment that names the duties inside (detect, record, hot keys, the login item, the updater, permissions, notifications, usage statistics, the upkeep). Each function below asks the table in place of `isInert`; in the window app the answer is the same as today.

  | Place | Duty |
  | --- | --- |
  | `AppController.swift:824` (`recoverInterrupted`) | `.recover` |
  | `:1766` (`syncCloud`), `:2048` (`makeMissingRecordings`) | `.backup` |
  | `:2041` (`processPending`) | `.queue` |
  | `:2071-2076` (`Retention.sweep` in `runHousekeeping`) | `.retention` |
  | `:2165-2167` (`CalendarSnapshot.write(... inert:)`) | `inert: !mode.does(.calendarSnapshot)` |
  | `AppController+Sync.swift:34` (`writesSharedItems`), `:175` (`syncNow`) | `.sharedItems`, `.sync` |
  | `AppController+Coach.swift:49` (`runCoach`), `:112` (`sendCoachEmail`, a new guard) | `.coach`, `.weeklyMail` |
  | `AppController+Commitments.swift:12`, `AppController+Series.swift:206`, `AppController+Personas.swift:83` | `.commitments`, `.nextTime`, `.personas` |
  | `AppController.swift:1036` (`refreshPeopleReferences`), `AppController+Commitments.swift:42`, `AppController+Findings.swift:124` | `.people` |
  | `AppController+Google.swift:260`, `:291`; `:229` (`refreshGoogleDirectory`) | `.geminiNotes`; `.upkeep` |
  | `AppController+Profiles.swift:21` (`changesProfiles`, in place of `!isInert`) | `.registry` |
  | `AppController+UsageStats.swift:10` | `inert: !mode.does(.usageStats)` |

  What still reads `isInert` after this step is not in the table: the views, the move of the backups (`AppController+Backup.swift:104`), and a change of the points in a preview (`AppController+Series.swift:180`).

- [ ] **Step 6: Start, tell, stop.** `workers = WorkerManager(identity: .current, mode: mode) { [weak self] in self?.workerLines = $0 }` in `init`. At the end of the full block of `finishLaunch` (`:890`), after Part 1's `finishRemovals()`: `workers.start(recording: isRecording)`. In the `didSet` of `status` (`:79`): when `isRecording` differs from what `oldValue` gives, `workers.setRecording(isRecording)`. In `AppDelegate` (`MossadApp.swift:237`): `func applicationWillTerminate(_:)` calls `AppController.current?.workers.quit()`. `profileMenu` (`AppController+Profiles.swift:17`) passes `status: workerLines`.
- [ ] **Step 7: `scripts/build.sh`.** After the line that waits for the old copy (`:52`) and before `rm -rf`: wait up to 5 s until `pgrep -f '/Mossad.app/Contents/MacOS/Mossad --profile [a-z0-9]+ --worker$'` finds nothing. The script sends them no signal: they end by themselves when the app is gone. After 5 s it goes on.
- [ ] **Step 8: Run the build check, then two greps.** `grep -n "isInert" App/AppController+Coach.swift App/AppController+Commitments.swift App/AppController+Personas.swift App/AppController+UsageStats.swift`: no output. `grep -rn "workers\.\(start\|resume\)" App | grep -v "AppController"`: no output (only the controller starts workers). Expected build: exit status 0.
- [ ] **Step 9: Commit.** `git commit -m "The foreground app starts a worker for each other profile when its launch is done, tells them when a call records, and stops them when it quits"`

---

### Task 10: A switch and a delete with a worker

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Worker/WorkerLaunch.swift` (one enum); `App/AppController+Profiles.swift:30-80` (`switchProfile`, `startInstance`) and `deleteProfile` (Part 1, Task 8)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/WorkerLaunchTests.swift` (new methods)

**Interfaces:**
- Consumes: `ProfileSwitch.decide` and `afterStart` (Part 1), `WorkerManager.stopAll(waitingFor:seconds:)`, `stop(_:seconds:)`, `resume(recording:)`.
- Produces:

```swift
public enum WorkerSwitch {
    public static let waitSeconds: TimeInterval = 5
    public enum Step: Equatable, Sendable { case stopWorkers, waitForFolder, saveActive, startInstance, quit, resumeWorkers, restoreActive }
    public static let order: [Step] = [.stopWorkers, .waitForFolder, .saveActive, .startInstance, .quit]
    public static func afterFailure(of step: Step) -> [Step]
    public static func refusal(_ name: String) -> String    // "Mossad could not stop the background work of “<name>”. Try again in a moment."
}
```

`afterFailure`: of `.waitForFolder`, `[.resumeWorkers]`; of `.saveActive`, `[.resumeWorkers]`; of `.startInstance`, `[.restoreActive, .resumeWorkers]`; of any other step, `[]`.

- [ ] **Step 1: Write the failing tests**

```swift
func testASwitchStopsTheWorkerAndWaitsForItsFolderBeforeTheNewInstanceStarts() {
    let o = WorkerSwitch.order
    XCTAssertEqual(o, [.stopWorkers, .waitForFolder, .saveActive, .startInstance, .quit])
    XCTAssertLessThan(o.firstIndex(of: .waitForFolder)!, o.firstIndex(of: .startInstance)!)
    XCTAssertLessThan(o.firstIndex(of: .waitForFolder)!, o.firstIndex(of: .saveActive)!)     // a refusal leaves the registry as it was
    XCTAssertEqual(WorkerSwitch.waitSeconds, 5)
}
func testAWorkerThatDoesNotStopRefusesTheSwitchAndTheOldAppStays() {
    let after = WorkerSwitch.afterFailure(of: .waitForFolder)
    XCTAssertEqual(after, [.resumeWorkers])
    for never in [WorkerSwitch.Step.quit, .startInstance, .saveActive, .restoreActive] { XCTAssertFalse(after.contains(never)) }
    XCTAssertEqual(WorkerSwitch.refusal("Personal"), "Mossad could not stop the background work of “Personal”. Try again in a moment.")
}
func testAFailedStartBringsTheWorkersBack() {
    XCTAssertEqual(WorkerSwitch.afterFailure(of: .startInstance), [.restoreActive, .resumeWorkers])
    XCTAssertEqual(WorkerSwitch.afterFailure(of: .saveActive), [.resumeWorkers])
    XCTAssertEqual(WorkerSwitch.afterFailure(of: .quit), [])
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter WorkerLaunchTests`. Expected: the build fails with "cannot find 'WorkerSwitch' in scope".
- [ ] **Step 3: Write `WorkerSwitch`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: `switchProfile(to:)`.** After `ProfileSwitch.decide` says `.go`, in a `Task`, the steps of `WorkerSwitch.order`: `await workers.stopAll(waitingFor: id, seconds: WorkerSwitch.waitSeconds)`; false: `workers.resume(recording: isRecording)`, `profileProblem = WorkerSwitch.refusal(<the target's name>)`, and return (nothing was saved, the old window app stays). True: the save of `active` as today (a failed save: `resume`, then today's words); `startInstance` as today; when `ProfileSwitch.afterStart` is `.restore` or `.stay`: today's steps, then `workers.resume(recording: isRecording)`. While the task runs, a second switch does nothing. The new instance still waits for the two locks in `MossadEntry.main()`, as Part 1 built it, and starts the workers of its own launch: the profile that was active is one of them.
- [ ] **Step 5: `deleteProfile(_:typed:)`.** After `ProfileRules.deleteProblem` and before the lock of the profile's folder is taken: `await workers.stop(id, seconds: WorkerSwitch.waitSeconds)`; false: `profileProblem = WorkerSwitch.refusal(name)`, `workers.resume(recording: isRecording)`, and return. A profile marked `removing` is not live, so no worker is started for it again.
- [ ] **Step 6: Run the build check.** Expected: exit status 0.
- [ ] **Step 7: Commit.** `git commit -m "A switch or a delete stops the profile's worker and sees its folder free first, and a worker that does not stop leaves Mossad as it was"`

---

### Task 11: The switcher's line

**Files:**
- Modify: `App/ProfileSwitcher.swift` (Part 1, Task 9); `App/DevHooks.swift`

**Interfaces:**
- Consumes: `ProfileMenu.Row.status` (Task 7), `controller.workerLines` (Task 9).

The rule is tested in Task 7 (`testTheLineOfEachState`, `testTheSwitcherShowsTheLineOfAnotherProfileOnly`). This task has no new logic.

- [ ] **Step 1: The row.** In the switcher's menu, a row whose `status` is not nil shows it as the item's second line (`Text(row.name)` then `Text(status)` in the button's label), at `Rhythm.secondarySize` in `Palette.secondary` where the menu draws custom text. VoiceOver reads "<name>, <status>". The active row never has one.
- [ ] **Step 2: The preview hook.** `App/DevHooks.swift`: in a preview, `MOSSAD_WORKER_LINES="1a2b3c4d=2 meetings in work"` (`<id>=<line>`, more with `;`) fills `workerLines`. Add it to the comment at the top of the hooks.
- [ ] **Step 3: Run the build check, then look at it in a preview under the rules of your brief**, with the made-up registry of Part 1's Task 9 and the hook: the menu shows "2 meetings in work" under the other profile, in light and dark, and nothing under the active one. Without the hook: no second line.
- [ ] **Step 4: Commit.** `git commit -m "The switcher's menu says how many meetings another profile has in work, or what last failed there"`

---

### Task 12: The words

**Files:**
- Modify: `AGENTS.md`, `website/content/site.json`

- [ ] **Step 1: `AGENTS.md`.** In the profiles row of Part 1, or a new row for `.../Worker/`, `Support/RunMode.swift`, `Sync/SyncPass.swift`, `App/WorkerEntry.swift`, `App/WorkerManager.swift`: a worker is `Mossad --profile <id> --worker`, a child process of the foreground app with no `AppController` and no `NSApplication`; `Duty` by `RunMode` is the one table of who does what, and a new gate reads it; `foreground.json` beside the registry (pid, start time, `recording`, `stopping`), read every 2 s, with the rule of `ForegroundWatch` (pid gone: the worker ends; unreadable: a call records); a stop is the end of the process; the exit codes and the restart rule; the order of a switch (`WorkerSwitch.order`); `ServiceSettings` is the one wiring of the services, for the app and the worker: add a setting there, not in one of the two; `WorkerCalendar`, `canRead()`, `inviteUnknown`, and `matchUnknownInvites`; `.behindApp`; `<data folder>/Worker/status.json` and its allowed keys; what a worker leaves for the window app; that a worker never looks at a lock by taking it; the debug hooks `--probe`, `MOSSAD_PROOF_CALL`, and `MOSSAD_WORKER_LINES`; and what the installed app's worker logged for the Mac's calendars (from "Owner steps", once known). Change the rows it touches: `.../Pipeline/Pipeline.swift` (the plan `.behindApp`, the mark), `.../Sync/` (`SyncPass`), `.../Onboarding/` (`AppIdentity` and a worker), and in "Build and test": an install waits for the workers to end.
- [ ] **Step 2: `website/content/site.json`.** In the feature `separate-profiles` (Part 1, Task 10), two more details: "The profile you are not in still finishes its meetings and keeps its sync and backup up to date" and "A recording from your iPhone gets its notes while the Mac is in another profile". Add `Packages/MossadCore/Sources/MossadCore/Worker/ProfileWorker.swift` to its `sources`. Say nothing of a process, a file, or a worker.
- [ ] **Step 3: Check.** Run: `python3 -m json.tool website/content/site.json > /dev/null && cd Packages/MossadCore && swift test`. Expected: exit status 0 and 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "AGENTS and the website say that the profile that is not active still finishes its meetings"`

---

## Owner steps

After the release, with the real app and two profiles:

1. In Activity Monitor, look for Mossad: two processes, one Dock icon, one menu bar item. Quit Mossad: both are gone within seconds.
2. Open the Log page of the profile that was in the background. Find "Worker: Mac calendars:". "readable" means a worker matches invites from the Mac's calendars. "not readable" means it cannot: its meetings are finished without their invite and get it when you next switch to that profile. Tell the builder which line you saw, for `AGENTS.md`.
3. Record a short call, then switch at once. The switcher's menu shows "1 meeting in work" under the profile you left, and then nothing. Switch back: the meeting is written, and no notification came from the other profile meanwhile.
4. Start a call in the active profile while the other profile has a meeting in work: its work waits until the call ends.
5. Send a room recording from the iPhone while the Mac is in the other profile: it gets its notes without a switch. (Until Part 3 the iPhone knows only the first profile.)
6. Know the limits of Part 2: the weekly mail, retention, Gemini notes, and the reads of people for the phone of a profile run only while that profile is active.

## Self-review

- **Spec coverage.** The worker and that it has no window, menu bar item, or Dock icon: Tasks 1 and 8 (no `NSApplication`). Started when the launch is done, stopped at a quit or a switch, ends when the foreground app is gone, holds its folder lock: Tasks 3, 8, 9, 10. The third mode and the table as one table test: Task 2; the app's gates read it: Task 9. Each row of "A worker does": Task 8's table of duties (the take-in of a moved meeting is a seam only). Each row of "A worker never does": Task 2's table, and Task 8's `testTheWorkersCodeCannotAskPostOrShow`. The calendar only to match an invite, with the profile's calendars and tokens, the proof first, and unknown: Tasks 1 and 6. What a worker leaves undone runs when the profile is next active: unchanged code of the window app. No heavy work during a call across processes, and "cannot tell": Tasks 3 and 4. What the owner sees: Tasks 7, 9, 11. The spec's test "the worker's mode (the table above as one table test)": Task 2. Words and the website: Task 12. Not covered, by the brief: Parts 3 and 4.
- **Types.** `ForegroundState.Read` is what `ForegroundWatch.next` takes and `ForegroundState.read` gives. `ForegroundWatcher.callRecords` is the closure of `ProfileWorker.Setup.callRecords` and of the worker's `HeavyWorkGate`. `ServiceSettings.MissingKey` is what `WorkerStatus.make` takes. `WorkerLaunch.Exit` raw values are the `Int32` that `WorkerLaunch.restart(exit:...)` reads. `ProfileMenu.Row.status` is filled from `AppController.workerLines`, which `WorkerManager` makes with `WorkerStatusLine.text`. `WorkerPace.Work` is what `ProfileWorker.pass` takes. `RunMode.runs(_:madeUpRegistry:)` is the one question each duty of the worker asks.
- **Proportion.** The spec's Part 2 is short because it leaves the mechanism to the builder. This plan is long where the brief asked for a rule with a test (the file, the watch, the switch, the status, the calendar) and short where the code is a move (Task 5) or a call in the app (Tasks 9 to 11).
