import type { Env, MeetingView } from './types';
import { timestamp } from './util';

/**
 * The reads beyond the meetings, from what the Mac already syncs to this server (`records/<name>/data` in R2): the
 * people (`SyncedPeople`, allowed fields only), the reads of how people think (`SyncedPersonas`, shown traits only),
 * the owner's points for next time, the owner's tasks, the coach's memory, each meeting's coach review, and the
 * chats. Nothing here writes. The rules that need the Mac's history (a person's band numbers, recurring meetings,
 * analytics) are not made again here: they stay in the Mac's MCP.
 */

export interface SyncedPerson {
  id: string;
  displayName: string;
  forms?: { text: string }[];
  emails?: { address: string; state?: string; shared?: boolean }[];
  isOwner?: boolean;
  company?: string;
  doNotProfile?: boolean;
  mergedInto?: string;
  deleted?: string;
  directory?: { jobTitle?: string; department?: string };
}

export interface PersonaRead {
  person: string;
  traits: { statement: string; soDoThis?: string; confidence?: number; supportCalls?: number; totalCalls?: number }[];
  card?: { headline?: string; lines: { kind: string; text: string }[] };
}

export interface Point {
  id: string;
  text: string;
  seriesID?: string;
  seriesTitle?: string;
  personID?: string;
  personName?: string;
  rank?: number;
  done?: { callID?: string; at?: number; quote?: string; date: string; byOwner?: boolean };
  carried?: string[];
  mentions?: { callID: string; at: number; quote: string; date: string }[];
  deleted?: boolean;
  created: string;
}

export interface Task {
  id: string;
  text: string;
  to?: string;
  toID?: string;
  callID?: string;
  callTitle?: string;
  at?: number;
  due?: string;
  done?: string;
  deleted?: boolean;
  madeAt?: string;
}

export interface Chat { id: string; title: string; updated: string; summary?: string; callID?: string; messages: { role: string; text: string }[] }

/** The read of each person goes out only when the Mac says so (the coach, its reads, and "other AI apps" on). */
export const personasKey = 'mcpPersonas';

const cardTitles: Record<string, string> = {
  open: 'Open with', evidence: 'Evidence they need', ask: 'Frame the ask', objections: 'Likely objections', avoid: 'Avoid',
};

const maxLimit = 60;
const lim = (v: unknown, d = 20) => Math.min(typeof v === 'number' && v > 0 ? v : d, maxLimit);
const day = (iso: string, tz: string) => new Intl.DateTimeFormat('en-US', { timeZone: tz, month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso));

async function data<T>(env: Env, name: string): Promise<T | null> {
  const object = await env.FILES.get(`records/${name}/data`);
  if (!object) return null;
  try { return (await object.json()) as T; } catch { return null; }
}

/** What the owner tools read, loaded once per call. */
export class OwnerData {
  constructor(
    readonly people: SyncedPerson[],
    readonly personas: PersonaRead[],
    readonly points: Point[],
    readonly tasks: Task[],
    readonly meetings: MeetingView[],
    readonly owner: string,
    readonly tz: string,
    /** Whether the Mac allows the reads of how people think here. */
    readonly showsPersonas: boolean,
  ) {}

  static async load(env: Env, meetings: MeetingView[], config: Record<string, string>): Promise<OwnerData> {
    const [people, personas, book, tasks] = await Promise.all([
      data<{ people: SyncedPerson[] }>(env, 'people'),
      data<{ personas: PersonaRead[] }>(env, 'personas'),
      data<{ points: Point[] }>(env, 'next-time'),
      data<{ items: Task[] }>(env, 'commitments'),
    ]);
    const tz = config.timeZone ?? meetings.find((m) => m.timeZone)?.timeZone ?? 'UTC';
    return new OwnerData(people?.people ?? [], personas?.personas ?? [], book?.points ?? [], tasks?.items ?? [], meetings,
      config.owner ?? 'the owner', tz, config[personasKey] === '1');
  }

  get live(): SyncedPerson[] { return this.people.filter((p) => !p.deleted && !p.mergedInto); }

  /** The id a merged person has now. */
  canonical(id: string): string {
    const seen = new Set<string>();
    let current = id;
    while (!seen.has(current)) {
      seen.add(current);
      const next = this.people.find((p) => p.id === current)?.mergedInto;
      if (!next) break;
      current = next;
    }
    return current;
  }

  /** A person on a sure match only: an id, an address of theirs, or a whole written name that one person has. */
  person(query: unknown): SyncedPerson | null {
    if (typeof query !== 'string' || !query.trim()) return null;
    const q = query.trim();
    const byID = this.people.find((p) => p.id === q);
    if (byID) return this.live.find((p) => p.id === this.canonical(byID.id)) ?? null;
    const lower = q.toLowerCase();
    const addressed = this.live.filter((p) => p.emails?.some((e) => e.state !== 'rejected' && !e.shared && e.address.toLowerCase() === lower));
    if (addressed.length === 1) return addressed[0];
    if (!q.includes(' ')) return null;
    const named = this.live.filter((p) => p.displayName.toLowerCase() === lower || p.forms?.some((f) => f.text.toLowerCase() === lower));
    return named.length === 1 ? named[0] : null;
  }

  /** The meetings with a person by their id: a voice or an invited person the Mac matched to them. */
  meetingsWith(id: string): MeetingView[] {
    return this.meetings.filter((m) => m.persons?.some((p) => this.canonical(p.id) === id));
  }

  /** The read of a person, only where the Mac allows it and never for a person who keeps none. */
  read(p: SyncedPerson): PersonaRead | null {
    if (!this.showsPersonas || p.doNotProfile) return null;
    return this.personas.find((r) => this.canonical(r.person) === p.id && r.traits.length > 0) ?? null;
  }

  role(p: SyncedPerson): string {
    return [p.directory?.jobTitle, p.directory?.department].filter(Boolean).join(' · ');
  }

  peopleText(input: Record<string, unknown>): string {
    const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
    const rows = this.live.filter((p) => !p.isOwner)
      .filter((p) => !q || p.displayName.toLowerCase().includes(q) || p.emails?.some((e) => e.address.toLowerCase().includes(q)))
      .map((p) => ({ p, meetings: this.meetingsWith(p.id) }))
      .sort((a, b) => b.meetings.length - a.meetings.length || a.p.displayName.localeCompare(b.p.displayName))
      .slice(0, lim(input.limit));
    if (!rows.length) return 'No people match.';
    return rows.map(({ p, meetings }) => {
      let line = `${p.displayName} | person_id: ${p.id}`;
      const role = this.role(p);
      if (role) line += ` | ${role}`;
      line += ` | ${meetings.length} meetings`;
      if (meetings[0]) line += ` | last ${day(meetings[0].start, this.tz)}`;
      return line;
    }).join('\n');
  }

  readPerson(input: Record<string, unknown>): string {
    const p = this.person(input.person);
    if (!p) return `No saved person is surely "${typeof input.person === 'string' ? input.person : ''}". Use their person_id, their whole name, or an address.`;
    const first = p.displayName.split(' ')[0];
    const parts: string[] = [];
    let head = `person_id: ${p.id} | ${p.displayName}${p.isOwner ? ' (the owner)' : ''}`;
    const role = this.role(p);
    if (role) head += ` | ${role}`;
    if (p.company) head += ` | ${p.company}`;
    const emails = (p.emails ?? []).filter((e) => e.state !== 'rejected' && !e.shared).map((e) => e.address);
    if (emails.length) head += ` | ${emails.join(', ')}`;
    parts.push(head);
    const forms = [...new Set((p.forms ?? []).map((f) => f.text).filter((t) => t !== p.displayName))].sort();
    if (forms.length) parts.push(`Also written as: ${forms.join('; ')}`);
    const meetings = this.meetingsWith(p.id);
    const shown = meetings.slice(0, lim(input.limit));
    parts.push(`Meetings with ${first} (newest first, ${shown.length} of ${meetings.length}):\n` +
      (shown.length ? shown.map((m) => `- call_id: ${m.id} | ${m.title} | ${day(m.start, this.tz)}`).join('\n') : '- none on this server'));
    if (!p.isOwner) {
      const points = this.points.filter((x) => !x.deleted && !x.done && !x.seriesID && x.personID && this.canonical(x.personID) === p.id);
      parts.push(`Next time I see ${first}:\n` + (points.length ? points.map((x) => `- ${x.text} (point_id: ${x.id})`).join('\n') : '- nothing saved'));
      const read = this.read(p);
      if (read) {
        const lines: string[] = [];
        if (read.card?.lines.length) lines.push(`How to present to ${first}: ` + read.card.lines.map((l) => `${cardTitles[l.kind] ?? l.kind}: ${l.text}`).join(' / '));
        for (const t of read.traits) lines.push(`- ${t.statement}${t.supportCalls ? ` (seen in ${t.supportCalls} calls)` : ''}`);
        parts.push(`How ${first} thinks (the coach's read, by code from several calls):\n` + lines.join('\n'));
      }
      const items = meetings.flatMap((m) => m.actionItems.filter((a) => a.ownerId && this.canonical(a.ownerId) === p.id)
        .map((a) => `- ${a.task} (call_id: ${m.id}, ${day(m.start, this.tz)})`));
      parts.push(`${first}'s action items:\n` + (items.length ? items.slice(0, lim(input.limit)).join('\n') : '- none'));
      const promises = this.tasks.filter((t) => !t.deleted && t.toID && this.canonical(t.toID) === p.id).map((t) => this.taskLine(t));
      parts.push(`Your promises to ${first}:\n` + (promises.length ? promises.join('\n') : '- none'));
    }
    parts.push("The talk numbers, how the two of you talk, and the voice are in Mossad's MCP on the Mac.");
    return parts.join('\n\n');
  }

  taskLine(t: Task): string {
    let line = `- ${t.text} (task_id: ${t.id})`;
    if (t.to) line += ` (to ${t.to})`;
    line += t.done ? ` | done ${day(t.done, this.tz)}` : t.due ? ` | due ${day(t.due, this.tz)}${Date.parse(t.due) < Date.now() ? ', overdue' : ''}` : ' | no date';
    if (t.callID) line += ` | made in call_id ${t.callID}${t.callTitle ? ` (${t.callTitle})` : ''}`;
    return line;
  }

  commitmentsText(input: Record<string, unknown>): string {
    const status = typeof input.status === 'string' ? input.status : 'open';
    const now = Date.now();
    const who = typeof input.person === 'string' ? input.person.toLowerCase() : '';
    const list = this.tasks.filter((t) => !t.deleted).filter((t) => {
      const overdue = !t.done && !!t.due && Date.parse(t.due) < now;
      const keep = status === 'all' ? true : status === 'done' ? !!t.done : status === 'overdue' ? overdue : !t.done;
      return keep && (!who || (t.to ?? '').toLowerCase().includes(who) || (t.callTitle ?? '').toLowerCase().includes(who));
    }).sort((a, b) => (a.due ?? '9999').localeCompare(b.due ?? '9999'));
    return list.length ? list.slice(0, lim(input.limit, 30)).map((t) => this.taskLine(t)).join('\n') : 'No commitments match.';
  }

  pointLine(x: Point): string {
    let line = `- ${x.text} (point_id: ${x.id}`;
    line += x.seriesTitle ? `, for the next ${x.seriesTitle}` : x.personName ? `, for the next time you see ${x.personName}` : '';
    line += `, saved ${day(x.created, this.tz)})`;
    if (x.done) {
      line += ` | discussed${x.done.callID ? ` in call_id ${x.done.callID}` : ''}${x.done.at !== undefined && x.done.at !== null ? ` at ${timestamp(x.done.at)}` : ''} on ${day(x.done.date, this.tz)}`;
      if (x.done.quote) line += `: "${x.done.quote}"`;
    } else {
      if (x.carried?.length) line += ` | carried over ${x.carried.length} ${x.carried.length === 1 ? 'meeting' : 'meetings'}`;
      const m = [...(x.mentions ?? [])].sort((a, b) => b.date.localeCompare(a.date))[0];
      if (m) line += ` | came up ${day(m.date, this.tz)} in a meeting Mossad has only the notes of (call_id: ${m.callID}): "${m.quote}"`;
    }
    return line;
  }

  pointsText(input: Record<string, unknown>): string {
    const status = typeof input.status === 'string' ? input.status : 'open';
    let list = this.points.filter((x) => !x.deleted);
    if (typeof input.series === 'string' && input.series.trim()) {
      const q = input.series.trim().toLowerCase();
      list = list.filter((x) => x.seriesID === input.series || (x.seriesTitle ?? '').toLowerCase().includes(q));
    }
    if (typeof input.person === 'string' && input.person.trim()) {
      const p = this.person(input.person);
      if (!p) return `No saved person is surely "${input.person}". Use their person_id or whole name.`;
      list = list.filter((x) => !x.seriesID && x.personID && this.canonical(x.personID) === p.id);
    }
    list = list.filter((x) => (status === 'all' ? true : status === 'done' ? !!x.done : !x.done));
    if (!list.length) return 'No points match.';
    list.sort((a, b) => Number(!!a.done) - Number(!!b.done) || (a.seriesTitle ?? a.personName ?? '').localeCompare(b.seriesTitle ?? b.personName ?? '') || (a.rank ?? 0) - (b.rank ?? 0));
    return list.slice(0, lim(input.limit, 40)).map((x) => this.pointLine(x)).join('\n');
  }

  /** ChatGPT's search over people and tasks, beside the meetings. */
  search(query: string): { id: string; title: string; url: string }[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const people = this.live.filter((p) => !p.isOwner && (p.displayName.toLowerCase().includes(q) || p.forms?.some((f) => f.text.toLowerCase().includes(q))))
      .slice(0, 10).map((p) => ({ id: `person:${p.id}`, title: p.displayName, url: `mossad://person/${encodeURIComponent(p.id)}` }));
    const tasks = this.tasks.filter((t) => !t.deleted && (t.text.toLowerCase().includes(q) || (t.to ?? '').toLowerCase().includes(q)))
      .slice(0, 10).map((t) => ({ id: `task:${t.id}`, title: `Task: ${t.text}`, url: 'mossad://tasks' }));
    return [...people, ...tasks];
  }

  fetch(id: string): { id: string; title: string; text: string; url: string; metadata: Record<string, string> } | null {
    if (id.startsWith('person:')) {
      const p = this.person(id.slice(7));
      if (!p) return null;
      return { id, title: p.displayName, text: this.readPerson({ person: p.id }), url: `mossad://person/${encodeURIComponent(p.id)}`, metadata: { kind: 'person' } };
    }
    if (id.startsWith('task:')) {
      const t = this.tasks.find((x) => x.id === id.slice(5) && !x.deleted);
      if (!t) return null;
      return { id, title: t.text, text: this.taskLine(t).slice(2), url: 'mossad://tasks', metadata: { kind: 'task' } };
    }
    return null;
  }
}

/** The coach's memory and one meeting's review, as text. */
export async function coachProfileText(env: Env): Promise<string> {
  const p = await data<{
    facts?: { kind: string; text: string }[]; guidance?: { text: string }[]; focus?: string;
    foci?: { plan: string; why: string; status: string }[]; people?: Record<string, { note: string }>;
  }>(env, 'coach-profile');
  if (!p) return 'The coach has no notes on this server.';
  const parts: string[] = [];
  const titles: Record<string, string> = { role: 'Your role', responsibility: 'What you are responsible for', goal: 'Your goals', relationship: 'Your relationships', context: 'Context' };
  for (const kind of Object.keys(titles)) {
    const list = (p.facts ?? []).filter((f) => f.kind === kind);
    if (list.length) parts.push(`${titles[kind]}:\n` + list.map((f) => `- ${f.text}`).join('\n'));
  }
  if (p.guidance?.length) parts.push('Coaching preferences:\n' + p.guidance.map((g) => `- ${g.text}`).join('\n'));
  const active = [...(p.foci ?? [])].reverse().find((f) => f.status === 'active');
  if (active) parts.push(`Current goal: ${active.plan} (why: ${active.why})`);
  else if (p.focus) parts.push(`Current focus: ${p.focus}`);
  const notes = Object.entries(p.people ?? {}).sort(([a], [b]) => a.localeCompare(b));
  if (notes.length) parts.push('Notes on people:\n' + notes.map(([name, n]) => `- ${name}: ${n.note}`).join('\n'));
  return parts.length ? parts.join('\n\n') : 'The coach has no notes yet.';
}

export async function coachReviewText(env: Env, callID: unknown): Promise<string> {
  if (typeof callID !== 'string' || !/^[A-Za-z0-9._-]{1,200}$/.test(callID)) return 'No coach review for that call_id.';
  const object = await env.FILES.get(`records/${callID}/coach`);
  if (!object) return 'No coach review for that call_id.';
  const v = (await object.json()) as {
    headline: string; overview?: string; strengths?: { title: string; observation: string; quote?: string; tryInstead?: string }[];
    improvements?: { title: string; observation: string; quote?: string; tryInstead?: string }[];
    scorecard?: { score: number; reason: string }; value?: { rating: string; reason: string; suggestion?: string };
    line?: { title: string; text: string; quote?: string; say?: string };
  };
  const parts = [v.headline, v.overview].filter((x): x is string => !!x && !!x.trim());
  if (v.line) parts.push(`The one line the owner saw. ${v.line.title}: ${v.line.text}${v.line.quote ? ` Quote: "${v.line.quote}"` : ''}${v.line.say ? ` Say: "${v.line.say}"` : ''}`);
  if (v.scorecard) parts.push(`Score ${v.scorecard.score}/5: ${v.scorecard.reason}`);
  if (v.value) parts.push(`Meeting value ${v.value.rating}: ${v.value.reason}${v.value.suggestion ? ` ${v.value.suggestion}` : ''}`);
  const point = (label: string) => (x: { title: string; observation: string; quote?: string; tryInstead?: string }) =>
    `${label} ${x.title}: ${x.observation}${x.quote ? ` Quote: "${x.quote}"` : ''}${x.tryInstead ? ` Try: ${x.tryInstead}` : ''}`;
  parts.push(...(v.strengths ?? []).map(point('Strength:')), ...(v.improvements ?? []).map(point('Improve:')));
  return parts.join('\n');
}

/** The newest chats, from their records: at most 60 are read, by their last change. */
export async function chats(env: Env): Promise<Chat[]> {
  const { results } = await env.DB.prepare("SELECT name FROM records WHERE type = 'Chat' AND deleted = 0 ORDER BY updated DESC LIMIT ?")
    .bind(maxLimit).all<{ name: string }>();
  const list = await Promise.all(results.map((r) => data<Chat>(env, r.name)));
  return list.filter((c): c is Chat => !!c && Array.isArray(c.messages));
}

export function pastChatsText(list: Chat[], input: Record<string, unknown>, tz: string): string {
  const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
  const found = list.filter((c) => !q || c.title.toLowerCase().includes(q) || (c.summary ?? '').toLowerCase().includes(q)
    || c.messages.some((m) => m.text.toLowerCase().includes(q))).slice(0, lim(input.limit));
  return found.length ? found.map((c) => `chat_id: ${c.id} | ${day(c.updated, tz)} | ${c.title}${c.summary ? ` | ${c.summary}` : ''}`).join('\n') : 'No earlier chats match.';
}

export function readChatText(list: Chat[], id: unknown, owner: string): string {
  const chat = list.find((c) => c.id === id);
  if (!chat) return 'No chat with that chat_id.';
  return `${chat.title}\n` + chat.messages.map((m) => `${m.role === 'user' ? owner : 'You'}: ${m.text}`).join('\n\n');
}

/** The owner's share links as the server counts them: never the token (the table holds only its hash) or the PIN. */
export async function sharesText(env: Env, input: Record<string, unknown>, tz: string): Promise<string> {
  try {
    const { results } = await env.DB.prepare(`SELECT title, created, expires, views, viewers, last_view, gone, pin_hash IS NOT NULL AS pin
      FROM shares ORDER BY created DESC LIMIT ?`).bind(lim(input.limit)).all<{
      title: string; created: string; expires: string | null; views: number; viewers: number; last_view: string | null; gone: number; pin: number;
    }>();
    if (!results.length) return 'No share links on this server.';
    const now = Date.now();
    return results.map((s) => {
      const expired = s.gone === 1 || (!!s.expires && Date.parse(s.expires) < now);
      let line = `${s.title} | made ${day(s.created, tz)} | ${expired ? 'expired' : s.expires ? `expires ${day(s.expires, tz)}` : 'no expiry'}`;
      line += s.pin === 1 ? ' | PIN on' : ' | no PIN';
      line += ` | ${s.views} ${s.views === 1 ? 'view' : 'views'}${s.viewers ? ` by ${s.viewers} ${s.viewers === 1 ? 'person' : 'people'}` : ''}`;
      if (s.last_view) line += ` | last viewed ${day(s.last_view, tz)}`;
      return line;
    }).join('\n');
  } catch {
    return 'The share links cannot be read on this server yet.';
  }
}

const person = { type: 'string', description: 'A person_id, a whole name, or an email address.' };

/** The tools over what the Mac syncs: the same names and words as the Mac's MCP, where the server can know it. */
export const ownerToolDefinitions = [
  {
    name: 'people',
    description: "The people the owner meets with, most meetings first: person_id, job title, how many meetings on this server, and the last one. Filter by a name. Use read_person for one person.",
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'integer' } } },
  },
  {
    name: 'read_person',
    description: "Reads one person: person_id, every written form of the name, addresses, job and team, the meetings with them (call_id), the owner's points for next time with them, how to present to them (when the owner allows the coach's reads here), their action items, and the owner's promises to them. person is a person_id, a whole name, or an address; a first name alone is not enough.",
    inputSchema: { type: 'object', properties: { person, limit: { type: 'integer' } }, required: ['person'] },
  },
  {
    name: 'next_time_points',
    description: "The owner's points to raise later, for the next meeting of a recurring meeting or the next time they see a person, with point_id and what happened to each: discussed (call_id, moment, quote), carried, or seen in notes. status is open (default), done, or all. Narrow by series (title words or series_id) or person.",
    inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'done', 'all'] }, series: { type: 'string' }, person, limit: { type: 'integer' } } },
  },
  {
    name: 'commitments',
    description: "What the owner personally promised (the Tasks page), with task_id, to whom, the meeting, the due date, and whether it is done or overdue. status is open (default), overdue, done, or all. Filter by a person's name.",
    inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'overdue', 'done', 'all'] }, person: { type: 'string' }, limit: { type: 'integer' } } },
  },
  {
    name: 'coach_profile',
    description: "What the communication coach knows about the owner: role, responsibilities, goals, relationships, coaching preferences, the current goal, and notes on people.",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'read_coach_review',
    description: "Reads one meeting's coach review: the line the owner saw, the score, the meeting's value, and the strengths and improvements with quotes and what to try.",
    inputSchema: { type: 'object', properties: { call_id: { type: 'string' } }, required: ['call_id'] },
  },
  {
    name: 'past_chats',
    description: 'Earlier conversations with the owner in Mossad, newest first, with their summaries. Filter by words.',
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'integer' } } },
  },
  {
    name: 'read_chat',
    description: 'Reads one earlier conversation in full.',
    inputSchema: { type: 'object', properties: { chat_id: { type: 'string' } }, required: ['chat_id'] },
  },
  {
    name: 'shares',
    description: "The owner's share links of meetings: title, when made, when it expires, whether it has a PIN, and how many views by how many people. Never the link, its token, or the PIN.",
    inputSchema: { type: 'object', properties: { limit: { type: 'integer' } } },
  },
].map((t) => ({ ...t, annotations: { readOnlyHint: true } }));

export const ownerToolNames = new Set(ownerToolDefinitions.map((t) => t.name));
