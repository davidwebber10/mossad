import type { MeetingView } from './types';
import { decisionLine, formatDay, localDayStart, timestamp } from './util';

/** The same rules as ChatTools on the Mac: the AI app sees the same tools and the same text. */

export const defaultLimit = 20;
const maxLimit = 60;
const maxMeetingCharacters = 160_000;

/** "Jen" finds "Jennifer Lee"; "Ray" and "Austin Ray" find "Austin Ray". */
export function nameMatches(query: string, person: string): boolean {
  const q = query.trim().toLowerCase();
  const p = person.toLowerCase();
  if (q.length < 2) return false;
  if (p === q || (p.includes(q) && q.includes(' '))) return true;
  const parts = p.split(' ').filter(Boolean);
  const first = parts[0];
  if (first && (first === q || (q.length >= 3 && first.startsWith(q)))) return true;
  return parts.slice(1).includes(q);
}

const contains = (text: string | undefined, q: string) => (text ?? '').toLowerCase().includes(q.toLowerCase());

export interface Filters {
  query?: string;
  people?: string[];
  from?: string;
  to?: string;
  tag?: string;
  limit?: number;
}

function range(f: Filters, tz: string) {
  const from = f.from ? localDayStart(f.from, tz) : null;
  // "to" is inclusive: up to the start of the next day.
  const toStart = f.to ? localDayStart(f.to, tz) : null;
  const to = toStart === null ? null : localDayStart(new Date(toStart + 36 * 3600_000).toISOString().slice(0, 10), tz);
  return { from, to };
}

export class MeetingTools {
  readonly meetings: MeetingView[];
  readonly tz: string;

  constructor(meetings: MeetingView[], readonly owner: string, timeZone?: string) {
    this.meetings = [...meetings].sort((a, b) => b.start.localeCompare(a.start));
    this.tz = timeZone ?? meetings.find((m) => m.timeZone)?.timeZone ?? 'UTC';
  }

  private matchesSearch(m: MeetingView, q: string): boolean {
    if (q.startsWith('#')) {
      const tag = q.slice(1).trim().toLowerCase();
      return m.tags.some((t) => t.toLowerCase() === tag);
    }
    return contains(m.title, q) || m.tags.some((t) => contains(t, q)) || contains(m.summary, q) || m.lines.some((l) => contains(l.text, q));
  }

  find(f: Filters): MeetingView[] {
    const { from, to } = range(f, this.tz);
    const q = f.query?.trim() ?? '';
    const names = f.people ?? [];
    const limit = Math.min(f.limit ?? defaultLimit, maxLimit);
    return this.meetings
      .filter((m) => {
        const start = Date.parse(m.start);
        if (from !== null && start < from) return false;
        if (to !== null && start >= to) return false;
        if (f.tag && !m.tags.some((t) => t.toLowerCase() === f.tag!.toLowerCase())) return false;
        // A person id from a person_ids line finds the person under any name.
        if (!names.every((n) => m.persons?.some((p) => p.id === n) || m.people.some((p) => nameMatches(n, p)))) return false;
        return !q || this.matchesSearch(m, q);
      })
      .slice(0, limit);
  }

  header(m: MeetingView): string {
    const minutes = Math.round((Date.parse(m.end) - Date.parse(m.start)) / 60_000);
    let line = `call_id: ${m.id} | ${m.title} | ${formatDay(m.start, this.tz)} | ${minutes} min | people: ${m.people.join(', ')}`;
    if (m.tags.length) line += ` | tags: ${m.tags.join(', ')}`;
    if (m.headline) line += ` | ${m.headline}`;
    return line;
  }

  transcript(m: MeetingView): string {
    return m.lines.map((l) => `[${timestamp(l.at)}] ${l.speaker}: ${l.text}`).join('\n');
  }

  read(id: string): string | null {
    const m = this.meetings.find((x) => x.id === id);
    if (!m) return null;
    const parts = [this.header(m)];
    if (m.attendees.length) parts.push(`Invited: ${m.attendees.join(', ')}`);
    if (m.persons?.length) parts.push(`person_ids: ${m.persons.map((p) => `${p.name}=${p.id}`).join('; ')}`);
    if (m.summary) parts.push(`Summary:\n${m.summary}`);
    for (const t of m.topics) parts.push(`### ${t.title}\n${t.summary}`);
    if (m.decisions.length) parts.push('Decisions:\n' + m.decisions.map((d, i) => `- ${decisionLine(d, m.decisionTimes?.[i])}`).join('\n'));
    if (m.actionItems.length) parts.push('Action items:\n' + m.actionItems.map((a) => `- ${a.text}`).join('\n'));
    const t = this.transcript(m);
    parts.push('Transcript:\n' + t.slice(0, maxMeetingCharacters) +
      (t.length > maxMeetingCharacters ? '\n(Transcript cut here; use search_transcripts for later parts.)' : ''));
    return parts.join('\n\n');
  }

  run(name: string, input: Record<string, unknown>): string {
    const f: Filters = {
      query: typeof input.query === 'string' ? input.query : undefined,
      people: Array.isArray(input.people) ? input.people.filter((p): p is string => typeof p === 'string') : [],
      from: typeof input.from === 'string' ? input.from : undefined,
      to: typeof input.to === 'string' ? input.to : undefined,
      tag: typeof input.tag === 'string' ? input.tag : undefined,
      limit: typeof input.limit === 'number' ? input.limit : undefined,
    };
    switch (name) {
      case 'find_meetings': {
        const found = this.find(f);
        return found.length ? found.map((m) => this.header(m)).join('\n') : 'No meetings match.';
      }
      case 'search_transcripts': {
        const q = f.query?.trim() ?? '';
        if (!q) return 'No transcript lines match.';
        const limit = Math.min(f.limit ?? 30, maxLimit);
        const hits: string[] = [];
        for (const m of this.find({ ...f, query: undefined, limit: maxLimit * 10 })) {
          for (const l of m.lines) {
            if (!contains(l.text, q)) continue;
            hits.push(`call_id: ${m.id} | ${m.title} | ${formatDay(m.start, this.tz)} | [${timestamp(l.at)}] ${l.speaker}: ${l.text}`);
            if (hits.length >= limit) return hits.join('\n');
          }
        }
        return hits.length ? hits.join('\n') : 'No transcript lines match.';
      }
      case 'read_meeting':
        return (typeof input.call_id === 'string' && this.read(input.call_id)) || 'No meeting with that call_id.';
      case 'action_items': {
        const owner = typeof input.owner === 'string' ? input.owner : undefined;
        const items = this.find({ from: f.from, to: f.to, limit: maxLimit * 10 }).flatMap((m) =>
          m.actionItems
            .filter((a) => !owner || (a.owner ? nameMatches(owner, a.owner) : false))
            .map((a) => `call_id: ${m.id} | ${m.title} | ${formatDay(m.start, this.tz)} | ${a.owner ?? 'no owner'}: ${a.task}`));
        return items.length ? items.join('\n') : 'No action items match.';
      }
      default:
        return `Unknown tool ${name}.`;
    }
  }

  /** ChatGPT's search tool: results with an id it passes to fetch. */
  search(query: string) {
    const found = this.find({ query, limit: 20 });
    const results = found.map((m) => ({ id: m.id, title: m.title, url: `mossad://call/${encodeURIComponent(m.id)}` }));
    return { results };
  }

  fetch(id: string) {
    const m = this.meetings.find((x) => x.id === id);
    if (!m) return null;
    return { id: m.id, title: m.title, text: this.read(id) ?? '', url: `mossad://call/${encodeURIComponent(m.id)}`, metadata: { start: m.start, people: m.people.join(', ') } };
  }
}

const filterProps = {
  people: { type: 'array', items: { type: 'string' } },
  from: { type: 'string', description: 'YYYY-MM-DD, local time.' },
  to: { type: 'string', description: 'YYYY-MM-DD, local time, inclusive.' },
};

export const toolDefinitions = [
  {
    name: 'find_meetings',
    description: 'Lists meetings, newest first, with call_id, title, date, length, people, tags, and a one-line summary. Every filter is optional and they combine. people matches first names, short forms ("Jen" finds Jennifer), last names, full names, or a person id from a person_ids line of read_meeting; every person listed must be in the meeting. Dates are YYYY-MM-DD in local time; to is inclusive.',
    inputSchema: { type: 'object', properties: { query: { type: 'string', description: 'Words in the title, tags, summary, or transcript.' }, ...filterProps, tag: { type: 'string' }, limit: { type: 'integer' } } },
  },
  {
    name: 'search_transcripts',
    description: 'Finds transcript lines that contain a word or phrase, with the meeting, the time, and the speaker. Narrow by people and dates like find_meetings.',
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, ...filterProps, limit: { type: 'integer' } }, required: ['query'] },
  },
  {
    name: 'read_meeting',
    description: 'Reads one meeting in full: people, summary, topics, decisions, action items with owners, and the whole timestamped transcript. Use it before saying what someone said, agreed to, or committed to.',
    inputSchema: { type: 'object', properties: { call_id: { type: 'string' } }, required: ['call_id'] },
  },
  {
    name: 'action_items',
    description: 'Lists action items from meeting summaries with their owner, meeting, and date. Filter by owner (same name matching as find_meetings) and dates.',
    inputSchema: { type: 'object', properties: { owner: { type: 'string' }, from: filterProps.from, to: filterProps.to } },
  },
  {
    name: 'search',
    description: 'Searches the meetings by title, tags, summary, and transcript, and the people and the owner\'s tasks by their words. Returns ids to pass to fetch: a meeting\'s call id, person:<id>, or task:<id>.',
    inputSchema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] },
  },
  {
    name: 'fetch',
    description: 'Reads one result of search in full by its id: a meeting, a person (person:<id>), or a task (task:<id>).',
    inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  },
].map((t) => ({ ...t, annotations: { readOnlyHint: true } }));
