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

async function setUp(skip: string[] = [], config: Record<string, string> = {}) {
  const w = fakeEnv();
  const put = async (name: string, type: string, body: unknown) => {
    if (skip.includes(name)) return;
    await w.files.put(`records/${name}/data`, JSON.stringify(body));
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, ?, '{}', '["data"]',
      (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, '2027-01-15T09:00:00Z')`).bind(name, type).run();
  };
  for (const part of ['digest-series', 'digest-bookmarks', 'digest-analytics', 'digest-coach', 'digest-meetings-2027-01', 'digest-meetings-2026-12']) {
    await put(part, 'Digest', fixture(part));
  }
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
    expect(out).toContain('Usually 3 people; 1 open item');
    expect(out).toContain('The next date is only known on your Mac');
    expect(out).toContain('As your Mac made it on Jan 15, 2027');
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
    expect(out).toContain('Sam Carter: came 2 of 2');
    expect(out).toContain('Draft the plan');
    expect(out).toContain('The next date is only known on your Mac');
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
    expect(page).toContain('Last 30 days: 3 calls');
    expect(await text(w, 'analytics', { days: 20 })).toContain('Last 30 days');
    const cards = await text(w, 'coach_findings');
    expect(cards).toContain('When you take an item, say the day.');
    expect(await text(w, 'coach_goals')).toContain('Name a date when you take an item');
  });

  it('says plainly when a part never arrived', async () => {
    const w = await setUp(['digest-series', 'digest-bookmarks', 'digest-analytics', 'digest-coach', 'digest-meetings-2027-01', 'digest-meetings-2026-12']);
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
});
