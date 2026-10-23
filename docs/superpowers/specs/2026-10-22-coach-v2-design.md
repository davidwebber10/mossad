# Coach v2: one focus, three lines, numbers against your normal

## Why

A review today is 1,000 to 1,400 words with a 1 to 5 score, four area scores, and many points. The coach also reports progress on a focus the owner never saw or agreed to ("you did this better this time"). Research (feedback interventions, grades versus comments, goal commitment, progress monitoring) says: few points, no grades, one focus the person agreed to, progress shown against their own baseline. The owner approved all six choices in the spike (artifact "Coach Concepts").

## Decisions

1. **After each call, about 60 words:** *Your focus* (with a dot per call), *Did well*, *Improving*, *Try next time*. Everything else (metrics with goals, the call strip, the meeting's value, the detailed points with 👍/👎, Talk to the coach) sits under "More from the coach".
2. **The focus is agreed, not assigned.** The coach proposes one focus as an if-then plan with a reason. The owner accepts, edits, or dismisses it, on the Mac or the iPhone. Until a focus is accepted, no review claims progress on it. Each review records the result for the active focus: hit, missed, or no chance. After 5 hits in the last 6 chances the focus is marked learned and the coach proposes the next one.
3. **No score per call.** New reviews have no scorecard. Numbers appear only against the owner's own history or a stated goal.
4. **Metrics with goals,** measured from the transcript, never by the model:
   - talk share against the range for the meeting: a 1:1 is 10 to 50 percent, a group is up to 1.5 times a fair share (1 / speakers);
   - longest turn under 2 minutes in a conversation;
   - questions asked (compared with the owner's usual);
   - pace, flagged only above 220 words a minute or 15 percent over the owner's usual.
   Filler words are no longer coached. A call strip shows talk share and pace for every 3 minutes, with long turns marked.
5. **Voice:** a direct peer by default; warm mentor and data only as settings. Autonomy-supportive words ("try", "next time you could"), no labels about the person, never scolding.
6. **Quiet calls:** when the owner mostly listened, or nothing is notable, the review is one line or a single "Did well".

## Data

- `CoachReview` gains `didWell`, `improving`, `tryNext` (each a `CoachNote`: text, optional quote and time), `focusResult` (focus id, outcome, evidence, time), and `quiet`. The existing `strengths`, `improvements`, and `value` stay as the detail under "More", capped at 2 points each. `scorecard` stays readable for older reviews and is no longer written.
- `CoachProfile` gains `foci: [CoachFocus]` (id, plan, why, optional metric with a target, status proposed / active / learned / dismissed, dates, results per call, `updated`) and `voice`. `focus` (text) stays for older readers and mirrors the active focus.
- iCloud merge: foci merge by id; the newer `updated` wins; results join by call. This lets an accept on the phone reach the Mac even though the Mac writes the other coaching fields.
- Older reviews render in the new layout: headline as the line, first strength as *Did well*, first improvement as *Try next time*.

## Out of scope

Live cues during a call. Custom metric targets in Settings (defaults only for now). A separate weekly screen: the weekly email carries the focus status and any proposal.
