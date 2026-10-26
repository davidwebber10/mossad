# Design overhaul plan

Spec: `docs/superpowers/specs/2026-10-26-design-overhaul.md` (approved 2026-10-26, with re-summaries for the last 90 days and a one-time 30-day coach question pass).

Rules: test first for logic in MossadCore; screenshots of Mossad windows only by window ID and only when no call records and the owner is not working full screen (use `--ui-preview` with `MOSSAD_ROOT`); check for a live call before every install; commit after each task; no AI attribution; no em dashes.

## Phase 1. Foundation
- [ ] 1.1 `SharedUI/Platform.swift`: `Space`, `Radius`, motion helper, 27 wrappers (`toolbarPolish`, `rowSwipe`, `phoneNavPolish`).
- [ ] 1.2 Theme on system colors; keep `Theme` names so call sites change little.
- [ ] 1.3 Mac toolbar: remove `ignoresSafeArea` in `MainWindow`, `.navigationTitle` and `.toolbar` per pane, `.searchable` in Meetings.
- [ ] 1.4 `DateRangeButton` (presets menu, custom two-month calendar, step arrows) in Analytics.

## Phase 2. Analytics and People
- [ ] 2.1 MossadCore metrics: scheduled calls and time, work-day load, back-to-back, call-free days, questions and interruptions (made and received), 1:1 vs group talk share, outcomes per hour, commitments made and done, people table (balance, trend, last met).
- [ ] 2.2 Person relation stats: balance 1:1/group, cadence, who leads, interruptions both ways, response time, topics, open items both ways, value together.
- [ ] 2.3 Analytics view rebuilt per spec, with scrub highlight and chart accessibility.
- [ ] 2.4 Person page rebuilt; Mac People list and iPhone People use the new stats; shared `PersonMark`.
- [ ] 2.5 Re-summarize calls from the last 90 days that lack kind, tags, or outcomes.

## Phase 3. Coach questions
- [ ] 3.1 `CoachQuestion` model, profile storage, merge, sync, answers to facts.
- [ ] 3.2 Coach schema and prompt: up to 2 questions per call; confirmed, rejected, and pending questions in the prompt. Keep the union-type count at 16 or less.
- [ ] 3.3 UI: Coach tab, coach memory (Mac and iPhone).
- [ ] 3.4 One-time 30-day question pass.

## Phase 4. Polish
- [ ] 4.1 Floating glass player bar with keys.
- [ ] 4.2 Chat composer and message parity.
- [ ] 4.3 First-run welcome with live permissions.
- [ ] 4.4 Coach after-call moment.
- [ ] 4.5 Accessibility pass.
- [ ] 4.6 Window focus states, sidebar band.
- [ ] 4.7 Menu commands and shortcuts.
- [ ] 4.8 iPhone: zoom transition, nav bar minimize, swipe actions, empty states.
- [ ] 4.9 Fonts to text styles across the remaining screens; `ContentUnavailableView`; placeholders.

## Log
