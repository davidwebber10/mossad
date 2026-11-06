# Editorial redesign, meeting titles, org chart

Status: approved direction (Nov 6). Replaces the look in `2026-10-26-design-overhaul.md`. The newest spec wins.

## Intent

Mossad works, but it looks like a default SwiftUI app. The redesign makes it calm and editorial: warm paper tones, almost no cards, hierarchy from type and hairlines, Liquid Glass only for what floats. The same system covers the Mac and the iPhone, so both read as one product. In the same release, meetings get real titles, decisions get times, people get an org chart, and bookmarks can carry a note.

The owner chose to ship all of it in one release.

## Sources

- The design canvas from Claude Design: `Mossad Redesign.dc.html` (design system and every page, light and dark, menu bar). It lives outside the repo.
- A second canvas for the screens the first one does not cover and for the iPhone app (processing card, live call and room views, sheets, setup, onboarding, org chart import, titles, empty states, iPhone screens).
- Where a canvas and this spec disagree, this spec wins; where the canvases are silent, follow the system rules below.

## Design system (from the canvas)

- **Type**: SF Pro only. Display 28/600, Title 22/600, Lede 17/500, Headline 13/600, Body 13/400, Secondary 12/400, Label 11/600 caps. SwiftUI: `.largeTitle` semibold, `.title2`, `.title3` medium, `.headline`, `.body`, `.callout`, `.caption` semibold. Numbers are tabular.
- **Spacing**: 4 pt grid: 4, 8, 12, 16, 24, 40. **Radii** concentric: control 6, row and chip 10, card 14, glass pane 20, capsule.
- **Page grammar**: a 150 pt label column on the left, content on the right, hairlines between groups. Used by the meeting summary, coach, person profile, analytics, and settings.
- **Glass** (`.glassEffect`): the sidebar, the toolbar controls (search, segmented tabs, buttons), the floating player, popovers and menus, the chat composer. **Never glass**: list rows, summary text, the progress card, chips, stats, content on the window background.
- **Elevation**: three levels only: window background, content surface, floating glass.
- **Color**: one orange accent for selection and "needs you" (unnamed voices, overdue, permissions). Red only for recording and destructive actions. Processing is accent at low opacity with a moving fill, never a spinner. Platform colors (Meet green, Zoom blue, Teams indigo, in person neutral) only as dots. Twelve speaker hues at equal lightness; the owner is always hue 1, and one speaker keeps one color in chips, lanes, transcript, and timeline. Every text role meets 4.5:1 in both modes.
- **Fallbacks**: Reduce Transparency makes glass the opaque surface color with a hairline. Increase Contrast raises hairlines to 20% ink. Reduce Motion turns pulses into static dots; the progress fill still moves.
- **App icon**: unchanged (the owner's choice).

## Screens

All pages in the canvases: Meetings (list and calendar, summary, transcript, coach, chat tabs), Commitments, Chat, People (list, profile, org chart), Analytics, Settings (General, Recording, AI, Sync & Server, Coach), Log, the menu bar panel, and the iPhone app.

### The lanes player

One lane per speaker, name and minutes on the left, the whole meeting across; the playhead is a line through all lanes; clicking a lane plays from that time. Decisions are dots and bookmarks are accent flags on the ruler. At most 12 lanes show; more scroll inside the player, with "+N more voices" at the bottom edge. Below the lanes: back 15, play, forward 15, Add bookmark, speed.

### Meetings list and titles

Groups: Upcoming, Today, Yesterday, then weekdays. A row shows the title, time, platform dot, length, and "needs names" as text. See "Meeting titles" below.

## Features in this release

### 1. Meeting titles

Today 12 of 21 meetings show "Google Meet call" or "In person call", because no calendar invite matched them (ad hoc calls, in-person meetings, invites without the meeting link).

- **Order**: the calendar invite's title when one matched (unchanged); else a generated title; else "<Platform> call".
- **Generated title**: the summary request returns `title` (at most 60 characters, names the topic and, for small meetings, the other person: "Freight model review with Jon"). Stored as `generatedTitle`, separate from `calendarTitle`, because Analytics counts a meeting with `calendarTitle` as scheduled.
- **During the call**: after about 5 minutes of live transcript, a small, cheap model request gives a provisional title, so the menu bar and the list show it while the call runs. The summary's title replaces it.
- **Editing**: the owner can rename a meeting inline; an edited title (`customTitle`) wins over every other source and is never overwritten.
- The canvas shows "Named by Mossad" on generated titles.

### 2. Decisions with times

The summary request returns each decision with the time it was made (seconds into the meeting). Old meetings get the same by running the summary again (see 6). A decision without a time shows without a dot.

### 3. Bookmarks with an optional note

Add bookmark (during the call, from the menu bar or the hot key, and afterwards from the player) adds the bookmark at once; a small popover then offers an optional note. No note is fine. The note shows on the ruler flag's tooltip and in the summary's Bookmarks list.

### 4. Org chart from a Paylocity export

- **Format**: CSV with `Last Name, First Name, Position Title, Supervisor`, the supervisor as "Last, First". No email column. One person has no supervisor (the root).
- **Import**: Settings or People › Import org chart… The file is copied to `~/Mossad/People/org.csv` and never synced or committed. Replace any time.
- **Matching** to saved people, by name: exact first and last name, case and spacing ignored; then common nicknames (Ben/Benjamin, Zach/Zachary, Jim/James, …) with the same last name; then the owner's manual matches, kept in `org-matches.json`. Duplicate full names in the file (there are a few) are left for a manual match.
- **Review**: a list of saved people with no match, each with a picker (a person from the file, or "Outside the company").
- **Views**: People gets a List or Org chart toggle. The chart shows the owner's part of the tree by default (the owner's manager, the owner, peers, and reports), the rest on demand; people outside the company are a separate group. A matched person's profile shows title and manager.
- The title is also given to the summary and the coach as context ("Jon Hueni, VP Planning").

### 5. People sort and duplicates

The sort menu from the canvas: Most recent, Most met with, Most talk time, Newest, Name, plus a "Needs a voice sample" filter. The duplicates banner and review from 2.7.8 stay, above the list.

### 6. Bring old meetings up to date

A one-time job after the update: for every written meeting with a transcript, ask the summary again so it has a generated title and decisions with times. It runs in the background, oldest last, and logs its cost. Notes are rewritten; names, tags the owner set, and edited titles stay.

## Not in this release

- Text-only bookmarks as a separate feature (only the optional note above).
- Changing the app icon.

## Constraints

- SwiftUI on macOS 26 and iOS 26, system materials, SF Pro and SF Symbols only.
- Private data (names, emails, the org file) never goes into the repo, tests, or previews; tests use made-up names.
- The zero-interaction goal holds: nothing here adds a prompt during a call. The bookmark note popover is optional and dismisses itself.
