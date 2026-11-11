import { describe, expect, it } from 'vitest';
import { copyText, minutesText, shareMarkdown } from '../src/markdown';
import type { Share } from '../src/types';

const meeting: Share = {
  title: 'Budget review', start: '2026-11-03T21:00:00Z', end: '2026-11-03T21:47:00Z', people: ['Dana Lee', 'Jennifer Lee'], owner: 'Dana Lee',
  summary: 'We held spend flat.', topics: [{ title: 'First quarter', summary: 'Spend is **flat**.\n- Travel is down' }],
  decisions: ['Keep the vendor', { text: 'Hold spend', at: 3128 }], decisionTimes: [61, null],
  actionItems: [{ task: 'Send the numbers', owner: 'Jennifer Lee', text: 'Jennifer Lee: Send the numbers' }, { task: 'Book the room', text: 'Book the room' }],
  lines: [{ at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' }, { at: 3725, speaker: 'Dana Lee', text: 'Then we hold.' }],
  audio: false, chat: false, expires: null, timeZone: 'America/Chicago',
};

describe('the Markdown of a shared meeting', () => {
  it('has the title, the date, the people, the notes, and every line with its speaker and time', () => {
    expect(shareMarkdown(meeting)).toBe(`# Budget review

- Date: Tuesday, November 3, 2026, 3:00 PM to 3:47 PM CST
- Duration: 47 minutes
- People: Dana Lee, Jennifer Lee
- Shared by: Dana Lee

## Summary

We held spend flat.

### First quarter

Spend is **flat**.
- Travel is down

## Decisions

- [00:01:01] Keep the vendor
- [00:52:08] Hold spend

## Action items

- [ ] Jennifer Lee: Send the numbers
- [ ] Book the room

## Transcript

[00:01:05] Jennifer Lee: I need the numbers by Friday.
[01:02:05] Dana Lee: Then we hold.
`);
  });

  it('leaves out the parts that are not shared', () => {
    const text = shareMarkdown({ ...meeting, summary: undefined, topics: undefined, decisions: undefined, actionItems: undefined });
    expect(text).not.toContain('## Summary');
    expect(text).not.toContain('## Decisions');
    expect(text).not.toContain('## Action items');
    expect(text).toContain('## Transcript');
    expect(shareMarkdown({ ...meeting, lines: undefined })).not.toContain('## Transcript');
  });

  it('starts the copy with one line for the AI, and names the address only when there is one', () => {
    const open = copyText(meeting, 'https://notes.example.com/abc.md').split('\n');
    expect(open.slice(0, 4)).toEqual(['Here is a meeting transcript and its notes. Use it as context for my questions.',
      'The same text is at https://notes.example.com/abc.md', '', '# Budget review']);
    const closed = copyText(meeting, null).split('\n');
    expect(closed.slice(0, 3)).toEqual(['Here is a meeting transcript and its notes. Use it as context for my questions.', '', '# Budget review']);
    expect(copyText(meeting, null)).not.toContain('http');
  });

  it('gives a length of an hour or more in hours and minutes', () => {
    expect(minutesText(47)).toBe('47 minutes');
    expect(minutesText(1)).toBe('1 minute');
    expect(minutesText(60)).toBe('1 h');
    expect(minutesText(130)).toBe('2 h 10 min');
  });
});
