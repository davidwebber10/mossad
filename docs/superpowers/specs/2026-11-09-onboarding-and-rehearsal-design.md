# Onboarding baseline and the Rehearsal app

## Intent

A new person installs Mossad and, in a few calm minutes, ends with everything that matters set up: who they are,
the permissions, the AI keys, their calendars, and a check that recording works. Today the welcome is three steps
(intro, permissions, name and keys) and much of the setup lives only in Settings. The owner wants a strong baseline
they can walk through in real life and then give feedback on, without disturbing their real Mossad.

The owner asked to skip the questions: every choice below is a call made for them, to be tuned after the walkthrough.

## Goals

- A guided onboarding window on the Mac, in the editorial design (tokens, glass, the design's icons), one topic per
  step, a step rail on the left with each step's state (done, needs you, skipped), Back/Continue, and every step
  skippable except "You". It replaces WelcomeView. It is reachable later from Settings ("Run setup again").
- Steps, in order:
  1. Welcome: what Mossad does in three short lines, and the privacy promise (audio stays on this Mac except for the
     transcription provider; voice fingerprints never leave the Mac; keys live in the Keychain).
  2. You: name (required), work email (used to find you in invites), company (optional).
  3. Permissions: one row per permission in importance order: Microphone, System audio recording, Calendars,
     Accessibility, Notifications, then Automation for each installed browser (for Google Meet). Each row: what it
     is for in one line, Required or Recommended, an action that triggers the real system prompt or opens the exact
     System Settings pane, and live state from PermissionsMonitor (it updates when the owner returns from System
     Settings). Continue is allowed without everything; a line says what will not work.
  4. AI: transcription provider and key (AssemblyAI by default) and notes provider and key (Anthropic by default),
     each with a "Get a key" link, paste, and a Check that makes the cheapest real call and shows a friendly result
     (FriendlyError). A one-line cost estimate per hour of meetings.
  5. Calendars: pick which calendars to read (after the permission), with a preview of today's next meeting that
     Mossad would record.
  6. Check: a live mic level ("say something") and a system audio check (Mossad plays a short tone and confirms the
     tap hears it). Plain pass/fail with what to fix.
  7. iPhone and sync (optional): None, iCloud, or your server, and the iPhone app's QR when relevant.
  8. Done: Open at login toggle (on), where the menu bar icon is, and what happens on the next call.
- Progress is saved per step, so quitting mid-way resumes at the same step.

## The Rehearsal app

- A second app target, "Mossad Rehearsal", bundle id `com.dwebber.mossad.rehearsal`, built from the same code with a
  REHEARSAL compile flag. Because the bundle id differs, macOS asks for every permission fresh, exactly as a new
  user sees it, and its UserDefaults are separate.
- It never touches the real app's data or secrets: its data root is `~/Mossad Rehearsal`, its Keychain service is
  `com.dwebber.mossad.rehearsal`, and it never detects calls, records, runs the pipeline, syncs, serves MCP, checks for
  updates, or registers a login item (the Done step's toggle is shown but does nothing in Rehearsal). Its menu bar
  icon and window carry a small "Rehearsal" mark.
- It opens straight into onboarding, with a slim rehearsal bar at the top: step jump menu, Restart onboarding, Reset
  permissions (runs `tccutil reset All com.dwebber.mossad.rehearsal` then relaunches), and a Note field that appends
  the owner's feedback, tagged with the current step and time, to `~/Mossad Rehearsal/feedback.md` (so Claude can read
  it).
- `scripts/rehearsal.sh` builds it and installs it to `/Applications/Mossad Rehearsal.app`, never touching
  `/Applications/Mossad.app` or the running Mossad, and opens it.

## Non-goals

- No iPhone onboarding changes in this pass. No account system. No change to how the real app records.

## Constraints

- Logic in MossadCore, test-first (step order and state, resume, which permissions count as required, the feedback
  file format). Swift 6, macOS 26. AGENTS.md rules: secrets only in the Keychain, never on the main thread for
  slow work, no AI attribution.
