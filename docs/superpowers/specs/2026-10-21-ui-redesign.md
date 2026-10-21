# Mossad UI Redesign: Implementation Spec

Date: 2026-10-21
Status: Draft for review
Source design: `Mossad.dc.html` (design canvas, every screen in light and dark), with screenshots `s01` to `s11`.
Scope: the app target (`App/`) plus the small `MossadCore` changes listed under Data gaps. Detection, capture, and the pipeline order do not change.

This spec is complete enough to build each screen without the design file. Where the design is inconsistent or wrong, the spec says so and picks one answer (marked **Decision**). Where the design shows something with no source data, see section 3.

---

## 1. Design tokens

Put all tokens in one file, `App/Theme.swift` (`enum Theme`), as `Color` and `CGFloat` constants. Prefer the native semantic color in the "Native" column. Use the hex value only where no semantic color fits.

### 1.1 Neutral colors

| Token | Light | Dark | Native |
| --- | --- | --- | --- |
| `bg` (window content) | `#f6f6f8` | `#1f1f23` | `Color(nsColor: .windowBackgroundColor)` |
| `surface` (cards, table) | `#ffffff` | `#2b2b30` | `Color(nsColor: .controlBackgroundColor)` |
| `surface2` (bordered buttons, popup buttons) | `#f2f2f5` | `#35353b` | native bordered button |
| `text` | `#1d1d1f` | `#f5f5f7` | `.primary` |
| `text2` | `#6e6e73` | `#a1a1a6` | `.secondary` |
| `text3` | `#9d9da3` | `#6e6e73` | `.tertiary` |
| `sep` | `rgba(0,0,0,.08)` | `rgba(255,255,255,.10)` | `Color(nsColor: .separatorColor)` |
| `field` (search fields, segmented track, chips, badges) | `rgba(0,0,0,.055)` | `rgba(255,255,255,.08)` | `.quaternary` fill (`Color.primary.opacity(0.055)` light / `0.08` dark) |
| `hover` (row hover and selected row) | `rgba(0,0,0,.06)` | `rgba(255,255,255,.09)` | `Color.primary.opacity(0.06)` / `0.09` |
| `glass` (panel, player, sheet, hover card) | `rgba(248,248,252,.78)` | `rgba(40,40,48,.72)` | material, see 1.7 |
| `glassBorder` (1 pt rim and top highlight) | `rgba(255,255,255,.75)` | `rgba(255,255,255,.14)` | material, see 1.7 |
| `sidebar` | `rgba(240,240,245,.85)` | `rgba(32,32,40,.78)` | system sidebar material |
| window shadow | `0 24 60 rgba(30,40,80,.22)` | `0 24 60 rgba(0,0,0,.55)` | system window shadow |

### 1.2 Accent

- Default accent: `#0a7aff` (system blue).
- The design offers 4 accent options: `#0a7aff` (blue), `#5e5ce6` (indigo), `#ff9500` (orange), `#34c759` (green).
- **Decision:** Use `Color.accentColor` everywhere the design says `accent`. Set the `AccentColor` asset to `#0a7aff`. Do not add an in-app accent picker. The system accent setting covers the other options. The tinted app icon also follows the system tint.
- Accent uses: primary buttons ("Name voices", "Save", "Set key"), timestamps in the transcript, the selected calendar event, the selected Voices row, the sidebar icons, the checked checkbox, "Open meeting" link.
- Text on accent: `#ffffff`. Secondary text on accent: `rgba(255,255,255,.8)`.

### 1.3 Status colors

| Use | Value | Native |
| --- | --- | --- |
| Recording, destructive text, now-line, today marker | `#ff3b30` | `.red` |
| Recording badge background | `rgba(255,59,48,.14)` | `.red.opacity(0.14)` |
| Listening dot | `#30d158`, ring `0 0 0 3px rgba(48,209,88,.2)` (panel only) | `.green` |
| Permission granted, switches on | `#34c759` | `.green` |
| Warning (permissions, consent, failed banner icon) | `#ff9500` | `.orange` |
| Warning background | `rgba(255,149,0,.14)`; consent box border `rgba(255,149,0,.35)` | `.orange.opacity(0.14)` |
| Failed badge | background `rgba(255,149,0,.16)`, text `#c76a00` light; use `#ff9f0a` text in dark (the design does not change it, and `#c76a00` is too dark on dark) | |
| "Set" key pill | background `rgba(52,199,89,.16)`, text `#1f8f3f` light / `#30d158` dark | |
| "Missing" key pill | background `rgba(255,59,48,.14)`, text `#ff3b30` | |
| Find match highlight | background `#ffd60a`, text `#1d1d1f`, radius 2, 1 pt horizontal pad (both themes) | `.yellow` |
| Unknown speaker / no data | `#8e8e93` | `.gray` |

Log level colors: INFO `#6e6e73`, ERROR `#ff3b30`, DEBUG `#8e8e93`.

### 1.4 Speaker and platform colors

Speaker palette, in order: owner (you) `#0a7aff`, then `#ff9500`, `#af52de`, `#34c759`, `#ff2d55`, then extend with `#30b0c7`, `#5e5ce6`, `#a2845e`.

- **Decision:** The owner is always `#0a7aff`. Other speakers take the next palette color in order of first appearance in that meeting (this is today's `SpeakerColors`, with the owner pinned first). The Voices table uses the same palette by row order, owner first.
- A speaker that is still unnamed (`Speaker A`) gets a palette color in the transcript, so lines stay distinct. Its header chip has a dashed `text3` border and the secondary text "unknown" (see 2.18).

Platform colors (a 12 pt or 14 pt rounded square before each meeting title, and the 3 pt left bar of calendar events):

| Platform | Color |
| --- | --- |
| Google Meet | `#00ac47` |
| Zoom | `#2d8cff` |
| Microsoft Teams | `#5b5fc7` |

Add `extension Platform { var color: Color }` in the app target, not in `MossadCore`.

### 1.5 Corner radii (pt)

| Element | Radius |
| --- | --- |
| Main window | 16 (system) |
| Menu bar panel outer / inner recording card | 22 / 15 |
| Sheet ("Who is speaking?") | 16 |
| Notification, drag helper | 18 |
| Player bar | 14 (12 in the compact component) |
| Calendar hover card | 14 |
| Cards (summary cards, Settings groups 11, Voices table 10, Log body 10) | 12 / 11 / 10 |
| Context menu, Pick menu | 12 |
| Meeting list row, panel step row | 9 / 11 |
| Sidebar item, panel row, search field, segmented track (large) | 8 |
| Small buttons, text fields, segmented track (small), calendar nav buttons, badges | 7 |
| Segmented thumb | 5 or 6 (track radius minus 2) |
| Week event / Day event / Month item | 7 / 9 / 5 |
| Platform square 12 pt / 14 pt | 3 / 4 |
| Chips, log level pills, count badge | capsule |
| Talk-time bar | 4; player track 3 |

### 1.6 Typography

All text is SF Pro (system font). Body size is 13 pt. Use `.monospacedDigit()` for every time, duration, and count. Use `.system(size:weight:)` where no text style matches.

| Use | Size / weight / tracking |
| --- | --- |
| Recording timer (live detail) | 40 / semibold / -1, monospaced digits |
| List-mode detail title | 24 / bold / -0.4 |
| Split-mode detail title | 20 / bold / -0.3 |
| Pane title ("Meetings", "Voices", "Log", "Settings") | 18 / bold / -0.3 |
| Sheet title | 16 / bold |
| Empty state title | 15 / semibold |
| Panel status title, panel timer | 14 / semibold; timer 14 / medium |
| Body, row titles (medium), summary text | 13 / regular or medium |
| Secondary lines, chips, talk time, search placeholder | 12 / regular |
| Group headers ("Today"), badges, segmented labels, section labels | 11 / semibold (badges medium) |
| Card headers ("SUMMARY") | 11 / semibold / +0.4, uppercase, `text3` |
| Calendar hour labels, week event meta | 10 / regular, `text3` |
| Log lines | SF Mono 11, line height 1.7 |
| Folder paths | SF Mono 10.5, `text3` |

Line height: summary text 1.55, transcript text 1.5, other multi-line text 1.4 to 1.45.

### 1.7 Spacing and materials

Spacing scale used in the design: 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40. Exact paddings are given per screen.

Materials ("Liquid Glass" in the design):

| Surface | Design | Native on macOS 26 | Fallback on macOS 15 |
| --- | --- | --- | --- |
| Menu bar panel | glass, blur 40, saturate 1.6, 1 pt rim, inset top highlight | system MenuBarExtra window glass (automatic) | system popover material (automatic) |
| Sidebar | translucent, blur 40 | `NavigationSplitView` sidebar (automatic) | same (automatic) |
| Player bar | glass, blur 30, rim, shadow `0 6 20 rgba(0,0,0,.08)` | `.glassEffect(.regular, in: .rect(cornerRadius: 14))` | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))` + 1 pt `glassBorder` stroke |
| Sheet | glass | system sheet (glass on 26) | system sheet |
| Calendar hover card, context menus | glass, shadow `0 14 40 rgba(0,0,0,.22)` | `.glassEffect` | `.regularMaterial` |
| Drag helper panel | glass | `NSGlassEffectView` | `NSVisualEffectView(.hudWindow)` |

Wrap the player, hover card, and drag helper treatment in one modifier, `.mossadGlass(cornerRadius:)`, so the availability check lives in one place (see 4.1).

### 1.8 Animations

| Name | Design | Native |
| --- | --- | --- |
| Pulse | 1.6 s, infinite. A red ring grows from 0 to 7 pt and fades from 50% to 0% opacity (peak at 70% of the cycle). Used on: recording dots, live calendar events, the Recording badge dot. | A `Circle` overlay that scales from 1 to `(d + 14) / d` and fades from 0.5 to 0, `.easeOut(duration: 1.6).repeatForever(autoreverses: false)`. |
| Spin | 1 s linear rotation of a ring with one transparent quarter. Used in: Transcribing badge (9 pt), panel processing row (14 pt), processing banner (13 pt). | `ProgressView().controlSize(.mini)` or `.small`. Do not draw a custom spinner. |
| Shimmer | 1.6 s, opacity 0.5 to 1 to 0.5, on the skeleton cards. | `PhaseAnimator([0.5, 1.0])` on opacity, or `.redacted(reason: .placeholder)` with an opacity animation. |

With Reduce Motion on: the pulse shows a static dot, and the shimmer holds at opacity 0.7. Spinners stay (system behavior).

---

## 2. Screens, in build order

Copy text in quotes is exact. `N`, `title`, and times are variables.

### 2.1 App icon

- Two layers: a neutral glass slab, and five raised waveform bars, 14 wide, radius 7, gap 9, heights 36, 72, 100, 56, 28 on a 160 canvas. Each bar has a soft shadow and a 1 pt top highlight.
- Light: slab gradient `#f7f9ff` to `#e9eef9`, bars gradient `#5aa7ff` to `#2f6fe4`.
- Dark: slab `#2a2a30` to `#1a1a20`, bars `#7ab6ff` to `#3d82f0`.
- Tinted: slab `#3a3a40` to `#232328`, bars take the system tint.
- A top-left radial highlight (white 45% to 0%) on the slab.
- Build it in Icon Composer as a `.icon` file with the two layers (see 4.9). Keep a flat `AppIcon` asset for macOS 15.

### 2.2 Menu bar icon

States: idle, recording. There is no processing or attention state in the bar. The panel shows those.

- Glyph: five vertical bars, 2.2 pt round-cap strokes, on an 18 x 18 grid. Bar x positions 2.5, 5.75, 9, 12.25, 15.5; bar spans y 7 to 11, 4.5 to 13.5, 2.5 to 15.5, 5.5 to 12.5, 7.5 to 10.5. It matches SF Symbol `waveform` in weight.
- Idle: the glyph as a template image (`isTemplate = true`). The system tints it for light, dark, and reduced-transparency menu bars.
- Recording: the same bars in `#ff3b30`, then a 5 pt gap, then the elapsed time `12:34` (13 pt, monospaced digits, `labelColor`). This is the only non-template state. Over one hour use `1:02:03`.
- Pressed (panel open): the system draws the highlight. Do nothing.
- **Constraint:** the label must stay one `Image`. Draw the recording state as one `NSImage` with a drawing handler, and update it from the existing 1 s `SecondsClock`. Do not use a `TimelineView`, an `HStack`, or a `Text` in the label (see 4.2).
- Change from today: the recording image now draws red bars instead of a red dot.
- Accessibility description: idle "Mossad", recording "Recording 12:34".

### 2.3 Menu bar panel

Container: `MenuBarExtra` with `.window` style. Content width 320. Outer padding 8, row gap 4. Rows sit 6 pt in from the panel edge with 8 pt inner padding.

Top section, one of:

**Idle**
- Padding 12 / 14 / 10. A 9 pt green dot (`#30d158`) with a 3 pt 20% green ring, 5 pt from the top.
- "Listening for calls" (14 semibold).
- "Zoom, Google Meet, and Microsoft Teams" (12, `text2`).

**Recording** (a card: `surface` background, radius 15, padding 14 / 14 / 12, gap 10, shadow `0 1 2 rgba(0,0,0,.06)`)
- Row: a 10 pt pulsing red dot, "Recording" (14 semibold), then right-aligned elapsed `12:34` (14 medium, red, monospaced).
- Title of the call (13 medium), for example "Q4 Demand Planning Review". Use `CallRecord.title`.
- "Google Meet · started 11:31 AM" (12, `text2`).
- Button "Skip and delete this call" (12 medium, red text, `field` background, radius 9, padding 5 x 11, left-aligned, not full width).
- Keep today's two-step confirm. The first click changes the label to "Click again to delete this recording". The second click skips.
- The elapsed time may use a `TimelineView` here. Only the menu bar label has the freeze problem.

Then, when they apply, these rows (each: radius 11, padding 9 x 8, gap 10):

**Processing** (`field` background)
- A 14 pt spinner.
- "Processing 1 call" or "Processing N calls" (13 medium).
- Below it, the step of the oldest call in progress (12, `text2`), for example "Identifying speakers". Step names are in 2.7.

**Permissions attention** (background `rgba(255,149,0,.14)`)
- A 16 pt orange circle with a white "!" (11 bold). Use `exclamationmark.circle.fill`.
- "1 permission needs attention" or "N permissions need attention" (13 medium).
- A chevron right (`text3`) at the trailing edge.
- Click: open Settings and close the panel.

The design shows the permissions row together with the recording card. Both can show at the same time.

Then:
- A separator (1 pt `sep`, inset 14, margin 4 vertical).
- Header "Recent" (11 semibold, `text3`, padding 2 / 14 / 0).
- Up to 3 recent calls that are not recording. Each row: a 14 pt platform square (radius 4), the title (13, one line, truncated), the time right-aligned (12, `text2`, monospaced). Today: "11:31 AM". Earlier: "Oct 9". Click opens the meeting.
- A separator.
- "Meetings" (`bubble.left.and.text.bubble.right`).
- "Name voices" (`person.wave.2`), only when calls need names. A count badge at the trailing edge: min width 18, height 18, capsule, `text` background, `bg` foreground, 11 semibold. Click opens the naming sheet for the first call.
- "Voices" (`person.2`), "Settings" (`gearshape`), "Log" (`doc.text`). Icons 16 pt in `text2`, gap 10.
- A separator.
- "Quit Mossad" with "⌘Q" right-aligned (12, `text3`).

Row hover: `hover` gray background, radius 8. **Decision:** follow the design, and do not use today's accent fill with white text. Every navigation row closes the panel.

Light and dark differ only by tokens.

### 2.4 Main window shell

- Design size 1240 x 940 (split) and 1240 x 720 (other modes). Min size 980 x 600. Default 1240 x 820. Keep the frame autosave name `MossadMain`.
- Full-height sidebar with the traffic lights inside it. Use a transparent title bar with the title hidden and a unified toolbar (see 4.4).
- Sidebar: width 200 (fixed range 180 to 240). Padding 14 / 10. 18 pt clear space under the traffic lights.
- Sidebar items, gap 2: "Meetings", "Voices", "Settings", "Log". Each item: padding 6 x 10, radius 8, gap 9, 16 pt icon in accent. The selected item has a `hover` background and medium weight. Use a native `List` with sidebar style. The system selection look is acceptable.
- Sidebar icons change: Meetings `bubble.left.and.text.bubble.right` (today `text.bubble`), Voices `person.2` (today `person.wave.2`), Settings `gearshape`, Log `doc.text` (today `doc.plaintext`). Update `AppController.Section.symbol`.

**Sidebar footer status** (pinned to the bottom, padding 8 x 10, gap 8, 12 pt, `text2`). Use `.safeAreaInset(edge: .bottom)` on the sidebar list.
- Idle: an 8 pt green dot, "Listening for calls". (This is the only footer state the design shows.)
- Recording: an 8 pt pulsing red dot, "Recording 12:34". (Extrapolated.)
- Processing: a mini spinner, "Processing 1 call". (Extrapolated.)
- Permissions: an 8 pt orange dot, "2 permissions need attention". Click opens Settings. (Extrapolated.)
- Priority when more than one applies: Recording, then Permissions, then Processing, then Idle.

### 2.5 Meetings: toolbar and modes

There are three modes: Split (default), List, and Calendar. Store the mode in `@AppStorage("meetingsMode")`.

Toolbar content, left to right:
- The pane title "Meetings" (18 bold). See 4.4 for where it lives.
- A segmented control with 3 options: Split (`sidebar.left`), List (`list.bullet`), Calendar (`calendar`).
  - In Split mode, the control sits in the list column header and shows icons only. Each segment is 24 x 20, the track radius is 7, and the thumb is `surface` with a shadow `0 1 2 rgba(0,0,0,.12)`.
  - In List and Calendar modes, each segment shows its icon and label ("Split", "List", "Calendar"). Labels are 12 medium, padding 4 x 12, gap 6, track radius 8.
- Calendar mode only: the navigation controls. These are "‹" (26 x 26, radius 7, `field`), "Today" (height 26, padding 0 x 10, 12 medium), and "›". Then the period title (13 semibold): "October 2026" (Week and Month), "Wednesday, October 21" (Day). Then the scope popup "Week ▾" (height 26, padding 0 x 10, `surface2` with a 1 pt `sep` border, 12 medium), with the options Day, Week, and Month.
- The search field, right-aligned, 240 wide, 28 high, radius 8, placeholder "Search titles and transcripts". In Split mode it is full width under the title in the list column. ⌘F focuses it.

Search behavior:
- The search matches titles and transcript text, case-insensitive (as today).
- In Split and List modes, the list shows only the matches. Groups with no matches are hidden.
- In Calendar mode (extrapolated), events that do not match show at 30% opacity.
- In the Transcript tab of an open meeting, the transcript find field starts with the search term.

### 2.6 Meetings list (Split mode)

Split layout: the list column is 330 wide (min 280, max 420), with a 1 pt `sep` right border. The detail column fills the rest.

List column:
- Header padding 12 / 12 / 8, gap 10. Row 1: "Meetings" and the icon segmented control. Row 2: the search field.
- The list scrolls with padding 0 / 8 / 8 and a row gap of 2.

Groups (11 semibold, `text3`, padding 10 / 8 / 4), in this order:
- "Today": the start is today.
- "Yesterday".
- "This week": the same calendar week as today (use `Calendar.current`), before yesterday.
- "Earlier": everything older.
- Hide empty groups. Sort newest first inside each group.

Row (padding 8, radius 9, gap 4):
- Line 1: a 12 pt platform square (radius 3), the title (13 medium, one line, truncated), and the length right-aligned (12, `text2`, monospaced).
- Line 2, indented 20: the "when" text (12, `text2`), then the status badge right-aligned.
- "When" format: Today and Yesterday show the time ("11:31 AM"). This week shows the weekday and time ("Mon 9:00 AM"). Earlier shows "Oct 9", plus the year when it is not the current year.
- Length format: "59 min" (at least "1 min"). A live call shows the elapsed time "12:34" and ticks every second.
- Selected row: `hover` background. Hover: `hover` background.

Status badges (padding 2 x 8, radius 7, 11 medium, gap 5):

| Badge | When | Look |
| --- | --- | --- |
| "Recording" | `status == .recording` | `rgba(255,59,48,.14)` background, red text, a 6 pt pulsing dot |
| "Transcribing" | `status` is `.recorded`, `.transcribed`, `.identified`, or `.summarized` | `field` background, `text2`, a 9 pt spinner |
| "Failed" | `status == .failed` | orange background and text (1.3) |
| "Needs names" | `status == .written` and `unknownSpeakers` is not empty | `field` background, `text`, an 11 pt `person.fill.questionmark` |
| none | other written calls | |

**Decision:** "Transcribing" is the one badge word for every processing step, as in the design. The detail banner gives the exact step.

Right-click menu: see 2.16.

Keyboard: Up and Down move the selection. Delete opens the delete confirmation (keep today's dialog).

### 2.7 Meeting detail (shared by Split and List modes)

Layout from the top: header, optional banner, player, tabs, content. In Split mode the detail uses the full column width. In List mode the content is centered with a max width of 900 and padding 20 / 32 (see 2.8).

**Header** (Split: padding 18 / 24 / 14, gap 10, 1 pt `sep` bottom border)
- The title (20 bold, -0.3), selectable.
- The subtitle (13, `text2`): "Today · 11:31 AM – 12:30 PM · 59 min · Google Meet".
  - The date word is "Today", "Yesterday", the weekday ("Mon") within the last 6 days, or else "Oct 9" ("Oct 9, 2025" in a past year).
  - Format the time range with the system interval formatter, so a shared AM/PM collapses ("9:00 – 9:32 AM").
  - The design writes "11:31 – 12:30 AM", which is wrong. Do not copy it.
  - A live call shows "Today · started 11:27 AM · Google Meet".
- Trailing buttons, gap 8:
  - "Name voices": accent fill, white, 13 medium, padding 5 x 11, radius 8, a 13 pt `person.wave.2` icon. Show it only when the call is written and has unknown speakers. It opens the sheet (2.11).
  - "More": a 28 pt circle, `field` background, `ellipsis`. It opens the same menu as the right-click menu (2.16).
- Speaker chips (wrap, gap 6): a capsule, `field` background, padding 3 / 10 / 3 / 7, gap 6, 12 pt. Each chip has an 8 pt color dot, the name (medium), and the email (`text2`).
  - The owner chip reads "Jordan Lee (you)" with no email.
  - When there is no email, the chip shows the name only (see 3).
  - An unnamed speaker shows "Speaker A" and "unknown", with a dashed 1 pt `text3` border.
  - Order: by first appearance in the transcript.

**Banner** (margin 12 / 16 / 0, padding 9 x 12, radius 11, gap 9, 13 medium), shown when the call is not written:
- Processing: `field` background, a 13 pt spinner, and the text "STEP, step N of 6". **Decision:** use a comma, not the design's dash. For example, "Identifying speakers, step 3 of 6".

  | `status` | Step text | N |
  | --- | --- | --- |
  | `.recorded` | "Transcribing" | 2 |
  | `.transcribed` | "Identifying speakers" | 3 |
  | `.identified` | "Writing the summary" | 4 |
  | `.summarized` | "Writing the note" | 5 |

  When `attempts > 0`, append the retry time: "Transcribing, step 2 of 6. Attempt 2 failed; Mossad retries at 3:15 PM." Use `nextAttempt`.
- Failed: background `rgba(255,149,0,.16)`, a 15 pt orange "!" circle, and the failure reason. For example, "Transcription failed: AssemblyAI key missing". See the data gap for the reason text. A "Retry now" button sits at the trailing edge (`surface` background, shadow `0 1 2 rgba(0,0,0,.15)`, radius 7, padding 4 x 10). It calls `controller.retry`.

**Player** (margin 12 / 16 / 0, padding 10 x 14, radius 14, glass, gap 12). It sticks to the top when the content scrolls.
- Controls, gap 4:
  - Back 15 s: a 30 pt circle, `gobackward.15`, `hover` background on hover.
  - Play/Pause: a 36 pt circle, `text` fill, `bg`-colored `play.fill` or `pause.fill` (14 pt). Space toggles it.
  - Forward 15 s: a 30 pt circle, `goforward.15`.
- Current time (12, `text2`, monospaced, width 36, right-aligned).
- Scrubber column (flex, gap 5):
  - Track: 6 high, radius 3, `field`. Played part: `text` at 85% opacity. Thumb: a 14 pt white circle with shadow `0 1 4 rgba(0,0,0,.35)`, centered on the position.
  - Speaker timeline below the track: 5 high, radius 3, segments with a 1 pt gap. Each segment is one run of the same speaker, with width proportional to its duration and the speaker's color. Gaps with no speech use `field`. Click or drag on the track or the timeline to seek.
- Total time (12, `text2`, monospaced, width 36).
- Speed: a small segmented control with "1×", "1.25×", "1.5×", "2×" (11 medium, track radius 7, segment padding 3 x 7). It binds to `player.rate`.
- Disabled look (the audio is not loaded or is missing): 45% opacity, no thumb, times "0:00" and "--:--" (or the known length), and the timeline is one gray `#8e8e93` segment.

**Tabs:** a centered segmented control, "Summary" and "Transcript" (12 medium, padding 4 x 18, track radius 8), with padding 14 / 0 / 6. On the Transcript tab, the control moves to the left, and the find field and the Follow switch sit on the same row (2.10).

**Detail states** (from 04b):

| State | Condition | Header | Banner | Player | Tabs | Content |
| --- | --- | --- | --- | --- | --- | --- |
| Written | `.written` | full, chips, Name voices when needed | none | enabled | yes | Summary or Transcript |
| Live recording | `.recording` | live subtitle, no chips, More only | none | hidden | hidden | the live panel (below) |
| Processing | `.recorded` to `.summarized` | no chips | processing | enabled when `AudioPlayer.isAvailable`, else disabled | yes | skeleton (below) |
| Failed | `.failed` | no chips | failed + Retry now | enabled when the audio loads | yes | empty: "No transcript yet" / reason-specific text (below) |
| No speech | `.written` and `utterances` is empty | no chips | none | enabled | yes | empty: "No speech detected" / "The call was recorded, but nobody spoke." |
| No audio | `.written` and the audio does not load | full | none | disabled, total = call length | yes | normal Summary or Transcript |

Notes on these states:
- **Decision (Processing):** the design dims the player while processing. Today's `AudioPlayer` already plays the raw tracks, so enable the player whenever audio loads.
- **Decision (No speech):** the design adds "No note was written." The pipeline does write a note for an empty call today (`Pipeline.swift`, the write step runs with no utterances). Drop that sentence unless the pipeline changes.
- **Decision (No audio):** the design replaces the tab content with "No audio available". That hides a transcript that still exists. Instead, keep the tabs working, and show this line inside the disabled player area (12, `text2`):
  - With retention on and the call older than the retention period: "No audio available. The recording was deleted after 30 days." Use the actual `recordingDays` value.
  - Otherwise: "No audio available."

Failed empty-state text (centered, an icon in `text3`, the title 15 semibold, the body 13 `text2` with max width 380 and line height 1.45):
- Missing key: "No transcript yet" / "The audio is saved. Add the AssemblyAI key in Settings, then retry."
- Interrupted: "No transcript yet" / "The recording was interrupted, and a track could not be read. Check the log, then retry."
- Gave up: "No transcript yet" / "Mossad gave up after N attempts. Check the log, then retry."

**Live panel** (centered, gap 14):
- 8 red bars, 6 wide, radius 3, gap 5, bottom-aligned in a 64 pt box. Heights: 20, 44, 64, 34, 52, 24, 40, 16. They are static. An optional gentle height animation is allowed, but it must stop with Reduce Motion.
- A 10 pt pulsing red dot and the elapsed time (40 semibold, -1 tracking, monospaced).
- "Recording your microphone and the call audio. The transcript and summary appear after the call ends." (13, `text2`)
- The button "Skip and delete this call" (`field` background, red 13 medium, padding 6 x 14, radius 8, top margin 8). It has the same two-step confirm as the panel.

**Skeleton** (processing): the Summary grid layout with placeholder bars in `field`.
- Full-width card: a 9 high x 60 header bar, then 4 lines 10 high at widths 96%, 88%, 92%, 60%.
- Two half cards: a header bar 80 or 70 wide, then 3 lines.
- Gap 10. The shimmer animation runs on the grid.

### 2.8 List mode

- The list takes the full pane. Header: padding 14 / 24 / 10, gap 14, 1 pt `sep` bottom border. It holds the title, the labeled segmented control, and the search field on the right.
- Groups: the same as in Split mode. Header padding 14 / 8 / 6.
- Row grid (padding 9 x 8, radius 9, column gap 14), with columns:
  - 20: the platform square, 12 pt.
  - flex: the title, 13 medium.
  - 150: the badge.
  - 90: "when", 12 `text2`.
  - 70: the length, 12 `text2`, right-aligned.
- Click or Return opens the meeting in the same pane. The header then becomes:
  - Back: 26 x 26, radius 7, `field`, `chevron.left`. Escape and ⌘[ also go back.
  - Breadcrumbs (13, `text2`, `chevron.right` separators at 10 pt in `text3`): "Meetings › Today › Q4 Demand Planning Review". The last part is `text` medium. The middle part is the group name. Clicking "Meetings" or the group name goes back to the list.
  - Right: "Name voices" and "More", the same as in 2.7.
- The opened detail: centered, max width 900, padding 20 / 32 / 0, gap 10.
  - The title is 24 bold, -0.4.
  - Then the subtitle, the chips, and the player (top margin 8, the same component).
  - Then the tabs (padding 10 / 0 / 4).
  - Summary grid: columns 1.4fr and 1fr. The Summary card is on the left. The Action items card is on the right. Talk time, Invited, and Decisions go in a second row of the same grid (extrapolated: the mock cuts off).
- Back restores the list scroll position and the selection.

### 2.9 Calendar mode

Shared rules:
- The scope is Day, Week, or Month. Store it in `@AppStorage("calendarScope")`, default Week.
- "Today" jumps to the current period. "‹" and "›" move by one period.
- Click an event or a month item to open the meeting. It opens in List-mode style (full pane, breadcrumbs, back returns to the calendar). The middle breadcrumb is the period title.
- Only recorded calls appear. Calendar invites that were not recorded do not appear.
- **Decision:** the first weekday follows `Calendar.current.firstWeekday` in both Week and Month. The mock starts the week on Monday and the month on Sunday.

**Week**
- Day header row: a 52 gutter, then 7 columns, each with a 1 pt `sep` left border and padding 8 / 0 / 8 / 8.
  - The weekday label "MON" is 11 semibold `text3`.
  - The date number sits in a 22 pt circle, 12 semibold.
  - Today: the label is red, and the number circle is red with white text.
- Hour grid:
  - 60 pt per hour. Hour lines are 1 pt `sep`. Each column has a 1 pt `sep` left border.
  - Hour labels ("8 AM") are 10 pt `text3`, right-aligned with 8 pt padding, shifted up 6 pt to sit on the line.
  - The grid covers 24 hours, scrolls vertically, and opens scrolled to 1 hour before the earliest event of the week, or 8 AM.
- Event block (absolute position, inset 3 left and right, radius 7, padding 4 x 7, gap 1):
  - Top = minutes since the start of the grid. Height = duration in minutes, min 18.
  - Background `surface`, shadow `0 1 3 rgba(0,0,0,.12)`, and a 3 pt left border in the platform color.
  - Title: 11 semibold, line height 1.2. Meta: 10 `text2`, "32 min · Failed" (the length, then the badge word when there is one).
  - A live call shows the meta "Recording" with a 6 pt pulsing red dot. Its height grows with the elapsed time (update every 30 s).
  - The selected or hovered event: accent background, white title, `rgba(255,255,255,.8)` meta, shadow `0 6 16 rgba(0,0,0,.2)`.
  - Overlapping events split the column width (see 4.5).
- Now-line: on today's column only. A 1.5 pt red line with an 8 pt red dot at the left edge. Its position updates every minute.
- Right padding 12 for the scroll bar.

**Hover card** (Week and Day)
- Shows after the pointer rests 0.5 s on an event. It hides when the pointer leaves both the event and the card.
- Size: 290 wide, glass, radius 14, padding 12 x 14, gap 8, 12 pt text. It sits beside the event and stays inside the pane.
- Content, in order:
  - The title (13 semibold).
  - "11:31 AM – 12:30 PM · 59 min · Google Meet" (`text2`).
  - Speaker chips with the name only: 11 pt, padding 2 / 8 / 2 / 6, a 7 pt dot.
  - A one-sentence snippet (13, `text`, line height 1.45). See the data gap.
  - A footer: the status badge, if any, and "Open meeting" (accent, medium) at the trailing edge.
- Clicking the card or "Open meeting" opens the meeting.

**Day**
- Header (padding 8 / 0 / 8 / 10):
  - "WED" (11 semibold red when today).
  - The number in a 24 pt circle (13 semibold; red with white text when today).
  - "3 calls · 1h 22m recorded" (12, `text2`, 6 pt left margin). Use "1 call" for one call. "Recorded" is the sum of the call lengths.
- The hour grid is as in Week, with one column. Events are inset 6, radius 9, padding 7 x 12, gap 16, in a horizontal layout:
  - Left: the title (13 semibold, line height 1.2) and "10:58 – 11:20 AM · Zoom · Transcribing" (12, `text2`).
  - Right: speaker chips (name only, 11 pt), only when the block is at least 44 pt tall. On an accent background, the chips use `rgba(255,255,255,.22)`.
  - A live event shows "11:27 AM –" with a pulsing dot.
- The now-line is as in Week.

**Month**
- Weekday header: 7 columns, labels "SUN" to "SAT" (11 semibold, `text3`, centered, padding 8 / 0 / 6). Rotate the labels to the first weekday.
- Grid: 7 columns x 5 or 6 rows, as needed. Each cell has 1 pt `sep` right and bottom borders, padding 6, gap 3.
  - Cells outside the month have a `field` background and a `text3` number.
- Day number: centered, min 22 x 22, capsule, 12 medium. The first of the month reads "Oct 1". Today is a red circle with white text.
- Up to 3 item rows per cell (padding 2 x 5, radius 5, 11 pt, gap 5, `hover` on hover):
  - A 7 pt dot in the platform color, filled when the note is written. When processing or failed, it is a 1.5 pt ring with no fill.
  - The time (`text2`, monospaced): "10am", "2:30pm" (hour only when on the hour).
  - The title (medium, truncated).
  - A live call adds a 6 pt pulsing red dot at the trailing edge.
  - The selected item has an accent background, white text, and a white filled dot.
- More than 3 calls: show 3, then "+N more" (11 semibold, `text2`). Clicking it switches to Day scope for that date.
- Clicking an empty part of a cell does nothing.

### 2.10 Meeting detail: Summary tab and Transcript tab

**Summary tab, Split mode:** a two-column grid, gap 12, padding 6 / 24 / 24. It scrolls.
- Row 1: the Summary card, full width.
- Row 2 left: the Action items card.
- Row 2 right: a stack (gap 12) with Talk time, Invited, and Decisions.

Card: padding 14 x 16, radius 12, `surface`, shadow `0 1 2 rgba(0,0,0,.05)`, gap 8. The header is 11 semibold uppercase with +0.4 tracking, `text3`. Card titles: "Summary", "Action items", "Talk time", "Invited", "Decisions". Hide a card that has no data. Keep "None." for Action items only when the summary exists.

**Summary card**
- Rendered Markdown, max width 680, line height 1.55, block gap 10:
  - Paragraphs.
  - `###` headings: 13 semibold, 6 pt above, the block gap minus 4 below.
  - `**bold**`.
  - `-` bullet lists: 18 pt indent, item gap 3.
- See the data gap and 4.6. The text can be selected.

**Action items card**
- Rows (gap 9, line height 1.4). Each row has a 15 pt circle (1.5 pt `text3` stroke, 2 pt top offset), then the owner's first name (semibold, the owner's speaker color), then the task.
- When the owner has no speaker color (for example "Unassigned"), the owner name uses `text2`.
- **Decision:** phase 1 shows the circle as a static marker. Phase 6 makes it a checkbox: the circle fills with accent and shows a white checkmark, and the task gets a strikethrough in `text2`. That state is saved (see Data gaps).

**Talk time card**
- Rows (gap 8, 12 pt, gap 10): the first name (width 72, medium), a bar (8 high, radius 4, `field` track, the fill in the speaker color, width = share of the longest talker), and "24 min" (width 42, right-aligned, `text2`, monospaced).
- Under 1 minute shows "<1 min".

**Invited card**
- Rows (12 pt), spaced to both edges: the name (medium) on the left, the email (`text2`) on the right.
- Fallback: when only one value exists, show it on the left in medium weight, with nothing on the right.

**Decisions card**
- Rows (gap 8, line height 1.4): a 4 pt `text2` dot (7 pt top offset), then the text.

**Summary tab, List mode:** the same cards in a 1.4fr / 1fr grid (2.8).

**No summary:** when `summary == nil` and the call is written:
- With no Anthropic key: "No summary for this meeting. Add the Anthropic key in Settings." plus the button "Retry summary".
- Otherwise: "No summary for this meeting."

**Transcript tab**
- Toolbar row (padding 14 / 24 / 6, gap 10):
  - The tab control on the left.
  - The find field on the right: 240 x 26, radius 7, `field`, 12 pt. It holds a magnifier icon, the term, the count "2 of 4" (`text2`, monospaced), and up and down chevron buttons.
  - "Follow playback" (12, `text2`) with a mini switch (green when on). The switch shows only when audio is available.
- Body (padding 6 / 24 / 24, block gap 12). The text can be selected.
  - Block header (when the speaker changes, or after a gap of more than 30 s, as `TranscriptBlock` does): a 7 pt dot and the name (12 semibold, the speaker color), with 6 pt top margin.
  - Line: padding 5 x 10, pulled out by -10 so the text aligns with the header, radius 8, gap 10.
    - Timestamp: 11 pt, accent, monospaced, width 36, 2 pt top padding, format "18:42" or "1:02:03". Click it to play from that time.
    - Text: 13, line height 1.5.
  - The current line (the playing line, when playing or paused after a start): `field` background.
  - Find matches: yellow highlight (1.3) on every match, in place.
- **Change from today:** find no longer filters lines. It highlights every match and shows "N of M".
  - Return or ⌘G goes to the next match. Shift-Return or ⇧⌘G goes to the previous match. The view scrolls the active match to the center.
  - With no matches, the count reads "0 of 0" in `text3`.
- Follow playback on: while playing, the view scrolls the current line to the center. When the user scrolls by hand, Follow turns off.
- No transcript: show the empty state from 2.7.

### 2.11 "Who is speaking?" sheet

This is a sheet on the main window. Width 560, padding 20 / 20 / 16, gap 14, radius 16, glass.
- The title "Who is speaking?" (16 bold).
- The subtitle (13, `text2`): "2 voices in Q4 Demand Planning Review are new. Name them once and Mossad recognizes them in future calls." Use "1 voice in TITLE is new." for one voice.
- One card per unknown speaker (`surface`, radius 12, padding 12 x 14, gap 10, shadow `0 1 2 rgba(0,0,0,.06)`):
  - Row: a 28 pt circle in the speaker's color with a white `play.fill` glyph. Click plays the sample (the existing `ClipExtractor` clip). Click again stops it.
  - Beside the circle: the meta line "Speaker A · 21 min · sample 0:05" (12, `text2`). Use the existing lettered label, not the design's "Speaker 2". The talk time is from `talkTime`. The sample length is the real clip length.
  - The quote below, italic, in curly quotes, line height 1.45: the longest utterance of that speaker (as today).
  - Input row (gap 8): a name text field (flex, 28 high, radius 7, placeholder "Name"), and a "Pick ▾" popup button (28 high, padding 0 x 10, `surface2`, 1 pt `sep` border).
  - The Pick menu has 2 sections, with a separator between them:
    - "Invited to this meeting": the attendees, minus names already used.
    - "Known voices": the library names, minus the attendees.
    - Each item shows the name with the email as the second text. Picking an item fills the field.
- Footer, right-aligned, gap 8: "Later" (bordered) and "Save" (accent, default action).
  - Save is disabled until at least one name is filled.
  - Save calls `applyNames` and closes the sheet. Later closes the sheet.

### 2.12 Notification

- One notification per call, only when voices need names (as today).
- The system draws it: the app icon, "Mossad", and "now" are automatic.
- Content:
  - `title`: "2 new voices in Q4 Demand Planning Review". Use "1 new voice in ..." for one voice.
  - `body`: "Click to name them".
- Change from today: today the title is "Mossad" and the count is in the body.
- Click opens the main window on that meeting with the sheet open (existing `openNaming`).

### 2.13 Voices

The pane has padding 16 / 20 / 10 in the header and 20 on the sides.
- Header: "Voices" (18 bold, flex). Then 3 small bordered buttons (12 medium, padding 4 x 10, radius 7):
  - "Rename". It opens a sheet with a name field.
  - "Merge". It is a pull-down menu, "Merge into ▸", that lists the other names.
  - "Delete". Red text. It opens the existing confirmation.
  - All 3 act on the selected row and are disabled with no selection. "Delete" and "Merge" are also disabled for the owner row.
- A table (`surface`, radius 10, 1 pt `sep` border). The header is 11 semibold `text3`. Rows have padding 7 x 12. Columns at 1.4 / 1.6 / 0.7 / 1 ratios:
  - "Name": an 8 pt color dot and the name, medium. The owner shows "Jordan Lee (you)".
  - "Email": 75% opacity. Empty when unknown (see Data gaps). **Decision:** hide this column until any profile has an email.
  - "Meetings": a count, monospaced.
  - "Last heard": 75% opacity. "Today", "Yesterday", or "Oct 14".
  - The selected row: accent background, white text.
- Footer, pinned to the bottom (padding 14 / 20 / 16, gap 10, 12 pt, `text2`, line height 1.45):
  - A `lock` icon.
  - "Voice fingerprints are biometric data. They stay on this Mac in the Voices folder and are never uploaded."
  - A red link "Delete all saved voices". It opens the existing confirmation dialog.
- Empty state: keep today's text: "No voices yet" / "Your voice is learned in your first call. Name other voices after a call."
- Double-click a row to rename it.

### 2.14 Log

- Header (padding 16 / 20 / 10, gap 8):
  - "Log" (18 bold, flex).
  - Level pills "Info", "Error", "Debug": capsule, padding 3 x 9, 11 semibold. On: `text` background with `bg` text. Off: `field` background with `text2` text. Defaults: Info and Error on, Debug off. They toggle independently.
  - A filter field: 150 x 26, radius 7, placeholder "Filter".
  - "Copy": bordered. It copies the visible lines as plain text.
- Body (margin 0 / 20 / 20, `surface`, radius 10, 1 pt `sep` border, padding 10 x 12, SF Mono 11, line height 1.7). The text can be selected.
  - Each line shows the time "11:31:02" (`text3`, local time from the ISO timestamp), the level (width 40, semibold, the level color), and the message (`text`).
- Data:
  - Parse the last 500 lines of `mossad.log`. The line format is `ISO8601 LEVEL message`.
  - A line that does not parse shows as a message with no time and no level.
  - Reload when the pane appears and every 2 s while it is visible. Drop the "Refresh" button.
  - Open scrolled to the bottom. Stay pinned to the bottom unless the user scrolled up.

### 2.15 Settings and drag helper

The pane is 720 wide in the design. Scroll it. Padding 8 / 24 / 24, section gap 18. Title "Settings" (18 bold, padding 16 / 24 / 8).

Group style: a label (11 semibold uppercase, +0.4 tracking, `text3`, 4 pt left padding, gap 6), then a box (`surface`, radius 11, 1 pt `sep` border). Rows inside the box are separated by 1 pt `sep`, with padding 8 x 12 (Permissions rows: 9 x 12), at 12 pt.

**1. Permissions** (full width). One row per item:
- A 16 pt status circle: green `checkmark.circle.fill` or red `xmark.circle.fill`.
- The name (13 medium) and the reason (12, `text2`).
- A fix button when the item is red (12 medium, bordered, padding 3 x 10).
- Clicking a red row also runs the fix (as today).

| Name | Reason | Fix label |
| --- | --- | --- |
| "Microphone" | "Records your side of the call" | "Allow…" when not asked, else "Open Settings" |
| "System audio recording" | "Needed to hear the other people on the call" | "Open Settings" |
| "Accessibility" | "Reads the window title to detect a call" | "Open Settings" |
| "Calendars" | "Matches calls to invites by meeting link" | "Allow…" / "Open Settings" |
| "Notifications" | "Tells you when voices need names" | "Allow…" / "Open Settings" |
| "Automation · Safari" (one row per installed browser) | "Reads the meeting link from the tab" | "Open browser" when the browser is not running, else "Allow…" / "Open Settings" |

These names and reasons replace today's strings in `PermissionsMonitor.baseItems`.

**2. Consent box** (full width)
- Background `rgba(255,149,0,.14)`, a 1 pt `rgba(255,149,0,.35)` border, radius 11, padding 12 x 14, gap 10. A 16 pt orange "!" circle.
- Text, line height 1.45: "**Recording consent.** Mossad does not announce itself on calls. Tell the people you meet with that the call is recorded. Some places require the consent of every person on the call."
- **Decision:** this shorter text replaces today's longer paragraph. Add " This is not legal advice." at the end, to keep the old disclaimer.

**3. Two-column grid** (gap 18):

"You and voices":
- "Your name": a text field, 140 wide, 24 high.
- "Company" with "optional" in `text3`: a text field, placeholder "Example Inc.".
- "Recognize voices": a mini switch.
- "Delete all saved voices…": red, medium. It opens the confirmation.
- The long footer text from today moves to a `.help` tooltip on "Recognize voices". The Voices footer already says the biometric line.

"Recording":
- "Open Mossad at login": a mini switch.
- A checkbox, "Delete recordings after a period of time".
- When the checkbox is on: "Keep audio for", then a number field (44 wide) with a stepper, then "days" (`text2`, indented 22). The range is 1 to 3650. Bind it to `recordingDays`.
- A hint (11, `text3`, indented 22): "Notes and transcripts are always kept. A recording uses about 14 MB an hour."

"Folders": 3 rows. Each row has a `folder` icon, the name (medium), the path (SF Mono 10.5, `text3`), and "Open" (`text3`, a link button).
- "Meetings": `~/Mossad/Meetings`
- "Audio": `~/Mossad/Audio`
- "Voices": `~/Mossad/Voices`
- Use the real `Paths` values, abbreviated with `~`. The paths in the design are wrong.

"API keys": 2 rows. Each row has the name (medium), a description (`text2`), a status pill (padding 2 x 8, radius 6, 11 semibold), and a button.
- "AssemblyAI", "Transcription and speaker turns".
- "Anthropic", "Summary and action items with Claude".
- Status "Set" (green pill) with the button "Change" (bordered). Status "Missing" (red pill) with the button "Set key" (accent).
- The button opens a sheet with a `SecureField` and the buttons Cancel and Save. Save writes the key to the Keychain and rebuilds the pipeline. Never echo or log the key.
- Keep a one-line hint under the box: "Keys are stored in the Keychain."

Keep today's behaviors: refresh permissions every 1 s while the pane is visible, and rebuild the pipeline when the pane closes.

**Drag helper** (a floating panel, restyled)
- 300 wide, glass, radius 18, padding 16, gap 12, centered text. It is a vertical layout. Today it is a horizontal 340 x 84 layout.
- The 72 pt app icon (radius 17, shadow `0 8 20 rgba(42,70,160,.25)`). It is draggable (the existing drag source).
- "Drag Mossad into the list" (13 semibold).
- "Drop the icon into System Settings › Privacy & Security › PANE, then turn it on." (12, `text2`, line height 1.45). PANE is the pane name for the permission, for example "Screen & System Audio Recording" or "Accessibility".
- An `arrow.down` glyph in `text3`.
- Keep the existing behavior: it floats beside System Settings, follows its window, and closes when the permission turns green.

### 2.16 Right-click menu (and the "More" menu)

A native context menu on list rows, calendar events, and month items:
- "Open note" (`doc.richtext`). Disabled when there is no `markdownPath`.
- "Show note in Finder" (`folder`). Disabled when there is no `markdownPath`.
- "Show audio in Finder" (`folder`).
- A separator.
- "Delete…" (`trash`, destructive). Disabled while the call is recording or processing (`canDelete`).

The header "More" menu uses the same items. A live call's More menu has only "Skip and delete this call" (`xmark.bin`, destructive).

### 2.17 Empty state

This is the list column (or the full pane in List and Calendar modes) when there are no meetings:
- The header and search field stay.
- Centered, gap 8, side padding 36:
  - A 5-bar waveform in `text3`: bars 3 wide, radius 2, gap 3, heights 10, 20, 28, 16, 8.
  - "No meetings yet" (13 semibold).
  - "Mossad records Zoom, Meet, and Teams calls on its own." (12, `text2`, line height 1.45).
- Use `ContentUnavailableView` with a custom label view.
- No selection in the detail column: keep "Select a meeting" (`ContentUnavailableView`).
- A search with no results: `ContentUnavailableView.search(text:)`.

### 2.18 Component sheet: shared components to build

Build these as reusable views in `App/Components/`:
1. `SpeakerChip(name:, email:, color:, unknown:)`. It has a full form (name and email) and a compact form (name only, 11 pt, a 7 pt dot). When `unknown` is true, it has a dashed border and the text "unknown".
2. `StatusBadge(kind:)` with Recording, Transcribing, Failed, and Needs names (2.6).
3. `PlayerBar(player:, segments:, compact:)`. The compact form: padding 8 x 12, radius 12, a 30 pt play button, no ±15 buttons, 11 pt times, a 5 high track, a 4 high timeline, speeds "1×" and "1.5×" only.
4. `TranscriptLine(time:, text:, isCurrent:, matches:)` with 3 looks: default, playing (`field` background), and with a find match.
5. `PermissionRow(item:)` (2.15).
6. `PulsingDot(size:)` and `PlatformSquare(platform:, size:)`.
7. `Card(title:) { content }` (2.10).

### 2.19 SF Symbols

| Use | Symbol |
| --- | --- |
| Meetings | `bubble.left.and.text.bubble.right` |
| View: Split / List / Calendar | `sidebar.left` / `list.bullet` / `calendar` |
| Calendar scope Day / Week / Month (popup items) | `calendar.day.timeline.left` / `calendar` / `calendar.badge.clock` (as in the design; `square.grid.3x3` reads better for Month, owner's choice) |
| Back (breadcrumbs) | `chevron.left` |
| Breadcrumb separator, panel row chevron | `chevron.right` |
| Name voices | `person.wave.2` |
| Voices | `person.2` |
| Settings | `gearshape` |
| Log | `doc.text` |
| Menu bar glyph | custom 5-bar template image (matches `waveform`) |
| Recording | `record.circle.fill` (where a symbol is needed; dots are drawn shapes) |
| Processing | `ProgressView` (the design names `progress.indicator`) |
| Failed | `exclamationmark.triangle.fill` |
| Needs names | `person.fill.questionmark` |
| Permissions warning | `exclamationmark.circle.fill` |
| Listening | `circle.fill`, green |
| Permission granted / missing | `checkmark.circle.fill` / `xmark.circle.fill` |
| Play / Pause | `play.fill` / `pause.fill` |
| Back / forward 15 s | `gobackward.15` / `goforward.15` |
| Follow playback | `text.below.photo` |
| Find in transcript, search | `magnifyingglass` |
| Find previous / next | `chevron.up` / `chevron.down` |
| More | `ellipsis` in a drawn circle (or `ellipsis.circle`) |
| Open note | `doc.richtext` |
| Show in Finder, folder rows | `folder` |
| Delete | `trash` |
| Skip and delete call | `xmark.bin` |
| Voice sample | `play.circle` (the sheet draws `play.fill` on the speaker color) |
| Voices privacy footer | `lock` |
| Drag helper arrow | `arrow.down` |

---

## 3. Data gaps

The design shows the items below that the app does not have today.

| # | Design shows | Today | Source | Work |
| --- | --- | --- | --- | --- |
| 1 | Summary with `###` headings, **bold**, and bullet lists | `summary: String`, 3 to 8 plain sentences | Summarizer schema and prompt change | Ask for Markdown: a lead paragraph, then optional `###` sections, with `**` for key numbers and dates, and `-` lists. Store it in the same `summary` field. Old records render as one paragraph. The note embeds the same Markdown, so update the golden test in `MarkdownWriterTests`. |
| 2 | Decisions list | none | Summarizer schema: add `decisions: [String]` | Add `CallRecord.decisions: [String] = []` (it decodes to empty for old records). Hide the card when it is empty. **Owner decision:** whether the note gets a `## Decisions` section (a golden test change). |
| 3 | Action items with an owner field | `actionItems: [String]` in the "Owner: task" form | Schema change to `{owner, task}`, or derive | **Phase 1:** split on the first `": "`. The owner is the text before it, when it is 1 to 3 words. **Later:** change the schema to `action_items: [{owner, task}]` and store `actionItems` as structs, with a custom decoder that reads the old strings. Keep the note format `- [ ] Owner: task`. |
| 4 | Owner name colored by speaker | none | Derived | Match the owner to a speaker display name: exact match, then first-name match. With no match, use `text2`. |
| 5 | Action item checked state | none | New persisted field | `CallRecord.completedActionItems: Set<Int>`. When it changes, rewrite the note's checklist (`- [x]`). This is optional (phase 6). |
| 6 | Attendee name and email pairs (Invited card, chip emails, Pick menu emails) | `attendees: [String]`. One value per person: EventKit's display name when there is one, else the email. | EventKit has both values | **Tabled by the owner. Do not build.** The UI must fall back cleanly: show the single string as the name, with no email column. When the string contains "@", show it in the name slot in `text` color, not as a secondary email. Chips show the name only. |
| 7 | Speaker email on chips and in the Voices table | `VoiceProfile` has no email | Would come from #6 (picking an attendee in the naming sheet) | Blocked by #6. Hide the email text, and hide the Voices "Email" column while no profile has one. Do not add `VoiceProfile.email` until #6 is done. |
| 8 | Per-platform colors | none | Constant | `Platform.color` in the app target (1.4). |
| 9 | "Transcribing" badge, step names, "step N of 6" | `MeetingRow` shows "Processing" or "Recording" | Derived from `status` | A pure `ProcessingStep(status:)` helper in `MossadCore`, with tests (2.7 table). |
| 10 | Live step in the panel and banner ("Identifying speakers") | `processing` is a count only. `meetings` refreshes only at some points. | Pipeline progress | Add an `onStep: (CallRecord) -> Void` callback to `Pipeline`. It fires after each `call.json` save. `AppController` updates that record in `meetings`. The panel shows the step of the oldest record in progress. |
| 11 | Failure reason text ("Transcription failed: AssemblyAI key missing") | `failedStep` only. The error goes only to the log. | Pipeline | Add `CallRecord.failureReason: String?`, set where the pipeline logs the error. Map known errors to short text: a missing key gives "AssemblyAI key missing" or "Anthropic key missing"; HTTP 401 gives "invalid API key". The banner reads "STEP failed: REASON". |
| 12 | Calendar views (positions, overlaps, now-line, month cells) | none | Derived from `start`, `end`, and `status` | A pure `CalendarLayout` in `MossadCore` that returns frames and overlap columns for a day, plus month cells. Unit tests cover overlaps, calls past midnight, and DST days. No new stored data. |
| 13 | Hover-card one-line snippet | none | Summarizer schema: add `headline` (one sentence, at most 140 characters) | **Phase 1 fallback:** the first sentence of `summary`, with the Markdown removed. Later: `CallRecord.headline: String?`. |
| 14 | Talk time in minutes per first name | `TranscriptBlock.talkTime` (seconds, full names) | Derived | Format it as "24 min" and show the first name. A full name is still in the tooltip. |
| 15 | Speaker timeline segments in the player | none | Derived from `utterances` | A pure `SpeakerTimeline.segments(record) -> [(speaker, start, end)]` that merges runs and keeps the gaps. |
| 16 | Voices "Meetings" count and "Last heard" | `VoiceProfile` has name, owner flag, and embeddings | Derived from all `CallRecord`s | Count the records where `speakerNames` contains the name. "Last heard" is the newest `start` of those records. Compute it when the pane appears, off the main actor. |
| 17 | Sample length in the naming sheet ("sample 0:08") | The clip is made on play | `ClipExtractor` output | Make the clip when the sheet opens (off the main actor). Read its duration. |
| 18 | "No speech detected" state | A note is written with an empty transcript | Existing data (`utterances.isEmpty`) | UI only. See the 2.7 decision about the "No note was written." sentence. |
| 19 | "No audio available" with "deleted after 30 days" | `AudioPlayer.isAvailable == false` | Existing data and settings | UI only. Use `deleteRecordings` and `recordingDays`. |
| 20 | API key entry ("Set key", "Change") | Keys are imported only by script | Keychain | A new sheet that writes with `Keychain`. No key in logs, files, or arguments. |
| 21 | Log level, time, and filters | Plain text | Parse the existing format | A pure `LogLine.parse` in `MossadCore`, with tests. |
| 22 | Permission row copy, "Automation · Safari" | Different strings | Copy | Update `PermissionsMonitor.baseItems`. |
| 23 | Calendar match line in the log ("Matched calendar event ... by meeting link") | Sample data only | none | No work. |

Data the app cannot get today: only #6 and #7 (attendee names paired with emails, and speaker emails). The UI must work without them in every place they appear.

---

## 4. Native feasibility

### 4.1 Liquid Glass and the deployment target

- `project.yml` sets the deployment target to macOS 15.0. The build machine has the macOS 27 SDK (Xcode 27) and runs macOS 27.
- `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, and `NSGlassEffectView` need macOS 26.
- On macOS 26 and later, the sidebar, toolbar, sheets, menus, and the MenuBarExtra window get Liquid Glass with no code.
- **Recommendation:** raise the deployment target to 26.0. This is a personal tool for one Mac, and that Mac is already on 27. Then use the glass APIs directly.
- If the owner wants to keep 15.0: put every custom glass surface behind one `mossadGlass(cornerRadius:)` modifier, with `if #available(macOS 26, *)` and a `.regularMaterial` fallback. Do not spread availability checks through the views.

### 4.2 MenuBarExtra label

- Today's rule holds. The label must be a single `Image`. A `TimelineView` or mixed views in the label froze the app or hid the item.
- Draw the recording image as one `NSImage(size:flipped:drawingHandler:)` with the red bar paths and the time string. Rebuild it on the existing 1 s `SecondsClock` tick.
- Idle uses a template `NSImage` of the same path. You can also use `Image(systemName: "waveform")`, but a custom path keeps idle and recording the same shape. Make it once and cache it.
- Risk: a non-template image does not follow a tinted or transparent menu bar on macOS 26. The design accepts this for the recording state only. Draw the time in `NSColor.labelColor` inside the drawing handler, so it resolves when the image is drawn (as today).
- The panel content may use `TimelineView`, animations, and hover.
- Panel width: set the frame to 320. You cannot set the panel corner radius (22 in the design), because the system draws it. Accept the system radius.

### 4.3 Hover rows and selection

- The panel rows stay custom buttons with `onHover` (today's `MenuRow`). Change the hover look to the gray `hover` fill.
- The meeting list: keep `List(selection:)` for keyboard navigation and accessibility. The system selection highlight is the accent color when the list has focus, which differs from the design's gray `hover`. **Recommendation:** accept the native selection.
- List mode rows: use a `List` with a custom row view.

### 4.4 Window chrome and toolbar

- The design shows a full-height sidebar with the traffic lights inside it, no visible title, and the pane titles in the content.
- Native approach: keep `NavigationSplitView` (sidebar | detail) in today's `NSWindow`. Set `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `toolbarStyle = .unified`, and keep `.fullSizeContentView`. The sidebar then runs under the traffic lights.
- **Recommendation:** put the mode switcher, the calendar controls, the scope popup, and search in the window toolbar. Use `ToolbarItem`, a `Picker` with `.segmented` style, and `.searchable(placement: .toolbar)`. This gives Liquid Glass, ⌘F, and the system layout with no custom chrome.
- Show the 18 pt bold pane title as a leading toolbar `Text` item. Do not use the window title.
- In Split mode, place the icon-only switcher at the top of the list column, not in the toolbar, to match the design.
- Do not use a 3-column `NavigationSplitView` for Split mode. Changing the column count per mode is fragile. Keep the list and detail as an `HStack` (as today) inside the detail column, with the list width fixed or in an `HSplitView`.
- Breadcrumbs: build them as a plain `HStack` of buttons in the content header. There is no native breadcrumb control.

### 4.5 Calendar grids

- SwiftUI has no calendar or timeline grid. `DatePicker` and `MultiDatePicker` do not fit.
- Week and Day: build a `ScrollView` with a fixed-height `ZStack` (24 x 60 pt). Draw the hour lines with a `Canvas` or a `Path`. Place the events with `.offset` from `CalendarLayout` frames, and the now-line inside a `TimelineView(.everyMinute)`. Use `ScrollViewReader` or `defaultScrollAnchor` for the first scroll position.
- Overlaps: use a standard column-packing algorithm in `CalendarLayout` (pure, tested).
- Month: a `Grid` with 7 columns. Compute the cells in `CalendarLayout`.
- Hover card: a `.popover` on hover flickers and draws an arrow. **Recommendation:** a custom overlay inside the calendar `ZStack`. Use an `.onHover` delay of 0.5 s, a hide grace period of 0.2 s so the pointer can move into the card, and position the card with anchor preferences, clamped to the pane.
- Performance: a month can have about 100 calls. That is fine without lazy views. Use `LazyVStack` only for List mode.

### 4.6 Summary Markdown

- `Text(AttributedString(markdown:))` renders inline styles only (bold, italic, links). It does not render headings or lists as blocks.
- **Recommendation:** a small pure parser in `MossadCore` (`SummaryBlocks.parse`). It returns `[.paragraph(String) | .heading(String) | .bullets([String])]`. Render each block with inline-only `AttributedString` parsing. Test it with summaries that have no Markdown, so old records still render.

### 4.7 Player bar

- The macOS `Slider` cannot be styled to the design (6 pt track, 14 pt white thumb).
- **Recommendation:** a custom scrubber. Use a `GeometryReader` with a `Capsule` track, a fill, a thumb, and a `DragGesture(minimumDistance: 0)`. Seek on release, as today. Draw the speaker timeline with a `Canvas`.
- For accessibility, add `.accessibilityRepresentation { Slider(...) }` so VoiceOver gets a real slider.
- Speed: a `Picker` with `.segmented` style and `.controlSize(.mini)`.
- "Sticky" player: put the player outside the `ScrollView`, above it.

### 4.8 Transcript find

- In-place highlights: build each line as an `AttributedString` with `backgroundColor` runs on the matches.
- "N of M" and next/previous: keep a match index list of `(lineID, range)`, and call `ScrollViewReader.scrollTo` on the line.
- Text selection across lines is not possible with `textSelection` on separate `Text` views. This is a known SwiftUI limit, and today's behavior is the same. Accept it.

### 4.9 App icon

- The light, dark, and tinted variants need an Icon Composer `.icon` file (macOS 26 and later). XcodeGen must copy the `.icon` into the target. Check that `project.yml` resources accept it, and that `ASSETCATALOG_COMPILER_APPICON_NAME` points at it.
- If the deployment target stays 15, also keep a flat `AppIcon.appiconset`.

### 4.10 Other items

- Notification: the system controls the layout. Only the title, subtitle, and body text can change. This is fine.
- Sheet glass and the Pick menu: a SwiftUI `Menu` with `Section`s works. Two-column name and email rows are not native. Use a `Button` with a title and a subtitle `Text` (macOS 14 and later shows it as a menu item subtitle). The email appears under the name, not right-aligned. Accept this.
- Voices table: SwiftUI `Table` with `selection` gives the accent-filled selected row natively. The column widths follow the 1.4 / 1.6 / 0.7 / 1 ratios as ideal widths.
- Log: a `ScrollView` + `LazyVStack` of `Text` rows (500 lines is fine). Keep `.defaultScrollAnchor(.bottom)`.
- Drag helper: today's `NSPanel` stays. Change only the hosted SwiftUI view and its size (300 x about 220).
- Pulse animation in the window list: one `repeatForever` animation per pulsing dot is cheap. Do not drive it from a timer.
- Live elapsed time in the list row and the detail: use `TimelineView(.periodic(from:by: 1))`. This is safe inside the window.

---

## 5. Build order

Each phase ships on its own, passes `swift test`, and leaves the app usable. Sizes: S is up to 1 day, M is 2 to 3 days, L is 4 to 6 days.

| Phase | Content | Core changes | Size |
| --- | --- | --- | --- |
| 1. Tokens and shell | `Theme.swift`, `Platform.color`, the shared components (2.18), the new sidebar icons, the sidebar footer status, window chrome (4.4), the menu bar icon with red bars (2.2), the menu bar panel restyle with the processing step and the permissions row (2.3), the right-click menu (2.16), the empty state (2.17), and the notification copy (2.12). Decide the deployment target here. | `ProcessingStep`, `Pipeline.onStep` (gaps 9, 10) | M |
| 2. Split list and detail | List grouping and rows with badges (2.6). Detail header with chips and fallbacks, banners, live panel, skeleton, empty states (2.7). Custom player with the speaker timeline and speed control. Summary cards: the Summary text (plain paragraphs), Action items with the owner parsed from "Owner: task", Talk time, and Invited with the email-only fallback. | `SpeakerTimeline`, `failureReason` (gaps 11, 15) | L |
| 3. Transcript and naming | The Transcript tab with in-place find, "N of M", Follow switch (2.10). The "Who is speaking?" sheet with the sample length and the sectioned Pick menu (2.11). | clip length (gap 17) | M |
| 4. Summary schema | Summarizer: Markdown summary, `decisions`, `headline`, and structured action items. The `SummaryBlocks` renderer. The Decisions card. Golden test update. Re-summarize stays opt-in: old records keep their text. | gaps 1, 2, 3, 13 | M |
| 5. List and Calendar modes | The mode switcher and toolbar, List mode with breadcrumbs (2.8), Calendar Week, Day, and Month with the now-line, live pulse, hover card, and "+N more" (2.9). | `CalendarLayout` (gap 12) | L |
| 6. Voices, Log, Settings | Voices table with counts and last heard (2.13). Log with levels and filters (2.14). Settings regrouped, with new permission copy, the consent box, and the API key sheet (2.15). Drag helper restyle. Optional: action item checkboxes (gap 5). | `LogLine.parse`, voice stats (gaps 16, 21) | M |
| 7. Polish | The Icon Composer app icon, Reduce Motion checks, a dark mode pass on every screen, VoiceOver labels, and keyboard shortcuts (⌘F, ⌘G, ⌘[, Space, Delete). | none | S |

Phases 1 to 3 give the full daily-use flow in the new look. Phases 4 and 5 add the new features. Phase 6 can run in parallel with phase 5.

## 6. Open decisions for the owner

1. Raise the deployment target to macOS 26 (recommended) or keep 15 with fallbacks.
2. The single badge word "Transcribing" for all processing steps (as designed), or "Processing".
3. Add a `## Decisions` section to the Markdown note (this changes the golden test).
4. The shorter consent text in Settings (with "This is not legal advice." kept).
5. Action item checkboxes that write back to the note (phase 6, optional).
6. The attendee name and email work stays tabled. The UI ships with the fallbacks in gaps 6 and 7.

### Owner answers (2026-10-21)

1. Raise the deployment target to macOS 26.
2. Use "Processing" for every processing step.
3. Yes: add `## Decisions` to the Markdown note.
4. Yes: use the shorter consent text.
5. No checkbox write-back.
6. Attendee directory work stays tabled. Names are collected input instead: in "Who is speaking?" the owner picks the person's email from the attendees and types the name in a separate field. Mossad stores the name with the email (voice profile) and shows "Name" with the email wherever the design shows both. Without a stored name, the email alone.

