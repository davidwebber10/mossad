import { describe, expect, it } from 'vitest';
import { handleMCP } from '../src/mcp';
import { fakeEnv } from './fakes';
import { fixture } from './fixtures.mjs';

/**
 * The digest's tools: what the Mac computed for the recurring meetings, each meeting's numbers, the bookmarks, the
 * Analytics page, and the coach's cards and goal, served as it came (the parts are written by the Swift encoder in
 * `ServerDigestTests`). A part that never arrived says so. No calendar data: no next date.
 */

type W = ReturnType<typeof fakeEnv>;

const parts = ['digest-series', 'digest-bookmarks', 'digest-analytics', 'digest-coach', 'digest-meetings-2027-01', 'digest-meetings-2026-12', 'digest-meetings-2026-09'];

async function setUp(skip: string[] = [], config: Record<string, string> = {}, replace: Record<string, unknown> = {}) {
  const w = fakeEnv();
  const put = async (name: string, type: string, body: unknown) => {
    if (skip.includes(name)) return;
    await w.files.put(`records/${name}/data`, JSON.stringify(body));
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, ?, '{}', '["data"]',
      (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, '2027-01-15T09:00:00Z')`).bind(name, type).run();
  };
  for (const part of parts) await put(part, 'Digest', part in replace ? replace[part] : fixture(part));
  if ('people' in replace) await put('people', 'People', replace.people);
  await put('next-time', 'NextTime', {
    points: [
      { id: 'P1', text: 'Ask about the March date', seriesID: 'cal:g-weekly', seriesTitle: 'Weekly sync', rank: 1, created: '2027-01-14T00:00:00Z' },
      { id: 'P2', text: 'Old key point', seriesID: 'cal:gone', seriesKeys: ['call:20270108-100000'], seriesTitle: 'Weekly sync', rank: 2, created: '2027-01-14T00:00:00Z' },
      { id: 'P3', text: 'Another series', seriesID: 'cal:other', seriesTitle: 'Other', rank: 1, created: '2027-01-14T00:00:00Z' },
    ],
  });
  for (const [k, v] of Object.entries({ owner: 'Avery Webb', timeZone: 'America/Chicago', ...config })) {
    await w.env.DB.prepare('INSERT INTO config (key, value) VALUES (?, ?)').bind(k, v).run();
  }
  return w;
}

async function call(w: W, name: string, args: Record<string, unknown> = {}) {
  const res = await handleMCP(new Request('https://mcp.example.com/mossad', { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) }), w.env);
  expect(res.status).toBe(200);
  return ((await res.json()) as { result: { content: { text: string }[]; structuredContent?: { results?: { id: string }[] } } }).result;
}
const text = async (w: W, name: string, args: Record<string, unknown> = {}) => (await call(w, name, args)).content[0].text;

describe('the digest tools', () => {
  it('lists every new tool as a read, with limits and offsets on its lists', async () => {
    const res = await handleMCP(new Request('https://mcp.example.com/mossad', { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) }), (await setUp()).env);
    const tools = ((await res.json()) as { result: { tools: { name: string; annotations: { readOnlyHint: boolean }; inputSchema: { properties: Record<string, unknown> } }[] } }).result.tools;
    for (const name of ['recurring', 'read_series', 'bookmarks', 'meeting_analytics', 'analytics', 'coach_findings', 'coach_goals']) {
      const t = tools.find((x) => x.name === name);
      expect(t, name).toBeDefined();
      expect(t!.annotations.readOnlyHint).toBe(true);
    }
    for (const name of ['recurring', 'read_series', 'bookmarks', 'coach_findings']) {
      expect(Object.keys(tools.find((x) => x.name === name)!.inputSchema.properties)).toEqual(expect.arrayContaining(['limit', 'offset']));
    }
  });

  it('lists the recurring meetings with no next date, and says when the Mac made the list', async () => {
    const out = await text(await setUp(), 'recurring');
    expect(out).toContain('series_id: cal:g-weekly | Weekly sync');
    expect(out).toContain('Usually 4 people; 1 open item');
    expect(out).toContain('Upcoming meetings stay on your Mac, so the next date is only known there');
    expect(out).toContain('Last changed on your Mac on Jan 15, 2027');
  });

  it('reads one series with its points, history, people, numbers, and open items', async () => {
    const w = await setUp();
    for (const q of ['cal:g-weekly', 'weekly sync', 'call:20270113-100000']) {
      expect(await text(w, 'read_series', { series: q })).toContain('series_id: cal:g-weekly');
    }
    const out = await text(w, 'read_series', { series: 'cal:g-weekly' });
    expect(out).toContain('Ask about the March date (point_id: P1,');
    expect(out).toContain('Old key point');
    expect(out).not.toContain('Another series');
    expect(out).toContain('call_id: 20270113-100000');
    expect(out).toContain('Sam Carter: spoke in 2 of 2');
    expect(out).not.toContain('Riley Stone');
    expect(out).toContain('Draft the plan');
    expect(out).toContain('Upcoming meetings stay on your Mac, so the next date is only known there');
    expect(await text(w, 'read_series', { series: 'nothing like it' })).toMatch(/^No recurring meeting matches/);
  });

  it('gives the bookmarks, one meeting\'s numbers, the Analytics page, and the coach', async () => {
    const w = await setUp();
    const marks = await text(w, 'bookmarks');
    expect(marks).toContain('call_id: 20270113-100000');
    expect(marks).toContain('note: Slip 2');
    expect(await text(w, 'bookmarks', { query: 'slip 1' })).not.toContain('Slip 2');
    const numbers = await text(w, 'meeting_analytics', { call_id: '20270113-100000' });
    expect(numbers).toContain('Sam Carter talked most');
    expect(numbers).toContain('Speakers:');
    expect(await text(w, 'meeting_analytics', { call_id: '20991231-000000' })).toMatch(/^No numbers on this server for that call_id/);
    const page = await text(w, 'analytics', { days: 30 });
    expect(page).toContain('Last 30 days, Dec 17, 2026 to Jan 15, 2027: 4 calls');
    expect(await text(w, 'analytics', { days: 20 })).toContain('Last 30 days');
    const cards = await text(w, 'coach_findings');
    expect(cards).toContain('When you take an item, say the day.');
    expect(await text(w, 'coach_goals')).toContain('Name a date when you take an item');
  });

  it('says plainly when a part never arrived', async () => {
    const w = await setUp(parts);
    expect(await text(w, 'recurring')).toMatch(/^This server has no recurring meetings from your Mac yet/);
    expect(await text(w, 'bookmarks')).toMatch(/^This server has no bookmarks from your Mac yet/);
    expect(await text(w, 'analytics')).toMatch(/^This server has no analytics from your Mac yet/);
    expect(await text(w, 'coach_findings')).toMatch(/^This server has no coach's cards from your Mac yet/);
    expect(await text(w, 'meeting_analytics', { call_id: '20270113-100000' })).toMatch(/^This server has no meeting numbers from your Mac/);
  });

  it('pages the lists', async () => {
    const w = await setUp();
    const first = await text(w, 'bookmarks', { limit: 1 });
    expect(first).toContain('(1 more; ask with offset 1.)');
    expect(await text(w, 'bookmarks', { limit: 1, offset: 1 })).not.toContain('more;');
  });

  it('searches and fetches series and bookmarks', async () => {
    const w = await setUp();
    const ids = (await call(w, 'search', { query: 'weekly' })).structuredContent?.results?.map((r) => r.id) ?? [];
    expect(ids).toContain('series:cal:g-weekly');
    const marks = (await call(w, 'search', { query: 'slip' })).structuredContent?.results?.map((r) => r.id) ?? [];
    expect(marks).toContain('bookmark:20270113-100000#310');
    expect(await text(w, 'fetch', { id: 'series:cal:g-weekly' })).toContain('Weekly sync');
    expect(await text(w, 'fetch', { id: 'bookmark:20270113-100000#310' })).toContain('Slip 2');
  });

  it('gives a card about a person only with the switch on and while the person keeps a read', async () => {
    const people = fixture('people');
    const sam = { id: 'id-sam', displayName: 'Sam Carter' };
    const off = await text(await setUp([], {}, { people: { people: [...people.people, sam] } }), 'coach_findings');
    expect(off).not.toContain('Sam reports to you.');
    expect(off).toContain('When you take an item, say the day.');
    const on = await text(await setUp([], { mcpPersonas: '1' }, { people: { people: [...people.people, sam] } }), 'coach_findings');
    expect(on).toContain('Sam reports to you.');
    expect(on).toContain('About Sam Carter');
    const kept = await text(await setUp([], { mcpPersonas: '1' }, { people: { people: [...people.people, { ...sam, doNotProfile: true }] } }), 'coach_findings');
    expect(kept).not.toContain('Sam reports to you.');
    // With no people file the server cannot tell who keeps a read: no card about a person.
    expect(await text(await setUp([], { mcpPersonas: '1' }), 'coach_findings')).not.toContain('Sam reports to you.');
  });

  it('says the coach is off on the Mac', async () => {
    const coach = { ...fixture('digest-coach'), coachOn: false, findings: [] };
    expect(await text(await setUp([], {}, { 'digest-coach': coach }), 'coach_findings')).toMatch(/^The coach is off on your Mac/);
  });

  it('writes out only the fields it knows: a key it does not know never shows', async () => {
    const series = fixture('digest-series');
    const s = series.series[0];
    const odd = { ...series, series: [{ ...s, next: '2027-01-16T10:00:00Z', invitees: ['odd.guest@example.com'], rows: s.rows.map((r: object) => ({ ...r, plannedMinutes: 77 })) }] };
    const w = await setUp([], {}, { 'digest-series': odd });
    for (const out of [await text(w, 'recurring'), await text(w, 'read_series', { series: 'weekly sync' })]) {
      expect(out).not.toContain('odd.guest');
      expect(out).not.toContain('2027-01-16');
      expect(out).not.toContain('Jan 16');
      expect(out).not.toContain('77');
    }
  });

  it('answers in words for a part from a newer Mac or a part that does not read', async () => {
    const newer = await setUp([], {}, { 'digest-series': { ...fixture('digest-series'), version: 2 } });
    expect(await text(newer, 'recurring')).toMatch(/newer form than this server reads/);
    const broken = await setUp([], {}, { 'digest-series': { version: 1, made: '2027-01-15T08:00:00Z' }, 'digest-coach': { version: 1, made: '2027-01-15T08:00:00Z', findings: 'x' } });
    expect(await text(broken, 'recurring')).toMatch(/do not read/);
    expect(await text(broken, 'coach_findings')).toMatch(/do not read/);
  });

  it('says the list of recurring meetings comes from the past meetings alone', async () => {
    const w = await setUp();
    expect(await text(w, 'recurring')).toContain('from your past meetings alone');
    const none = await text(w, 'read_series', { series: 'old standup' });
    expect(none).toMatch(/^No recurring meeting matches/);
    expect(none).toContain("Recurring page has every one");
  });

  it('finds a series by a calendar id with an @ as the Mac has it, and links to it whole', async () => {
    const series = fixture('digest-series');
    const id = 'cal:ek:abc123@google.com';
    const s = { ...series.series[0], id, keys: [id, ...series.series[0].keys] };
    const w = await setUp([], {}, { 'digest-series': { ...series, series: [s] } });
    expect(await text(w, 'read_series', { series: id })).toContain(`series_id: ${id}`);
    expect(await text(w, 'read_series', { series: 'call:20270113-100000' })).toContain('Weekly sync');
    const found = (await call(w, 'search', { query: 'weekly' })).structuredContent as { results: { id: string; url: string }[] };
    expect(found.results.find((r) => r.id === `series:${id}`)?.url).toBe('mossad://series/cal%3Aek%3Aabc123%40google.com');
  });

  it('holds back every card about a person while the switch is off: an id, a name, or the Mac\'s flag', async () => {
    const coach = fixture('digest-coach');
    const named = { ...coach.findings[2], id: 'named', text: 'A conclusion about someone.', personName: 'Jordan Price' };
    const w = await setUp([], {}, { 'digest-coach': { ...coach, findings: [...coach.findings, named] } });
    const off = await text(w, 'coach_findings');
    expect(off).not.toContain('A conclusion about someone.');
    expect(off).not.toContain('Let Sam Carter finish');
    expect(off).not.toContain('Sam reports to you.');
    expect(off).toContain('When you take an item, say the day.');
    expect(off).toContain('This call sets the plan for March.');
    const people = fixture('people');
    const on = await text(await setUp([], { mcpPersonas: '1' }, { people: { people: [...people.people, { id: 'id-sam', displayName: 'Sam Carter' }] } }), 'coach_findings');
    expect(on).toContain('Let Sam Carter finish');
  });

  it('says only that upcoming meetings stay on the Mac, and where the points of a missing series are', async () => {
    const w = await setUp();
    const outs = [await text(w, 'recurring'), await text(w, 'read_series', { series: 'weekly sync' }), await text(w, 'meeting_analytics', { call_id: '20270113-100000' })];
    for (const out of outs) expect(out).not.toMatch(/invite|planned|calendar/i);
    expect(outs[0]).toContain('Upcoming meetings stay on your Mac');
    expect(outs[0]).toContain('from your past meetings');
    expect(await text(w, 'read_series', { series: 'old standup' })).toContain('next_time_points');
  });

  it('says when the Mac last changed a part and last sent its copy', async () => {
    const w = await setUp([], { syncedAt: '2027-01-20T09:00:00Z' });
    const out = await text(w, 'bookmarks');
    expect(out).toContain('Last changed on your Mac on Jan 15, 2027');
    expect(out).toContain('Your Mac last sent its copy on Jan 20, 2027');
  });

  it('fetches a bookmark by an id with its # sent as %23', async () => {
    expect(await text(await setUp(), 'fetch', { id: 'bookmark:20270113-100000%23310' })).toContain('Slip 2');
  });

  it('says that cards about a person are held back while the switch is off, with cards or without', async () => {
    const held = 'Cards about a person show here only when "Share the reads with other AI apps" is on in Settings > Coach.';
    expect(await text(await setUp(), 'coach_findings')).toContain(held);
    const none = { ...fixture('digest-coach'), findings: [] };
    const empty = await text(await setUp([], {}, { 'digest-coach': none }), 'coach_findings');
    expect(empty).toMatch(/^No cards wait for an answer/);
    expect(empty).toContain(held);
    expect(await text(await setUp([], { mcpPersonas: '1' }), 'coach_findings')).not.toContain(held);
  });

  it('says how long a series may go with no meeting before it leaves the list', async () => {
    expect(await text(await setUp(), 'recurring')).toContain('no meeting for about 8 weeks (longer for a series that meets less often)');
  });
});
