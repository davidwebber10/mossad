import type { Share } from './types';
import { decisionLine, timestamp } from './util';

/** A shared meeting as plain Markdown, for an AI app to read: the notes first, then every line of the transcript. */

export const instruction = 'Here is a meeting transcript and its notes. Use it as context for my questions.';

/** "Tuesday, November 3, 2026" and "3:00 PM to 3:47 PM CST" in the owner's time zone. */
export function when(s: Share): { day: string; time: string; minutes: number } {
  const timeZone = s.timeZone ?? 'UTC';
  const start = new Date(s.start), end = new Date(s.end);
  const day = new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }).format(start);
  const clock = (d: Date, zone = false) => new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', minute: '2-digit', ...(zone ? { timeZoneName: 'short' as const } : {}) }).format(d);
  return { day, time: `${clock(start)} to ${clock(end, true)}`, minutes: Math.max(0, Math.round((end.getTime() - start.getTime()) / 60_000)) };
}

export const minutesText = (n: number) => (n === 1 ? '1 minute' : `${n} minutes`);

export function shareMarkdown(s: Share): string {
  const w = when(s);
  const out = [`# ${s.title}`, [
    `- Date: ${w.day}, ${w.time}`,
    `- Duration: ${minutesText(w.minutes)}`,
    ...(s.people.length ? [`- People: ${s.people.join(', ')}`] : []),
    `- Shared by: ${s.owner}`,
  ].join('\n')];
  if (s.summary || s.topics?.length) {
    out.push('## Summary');
    if (s.summary) out.push(s.summary.trim());
    for (const t of s.topics ?? []) out.push(`### ${t.title}`, t.summary.trim());
  }
  if (s.decisions?.length) out.push('## Decisions', s.decisions.map((d, i) => `- ${decisionLine(d, s.decisionTimes?.[i])}`).join('\n'));
  if (s.actionItems?.length) out.push('## Action items', s.actionItems.map((a) => `- [ ] ${a.owner ? `${a.owner}: ${a.task}` : a.text}`).join('\n'));
  if (s.lines?.length) out.push('## Transcript', s.lines.map((l) => `[${timestamp(l.at)}] ${l.speaker}: ${l.text}`).join('\n'));
  return out.join('\n\n') + '\n';
}

/**
 * What "Copy for your AI" puts on the clipboard: one line that says what follows, the address of the same text
 * when the share has one (a share with a PIN has none), and the meeting.
 */
export function copyText(s: Share, address: string | null): string {
  return [instruction, ...(address ? [`The same text is at ${address}`] : []), '', shareMarkdown(s)].join('\n');
}
