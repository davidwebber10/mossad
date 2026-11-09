import { describe, expect, it } from 'vitest';
import { indexMeeting } from '../src/api';
import { callIDDay, maxSearchLines, toolsFor } from '../src/mcp';
import type { Env, MeetingView } from '../src/types';

interface Row { call_id: string; at: number; speaker: string; text: string }

/** A D1 stand-in that keeps the statements it was given, and answers the three queries the MCP makes. */
function fakeEnv(views: Omit<MeetingView, 'lines'>[], lines: Row[]) {
  const statements: { sql: string; params: unknown[] }[] = [];
  const batches: number[] = [];
  const prepare = (sql: string) => {
    const statement = {
      sql, params: [] as unknown[],
      bind(...params: unknown[]) { statement.params = params; return statement; },
      async all() {
        statements.push({ sql, params: statement.params });
        if (sql.includes('FROM config')) return { results: [{ key: 'owner', value: 'Dana' }] };
        if (sql.includes('FROM meetings')) return { results: views.map((v) => ({ view: JSON.stringify(v) })) };
        if (sql.includes('FROM lines WHERE call_id')) return { results: lines.filter((l) => l.call_id === statement.params[0]) };
        if (sql.includes('FROM lines')) {
          const params = [...statement.params];
          const q = String(params.shift()).toLowerCase();
          const limit = Number(params.pop());
          const after = sql.includes('call_id >= ?') ? String(params.shift()) : '';
          const before = sql.includes('call_id < ?') ? String(params.shift()) : '\uffff';
          return { results: lines.filter((l) => l.text.toLowerCase().includes(q) && l.call_id >= after && l.call_id < before).slice(0, limit) };
        }
        return { results: [] };
      },
    };
    return statement;
  };
  const env = {
    DB: { prepare, async batch(list: { sql: string; params: unknown[] }[]) { batches.push(list.length); statements.push(...list.map((s) => ({ sql: s.sql, params: s.params }))); } },
    FILES: { async get() { return null as unknown; } },
  };
  return { env: env as unknown as Env, statements, batches, files: env.FILES };
}

const view = (id: string, start: string) => ({
  id, title: `Budget ${id}`, start, end: start, tags: [], people: ['Dana', 'Jennifer Lee'], attendees: [], topics: [], decisions: [],
  actionItems: [], timeZone: 'America/Chicago',
});

describe('search over many meetings', () => {
  const views = [view('20261105-090000', '2026-11-05T15:00:00Z'), view('20261103-090000', '2026-11-03T15:00:00Z')];
  const lines: Row[] = [
    { call_id: '20261103-090000', at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' },
    { call_id: '20261103-090000', at: 70, speaker: 'Dana', text: 'Agreed.' },
    { call_id: '20261105-090000', at: 12, speaker: 'Dana', text: 'Hiring is on hold.' },
  ];

  it('asks the database for the matching lines only, with a limit', async () => {
    const { env, statements } = fakeEnv(views, lines);
    const tools = await toolsFor(env, 'search_transcripts', { query: 'Numbers' });
    const out = tools.run('search_transcripts', { query: 'Numbers' });
    expect(out).toContain('call_id: 20261103-090000');
    expect(out).toContain('I need the numbers by Friday.');
    const lineQueries = statements.filter((s) => s.sql.includes('FROM lines'));
    expect(lineQueries).toHaveLength(1);
    expect(lineQueries[0].sql).toContain('WHERE instr(lower(text), lower(?)) > 0');
    expect(lineQueries[0].sql).toContain('LIMIT ?');
    expect(lineQueries[0].params).toEqual(['Numbers', maxSearchLines]);
  });

  it('limits the lines to the date range in the database, so the cap cannot hide an old meeting', async () => {
    const { env, statements } = fakeEnv(views, lines);
    const args = { query: 'the', from: '2026-11-03', to: '2026-11-03' };
    const tools = await toolsFor(env, 'search_transcripts', args);
    expect(tools.run('search_transcripts', args)).toContain('call_id: 20261103-090000');
    const q = statements.find((s) => s.sql.includes('FROM lines'))!;
    expect(q.sql).toContain('AND call_id >= ? AND call_id < ?');
    expect(q.params).toEqual(['the', '20261102', '20261105', maxSearchLines]);
    expect(callIDDay('nope', 0)).toBeNull();
  });

  it('finds meetings by a word in the transcript, and reads no lines without a query', async () => {
    const found = fakeEnv(views, lines);
    const tools = await toolsFor(found.env, 'find_meetings', { query: 'hiring' });
    expect(tools.run('find_meetings', { query: 'hiring' })).toContain('call_id: 20261105-090000');
    expect(tools.run('find_meetings', { query: 'hiring' })).not.toContain('call_id: 20261103-090000');

    const plain = fakeEnv(views, lines);
    await toolsFor(plain.env, 'find_meetings', {});
    await toolsFor(plain.env, 'find_meetings', { query: '#Budget' });
    expect(plain.statements.filter((s) => s.sql.includes('FROM lines'))).toHaveLength(0);
  });

  it('reads one meeting with only that meeting\'s lines', async () => {
    const { env, statements } = fakeEnv(views, lines);
    const tools = await toolsFor(env, 'read_meeting', { call_id: '20261103-090000' });
    expect(tools.run('read_meeting', { call_id: '20261103-090000' })).toContain('Agreed.');
    expect(statements.filter((s) => s.sql.includes('FROM lines')).map((s) => s.params)).toEqual([['20261103-090000']]);
  });
});

describe('indexing a meeting', () => {
  it('writes a long meeting in one batch, so a failure cannot leave half of it', async () => {
    const { env, batches, files, statements } = fakeEnv([], []);
    const meeting = { ...view('m1', '2026-11-03T15:00:00Z'), lines: Array.from({ length: 1500 }, (_, i) => ({ at: i, speaker: 'Dana', text: `line ${i}` })) };
    (files as { get: unknown }).get = async () => ({ json: async () => meeting });
    await indexMeeting(env, 'm1');
    expect(batches).toEqual([2 + 60]);
    const inserts = statements.filter((s) => s.sql.startsWith('INSERT INTO lines'));
    expect(inserts[0].params).toHaveLength(100);
    expect(inserts.flatMap((s) => s.params).filter((p) => typeof p === 'string' && p.startsWith('line ')).length).toBe(1500);
  });
});
