import { describe, expect, it } from 'vitest';
import { handleMCP } from '../src/mcp';
import { fakeEnv } from './fakes';
import { fixture } from './fixtures.mjs';

/**
 * The review's server findings: nothing the coach learned about a person who keeps no read (R1), honest answers when
 * a kind never arrived or is old (R2), lists that say they were cut (R8), two people with one name (R10), what "N
 * meetings" counts (R11), no 500 from a bad date or zone (R12), and the payloads as the Mac writes them (R9).
 */

type W = ReturnType<typeof fakeEnv>;
const at = (iso: string) => iso;

async function base(opts: { config?: Record<string, string>; skip?: string[]; updated?: Record<string, string>; migrations?: number } = {}) {
  const w = fakeEnv({}, opts.migrations ?? Infinity);
  const rec = async (name: string, type: string, body: unknown) => {
    if (opts.skip?.includes(name)) return;
    await w.files.put(`records/${name}/data`, JSON.stringify(body));
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, ?, '{}', '["data"]',
      (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, ?)`).bind(name, type, opts.updated?.[name] ?? '2026-11-12T00:00:00Z').run();
  };
  await rec('people', 'People', {
    people: [
      { id: 'id-owner', displayName: 'Avery Webb', isOwner: true },
      { id: 'id-sam', displayName: 'Sam Carter', emails: [{ address: 'sam@example.com', state: 'verified' }] },
      { id: 'ID-SAM2', displayName: 'Sam Carter', emails: [{ address: 'sam2@example.com', state: 'verified' }] },
      { id: 'id-dana', displayName: 'Dana Lee', doNotProfile: true },
      { id: 'id-dana-old', displayName: 'D. Lee', mergedInto: 'id-dana' },
    ],
  });
  await rec('personas', 'Personas', { personas: [{ person: 'id-dana-old', traits: [{ statement: 'Dana READ' }] }, { person: 'id-sam', traits: [{ statement: 'Sam READ' }] }] });
  await rec('coach-profile', 'CoachProfile', {
    facts: [{ kind: 'role', text: 'Head of data' }, { kind: 'relationship', text: 'Dana FACT', person: 'id-dana' }],
    guidance: [{ text: 'Dana GUIDE', person: 'id-dana-old' }],
    people: { 'Dana Lee': { note: 'Dana NOTE' }, 'Old name': { note: 'Dana NOTE BY ID', person: 'id-dana' }, 'Sam Carter': { note: 'Sam NOTE', person: 'id-sam' } },
  });
  await rec('commitments', 'Commitments', { items: Array.from({ length: 35 }, (_, i) => ({ id: `T-${i}`, text: `Task ${i}`, madeAt: '2026-11-01T00:00:00Z' })) });
  await rec('next-time', 'NextTime', { points: [] });
  for (let i = 0; i < 61; i++) {
    const id = `00000000-0000-0000-0000-${String(i).padStart(12, '0')}`.toUpperCase();
    await rec(`chat-${id}`, 'Chat', { id, title: `Chat ${i}`, updated: `2026-10-${String(1 + (i % 28)).padStart(2, '0')}T00:00:00Z`, messages: [{ role: 'user', text: 'x'.repeat(i === 0 ? 200_000 : 10) }] });
  }
  const meeting = (id: string, start: string, persons?: { id: string; name: string }[]) => ({
    id, title: `Sync ${id}`, start, end: start, tags: [], people: [], ...(persons ? { persons } : {}), attendees: [], topics: [], decisions: [], actionItems: [],
  });
  for (const m of [meeting('m1', '2026-11-12T15:00:00Z', [{ id: 'id-sam', name: 'Sam Carter' }]), meeting('m0', '2026-11-01T15:00:00Z')]) {
    await w.env.DB.prepare('INSERT INTO meetings (id, start, view) VALUES (?, ?, ?)').bind(m.id, Date.parse(m.start), JSON.stringify(m)).run();
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, 'Meeting', '{}', '["view"]',
      (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, ?)`).bind(m.id, opts.updated?.meetings ?? '2026-11-12T16:00:00Z').run();
  }
  for (const [k, v] of Object.entries({ owner: 'Avery Webb', timeZone: 'America/Chicago', ...(opts.config ?? {}) })) {
    await w.env.DB.prepare('INSERT INTO config (key, value) VALUES (?, ?)').bind(k, v).run();
  }
  return w;
}

async function text(w: W, name: string, args: Record<string, unknown> = {}) {
  const res = await handleMCP(new Request('https://mcp.example.com/mossad', { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) }), w.env);
  expect(res.status).toBe(200);
  return ((await res.json()) as { result: { content: { text: string }[] } }).result.content[0].text;
}

describe('R1: what the coach learned about a person who keeps no read', () => {
  it('never leaves the server, by name, by id, or by an id merged away', async () => {
    const out = await text(await base({ config: { mcpPersonas: '1' } }), 'coach_profile');
    expect(out).toContain('Head of data');
    expect(out).toContain('Sam NOTE');
    for (const word of ['Dana NOTE', 'Dana FACT', 'Dana GUIDE']) expect(out).not.toContain(word);
  });

  it('gives no notes on people without the people file, or with the switch off', async () => {
    expect(await text(await base({ config: { mcpPersonas: '1' }, skip: ['people'] }), 'coach_profile')).not.toContain('NOTE');
    const off = await text(await base(), 'coach_profile');
    expect(off).not.toContain('NOTE');
    expect(off).toContain('Head of data');
  });

  it('gives no read of a person merged into one who keeps none', async () => {
    const w = await base({ config: { mcpPersonas: '1' } });
    expect(await text(w, 'read_person', { person: 'id-dana' })).not.toContain('Dana READ');
    expect(await text(w, 'read_person', { person: 'sam@example.com' })).toContain('Sam READ');
  });
});

describe('R2: unknown is not false', () => {
  it('says plainly when the Mac never sent a kind', async () => {
    const w = await base({ skip: ['people', 'commitments', 'next-time', 'coach-profile', 'personas'] });
    expect(await text(w, 'commitments')).toMatch(/^This server has no tasks from your Mac yet/);
    expect(await text(w, 'people')).toMatch(/^This server has no people from your Mac yet/);
    expect(await text(w, 'next_time_points')).toMatch(/^This server has no points for next time from your Mac yet/);
    expect(await text(w, 'coach_profile')).toMatch(/^This server has no coach memory from your Mac yet/);
  });

  it('gives the date of a copy that is older than the newest meeting', async () => {
    const w = await base({ updated: { commitments: '2026-10-01T12:00:00Z' } });
    const old = await text(w, 'commitments');
    expect(old.slice(-200)).toContain('This copy is from Oct 1, 2026');
    expect(await text(w, 'people')).not.toContain('This copy is from');
  });

  it('gives no read when the reads are newer than the people file that says who keeps none', async () => {
    const w = await base({ config: { mcpPersonas: '1' }, updated: { personas: '2026-11-11T00:00:00Z', people: '2026-11-10T00:00:00Z' } });
    expect(await text(w, 'read_person', { person: 'sam@example.com' })).not.toContain('Sam READ');
  });
});

describe('R8, R10, R11, R12: lists, names, counts, and dates', () => {
  it('says how many more a list has, and takes an offset', async () => {
    const w = await base();
    const first = await text(w, 'commitments', { limit: 30 });
    expect(first).toContain('(5 more; ask with offset 30.)');
    const next = await text(w, 'commitments', { limit: 30, offset: 30 });
    expect(next.split('\n').filter((l) => l.startsWith('- '))).toHaveLength(5);
    for (const limit of [0, -1, 'x', 1000]) expect(await text(w, 'commitments', { limit })).toContain('Task 0');
  });

  it('reads a chat beyond the newest 60 by its id in any case, with a size limit', async () => {
    const w = await base();
    const old = '00000000-0000-0000-0000-000000000027';
    expect(await text(w, 'read_chat', { chat_id: old })).toContain('Chat 27');
    const long = await text(w, 'read_chat', { chat_id: '00000000-0000-0000-0000-000000000000' });
    expect(long.length).toBeLessThan(170_000);
    expect(long).toContain('(The chat is cut here.)');
  });

  it('lists the people two names fit, never one of them', async () => {
    const out = await text(await base(), 'read_person', { person: 'Sam Carter' });
    expect(out).toContain('Several saved people fit');
    expect(out).toContain('person_id: id-sam');
    expect(out).toContain('person_id: ID-SAM2');
    expect(await text(await base(), 'read_person', { person: 'id-sam2' })).toContain('person_id: ID-SAM2');
  });

  it('says what a count of meetings holds, and not known without ids', async () => {
    const w = await base();
    expect(await text(w, 'people', { query: 'sam@example.com' })).toContain('1 meetings (spoke or invited)');
    const old = fakeEnv();
    await old.files.put('records/people/data', JSON.stringify({ people: [{ id: 'id-sam', displayName: 'Sam Carter' }] }));
    await old.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES ('people', 'People', '{}', '["data"]', 1, 0, '2026-11-10T00:00:00Z')`).run();
    const m = { id: 'm9', title: 'Old', start: '2026-11-01T00:00:00Z', end: '2026-11-01T00:00:00Z', tags: [], people: ['Sam Carter'], attendees: [], topics: [], decisions: [], actionItems: [] };
    await old.env.DB.prepare('INSERT INTO meetings (id, start, view) VALUES (?, ?, ?)').bind('m9', 0, JSON.stringify(m)).run();
    expect(await text(old, 'people')).toContain('meetings not known');
  });

  it('answers with a bad time zone in the config', async () => {
    const w = await base({ config: { timeZone: 'Not/AZone' } });
    expect(await text(w, 'commitments')).toContain('Task 0');
    expect(await text(w, 'past_chats')).toContain('chat_id');
  });

  it('says the shares cannot be read on a database from before migration 2', async () => {
    expect(await text(await base({ migrations: 1 }), 'shares')).toContain('cannot be read on this server yet');
  });

  it('answers people quickly with many people and meetings', async () => {
    const w = fakeEnv();
    const list = Array.from({ length: 300 }, (_, i) => ({ id: `p${i}`, displayName: `Person ${i}` }));
    await w.files.put('records/people/data', JSON.stringify({ people: list }));
    await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES ('people', 'People', '{}', '["data"]', 1, 0, '2026-11-10T00:00:00Z')`).run();
    for (let i = 0; i < 1500; i++) {
      const m = { id: `m${i}`, title: 'x', start: at('2026-11-01T00:00:00Z'), end: at('2026-11-01T00:00:00Z'), tags: [], people: [], attendees: [], topics: [], decisions: [], actionItems: [],
        persons: [0, 1, 2, 3].map((k) => ({ id: `p${(i + k * 7) % 300}`, name: 'x' })) };
      await w.env.DB.prepare('INSERT INTO meetings (id, start, view) VALUES (?, ?, ?)').bind(m.id, i, JSON.stringify(m)).run();
    }
    const started = performance.now();
    await text(w, 'people');
    expect(performance.now() - started).toBeLessThan(300);
  });
});

describe('R9: the payloads as the Mac writes them', () => {

  it('reads the people, the reads, the points, the tasks, the coach, and a chat that Swift encoded', async () => {
    const w = fakeEnv();
    const put = async (name: string, type: string, body: unknown) => {
      await w.files.put(`records/${name}/data`, JSON.stringify(body));
      await w.env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated) VALUES (?, ?, '{}', '["data"]',
        (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, '2026-11-10T00:00:00Z')`).bind(name, type).run();
    };
    const chat = fixture('chat');
    await put('people', 'People', fixture('people'));
    await put('personas', 'Personas', fixture('personas'));
    await put('next-time', 'NextTime', fixture('next-time'));
    await put('commitments', 'Commitments', fixture('commitments'));
    await put('coach-profile', 'CoachProfile', fixture('coach-profile'));
    await put(`chat-${chat.id}`, 'Chat', chat);
    await w.env.DB.prepare("INSERT INTO config (key, value) VALUES ('mcpPersonas', '1')").run();
    const sam = await text(w, 'read_person', { person: 'sam@example.com' });
    expect(sam).toContain('person_id: id-sam | Sam Carter | Staff Engineer · Platform');
    expect(sam).toContain('Sam asks for the answer first. (seen in 6 calls)');
    expect(sam).toContain('Ask about hiring');
    expect(sam).toContain('Send the forecast');
    expect(await text(w, 'coach_profile')).toContain('Head of data');
    expect(await text(w, 'coach_profile')).toContain('Sam NOTE');
    expect(await text(w, 'next_time_points', { status: 'all' })).toContain('discussed in call_id c1 at 00:01:05');
    expect(await text(w, 'read_chat', { chat_id: chat.id })).toContain('How do I pitch?');
  });
});
