import { describe, expect, it } from 'vitest';
import { MeetingTools, nameMatches } from '../src/tools';
import type { MeetingView } from '../src/types';
import { localDayStart, timestamp } from '../src/util';

const meeting = (id: string, start: string, over: Partial<MeetingView> = {}): MeetingView => ({
  id, title: `Budget ${id}`, start, end: new Date(Date.parse(start) + 30 * 60_000).toISOString(),
  tags: ['Budget'], people: ['Dana', 'Jennifer Lee'], attendees: [], topics: [], decisions: [],
  actionItems: [{ task: 'Send the numbers', owner: 'Jennifer Lee', text: 'Jennifer Lee: Send the numbers' }],
  lines: [{ at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' }],
  timeZone: 'America/Chicago', ...over,
});

describe('names', () => {
  it('matches first names, short forms, and last names like the Mac', () => {
    expect(nameMatches('Jen', 'Jennifer Lee')).toBe(true);
    expect(nameMatches('Lee', 'Jennifer Lee')).toBe(true);
    expect(nameMatches('Jennifer Lee', 'Jennifer Lee')).toBe(true);
    expect(nameMatches('J', 'Jennifer Lee')).toBe(false);
    expect(nameMatches('nif', 'Jennifer Lee')).toBe(false);
  });
});

describe('dates', () => {
  it('reads a day in the owner time zone', () => {
    expect(localDayStart('2026-11-04', 'America/Chicago')).toBe(Date.parse('2026-11-04T06:00:00Z'));
    expect(localDayStart('2026-07-04', 'America/Chicago')).toBe(Date.parse('2026-07-04T05:00:00Z'));
    expect(localDayStart('nope')).toBeNull();
  });

  it('writes times as the notes do', () => {
    expect(timestamp(3725.9)).toBe('01:02:05');
  });
});

describe('tools', () => {
  const tools = new MeetingTools([
    meeting('a', '2026-11-03T15:00:00Z'),
    meeting('b', '2026-11-05T03:00:00Z', { people: ['Dana', 'Ed Ng'], title: 'Hiring', tags: [], lines: [] }),
  ], 'Dana');

  it('finds meetings newest first, by person, word, and local day', () => {
    expect(tools.find({}).map((m) => m.id)).toEqual(['b', 'a']);
    expect(tools.find({ people: ['Jen'] }).map((m) => m.id)).toEqual(['a']);
    expect(tools.find({ query: 'friday' }).map((m) => m.id)).toEqual(['a']);
    // 03:00 UTC on Nov 5 is the evening of Nov 4 in Chicago.
    expect(tools.find({ from: '2026-11-04', to: '2026-11-04' }).map((m) => m.id)).toEqual(['b']);
  });

  it('reads a meeting with its transcript in the notes format', () => {
    const text = tools.run('read_meeting', { call_id: 'a' });
    expect(text).toContain('call_id: a | Budget a |');
    expect(text).toContain('Action items:\n- Jennifer Lee: Send the numbers');
    expect(text).toContain('[00:01:05] Jennifer Lee: I need the numbers by Friday.');
    expect(tools.run('read_meeting', { call_id: 'x' })).toBe('No meeting with that call_id.');
  });

  it('reads decisions from both the old string form and the timed form', () => {
    const t = new MeetingTools([meeting('d', '2026-11-03T15:00:00Z', { decisions: ['Ship Friday', { text: 'Hire two', at: 3128 }, { text: 'Skip it' }] })], 'Dana');
    expect(t.run('read_meeting', { call_id: 'd' })).toContain('Decisions:\n- Ship Friday\n- [00:52:08] Hire two\n- Skip it');
  });

  it('reads decision times that arrive beside plain-string decisions', () => {
    const t = new MeetingTools([meeting('e', '2026-11-03T15:00:00Z', { decisions: ['Ship Friday', 'Hire two'], decisionTimes: [null, 3128] })], 'Dana');
    expect(t.run('read_meeting', { call_id: 'e' })).toContain('Decisions:\n- Ship Friday\n- [00:52:08] Hire two');
  });

  it('searches lines and lists action items by owner', () => {
    expect(tools.run('search_transcripts', { query: 'numbers' })).toContain('[00:01:05] Jennifer Lee:');
    expect(tools.run('action_items', { owner: 'Jen' })).toContain('Jennifer Lee: Send the numbers');
    expect(tools.run('action_items', { owner: 'Ed' })).toBe('No action items match.');
  });

  it('gives ChatGPT search results and full text with links into the app', () => {
    expect(tools.search('budget').results).toEqual([{ id: 'a', title: 'Budget a', url: 'mossad://call/a' }]);
    expect(tools.fetch('a')?.text).toContain('Transcript:');
  });
});
