# Design overhaul: coach questions, Analytics, People, and whole-app polish

Date: 2026-10-26. Sources: the owner's requests, two design reviews, and the 2026 Apple Design Award winners.

## Intent

Mossad should feel like a best-in-class Apple app on Mac and iPhone: calm, native, and polished. The owner also wants the coach to understand their context better, and wants more useful numbers about their time and the people they meet.

## Constraints

- Minimum stays macOS 26 / iOS 26. Use macOS 27 / iOS 27 features behind `if #available`, through small shared wrappers in `SharedUI/Platform.swift`, with a good 26 fallback.
- Glass only in the controls layer (toolbars, sidebar, player bar, chat composer, recording pill). The one exception is a short-lived chart scrub highlight.
- No new notifications. The coach's questions wait where the owner already looks.
- No required third-party UI libraries.
- Do not add `.inspector` to the main `NavigationSplitView`: it crashes on macOS 27.0.

## Part 1. Coach questions ("Is this right?")

The coach forms conclusions about the owner's world and asks the owner to confirm them. Confirmed ones become facts that shape the purpose of each call and the feedback.

- Each review may propose at most 2 questions, only when the answer would change the coaching. Examples: "Mitch reports to you." "The Monday call is a status update, not a decision meeting." "You held back a date in the budget call. Was that on purpose?"
- A question has: the statement, its kind (relationship, role, meeting purpose, preference, or about this call), the evidence (a quote with its time), and the call.
- The owner answers Yes, No, or "Not quite" with a short note ("No: legal approves dates first").
  - Yes: the statement becomes a fact.
  - Not quite: the note becomes the fact.
  - No: the coach remembers that it is not true and never asks again.
- About-this-call answers also correct that call's review: a wrong point is withdrawn and the context is kept for later calls.
- Where: the top of the meeting's Coach tab, a "Questions" list in the coach's memory (Mac Settings and iPhone), and the coach's after-call message. They sync through iCloud like the focus.
- A one-time pass over the last 30 days proposes a first set (at most 10).

## Part 2. Analytics

One story, top to bottom: how much time, where it went, with whom, how you did, what it cost.

1. Header: the title and one date button ("Sep 27 – Oct 26, 2026"). Its menu has Last 7, 30, 90 days, This month, Last month, This year, All time (each with its dates), and "Custom range…", which opens two month calendars (click the start, then the end). Two small arrows move the period back or forward.
2. Four tiles: Time in calls, Calls, Scheduled share, Your talk share, each with the change from the period before.
3. Your time: one chart of scheduled and unscheduled bars, with an Hours / Calls switch, next to the Scheduled card: two bars, "Calls" and "Time", each split scheduled and unscheduled with percents, plus the average length of each.
4. When you meet: the heat map, and the work-day load (hours in calls a day, back-to-back share, call-free days).
5. What you meet about: top topics, and meeting value (high, medium, low).
6. Who you meet with: a table of the top 8 people: calls, time, share of your call time, talk balance, trend, last met. A click opens the person.
7. How you communicate: pace, questions, and interruptions (made and received), each against your usual, and your talk share in 1:1s against groups.
8. Outcomes: action items and decisions per call hour, and commitments made and done.
9. Costs: in a closed disclosure at the bottom.

Interaction: drag across any time chart to read exact values. A glass highlight follows the pointer and the card reacts slightly (not with Reduce Motion). Charts animate between periods. Every bar, topic, and person filters the Meetings list.

Most new numbers come from the transcripts and cost nothing. Topics, kind, and outcomes are missing on older calls and need a new summary.

## Part 3. People

The person page shows, in relation to the owner:

1. Talk balance: you against them, in 1:1s and in groups.
2. Cadence: calls per week over six months, average gap, last met, usual slot.
3. Who leads: who speaks first, questions per hour for each.
4. Interruptions: how often you cut in on them, and they on you.
5. Response time: the usual pause before you answer them, and they you.
6. Topics together: the top 5.
7. Open items both ways: their action items from shared meetings, and your commitments to them with done status.
8. Value together: how your shared meetings were rated.

One line under the name replaces the "Voice samples" and "First heard" tiles. The same color and initials for a person on Mac and iPhone.

## Part 4. Whole-app polish

1. A real macOS toolbar with titles and search (`.searchable`) instead of seven hand-made headers.
2. A semantic theme: system colors, text styles (Dynamic Type), a 4 pt spacing grid, three corner radii, `ConcentricRectangle`.
3. A floating glass player bar over the transcript, with keyboard keys.
4. The same chat composer and message style on Mac and iPhone.
5. A first-run welcome with live permission checks (Moonlitt).
6. The coach's moment after a call: one line, shown calmly, with the focus result (grug).
7. Accessibility: chart descriptions for VoiceOver, symbols with colors, Increase Contrast, large text (Guitar Wiz).
8. Window focus states and the sidebar band (macOS 27).
9. Menu commands and shortcuts: ⌘1–7 for sections, ⌘⇧F to find in a transcript, ⌘R to regenerate.
10. iPhone: the zoom transition into a meeting, a navigation bar that shrinks on scroll (27), swipe actions (27).
11. Empty states with `ContentUnavailableView`, placeholders instead of spinners, numbers that animate when they change.

## Order

1. Foundation: theme, toolbar, the date button. Everything after builds on it.
2. Analytics and People.
3. Coach questions.
4. The rest of the polish, Mac and iPhone.

Each step ships on its own, with screenshots in light and dark mode.

## Left to the builder

Chart details, exact copy, and the placement of small controls, within the rules above.
