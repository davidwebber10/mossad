# Profiles Part 1 (the Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner adds a second profile on the Mac, and each profile has its own folder, keys, settings, sync, backup, and MCP, with one click to change from one to the other.

**Architecture:** A process of Mossad is one profile from its first line to its last. `AppIdentity` reads a small registry (`profiles.json`) and gives the profile's folder, Keychain service, and settings suite; the suite takes the place of `UserDefaults.standard` before anything reads a setting, so the existing reads do not change. A short list of Mac-wide keys stays in the real standard domain (`MacDefaults`), and a switch saves `active`, starts a new instance, and quits.

**Tech Stack:** Swift 6, SwiftUI with AppKit, CloudKit, Security (Keychain), Sparkle 2.10, XCTest. No new package.

**Spec:** `docs/superpowers/specs/2026-11-16-profiles-design.md`. Read it whole before any task. This plan covers only "The model: one profile for each process" and "Part 1: profiles on the Mac". Where this plan and the spec disagree, the spec wins, except for the points in "What the code contradicts".

**Branch:** `feature/profiles-mac`, made from `main` after the phone call import is merged (the spec's order of the work).

## Global Constraints

- Test first. Write the failing test, run it, then write the code.
- Pure logic goes in `Packages/MossadCore/`. The app target holds views and wiring only.
- `cd Packages/MossadCore && swift test` (the whole suite) must pass before every commit.
- No build, test, or preview while a call records. Before each `swift test`, `xcodebuild`, or run of the app, run the call gate script that your brief names. If it says a call records, wait.
- Never block the main thread. The one wait in this plan (10 seconds for a lock) is in `MossadEntry.main()`, before the app object exists.
- Unknown is not false: a registry or a do-not-record file that cannot be read is "not known", never "empty".
- Do not lose audio. A switch never happens while a call records, and a deleted profile's folder goes to the Trash.
- No AI attribution, no em dashes, and no real names of people in commits, code, or tests. Use made-up names such as "Sam Carter". Profile names such as "Work" and "Personal" are fine.
- Secrets live only in the Keychain. Never log them and never put them in arguments. The registry holds a hash of a server address, never the address or the secret.
- `Mossad.xcodeproj` is generated from `project.yml`. Never edit or commit it.
- Settings pages hold only settings. An explanation goes in a sheet.
- New Mac view text sizes and gaps come from `SharedUI/Rhythm.swift` tokens (`Rhythm`, `Space`).
- The website follows the app: `website/content/site.json` in the same branch, benefits and not mechanism, and nothing about the usage statistics.
- `AGENTS.md` rows are updated in the same branch.
- Zero interaction: with ONE profile no new control shows except "Add profile…" in Settings > General, and every existing test passes unchanged. Add new test files or new test methods; do not edit an existing test.
- Never deploy `server/` from an agent session. This plan changes nothing in `server/`.
- Exact values from the spec: the first profile's id is `default` and its name is "Mossad"; another id is 8 random hex characters; Keychain service and settings suite `com.dwebber.mossad.profile.<id>`; the registry is `~/Library/Application Support/Mossad/profiles.json` with `version`, `profiles` (`id`, `name`, `color`, `root`), and `active`; the folder `~/Mossad <Name>`; the zone `Mossad-<id>`; the iCloud Keychain accounts `ai.<id>` and `server.<id>`; the backup prefix `profiles/<id>/`; the MCP server name `mossad-<name in lower case, letters and digits>`; the sentences "A call is recording. Switch when it ends." and "Another copy of Mossad is running"; the menu words "Add profile…" and "Manage profiles…"; the wait of 10 seconds.
- Build check for app changes (not verified by the plan's author, who could not build): `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Debug -derivedDataPath build/dev build -quiet`. Expected: exit status 0 and no line with `error:`.
- Commit messages are one sentence in the repo's style.

**The hard invariant.** With no registry file, the process is `default`, and these are byte for byte what they are today: the data folder (`~/Mossad`), the Keychain service (`com.dwebber.mossad`), the settings domain (the standard domain, no swap), the CloudKit zone (`Mossad`), the two iCloud Keychain accounts (`ai`, `server`), the backup key (`calls/<id>/recording.m4a`), the note's audio line (`audio: ~/Mossad/Audio/<id>`), and the MCP command and server name (`mossad`). Rehearsal, `--ui-preview`, and a run with `MOSSAD_ROOT` ignore the registry.

## Review Focus

1. **The hard invariant breaks for the owner who never adds a profile.** Expected: nothing changes on disk, in the Keychain, in iCloud, or in an AI app's connector. Tests: `testWithNoRegistryTheProcessIsDefaultAndAsToday`, `testRehearsalAPreviewAndMossadRootIgnoreTheRegistry`, `testOnlyTheRealMacAppReadsTheRegistryFile` (Task 1); `testTheDefaultProfileKeepsTodaysZoneAccountsAndKeys` (Task 4); the unchanged golden test in `MarkdownWriterTests` (Task 5); `testTheDefaultCommandIsTodaysText` (Task 6).
2. **A command or a static reads a setting before the profile is known, or reads the wrong profile.** An AI app set up for work starts `Mossad --mcp` while Personal is active. Expected: a command with no `--profile` is `default`, always; a command with `--profile` reads that profile's suite, folder, and keys. Tests: `testTheWindowAppIsTheActiveProfileAndACommandIsDefault`, `testAProfileSuiteNeverReadsTheStandardDomain` (Task 1), and the proof run (Task 1, Step 9).
3. **Sparkle or the login item reads a profile's suite.** The owner turned automatic updates or "Open Mossad at login" off, and a new profile turns them on again. Expected: both read the real standard domain in every profile. Tests: `testTheSwapHandsTheRealDomainOverOnTheMainThreadOnly`, `testTheMacWideKeysAreThisList`, `testAMacWideKeyInAProfilesSettingsIsAStray` (Task 1).
4. **A new profile's first launch takes something from the first profile in iCloud.** A new profile has no AI key and no server, and today's code deletes the shared item in that case (`AppController+Sync.swift:37-39`, `:112-113`), before the inert check; a shared zone would let one profile's sync delete the other's meetings. Expected: a process names only its own accounts and its own zone, and the zone `Mossad` can never be deleted. Tests: `testAProfileNeverNamesTheDefaultSharedItems`, `testTwoProfilesNeverShareAZoneOrASyncState`, `testTheFirstProfilesZoneCanNeverBeDeleted` (Task 4).
5. **A switch at a bad moment.** During a recording; during a pipeline step; when the new instance does not start; when two window apps run as two profiles and both record one call. Expected: a refusal while a call records; a meeting in work keeps its state and is finished when that profile is next active; a failed start puts `active` back; one foreground app for the Mac. Tests: `testASwitchIsRefusedWhileACallRecords`, `testASwitchDuringProcessingGoes`, `testAFailedStartPutsTheActiveProfileBack` (Task 2); `testTheNewInstanceWaitsForTheLocks`, `testOnlyOneForegroundAppForTheMac` (Task 7).

## Choices made where the spec left one

- **Sparkle:** the real standard domain is kept and handed over. `Updater` makes `SPUStandardUpdaterController` inside `MacDefaults.handOver { }`, during which `UserDefaults.standard` on the main thread is the real domain. Every `SUHost` that reads or writes a setting in the app's process is made in that one call (`SPUUpdater.m:97`, `SPUUpdaterSettings.m:46`, `SPUStandardUserDriver.m:95`) and keeps the object it took (`SUHost.m:66`). "Host made before the swap" was not chosen: the updater is made lazily after launch (`AppController.swift:225`, first use `:739` or `MainWindow.swift:272`).
- **A made-up registry:** the environment variable `MOSSAD_PROFILES=<file>`. In a `--ui-preview` it only fills what the switcher and Settings show; the preview stays a preview. In a run that is not a preview, the process is a profile of that file and is inert (`RunMode`). The real registry is never read in either case. This serves the spec's "signed build on a made-up registry" and the preview of the switcher.
- **The proof run is not a `--ui-preview`.** A preview's suite is emptied at each launch, so it cannot prove "never emptied" or "across a restart". The proof run is the signed app, inert, on a made-up registry and a made-up folder. It shows the Mac's real calendars in its window, so take no capture of it.
- **`root` in the registry** is a path that starts with `~/` (read against the home folder) or an absolute path (a made-up registry). For `default` it is ignored: the folder is always `~/Mossad`.
- **A folder name** keeps letters, digits, spaces, `-`, and `_` of the name (40 characters at most), so the note's `audio:` line stays valid YAML. A taken name gets " 2", " 3". An empty result is "Mossad Profile". "Mossad" and "Mossad Rehearsal" are always taken.
- **Colors:** `orange` (the first profile), `blue`, `green`, `purple`, `pink`, `graphite`. A new profile is offered the first color no other profile has. An unknown color in the file reads as `graphite`.
- **Names:** two profiles cannot have one name (letter case ignored). Rename changes the name and the color, never the folder.
- **A registry that cannot be read** is never replaced and never moved aside. The window app starts as `default`, Add, Rename, Delete, and Switch are refused, and Settings > General says so in the group's footer. A newer registry is read and never saved: a switch then passes `--profile <id>` and does not save `active`.
- **`--profile` in Rehearsal, a preview, or a `MOSSAD_ROOT` run** is ignored, as any unknown argument is today.
- **One foreground app for the Mac:** when a registry file exists, the window app also takes a lock on `~/Library/Application Support/Mossad/.lock`. A window app that cannot take it is a second copy, as today. With no registry file nothing new is made on disk.
- **The 10 second wait** runs only in an instance started by a switch (argument `--switched`), in `MossadEntry.main()`. It waits for the Mac-wide lock and then the folder lock, 10 seconds in all. So the old instance has released its hot keys before the new one registers them. `--switched` also opens the main window.
- **Add is refused while a call records** ("A call is recording. Add a profile when it ends."), because it restarts Mossad.
- **Delete is resumable.** Order: (1) the registry entry is marked `removing`, so the profile cannot start and does not show; (2) its two iCloud Keychain items; (3) its Keychain items; (4) its settings suite; (5) its folder to the Trash; (6) its iCloud zone; (7) the registry entry. A step that fails stops the run; the next launch of the foreground app runs it again from step 2 (each step does nothing when already done). The local steps come before the zone, so an offline Mac still removes the profile from this Mac at once.
- **Delete refuses** while that profile's folder is locked, and never puts in the Trash a folder that is not a direct child of the home folder with a name that starts with "Mossad ", or that is `~/Mossad`, `~/Mossad Rehearsal`, or another profile's folder. Such a folder stays and the step counts as done.
- **The delete sheet** says the server sentence only when the registry has a server hash for the profile, and always says "Recordings that this profile backed up to a bucket stay in the bucket."
- **The server address** of each profile is in the registry as `server`: the SHA-256 (hex) of `ServerConnection.address(from:)`'s `absoluteString` in lower case. The active profile writes only its own. With no registry file, the first profile's hash is written when the file is first made (Add).
- **Not recording across profiles:** the gate reads the other profiles' rules in memory (`NoRecordBook.forGate`); the pages, the Gemini notes import, and Reset use only the active profile's book. Another profile's refusal wins over the active profile's "Record", and no page shows why (the spec: no page of another profile shows it). A do-not-record file of another profile that cannot be read blocks as the active one's does today, and is never moved aside from here.
- **A blocked call goes on across a switch:** the gate adopts the other profile's blocked call session (`no-record-session.json`) without its title.
- **More Mac-wide keys than the spec lists:** `screenCaptureAsked` and `automationState.<bundle id>` (the permission memory), and the two hidden usage statistics keys (`usageStatsEndpoint`, `usageStatsInDebug`).
- **Usage statistics counters** stay a file in each data folder. At a launch with the switch off, the active profile's counters are deleted, so a profile that was not active when the owner turned the switch off keeps nothing.
- **The MCP server name** uses ASCII letters and digits after accents are removed ("Café 2" gives `mossad-cafe2`). With no letter or digit left it is `mossad-<id>`. When another profile has the same result, both get `-<id>` at the end. `default` is always `mossad`, also after a rename.
- **The note's audio line** names the registry's `root` as written (`audio: ~/Mossad Work/Audio/<id>`). Rehearsal and a `MOSSAD_ROOT` run keep the fixed text `~/Mossad`, as today.
- **The switcher** is a native `Menu` at the bottom of the sidebar, under the status cards. The menu bar icon gets a 5 pt dot in the profile's color at its bottom trailing corner in the idle and off states; the recording icon does not change. The menu bar panel's first row is a dot and the profile's name.
- **Settings > General > Profiles** is a group after "You". With one profile it is one row with "Add profile…".
- **Preview hooks:** `MOSSAD_PROFILES=<file>` and `MOSSAD_PROFILE_SHEET=add|rename|delete`. In a preview, Add, Rename, Delete, and Switch do nothing.

## What the code contradicts

- **"That file holds only the keys of events and series (links and ids), never a title or a person."** The key is the meeting's title in lower case, then the link's host and path (`NoRecordBook.swift:51-55`), and the blocked call's session file holds the invite's title (`NoRecordBook.swift:191`). Plan: the other profiles' keys are held in memory only, never shown, never logged; an adopted session drops its title.
- **A refusal reaches the other profile only through an invite.** The gate matches a key against the calendar events of the active profile (`NoRecordBook.swift:116-122`). A meeting refused in Work blocks in Personal only when Personal's chosen calendars also hold that event, or when the blocked call session is adopted. The plan builds this as it is and says so in "Owner steps".
- **"As `restartAsWorkingCopy` does."** That function returns unless the copy is a second copy (`AppController+SecondCopy.swift:27`) and copies every argument (`:30`). A switch gets its own function, which removes an old `--profile`.
- **"The new instance waits up to 10 seconds for the profile's folder lock."** The lock is taken in `AppController.init` on the main thread (`AppController.swift:624`). The wait is in `MossadEntry.main()` (see "Choices").
- **"Steps that are Mac-wide (the permissions, the login item) show as done."** The login item is not a step: it is a switch in the Done step (`OnboardingSteps2.swift:299-306`). The Permissions step is done by itself when the Mac has the permissions (`Onboarding.swift:38`). The plan adds no step state; it makes the login flag and the permission memory Mac-wide (`OnboardingSteps2.swift:300`, `:330`; `PermissionsMonitor.swift:103-112`, `:126-127`, `:198`).
- **"The usage statistics (one install id, one switch, at most one report a day)."** The counters are a file in each data folder (`AppController.swift:504`), and "off" deletes only the active profile's (`AppController+UsageStats.swift:44`). See "Choices".
- **"The line names the profile's real folder."** Today the line is the fixed text `~/Mossad`, also for Rehearsal and a `MOSSAD_ROOT` run, whose folder is another (`MarkdownWriter.swift:91`). The plan changes it only for a profile other than `default`.
- **"Rehearsal, previews, and a run with `MOSSAD_ROOT` have no profiles"** against "the builder proves with a signed build on a made-up registry". The two meet through `MOSSAD_PROFILES` (see "Choices").
- **"The 199 reads of settings."** The count today is 78 `@AppStorage` and 102 `UserDefaults.standard` in `App/` and `SharedUI/`, and 4 in MossadCore. Not material: none of them changes.
- **The checked facts hold.** `AppIdentity.swift:94-101`, `SUHost.m:66`, `AppController.swift:225`, `MossadApp.swift:23-87`, `InstanceLock.swift:19-28`, `SharedAIKey.swift:17-28`, `ServerPairing.swift:26-36`, `AppController.swift:1002-1003` (before the inert check at `:636`), `CloudKitStore.swift:7`, `BucketArchive.swift:16`, `MarkdownWriter.swift:62` and `:91`, `SettingsAI.swift:112-114`, `MCPServer.swift:58`, `AppController.swift:2062-2070`, `:188`, `:603`, `NoRecordBook.swift:271`, `UsageReportPlan.swift:69-79` are as the brief says.

## The first lines of `MossadEntry.main()`

A profile is resolved before anything reads a setting, the Keychain, or `Paths.live`. After Task 1 the entry starts with these lines, in this order:

1. `let identity = AppIdentity.current`. This is the first static made. It reads `Bundle.main`, `CommandLine.arguments`, the environment, and (only for the real Mac app that takes profiles) the registry file. It reads no setting.
2. `identity.refusal(home:environment:)`: a preview on a real folder, or an unknown profile id. One line on stderr, `exit(2)`.
3. `identity.isolateDefaults()`: holds the real standard domain in `MacDefaults`, then puts the preview's or the profile's suite in place of `UserDefaults.standard`. `exit(2)` when it fails.
4. (Task 7) For a window app with `--switched`: the wait for the locks.
5. `CompanyDomains.loadSaved()` and the rest, as today.

Checked: `Paths.live` (`Paths.swift:14`) and `Keychain.app` (`AppIdentity.swift:106`) are the only statics made from the identity, and both are lazy, so they are made after line 1. No file-scope `let` and no `static let` in `App/`, `SharedUI/`, or MossadCore holds `UserDefaults`. No Objective-C `+load` exists in the repo's own code. The builder runs this again in Task 1, Step 8:

```sh
grep -rnE "static let [A-Za-z]+ *=.*(UserDefaults|Keychain\.app|Paths\.live|AppIdentity\.current)" --include='*.swift' App SharedUI Packages/MossadCore/Sources
```

Expected: 2 lines, `Paths.swift:14` and `AppIdentity.swift:106`.

## Seams for Parts 2 to 4

- **`--profile <id>` on any run** is read by `ProfileLaunch.choice` (Task 1). Part 2 adds `--worker` beside it; a worker is not in `AppIdentity.commands`, so it needs its `--profile`.
- **`RunMode`** (Task 1) has `full` and `inert`. Part 2 adds `worker` there and in `RunMode.decide`.
- **The Mac-wide lock** (Task 7) says "the foreground app runs". A worker does not take it; it can watch it to end when the foreground app is gone.
- **`AppController.switchProfile(to:)`** (Task 7) saves `active`, then starts the new instance. Part 2 stops the workers between these two steps, and stops the target's worker before a delete (the delete already refuses a locked folder).
- **`ProfileMenu.Row`** (Task 2) has `id`, `name`, `color`, `active`. Part 2 adds the status line of each other profile.
- **The iCloud Keychain accounts** take `profile:` (Task 4), with the process's own profile as the default. Part 3 passes the phone's chosen profile and adds the account `profiles`.
- **`CloudKitStore(zone:)`** (Task 4) takes the zone as a value, for the phone's one process.
- **`Profile`** is Codable with optional fields; Part 3 adds how a profile syncs with `version` still 1.
- **`ProfileRegistry.live`** gives Part 4 its "Move to" targets and their folders.

## File structure

| File | Responsibility |
| --- | --- |
| `Packages/MossadCore/Sources/MossadCore/Profiles/Profile.swift` (new) | `Profile`, `ProfileColor`. |
| `.../Profiles/ProfileRegistry.swift` (new) | The registry: read, state, save, changes. |
| `.../Profiles/ProfileLaunch.swift` (new) | Which profile a process is. |
| `.../Profiles/ProfileRules.swift` (new) | Names, folders, ids, the delete rule, the switch, the menu, the server hash. |
| `.../Profiles/ProfileRemoval.swift` (new) | The steps of a delete. |
| `.../Support/MacDefaults.swift` (new) | The real standard domain, the Mac-wide keys, the hand-over. |
| `.../Support/RunMode.swift` (new) | `full` or `inert`. |
| `.../Chat/MCPCommand.swift` (new) | The MCP server name and the commands the owner copies. |
| `.../Support/AppIdentity.swift` | The profile of the process and everything named after it. |
| `App/AppController+Profiles.swift` (new) | The registry in the app, Switch, Add, Rename, Delete. |
| `App/ProfileSwitcher.swift` (new) | The sidebar control, the colors, the menu bar mark. |
| `App/ProfileSettings.swift` (new) | Settings > General > Profiles and its three sheets. |

---

### Task 1: The proof: a process as a profile, with Sparkle and the login item on the real domain

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/Profile.swift`, `.../Profiles/ProfileRegistry.swift`, `.../Profiles/ProfileLaunch.swift`, `.../Support/MacDefaults.swift`, `.../Support/RunMode.swift`
- Modify: `.../Support/AppIdentity.swift:15-28, 41-51, 70-74, 91-101`; `App/MossadApp.swift:7-21`; `App/Updater.swift:28`; `App/AppController.swift:636-637, 2063-2066`; `App/OnboardingSteps2.swift:300, 330`; `App/DevHooks.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileProofTests.swift` (new)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:

```swift
public enum ProfileColor: String, Codable, CaseIterable, Sendable { case orange, blue, green, purple, pink, graphite }
public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public static let defaultID = "default"
    public static let `default` = Profile(id: "default", name: "Mossad", color: .orange, root: "~/Mossad")
    public var id: String, name: String, color: ProfileColor, root: String
    public var server: String?      // Task 2
    public var removing: Bool?      // Task 2
    public init(id: String, name: String, color: ProfileColor, root: String)
    public var isDefault: Bool { get }
    public func rootURL(home: URL) -> URL          // "~/x" under home; any other path as it is; `default` is home/Mossad
}
public struct ProfileRegistry: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int, profiles: [Profile], active: String
    public init()                                   // one profile, `default`, active
    public static func folder(home: URL) -> URL     // home/Library/Application Support/Mossad
    public static func fileURL(home: URL) -> URL    // folder/profiles.json
    public var live: [Profile] { get }              // without `removing`
    public func profile(_ id: String) -> Profile?   // live only; "default" always answers
    public var activeProfile: Profile { get }       // `default` when `active` is not a live profile
    public enum State: Equatable, Sendable { case none, read, newer, unreadable }
    public struct Loaded: Equatable, Sendable {
        public var registry: ProfileRegistry, state: State
        public var canSave: Bool { get }            // .none or .read
        public static let none: Loaded
    }
    public static func load(from file: URL) -> Loaded   // never writes, never moves the file
}
public enum ProfileLaunch {
    public enum Choice: Equatable, Sendable { case profile(Profile), refused(String) }
    public static func choice(arguments: [String], registry: ProfileRegistry.Loaded) -> Choice
}
public enum RunMode: Equatable, Sendable {
    case full, inert
    public static func decide(preview: Bool, rehearsal: Bool, secondCopy: Bool, madeUpRegistry: Bool) -> RunMode
}
public enum MacDefaults {
    public static let keys: [String]
    public static let prefixes: [String]
    public static func isMacWide(_ key: String) -> Bool
    public static func strays(in domain: [String: Any]) -> [String]   // sorted
    public static var store: UserDefaults { get }                     // `.standard` until held
    static func hold(_ real: UserDefaults)
    public static func handOver<T>(_ make: () -> T) -> T              // main thread only
}
struct DefaultsSwap { let real: UserDefaults; let profile: UserDefaults
    func current(handingOver: Bool, isMainThread: Bool) -> UserDefaults }

// AppIdentity
public init(bundleID: String?, arguments: [String] = [], environment: [String: String] = [:],
            registry: ProfileRegistry.Loaded? = nil, madeUpRegistry: Bool = false)
public let profile: Profile
public let registry: ProfileRegistry.Loaded      // what the switcher shows; `.none` with none
public let madeUpRegistry: Bool
public let profileRefusal: String?
public var takesProfiles: Bool { get }           // not Rehearsal, not a preview, no MOSSAD_ROOT
public var emptiesSettings: Bool { get }         // a preview only
public func profileSettings() -> UserDefaults?   // the profile's suite, untouched; nil for `default` and a preview
public static func readsRegistry(bundleID: String?, arguments: [String], environment: [String: String]) -> Bool
public static func launch(bundleID: String?, arguments: [String], environment: [String: String], home: URL) -> AppIdentity
```

Rules the signatures do not say:
- `ProfileLaunch.choice`: `--profile <id>` gives that live profile, or `.refused("Mossad: no profile with the id <id>; not starting.")`; `--profile` with no value gives `.refused("Mossad: --profile needs a profile id; not starting.")`. With no `--profile`: a run with one of `AppIdentity.commands` is `default`; any other run is `registry.activeProfile`.
- `AppIdentity.init` applies the choice only when `takesProfiles`; else `profile` is `.default` and `profileRefusal` is nil. `refusal(home:environment:)` returns the preview's refusal as today, then `profileRefusal`.
- `keychainService`: a preview as today; a profile other than `default` gives `appID + ".profile." + id`; else `appID`. `defaultsSuite`: a preview as today; a profile other than `default` gives `appID + ".profile." + id`; else nil. `dataRoot`: `MOSSAD_ROOT`, then Rehearsal, then `profile.rootURL(home:)`.
- `ProfileRegistry.load`: a missing file is `.none`; a file that does not decode is `.unreadable` with one `default` profile; `version` above 1 is `.newer`. `default` is always there and first. An entry whose id is not 8 characters of `0-9a-f`, or whose id is there twice, is left out. An unknown `color` reads as `graphite`.
- `AppIdentity.launch`: `readsRegistry` is true only for `bundleID == mainBundleID`, no `--ui-preview`, and an empty `MOSSAD_ROOT`. With `MOSSAD_PROFILES=<file>` set: a preview loads that file for `registry` only; a run that reads registries loads it in place of the real file, with `madeUpRegistry` true. On iOS, `launch` never reads a file. `AppIdentity.current` calls `launch`.
- `isolateDefaults()`: for `default`, `MacDefaults.hold(.standard)` and no swap. For a preview, as today, then `MacDefaults.hold(<the preview's suite>)`. For a profile: `let real = UserDefaults.standard`, `MacDefaults.hold(real)`, then the class method is replaced by a block that returns `DefaultsSwap(real:profile:).current(handingOver: <the flag>, isMainThread: Thread.isMainThread)`. The profile's suite is never emptied and gets no registered defaults.
- `MacDefaults.keys` is exactly `["offUntil", "didSetLoginItem", "screenCaptureAsked", "usageStatsEnabled", "usageStatsInstallID", "usageStatsLastAttempt", "usageStatsEndpoint", "usageStatsInDebug"]`; `prefixes` is exactly `["SU", "automationState."]` (Sparkle's keys all start with `SU`).

- [ ] **Step 1: Write the failing tests** in `ProfileProofTests.swift`

```swift
private let home = URL(fileURLWithPath: "/Users/someone")
private let main = AppIdentity.mainBundleID
private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")
private func registry(active: String = "1a2b3c4d") -> ProfileRegistry.Loaded   // default and work, state .read
private func id(_ a: [String] = [], _ env: [String: String] = [:], bundle: String? = main,
                registry r: ProfileRegistry.Loaded? = registry()) -> AppIdentity   // arguments: ["Mossad"] + a

func testWithNoRegistryTheProcessIsDefaultAndAsToday() {
    let i = id(registry: nil)
    XCTAssertEqual(i.profile, .default); XCTAssertNil(i.profileRefusal)
    XCTAssertEqual(i.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad")
    XCTAssertEqual(i.keychainService, "com.dwebber.mossad"); XCTAssertNil(i.defaultsSuite); XCTAssertNil(i.profileSettings())
}
func testAProfileHasItsOwnFolderServiceAndSuite() {
    let i = id(["--profile", "1a2b3c4d"])
    XCTAssertEqual(i.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad Work")
    XCTAssertEqual(i.keychainService, "com.dwebber.mossad.profile.1a2b3c4d")
    XCTAssertEqual(i.defaultsSuite, "com.dwebber.mossad.profile.1a2b3c4d"); XCTAssertFalse(i.emptiesSettings)
}
func testTheWindowAppIsTheActiveProfileAndACommandIsDefault() {
    XCTAssertEqual(id().profile.id, "1a2b3c4d")
    XCTAssertEqual(id(["-psn_0_12345"]).profile.id, "1a2b3c4d")
    for flag in AppIdentity.commands {
        XCTAssertEqual(id([flag]).profile.id, "default", flag)
        XCTAssertEqual(id([flag]).keychainService, "com.dwebber.mossad", flag)
        XCTAssertEqual(id([flag, "--profile", "1a2b3c4d"]).profile.id, "1a2b3c4d", flag)
    }
}
func testAnUnknownProfileDoesNotStart() {
    XCTAssertEqual(id(["--profile", "ffffffff"]).refusal(home: home, environment: [:]), "Mossad: no profile with the id ffffffff; not starting.")
    XCTAssertEqual(id(["--profile"]).refusal(home: home, environment: [:]), "Mossad: --profile needs a profile id; not starting.")
    XCTAssertNil(id(["--profile", "default"], registry: nil).refusal(home: home, environment: [:]))
}
func testRehearsalAPreviewAndMossadRootIgnoreTheRegistry() {
    let a = ["--profile", "1a2b3c4d"]
    let rehearsal = id(a, bundle: AppIdentity.rehearsalBundleID)
    let preview = id(a + ["--ui-preview"], ["MOSSAD_ROOT": "/tmp/demo"])
    let hand = id(a, ["MOSSAD_ROOT": "/tmp/demo"])
    for i in [rehearsal, preview, hand] { XCTAssertEqual(i.profile, .default); XCTAssertNil(i.profileRefusal) }
    XCTAssertEqual(rehearsal.keychainService, "com.dwebber.mossad.rehearsal")
    XCTAssertEqual(rehearsal.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad Rehearsal")
    XCTAssertEqual(preview.keychainService, "com.dwebber.mossad.preview"); XCTAssertTrue(preview.emptiesSettings)
    XCTAssertEqual(preview.defaultsSuite, AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"]).defaultsSuite)
    XCTAssertEqual(hand.keychainService, "com.dwebber.mossad"); XCTAssertNil(hand.defaultsSuite)
    XCTAssertEqual(hand.dataRoot(home: home, environment: ["MOSSAD_ROOT": "/tmp/demo"]).path, "/tmp/demo")
}
func testOnlyTheRealMacAppReadsTheRegistryFile() throws {
    XCTAssertTrue(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad"], environment: [:]))
    for b in [nil, "com.dwebber.mossad.phone", AppIdentity.rehearsalBundleID, "com.apple.dt.xctest.tool"] as [String?] {
        XCTAssertFalse(AppIdentity.readsRegistry(bundleID: b, arguments: ["Mossad"], environment: [:]))
    }
    XCTAssertFalse(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad", "--ui-preview"], environment: [:]))
    XCTAssertFalse(AppIdentity.readsRegistry(bundleID: main, arguments: ["Mossad"], environment: ["MOSSAD_ROOT": "/tmp/demo"]))
    // A temp home with a registry whose active profile is Work:
    XCTAssertEqual(AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: [:], home: tmp).profile.id, "1a2b3c4d")
    XCTAssertEqual(AppIdentity.launch(bundleID: nil, arguments: ["Mossad"], environment: [:], home: tmp).profile.id, "default")
    // The same file given as MOSSAD_PROFILES, with an empty temp home:
    let made = AppIdentity.launch(bundleID: main, arguments: ["Mossad"], environment: ["MOSSAD_PROFILES": file.path], home: empty)
    XCTAssertTrue(made.madeUpRegistry); XCTAssertEqual(made.profile.id, "1a2b3c4d")
    let shown = AppIdentity.launch(bundleID: main, arguments: ["Mossad", "--ui-preview"], environment: ["MOSSAD_PROFILES": file.path, "MOSSAD_ROOT": "/tmp/demo"], home: empty)
    XCTAssertEqual(shown.profile, .default); XCTAssertEqual(shown.registry.registry.live.count, 2)
}
func testTheRegistryIsReadAndNeverChanged() throws {
    // missing file: .none, one profile. Garbage: .unreadable, one profile, the file's bytes are the same after.
    // {"version":2,...}: .newer, canSave false. An entry with id "WORK" or a second "1a2b3c4d": left out.
    // "color":"teal": .graphite. "active":"ffffffff": activeProfile is .default.
}
func testAProfilesSettingsAreNeverEmptied() throws {
    let suite = "com.dwebber.mossad.profile.1a2b3c4d"
    UserDefaults(suiteName: suite)?.set("Sam Carter", forKey: "ownerName")
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let s = try XCTUnwrap(id(["--profile", "1a2b3c4d"]).profileSettings())
    XCTAssertEqual(s.persistentDomain(forName: suite)?["ownerName"] as? String, "Sam Carter")
}
func testAProfileSuiteNeverReadsTheStandardDomain() throws {
    let key = "profileProof.\(UUID().uuidString)"
    UserDefaults.standard.set("real", forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
    let s = try XCTUnwrap(id(["--profile", "1a2b3c4d"]).profileSettings())   // remove its domain in a defer
    XCTAssertNil(s.object(forKey: key))
    s.set("profile", forKey: key)
    XCTAssertEqual(UserDefaults.standard.string(forKey: key), "real")
}
func testTheSwapHandsTheRealDomainOverOnTheMainThreadOnly() {
    let real = UserDefaults(suiteName: "com.dwebber.mossad.test-real")!, profile = UserDefaults(suiteName: "com.dwebber.mossad.test-profile")!
    let swap = DefaultsSwap(real: real, profile: profile)
    XCTAssertTrue(swap.current(handingOver: false, isMainThread: true) === profile)
    XCTAssertTrue(swap.current(handingOver: true, isMainThread: true) === real)
    XCTAssertTrue(swap.current(handingOver: true, isMainThread: false) === profile)
}
func testTheMacWideKeysAreThisList() {
    XCTAssertEqual(MacDefaults.keys, ["offUntil", "didSetLoginItem", "screenCaptureAsked", "usageStatsEnabled", "usageStatsInstallID",
                                      "usageStatsLastAttempt", "usageStatsEndpoint", "usageStatsInDebug"])
    XCTAssertEqual(MacDefaults.prefixes, ["SU", "automationState."])
}
func testAMacWideKeyInAProfilesSettingsIsAStray() {
    XCTAssertEqual(MacDefaults.strays(in: ["ownerName": "x", "SUEnableAutomaticChecks": true, "didSetLoginItem": true,
                                            "automationState.com.google.Chrome": "granted", "syncWith": "icloud"]),
                   ["SUEnableAutomaticChecks", "automationState.com.google.Chrome", "didSetLoginItem"])
}
func testAMadeUpRegistryRunsInert() {
    XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: false), .full)
    XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: true), .inert)
    XCTAssertEqual(RunMode.decide(preview: true, rehearsal: false, secondCopy: false, madeUpRegistry: false), .inert)
    XCTAssertEqual(RunMode.decide(preview: false, rehearsal: true, secondCopy: false, madeUpRegistry: false), .inert)
    XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false), .inert)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/MossadCore && swift test --filter ProfileProofTests`
Expected: the build fails with "cannot find type 'Profile' in scope".

- [ ] **Step 3: Write `Profile.swift`, `ProfileRegistry.swift` (the read side), `ProfileLaunch.swift`, and `RunMode.swift`** with the signatures and rules above.

- [ ] **Step 4: Write `MacDefaults.swift`** (`MacDefaults`, `DefaultsSwap`). `handOver` sets a flag for the time of the call and asserts the main queue; the flag is safe to read from any thread.

- [ ] **Step 5: Change `AppIdentity.swift`**: the new stored values and `init`, `launch`, `readsRegistry`, `takesProfiles`, `emptiesSettings`, `profileSettings()`, the profile cases of `keychainService`, `defaultsSuite`, `dataRoot`, `refusal`, and `isolateDefaults()`. `current` calls `launch`. `previewSettings(arguments:)` does not change.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Packages/MossadCore && swift test --filter ProfileProofTests`, then `swift test`
Expected: PASS, then "Executed N tests, with 0 failures". `AppIdentityTests` passes unchanged.

- [ ] **Step 7: Wire the app**
  - `App/MossadApp.swift:7-21`: the lines of "The first lines of `MossadEntry.main()`" (the code there already has this order; only the comments and the refusal's reach change).
  - `App/Updater.swift:28`: `controller = MacDefaults.handOver { SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil) }`.
  - `App/AppController.swift:636`: `let inert = RunMode.decide(preview: preview || AppIdentity.current.isPreview, rehearsal: Rehearsal.isOn, secondCopy: isSecondCopy, madeUpRegistry: AppIdentity.current.madeUpRegistry) == .inert`.
  - `App/AppController.swift:2063, 2066` and `App/OnboardingSteps2.swift:300, 330`: `didSetLoginItem` is read and set through `MacDefaults.store`.
  - `App/AppController.swift`, in `finishLaunch`, also in an inert copy: for a profile other than `default`, `MacDefaults.strays(in: UserDefaults.standard.persistentDomain(forName: suite) ?? [:])`; when not empty, `Log.error("Settings: Mac-wide keys in this profile's settings: <keys>")`.
  - `App/DevHooks.swift`, in `run`: only with `AppIdentity.current.madeUpRegistry` and not in a preview, `MOSSAD_PROOF_DAYS=<n>` sets `c.recordingDays = n` (through its `@AppStorage`) and logs `Log.info("Proof: updates check automatically: \(c.updater.automaticallyChecks)")`.

- [ ] **Step 8: Run the build check and the two greps**

Run: the build check of "Global Constraints"; the grep of "The first lines of `MossadEntry.main()`"; and `grep -rn '"didSetLoginItem"' App | grep "UserDefaults.standard"`.
Expected: exit status 0; 2 lines; no output.

- [ ] **Step 9: The proof run (by hand, under the rules of your brief: the call gate first, a signed build, never the installed copy's data)**

What the tests of Step 1 prove: which suite a profile gets; that the suite is not emptied; that a suite does not read or write the standard domain (Foundation's search list); which object the swap returns, on which thread; the list of Mac-wide keys. What only this run proves: that the swap of the class method works in the signed app with a suite that is kept; that `@AppStorage` writes through it; that `ToolSettings.read(.standard)` in a command reads it after a restart; that Sparkle's own hosts take the handed domain.

```sh
APP="<the signed build>/Mossad.app/Contents/MacOS/Mossad"; S=com.dwebber.mossad.profile.feedc0de
R="$(mktemp -d)"; mkdir -p "$R/Mossad Proof"
printf '{"version":1,"active":"feedc0de","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"feedc0de","name":"Proof","color":"blue","root":"%s/Mossad Proof"}]}' "$R" > "$R/profiles.json"
BEFORE="$(defaults read com.dwebber.mossad recordingDays 2>&1)"
for SEED in true false; do
  defaults write $S SUEnableAutomaticChecks -bool $SEED
  MOSSAD_PROFILES="$R/profiles.json" MOSSAD_PROOF_DAYS=47 "$APP" --profile feedc0de & PID=$!; sleep 20; kill $PID; wait $PID
  grep -h "Proof: updates check automatically" "$R/Mossad Proof/Logs/"* | tail -1
done
defaults read $S recordingDays
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app_status","arguments":{}}}' \
  | MOSSAD_PROFILES="$R/profiles.json" "$APP" --mcp --profile feedc0de | grep -o "recordings kept [0-9]* days"
defaults read $S | grep -cE '^ *"?(SU|didSetLoginItem|offUntil|usageStats)' ; grep -ch "Mac-wide keys in this profile" "$R/Mossad Proof/Logs/"*
[ "$BEFORE" = "$(defaults read com.dwebber.mossad recordingDays 2>&1)" ] && echo "real domain: same"
MOSSAD_PROFILES="$R/profiles.json" "$APP" --mcp --profile ffffffff; echo "exit $?"
defaults delete $S; rm -rf "$R"
```

Expected, in order: the two "Proof:" lines are the same (Sparkle does not follow the seed); `47`; `recordings kept 47 days`; `1` (only the seeded `SUEnableAutomaticChecks`) and a count of 1 or more for the stray line (the seeded key is found); `real domain: same`; `Mossad: no profile with the id ffffffff; not starting.` and `exit 2`. If one differs, stop and report: the rest of the plan stands on this.

- [ ] **Step 10: Commit**

```bash
git add Packages/MossadCore App
git commit -m "A process can be a profile: its own folder, Keychain service, and settings, with Sparkle and the login item on the Mac's own settings"
```

---

### Task 2: The registry's changes and the pure rules

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Profiles/ProfileRegistry.swift`
- Create: `.../Profiles/ProfileRules.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileRulesTests.swift` (new)

**Interfaces:**
- Consumes: `Profile`, `ProfileColor`, `ProfileRegistry`, `ProfileRegistry.Loaded`, `ProfileLaunch.choice` (Task 1).
- Produces:

```swift
extension ProfileRegistry {
    public struct ReadOnly: Error {}
    public mutating func add(name: String, color: ProfileColor, takenFolders: Set<String>, random: () -> String = ProfileRules.randomID) -> Profile
    public mutating func rename(_ id: String, name: String, color: ProfileColor)
    public mutating func setActive(_ id: String)
    public mutating func setServer(_ hash: String?, for id: String)
    public mutating func markRemoving(_ id: String)
    public mutating func remove(_ id: String)
    public var removing: [Profile] { get }
}
extension ProfileRegistry.Loaded {
    public func save(to file: URL) throws     // one atomic write; makes the folder; throws ReadOnly when !canSave
}
public enum ProfileRules {
    public static let nameLimit = 40
    public static func nameProblem(_ typed: String, in registry: ProfileRegistry, renaming id: String? = nil) -> String?
    public static func folderName(for name: String, taken: Set<String>) -> String     // `taken` in lower case
    public static func randomID() -> String                                            // 8 characters of 0-9a-f
    public static func newID(taken: Set<String>, random: () -> String) -> String
    public static func nextColor(in registry: ProfileRegistry) -> ProfileColor
    public static func deleteProblem(_ id: String, in registry: ProfileRegistry, active: String, typed: String) -> String?
    public static func serverHash(_ address: URL) -> String
    public static func serverOwner(of address: URL, in registry: ProfileRegistry, except id: String) -> Profile?
    public static func serverRefusal(_ owner: Profile) -> String
}
public enum ProfileSwitch {
    public static let refusal = "A call is recording. Switch when it ends."
    public static let addRefusal = "A call is recording. Add a profile when it ends."
    public enum Decision: Equatable, Sendable { case go(save: Bool, arguments: [String]), refused(String), stay }
    public static func decide(to id: String, registry: ProfileRegistry.Loaded, active: String, recording: Bool, arguments: [String]) -> Decision
    public enum AfterStart: Equatable, Sendable { case quit, restore(active: String), stay }
    public static func afterStart(started: Bool, saved: Bool, was active: String) -> AfterStart
    public static func waitSeconds(_ arguments: [String]) -> TimeInterval     // 10 with "--switched", else 0
}
public struct ProfileMenu: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable { public let id: String, name: String, color: ProfileColor, active: Bool }
    public static let add = "Add profile…", manage = "Manage profiles…"
    public let rows: [Row]
    public let title: String, color: ProfileColor     // the active profile's
    public let note: String?                          // ProfileSwitch.refusal while a call records
    public init?(_ registry: ProfileRegistry, active: String, recording: Bool)   // nil with fewer than 2 live profiles
}
```

Words: `nameProblem` gives "Give the profile a name." or "Another profile has this name."; `deleteProblem` gives "The first profile cannot be deleted.", "Switch to another profile first.", or "Type the profile's name to delete it." (the typed name must equal the name after spaces at both ends are removed); `serverRefusal` gives "The profile “<name>” already uses this server. Each profile needs its own server."

`decide`: `recording` gives `.refused(refusal)`; an id that is not live, the active id, or an unreadable registry gives `.stay`; else `.go`. The arguments are the current ones without the program's name, without `--profile <value>`, `--switched`, `--background`, and `--open-window <value>`, then `--switched`, then `--profile <id>` only when the registry cannot be saved.

- [ ] **Step 1: Write the failing tests**

```swift
func testAFolderNameIsMadeUnique() {
    XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: []), "Mossad Work")
    XCTAssertEqual(ProfileRules.folderName(for: "Work", taken: ["mossad work"]), "Mossad Work 2")
    XCTAssertEqual(ProfileRules.folderName(for: "work", taken: ["mossad work", "mossad work 2"]), "Mossad work 3")
    XCTAssertEqual(ProfileRules.folderName(for: "Rehearsal", taken: []), "Mossad Rehearsal 2")
    XCTAssertEqual(ProfileRules.folderName(for: "A/B: #1", taken: []), "Mossad AB 1")
    XCTAssertEqual(ProfileRules.folderName(for: "🙂", taken: []), "Mossad Profile")
    XCTAssertEqual(ProfileRules.folderName(for: String(repeating: "a", count: 60), taken: []), "Mossad " + String(repeating: "a", count: 40))
}
func testANewIDIs8HexCharactersAndNotTaken() {
    var answers = ["1a2b3c4d", "1a2b3c4d", "9f8e7d6c"]
    XCTAssertEqual(ProfileRules.newID(taken: ["1a2b3c4d"]) { answers.removeFirst() }, "9f8e7d6c")
    XCTAssertNotNil(ProfileRules.randomID().wholeMatch(of: /[0-9a-f]{8}/))
}
func testAddMakesAnEntryAndKeepsTheFolderOnARename() {
    var r = ProfileRegistry()
    let p = r.add(name: " Work ", color: .blue, takenFolders: []) { "1a2b3c4d" }
    XCTAssertEqual(p, Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work"))
    XCTAssertEqual(r.active, "default"); XCTAssertEqual(r.live.map(\.id), ["default", "1a2b3c4d"])
    r.rename("1a2b3c4d", name: "Client", color: .green)
    XCTAssertEqual(r.profile("1a2b3c4d")?.root, "~/Mossad Work"); XCTAssertEqual(r.profile("1a2b3c4d")?.name, "Client")
    XCTAssertEqual(ProfileRules.nextColor(in: ProfileRegistry()), .blue)
}
func testANameMustBeThereAndNotTaken() {
    // "" and "  " give "Give the profile a name."; "work" with a profile "Work" gives "Another profile has this name.";
    // the same name is fine when renaming that profile; "Personal" gives nil.
}
func testANewerOrUnreadableRegistryIsNeverSaved() throws {
    // Loaded(state: .newer).save and Loaded(state: .unreadable).save throw ProfileRegistry.ReadOnly and write nothing.
    // Loaded(state: .none).save writes; load(from:) then gives the same registry with state .read.
    // The saved JSON has the keys "version", "profiles", "active", and each profile "id", "name", "color", "root".
}
func testTheDeleteRule() {
    // default: "The first profile cannot be deleted."; the active one: "Switch to another profile first.";
    // typed "work" for "Work": "Type the profile's name to delete it."; typed " Work ": nil.
}
func testARemovingProfileCannotStartAndDoesNotShow() {
    var r = two; r.markRemoving("1a2b3c4d")
    XCTAssertNil(r.profile("1a2b3c4d")); XCTAssertEqual(r.live.map(\.id), ["default"]); XCTAssertEqual(r.removing.map(\.id), ["1a2b3c4d"])
    XCTAssertEqual(ProfileLaunch.choice(arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: .init(registry: r, state: .read)),
                   .refused("Mossad: no profile with the id 1a2b3c4d; not starting."))
    XCTAssertNil(ProfileMenu(r, active: "default", recording: false))
}
func testASwitchIsRefusedWhileACallRecords() {
    XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: read, active: "default", recording: true, arguments: ["Mossad"]),
                   .refused("A call is recording. Switch when it ends."))
}
func testASwitchDuringProcessingGoes() {
    // The decision does not ask about processing: a meeting in work keeps its state on disk.
    XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: read, active: "default", recording: false,
                                        arguments: ["Mossad", "--background", "--profile", "default", "-ownerName", "Sam Carter", "--open-window", "Settings"]),
                   .go(save: true, arguments: ["-ownerName", "Sam Carter", "--switched"]))
    XCTAssertEqual(ProfileSwitch.decide(to: "1a2b3c4d", registry: newer, active: "default", recording: false, arguments: ["Mossad"]),
                   .go(save: false, arguments: ["--switched", "--profile", "1a2b3c4d"]))
    XCTAssertEqual(ProfileSwitch.decide(to: "default", registry: read, active: "default", recording: false, arguments: ["Mossad"]), .stay)
    XCTAssertEqual(ProfileSwitch.decide(to: "ffffffff", registry: read, active: "default", recording: false, arguments: ["Mossad"]), .stay)
    XCTAssertEqual(ProfileSwitch.waitSeconds(["Mossad", "--switched"]), 10); XCTAssertEqual(ProfileSwitch.waitSeconds(["Mossad"]), 0)
}
func testAFailedStartPutsTheActiveProfileBack() {
    XCTAssertEqual(ProfileSwitch.afterStart(started: true, saved: true, was: "default"), .quit)
    XCTAssertEqual(ProfileSwitch.afterStart(started: false, saved: true, was: "default"), .restore(active: "default"))
    XCTAssertEqual(ProfileSwitch.afterStart(started: false, saved: false, was: "default"), .stay)
}
func testTheSwitcherShowsOnlyWithTwoProfiles() {
    XCTAssertNil(ProfileMenu(ProfileRegistry(), active: "default", recording: false))
    let m = try XCTUnwrap(ProfileMenu(two, active: "1a2b3c4d", recording: false))
    XCTAssertEqual(m.rows, [.init(id: "default", name: "Mossad", color: .orange, active: false), .init(id: "1a2b3c4d", name: "Work", color: .blue, active: true)])
    XCTAssertEqual(m.title, "Work"); XCTAssertEqual(m.color, .blue); XCTAssertNil(m.note)
    XCTAssertEqual(ProfileMenu(two, active: "default", recording: true)?.note, "A call is recording. Switch when it ends.")
}
func testAServerBelongsToOneProfile() {
    let a = URL(string: "https://notes.example.com")!
    var r = two; r.setServer(ProfileRules.serverHash(a), for: "default")
    XCTAssertEqual(ProfileRules.serverHash(a).count, 64)
    XCTAssertEqual(ProfileRules.serverHash(URL(string: "https://NOTES.example.com")!), ProfileRules.serverHash(a))
    XCTAssertEqual(ProfileRules.serverOwner(of: a, in: r, except: "1a2b3c4d")?.id, "default")
    XCTAssertNil(ProfileRules.serverOwner(of: a, in: r, except: "default"))
    XCTAssertNil(ProfileRules.serverOwner(of: URL(string: "https://other.example.com")!, in: r, except: "1a2b3c4d"))
    XCTAssertEqual(ProfileRules.serverRefusal(.default), "The profile “Mossad” already uses this server. Each profile needs its own server.")
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter ProfileRulesTests`. Expected: the build fails with "cannot find 'ProfileRules' in scope".
- [ ] **Step 3: Write the registry's changes and `ProfileRules.swift`** (`ProfileRules`, `ProfileSwitch`, `ProfileMenu`). `folderName` always counts "mossad" and "mossad rehearsal" as taken. `add` makes the id with `newID`, the folder with `folderName`, and the root as `"~/" + folder`.
- [ ] **Step 4: Run to verify they pass.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 5: Commit.** `git commit -m "The profile registry is saved in one write, and the rules of a name, a folder, a switch, and a delete are pure"`

---

### Task 3: Mac-wide: not recording, the usage statistics, the permission memory

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Calendar/NoRecordBook.swift:142-165, 223-237`; `.../Telemetry/UsageReportPlan.swift:69, 75`
- Modify: `App/AppController.swift:188, 500, 603-605, 1490-1492, 1507-1510`; `App/AppController+UsageStats.swift:12, 19, 57`; `App/PermissionsMonitor.swift:103-112, 126-127, 198`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/NoRecordBookTests.swift` (new methods), `ProfileProofTests.swift` (one new method)

**Interfaces:**
- Consumes: `MacDefaults.store` (Task 1); `ProfileRegistry.live`, `Profile.rootURL(home:)` (Task 1).
- Produces:

```swift
extension NoRecordBook {
    public static func peek(from dir: URL) -> NoRecordBook                              // reads only; never moves a file
    public static func forGate(own: NoRecordBook, others: [NoRecordBook]) -> NoRecordBook
}
extension NoRecordGate {
    public func adopt(sessionsIn dirs: [URL])        // after persistSession(in:); reads only
}
// UsageReportPlan: the default argument of installID(_:) and resetInstallID(_:) becomes MacDefaults.store.
// App/AppController.swift
var otherNoRecord: [NoRecordBook]                   // stored; read once at launch
var otherNoRecordFolders: [URL] { get }             // every live profile's NoRecord folder except this process's; [] when !takesProfiles
```

Rules: `peek` gives an empty book for a missing file; a book with `unreadable` true for a file that does not decode, or for a missing file beside a set-aside one (as `load` does); it never writes. `forGate` has the rules of `own` and of every other book, the `ended` of `own` only, and is `unreadable` when any book is. `adopt` takes the session with the newest `lastSeen` that has not ended, only when the gate has no session of its own that is newer and not ended, and sets its `title` to nil; it does not write the other folder.

- [ ] **Step 1: Write the failing tests**

```swift
func testARefusalInAnotherProfileBlocksTheCall() {
    // other: set(.skipSeries, for: meeting). own: empty.
    let gate = NoRecordBook.forGate(own: own, others: [other])
    XCTAssertTrue(gate.blocks(platform: .zoom, meetingID: id, at: start, events: [event]))
    XCTAssertEqual(own.choice(for: meeting), .record)             // the active profile's pages do not show it
    XCTAssertFalse(NoRecordBook.forGate(own: own, others: []).blocks(platform: .zoom, meetingID: id, at: start, events: [event]))
}
func testOnlyTheActiveProfilesEndedRulesKeepNotesOut() {
    // other has the series in `ended`: forGate(own: own, others: [other]).excludesNotes(of: event) is false.
}
func testAnotherProfilesListIsReadAndNeverChanged() throws {
    // dir holds no-record.json with the bytes "{": peek(from: dir).unreadable is true, the file's bytes are the same,
    // and the folder holds exactly that one file. A missing folder: an empty book, and no folder is made.
    // forGate(own: NoRecordBook(), others: [peek(from: dir)]).unreadable is true.
}
func testABlockedCallGoesOnAfterASwitch() {
    // Gate A (book blocks the invite, persistSession(in: dirA)): blocksStart(...) is true.
    // Gate B: persistSession(in: dirB); adopt(sessionsIn: [dirA]); update(events: []).
    XCTAssertTrue(b.blocksStart(platform: .zoom, bundleID: "us.zoom.xos", meetingID: id, at: start.addingTimeInterval(120)))
    XCTAssertEqual(b.currentBlock?.title, "")                      // the other profile's title is not carried
}
func testAnEndedBlockOfAnotherProfileIsNotAdopted() {
    // Gate A's call ended (callEnded(at:)); gate B adopts; b.blocksStart(... no invite ...) is false.
}
// ProfileProofTests:
func testTheInstallIDIsTheMacsOwn() {
    // With nothing held, MacDefaults.store === UserDefaults.standard, so installID() reads what it reads today.
    XCTAssertTrue(MacDefaults.store === UserDefaults.standard)
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter NoRecordBookTests`. Expected: the build fails with "type 'NoRecordBook' has no member 'forGate'".
- [ ] **Step 3: Write `peek`, `forGate`, and `adopt`**, and change the two default arguments in `UsageReportPlan.swift`.
- [ ] **Step 4: Run to verify they pass.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 5: Wire the app**
  - `AppController.swift:188`: `@AppStorage("offUntil", store: MacDefaults.store)`. `:500`: `@AppStorage(UsageReportPlan.enabledKey, store: MacDefaults.store)`.
  - `:603-605`: after the own book is read, `otherNoRecord = otherNoRecordFolders.map(NoRecordBook.peek)` (kept for the launch), the gate gets `NoRecordBook.forGate(own: noRecord, others: otherNoRecord)`, then `persistSession(in:)`, then `adopt(sessionsIn: otherNoRecordFolders)`. `:1491` and `:1509` give the gate the same `forGate` book. The saves at `:1492` and `:1510` keep `paths.noRecord`.
  - `AppController+UsageStats.swift:12, 57` and the endpoint read: `MacDefaults.store`. `:19`: when the gate does not allow and `usageStatsEnabled` is false, delete this profile's counters off the main thread.
  - `PermissionsMonitor.swift`: the three keys' reads and writes go through `MacDefaults.store`.
- [ ] **Step 6: Run the build check and the grep.** Run: the build check, and `grep -rnE '"offUntil"|screenAskedKey|automationState|usageStats(Enabled|InstallID|LastAttempt|Endpoint|InDebug)|UsageReportPlan\.(enabledKey|installIDKey|lastAttemptKey|endpointKey|debugKey)' App | grep "UserDefaults.standard"`. Expected: exit status 0; no output.
- [ ] **Step 7: Commit.** `git commit -m "The Off switch, the usage statistics, and the permission memory are the Mac's own, and a refusal to record holds in every profile"`

---

### Task 4: Sync and backup apart

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Support/AppIdentity.swift`; `.../Sync/CloudKitStore.swift:7-22, 51, 65, 106, 116`; `.../Support/SharedAIKey.swift:19-59`; `.../Sync/ServerPairing.swift:27-68`; `.../Cloud/BucketArchive.swift:8-21`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileSyncTests.swift` (new)

**Interfaces:**
- Consumes: `AppIdentity.profile` (Task 1).
- Produces:

```swift
// AppIdentity
public var cloudZone: String { get }                         // "Mossad" | "Mossad-<id>"
public var backupPrefix: String { get }                      // "" | "profiles/<id>/"
// CloudKitStore
public init(zone: String = AppIdentity.current.cloudZone)
static func zoneID(named: String) -> CKRecordZone.ID
public static func mayDelete(zone: String) -> Bool           // only "Mossad-" and 8 characters of 0-9a-f
public static func deleteZone(named: String) async throws    // throws when !mayDelete; a zone that is not there is a success
// SharedAIKey, ServerPairing (every parameter defaults to AppIdentity.current.profile.id)
static func account(profile: String) -> String               // "ai" | "ai.<id>"; "server" | "server.<id>"
static func query(profile: String) -> [String: Any]
SharedAIKey.load(profile:), save(profile:), delete(profile:)
ServerPairing.shared(profile:), share(_:profile:), unshare(profile:)
// BucketArchive
public init(config: S3Config, session: URLSession = .shared, root: String = AppIdentity.current.backupPrefix)
```

The zone becomes a stored value of the store; `id(_:)` becomes an instance method. Record names and types do not change. `BucketArchive.key(for:)` and the list in `recordingCount()` start with `root`. The server archive does not change: a server is one profile's.

- [ ] **Step 1: Write the failing tests**

```swift
func testTheDefaultProfileKeepsTodaysZoneAccountsAndKeys() {
    let d = AppIdentity(bundleID: main)
    XCTAssertEqual(d.cloudZone, "Mossad"); XCTAssertEqual(d.backupPrefix, "")
    XCTAssertEqual(SharedAIKey.account(profile: "default"), "ai"); XCTAssertEqual(ServerPairing.account(profile: "default"), "server")
    XCTAssertEqual(BucketArchive(config: config, root: "").key(for: "20261116-090000"), "calls/20261116-090000/recording.m4a")
    XCTAssertEqual(CloudKitStore.zoneID(named: d.cloudZone).zoneName, "Mossad")
}
func testTwoProfilesNeverShareAZoneOrASyncState() {
    let w = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two)
    XCTAssertEqual(w.cloudZone, "Mossad-1a2b3c4d")
    XCTAssertEqual(CloudKitStore.zoneID(named: w.cloudZone).zoneName, "Mossad-1a2b3c4d")
    XCTAssertEqual(Paths(root: w.dataRoot(home: home, environment: [:])).sync.path, "/Users/someone/Mossad Work/Sync")
    XCTAssertEqual(Paths(root: AppIdentity(bundleID: main).dataRoot(home: home, environment: [:])).sync.path, "/Users/someone/Mossad/Sync")
}
func testTheFirstProfilesZoneCanNeverBeDeleted() {
    for zone in ["Mossad", "", "Mossad-", "Mossad-default", "mossad-1a2b3c4d", "Mossad-1A2B3C4D"] { XCTAssertFalse(CloudKitStore.mayDelete(zone: zone), zone) }
    XCTAssertTrue(CloudKitStore.mayDelete(zone: "Mossad-1a2b3c4d"))
}
func testAProfileNeverNamesTheDefaultSharedItems() {
    XCTAssertEqual(SharedAIKey.query(profile: "1a2b3c4d")[kSecAttrAccount as String] as? String, "ai.1a2b3c4d")
    XCTAssertEqual(ServerPairing.query(profile: "1a2b3c4d")[kSecAttrAccount as String] as? String, "server.1a2b3c4d")
    XCTAssertEqual(SharedAIKey.query(profile: "default")[kSecAttrAccount as String] as? String, "ai")
    XCTAssertEqual(ServerPairing.query(profile: "default")[kSecAttrAccount as String] as? String, "server")
    XCTAssertEqual(SharedAIKey.query(profile: "1a2b3c4d")[kSecAttrAccessGroup as String] as? String, SharedAIKey.accessGroup)
}
func testAProfilesBackupIsUnderItsOwnPrefix() {
    let w = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two)
    XCTAssertEqual(w.backupPrefix, "profiles/1a2b3c4d/")
    XCTAssertEqual(BucketArchive(config: config, root: w.backupPrefix).key(for: "20261116-090000"), "profiles/1a2b3c4d/calls/20261116-090000/recording.m4a")
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter ProfileSyncTests`. Expected: the build fails with "value of type 'AppIdentity' has no member 'cloudZone'".
- [ ] **Step 3: Write the code** with the signatures above. The app's call sites (`AppController+Sync.swift:38, 42, 94, 111, 113, 125`, `AppController+Backup.swift:23`) and the phone's (`PhoneStore.swift:159, 308, 320`) do not change: the defaults give the process's own profile.
- [ ] **Step 4: Run to verify they pass.** Run the filter, then `swift test`. Expected: PASS, then 0 failures; `CloudArchiveTests` and `ArchiveMoveTests` pass unchanged.
- [ ] **Step 5: Check that no call names another profile.** Run: `grep -rn "profile: " App PhoneApp | grep -E "SharedAIKey|ServerPairing|CloudKitStore"`. Expected: no output (Task 8 adds the one use, in the delete).
- [ ] **Step 6: Commit.** `git commit -m "Each profile has its own iCloud zone, its own two iCloud Keychain items, and its own prefix in a backup bucket"`

---

### Task 5: The note's audio line

**Files:**
- Modify: `Packages/MossadCore/Sources/MossadCore/Support/AppIdentity.swift`; `.../Output/MarkdownWriter.swift:57-63, 75, 91`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MarkdownWriterTests.swift` (new methods)

**Interfaces:**
- Consumes: `AppIdentity.profile` (Task 1).
- Produces: `AppIdentity.noteRoot: String` (`profile.root` for a profile other than `default`, else `"~/Mossad"`); `MarkdownWriter.audioRoot: String` (a static, `AppIdentity.current.noteRoot`); `MarkdownWriter.render(_ r: CallRecord, audioRoot: String = MarkdownWriter.audioRoot) -> String`. `isNote(_:of:)` keeps its signature and is true for a line that starts with `audio: ` and ends with `/Audio/<id>`.

- [ ] **Step 1: Write the failing tests**

```swift
func testAProfilesNoteNamesItsOwnFolder() {
    XCTAssertTrue(MarkdownWriter.render(fixture(), audioRoot: "~/Mossad Work").contains("\naudio: ~/Mossad Work/Audio/20261020-143000\n"))
    XCTAssertEqual(AppIdentity(bundleID: AppIdentity.mainBundleID).noteRoot, "~/Mossad")
    XCTAssertEqual(AppIdentity(bundleID: AppIdentity.rehearsalBundleID).noteRoot, "~/Mossad")
}
func testANoteOfAnyFolderIsFoundByItsCallID() throws {
    // Files whose front matter has this line, asked with isNote(url, of: "c1"):
    // "audio: ~/Mossad/Audio/c1" true; "audio: ~/Mossad Work/Audio/c1" true; "audio: /Volumes/x/Mossad/Audio/c1" true;
    // "audio: ~/Mossad Work/Audio/c12" false; "audio: ~/Mossad/Audio/c1/x" false; "note: see /Audio/c1" false.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter MarkdownWriterTests`. Expected: the build fails with "extra argument 'audioRoot' in call".
- [ ] **Step 3: Write the code.** The callers (`Pipeline.swift:969, 1392`, `PeopleMigration.swift:720`) do not change.
- [ ] **Step 4: Run to verify they pass.** Run the filter, then `swift test`. Expected: PASS, then 0 failures; the golden test passes unchanged.
- [ ] **Step 5: Commit.** `git commit -m "A note names its own profile's folder in its audio line, and a note is found by its call id in any folder"`

---

### Task 6: MCP for each profile, and the commands

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Chat/MCPCommand.swift`
- Modify: `.../Chat/MCPServer.swift:11-36, 58`; `.../Persona/PersonaFill.swift`; `App/MossadApp.swift:30-39, 55-60`; `App/SettingsAI.swift:110-116`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/MCPCommandTests.swift` (new), `MCPServerTests.swift` (one new method)

**Interfaces:**
- Consumes: `Profile`, `AppIdentity.profile`, `AppIdentity.registry` (Task 1); `InstanceLock.acquire(root:)`.
- Produces:

```swift
public struct MCPCommand: Equatable, Sendable {
    public let serverName: String
    public let arguments: [String]                     // ["--mcp"] | ["--mcp", "--profile", "<id>"]
    public init(profile: Profile, among profiles: [Profile])
    public func claudeCode(binary: String) -> String
    public func desktop(binary: String) -> String
}
// MCPServer: both inits gain `name: String = "mossad"`, which `serverInfo` gives.
// PersonaFill
public static func openMessage(_ profile: Profile) -> String
```

`openMessage` gives "Quit Mossad first: the fill writes the files that the app keeps." for `default` (today's text) and "Mossad has this profile open. Switch to another profile or quit Mossad first: the fill writes the files that the app keeps." for another.

- [ ] **Step 1: Write the failing tests**

```swift
private let bin = "/Applications/Mossad.app/Contents/MacOS/Mossad"
func testTheDefaultCommandIsTodaysText() {
    let c = MCPCommand(profile: .default, among: [.default])
    XCTAssertEqual(c.serverName, "mossad"); XCTAssertEqual(c.arguments, ["--mcp"])
    XCTAssertEqual(c.claudeCode(binary: bin), "claude mcp add --scope user mossad -- \"\(bin)\" --mcp")
    XCTAssertEqual(c.desktop(binary: bin), "\"mossad\": { \"command\": \"\(bin)\", \"args\": [\"--mcp\"] }")
    var renamed = Profile.default; renamed.name = "Work"
    XCTAssertEqual(MCPCommand(profile: renamed, among: [renamed]).serverName, "mossad")
}
func testAProfilesCommandNamesItAndPassesItsID() {
    let p = Profile(id: "1a2b3c4d", name: "Personal", color: .blue, root: "~/Mossad Personal")
    let c = MCPCommand(profile: p, among: [.default, p])
    XCTAssertEqual(c.serverName, "mossad-personal"); XCTAssertEqual(c.arguments, ["--mcp", "--profile", "1a2b3c4d"])
    XCTAssertEqual(c.claudeCode(binary: bin), "claude mcp add --scope user mossad-personal -- \"\(bin)\" --mcp --profile 1a2b3c4d")
    XCTAssertEqual(c.desktop(binary: bin), "\"mossad-personal\": { \"command\": \"\(bin)\", \"args\": [\"--mcp\", \"--profile\", \"1a2b3c4d\"] }")
}
func testTheServerNameIsLettersAndDigits() {
    // "Client A" gives "mossad-clienta"; "Café 2" gives "mossad-cafe2"; "!!" gives "mossad-1a2b3c4d";
    // "Client A" (1a2b3c4d) with "ClientA" (9f8e7d6c) among the profiles: "mossad-clienta-1a2b3c4d" and "mossad-clienta-9f8e7d6c".
}
func testTheFillSaysWhichCopyToClose() {
    XCTAssertEqual(PersonaFill.openMessage(.default), "Quit Mossad first: the fill writes the files that the app keeps.")
    XCTAssertEqual(PersonaFill.openMessage(Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")),
                   "Mossad has this profile open. Switch to another profile or quit Mossad first: the fill writes the files that the app keeps.")
}
// MCPServerTests:
func testServerInfoSaysTheProfilesName() throws {
    // MCPServer(paths:owner:name: "mossad-personal") answers initialize with serverInfo.name "mossad-personal".
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter MCPCommandTests`. Expected: the build fails with "cannot find 'MCPCommand' in scope".
- [ ] **Step 3: Write `MCPCommand.swift`, the `name` of `MCPServer`, and `PersonaFill.openMessage`.**
- [ ] **Step 4: Run to verify they pass.** Run the filter, then `swift test`. Expected: PASS, then 0 failures; the existing `MCPServerTests` pass unchanged.
- [ ] **Step 5: Wire the app**
  - `App/MossadApp.swift:38`: `MCPServer(paths: .live, owner: owner, name: MCPCommand(profile: identity.profile, among: identity.registry.registry.live).serverName, settings: …)`.
  - `App/MossadApp.swift:58-60`: in place of the look for a running app, with `--go`: `InstanceLock.acquire(root: Paths.live.root)`. `.taken` prints `PersonaFill.openMessage(identity.profile)` and exits with 1; `.held` keeps the lock until the command ends; `.failed` goes on. The other commands need no change: they read `Paths.live`, `Keychain.app`, and `UserDefaults.standard`, which are the profile's.
  - `App/SettingsAI.swift:112-114`: `MCPSetup` makes its two texts with `MCPCommand(profile: AppIdentity.current.profile, among: AppIdentity.current.registry.registry.live)` and `DevHooks.shownBinary`.
- [ ] **Step 6: Run the build check.** Expected: exit status 0.
- [ ] **Step 7: Commit.** `git commit -m "Each profile has its own MCP command and server name, and the persona fill asks only for its own profile's folder"`

---

### Task 7: Switch and Add in the app, one foreground app, and one server for each profile

**Files:**
- Create: `App/AppController+Profiles.swift`
- Modify: `Packages/MossadCore/Sources/MossadCore/Support/InstanceLock.swift`; `.../Profiles/ProfileLaunch.swift`; `App/MossadApp.swift:17-19, 244-246`; `App/AppController.swift:377-386, 623-635`; `App/AppController+SecondCopy.swift:15`; `App/AppController+Sync.swift:56-96`; `App/ServerSetupSheet.swift:46-50, 167-169`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileRulesTests.swift` (new methods), `OnboardingTests.swift` (one new method)

**Interfaces:**
- Consumes: `ProfileRegistry` and its changes, `ProfileRules`, `ProfileSwitch`, `ProfileMenu` (Tasks 1 and 2); `AppIdentity.current` (Task 1).
- Produces:

```swift
// InstanceLock
public static func waitUntilFree(root: URL, timeout: TimeInterval, every: TimeInterval = 0.2) -> Bool   // looks and lets go; true when free
// ProfileLaunch
public static func takesForegroundLock(_ identity: AppIdentity) -> Bool   // takesProfiles, a registry file was read, not a made-up one
// AppController (stored, in AppController.swift)
@Published var profiles: ProfileRegistry.Loaded      // starts as AppIdentity.current.registry
@Published var profileProblem: String?
// AppController+Profiles.swift
var activeProfile: Profile { get }                   // AppIdentity.current.profile; in a preview, profiles.registry.activeProfile
var profileMenu: ProfileMenu? { get }
func switchProfile(to id: String)
func addProfile(name: String, color: ProfileColor)
func renameProfile(_ id: String, name: String, color: ProfileColor)
func noteServer(_ address: URL?)                     // this profile's hash in the registry
```

- [ ] **Step 1: Write the failing tests**

```swift
func testTheNewInstanceWaitsForTheLocks() throws {
    // A temp folder. Hold its lock; let it go after 0.3 s on another queue:
    XCTAssertTrue(InstanceLock.waitUntilFree(root: dir, timeout: 2, every: 0.05))
    // Hold it for the whole test:
    XCTAssertFalse(InstanceLock.waitUntilFree(root: dir, timeout: 0.3, every: 0.05))
    // A folder that is not there cannot be locked by anyone:
    XCTAssertTrue(InstanceLock.waitUntilFree(root: missing, timeout: 0.3))
}
func testOnlyOneForegroundAppForTheMac() {
    XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main)))                        // no registry file: as today
    XCTAssertTrue(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, registry: read)))
    XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, registry: read, madeUpRegistry: true)))
    XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: read)))
    XCTAssertFalse(ProfileLaunch.takesForegroundLock(AppIdentity(bundleID: AppIdentity.rehearsalBundleID, registry: read)))
}
// OnboardingTests:
func testANewProfileStartsSetupWithThePermissionsDone() {
    let facts = OnboardingFacts(granted: Set(OnboardingPermissions.required))
    XCTAssertTrue(Onboarding.opensAtLaunch(finished: false, hasMeetings: false, preview: false, forced: false, rehearsal: false))
    XCTAssertEqual(OnboardingProgress().state(of: .permissions, facts: facts), .done)
    XCTAssertEqual(OnboardingProgress().state(of: .welcome, facts: facts), .current)
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter ProfileRulesTests`. Expected: the build fails with "type 'InstanceLock' has no member 'waitUntilFree'".
- [ ] **Step 3: Write `waitUntilFree` and `takesForegroundLock`.** Run the filters, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: The launch**
  - `App/MossadApp.swift`, after `isolateDefaults()` and only with none of `AppIdentity.commands`: `let seconds = ProfileSwitch.waitSeconds(CommandLine.arguments)`; when above 0, `waitUntilFree(root: ProfileRegistry.folder(home:), timeout: seconds)`, then `waitUntilFree(root: Paths.live.root, timeout: <what is left>)`.
  - `App/AppController.swift:623-635`: when `ProfileLaunch.takesForegroundLock(AppIdentity.current)`, take `InstanceLock.acquire(root: ProfileRegistry.folder(home:))` first and keep it for the life of the app; `.taken` is handled as the folder's `.taken` is (the second copy, with today's words). `AppController+SecondCopy.swift:15` looks at both locks.
  - `App/MossadApp.swift:244`: `--switched` opens the main window, also in the first minutes after a start of the Mac.
- [ ] **Step 5: Write `AppController+Profiles.swift`**
  - `switchProfile(to:)`: does nothing in an inert copy. `ProfileSwitch.decide(...)` with `isRecording`. `.refused` sets `profileProblem`. `.go`: read the registry again from the file, `setActive`, save (when `save`); start a new instance as `restartAsWorkingCopy` does (`createsNewApplicationInstance`, the decision's arguments, this process's environment); then `ProfileSwitch.afterStart(started:saved:was:)` with the proof of a new process (another pid, not ended): `.quit` quits; `.restore` saves the old `active` again; `.restore` and `.stay` set `profileProblem = "Could not switch. Mossad stays in <name>."`.
  - `addProfile(name:color:)`: refused while a call records (`ProfileSwitch.addRefusal`) or with a `nameProblem`. Reads the names in the home folder (lower case) for `takenFolders`, calls `add`, makes the empty folder, sets this profile's server hash (`noteServer`), saves, then `switchProfile(to:)`. When the folder cannot be made, the registry does not change and `profileProblem` says "The folder for this profile could not be made."
  - `renameProfile`: `nameProblem`, `rename`, save.
  - Every change of the registry is refused with `profileProblem = "The list of profiles could not be read. Mossad did not change it."` when `!profiles.canSave`, except a switch on a newer file.
- [ ] **Step 6: One server for each profile**
  - `App/ServerSetupSheet.swift:168`, at the start of `checkAddress()`: when `ProfileRules.serverOwner(of: url, in: controller.profiles.registry, except: controller.activeProfile.id)` answers, `addressCheck = .failed(ProfileRules.serverRefusal(owner))` and no request goes out.
  - `App/ServerSetupSheet.swift:46-50`: when `controller.profileMenu != nil`, step 1 has one more line: "Each profile needs its own server: its own Worker, address, secret, database, and bucket."
  - `App/AppController+Sync.swift`: `connectServer` returns without a change when the address has another owner, and calls `noteServer(c.address)` when it connects; `disconnectServer` calls `noteServer(nil)`. `noteServer` writes only when a registry file exists and the hash differs.
- [ ] **Step 7: Run the build check.** Expected: exit status 0.
- [ ] **Step 8: Commit.** `git commit -m "The owner adds a profile and changes from one to the other; one copy is the foreground app, and a server belongs to one profile"`

---

### Task 8: Delete a profile

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/ProfileRemoval.swift`
- Modify: `App/AppController+Profiles.swift`; `App/AppController.swift` (in `finishLaunch`)
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileRemovalTests.swift` (new)

**Interfaces:**
- Consumes: `Profile`, `ProfileRegistry.markRemoving`, `remove`, `removing`, `ProfileRules.deleteProblem` (Tasks 1 and 2); `CloudKitStore.deleteZone(named:)`, `SharedAIKey.delete(profile:)`, `ServerPairing.unshare(profile:)` (Task 4); `Keychain(service:)`, `APIKey.allCases`; `InstanceLock.acquire(root:)`.
- Produces:

```swift
public enum ProfileRemoval {
    public enum Step: String, CaseIterable, Sendable { case sharedItems, keys, settings, folder, zone }
    public struct Names: Equatable, Sendable { public let id, service, suite, zone: String; public let root: URL }
    public static func names(of profile: Profile, home: URL) -> Names
    public struct Actions: Sendable {
        public var sharedItems: @Sendable (String) -> Void             // the profile's id
        public var keys: @Sendable (String) -> Void                    // the service
        public var settings: @Sendable (String) -> Void                // the suite
        public var trash: @Sendable (URL) throws -> Void
        public var zone: @Sendable (String) async throws -> Void
    }
    public struct Outcome: Equatable, Sendable { public var done: [Step]; public var failed: Step?; public var complete: Bool { get } }
    public static func mayTrash(_ root: URL, home: URL, others: [URL]) -> Bool
    public static func run(_ profile: Profile, home: URL, others: [Profile], actions: Actions) async -> Outcome
    public static let serverNote = "This profile used a server. Mossad does not remove it: it is yours to remove."
    public static let bucketNote = "Recordings that this profile backed up to a bucket stay in the bucket."
}
// AppController+Profiles.swift
func deleteProfile(_ id: String, typed: String)
func finishRemovals()
```

`run` does the steps in the order of `Step.allCases` and stops at the first one that throws. The folder step is skipped (and counts as done) when `mayTrash` is false or the folder is not there.

- [ ] **Step 1: Write the failing tests**

```swift
private let work = Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work")
func testTheNamesOfWhatADeleteRemoves() {
    XCTAssertEqual(ProfileRemoval.names(of: work, home: home),
                   .init(id: "1a2b3c4d", service: "com.dwebber.mossad.profile.1a2b3c4d", suite: "com.dwebber.mossad.profile.1a2b3c4d",
                         zone: "Mossad-1a2b3c4d", root: URL(fileURLWithPath: "/Users/someone/Mossad Work")))
}
func testTheStepsRunInThisOrder() async {
    // Actions that write their step's name and argument to a list:
    // ["sharedItems 1a2b3c4d", "keys com.dwebber.mossad.profile.1a2b3c4d", "settings com.dwebber.mossad.profile.1a2b3c4d",
    //  "trash /Users/someone/Mossad Work", "zone Mossad-1a2b3c4d"]; the outcome is complete.
}
func testAFailedStepStopsTheRunAndTheRestWaits() async {
    // trash throws: done is [.sharedItems, .keys, .settings], failed is .folder, the zone action was not called, complete is false.
    // zone throws: done is [.sharedItems, .keys, .settings, .folder], failed is .zone, complete is false.
    // A second run with a zone that works: complete.
}
func testADeleteNeverTrashesTheFirstProfilesFolderOrAnothers() {
    let h = home
    XCTAssertTrue(ProfileRemoval.mayTrash(h.appendingPathComponent("Mossad Work"), home: h, others: [h.appendingPathComponent("Mossad")]))
    for bad in ["Mossad", "Mossad Rehearsal", "Documents", "Mossad Work/Audio", "../other/Mossad Work"] {
        XCTAssertFalse(ProfileRemoval.mayTrash(h.appendingPathComponent(bad), home: h, others: []), bad)
    }
    XCTAssertFalse(ProfileRemoval.mayTrash(URL(fileURLWithPath: "/tmp/Mossad Work"), home: h, others: []))
    XCTAssertFalse(ProfileRemoval.mayTrash(h.appendingPathComponent("Mossad Work"), home: h, others: [h.appendingPathComponent("Mossad Work")]))
    // With mayTrash false, run(...) does not call trash, and .folder is in `done`.
}
```

- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter ProfileRemovalTests`. Expected: the build fails with "cannot find 'ProfileRemoval' in scope".
- [ ] **Step 3: Write `ProfileRemoval.swift`.** Run the filter, then `swift test`. Expected: PASS, then 0 failures.
- [ ] **Step 4: Wire the app**
  - `deleteProfile(_:typed:)`: does nothing in an inert copy. `ProfileRules.deleteProblem` sets `profileProblem`. `InstanceLock.acquire(root:)` on the profile's folder: `.taken` sets `profileProblem = "Mossad has this profile open. Quit that copy first."`; `.held` is kept until the run ends. Then `markRemoving`, save, and `finishRemovals()`.
  - `finishRemovals()`: never in an inert copy and never while a call records. For each profile in `profiles.registry.removing`, off the main thread: `ProfileRemoval.run` with the real actions (`SharedAIKey.delete(profile:)` and `ServerPairing.unshare(profile:)` only when `Self.hasICloud`; `Keychain(service:).delete` for each of `APIKey.allCases`; `MacDefaults.store.removePersistentDomain(forName:)`; `FileManager.default.trashItem`; `CloudKitStore.deleteZone(named:)`, a success when `!Self.hasICloud`). When the outcome is complete: `remove`, save. Else: `Log.error("Removing the profile stopped at <step>; Mossad tries again at the next launch")`; the log never has a key.
  - `finishLaunch` calls `finishRemovals()` in a copy that is not inert.
- [ ] **Step 5: Run the build check and the grep of Task 4, Step 5.** Expected: exit status 0; the only lines are in `App/AppController+Profiles.swift`.
- [ ] **Step 6: Commit.** `git commit -m "A deleted profile loses its iCloud Keychain items, keys, settings, and zone, and its folder goes to the Trash; a stopped delete goes on at the next launch"`

---

### Task 9: The switcher, the menu bar, and Settings > General > Profiles

**Files:**
- Create: `App/ProfileSwitcher.swift`, `App/ProfileSettings.swift`
- Modify: `App/MainWindow.swift:155`; `App/MossadApp.swift:112-119`; `App/MenuContent.swift:16`; `App/SettingsGeneral.swift:39`; `App/DevHooks.swift`; `App/AppController.swift` (one stored value)

**Interfaces:**
- Consumes: `controller.profileMenu`, `profiles`, `activeProfile`, `profileProblem`, `switchProfile(to:)`, `addProfile`, `renameProfile`, `deleteProfile` (Tasks 7 and 8); `ProfileMenu`, `ProfileRules.nameProblem`, `nextColor`, `deleteProblem`, `ProfileRemoval.serverNote`, `bucketNote` (Tasks 2 and 8).
- Produces: `ProfileSwitcher` (a view), `ProfileColor.color: Color` and `ProfileColor.nsColor: NSColor`, `MenuBarIcon.marked(on: Bool, color: NSColor) -> NSImage`, `ProfileSettingsGroup` (a view), `AddProfileSheet`, `RenameProfileSheet`, `DeleteProfileSheet`, and on the controller `enum ProfileSheet: Equatable, Identifiable { case add, rename(String), delete(String) }` with `@Published var profileSheet: ProfileSheet?` (the sheet that `ProfileSettingsGroup` shows; the switcher's "Add profile…" and the preview hook set it).

The rules these views show are tested in Task 2 (`testTheSwitcherShowsOnlyWithTwoProfiles`, `testANameMustBeThereAndNotTaken`, `testTheDeleteRule`). This task has no new logic.

- [ ] **Step 1: The colors.** In `ProfileSwitcher.swift`: `orange` 55, `blue` 235, `green` 145, `purple` 295, `pink` 355 as `Color(light: OKLCH(lightness: 0.58, chroma: 0.15, hue: h), dark: OKLCH(lightness: 0.74, chroma: 0.15, hue: h))`, the values of `Palette.speakers`; `graphite` is `Palette.inPerson`.
- [ ] **Step 2: The switcher.** `ProfileSwitcher(menu:)`: a `Menu` whose label is a row of the sidebar's size (`Chrome.navRowHeight`, `Chrome.navRowPadding`, `Rhythm.bodySize`): an 8 pt dot in the color, the name, a small chevron. Its items: `menu.note` as a disabled first item when there is one; each row (a check on the active one; disabled while `menu.note` is there); a divider; "Add profile…" (opens Settings > General with the add sheet); "Manage profiles…" (sets `settingsPage` to `general` and opens Settings, as `MenuContent.swift:93` does). `MainWindow.swift:155`: `if let menu = controller.profileMenu { ProfileSwitcher(menu: menu) }` under `SidebarStatus()`, with `Space.s` between. VoiceOver reads "Profile, <name>".
- [ ] **Step 3: The menu bar.** `MenuBarIcon.marked(on:color:)`: the bars in `NSColor.labelColor` (35% when off) and a 5 pt dot of the color at the bottom trailing corner, drawn when the menu bar draws it, `isTemplate = false`, as `recording(_:)` is. `MossadApp.swift:118`: with a `profileMenu`, the marked image; else today's line. `MenuContent.swift:16`: with a `profileMenu`, a first row before `statusSection`: the dot and the name, `Rhythm.secondarySize`, `Palette.secondary`.
- [ ] **Step 4: Settings.** `ProfileSettingsGroup` after the "You" group (`SettingsGeneral.swift:39`), built from `SettingsGroup`, `SettingsRow`, and `.buttonStyle(.settings)`:
  - One live profile: one row, title "Profiles", detail "Keep work and personal meetings apart.", button "Add profile…".
  - Two or more: one row for each (the dot, the name, the folder through `DevHooks.shownPath`, "Active" on the active one) with "Rename…" and "Delete…" ("Delete…" is disabled for `default` and for the active one), then a row with "Add profile…".
  - The group's footer shows `profileProblem`, or, with an unreadable registry, "The list of profiles could not be read. Mossad runs as the first profile.", or, with a profile in `removing`, "A deleted profile is still being removed. Mossad tries again at the next launch."
  - `AddProfileSheet` (with `SheetHeader`): a name field, the six colors (the first free one chosen), the explanation "A profile has its own keys, settings, people, voices, coach, sync, and MCP. Nothing is copied from another profile. Mossad restarts and takes you through setup for the new profile.", Cancel and "Add and restart". The button is disabled while `nameProblem` answers; the problem shows under the field.
  - `RenameProfileSheet`: the name and the color, with the line "The folder keeps its name."
  - `DeleteProfileSheet`: "This removes the profile's keys and settings from this Mac and its meetings from iCloud, and moves <folder> to the Trash.", `ProfileRemoval.serverNote` when the profile has a `server`, `ProfileRemoval.bucketNote`, a field "Type the profile's name", and a destructive "Delete" that is disabled while `deleteProblem` answers.
- [ ] **Step 5: The preview hooks.** `App/DevHooks.swift`: `MOSSAD_PROFILES=<file>` needs no code here (Task 1 loads it into `AppIdentity.current.registry`, which `controller.profiles` starts from). `MOSSAD_PROFILE_SHEET=add|rename|delete` in a preview opens that sheet of `ProfileSettingsGroup` (rename and delete for the first profile that is not `default`). Document both in the comment at the top of the hooks.
- [ ] **Step 6: Run the build check, then look at it in a preview under the rules of your brief.**

A made-up registry for the preview (never the real one):

```sh
printf '{"version":1,"active":"1a2b3c4d","profiles":[{"id":"default","name":"Personal","color":"orange","root":"~/Mossad"},{"id":"1a2b3c4d","name":"Work","color":"blue","root":"~/Mossad Work"}]}' > "$MADE_UP/profiles.json"
MOSSAD_ROOT="$MADE_UP/data" MOSSAD_PROFILES="$MADE_UP/profiles.json" MOSSAD_UPCOMING="$MADE_UP/upcoming.json" "$APP" --ui-preview --open-window Settings
```

Expected: the sidebar's bottom shows a blue dot and "Work"; Settings > General shows the Profiles group with two rows; with `MOSSAD_PROFILE_SHEET=delete` the delete sheet shows; in light and dark. The same run without `MOSSAD_PROFILES`: no switcher, and one "Profiles" row with "Add profile…".

- [ ] **Step 7: Commit.** `git commit -m "The sidebar shows the active profile and changes it, the menu bar carries its color, and Settings > General lists the profiles"`

---

### Task 10: The words

**Files:**
- Modify: `AGENTS.md`, `README.md:62, 185`, `website/content/site.json`

- [ ] **Step 1: `AGENTS.md`.** A new row for `.../Profiles/`, `Support/MacDefaults.swift`, `Support/RunMode.swift`, `App/AppController+Profiles.swift`, `App/ProfileSwitcher.swift`, `App/ProfileSettings.swift`: the registry and its states; which profile a process is; the swap and that a profile's suite is never emptied; the list of Mac-wide keys and the hand-over to Sparkle; one foreground app; Switch, Add, and the order of a delete; not recording across profiles; the preview hooks `MOSSAD_PROFILES` and `MOSSAD_PROFILE_SHEET`, and `MOSSAD_PROOF_DAYS`. Change the rows it touches: `.../Onboarding/` (`AppIdentity` gives the data root, Keychain service, and suite of each profile), `.../Cloud/` (the prefix `profiles/<id>/`), `.../Sync/` (the zone `Mossad-<id>` and the two accounts), `.../Chat/` (`Mossad --mcp --profile <id>` and the server name), `.../Telemetry/` (Mac-wide keys), `.../Output/MarkdownWriter.swift` (the audio line). In "Build and test": a preview and a `MOSSAD_ROOT` run have no profiles. In "Conventions", Secrets: the service of a profile. In "Reading meeting notes": another profile's notes are in its own folder, such as `~/Mossad Work/Meetings`.
- [ ] **Step 2: `README.md`.** Line 62: after `Mossad --mcp`, add "for another profile, `Mossad --mcp --profile <id>`, as Settings > AI shows". After line 185: "Another profile keeps the same layout in its own folder, such as `~/Mossad Work`."
- [ ] **Step 3: `website/content/site.json`.** A new feature in the group `storage` (the id `profiles` is taken by the page of a person):

```json
{
  "id": "separate-profiles",
  "title": "Work and personal, kept apart",
  "body": "Keep work calls and personal calls in separate profiles on one Mac, and change from one to the other with one click.",
  "details": [
    "Each profile has its own keys, people, voices, coach, sync, and backup",
    "A call is recorded by the profile you are in, and the menu bar shows which one",
    "An AI app that you connect to one profile never reads the other",
    "With one profile, nothing changes"
  ],
  "icon": "person.2.crop.square.stack",
  "comingSoon": false,
  "sources": ["Packages/MossadCore/Sources/MossadCore/Profiles/ProfileRegistry.swift", "Packages/MossadCore/Sources/MossadCore/Support/AppIdentity.swift", "App/ProfileSwitcher.swift", "App/ProfileSettings.swift"]
}
```

In `mcp-local`, add the detail "Each profile has its own connection". Say nothing about the iPhone, a background run, or a move of a meeting: those are Parts 2 to 4.
- [ ] **Step 4: Check.** Run: `python3 -m json.tool website/content/site.json > /dev/null && cd Packages/MossadCore && swift test`. Expected: exit status 0 and 0 failures.
- [ ] **Step 5: Commit.** `git commit -m "AGENTS, the README, and the website say what profiles are"`

---

## Owner steps

After the release, with the real app:

1. Before you add a profile: check that Settings > AI shows the same MCP command as before, and that your iPhone still gets a new meeting.
2. Add a profile "Personal". Setup opens. Check that the Permissions step is done and that "Open Mossad at login" and the update switches in Settings > General are as you left them in the first profile.
3. Turn Mossad off "until tomorrow", switch, and check that it is still off. Turn it on again.
4. Record a short call in each profile. Check that each meeting is only in its own profile's list, folder (`~/Mossad`, `~/Mossad Personal`), and MCP (`Mossad --mcp` against `Mossad --mcp --profile <id>`).
5. On the iPhone: the first profile's AI key and server still work after the second profile's first launch.
6. Know the limits of Part 1: a meeting that was in work when you switched is finished the next time that profile is active; the iPhone shows only the first profile; a meeting that you chose not to record in one profile is not recorded in the other only when the other profile's calendars also have that invite.

## Self-review

- **Spec coverage.** The registry, its states, and the atomic write: Tasks 1 and 2. Which profile a process is, and the unknown id: Task 1. Mac-wide (permissions, login item, updates, usage statistics): Tasks 1 and 3; the models folder and the registry are outside every profile already. Not recording Mac-wide: Task 3. The risk to prove first: Task 1, Step 9. Add, Rename, setup for a new profile: Tasks 7 and 9. Delete: Task 8. The switcher, the menu bar, the refusal, the wait for the lock: Tasks 2, 7, and 9. The note's audio line: Task 5. MCP for each profile, `--persona-fill`, one server for each profile: Tasks 6 and 7. Sync and backup apart: Task 4. The spec's tests for Part 1 (the registry, `AppIdentity` with a profile, the zone, the accounts, the prefix, the MCP server name, `isNote`): Tasks 1, 2, 4, 5, 6. Words and the website: Task 10. Not covered, by the brief: the worker's mode (Part 2), the phone (Part 3), the move (Part 4), "Show code for iPhone" (Part 3), and the status line of another profile in the switcher (Part 2).
- **Types.** `ProfileRegistry.Loaded` is what `AppIdentity.registry` and `AppController.profiles` hold; `ProfileRegistry` is what the rules take. `Profile.rootURL(home:)` is the one way from a `root` to a folder. `ProfileSwitch.decide` and `ProfileMenu.init` take `recording`, which the app gives as `isRecording`.
- **Not verified by the plan's author:** no build and no test was run. The line numbers were read on `main` at `8a8db15`; the phone call import lands first and can move them.
