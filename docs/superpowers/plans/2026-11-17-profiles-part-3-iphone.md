# Profiles Part 3 (the iPhone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iPhone knows the Mac's profiles, keeps each one apart (folder, settings, secret, sync store, outbox), shows one at a time with a switch in Settings, and sends a room recording or a shared phone call to the profile the owner picks.

**Architecture:** The phone stays one process and `AppIdentity.current` stays `default`. A profile is a value, `PhoneProfileContext`, made from its id alone, and it names the folder, the Keychain service, the settings suite, the zone, and the two iCloud Keychain accounts. One `ProfileUploader` for each known profile lives for the app's life and owns that profile's outbox, sync store, and uploads. `PhoneStore` is built for the profile that shows and takes that profile's uploader; a switch closes the old store and builds a new one. The Mac's foreground app writes a third iCloud Keychain item, `profiles`, from its registry.

**Tech Stack:** Swift 6, SwiftUI, CloudKit, Security (Keychain), VisionKit (the code scanner that exists), App Intents, XCTest. No new package.

**Spec:** `docs/superpowers/specs/2026-11-16-profiles-design.md`. Read it whole before any task. This plan covers only "Part 3: the iPhone". The import screen comes from `docs/superpowers/specs/2026-11-16-phone-call-import-design.md`. Where this plan and the spec disagree, the spec wins, except for the points in "What the code contradicts".

**Branch:** `feature/profiles-iphone`, made from `main` after Part 2 (`feature/profiles-worker`) is merged.

**Code read for this plan:** commit 49e5fd0 (Part 1 complete, and the phone call import). Every `file:line` below is of that commit. Find each place again by its text before you edit. If Part 2 is in: `RunMode` has `worker` and a `Duty` table; put `updateSharedProfiles()` (Task 2) under the same duty as `updateSharedAIKey()`.

## Global Constraints

- Test first. Write the failing test, run it, then write the code.
- Pure logic goes in `Packages/MossadCore/`. The app targets hold views and wiring only.
- `cd Packages/MossadCore && swift test` (the whole suite) must pass before every commit. Expected last line: "Executed N tests, with 0 failures".
- No build, test, or run while a call records. Before each `swift test`, `xcodebuild`, or simulator run, run the call gate script that your brief names. If it says a call records, wait.
- Never block the main actor: Keychain reads, file reads, hashes, and folder removals run off it.
- Unknown is not false. A `profiles` item that the Keychain cannot give is "not known", never "one profile". An outbox or a folder that cannot be read is "not known", never "empty".
- Do not lose audio. A recording in an outbox is never deleted before the Mac has it. Only the owner's own "Delete" removes one.
- No AI attribution, no em dashes, and no real names of people in commits, code, or tests. Use made-up names such as "Sam Carter". Profile names such as "Work" are fine.
- Secrets live only in the Keychain. Never log them, never keep them in a setting, and never put them in a URL that is logged.
- `Mossad.xcodeproj` is generated from `project.yml`. Never edit or commit it.
- No `killall`, no `pkill`. Never open Simulator.app.
- Settings pages hold only settings. An explanation goes in a sheet.
- The website follows the app: `website/content/site.json` in the same branch, benefits and not mechanism.
- `AGENTS.md` rows are updated in the same branch.
- Add new test files or new test methods. Do not edit an existing test.
- Never deploy `server/` from an agent session. This plan changes nothing in `server/`.
- Build checks (not verified by the plan's author, who could not build). Mac: `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme Mossad -configuration Debug -derivedDataPath build/dev build -quiet`. iPhone: `xcodegen generate --quiet && xcodebuild -project Mossad.xcodeproj -skipPackagePluginValidation -scheme MossadPhone -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone CODE_SIGNING_ALLOWED=NO build -quiet`. Expected for both: exit status 0 and no line with `error:`.
- Exact values: the Keychain account `profiles` in the service `com.dwebber.mossad.shared` and the group `35VNBDXR6B.com.dwebber.mossad.shared`; the code scheme `mossad-profile:`; the old scheme `mossad-server:`; the folder `Documents/Mossad Profiles/<id>`; the Keychain service and the settings suite `com.dwebber.mossad.profile.<id>`; the zone `Mossad-<id>`; the accounts `ai.<id>` and `server.<id>`; the sentence "A room recording is running. Switch when it ends."
- Commit messages are one sentence in the repo's style.

**The hard invariant for the phone.** With no `profiles` item (a Mac with one profile, or a Mac from before this change) and no scanned profile code, these are byte for byte what they are today: the folder (`Documents/Mossad`, or `MOSSAD_ROOT`), the Keychain service (`com.dwebber.mossad`), the settings keys in the standard domain (`syncWith`, `serverAddress`, `recentSearches`, `findingsSeen`, and no new key), the zone (`Mossad`), the outbox path (`Documents/Mossad/Recordings/outbox.json`), the import memory (`Recordings/imported.json`), the AI key account (`ai`), and the server account (`server`). No new control shows. A phone from before this change keeps working against a Mac with profiles: it reads only `ai`, `server`, and the zone `Mossad`, so it sees the first profile. Tests: `testTheDefaultContextIsTodaysPhoneByteForByte` (Task 1), `testTheProfilesItemNeverNamesTheOtherAccounts`, `testAMacWithOneProfileNeverWritesTheItem` (Task 2), `testWithNoItemThePhoneListsOnlyTheFirstProfileAndSavesNothing` (Task 4), and run A of the simulator check (Task 10).

## Decisions already made (do not reopen)

- The Mac's foreground app writes the iCloud Keychain item `profiles`: each profile's id, name, color, and how it syncs. Never an address, a secret, or a folder path. It is written when the registry or a profile's sync choice changes, only by a real foreground app that is not inert, through `SharedItemsGate`. With one profile it is not written.
- Where iCloud Keychain is off, the phone adds a profile from a profile code. The Mac shows it in Settings > General > Profiles ("Show code for iPhone…"). An old `mossad-server:` code still pairs `default`.
- `default` on the phone keeps its folder, its settings keys, and its Keychain service. Another profile has its own of each, and its own outbox and import memory.
- `PhoneStore` takes its profile as a value. The app builds a new store on a switch, and nothing of the old store still runs.
- Settings starts with a Profile row, and the Meetings title carries the profile's color, only with two or more profiles.
- The room recorder records into the active profile. A switch is refused while it records.
- The import screen gains a Profile row (the last one chosen; the first time, the active one), with two or more profiles. A recording for any profile is sent at once, whichever profile shows. The Shortcuts action gains an optional Profile parameter (by name).
- The phone never moves a meeting and never shows two profiles in one list.
- A profile deleted on the Mac leaves the phone's list at the next read of the item. Its folder on the phone is removed only after its outbox is empty.
- The phone's active profile is the phone's own choice.

## Review Focus

1. **A recording goes to the wrong profile.** The owner picks "Work" on the import screen while "Mossad" shows, changes the pick after a person was chosen, or runs the Shortcuts action with a profile name. Expected: the audio, the outbox entry, the import memory, and the upload are all in the picked profile, and a person id of one profile never travels in another. Tests: `testEachProfileSendsOnItsOwnStore` (Task 5), `testAnImportForAProfileThatIsNotShownLandsInItsFolderOutboxAndStore`, `testAPersonIDOfAnotherProfileNeverTravels` (Task 6), `testTheImportProfileIsTheLastChosenElseTheActiveOne` (Task 4).
2. **A recording waits while its profile is renamed or deleted on the Mac, or while the Keychain cannot answer.** Expected: a rename changes a label and nothing else; a deleted profile keeps its folder and its audio until the owner shares or deletes each recording, and sends nothing; an item that cannot be read changes nothing. Tests: `testARenameKeepsTheIdAndEverythingNamedAfterIt`, `testAGoneProfileKeepsItsFolderWhileARecordingWaits`, `testAnItemThatCannotBeReadChangesNothing` (Task 4), `testAGoneProfileSendsNothingAndKeepsItsAudio` (Task 5).
3. **The first profile's secret, server, or AI key is replaced by another profile's.** A profile code is scanned while another profile shows; a Mac in "Work" shows its server code; a read of a shared item uses the default account. Expected: each profile names only its own service, suite, zone, and accounts; an old `mossad-server:` code is for `default` only, and a Mac in another profile never shows one. Tests: `testAnotherProfileHasItsOwnOfEverything`, `testTwoProfilesShareNoName` (Task 1), `testThePairingCodeOfTheFirstProfileIsTodaysAndAnothersIsAProfileCode`, `testWhatACodePutsInSettingsNeverHoldsTheSecret` (Task 3), `testConnectingAServerInOneProfileLeavesTheOthers` (Task 5), and the grep of Task 7, Step 6.
4. **An old phone, an old Mac, or a newer one in the mix.** Expected: the hard invariant; a newer item is read as far as known; the Mac never writes over a newer item; a newer code is refused in its own words. Tests: the invariant's tests, `testANewerItemIsReadAsFarAsKnown`, `testTheMacsRuleForTheItem` (Task 2), `testANewerCodeIsRefusedWithItsOwnWords` (Task 3).
5. **A switch at a bad moment, or a switch that leaves the old store at work.** The recorder runs; an import runs; the old store's sync ends after the switch; two passes send one recording. Expected: a refusal with its sentence; a closed store starts no read, sync, or timer and only finishes an edit already made; one uploader for a profile for the app's life; one upload for one entry. Tests: `testTheSwitchTable`, `testAClosedStoreStartsNoWorkButFinishesAnEdit` (Task 4), `testOneProfileHasOneUploaderForTheAppsLife`, `testTwoSendsAtOnceUploadARecordingOnce`, `testAShownProfilesUploaderLeavesThePullToItsStore` (Task 5).

## Choices made where the spec left one

- **Settings: a suite, not prefixed keys.** Another profile's settings are the suite `com.dwebber.mossad.profile.<id>` in the phone app's own container. Why: every profile then uses the same key names, so the store's code has no branch; removal is one `removePersistentDomain`; and the name is the Mac's. `UserDefaults.standard` is never swapped on the phone. `default` uses the standard domain. A suite that cannot be made means the profile cannot open; it never falls back to the standard domain.
- **Which settings are a profile's own:** `syncWith`, `serverAddress`, `recentSearches`, and `findingsSeen`. `findingsSeen` cannot stay shared: the deck replaces the whole list with the cards of the profile that shows (`PhoneApp/FindingsScreen.swift:51`), so a shared list would forget the other profile's cards. **Shared (the standard domain):** `analyticsPreset`, `analyticsStart`, `analyticsEnd`, `analyticsTrendSplit`, `peopleSort`. They say how the owner likes to look, and hold nothing of a profile. Also shared: `phoneProfiles` (the phone's list, the active profile, the last import choice).
- **How the Mac knows each profile's sync.** The foreground app is one profile and reads no setting of another (Part 2's rule). So the registry gains `sync` on each profile (`icloud`, `server`, or `off`), which each profile's own foreground app writes for itself, as `noteServer` does for the server hash. The item is then made from the registry alone. A profile that was not the foreground app since this change has no `sync`: not known.
- **A profile whose sync is not known** (not `default`): the phone lists it, sends nothing, and says "Open this profile in Mossad on your Mac once. Then this iPhone knows how it syncs." The owner can still choose in the phone's Settings. A recording added for it waits in its outbox. `default` never follows the item: its rule is today's (the saved choice, else iCloud).
- **A profile's sync on the phone:** the choice the owner made on the phone for that profile, else what the Mac says. A profile from a code saves the code's choice.
- **A profile the phone cannot reach.** Server with no connection: today's "not connected" error, and the line "Scan this profile's code on your Mac to connect its server." iCloud, from a code, on a phone with another iCloud account: the phone cannot tell, so the row says "This profile syncs through iCloud. It reaches your Mac only when this iPhone uses the same iCloud account." A phone on another iCloud account never sees the item at all.
- **The item on a Mac:** written only when a registry file exists and reads cleanly. `.none` (no file) leaves the Keychain alone: no read, no write, no delete, so a second Mac with one profile on the same iCloud account does not delete the first Mac's item. One live profile with a file deletes the item. An unreadable, partial, or newer registry leaves it. Two Macs with profiles on one iCloud account: the last writer wins, as for `ai` and `server` today.
- **A delete on the Mac needs no new step.** A profile marked `removing` is not `live`, so the next write of the item leaves it out.
- **The profile code** is for the Mac's active profile only (the foreground app has no other profile's secret). It needs a sync of iCloud or a server; a profile that does not sync has no code. A code with a secret hides after 60 seconds, as the pairing card does.
- **The Mac's old pairing card** ("Show code" in Storage & Sync) keeps the `mossad-server:` code for `default`, so an old phone still pairs. In another profile it shows that profile's `mossad-profile:` code. An old phone ignores it.
- **Where the phone scans.** One scanner takes both schemes. With one profile known, the way in is the scanner that exists (Settings, Your server, Scan code), so nothing new shows. With two or more, the Profile screen also has "Add a profile".
- **An old `mossad-server:` code on the phone** pairs `default`, whichever profile shows, and the screen says which profile it connected.
- **A profile from a code** stays until the owner removes it ("Remove from this iPhone") or until the item has listed it once and then drops it. After the item listed it, it follows the item.
- **A deleted profile with a recording.** It sends nothing: the Mac deleted its zone, and an upload would make the zone again. The Meetings list of the profile that shows gets one quiet row, "1 recording of “Work” was not sent", and Settings > Profile gets the group "No longer on your Mac". Each recording there has "Share audio" (the system share sheet, so the owner can save it or share it to Mossad for another profile) and "Delete". The folder goes when nothing is left. The Profile row shows while such a profile exists, also with one profile.
- **The active profile disappears.** The phone goes to `default`. If the recorder runs, the switch waits for the stop; the recording stays in the old profile's folder and is listed as above.
- **One uploader for each profile, for the app's life.** `ProfileUploader` owns the profile's outbox, the sync choice and store, the one write queue, and the upload. It is in MossadCore (`@MainActor`, `@Observable`) so its tests run with the tests' `MemoryStore`. The store of the profile that shows uses the same object, so a switch never makes a second sender.
- **How an uploader that is not shown learns that the Mac has a recording.** It pulls its own profile's store into its own folder (`CloudSync.pull`, only while a sent recording waits), then reads only `Audio/<id>/call.json` and `Audio/<id>-iphone/call.json` of that folder for the ids in its outbox, and settles by `Outbox.arrived`, the proof of today. No list, no index, no store. With an empty outbox it does nothing.
- **The person on the import screen for a profile that is not shown:** that profile's saved people when it has them (the owner's server), else a name as typed. The named speakers of its meetings are not read. Changing the profile clears the person.
- **After an import for a profile that is not shown** the screen closes as today. The Profile screen's row for that profile says "1 recording waits to send".
- **The room recorder and the import inbox are the app's, not a store's.** One `RoomRecorder` and one `incomingAudio` live in `PhoneProfiles`, so a switch cannot leave a second recorder or drop a shared file.
- **The title's mark:** a leading toolbar item on Meetings with the profile's dot and name. It opens the Profile screen.
- **The switch is also refused while an import runs:** "A recording is being added. Switch when it is done."
- **The DEBUG hooks** (read only with `MOSSAD_ROOT`): `MOSSAD_PHONE_PROFILES=<file>` (the item's JSON, in place of the Keychain read), `MOSSAD_PHONE_PROFILE=<id>` (the active profile), `MOSSAD_IMPORT_PROFILE=<id>` (the import screen's profile), `MOSSAD_SETTINGS=profiles` (opens the Profile screen). With `MOSSAD_ROOT`, another profile's folder is `<MOSSAD_ROOT> Profiles/<id>`.

## What the code contradicts

- **"The Mac's foreground app writes ... whether it syncs by iCloud or a server."** The sync choice is a setting of each profile's own suite (`App/AppController.swift:493`), and the registry holds none (`Packages/MossadCore/Sources/MossadCore/Profiles/Profile.swift:19-29`). Plan: `Profile.sync` in the registry (see "Choices").
- **"Through `SharedItemsGate`" as the whole rule.** The gate stops only a preview and a made-up registry (`Packages/MossadCore/Sources/MossadCore/Support/SharedItemsGate.swift:6-9`). "Not inert" and "has iCloud" are the app's own `writesSharedItems` (`App/AppController+Sync.swift:34`). The new write goes through both, as the two others do.
- **"An old server code still pairs `default`."** The Mac makes that code from the active profile's connection, whichever profile is active (`App/PhonePairing.swift:64`). A Mac in "Work" would give `default` the server of "Work". Plan: the card shows a profile code in another profile (Task 3). A Mac of Part 1 or Part 2 without this change still has the fault; "Owner steps" says so.
- **"`App/PhonePairing.swift:65`"** in the spec is line 64.
- **"The phone's Profile row has 'Add a profile' that scans it"** against "with one profile the phone shows nothing new". A phone with iCloud Keychain off knows one profile and has no Profile row. And the scanner takes only texts that start with `mossad-server:` (`PhoneApp/PhoneSettingsView.swift:275`). Plan: the one scanner takes both schemes (see "Choices").
- **"View choices ... may stay shared"** does not hold for `findingsSeen` (`PhoneApp/FindingsScreen.swift:51`, `PhoneApp/MeetingsListView.swift:18`). See "Choices".
- **"`PhoneStore` takes its profile ... as a value."** The store is a static (`PhoneApp/PhoneStore.swift:18`, used at `MossadPhoneApp.swift:9` and `AddRecordingIntent.swift:19`), and three things outlive a store: `AnalyticsScreen.facts` (`PhoneApp/AnalyticsScreen.swift:22`, read at `CoachMemoryView.swift:170`), `CompanyDomains.current` (set at `PhoneStore.swift:207`), and the store's `incomingAudio`. Plan: Task 7 moves the first into the store, sets the second again at each store's first read, and moves the third to the app.
- **"The import screen picks the profile."** The screen's person list and the Shortcuts action read the people and the meetings of the store that shows (`PhoneApp/PhoneStore+Import.swift:9-11`, `:119-120`, `AddRecordingIntent.swift:33`). A profile that is not shown has none in memory. Plan: Task 6.
- **The checked facts hold.** `AppIdentity.swift:54-57` (the phone has no registry), `Paths.swift:18-19`, `PhoneStore.swift:98-102`, `:179`, `:324-328`, `:340`, `:572-573`; `SharedAIKey.swift:20-22`, `ServerPairing.swift:28-30` (the accounts take `profile:`); `CloudKitStore.swift:13` (the zone as a value); `CloudSync.swift:196` (people only to the owner's server); `ServerPairing.swift:9-12`.

## File structure

| File | Responsibility |
| --- | --- |
| `Packages/MossadCore/Sources/MossadCore/Profiles/PhoneProfileContext.swift` (new) | `PhoneProfile`, and `PhoneProfileContext`: every name of a profile on the phone, from its id. |
| `.../Profiles/ProfilesItem.swift` (new) | The `profiles` item: format, the Mac's rule, the Keychain read and write. |
| `.../Profiles/ProfileCode.swift` (new) | The profile code: make, text, parse. |
| `.../Profiles/PhoneProfileBook.swift` (new) | The phone's list, the switch rule, `StoreLife`, the words. |
| `.../Room/ProfileUploader.swift`, `.../Room/ProfileUploader+Import.swift` (new) | One profile's outbox, sync store, uploads, and imports; `ProfileUploaders`. |
| `.../Profiles/Profile.swift`, `ProfileRegistry.swift`, `ProfileSettingsWords.swift` | `sync` on a profile; the code sheet's words. |
| `App/AppController+Sync.swift`, `App/AppController+Profiles.swift` | `updateSharedProfiles()`, `noteSync()`. |
| `App/ProfileCodeSheet.swift` (new), `App/ProfileSettings.swift`, `App/PhonePairing.swift`, `App/DevHooks.swift` | The Mac's code sheet, its button, the pairing card's code. |
| `SharedUI/ProfileDot.swift` (new) | `ProfileColor.color`, `title`, and `ProfileDot`, moved from `App/ProfileSwitcher.swift:6-35` for both apps. |
| `PhoneApp/PhoneProfiles.swift` (new) | The app's one object: the list, the uploaders, the recorder, the store that shows, the switch. |
| `PhoneApp/ProfilesScreen.swift` (new) | Settings > Profile. |
| `PhoneApp/PhoneStore.swift`, `PhoneStore+Import.swift`, `MossadPhoneApp.swift` | The store takes its profile; the app builds it. |
| `PhoneApp/PhoneSettingsView.swift`, `MeetingsListView.swift`, `CallImportScreen.swift`, `AddRecordingIntent.swift` | The Profile row, the mark, the import's Profile row, the Shortcuts parameter. |

Made-up values for every test: `let work = "1a2b3c4d"`, `let club = "5e6f7a8b"`, the server `https://notes.example.com` with the secret `"made-up-secret"`, the documents folder `URL(fileURLWithPath: "/D")`.

---

### Task 1: A profile as a value

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/PhoneProfileContext.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/PhoneProfileContextTests.swift`

**Interfaces:**
- Consumes: `ProfileRegistry.isID`, `ProfileColor`, `SyncChoice`, `SharedAIKey.account(profile:)`, `ServerPairing.account(profile:)`, `Paths(root:)`, `AppIdentity.mainBundleID`.
- Produces:
  ```swift
  public struct PhoneProfile: Codable, Equatable, Sendable, Identifiable {
      public enum Source: String, Codable, Sendable { case item, code }
      public var id: String
      public var name: String
      public var color: ProfileColor
      public var syncName: String?           // coded as "sync"; "icloud", "server", "off"
      public var source: Source
      public var gone: Date?                 // since when the Mac no longer lists it
      public init(id: String, name: String, color: ProfileColor, sync: SyncChoice?, source: Source, gone: Date? = nil)
      public var sync: SyncChoice? { get }   // nil for no word or a word this build does not know
      public var isDefault: Bool { get }
      public static let `default`: PhoneProfile   // "default", "Mossad", .orange, sync nil, .item
  }

  public struct PhoneProfileContext: Equatable, Hashable, Sendable {
      public let id: String
      public init?(id: String)               // nil unless "default" or 8 characters of 0-9a-f
      public static let `default`: PhoneProfileContext
      public var isDefault: Bool { get }
      public func root(documents: URL, environment: [String: String]) -> URL
      public func paths(documents: URL, environment: [String: String]) -> Paths
      public var keychainService: String { get }
      public var settingsSuite: String? { get }
      public func settings(standard: UserDefaults, makeSuite: (String) -> UserDefaults?) -> UserDefaults?
      public var cloudZone: String { get }
      public var aiAccount: String { get }
      public var serverAccount: String { get }
      public func sync(saved: String?, listed: SyncChoice?) -> SyncChoice?
      public func mayRemove(_ folder: URL, documents: URL, environment: [String: String]) -> Bool
      public static let ownKeys = ["syncWith", "serverAddress", "recentSearches", "findingsSeen"]
      public static let sharedKeys = ["analyticsPreset", "analyticsStart", "analyticsEnd", "analyticsTrendSplit", "peopleSort", "phoneProfiles"]
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `testTheDefaultContextIsTodaysPhoneByteForByte`: for `PhoneProfileContext.default`: `root(documents: /D, environment: [:]).path == "/D/Mossad"`; with `["MOSSAD_ROOT": "/tmp/x"]` it is `"/tmp/x"`; `keychainService == "com.dwebber.mossad"` and equals `AppIdentity(bundleID: "com.dwebber.mossad.phone").keychainService`; `settingsSuite == nil`; `settings(standard: s, makeSuite: { _ in XCTFail(); return nil }) === s`; `cloudZone == "Mossad"` and equals that identity's `cloudZone`; `aiAccount == "ai"`; `serverAccount == "server"`; `paths(...).root.appendingPathComponent("Recordings").appendingPathComponent(Outbox.fileName).path == "/D/Mossad/Recordings/outbox.json"`; the same with `ImportMemory.fileName` ends in `"/D/Mossad/Recordings/imported.json"`.
  - `testAnotherProfileHasItsOwnOfEverything`: for `1a2b3c4d`: root `"/D/Mossad Profiles/1a2b3c4d"`; with `MOSSAD_ROOT=/tmp/x` root `"/tmp/x Profiles/1a2b3c4d"`; service and suite `"com.dwebber.mossad.profile.1a2b3c4d"`; zone `"Mossad-1a2b3c4d"`; accounts `"ai.1a2b3c4d"` and `"server.1a2b3c4d"`.
  - `testTwoProfilesShareNoName`: for `default`, `1a2b3c4d`, `5e6f7a8b`: the roots, services, zones, AI accounts, and server accounts are each three different values, and no root's path starts with another root's path and `"/"`.
  - `testAnIDThatIsNotEightHexIsNoContext`: `PhoneProfileContext(id:)` is nil for `""`, `"DEFAULT"`, `"1A2B3C4D"`, `"../x"`, `"1a2b3c4"`, `"1a2b3c4d5"`.
  - `testAProfileWhoseSettingsCannotBeMadeNeverGetsTheFirstProfilesSettings`: for `1a2b3c4d`, `settings(standard: s, makeSuite: { _ in nil }) == nil`; with a maker that returns `t`, the result is `t` and the maker got `"com.dwebber.mossad.profile.1a2b3c4d"`.
  - `testTheSyncOfAProfile`, a table of (context, saved, listed, expected): (default, nil, nil, `.icloud`); (default, nil, `.server`, `.icloud`); (default, `"server"`, `.icloud`, `.server`); (default, `"junk"`, nil, `.icloud`); (work, nil, nil, nil); (work, nil, `.server`, `.server`); (work, `"icloud"`, `.server`, `.icloud`); (work, `"junk"`, `.off`, `.off`).
  - `testOnlyAProfilesOwnFolderMayBeRemoved`: `mayRemove` is true for work's own root; false for `/D/Mossad`, for `/D/Mossad Profiles`, for club's root asked of work, and for anything asked of `default`.
  - `testAProfileReadsASyncWordItDoesNotKnowAsNotKnown`: a `PhoneProfile` decoded from `{"id":"1a2b3c4d","name":"Work","color":"blue","sync":"carrier-pigeon","source":"item"}` has `sync == nil`; with `"sync":"server"` it is `.server`.
- [ ] **Step 2: Run to verify they fail.** Run: `cd Packages/MossadCore && swift test --filter PhoneProfileContextTests`. Expected: the build fails with "cannot find 'PhoneProfileContext' in scope".
- [ ] **Step 3: Implement the two types.** `root`: `default` is `MOSSAD_ROOT` when set and not empty, else `documents/Mossad`; another profile is the sibling folder named the first root's last component plus `" Profiles"`, then the id. The accounts call `SharedAIKey.account(profile:)` and `ServerPairing.account(profile:)`. `PhoneProfile` codes `syncName` under the key `sync`.
- [ ] **Step 4: Run to verify they pass.** Run the filter, then the whole suite. Expected: "0 failures". `ProfilePhoneCallTests.testThePhoneHasNoProfilesAndKeepsTheFirstZone` still passes unchanged: `AppIdentity` on the phone stays `default`.
- [ ] **Step 5: Commit.** `git commit -m "A profile on the iPhone is a value that names its folder, service, settings, zone, and accounts"`

---

### Task 2: The `profiles` item, and the Mac writes it

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/ProfilesItem.swift`
- Modify: `.../Profiles/Profile.swift` (one optional field), `.../Profiles/ProfileRegistry.swift` (`setSync`), `App/AppController+Sync.swift`, `App/AppController+Profiles.swift`, `App/AppController.swift:693-694`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfilesItemTests.swift`

**Interfaces:**
- Consumes: `ProfileRegistry`, `ProfileRegistry.Loaded`, `SharedItemsGate.perform`, `SharedAIKey.accessGroup`, `SharedAIKey.service`, `SerialQueue`.
- Produces:
  ```swift
  // Profile.swift
  public var sync: String?                                   // "icloud", "server", "off"; written by that profile's own foreground app
  // ProfileRegistry.swift
  public mutating func setSync(_ sync: String?, for id: String)

  public struct ProfilesItem: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public static let account = "profiles"
      public static let fields = ["id", "name", "color", "sync"]      // the allowed fields of an entry
      public struct Entry: Codable, Equatable, Sendable { public var id: String; public var name: String; public var color: ProfileColor; public var sync: String? }
      public var version: Int
      public var profiles: [Entry]
      public static func make(from registry: ProfileRegistry) -> ProfilesItem     // the live profiles, `default` first
      public func encoded() throws -> Data                                        // sorted keys
      public static func decode(_ data: Data) -> ProfilesItem?                    // nil only when there is no `version`
      public enum Read: Equatable, Sendable { case found(ProfilesItem), none, unknown }
      public enum Plan: Equatable, Sendable { case write(ProfilesItem), delete, leave }
      public static func plan(_ loaded: ProfileRegistry.Loaded, existing: Read) -> Plan
      static func query() -> [String: Any]
      public static func read() -> Read            // not found: .none; any other failure or data that does not decode: .unknown
      public func save() throws                    // through SharedItemsGate
      public static func delete()                  // through SharedItemsGate
  }
  // App
  func noteSync()                // AppController+Profiles.swift
  func updateSharedProfiles()    // AppController+Sync.swift
  ```

- [ ] **Step 1: Write the failing tests.**
  - `testTheItemHoldsOnlyTheAllowedFields`: a registry with `default` (server hash set, `sync: "icloud"`) and Work (`root: "~/Mossad Work"`, `server: "abc"`, `sync: "server"`). The JSON object of each entry of `make(from:).encoded()` has exactly the keys of `ProfilesItem.fields` that are set, and the whole text contains none of `"root"`, `"Mossad Work"`, `"server\":\"abc"`, `"removing"`, `"active"`. The order is `default`, then `1a2b3c4d`.
  - `testAProfileBeingRemovedIsNotInTheItem`: after `markRemoving("1a2b3c4d")`, `make(from:).profiles.map(\.id) == ["default"]`.
  - `testTheProfilesItemNeverNamesTheOtherAccounts`: `query()` has the account `"profiles"`, the service `"com.dwebber.mossad.shared"`, the group `SharedAIKey.accessGroup`, and synchronizable true; `SharedAIKey.account(profile: "default") == "ai"`; `ServerPairing.account(profile: "default") == "server"`.
  - `testAMacWithOneProfileNeverWritesTheItem`: `plan(.none, existing: .found(anItem)) == .leave`; `plan(.none, existing: .none) == .leave`.
  - `testTheMacsRuleForTheItem`, a table (registry state, live profiles, existing, plan): (read, 2, none, write); (read, 2, found the same, leave); (read, 2, found another, write); (read, 2, found with `version` 2, leave); (read, 2, unknown, write); (read, 1, found, delete); (read, 1, none, leave); (read, 1, found with `version` 2, leave); (unreadable, any, found, leave); (partial, 2, none, leave); (newer, 2, none, leave).
  - `testANewerItemIsReadAsFarAsKnown`: `decode` of `{"version":2,"future":true,"profiles":[{"id":"default","name":"Mossad","color":"orange","sync":"icloud","extra":1},{"id":"1a2b3c4d","name":"Work","color":"teal","sync":"relay"}]}` gives version 2, two entries, the second with the color `.graphite` and the sync word `"relay"`.
  - `testADamagedItemIsNotAnItem`: `decode(Data("junk".utf8)) == nil`; `decode` of `{"profiles":[]}` is nil; an entry with the id `"../x"` or a repeated id is left out; an item with no `default` entry still decodes.
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter ProfilesItemTests`. Expected: the build fails with "cannot find 'ProfilesItem' in scope".
- [ ] **Step 3: Implement `ProfilesItem`, `Profile.sync`, and `setSync`.** The Keychain calls copy `ServerPairing`'s (`ServerPairing.swift:32-73`): the same service, group, `kSecAttrSynchronizable`, and `kSecAttrAccessibleAfterFirstUnlock` on add. `read()` returns `.none` only for `errSecItemNotFound`.
- [ ] **Step 4: Run to verify they pass.** The filter, then the whole suite. Expected: "0 failures".
- [ ] **Step 5: The Mac's wiring.** No unit test: the rule is `plan`.
  - `noteSync()`, beside `noteServer` (`AppController+Profiles.swift:197`), with the same guards (`changesProfiles`; a registry file exists; `canSave`): when the registry's `sync` of the active profile is not `syncWith.rawValue`, set it and save. It ends with `updateSharedProfiles()`.
  - `updateSharedProfiles()`, beside `updateSharedServer()`: `guard writesSharedItems, profiles.state != .none`. Then, on one `SerialQueue` of the controller and off the main actor: `ProfilesItem.plan(profiles, existing: ProfilesItem.read())`, and `save()`, `delete()`, or nothing. A failure logs "Profiles: the list for the iPhone could not be saved" and no more.
  - Calls: at launch after `updateSharedServer()` (`AppController.swift:694`): `noteSync()`. In `chooseSync`, `connectServer`, and `disconnectServer` (`AppController+Sync.swift:59-116`): `noteSync()`. After each save of the registry in `addProfile` (also set the active profile's `sync` in the same save as its server hash, `:156`), `renameProfile`, `deleteProfile`, `endRemoval`, and `noteServer`: `updateSharedProfiles()`.
- [ ] **Step 6: Run the whole suite and the Mac build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 7: Commit.** `git commit -m "The Mac tells the iPhone its profiles through one iCloud Keychain item, and only with two or more"`

---

### Task 3: The profile code, and the Mac's sheet for it

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/ProfileCode.swift`, `App/ProfileCodeSheet.swift`
- Modify: `.../Profiles/ProfileSettingsWords.swift`, `App/ProfileSettings.swift` (`ProfileSheet`, the group), `App/PhonePairing.swift:64`, `App/DevHooks.swift:85-92`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileCodeTests.swift`

**Interfaces:**
- Consumes: `Profile`, `ProfileColor`, `SyncChoice`, `ServerConnection`, `ServerConnection.address(from:)`, `ServerPairing.code(for:)`, `ServerPairing.connection(fromCode:)`, `ProfileRules.nameLimit`, `QRCode.image` (`App/PhonePairing.swift:108`).
- Produces:
  ```swift
  public struct ProfileCode: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
      public static let scheme = "mossad-profile"
      public static let currentVersion = 1
      public var version: Int
      public var id: String
      public var name: String
      public var color: ProfileColor
      public var sync: String                 // "icloud" or "server"
      public var address: URL?                // only with "server"
      public var secret: String?              // only with "server"
      public static func make(profile: Profile, sync: SyncChoice, server: ServerConnection?) -> ProfileCode?   // nil for .off, and for .server with no connection
      public var text: String                 // "mossad-profile:<base64url JSON>"
      public var connection: ServerConnection? { get }
      public var holdsSecret: Bool { get }
      public var settings: [String: String] { get }      // what goes in the profile's settings: "syncWith", and "serverAddress" with a server
      public enum Parsed: Equatable, Sendable {
          case profile(ProfileCode), server(ServerConnection), newer, damaged, notMossad
          public var problem: String? { get }
      }
      public static func parse(_ text: String) -> Parsed
      public static func isCode(_ text: String) -> Bool   // starts with either scheme and a colon
      public static func pairingText(profile: Profile, connection: ServerConnection) -> String
  }
  // ProfileSettingsWords
  public static let codeButton = "Show code for iPhone…"
  public static func codeTitle(_ name: String) -> String          // "Add “Work” to your iPhone"
  public static let codeSteps = ["Open Mossad on your iPhone.", "Tap the gear on the Meetings screen.",
                                 "Tap Profile, then Add a profile. With no Profile row, tap Your server, then Scan code."]
  public static func codeSecretNote(seconds: Int) -> String       // "The code holds this profile's server secret, so it hides again in 0:59."
  public static let codeICloudNote = "This profile syncs through iCloud. Your iPhone needs the same iCloud account as this Mac."
  public static let codeNoSync = "This profile does not sync. Choose iCloud or your server in Settings › Storage & Sync first."
  public static let codeNoServer = "Finish this profile's server in Settings › Storage & Sync first."
  // App
  enum ProfileSheet { case add, rename(String), delete(String), code }
  struct ProfileCodeSheet: View
  ```
  The problems: `.newer` "This code is from a newer Mossad. Update Mossad on this iPhone, then scan it again."; `.damaged` "That code could not be read. Show the code on your Mac again."; `.notMossad` "That code isn't from Mossad. Show the code on your Mac again." (the sentence of today, `PhoneSettingsView.swift:218`); the others nil.

- [ ] **Step 1: Write the failing tests.**
  - `testACodeRoundTrips`: `make` for Work (blue) with `.server` and the made-up connection; `parse(code.text) == .profile(code)`; `code.holdsSecret`; `code.connection == c`. For `.icloud`: `address == nil`, `secret == nil`, `!holdsSecret`, and the round trip holds. `text` starts with `"mossad-profile:"` and has no `"="`, `"+"`, or `"/"` after the colon.
  - `testNoCodeWithoutAWayToSync`: `make(profile: work, sync: .off, server: c) == nil`; `make(profile: work, sync: .server, server: nil) == nil`; `make(profile: work, sync: .icloud, server: c)` has no address and no secret.
  - `testANewerCodeIsRefusedWithItsOwnWords`: a code whose JSON has `"version":2` parses to `.newer`, and its `problem` is the sentence above.
  - `testADamagedCodeIsRefused`: each parses to `.damaged`: `"mossad-profile:"`, `"mossad-profile:!!!"`, valid base64 of `"{}"`, an id of `"../x"`, an empty name, `"sync":"server"` with no secret, `"sync":"server"` with the address `"not a host"`, `"sync":"off"`. A name of 60 characters parses and is cut to 40.
  - `testAnOldServerCodeIsForTheFirstProfile`: `parse(ServerPairing.code(for: c)) == .server(c)`; `parse("mossad-server:junk") == .damaged`; `parse("https://example.com") == .notMossad`; `isCode` is true for both schemes and false for `"mossad-profiles:x"` and `""`.
  - `testWhatACodePutsInSettingsNeverHoldsTheSecret`: for the server code, `settings == ["syncWith": "server", "serverAddress": "https://notes.example.com"]`; for the iCloud code, `["syncWith": "icloud"]`. `"\(code)"`, `String(describing: code)`, and `String(reflecting: code)` do not contain `"made-up-secret"`.
  - `testThePairingCodeOfTheFirstProfileIsTodaysAndAnothersIsAProfileCode`: `pairingText(profile: .default, connection: c) == ServerPairing.code(for: c)`; for Work the text starts with `"mossad-profile:"` and parses to a `.profile` with the id `1a2b3c4d` and the connection `c`.
  - `testTheCodeSheetsWords`: each word above, exactly; `codeSecretNote(seconds: 5)` ends in `"0:05."`.
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter ProfileCodeTests`. Expected: the build fails with "cannot find 'ProfileCode' in scope".
- [ ] **Step 3: Implement `ProfileCode` and the words.** `parse` reads `version` before anything else. With `"icloud"`, an address or a secret in the JSON is dropped. `description` and `debugDescription` are `"ProfileCode(<id>)"`.
- [ ] **Step 4: Run to verify they pass.** The filter, then the whole suite. Expected: "0 failures".
- [ ] **Step 5: The Mac's sheet.** No unit test: the sheet holds no rule.
  - `ProfileSettingsGroup` (`App/ProfileSettings.swift:19`): in the row of buttons under the profiles (shown only with two or more), a button `ProfileSettingsWords.codeButton` before "Add profile…". It opens `ProfileSheet.code`. With one profile it does not show.
  - `ProfileCodeSheet`: `SheetHeader(icon: .qrLarge, title: codeTitle(active.name), close:)`, then the code as `QRCode.image(code.text)` black on white at 200 points with the accessibility label "Profile code", then `codeSteps` numbered, then one note: `codeSecretNote` with the countdown of `PairingCard` (`App/PhonePairing.swift:83-88`; at 0 the sheet closes) when the code holds a secret, else `codeICloudNote`. With no code: only `codeNoSync` or `codeNoServer`. The code is `ProfileCode.make(profile: controller.activeProfile, sync: controller.syncWith, server: controller.serverConnection)`: the active profile's own values and no other's. Sizes and gaps from `Rhythm` and `Space`. `SheetFooter` with "Done".
  - `PairingCard` (`App/PhonePairing.swift:64`): the text is `ProfileCode.pairingText(profile: controller.activeProfile, connection: c)`.
  - `DevHooks.swift:87-92`: `"code"` opens `.code`.
- [ ] **Step 6: Run the whole suite and the Mac build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 7: Commit.** `git commit -m "A profile code adds one profile to the iPhone where iCloud Keychain is off, and the Mac shows it in a sheet"`

---

### Task 4: The phone's list of profiles, the switch rule, and the words

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Profiles/PhoneProfileBook.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/PhoneProfileBookTests.swift`

**Interfaces:**
- Consumes: `PhoneProfile`, `PhoneProfileContext` (Task 1), `ProfilesItem.Read` (Task 2), `ProfileCode` (Task 3).
- Produces:
  ```swift
  public struct PhoneProfileBook: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public static let defaultsKey = "phoneProfiles"
      public var version: Int
      public var profiles: [PhoneProfile]      // as last known; may hold `default` for its name and color
      public var active: String?               // nil is `default`
      public var importTarget: String?         // the last profile chosen for an import
      public init()
      public var listed: [PhoneProfile] { get }        // `default` first, then the item's order, then the coded ones; none that is gone
      public var leaving: [PhoneProfile] { get }       // gone, and never `default`
      public var showsProfiles: Bool { get }           // listed.count >= 2
      public var showsProfileRow: Bool { get }         // showsProfiles or a leaving profile
      public var activeProfile: PhoneProfile { get }   // the listed one for `active`, else `default`
      public var importDefault: PhoneProfile { get }   // the listed one for `importTarget`, else `activeProfile`
      public func profile(named name: String) -> PhoneProfile?    // among `listed`, trimmed, letter case ignored
      public mutating func take(_ read: ProfilesItem.Read, now: Date)
      public mutating func add(_ code: ProfileCode, now: Date)
      public mutating func removeFromPhone(_ id: String, now: Date)   // the owner's own; never `default`
      public mutating func forget(_ id: String)                       // after its folder is gone
      public var isEmpty: Bool { get }
      public static func load(_ defaults: UserDefaults) -> PhoneProfileBook
      public func save(to defaults: UserDefaults)      // removes the key when `isEmpty`; never saves a book of a newer version
      public enum Cleanup: Equatable, Sendable { case stays, holds(Int), unknown, remove }
      public static func cleanup(_ profile: PhoneProfile, outbox: Int?, audio: Int?) -> Cleanup
  }

  public enum PhoneProfileSwitch {
      public static let recordingRefusal = "A room recording is running. Switch when it ends."
      public static let importRefusal = "A recording is being added. Switch when it is done."
      public enum Decision: Equatable, Sendable { case go(String), refused(String), stay }
      public static func decide(to id: String, book: PhoneProfileBook, active: String, recording: Bool, importing: Bool) -> Decision
      public enum Step: String, CaseIterable, Sendable { case closeOld, remember, buildNew }   // the order of a `.go`
  }

  public struct StoreLife: Equatable, Sendable {
      public enum Work: CaseIterable, Sendable { case read, sync, index, findings, timer, finishEdit }
      public init()
      public private(set) var closed: Bool
      public mutating func close()
      public func allows(_ work: Work) -> Bool
  }

  public enum PhoneProfileWords {
      public static func label(_ name: String) -> String                    // "Profile, Work"
      public static func waiting(_ count: Int) -> String                    // "1 recording waits to send", "2 recordings wait to send"
      public static let leavingTitle = "No longer on your Mac"
      public static func leavingRow(name: String, count: Int) -> String     // "1 recording of “Work” was not sent", "2 recordings of “Work” were not sent"
      public static let leavingFooter = "Your Mac no longer has this profile, so Mossad does not send these recordings. Share a recording to keep it, or delete it."
      public static func note(for profile: PhoneProfile, hasServer: Bool) -> String?
      public static func noProfileNamed(_ name: String) -> String           // "Mossad has no profile named “Home” on this iPhone."
      public static func connected(name: String, host: String) -> String    // "Connected “Mossad” to notes.example.com."
      public static func added(_ name: String) -> String                    // "Added “Work”."
      public static let cannotOpen = "This profile could not be opened on this iPhone."
      public static let notInProfile = "That meeting is not in this profile on this iPhone."
  }
  ```

- [ ] **Step 1: Write the failing tests.**
  - `testWithNoItemThePhoneListsOnlyTheFirstProfileAndSavesNothing`: a new book after `take(.none, now:)`: `listed == [.default]`, `!showsProfiles`, `!showsProfileRow`, `isEmpty`; `save(to:)` on a test suite leaves no value for `"phoneProfiles"`, and removes one that was there.
  - `testTheItemFillsTheList`: `take(.found(item of default "Home" green icloud, Work blue server))`: `listed.map(\.id) == ["default", "1a2b3c4d"]`; the first has the name "Home" and the color `.green`; the second has `sync == .server` and the source `.item`; `showsProfiles`.
  - `testARenameKeepsTheIdAndEverythingNamedAfterIt`: after a second `take` with Work as "Client" purple: one entry with the id `1a2b3c4d`, the name "Client", the color `.purple`; `PhoneProfileContext(id: entry.id)` equals the context of before; `active` and `importTarget` set to `1a2b3c4d` before the take are unchanged.
  - `testAnItemThatCannotBeReadChangesNothing`: `take(.unknown, now:)` on a book with two profiles leaves the book equal to itself before.
  - `testAProfileTheMacDroppedLeaves`: a third `take` without Work, at `t1`: Work is in `leaving` with `gone == t1` and not in `listed`; a `take` at `t2` without it keeps `t1`; a `take` that lists it again clears `gone`. With `active == "1a2b3c4d"` at the drop, `active == nil` after. `take(.none)` with Work from the item: Work leaves, and the entry of `default` is removed.
  - `testTheFirstProfileNeverLeaves`: an item with no `default` entry, and `.none`: `listed.first?.id == "default"`, `leaving` never holds `default`, `removeFromPhone("default", now:)` changes nothing.
  - `testACodedProfileStaysUntilTheItemTookItOver`: `add(code for club)`: listed last, the source `.code`. `take(.found(item without club))`: club stays. `take(.found(item with club))`: the source is `.item`. `take(.found(item without club))`: club leaves. `removeFromPhone("5e6f7a8b", now:)` on a coded one sets `gone`.
  - `testTheImportProfileIsTheLastChosenElseTheActiveOne`: with `active = work`, `importTarget = nil`: `importDefault.id == work`. With `importTarget = club` and club listed: club. After club leaves: work. `profile(named: " work ")` is Work; `profile(named: "Home")` is nil when no profile has the name.
  - `testAGoneProfileKeepsItsFolderWhileARecordingWaits`, the table of `cleanup` (gone, outbox, audio, result): (nil, 0, 0, `.stays`); (set, nil, 0, `.unknown`); (set, 0, nil, `.unknown`); (set, 1, 1, `.holds(1)`); (set, 0, 2, `.holds(2)`); (set, 0, 0, `.remove`); (`default` with any values, `.stays`).
  - `testANewerBookIsReadAndNeverSaved`: a saved book with `"version":2`: `load` gives its profiles; `save(to:)` leaves the stored bytes as they were.
  - `testTheSwitchTable` (to, active, recording, importing, decision), on a book with `default`, Work, and a leaving club: (work, default, false, false, `.go("1a2b3c4d")`); (work, work, true, false, `.stay`); (work, default, true, false, `.refused(recordingRefusal)`); (work, default, false, true, `.refused(importRefusal)`); (work, default, true, true, `.refused(recordingRefusal)`); (club, default, false, false, `.stay`); (`"ffffffff"`, default, false, false, `.stay`); (default, work, false, false, `.go("default")`). `Step.allCases == [.closeOld, .remember, .buildNew]`.
  - `testAClosedStoreStartsNoWorkButFinishesAnEdit`: a new `StoreLife` allows every `Work`; after `close()`, only `.finishEdit`.
  - `testTheWordsOfTheProfileScreen`: each word above, exactly. `note(for:hasServer:)`: a profile with no sync word, not `default`: "Open this profile in Mossad on your Mac once. Then this iPhone knows how it syncs."; `.server` with `hasServer` false: "Scan this profile's code on your Mac to connect its server."; `.off`: "This profile does not sync on your Mac."; `.icloud` from a code: "This profile syncs through iCloud. It reaches your Mac only when this iPhone uses the same iCloud account."; `.icloud` from the item, `.server` with a server, and `default` with no sync word: nil.
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter PhoneProfileBookTests`. Expected: the build fails with "cannot find 'PhoneProfileBook' in scope".
- [ ] **Step 3: Implement the four types.** `take` keeps the first `gone` date. `isEmpty` is true when `profiles` is empty, `active` is nil or `default`, and `importTarget` is nil. `cleanup` holds `max(outbox, audio)`.
- [ ] **Step 4: Run to verify they pass.** The filter, then the whole suite. Expected: "0 failures".
- [ ] **Step 5: Commit.** `git commit -m "The iPhone's list of profiles follows the Mac's item and the scanned codes, and one rule decides a switch"`

---

### Task 5: `ProfileUploader`: one profile's outbox, sync store, and uploads

This moves code out of `PhoneStore` into MossadCore, where it gets its first tests. The moved code keeps its words, its log lines, and its order.

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Room/ProfileUploader.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileUploaderTests.swift`

**Interfaces:**
- Consumes: `PhoneProfileContext` (Task 1); `Outbox`, `RoomAudio`, `CloudSync`, `SyncStatus`, `FriendlyError`, `SerialQueue`, `TransientRetry`, `CallRecord.load(from:)`, `ProcessingQueue.minimumCallDuration`; in tests, `MemoryStore` (`RecordStoreTests.swift:6`).
- Produces:
  ```swift
  @MainActor @Observable
  public final class ProfileUploader {
      public struct Parts: Sendable {
          public var icloud: @Sendable (_ zone: String) -> any RecordStore
          public var server: @Sendable (ServerConnection) -> any RecordStore
          public var secret: @Sendable () -> String?                   // this profile's own server secret
          public var setSecret: @Sendable (String?) -> Void
          public var pairedServer: @Sendable () -> ServerConnection?   // the Mac's shared item of this profile
          public static func live(_ context: PhoneProfileContext) -> Parts
      }
      public let context: PhoneProfileContext
      public let paths: Paths
      public let settings: UserDefaults
      public let writes: SerialQueue
      public init(context: PhoneProfileContext, paths: Paths, settings: UserDefaults, listed: SyncChoice?, offline: Bool, parts: Parts,
                  background: @escaping @MainActor (String) -> @MainActor () -> Void = { _ in {} })

      public private(set) var outbox: Outbox
      public private(set) var uploading: Set<String>
      public private(set) var joining: Set<String>
      public var syncStatus: SyncStatus
      public var listed: SyncChoice?                    // what the Mac says; a change is taken at once
      public var sends: Bool                            // false for a profile that left
      public var shown: Bool                            // its store exists: the store pulls, not `pass`
      public var onStoreChange: (@MainActor () -> Void)?
      public private(set) var syncWith: SyncChoice?     // nil: not known
      public var server: ServerConnection? { get }
      public var place: String { get }
      public var cloud: (key: String, sync: CloudSync)? { get }
      public var recordingsFolder: URL { get }
      public func choose(_ choice: SyncChoice)
      public func connect(_ c: ServerConnection)
      public func disconnectServer()

      public func ready() async                         // the first read of the outbox, once
      func addImported(_ recording: PhoneRecording) -> Bool    // a finished recording's entry, saved; false when it could not be saved
      func dropImported(_ id: String)
      public func settle(arrived: Set<String>)
      public func sendOutbox() async
      public func pass() async
      public var waits: Bool { get }                    // an entry besides the one recording now

      public func begin(_ recording: PhoneRecording)
      public func keepTitle(_ id: String, _ title: String?)
      public func finish(_ id: String, end: Date, counted: TimeInterval, title: String?, discard: Bool)
      public func recover(active: String?) async
      public func retryUnfinished(active: String?)
      public func canRemove(_ id: String, active: String?) -> Bool
      public func remove(_ id: String, active: String?)
      public func sendAgain(_ id: String)
  }

  @MainActor
  public final class ProfileUploaders {
      public init(make: @escaping @MainActor (PhoneProfile) -> ProfileUploader?)
      public func uploader(for profile: PhoneProfile) -> ProfileUploader?    // the same object for an id, for the app's life
      public var all: [ProfileUploader] { get }
      public func drop(_ id: String)
  }
  ```
  `Parts.live`: `icloud: { CloudKitStore(zone: $0) }`, `server: { ServerStore($0) }`, the secret through `Keychain(service: context.keychainService)` and `.serverSecret`, `pairedServer: { ServerPairing.shared(profile: context.id) }`.

  What moves from `PhoneApp/PhoneStore.swift`, as it is, with `recorder.id` given as `active`: the engine (`server`, `place`, `cloud`, `choose`, `use`, `connect`, `disconnectServer`, lines 323-382; the store-only part of `use`, lines 363-368, becomes the call of `onStoreChange`), `saveOutbox` (577-587), `addImported` and `dropImported` (591-604), `settleOutbox` (608-614), `readOutbox` (618-623), `recoverRecordings` (627-665), `retryUnfinishedRecordings` (668-676), `join` (682-710), what `stopRecording` does after `recorder.stop()` (734-757), `canRemoveRecording`, `removeRecording`, `sendAgain` (761-780), `sendOutbox` (784-807). `BackgroundTime` stays in the app and comes in as `background`.

  New rules:
  - `syncWith` is `context.sync(saved: settings.string(forKey: "syncWith"), listed: listed)`.
  - `cloud` is nil when `offline`, when `sends` is false, and when `syncWith` is nil or `.off`. For `.icloud` the store is `parts.icloud(context.cloudZone)` and the key is `"icloud"`. For `.server` the connection is the profile's own (`settings`' `serverAddress` with `parts.secret()`), else `parts.pairedServer()`, and the key is `"server:<address>"`. The keys are today's, so an outbox of today reads as sent to the same store.
  - `pass()`: returns at once when `shown`, when `cloud` is nil, or when the outbox is empty. When a sent entry waits: `writes.run { TransientRetry.run { cloud.pull(includeMeetings: true) } }`; a failure goes to `syncStatus` and the pass goes on. Then `settle(arrived: Outbox.arrived(Self.arrivals(of: ids, paths: paths)))`, read off the main actor, where `arrivals` loads only `paths.callDirectory(id)` and `paths.callDirectory(id + "-iphone")` for the outbox's ids. Then `sendOutbox()`.
  - With no `onStoreChange`, a change of store ends with `Task { await pass() }`.
  - When it runs (wired in Task 7): at launch, when the app becomes active, after an import (the moved `importCall` ends with `sendOutbox()`), and every 60 seconds while an entry waits and the app is active. These are today's moments (`MossadPhoneApp.swift:40-58`, `PhoneStore.swift:170-173`, `PhoneStore+Import.swift:74`).

- [ ] **Step 1: Write the failing tests** (`@MainActor final class ProfileUploaderTests: XCTestCase`). A helper makes an uploader on a temporary folder with a `Parts` of `MemoryStore`s that records each zone asked for, a secret kept in a box, and a `UserDefaults` suite with a random name that the teardown removes. A helper writes a finished 3 second audio file with `PhoneRecording.settings` as `RoomAudio.finished(id, in:)` and adds its entry with `addImported`.
  - `testEachProfileSendsOnItsOwnStore`: two uploaders, `default` and Work, each with `.icloud` and one waiting recording (`20270115-090000` and `20270115-100000`). After `sendOutbox()` on both: the zones asked for are `["Mossad"]` for the first and `["Mossad-1a2b3c4d"]` for the second; the first store holds only `rec-20270115-090000`, the second only `rec-20270115-100000`; each outbox entry is `.sent(store: "icloud", ...)`.
  - `testAProfileWithNoKnownSyncSendsNothing`: Work with `listed: nil` and no saved choice: `syncWith == nil`, `cloud == nil`, and after `sendOutbox()` the entry still waits and no store was asked for. Then `listed = .icloud`: the next `sendOutbox()` sends it to the zone `Mossad-1a2b3c4d`.
  - `testTwoSendsAtOnceUploadARecordingOnce`: `async let a = u.sendOutbox(); async let b = u.sendOutbox()`, then both awaited: `await store.entries["rec-20270115-090000"]?.seq == 1` and the entry has `sends == 1`.
  - `testAGoneProfileSendsNothingAndKeepsItsAudio`: with `sends = false`: `sendOutbox()` and `pass()` save nothing in the store; the entry waits; the audio file exists.
  - `testASentRecordingSettlesOnlyByItsOwnProfilesMeeting`: Work's entry is sent. A written in-person meeting with the same id and `bundleID == PhoneRecording.bundleID` is saved in the folder of `default` only: after Work's `pass()`, the entry and the audio are there. The same meeting saved in Work's folder: after `pass()`, the entry is gone and the audio is deleted. A meeting with that id and another `bundleID` in Work's folder settles nothing.
  - `testAShownProfilesUploaderLeavesThePullToItsStore`: with `shown = true`, one waiting entry, and one sent entry whose meeting is in the folder: after `pass()` both entries are as before, both audio files exist, and no store was asked for.
  - `testAnIdleUploaderAsksNothing`: an empty outbox: `pass()` makes no store.
  - `testConnectingAServerInOneProfileLeavesTheOthers`: `default` is connected to `https://first.example.com` with the secret `"first-secret"`. `work.connect(ServerConnection(address: notes.example.com, secret: "made-up-secret"))`: the secret box of `default` still holds `"first-secret"`; its settings' `serverAddress` and `syncWith` are unchanged; Work's settings have `serverAddress == "https://notes.example.com"` and `syncWith == "server"`; no value of either suite's `dictionaryRepresentation()` contains `"made-up-secret"`.
  - `testOneProfileHasOneUploaderForTheAppsLife`: `uploaders.uploader(for: workProfile) === uploaders.uploader(for: workRenamed)` (the same id, another name and color); `all.count == 1`; a maker that returns nil gives nil and is asked again the next time.
  - `testTheOutboxOfAProfileIsInItsOwnFolder`: after `begin` and `ready()` on a second uploader of the same folder, the entry is read from `<root>/Recordings/outbox.json`; the folder of another profile has no `Recordings`.
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter ProfileUploaderTests`. Expected: the build fails with "cannot find 'ProfileUploader' in scope".
- [ ] **Step 3: Implement `ProfileUploader` and `ProfileUploaders`** by the moves and the new rules above. `PhoneStore` is not changed yet; the app still builds.
- [ ] **Step 4: Run to verify they pass.** The filter, then the whole suite. Expected: "0 failures".
- [ ] **Step 5: Commit.** `git commit -m "One uploader for each profile owns its outbox, its sync store, and its uploads"`

---

### Task 6: An import into any profile's uploader

**Files:**
- Create: `Packages/MossadCore/Sources/MossadCore/Room/ProfileUploader+Import.swift`
- Test: `Packages/MossadCore/Tests/MossadCoreTests/ProfileUploaderImportTests.swift`

**Interfaces:**
- Consumes: `ProfileUploader` (Task 5); `CallImport.plan`, `CallImport.Draft`, `CallImport.Known`, `CallImport.Choice`, `CallImport.choices`, `ImportMemory`, `RoomAudio.adopt`, `PeopleStore.peek(in:)`, `MeetingIndex(paths:).all()`.
- Produces:
  ```swift
  extension ProfileUploader {
      public var importing: Set<String> { get }                               // the paths of the handed files that an import reads now
      public var isImporting: Bool { get }                                   // !importing.isEmpty
      public var known: (@MainActor () -> [CallImport.Known])? { get set }   // the meetings of the store that shows; nil reads this profile's folder
      public func loadPeople() async                                         // this profile's saved people, read off the main actor
      public func importChoices(_ query: String, heard: [String], owner: String) -> [CallImport.Choice]
      public func importRefusal(_ draft: CallImport.Draft, from url: URL) async -> CallImport.Refusal?
      public func importCall(_ draft: CallImport.Draft, from url: URL) async -> Result<String, CallImport.Refusal>
      public func sent(_ id: String, within seconds: TimeInterval) async -> Bool
  }
  ```
  What moves from `PhoneApp/PhoneStore+Import.swift`, as it is: `importMemoryFile` (6), `importRefusal` (14-17), `importCall` (22-76) without its `discardIncoming` line (the caller discards), `sent` (85-93), `importPlan` (113-122). New: the meetings of `importPlan` and of the memory's `keep(only:)` are `known?()`, else `MeetingIndex(paths: paths).all()` read off the main actor; a draft's `personID` that is not an id of this profile's saved people is dropped and its name stays.

- [ ] **Step 1: Write the failing tests.** A helper writes a 70 second AAC file named `Call with Sam Carter.m4a` in a folder outside every profile.
  - `testAnImportForAProfileThatIsNotShownLandsInItsFolderOutboxAndStore`: uploaders for `default` and Work on `.icloud`. `await work.importCall(draft, from: file)` succeeds with an id; `RoomAudio.finished(id, in: work.recordingsFolder)` exists; Work's `outbox.json` and `imported.json` exist; the folder of `default` has no `Recordings` folder; after `await work.sendOutbox()` the store of the zone `Mossad-1a2b3c4d` holds `rec-<id>` with the field `kind == "phoneCall"`, and no store was made for `Mossad`. The source file still exists.
  - `testTheSameFileIsADuplicateOnlyInTheProfileThatHasIt`: after the import into Work, `await work.importRefusal(draft, from: file) == .duplicate` and `await first.importRefusal(draft, from: file) == nil`.
  - `testAPersonIDOfAnotherProfileNeverTravels`: Work's people file holds one person, Sam Carter, with the id `p-1`. A draft with `Choice(name: "Sam Carter", personID: "p-1")` imported into Work keeps `personID == "p-1"` in the outbox entry. A draft with `Choice(name: "Robin Vale", personID: "p-9")` keeps the name and has `personID == nil`. The same first draft imported into `default`, which has no people file, has `personID == nil`.
  - `testThePersonChoicesComeFromThisProfileOnly`: after `loadPeople()`, `work.importChoices("sam", heard: [], owner: "")` holds Sam Carter with `p-1`; the same call on `default` is empty.
  - `testAnImportWithNoMeetingsInMemoryReadsItsOwnFolder`: with `known == nil` and a written meeting in Work's folder at the draft's start and length, `importRefusal` is `.duplicate`; with `known = { [] }` it is nil.
  - `testAnImportIsBusyUntilItsAudioIsThere`: `isImporting` is false before and after `importCall`, and the id is in `joining` only while it runs (checked through a `background` closure that reads `joining` when the hold begins).
- [ ] **Step 2: Run to verify they fail.** Run: `swift test --filter ProfileUploaderImportTests`. Expected: the build fails with "value of type 'ProfileUploader' has no member 'importCall'".
- [ ] **Step 3: Implement the extension** by the moves and the two new rules.
- [ ] **Step 4: Run to verify they pass.** The filter, then the whole suite. Expected: "0 failures".
- [ ] **Step 5: Commit.** `git commit -m "A shared recording can be added to any profile, with that profile's own people, duplicates, and store"`

---

### Task 7: `PhoneStore` takes its profile, and `PhoneProfiles` builds a store on a switch

No behavior changes for a phone with one profile. This task has no new unit test: every rule it calls is tested in Tasks 1, 4, 5, and 6. Its proof is the grep of Step 6, the build, and run A of Task 10.

**Files:**
- Create: `PhoneApp/PhoneProfiles.swift`
- Modify: `PhoneApp/PhoneStore.swift`, `PhoneApp/PhoneStore+Import.swift`, `PhoneApp/MossadPhoneApp.swift`, `PhoneApp/RoomRecorder.swift`, `PhoneApp/CallImportScreen.swift:16-24`, `PhoneApp/AddRecordingIntent.swift:19`, `PhoneApp/AnalyticsScreen.swift:22`, `PhoneApp/CoachMemoryView.swift:170`, `PhoneApp/MeetingsListView.swift:18-22`, `PhoneApp/FindingsScreen.swift:14,51,53`

**Interfaces:**
- Consumes: everything of Tasks 1, 2, 4, 5, 6.
- Produces:
  ```swift
  @Observable @MainActor
  final class PhoneProfiles {
      static let shared: PhoneProfiles
      private(set) var book: PhoneProfileBook
      private(set) var store: PhoneStore              // the profile that shows
      let recorder: RoomRecorder                      // the app's one recorder
      var incomingAudio: IncomingAudio?               // moved from PhoneStore
      var problem: String?                            // the last refusal of a switch
      func uploader(for profile: PhoneProfile) -> ProfileUploader?
      func refresh() async                            // reads the item off the main actor, takes it, cleans up
      func switchTo(_ id: String) async
      func pass() async                               // the store's sync, then `pass()` of every other uploader that sends
      var waits: Bool { get }                         // any uploader waits
      func remember(importTarget id: String)
      func discardIncoming(_ url: URL)                // moved from PhoneStore+Import.swift:79-82
      func clearOldInbox()                            // moved from PhoneStore+Import.swift:97-110
  }
  // PhoneStore
  init(context: PhoneProfileContext, uploader: ProfileUploader, recorder: RoomRecorder)
  let context: PhoneProfileContext
  let uploader: ProfileUploader
  let facts: MeetingFactsCache                        // was AnalyticsScreen.facts
  var findingsSeen: String { get set }                // the profile's own settings
  func close() async
  // RoomRecorder
  var busy: Bool { get }                              // id != nil, or a start is in progress
  ```

- [ ] **Step 1: `PhoneStore`.** Remove `static let shared`. `paths` is `uploader.paths`. Every `UserDefaults.standard` becomes `uploader.settings` (`recentSearches`, lines 463-476). `languageModel` reads `SharedAIKey.load(profile: context.id)`. `syncWith`, `server`, `place`, `choose`, `connect`, `disconnectServer`, `outbox`, `uploading`, `joining`, `syncStatus`, `sendOutbox`, `sendAgain`, `canRemoveRecording`, `removeRecording`, `importChoices`, `importRefusal`, `importCall`, and `sent` become one-line forwards to the uploader, so no view changes for them; `syncWith` shows `.off` when the uploader's is nil. `writes` is `uploader.writes`. `runSync` uses `uploader.cloud`. `apply` calls `uploader.settle(arrived: Outbox.arrived(meetings))`. `startRecording`, `keepRecordingTitle`, and `stopRecording` call `uploader.begin`, `keepTitle`, and `finish` with the recorder's values. The init sets `uploader.shown = true`, `uploader.known` (the meetings in memory as `CallImport.Known`), and `uploader.onStoreChange` (the store-only lines of `use`, 363-368); its launch task awaits `uploader.ready()` in place of `readOutbox()`, then `uploader.recover(active:)`. `incomingAudio` with its two hooks (`MOSSAD_IMPORT`, `MOSSAD_IMPORT_AFTER`, lines 65-66 and 153-161), `discardIncoming`, and `clearOldInbox` leave for `PhoneProfiles`; the store's `importing` set goes, and `clearOldInbox` reads the union of every uploader's `importing`. `PhoneStore+Import.swift` keeps only the forwards.
- [ ] **Step 2: A store that can close.** The store holds a `StoreLife`. `load`, `sync`, `refreshSearch`, `refreshFindings`, and each `Task` that the store starts by itself ask `life.allows` first; `write(_:_:)` asks for `.finishEdit`, so the owner's last edit is saved and sent. `close()`: `life.close()`; cancel `syncTask` and `indexing`; await `launch`, `loading`, and the sync task; then `uploader.shown = false`, `uploader.known = nil`, `uploader.onStoreChange = nil`. `apply` returns at once on a closed store.
- [ ] **Step 3: The statics.** `AnalyticsScreen.facts` goes; `AnalyticsScreen` and `CoachMemoryView.swift:170` read `store.facts`. `findingsSeen` in `MeetingsListView` and `FindingsScreen` reads and writes `store.findingsSeen` in place of `@AppStorage`; the key and the format stay. The first `Snapshot.read` of a store sets `CompanyDomains.current` as today (`:207`), which also resets it after a switch.
- [ ] **Step 4: `PhoneProfiles`.** The init: `book = PhoneProfileBook.load(.standard)`; in a DEBUG build with `MOSSAD_ROOT`, `MOSSAD_PHONE_PROFILES` is decoded with `ProfilesItem.decode` and taken, and `MOSSAD_PHONE_PROFILE` sets `active`. The init also calls `clearOldInbox()`. `ProfileUploaders(make:)` makes an uploader from `PhoneProfileContext(id:)`, its `paths(documents: URL.documentsDirectory, environment:)`, its `settings(standard: .standard, makeSuite: UserDefaults.init(suiteName:))` (nil: no uploader, and the row says `PhoneProfileWords.cannotOpen`), `listed: profile.sync`, `offline` as today (`MOSSAD_ROOT` set), `Parts.live`, and `background` from `BackgroundTime`. Every listed and every leaving profile gets its uploader at once; a leaving one has `sends = false`. The store is built for `book.activeProfile`.
  - `refresh()`: with `MOSSAD_ROOT`, nothing is read. Else `await Task.detached { ProfilesItem.read() }.value`, `book.take`, `book.save(to: .standard)`; each uploader gets its `listed` and `sends`; new profiles get uploaders. When `book.activeProfile.id` is no longer the store's, `switchTo(book.activeProfile.id)`; when that is refused because the recorder runs, it is tried again when the recorder stops. Then for each leaving profile, off the main actor: `PhoneProfileBook.cleanup(profile, outbox: its entries, audio: RoomAudio.ids(in:)?.count)`; on `.remove`, and only when `context.mayRemove` says yes: the folder, `UserDefaults.standard.removePersistentDomain(forName: suite)`, the profile's server secret, `uploaders.drop(id)`, `book.forget(id)`, and a save.
  - `switchTo(_:)`: `PhoneProfileSwitch.decide(to:book:active:recording: recorder.busy || store.recorderScreenOpen, importing: any uploader's isImporting)`. `.refused` sets `problem`. `.go`: `await store.close()`; `book.active = id`, saved; `store = PhoneStore(context:uploader:recorder:)`; `Task { await pass() }`.
  - `pass()`: `await store.sync()`, then `await u.pass()` for each other uploader.
- [ ] **Step 5: The app.** `MossadPhoneApp` holds `PhoneProfiles.shared`. The `TabView` moves into a view `PhoneRoot`, shown as `PhoneRoot(query: $query).environment(profiles.store).id(profiles.store.context.id)`. Outside that id, on the app's level: `.environment(profiles)`, the import sheet (`callImportSheet` reads `profiles.incomingAudio`), `.onOpenURL`, `.task { await profiles.refresh(); await profiles.pass() }`, the same on `phase == .active`, and the 60 second loop as `.task(id: phase == .active && profiles.waits)` that calls `profiles.pass()`. `AddRecordingIntent` reads `PhoneProfiles.shared.store` for now (Task 9 changes it).
- [ ] **Step 6: Check that nothing of the phone still names the first profile by default.** Run:
  ```sh
  grep -rnE "SharedAIKey\.load\(\)|ServerPairing\.shared\(\)|CloudKitStore\(\)|CloudSync\(paths: [a-z]+\)|Paths\.live|Keychain\.app|PhoneStore\.shared|@AppStorage\(\"findingsSeen\"" PhoneApp
  grep -rn "UserDefaults.standard" PhoneApp
  ```
  Expected: the first prints nothing. The second prints only lines of `PhoneApp/PhoneProfiles.swift`.
- [ ] **Step 7: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 8: Commit.** `git commit -m "The iPhone's store takes its profile as a value, and a switch closes the old store before the new one is built"`

---

### Task 8: The Profile row, the Profile screen, the scan, and the title's mark

No unit test: the views hold no rule. Their words and rules are `PhoneProfileWords`, `PhoneProfileBook`, `PhoneProfileSwitch`, and `ProfileCode.parse`.

**Files:**
- Create: `PhoneApp/ProfilesScreen.swift`, `SharedUI/ProfileDot.swift`
- Modify: `App/ProfileSwitcher.swift:6-35` (the moved parts leave; `nsColor` stays), `PhoneApp/PhoneSettingsView.swift`, `PhoneApp/MeetingsListView.swift`, `PhoneApp/PhoneProfiles.swift`, `PhoneApp/PhoneStore.swift:515-517`, `project.yml:114`, `PhoneApp/Info.plist`

**Interfaces:**
- Consumes: `PhoneProfiles`, `PhoneProfileBook`, `PhoneProfileWords`, `ProfileCode.parse`, `ProfileCode.isCode`, `ServerClient(c).hello()`.
- Produces:
  ```swift
  // PhoneProfiles
  func apply(_ parsed: ProfileCode.Parsed) async -> Result<String, FriendlyError>   // the words of what it connected or added
  func remove(_ id: String)                                                         // "Remove from this iPhone"
  // Views
  struct ProfilesScreen: View
  struct ProfileMark: View          // the dot and the name, for the Meetings toolbar
  struct CodeScanner                // PhoneSettingsView.swift:251, no longer private
  ```

- [ ] **Step 1: `apply`.** `.notMossad`, `.damaged`, `.newer`: a failure with `parsed.problem`. `.server(c)`: `hello()` as `ConnectServerView.check` does (`PhoneSettingsView.swift:228-242`), then the uploader of `default` connects, and the result is `PhoneProfileWords.connected(name: default's name, host:)`. `.profile(code)`: with a server, `hello()` first; then `book.add(code, now:)` and a save; the uploader of that id is made; `code.settings` go into that uploader's settings; with a server, `uploader.connect(code.connection!)`, which puts the secret in that profile's Keychain service. The code itself is never stored and never logged. The result is `connected(name:host:)` or `added(_:)`.
- [ ] **Step 2: The scanner.** `CodeScanner`'s coordinator takes a text when `ProfileCode.isCode(text)` (`:275`). `ConnectServerView`'s scan (`:216-219`) calls `profiles.apply(ProfileCode.parse(code))` and shows the result's words in its "Connected" state or as its error. Its "Use ... from iCloud Keychain" row reads `ServerPairing.shared(profile: store.context.id)` (`:156`). The camera sentence in `project.yml:114` becomes "Mossad scans the code your Mac shows to connect to your server or to add a profile."; `PhoneApp/Info.plist` follows from XcodeGen.
- [ ] **Step 3: `SharedUI/ProfileDot.swift`.** Move `ProfileColor.color`, `title`, the private `hue`, and `ProfileDot` there, unchanged. The Mac build must still pass.
- [ ] **Step 4: Settings.** `PhoneSettingsView` gets a first section, only when `profiles.book.showsProfileRow`: one `NavigationLink` row with `ProfileDot`, the active profile's name, and, when another uploader waits, `PhoneProfileWords.waiting(count)` with that profile's name. It opens `ProfilesScreen`. `MOSSAD_SETTINGS=profiles` opens it at once.
- [ ] **Step 5: `ProfilesScreen`.** A list with the title "Profile":
  - One row for each of `book.listed`: the dot, the name, a checkmark on the active one, and under the name the first that applies: `PhoneProfileWords.cannotOpen`; `note(for:hasServer:)`; `waiting(count)` when its outbox is not empty (in `Palette.recording` when `syncStatus.uploads` has a problem for one of its entries). A tap calls `profiles.switchTo(id)` and, on a `.go`, closes Settings. The accessibility label is `PhoneProfileWords.label(name)`, with the selected trait on the active one.
  - The footer of that group is `profiles.problem` when set.
  - "Add a profile" opens `CodeScanner` in a full-screen cover, then `apply`; its words or its error show under the button.
  - A coded profile that is not active has the swipe action "Remove from this iPhone" (`profiles.remove`, which calls `book.removeFromPhone` and `refresh`'s cleanup).
  - The group `PhoneProfileWords.leavingTitle`, only when a leaving profile holds a recording: for each such profile, its name, and one row for each entry of its outbox with the title, the day and time, and the length as the Meetings list writes them (`MeetingsListView.swift:119-122`); `ShareLink(item: RoomAudio.finished(id, in:))` named "Share audio" when the file exists, and "Delete" with the dialog of today (`MeetingsListView.swift:162-170`), which calls that uploader's `remove(_:active:)` and then `profiles.refresh()`. The footer is `leavingFooter`.
- [ ] **Step 6: The Meetings list.** With `profiles.book.showsProfiles`: `ToolbarItem(placement: .topBarLeading) { ProfileMark }`, a button with a 10 point `ProfileDot` and the name in `.textRole(.secondary)` weight semibold, the label `PhoneProfileWords.label(name)`; it opens Settings on the Profile screen. Above the meetings, while a leaving profile holds a recording: one quiet row in the style of `findingsRow` (`:25-42`) with `PhoneProfileWords.leavingRow(name:count:)`; it opens the same screen. `PhoneStore.notOnThisPhone` (`PhoneStore.swift:515`) says `PhoneProfileWords.notInProfile` when the book shows profiles.
- [ ] **Step 7: Run the whole suite, the iPhone build check, and the Mac build check.** Expected: "0 failures"; exit 0 twice.
- [ ] **Step 8: Commit.** `git commit -m "Settings on the iPhone starts with the profile, and the Meetings title says which profile shows"`

---

### Task 9: The import screen's Profile row and the Shortcuts parameter

No unit test: the rules are `PhoneProfileBook.importDefault`, `profile(named:)`, and `ProfileUploader`'s import (Tasks 4 and 6).

**Files:**
- Modify: `PhoneApp/CallImportScreen.swift`, `PhoneApp/AddRecordingIntent.swift`, `PhoneApp/PhoneProfiles.swift`

**Interfaces:**
- Consumes: `PhoneProfiles.uploader(for:)`, `remember(importTarget:)`, `discardIncoming`, `book.importDefault`, `book.profile(named:)`, `PhoneProfileWords.noProfileNamed`, `ProfileUploader.importChoices`, `importRefusal`, `importCall`, `sent`, `loadPeople`, `ready`.
- Produces:
  ```swift
  // AddRecordingIntent
  @Parameter(title: "Profile") var profile: String?
  // PhoneProfiles
  func importChoices(_ query: String, for profile: PhoneProfile) -> [CallImport.Choice]
  ```
  `importChoices(_:for:)`: for the profile that shows, the store's list of today (people, heard names, the owner); for another, `uploader.importChoices(query, heard: [], owner: "")`.

- [ ] **Step 1: The screen.** A `@State` profile, first `profiles.book.importDefault`; in a DEBUG build `MOSSAD_IMPORT_PROFILE=<id>` picks a listed one. With `book.showsProfiles`, a first `HairlineRow`: `PhoneLabel("Profile")` and a `Menu` of `book.listed`, each with its dot and name. On a change: `person = nil`, `await uploader.loadPeople()`, and `refusal` is asked again of the new profile's uploader. `read()` asks `importRefusal` of the chosen uploader; the person picker reads `profiles.importChoices(query, for: profile)`; `add()` calls the chosen uploader's `importCall`. On success: `profiles.remember(importTarget: profile.id)`, `profiles.discardIncoming(incoming.url)`, and the sheet closes; the tab changes to Meetings only when the chosen profile shows. A profile with no uploader shows `PhoneProfileWords.cannotOpen` in place of the button.
- [ ] **Step 2: The Shortcuts action.** The profile is `book.profile(named:)` for the parameter, else `book.importDefault`. A name that no listed profile has throws an error whose words are `PhoneProfileWords.noProfileNamed(name)`. In place of `store.launch`: `await uploader.ready()` and `await uploader.loadPeople()`. The person is `CallImport.typed(person, among: profiles.importChoices(person, for: profile))`. The import and `sent(id, within: 20)` are the uploader's. A parameter given saves the import target, as the screen does. The description says "Adds a call recording to Mossad. Your Mac writes its note." as today.
- [ ] **Step 3: Run the whole suite and the iPhone build check.** Expected: "0 failures"; exit 0.
- [ ] **Step 4: Commit.** `git commit -m "A shared call recording goes to the profile the owner picks, and is sent at once whichever profile shows"`

---

### Task 10: The simulator check

Headless, on your own device, with made-up data only. Run the call gate first. Never open Simulator.app. Look at each screenshot yourself.

- [ ] **Step 1: Make the data and the device.**
  ```sh
  D="$(mktemp -d)"; mkdir -p "$D/Mossad"
  python3 - "$D/call.wav" <<'EOF'
  import math, struct, sys, wave
  w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
  w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(i * 0.05))) for i in range(16000 * 70))); w.close()
  EOF
  afconvert -f m4af -d aac "$D/call.wav" "$D/Call with Sam Carter.m4a"
  printf '{"version":1,"profiles":[{"id":"default","name":"Mossad","color":"orange","sync":"icloud"},{"id":"1a2b3c4d","name":"Work","color":"blue","sync":"icloud"}]}' > "$D/profiles.json"
  TYPE="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; print([d for d in json.load(sys.stdin)["devicetypes"] if d["productFamily"]=="iPhone"][-1]["identifier"])')"
  UDID="$(xcrun simctl create "Mossad profiles check" "$TYPE")"
  xcrun simctl boot "$UDID"
  xcrun simctl install "$UDID" build/phone/Build/Products/Debug-iphonesimulator/*.app
  run() { xcrun simctl launch --terminate-running-process "$UDID" com.dwebber.mossad.phone >/dev/null; sleep 6; xcrun simctl io "$UDID" screenshot "$D/$1.png"; }
  ```
  Each run below sets its variables with the prefix `SIMCTL_CHILD_`, and always `SIMCTL_CHILD_MOSSAD_ROOT="$D/Mossad"`.
- [ ] **Step 2: Run A, one profile.** `run a-meetings`; with `MOSSAD_SETTINGS=1`: `run a-settings`; with `MOSSAD_IMPORT="$D/Call with Sam Carter.m4a"`: `run a-import`. Expected: Meetings has no mark beside its title; Settings starts with "Sync with"; "Add call" has the rows Title, When, and Who was on the call, and no Profile row. `ls "$D"` shows no `Mossad Profiles`. `xcrun simctl spawn "$UDID" defaults read com.dwebber.mossad.phone phoneProfiles` ends with "does not exist".
- [ ] **Step 3: Run B, two profiles.** Add `MOSSAD_PHONE_PROFILES="$D/profiles.json"` to every run, and `MOSSAD_PHONE_PROFILE=default` to every run that does not name another profile.
  - `run b-meetings`: the mark "Mossad" with an orange dot.
  - With `MOSSAD_SETTINGS=1`: `run b-settings`: the first row is the profile. With `MOSSAD_SETTINGS=profiles`: `run b-profiles`: two rows, the check on "Mossad", and "Add a profile".
  - With `MOSSAD_PHONE_PROFILE=1a2b3c4d`: `run b-work`: the mark "Work" with a blue dot, and no meeting or recording of "Mossad" in the list.
  - With `MOSSAD_IMPORT` as above: `run b-import`: the Profile row is first and says "Mossad".
  - With `MOSSAD_IMPORT`, `MOSSAD_IMPORT_PROFILE=1a2b3c4d`, and `MOSSAD_IMPORT_ADD=1`, while "Mossad" shows: `run b-added`. Expected: the Meetings list of "Mossad" has no group "On this iPhone". `ls "$D/Mossad Profiles/1a2b3c4d/Recordings"` shows one `.m4a`, `outbox.json`, and `imported.json`. `ls "$D/Mossad/Recordings" 2>/dev/null` shows nothing. The source file `"$D/Call with Sam Carter.m4a"` still exists.
  - With `MOSSAD_SETTINGS=profiles`: `run b-waits`: the row "Work" says "1 recording waits to send".
  - With `MOSSAD_PHONE_PROFILE=1a2b3c4d`: `run b-work-list`: "On this iPhone" has one row, "Phone call" or the file's title, "Waiting to send".
- [ ] **Step 4: Clean up.** `xcrun simctl shutdown "$UDID"; xcrun simctl delete "$UDID"; rm -rf "$D"`. `xcrun simctl list devices | grep -c "Mossad profiles check"` prints 0.
- [ ] **Step 5: Report** each expectation as seen or not seen. A miss is a defect of Tasks 7 to 9: fix it there, with the suite and the build check, and run this task again. Nothing to commit unless a fix was made.

---

### Task 11: Words: `AGENTS.md` and the website

**Files:**
- Modify: `AGENTS.md`, `website/content/site.json` (the feature `separate-profiles`)

- [ ] **Step 1: `AGENTS.md`**, in the rows' own style:
  - The profiles row: on the iPhone a profile is a value (`PhoneProfileContext`: `Documents/Mossad Profiles/<id>`, the service and the suite `com.dwebber.mossad.profile.<id>`, the zone, the accounts; `default` is the phone of before); `ProfilesItem` (the third iCloud Keychain item, `profiles`: id, name, color, sync, with a `version`; `plan` is the Mac's rule: written from a registry that reads cleanly with two profiles or more, deleted with one, never touched with no file); `Profile.sync` and `noteSync`; `ProfileCode` (`mossad-profile:`, shown by "Show code for iPhone…" for the active profile; the pairing card shows it in a profile other than the first); `PhoneProfileBook` (the phone's list in `phoneProfiles`, a profile that left, `cleanup`), `PhoneProfileSwitch`, `StoreLife`.
  - `.../Sync/`: the third item and who writes it.
  - `.../Room/`: `ProfileUploader` (one for each profile for the app's life: the outbox, the sync choice and store, the write queue, the uploads, the imports; `pass` for a profile that is not shown pulls only while a sent recording waits and settles by that profile's own `call.json`) and `ProfileUploaders`.
  - `PhoneApp/`: `PhoneProfiles` (the list, the uploaders, the one recorder, the store that shows, the switch), `ProfilesScreen`, the Profile row of the import screen, the Profile parameter of the Shortcuts action, which settings are a profile's own, and the hooks `MOSSAD_PHONE_PROFILES`, `MOSSAD_PHONE_PROFILE`, `MOSSAD_IMPORT_PROFILE`, `MOSSAD_SETTINGS=profiles`.
- [ ] **Step 2: `site.json`.** In `separate-profiles`: the body gains "on your Mac and your iPhone"; two details are added, "On your iPhone, each profile has its own meetings, and you change profile in Settings" and "A phone call that you share goes to the profile you pick"; the sources gain `PhoneApp/PhoneProfiles.swift`, `PhoneApp/ProfilesScreen.swift`, and `Packages/MossadCore/Sources/MossadCore/Profiles/PhoneProfileBook.swift`. Nothing about the Keychain item or the code's format.
- [ ] **Step 3: Check.** `python3 -m json.tool website/content/site.json > /dev/null` exits 0. Run the whole suite. Expected: "0 failures".
- [ ] **Step 4: Commit.** `git commit -m "AGENTS.md and the website say what profiles add on the iPhone"`

---

## Owner steps

Only a real iPhone with iCloud Keychain can prove these. The Mac and the iPhone use one iCloud account, and both have this build.

1. **One profile.** On an iPhone whose Mac has one profile: Settings starts with "Sync with", and Meetings has no mark. Nothing is new.
2. **The item arrives.** On the Mac, have two profiles. Open each profile once, so each one says how it syncs. Within some minutes, Settings on the iPhone starts with the Profile row.
3. **The switch.** Tap the other profile. Its meetings arrive from its own zone or server, and none of the first profile's show. Chat works when that profile's "Use my AI key on my iPhone" is on.
4. **A room recording.** Record a room in the second profile. Its note arrives in that profile on the Mac.
5. **A phone call.** Share a call recording, pick the profile that does not show, and tap "Add to Mossad". Its note arrives in that profile.
6. **A rename and a delete.** Rename a profile on the Mac: the iPhone follows. Delete one: it leaves the iPhone's list.
7. **The code.** On an iPhone with iCloud Keychain off: on the Mac, Settings > General > Profiles, "Show code for iPhone…"; on the iPhone, Settings, Your server, Scan code.
8. **Update the Mac first.** A Mac of before this change, in a profile other than the first, still shows a server code that the iPhone takes for the first profile. Do not scan one from such a Mac.

No CloudKit Console step: the new zones use the record types that exist.

## Self-review

- **Spec coverage.** How the phone knows the profiles: Tasks 2, 3, 4, 8. Apart on the phone: Tasks 1, 5, 7. One process, a new store on a switch: Tasks 4, 7. The Profile row and the title's color: Task 8. The room recorder: Tasks 4, 7. The import screen and one outbox for each profile: Tasks 5, 6, 9. Never two profiles in one list, and no move: Tasks 7, 9. The words and the website: Task 11.
- **Not done on purpose.** No upload while the app does not run. No profile choice by a Shortcuts entity. No move of a recording between profiles by the phone itself. The named speakers of a profile that is not shown are not offered as people.
- **Type consistency.** `PhoneProfile`, `PhoneProfileContext`, `ProfilesItem` (`Read`, `Plan`), `ProfileCode` (`Parsed`), `PhoneProfileBook` (`Cleanup`), `PhoneProfileSwitch`, `StoreLife`, `PhoneProfileWords`, `ProfileUploader` (`Parts`), `ProfileUploaders`, `PhoneProfiles`, `ProfilesScreen`, `ProfileMark`, `noteSync`, and `updateSharedProfiles` have one spelling in every task.
- **Review Focus.** Each of the five lines names its tests, and each test is in the task that owns the code.
- **Open risk.** The author did not build. Task 5 moves about 250 lines out of `PhoneStore`; run A of Task 10 is the check that a phone with one profile is as before. The simulator has no iCloud Keychain, so "Owner steps" 2 to 7 are the only proof of the item and the code on a device.
