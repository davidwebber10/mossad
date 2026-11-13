import { MeetingTools, toolDefinitions as meetingToolDefinitions } from './tools';
import { OwnerData, chats, coachProfileText, coachReviewText, ownerToolDefinitions, ownerToolNames, pastChatsText, readChatText, sharesText } from './owner';
import type { Env, Line, MeetingView } from './types';

/** A stateless Streamable HTTP MCP server: each POST is one JSON-RPC message and gets one JSON reply. */

const fallbackVersion = '2025-06-18';

/** The meeting tools, then the reads of what else the Mac syncs. All read only. */
export const toolDefinitions = [...meetingToolDefinitions, ...ownerToolDefinitions];

export async function config(env: Env): Promise<Record<string, string>> {
  const { results } = await env.DB.prepare('SELECT key, value FROM config').all<{ key: string; value: string }>();
  return Object.fromEntries(results.map((r) => [r.key, r.value]));
}

/** The most transcript lines one search reads. A year of meetings is half a million lines; a search must not load them all. */
export const maxSearchLines = 4000;

/**
 * The meetings without transcripts, or with only the transcript lines that contain `query`. The database does the
 * search, so the Worker never holds every line of every meeting. The tools then see the same lines they would have
 * found themselves.
 */
/** "2026-11-03" moved by some days, as the start of a call id ("20261103"); null when it is not a date. */
export function callIDDay(day: unknown, shift: number): string | null {
  if (typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return null;
  const t = Date.parse(`${day}T00:00:00Z`);
  return Number.isNaN(t) ? null : new Date(t + shift * 86_400_000).toISOString().slice(0, 10).replaceAll('-', '');
}

export async function meetings(env: Env, query?: string, from?: unknown, to?: unknown): Promise<MeetingView[]> {
  const { results } = await env.DB.prepare('SELECT view FROM meetings ORDER BY start DESC').all<{ view: string }>();
  const views = results.map((r) => ({ ...(JSON.parse(r.view) as Omit<MeetingView, 'lines'>), lines: [] as Line[] }));
  const q = query?.trim() ?? '';
  // A "#tag" query reads tags only.
  if (!q || q.startsWith('#') || !views.length) return views;
  // A call id starts with its date, so a date range limits the lines in the database: the cap then counts only
  // lines of that range, and a common word in an old range is still found. One day of room on each side covers
  // the time zone; the tools apply the exact range after.
  const after = callIDDay(from, -1), before = callIDDay(to, 2);
  const range = (after ? ' AND call_id >= ?' : '') + (before ? ' AND call_id < ?' : '');
  // Newest meetings first, so the cap drops the oldest hits.
  const { results: lines } = await env.DB.prepare(
    `SELECT call_id, at, speaker, text FROM lines WHERE instr(lower(text), lower(?)) > 0${range} ORDER BY call_id DESC, at LIMIT ?`)
    .bind(...[q, after, before].filter((v): v is string => v !== null), maxSearchLines).all<{ call_id: string; at: number; speaker: string; text: string }>();
  const byID = new Map(views.map((v) => [v.id, v]));
  for (const l of lines) byID.get(l.call_id)?.lines.push({ at: l.at, speaker: l.speaker, text: l.text });
  return views;
}

async function linesFor(env: Env, id: string): Promise<Line[]> {
  const { results } = await env.DB.prepare('SELECT at, speaker, text FROM lines WHERE call_id = ? ORDER BY at').bind(id).all<Line>();
  return results;
}

export async function toolsFor(env: Env, name: string, args: Record<string, unknown>): Promise<MeetingTools> {
  const c = await config(env);
  // Transcript lines are the big part: only the lines that match the query are read, and only for the tools that search.
  const searches = name === 'search_transcripts' || name === 'search' || name === 'find_meetings';
  const query = searches && typeof args.query === 'string' ? args.query.trim() : '';
  const list = await meetings(env, query, args.from, args.to);
  const id = typeof args.call_id === 'string' ? args.call_id : typeof args.id === 'string' ? args.id : '';
  if (!query && id) {
    const m = list.find((v) => v.id === id);
    if (m) m.lines = await linesFor(env, id);
  }
  return new MeetingTools(list, c.owner ?? 'the owner', c.timeZone);
}

/** The tools over the owner's synced data: people, points, tasks, the coach, chats, and shares. */
export async function runOwnerTool(env: Env, name: string, args: Record<string, unknown>): Promise<string> {
  const c = await config(env);
  const tz = c.timeZone ?? 'UTC';
  switch (name) {
    case 'coach_profile': return coachProfileText(env);
    case 'read_coach_review': return coachReviewText(env, args.call_id);
    case 'past_chats': return pastChatsText(await chats(env), args, tz);
    case 'read_chat': return readChatText(await chats(env), args.chat_id, c.owner ?? 'the owner');
    case 'shares': return sharesText(env, args, tz);
  }
  const owner = await OwnerData.load(env, await meetings(env), c);
  switch (name) {
    case 'people': return owner.peopleText(args);
    case 'read_person': return owner.readPerson(args);
    case 'next_time_points': return owner.pointsText(args);
    case 'commitments': return owner.commitmentsText(args);
    default: return `Unknown tool ${name}.`;
  }
}

type RPC = { jsonrpc?: string; id?: string | number | null; method?: string; params?: Record<string, unknown> };

export async function handleMCP(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: { Allow: 'POST' } });
  let message: RPC;
  try { message = await request.json(); } catch {
    return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
  }
  if (message.id === undefined || message.id === null) return new Response(null, { status: 202 });
  const params = message.params ?? {};
  const reply = (result: unknown) => Response.json({ jsonrpc: '2.0', id: message.id, result });
  switch (message.method) {
    case 'initialize': {
      const c = await config(env);
      return reply({
        protocolVersion: typeof params.protocolVersion === 'string' ? params.protocolVersion : fallbackVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'mossad', version: '1.0' },
        instructions: `Search and read ${c.owner ?? 'the owner'}'s recorded meetings (transcripts, summaries, decisions, and action items), the people in them (read_person), their tasks, points for next time, the coach's notes, and earlier chats. Read a meeting before saying what someone agreed to.`,
      });
    }
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({ tools: toolDefinitions });
    case 'tools/call': {
      const name = typeof params.name === 'string' ? params.name : '';
      const args = (params.arguments as Record<string, unknown>) ?? {};
      if (!toolDefinitions.some((t) => t.name === name)) return reply({ content: [{ type: 'text', text: `Unknown tool ${name}.` }], isError: true });
      if (ownerToolNames.has(name)) return reply({ content: [{ type: 'text', text: await runOwnerTool(env, name, args) }] });
      const id = typeof args.id === 'string' ? args.id : '';
      // A kind prefix: "person:<id>" and "task:<id>" are the owner's data; "meeting:<id>" and a bare id are meetings.
      const meetingArgs = name === 'fetch' && id.startsWith('meeting:') ? { ...args, id: id.slice(8) } : args;
      const tools = await toolsFor(env, name, meetingArgs);
      if (name === 'search') {
        const query = typeof args.query === 'string' ? args.query : '';
        const owner = await OwnerData.load(env, tools.meetings, await config(env));
        const result = { results: [...tools.search(query).results, ...owner.search(query)] };
        return reply({ content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result });
      }
      if (name === 'fetch') {
        const doc = id.startsWith('person:') || id.startsWith('task:')
          ? (await OwnerData.load(env, tools.meetings, await config(env))).fetch(id)
          : tools.fetch(typeof meetingArgs.id === 'string' ? meetingArgs.id : '');
        if (!doc) return reply({ content: [{ type: 'text', text: 'Nothing with that id.' }], isError: true });
        return reply({ content: [{ type: 'text', text: JSON.stringify(doc) }], structuredContent: doc });
      }
      return reply({ content: [{ type: 'text', text: tools.run(name, args) }] });
    }
    default:
      return Response.json({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } });
  }
}
