import type { Env, MeetingView } from './types';
import { timestamp } from './util';

/**
 * The reads beyond the meetings, from what the Mac syncs to this server (`records/<name>/data` in R2): the people
 * (`SyncedPeople`, allowed fields only), the reads of how people think (`SyncedPersonas`, shown traits only), the
 * owner's points for next time, the owner's tasks, the coach's memory, each meeting's coach review, and the chats.
 * Nothing here writes. The rules that need the Mac's history (a person's numbers, recurring meetings, analytics)
 * are not made again here: they stay in the Mac's MCP.
 *
 * Unknown is not false: a kind the Mac never sent here says so, and an old copy gives its date.
 * Nothing the coach learned about a person who keeps no read (`doNotProfile`) goes out, by name or by id; without
 * the people file, which says who that is, no note on any person goes out.
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

interface CoachMemory {
  facts?: { kind: string; text: string; person?: string }[];
  guidance?: { text: string; person?: string }[];
  focus?: string;
  foci?: { plan: string; why: string; status: string }[];
  people?: Record<string, { note: string; person?: string }>;
}

/** The read of each person goes out only when the Mac says so (the coach, its reads, and "other AI apps" on). */
export const personasKey = 'mcpPersonas';

const cardTitles: Record<string, string> = {
  open: 'Open with', evidence: 'Evidence they need', ask: 'Frame the ask', objections: 'Likely objections', avoid: 'Avoid',
};

/** The records the owner tools read, with the words for each kind. */
const kinds = {
  people: 'people', personas: 'reads of how people think', 'next-time': 'points for next time', commitments: 'tasks', 'coach-profile': 'coach memory',
} as const;
type Kind = keyof typeof kinds;

const maxLimit = 60;
const maxChatCharacters = 160_000;
/** A copy older than the newest meeting by this much gives its date. */
const staleMs = 2 * 86_400_000;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const same = (a: string | undefined, b: string | undefined) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** A time zone that the runtime knows, else UTC: a bad one must not end the answer. */
export function safeZone(tz: string | undefined): string {
  try { new Intl.DateTimeFormat('en-US', { timeZone: tz ?? 'UTC' }); return tz ?? 'UTC'; } catch { return 'UTC'; }
}

export function day(iso: string | undefined, tz: string): string {
  if (!iso) return 'no date';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  try { return new Intl.DateTimeFormat('en-US', { timeZone: tz, month: 'short', day: 'numeric', year: 'numeric' }).format(d); } catch { return iso.slice(0, 10); }
}

/** The page of a list: `limit` (1 to 60, default `d`) from `offset`, and a line that says how many more there are. */
export function page<T>(items: T[], input: Record<string, unknown>, d = 20): { rows: T[]; tail: string } {
  const limit = typeof input.limit === 'number' && input.limit > 0 ? Math.min(Math.floor(input.limit), maxLimit) : d;
  const offset = typeof input.offset === 'number' && input.offset > 0 ? Math.floor(input.offset) : 0;
  const rows = items.slice(offset, offset + limit);
  const more = items.length - offset - rows.length;
  return { rows, tail: more > 0 ? `\n(${more} more; ask with offset ${offset + rows.length}.)` : '' };
}

export async function data<T>(env: Env, name: string): Promise<T | null> {
  const object = await env.FILES.get(`records/${name}/data`);
  if (!object) return null;
  try { return (await object.json()) as T; } catch { return null; }
}

/** When each kind last arrived, and the newest meeting. */
async function arrivals(env: Env): Promise<{ updated: Partial<Record<Kind, string>>; newestMeeting?: string }> {
  const names = Object.keys(kinds);
  const { results } = await env.DB.prepare(`SELECT name, updated FROM records WHERE deleted = 0 AND name IN (${names.map(() => '?').join(', ')})`)
    .bind(...names).all<{ name: Kind; updated: string }>();
  const newest = await env.DB.prepare("SELECT MAX(updated) AS updated FROM records WHERE type = 'Meeting' AND deleted = 0").first<{ updated: string | null }>();
  return { updated: Object.fromEntries(results.map((r) => [r.name, r.updated])), newestMeeting: newest?.updated ?? undefined };
}

/** What the owner tools read, loaded once per call. */
export class OwnerData {
  private readonly canon = new Map<string, string>();
  private readonly byPerson = new Map<string, MeetingView[]>();
  /** False when no meeting here has person ids: then a count by person is not known. */
  readonly meetingsHaveIds: boolean;

  constructor(
    readonly people: SyncedPerson[],
    readonly personas: PersonaRead[],
    readonly points: Point[],
    readonly tasks: Task[],
    readonly meetings: MeetingView[],
    readonly owner: string,
    readonly tz: string,
    /** Whether the Mac allows the reads of how people think here, and the copies agree on who keeps none. */
    readonly showsPersonas: boolean,
    readonly updated: Partial<Record<Kind, string>> = {},
    readonly newestMeeting?: string,
    /** When the Mac last sent every kind without an error (`config.syncedAt`); absent from a Mac before it. */
    readonly syncedAt?: string,
  ) {
    const byID = new Map(people.map((p) => [p.id.toLowerCase(), p]));
    for (const p of people) {
      let current = p.id.toLowerCase();
      const seen = new Set<string>();
      while (!seen.has(current)) {
        seen.add(current);
        const next = byID.get(current)?.mergedInto?.toLowerCase();
        if (!next) break;
        current = next;
      }
      this.canon.set(p.id.toLowerCase(), current);
    }
    for (const m of meetings) {
      const ids = new Set((m.persons ?? []).map((p) => this.canonical(p.id)));
      for (const id of ids) this.byPerson.set(id, [...(this.byPerson.get(id) ?? []), m]);
    }
    this.meetingsHaveIds = meetings.some((m) => m.persons !== undefined);
  }

  static async load(env: Env, meetings: MeetingView[], config: Record<string, string>): Promise<OwnerData> {
    const [people, personas, book, tasks, when] = await Promise.all([
      data<{ people: SyncedPerson[] }>(env, 'people'),
      data<{ personas: PersonaRead[] }>(env, 'personas'),
      data<{ points: Point[] }>(env, 'next-time'),
      data<{ items: Task[] }>(env, 'commitments'),
      arrivals(env),
    ]);
    const tz = safeZone(config.timeZone ?? meetings.find((m) => m.timeZone)?.timeZone);
    // The reads only with the people file, which says who keeps no read. The Mac sends both at each sync where they
    // changed, so a record's own date says nothing about how current it is.
    const both = !!people && !!personas;
    return new OwnerData(people?.people ?? [], personas?.personas ?? [], book?.points ?? [], tasks?.items ?? [], meetings,
      config.owner ?? 'the owner', tz, config[personasKey] === '1' && both, when.updated, when.newestMeeting, config.syncedAt);
  }

  /** "This server has no tasks from your Mac yet" when the kind never came; nil when it is here. */
  absent(kind: Kind): string | null {
    if (this.updated[kind]) return null;
    return `This server has no ${kinds[kind]} from your Mac yet. Mossad after 2.24 sends them at its next sync; until then, Mossad's MCP on the Mac has them.`;
  }

  /** How old the copies are, by when the Mac last sent everything: said only when that is days before the newest
   * meeting here. A Mac that never sent the time gets no word on age, not a false one. */
  age(_kind?: Kind): string {
    const at = this.syncedAt;
    if (!at || !this.newestMeeting || Number.isNaN(Date.parse(at))) return '';
    return Date.parse(this.newestMeeting) - Date.parse(at) > staleMs
      ? `\n(Your Mac last sent these on ${day(at, this.tz)}; newer meetings came since, so they can be out of date.)` : '';
  }

  get live(): SyncedPerson[] { return this.people.filter((p) => !p.deleted && !p.mergedInto); }

  /** The id a merged person has now, in lower case. */
  canonical(id: string): string { return this.canon.get(id.toLowerCase()) ?? id.toLowerCase(); }

  private liveByID(id: string): SyncedPerson | null {
    const c = this.canonical(id);
    return this.live.find((p) => p.id.toLowerCase() === c) ?? null;
  }

  /** Every live person the words fit: an id, an address of theirs, or a whole written name. */
  fits(query: unknown): SyncedPerson[] {
    if (typeof query !== 'string' || !query.trim()) return [];
    const q = query.trim();
    if (this.people.some((p) => same(p.id, q))) {
      const p = this.liveByID(q);
      return p ? [p] : [];
    }
    const lower = q.toLowerCase();
    const addressed = this.live.filter((p) => p.emails?.some((e) => e.state !== 'rejected' && !e.shared && e.address.toLowerCase() === lower));
    if (addressed.length) return addressed;
    if (!q.includes(' ')) return [];
    return this.live.filter((p) => p.displayName.toLowerCase() === lower || p.forms?.some((f) => f.text.toLowerCase() === lower));
  }

  /** A person on a sure match only: exactly one fits. */
  person(query: unknown): SyncedPerson | null {
    const hits = this.fits(query);
    return hits.length === 1 ? hits[0] : null;
  }

  keepsNoRead(id: string | undefined): boolean {
    if (!id) return false;
    const c = this.canonical(id);
    return this.people.some((p) => this.canonical(p.id) === c && p.doNotProfile === true);
  }

  /** The meetings with a person by their id: a voice or an invited person the Mac matched to them. */
  meetingsWith(id: string): MeetingView[] { return this.byPerson.get(this.canonical(id)) ?? []; }

  /** The read of a person, only where the Mac allows it and never for a person who keeps none. */
  read(p: SyncedPerson): PersonaRead | null {
    if (!this.showsPersonas || this.keepsNoRead(p.id)) return null;
    return this.personas.find((r) => this.canonical(r.person) === this.canonical(p.id) && !this.keepsNoRead(r.person) && r.traits.length > 0) ?? null;
  }

  role(p: SyncedPerson): string {
    return [p.directory?.jobTitle, p.directory?.department].filter(Boolean).join(' · ');
  }

  private count(id: string): string {
    if (!this.meetingsHaveIds) return 'meetings not known (the meetings here are from a Mac before person ids)';
    return `${this.meetingsWith(id).length} meetings (spoke or invited)`;
  }

  peopleText(input: Record<string, unknown>): string {
    const none = this.absent('people');
    if (none) return none;
    const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
    const rows = this.live.filter((p) => !p.isOwner)
      .filter((p) => !q || p.displayName.toLowerCase().includes(q) || p.emails?.some((e) => e.address.toLowerCase().includes(q)))
      .map((p) => ({ p, meetings: this.meetingsWith(p.id) }))
      .sort((a, b) => b.meetings.length - a.meetings.length || a.p.displayName.localeCompare(b.p.displayName));
    if (!rows.length) return 'No people match.' + this.age('people');
    const { rows: shown, tail } = page(rows, input);
    return shown.map(({ p, meetings }) => {
      let line = `${p.displayName} | person_id: ${p.id}`;
      const role = this.role(p);
      if (role) line += ` | ${role}`;
      line += ` | ${this.count(p.id)}`;
      if (meetings[0]) line += ` | last ${day(meetings[0].start, this.tz)}`;
      return line;
    }).join('\n') + tail + this.age('people');
  }

  readPerson(input: Record<string, unknown>): string {
    const none = this.absent('people');
    if (none) return none;
    const hits = this.fits(input.person);
    if (hits.length > 1) {
      return `Several saved people fit "${String(input.person)}"; ask the owner which one:\n` + hits.map((p) => {
        const last = this.meetingsWith(p.id)[0];
        return `- ${p.displayName} (person_id: ${p.id})${this.role(p) ? `, ${this.role(p)}` : ''}${last ? `, last meeting ${day(last.start, this.tz)}` : ''}`;
      }).join('\n');
    }
    const p = hits[0];
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
    const { rows, tail } = page(meetings, input);
    parts.push(this.meetingsHaveIds
      ? `Meetings with ${first}, spoke or invited (newest first, ${rows.length} of ${meetings.length}):\n` +
        (rows.length ? rows.map((m) => `- call_id: ${m.id} | ${m.title} | ${day(m.start, this.tz)}`).join('\n') + tail : '- none on this server')
      : `Meetings with ${first}: not known (the meetings here are from a Mac before person ids).`);
    if (!p.isOwner) {
      if (this.updated['next-time']) {
        const points = this.points.filter((x) => !x.deleted && !x.done && !x.seriesID && x.personID && this.canonical(x.personID) === this.canonical(p.id));
        parts.push(`Next time I see ${first}:\n` + (points.length ? points.map((x) => `- ${x.text} (point_id: ${x.id})`).join('\n') : '- nothing saved'));
      }
      const read = this.read(p);
      if (read) {
        const lines: string[] = [];
        if (read.card?.lines.length) lines.push(`How to present to ${first}: ` + read.card.lines.map((l) => `${cardTitles[l.kind] ?? l.kind}: ${l.text}`).join(' / '));
        for (const t of read.traits) lines.push(`- ${t.statement}${t.supportCalls ? ` (seen in ${t.supportCalls} calls)` : ''}`);
        parts.push(`How ${first} thinks (the coach's read, by code from several calls):\n` + lines.join('\n'));
      }
      const items = meetings.flatMap((m) => m.actionItems.filter((a) => a.ownerId && this.canonical(a.ownerId) === this.canonical(p.id))
        .map((a) => `- ${a.task} (call_id: ${m.id}, ${day(m.start, this.tz)})`));
      const itemPage = page(items, { limit: input.limit });
      parts.push(`${first}'s action items:\n` + (items.length ? itemPage.rows.join('\n') + itemPage.tail : '- none'));
      if (this.updated.commitments) {
        const promises = this.tasks.filter((t) => !t.deleted && t.toID && this.canonical(t.toID) === this.canonical(p.id)).map((t) => this.taskLine(t));
        parts.push(`Your promises to ${first}:\n` + (promises.length ? promises.join('\n') : '- none'));
      }
    }
    parts.push("The talk numbers, how the two of you talk, and the voice are in Mossad's MCP on the Mac.");
    return parts.join('\n\n');
  }

  taskLine(t: Task): string {
    let line = `- ${t.text} (task_id: ${t.id})`;
    if (t.to) line += ` (to ${t.to})`;
    const due = t.due ? Date.parse(t.due) : NaN;
    line += t.done ? ` | done ${day(t.done, this.tz)}` : t.due ? ` | due ${day(t.due, this.tz)}${due < Date.now() ? ', overdue' : ''}` : ' | no date';
    if (t.callID) line += ` | made in call_id ${t.callID}${t.callTitle ? ` (${t.callTitle})` : ''}`;
    return line;
  }

  commitmentsText(input: Record<string, unknown>): string {
    const none = this.absent('commitments');
    if (none) return none;
    const status = typeof input.status === 'string' ? input.status : 'open';
    const now = Date.now();
    const who = typeof input.person === 'string' ? input.person.toLowerCase() : '';
    const list = this.tasks.filter((t) => !t.deleted).filter((t) => {
      const overdue = !t.done && !!t.due && Date.parse(t.due) < now;
      const keep = status === 'all' ? true : status === 'done' ? !!t.done : status === 'overdue' ? overdue : !t.done;
      return keep && (!who || (t.to ?? '').toLowerCase().includes(who) || (t.callTitle ?? '').toLowerCase().includes(who));
    }).sort((a, b) => (a.due ?? '9999').localeCompare(b.due ?? '9999'));
    if (!list.length) return 'No commitments match.' + this.age('commitments');
    const { rows, tail } = page(list, input, 30);
    return rows.map((t) => this.taskLine(t)).join('\n') + tail + this.age('commitments');
  }

  pointLine(x: Point): string {
    let line = `- ${x.text} (point_id: ${x.id}`;
    line += x.seriesTitle ? `, for the next ${x.seriesTitle}` : x.personName ? `, for the next time you see ${x.personName}` : '';
    line += `, saved ${day(x.created, this.tz)})`;
    if (x.done) {
      line += ` | discussed${x.done.callID ? ` in call_id ${x.done.callID}` : ''}${typeof x.done.at === 'number' ? ` at ${timestamp(x.done.at)}` : ''} on ${day(x.done.date, this.tz)}`;
      if (x.done.quote) line += `: "${x.done.quote}"`;
    } else {
      if (x.carried?.length) line += ` | carried over ${x.carried.length} ${x.carried.length === 1 ? 'meeting' : 'meetings'}`;
      const m = [...(x.mentions ?? [])].sort((a, b) => b.date.localeCompare(a.date))[0];
      if (m) line += ` | came up ${day(m.date, this.tz)} in a meeting Mossad has only the notes of (call_id: ${m.callID}): "${m.quote}"`;
    }
    return line;
  }

  pointsText(input: Record<string, unknown>): string {
    const none = this.absent('next-time');
    if (none) return none;
    const status = typeof input.status === 'string' ? input.status : 'open';
    let list = this.points.filter((x) => !x.deleted);
    if (typeof input.series === 'string' && input.series.trim()) {
      const q = input.series.trim().toLowerCase();
      list = list.filter((x) => same(x.seriesID, input.series as string) || (x.seriesTitle ?? '').toLowerCase().includes(q));
    }
    if (typeof input.person === 'string' && input.person.trim()) {
      const p = this.person(input.person);
      if (!p) return `No saved person is surely "${input.person}". Use their person_id or whole name.`;
      list = list.filter((x) => !x.seriesID && x.personID && this.canonical(x.personID) === this.canonical(p.id));
    }
    list = list.filter((x) => (status === 'all' ? true : status === 'done' ? !!x.done : !x.done));
    if (!list.length) return 'No points match.' + this.age('next-time');
    list.sort((a, b) => Number(!!a.done) - Number(!!b.done) || (a.seriesTitle ?? a.personName ?? '').localeCompare(b.seriesTitle ?? b.personName ?? '') || (a.rank ?? 0) - (b.rank ?? 0));
    const { rows, tail } = page(list, input, 40);
    return rows.map((x) => this.pointLine(x)).join('\n') + tail + this.age('next-time');
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
      const t = this.tasks.find((x) => same(x.id, id.slice(5)) && !x.deleted);
      if (!t) return null;
      return { id, title: t.text, text: this.taskLine(t).slice(2), url: 'mossad://tasks', metadata: { kind: 'task' } };
    }
    return null;
  }

  /** The coach's memory, without what it learned about a person who keeps no read; no notes on people where the
   * reads do not go out, or with no people file to say who keeps none. */
  coachProfileText(p: CoachMemory | null): string {
    const none = this.absent('coach-profile');
    if (none || !p) return none ?? 'This server has no coach memory from your Mac yet.';
    const known = !!this.updated.people;
    const off = (id?: string) => !!id && (!known || this.keepsNoRead(id));
    const offName = (name: string) => this.people.some((x) => x.doNotProfile && (same(x.displayName, name) || x.forms?.some((f) => same(f.text, name))));
    const parts: string[] = [];
    const titles: Record<string, string> = { role: 'Your role', responsibility: 'What you are responsible for', goal: 'Your goals', relationship: 'Your relationships', context: 'Context' };
    for (const kind of Object.keys(titles)) {
      const list = (p.facts ?? []).filter((f) => f.kind === kind && !off(f.person));
      if (list.length) parts.push(`${titles[kind]}:\n` + list.map((f) => `- ${f.text}`).join('\n'));
    }
    const guidance = (p.guidance ?? []).filter((g) => !off(g.person));
    if (guidance.length) parts.push('Coaching preferences:\n' + guidance.map((g) => `- ${g.text}`).join('\n'));
    const active = [...(p.foci ?? [])].reverse().find((f) => f.status === 'active');
    if (active) parts.push(`Current goal: ${active.plan} (why: ${active.why})`);
    else if (p.focus) parts.push(`Current focus: ${p.focus}`);
    if (known && this.showsPersonasSwitch) {
      const notes = Object.entries(p.people ?? {}).filter(([name, n]) => !off(n.person) && !offName(name)).sort(([a], [b]) => a.localeCompare(b));
      if (notes.length) parts.push('Notes on people:\n' + notes.map(([name, n]) => `- ${name}: ${n.note}`).join('\n'));
    }
    return (parts.length ? parts.join('\n\n') : 'The coach has no notes yet.') + this.age('coach-profile');
  }

  /** The switch alone, for the notes: the reads' copies need not agree for a note. */
  showsPersonasSwitch = false;
}

/** One meeting's review, as text. */
export async function coachReviewText(env: Env, callID: unknown): Promise<string> {
  if (typeof callID !== 'string' || !/^[A-Za-z0-9._-]{1,200}$/.test(callID)) return 'No coach review for that call_id.';
  const object = await env.FILES.get(`records/${callID}/coach`);
  if (!object) return 'No coach review for that call_id on this server.';
  let v: {
    headline: string; overview?: string; strengths?: { title: string; observation: string; quote?: string; tryInstead?: string }[];
    improvements?: { title: string; observation: string; quote?: string; tryInstead?: string }[];
    scorecard?: { score: number; reason: string }; value?: { rating: string; reason: string; suggestion?: string };
    line?: { title: string; text: string; quote?: string; say?: string };
  };
  try { v = await object.json(); } catch { return 'The coach review of that call cannot be read on this server.'; }
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
  if (!list.length) return 'This server has no chats from your Mac yet. Mossad after 2.24 sends them at its next sync.';
  const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
  const found = list.filter((c) => !q || c.title.toLowerCase().includes(q) || (c.summary ?? '').toLowerCase().includes(q)
    || c.messages.some((m) => m.text.toLowerCase().includes(q)));
  if (!found.length) return 'No earlier chats among the newest 60 match.';
  const { rows, tail } = page(found, input);
  return rows.map((c) => `chat_id: ${c.id} | ${day(c.updated, tz)} | ${c.title}${c.summary ? ` | ${c.summary}` : ''}`).join('\n') + tail;
}

/** One chat by its id, any chat here, in any letter case; a long chat is cut. */
export async function readChatText(env: Env, id: unknown, owner: string): Promise<string> {
  if (typeof id !== 'string' || !uuid.test(id)) return 'No chat with that chat_id.';
  const chat = await data<Chat>(env, `chat-${id.toUpperCase()}`) ?? await data<Chat>(env, `chat-${id.toLowerCase()}`);
  if (!chat || !Array.isArray(chat.messages)) return 'No chat with that chat_id on this server.';
  const text = `${chat.title}\n` + chat.messages.map((m) => `${m.role === 'user' ? owner : 'You'}: ${m.text}`).join('\n\n');
  return text.length > maxChatCharacters ? text.slice(0, maxChatCharacters) + '\n(The chat is cut here.)' : text;
}

/** The owner's share links as the server counts them: never the token (the table holds only its hash) or the PIN. */
export async function sharesText(env: Env, input: Record<string, unknown>, tz: string): Promise<string> {
  try {
    const { results } = await env.DB.prepare(`SELECT title, created, expires, views, viewers, last_view, gone, pin_hash IS NOT NULL AS pin
      FROM shares ORDER BY created DESC`).all<{
      title: string; created: string; expires: string | null; views: number; viewers: number; last_view: string | null; gone: number; pin: number;
    }>();
    if (!results.length) return 'No share links on this server.';
    const now = Date.now();
    const { rows, tail } = page(results, input);
    return rows.map((s) => {
      const expired = s.gone === 1 || (!!s.expires && Date.parse(s.expires) < now);
      let line = `${s.title} | made ${day(s.created, tz)} | ${expired ? 'expired' : s.expires ? `expires ${day(s.expires, tz)}` : 'no expiry'}`;
      line += s.pin === 1 ? ' | PIN on' : ' | no PIN';
      line += ` | ${s.views} ${s.views === 1 ? 'view' : 'views'}${s.viewers ? ` by ${s.viewers} ${s.viewers === 1 ? 'person' : 'people'}` : ''}`;
      if (s.last_view) line += ` | last viewed ${day(s.last_view, tz)}`;
      return line;
    }).join('\n') + tail;
  } catch {
    return 'The share links cannot be read on this server yet: its database needs the update in server/README.md.';
  }
}

/** The tools over the owner's synced data. Each loads only what it reads. */
export async function runOwnerTool(env: Env, name: string, args: Record<string, unknown>, config: Record<string, string>,
  meetings: () => Promise<MeetingView[]>): Promise<string> {
  const tz = safeZone(config.timeZone);
  switch (name) {
    case 'read_coach_review': return coachReviewText(env, args.call_id);
    case 'past_chats': return pastChatsText(await chats(env), args, tz);
    case 'read_chat': return readChatText(env, args.chat_id, config.owner ?? 'the owner');
    case 'shares': return sharesText(env, args, tz);
  }
  // Only `people` and `read_person` read the meetings.
  const needsMeetings = name === 'people' || name === 'read_person';
  const owner = await OwnerData.load(env, needsMeetings ? await meetings() : [], config);
  owner.showsPersonasSwitch = config[personasKey] === '1';
  switch (name) {
    case 'coach_profile': return owner.coachProfileText(await data<CoachMemory>(env, 'coach-profile'));
    case 'people': return owner.peopleText(args);
    case 'read_person': return owner.readPerson(args);
    case 'next_time_points': return owner.pointsText(args);
    case 'commitments': return owner.commitmentsText(args);
    default: return `Unknown tool ${name}.`;
  }
}
const person = { type: 'string', description: 'A person_id, a whole name, or an email address.' };

/** The tools over what the Mac syncs: the same names and words as the Mac's MCP, where the server can know it. */
export const ownerToolDefinitions = [
  {
    name: 'people',
    description: "The people the owner meets with, most meetings first: person_id, job title, how many meetings on this server they spoke in or were invited to, and the last one. A list says how many more there are; ask again with offset. Filter by a name. Use read_person for one person.",
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'integer' }, offset: { type: 'integer' } } },
  },
  {
    name: 'read_person',
    description: "Reads one person: person_id, every written form of the name, addresses, job and team, the meetings with them (call_id), the owner's points for next time with them, how to present to them (when the owner allows the coach's reads here), their action items, and the owner's promises to them. person is a person_id, a whole name, or an address; a first name alone is not enough.",
    inputSchema: { type: 'object', properties: { person, limit: { type: 'integer' }, offset: { type: 'integer', description: 'Moves the list of meetings.' } }, required: ['person'] },
  },
  {
    name: 'next_time_points',
    description: "The owner's points to raise later, for the next meeting of a recurring meeting or the next time they see a person, with point_id and what happened to each: discussed (call_id, moment, quote), carried, or seen in notes. status is open (default), done, or all. Narrow by series (title words or series_id) or person.",
    inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'done', 'all'] }, series: { type: 'string' }, person, limit: { type: 'integer' }, offset: { type: 'integer' } } },
  },
  {
    name: 'commitments',
    description: "What the owner personally promised (the Tasks page), with task_id, to whom, the meeting, the due date, and whether it is done or overdue. status is open (default), overdue, done, or all. Filter by a person's name.",
    inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'overdue', 'done', 'all'] }, person: { type: 'string' }, limit: { type: 'integer' }, offset: { type: 'integer' } } },
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
    description: 'Earlier conversations with the owner in Mossad, newest first, with their summaries: the newest 60 only. Filter by words.',
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'integer' }, offset: { type: 'integer' } } },
  },
  {
    name: 'read_chat',
    description: 'Reads one earlier conversation in full, by its chat_id, also one older than the newest 60. A long chat is cut.',
    inputSchema: { type: 'object', properties: { chat_id: { type: 'string' } }, required: ['chat_id'] },
  },
  {
    name: 'shares',
    description: "The owner's share links of meetings: title, when made, when it expires, whether it has a PIN, and how many views by how many people. Never the link, its token, or the PIN.",
    inputSchema: { type: 'object', properties: { limit: { type: 'integer' }, offset: { type: 'integer' } } },
  },
].map((t) => ({ ...t, annotations: { readOnlyHint: true } }));

export const ownerToolNames = new Set(ownerToolDefinitions.map((t) => t.name));
