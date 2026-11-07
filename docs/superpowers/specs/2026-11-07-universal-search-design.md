# Universal search and the iPhone bottom bar

## Intent

The owner wants search to be "super good": one place that finds meetings, people, transcript moments, and the rest,
shown in separate groups, high quality and slick, on the iPhone and on the Mac. On the iPhone the bottom bar becomes
option E from the mockups: Meetings, Tasks, Chat, Analytics, and a Search circle. People becomes a section inside
Analytics. The red "Record room" pill leaves the bar area.

## Goals

- One search engine in MossadCore, shared by both apps, fully unit tested.
- Results in groups, in this order, each group hidden when empty: Top hit, Meetings, People, Transcript (moments),
  Decisions and action items, Tasks, Chats.
- Quality: words in any order (all must match), prefix matching on every word ("freig" finds "freight"), case and
  diacritic folding, one-typo tolerance for words of 5+ letters in names and titles, nicknames for people (the
  existing Nicknames table: "Mike" finds "Michael"), an exact-phrase bonus, field weights (title > tag/kind > person >
  decision/action item > transcript), and a mild recency boost. Every result carries the matched ranges so the UI can
  bold them; transcript results carry a short snippet centered on the match.
- Transcript moments: one result per matching turn, with meeting, speaker, time; at most 3 shown per meeting inside
  the group, "N more in this meeting" to expand. Opening one plays the meeting from that time.
- Speed: an in-memory index built off the main thread and updated when meetings change; a query on 500 meetings with
  800 turns each answers in under 50 ms (a test pins this).
- Mac: Command-K from anywhere in the main window opens a search palette (a floating glass panel over the window,
  the design's tokens and icons). Typing updates results live; Up/Down move across groups; Return opens; Command-Return
  opens a meeting's transcript at the moment; Esc closes. Empty query shows recent meetings and frequent people.
  The toolbar search fields keep filtering their own page as today.
- iPhone: the Search tab (iOS 26 search role, the circle at the right of the tab bar) shows the same groups as a
  native list with the search field at the bottom; empty query shows recent searches, people, and tags.
- iPhone bar: tabs Meetings, Tasks, Chat, Analytics, plus Search. Analytics gains a People section (the current People
  screen's list and profile, reached from Analytics). "Record room" stays a floating button, but only on the Meetings
  tab (not on Tasks, Chat, Analytics, or Search), placed so it never sits on the tab bar; while recording, the
  existing recording UI stays.

## Non-goals

- No semantic or AI search in this pass (Chat covers questions). No server-side search. No new data sync.
- No org chart on the iPhone (the org file stays on the Mac).

## Constraints

- Swift 6, SwiftUI, macOS 26 and iOS 26. Logic in MossadCore, test-first. Design tokens and icons from SharedUI and
  the asset catalogs. Owner rules in AGENTS.md (no AI attribution, secrets in Keychain, never block the main thread).

## Calls made for the owner (not asked)

- Command-K palette on the Mac instead of replacing the per-page search fields.
- Typo tolerance only on names and titles, not transcript text, to keep transcript results precise.
- People lives under Analytics as a section with its own row/link, as the owner asked; the Mac keeps People in the
  sidebar.
