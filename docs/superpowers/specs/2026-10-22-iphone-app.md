# Mossad for iPhone

## Intent

David wants to read his meetings on his phone: summaries, action items, decisions, transcripts, and the coach's reviews. The phone does not record calls. Recording a meeting in a room from the phone may come later.

## Decisions

- **Sync through iCloud (CloudKit, private database).** David chose iCloud over Cloudflare: no server to run, and only his Apple account can read the data.
- **The Mac writes, the phone reads.** The Mac is the only writer. The phone fetches changes and keeps a local copy, so it works offline.
- **Container:** `iCloud.com.dwebber.mossad`, private database, custom zone `Mossad`.
- **Records:**
  - `Meeting`, named by the call ID. Fields for the list: `title`, `start`, `end`, `platform`, `headline`, `kind`, `tags`, `status`. Assets: `record` (the call record without voice fingerprints, word timings, or per-track utterances, to keep it small) and `coach` (the coach review, when there is one).
  - `CoachProfile`, one record: the coach's memory as an asset.
- **Change tracking on the Mac:** a hash of what was last uploaded for each meeting, in `~/Mossad/Sync/state.json`. Only changed meetings upload; deleted meetings are deleted from iCloud.
- **Audio** stays where it is (on the Mac, or in R2). Playback on the phone is a later step.
- **Chat on the phone** uses the Mac's AI provider and key, shared through iCloud Keychain when the owner turns on "Use my AI key on my iPhone". Chats, ratings, replies to the coach, and the coach's memory sync both ways (`Chat`, `CoachNotes`, and `CoachProfile` records).
- **Tabs:** Meetings, Chat (also the coach), People, Analytics, and a search tab. Liquid Glass only on the navigation layer: the tab bar, toolbars, sheets, and the chat composer.

## Setup that needs David

- The iCloud container must exist and be enabled for both app IDs (`com.dwebber.mossad`, `com.dwebber.mossad.phone`). Xcode creates it with automatic signing when it is signed in to the account.
- The Mac app gets the iCloud entitlement only once that works, so recording is never at risk from a signing change. Until then, the Mac sync code does not run.
