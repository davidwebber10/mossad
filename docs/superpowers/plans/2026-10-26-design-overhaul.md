# Design overhaul plan

Spec: `docs/superpowers/specs/2026-10-26-design-overhaul.md` (approved 2026-10-26, with re-summaries for the last 90 days and a one-time 30-day coach question pass).

Rules: test first for logic in MossadCore; screenshots of Mossad windows only by window ID and only when no call records and the owner is not working full screen (use `--ui-preview` with `MOSSAD_ROOT`); check for a live call before every install; commit after each task; no AI attribution; no em dashes.

## Phase 1. Foundation
- [ ] 1.1 `SharedUI/Platform.swift`: `Space`, `Radius`, motion helper, 27 wrappers (`toolbarPolish`, `rowSwipe`, `phoneNavPolish`).
- [ ] 1.2 Theme on system colors; keep `Theme` names so call sites change little.
- [x] 1.3 Mac toolbar: remove `ignoresSafeArea` in `MainWindow`, `.navigationTitle` and `.toolbar` per pane, `.searchable` in Meetings.
- [x] 1.4 `DateRangeButton` (presets menu, custom two-month calendar, step arrows) in Analytics.

## Phase 2. Analytics and People
- [x] 2.1 MossadCore metrics: scheduled calls and time, work-day load, back-to-back, call-free days, questions and interruptions (made and received), 1:1 vs group talk share, outcomes per hour, commitments made and done, people table (balance, trend, last met).
- [x] 2.2 Person relation stats: balance 1:1/group, cadence, who leads, interruptions both ways, response time, topics, open items both ways, value together.
- [x] 2.3 Analytics view rebuilt per spec, with scrub highlight and chart accessibility.
- [x] 2.4 Person page rebuilt; Mac People list and iPhone People use the new stats; shared `PersonMark`.
- [x] 2.5 Re-summarize calls from the last 90 days that lack kind, tags, or outcomes.

## Phase 3. Coach questions
- [x] 3.1 `CoachQuestion` model, profile storage, merge, sync, answers to facts.
- [x] 3.2 Coach schema and prompt: up to 2 questions per call; confirmed, rejected, and pending questions in the prompt. Keep the union-type count at 16 or less.
- [x] 3.3 UI: Coach tab, coach memory (Mac and iPhone).
- [x] 3.4 One-time 30-day question pass.

## Phase 4. Polish
- [x] 4.1 Floating glass player bar with keys.
- [x] 4.2 Chat composer and message parity.
- [x] 4.3 First-run welcome with live permissions.
- [x] 4.4 Coach after-call moment.
- [x] 4.5 Accessibility pass.
- [x] 4.6 Window focus states, sidebar band.
- [x] 4.7 Menu commands and shortcuts.
- [x] 4.8 iPhone: zoom transition, nav bar minimize, swipe actions, empty states.
- [x] 4.9 Fonts to text styles across the remaining screens; `ContentUnavailableView`; placeholders.

## Log
- 2026-10-26: 1.1 and 1.2 deferred into 4.9 (tokens and system colors change screen by screen as each is rebuilt). Card restyled app-wide (sentence-case title, hairline border).
- 2026-10-26: Analytics cut-ins count only lines of 3+ words that outlast the other speaker; the coach's DeliveryStats keeps its older rule so its history stays comparable.
- 2026-10-26: `--ui-preview` windows open behind other windows (orderBack); `MOSSAD_SCROLL_TO` scrolls Analytics to a section heading for screenshots.
- 2026-10-26: Coach questions: open limit 10 (the first pass asks up to 10); the schema has 15 union types, under Claude's 16.
- 2026-10-26: `toolbarMinimizeBehavior` does not exist in the iOS 27 SDK; skipped. Swipe actions skipped; commitments keep their context menus.
- 2026-10-26: Fonts: the iPhone and SharedUI already use text styles; new Mac screens use text styles; older Mac screens keep fixed sizes (macOS does not scale them).
- 2026-10-26: `--background` starts the app with no window (quiet restart after an update); `--welcome` / `--welcome-inline` and `MOSSAD_PERSON` are preview hooks.
