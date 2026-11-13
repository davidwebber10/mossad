import { describe, expect, it } from 'vitest';
import { handleAPI } from '../src/api';
import { handleMCP } from '../src/mcp';
import { fakeEnv } from './fakes';

/** The server MCP's reads beyond the meetings, from what the Mac syncs: people, points, tasks, coach, chats, shares. */

const people = {
  version: 2,
  people: [
    { id: 'id-owner', displayName: 'Avery Webb', isOwner: true, forms: [{ text: 'Avery Webb' }], emails: [] },
    {
      id: 'id-sam', displayName: 'Sam Carter', forms: [{ text: 'Sam Carter' }, { text: 'Carter, Sam' }],
      emails: [{ address: 'sam@example.com', state: 'verified' }, { address: 'old@example.com', state: 'rejected' }],
      directory: { jobTitle: 'Staff Engineer', department: 'Platform' },
    },
    { id: 'id-dana', displayName: 'Dana Lee', forms: [{ text: 'Dana Lee' }], doNotProfile: true },
    { id: 'id-old', displayName: 'Sam C', mergedInto: 'id-sam' },
  ],
};

const read = (person: string, name: string) => ({
  person, updated: '2026-11-01T00:00:00Z', calls: 3, oneCall: 0,
  traits: [{ statement: `${name} asks for the answer first.`, supportCalls: 3 }],
  card: { headline: 'Answer first', lines: [{ kind: 'open', text: 'Open with the answer.' }] },
});

const view = (id: string, start: string, persons: { id: string; name: string }[], items: { task: string; owner?: string; text: string; ownerId?: string }[] = []) => ({
  id, title: `Sync ${id}`, start, end: start, tags: [], people: persons.map((p) => p.name), persons, attendees: [], topics: [], decisions: [],
  actionItems: items, timeZone: 'America/Chicago',
});

async function setUp(config: Record<string, string> = {}) {
  const w = fakeEnv();
  const types: Record<string, string> = { people: 'People', personas: 'Personas', 'next-time': 'NextTime', commitments: 'Commitments', 'coach-profile': 'CoachProfile' };
  const put = async (name: string, body: unknown) => {
    await w.files.put(`records/${name}/data`, JSON.stringify(body));
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, ?, '{}', '["data"]',
      (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, '2026-11-10T00:00:00Z')`).bind(name, types[name] ?? 'Chat').run();
  };
  await put('people', people);
  await put('personas', { version: 1, personas: [read('id-sam', 'Sam'), read('id-dana', 'Dana')] });
  await put('next-time', {
    version: 1, answers: [], checked: [], points: [
      { id: 'p1', text: 'Ask about hiring', personID: 'id-old', personName: 'Sam Carter', rank: 1, created: '2026-11-01T00:00:00Z' },
      { id: 'p2', text: 'Thank Sam', personID: 'id-sam', personName: 'Sam Carter', rank: 2, created: '2026-11-01T00:00:00Z',
        done: { callID: 'm1', at: 65, quote: 'thanks for the demo', date: '2026-11-03T00:00:00Z', byOwner: false } },
      { id: 'p3', text: 'Budget numbers', seriesID: 'cal:w', seriesTitle: 'Weekly sync', rank: 1, created: '2026-11-01T00:00:00Z', carried: ['m1'] },
    ],
  });
  await put('commitments', { items: [{ id: 't1', text: 'Send the forecast', to: 'Sam Carter', toID: 'id-sam', due: '2099-01-01T00:00:00Z', madeAt: '2026-11-01T00:00:00Z' }] });
  await put('coach-profile', { facts: [{ kind: 'role', text: 'Head of data' }], guidance: [{ text: 'Be blunt.' }], people: { 'Sam Carter': { note: 'Wants the decision first.' } } });
  await put('chat-AAAAAAAA-0000-0000-0000-000000000001', { id: 'AAAAAAAA-0000-0000-0000-000000000001', title: 'Budget prep', updated: '2026-11-02T00:00:00Z', summary: 'Planned the pitch.', messages: [{ role: 'user', text: 'How do I pitch two hires?' }, { role: 'assistant', text: 'Lead with the cost.' }] });
  await w.files.put('records/m1/coach', JSON.stringify({ headline: 'Strong open', overview: 'O', strengths: [{ title: 'Framed the goal', observation: 'Opened with it.', quote: 'Let us start' }], improvements: [] }));
  const meetings = [
    view('m1', '2026-11-03T15:00:00Z', [{ id: 'id-owner', name: 'Avery Webb' }, { id: 'id-sam', name: 'Sam Carter' }],
      [{ task: 'Send the vendor list', owner: 'Sam Carter', text: 'Sam Carter: Send the vendor list', ownerId: 'id-sam' }]),
    view('m2', '2026-11-04T15:00:00Z', [{ id: 'id-dana', name: 'Dana Lee' }]),
  ];
  for (const m of meetings) await w.env.DB.prepare('INSERT INTO meetings (id, start, view) VALUES (?, ?, ?)').bind(m.id, Date.parse(m.start), JSON.stringify(m)).run();
  for (const [k, v] of Object.entries({ owner: 'Avery Webb', timeZone: 'America/Chicago', ...config })) {
    await w.env.DB.prepare('INSERT INTO config (key, value) VALUES (?, ?)').bind(k, v).run();
  }
  await w.env.DB.prepare(`INSERT INTO shares (id, title, created, expires, views, viewers, pin_hash) VALUES ('${'a'.repeat(64)}', 'Budget review', '2026-11-01T00:00:00Z', NULL, 5, 2, 'pbkdf2-sha256$1$salt$hash')`).run();
  return w;
}

async function call(w: Awaited<ReturnType<typeof setUp>>, name: string, args: Record<string, unknown> = {}) {
  const res = await handleMCP(new Request('https://mcp.example.com/mossad', { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) }), w.env);
  const body = (await res.json()) as { result: { content: { text: string }[]; structuredContent?: { results?: { id: string }[] } } };
  return body.result;
}

const text = async (w: Awaited<ReturnType<typeof setUp>>, name: string, args: Record<string, unknown> = {}) => (await call(w, name, args)).content[0].text;

describe('the owner tools of the server MCP', () => {
  it('lists every tool as a read', async () => {
    const w = await setUp();
    const res = await handleMCP(new Request('https://mcp.example.com/mossad', { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) }), w.env);
    const tools = ((await res.json()) as { result: { tools: { name: string; annotations: { readOnlyHint: boolean } }[] } }).result.tools;
    for (const name of ['people', 'read_person', 'next_time_points', 'commitments', 'coach_profile', 'read_coach_review', 'past_chats', 'read_chat', 'shares', 'search', 'fetch']) {
      expect(tools.map((t) => t.name)).toContain(name);
    }
    expect(tools.every((t) => t.annotations.readOnlyHint)).toBe(true);
    expect(tools.map((t) => t.name)).not.toContain('add_next_time_point');
  });

  it('reads one person on a sure match only, with their meetings, points, items, and your promises', async () => {
    const w = await setUp();
    for (const q of ['id-sam', 'sam@example.com', 'Sam Carter', 'Carter, Sam', 'id-old']) {
      expect(await text(w, 'read_person', { person: q })).toContain('person_id: id-sam | Sam Carter');
    }
    expect(await text(w, 'read_person', { person: 'Sam' })).toMatch(/^No saved person is surely/);
    expect(await text(w, 'read_person', { person: 'old@example.com' })).toMatch(/^No saved person is surely/);
    const sam = await text(w, 'read_person', { person: 'Sam Carter' });
    expect(sam).toContain('Staff Engineer · Platform');
    expect(sam).toContain('call_id: m1');
    expect(sam).not.toContain('call_id: m2');
    expect(sam).toContain('Ask about hiring (point_id: p1)');
    expect(sam).not.toContain('Thank Sam');
    expect(sam).toContain('Send the vendor list');
    expect(sam).toContain('Send the forecast (task_id: t1)');
    expect(sam).not.toContain('old@example.com');
  });

  it('gives the read of how a person thinks only when the Mac allows it, and never for a person who keeps none', async () => {
    const off = await setUp();
    expect(await text(off, 'read_person', { person: 'id-sam' })).not.toContain('asks for the answer first');
    const on = await setUp({ mcpPersonas: '1' });
    const sam = await text(on, 'read_person', { person: 'id-sam' });
    expect(sam).toContain('How to present to Sam: Open with: Open with the answer.');
    expect(sam).toContain('Sam asks for the answer first. (seen in 3 calls)');
    expect(await text(on, 'read_person', { person: 'id-dana' })).not.toContain('asks for the answer first');
  });

  it('takes the switch from the Mac in its config', async () => {
    const w = await setUp();
    const res = await handleAPI(new Request('https://notes.example.com/api/config', {
      method: 'PUT', headers: { Authorization: 'Bearer owner-secret', 'Content-Type': 'application/json' }, body: JSON.stringify({ owner: 'Avery Webb', mcpPersonas: true }),
    }), w.env);
    expect(res.status).toBe(200);
    expect(await text(w, 'read_person', { person: 'id-sam' })).toContain('asks for the answer first');
    // The time of the Mac's last full send is kept; a date that does not parse is not.
    const put = (body: unknown) => handleAPI(new Request('https://notes.example.com/api/config', {
      method: 'PUT', headers: { Authorization: 'Bearer owner-secret', 'Content-Type': 'application/json' }, body: JSON.stringify(body) }), w.env);
    await put({ owner: 'Avery Webb', syncedAt: 'not a date' });
    expect(await w.env.DB.prepare("SELECT value FROM config WHERE key = 'syncedAt'").first()).toBeNull();
    await put({ owner: 'Avery Webb', syncedAt: '2026-10-01T12:00:00Z' });
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES ('m1', 'Meeting', '{}', '["view"]', 99, 0, '2026-11-12T00:00:00Z')`).run();
    expect(await text(w, 'commitments')).toContain('Your Mac last sent these on Oct 1, 2026');
  });

  it('lists the people, the points, and the tasks', async () => {
    const w = await setUp();
    const list = await text(w, 'people');
    expect(list).toContain('Sam Carter | person_id: id-sam | Staff Engineer · Platform | 1 meetings');
    expect(list).not.toContain('Avery Webb');
    expect(list).not.toContain('Sam C |');
    expect(await text(w, 'next_time_points')).toContain('Budget numbers (point_id: p3, for the next Weekly sync');
    expect(await text(w, 'next_time_points')).toContain('carried over 1 meeting');
    const done = await text(w, 'next_time_points', { status: 'done', person: 'Sam Carter' });
    expect(done).toContain('discussed in call_id m1 at 00:01:05');
    expect(done).toContain('"thanks for the demo"');
    expect(await text(w, 'commitments')).toContain('Send the forecast (task_id: t1) (to Sam Carter) | due');
  });

  it('reads the coach, the chats, and the shares, never a PIN', async () => {
    const w = await setUp({ mcpPersonas: '1' });
    expect(await text(w, 'coach_profile')).toContain('Head of data');
    expect(await text(w, 'coach_profile')).toContain('Sam Carter: Wants the decision first.');
    expect(await text(w, 'read_coach_review', { call_id: 'm1' })).toContain('Strength: Framed the goal');
    expect(await text(w, 'past_chats')).toContain('chat_id: AAAAAAAA-0000-0000-0000-000000000001');
    expect(await text(w, 'read_chat', { chat_id: 'aaaaaaaa-0000-0000-0000-000000000001' })).toContain('Avery Webb: How do I pitch two hires?');
    const shares = await text(w, 'shares');
    expect(shares).toContain('Budget review');
    expect(shares).toContain('PIN on');
    expect(shares).toContain('5 views by 2 people');
    expect(shares).not.toContain('pbkdf2');
    expect(shares).not.toContain('a'.repeat(64));
  });

  it('searches and fetches people and tasks beside the meetings', async () => {
    const w = await setUp();
    const found = await call(w, 'search', { query: 'Sam' });
    const ids = found.structuredContent?.results?.map((r) => r.id) ?? [];
    expect(ids).toContain('person:id-sam');
    const tasks = (await call(w, 'search', { query: 'forecast' })).structuredContent?.results?.map((r) => r.id) ?? [];
    expect(tasks).toContain('task:t1');
    expect(await text(w, 'fetch', { id: 'person:id-sam' })).toContain('person_id: id-sam');
    expect(await text(w, 'fetch', { id: 'task:t1' })).toContain('Send the forecast');
    expect(await text(w, 'fetch', { id: 'meeting:m1' })).toContain('Sync m1');
    expect(await text(w, 'fetch', { id: 'm1' })).toContain('Sync m1');
  });
});
