import { data, day, page, safeZone } from './owner';
import type { Env } from './types';
import { timestamp } from './util';

/**
 * The tools over the digest (`ServerDigest` on the Mac): the recurring meetings, each meeting's numbers by month,
 * the bookmarks, the Analytics page, and the coach's cards and goal. The Mac computed every number and sentence with
 * the app's own rules; this file only finds, pages, and writes them out. No calendar data reaches the server, so a
 * series has no next date here. A part that never arrived says so; each answer says when the Mac made it.
 */

interface Named { name: string; personID?: string }
interface Row { callID: string; start: string; minutes: number; plannedMinutes?: number; lateMinutes?: number; overMinutes?: number; ownerShare?: number; people?: number; headline?: string; notesOnly?: boolean }
interface Attendee { name: string; personID?: string; came: number; of: number; last?: string; share?: number; trend: string }
interface Stats { meetings: number; since?: string; medianMinutes?: number; medianPlannedMinutes?: number; planned: number; ranOver: number; startedLate: number; skipped?: string; ownerShare?: number; talksMost?: string }
interface Open { kind: string; text: string; owner?: string; callID?: string; at?: number; date: string }
interface Series { id: string; keys: string[]; title: string; schedule?: string; usualPeople: Named[]; line?: string; rows: Row[]; attendees: Attendee[]; stats: Stats; openItems: Open[] }
interface Speaker { name: string; isOwner: boolean; seconds: number; share: number; turns?: number; wordsPerMinute?: number; fillersPerMinute?: number; questions: number; cutIn?: number; cutOff?: number; reply?: number }
interface Meeting {
  callID: string; title: string; start: string; duration: number; byWords: boolean; sentences: string[]; speakers: Speaker[]; participation?: string;
  outcomes?: string; owners: { name?: string; tasks: string[] }[]; coach?: string; screens?: string; standouts: string[]; earlier: number;
  cost?: { total: number; transcription: number; ai: number; estimated: boolean };
}
interface Bookmark { callID: string; title: string; start: string; at: number; note?: string; speaker?: string; said?: string }
interface Period {
  days: number; calls: number; callSeconds: number; averageSeconds: number; callsPerDay: number; talkShare?: number; scheduled: number; unscheduled: number;
  valueHours: { name: string; seconds: number }[]; topics: { name: string; seconds: number }[]; people: { name: string; seconds: number }[];
  hoursPerWorkday: number; coreHoursShare: number; backToBackShare?: number; callFreeDays: number; workdays: number; itemsPerHour: number;
  decisionsPerHour: number; withOutcomesShare?: number; itemsMine: number; itemsOthers: number; tasksMade: number; tasksDone: number;
  questionsPerHour?: number; cutInPerHour?: number; cutOffPerHour?: number; oneOnOneShare?: number; groupShare?: number;
  trends: { metric: string; sentence: string; usual?: string }[]; cost: number; costParts: { name: string; dollars: number }[];
}
interface Card { id: string; title: string; text: string; callID: string; date: string; at?: number; quote?: string; number?: string; usual?: string; say?: string; why?: string; question: string; answers: string[] }
interface Goal { plan: string; why?: string; status: string; target?: string; before?: string; progress?: string; review?: string; results: { date: string; outcome: string; callID: string; at?: number; evidence: string }[]; date: string; hits: string }
interface Part { version: number; made: string }
interface Point { id: string; text: string; seriesID?: string; seriesKeys?: string[]; personID?: string; done?: { callID?: string; at?: number; quote?: string; date: string }; carried?: string[]; deleted?: boolean; created: string }

const noNext = 'The next date is only known on your Mac: the calendar never goes to this server.';
const pct = (v?: number) => (typeof v === 'number' ? `${Math.round(v * 100)}%` : 'not known');
const mins = (v?: number) => (typeof v === 'number' ? `${Math.round(v)} min` : 'not known');
const span = (s: number) => {
  const t = Math.max(0, Math.round(s));
  if (t < 60) return `${t} s`;
  const m = Math.floor(t / 60);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
};
const words = (s: string) => s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);

const kinds: Record<string, string> = {
  'digest-series': 'recurring meetings', 'digest-bookmarks': 'bookmarks', 'digest-analytics': 'analytics', 'digest-coach': "coach's cards",
  meetings: 'meeting numbers',
};

function absent(what: string): string {
  return `This server has no ${what} from your Mac yet. Mossad after 2.25 sends them with its copy to this server, after meetings are written; until then, Mossad's MCP on the Mac has them.`;
}

async function part<T extends Part>(env: Env, name: string): Promise<T | null> {
  const p = await data<T>(env, name);
  return p && typeof p.version === 'number' && p.version <= 1 ? p : null;
}

const made = (p: Part, tz: string) => `As your Mac made it on ${day(p.made, tz)}.`;

/** The series a word names: its id or one of its keys, else every word of the query in its title. */
function findSeries(list: Series[], q: unknown): Series[] {
  if (typeof q !== 'string' || !q.trim()) return [];
  const query = q.trim().toLowerCase();
  const byID = list.filter((s) => s.id.toLowerCase() === query || s.keys.some((k) => k.toLowerCase() === query));
  if (byID.length) return byID;
  const exact = list.filter((s) => s.title.toLowerCase() === query);
  if (exact.length) return exact;
  const w = words(query);
  return list.filter((s) => { const t = new Set(words(s.title)); return w.every((x) => t.has(x)); });
}

function seriesLine(s: Series, tz: string): string {
  let line = `series_id: ${s.id} | ${s.title} | ${s.schedule ?? 'no fixed day'}`;
  const last = s.rows[0];
  if (last) line += ` | last ${day(last.start, tz)} (call_id: ${last.callID})`;
  line += ` | ${s.stats.meetings} recorded`;
  if (s.usualPeople.length) line += ` | usually: ${s.usualPeople.slice(0, 6).map((p) => p.name).join(', ')}`;
  if (s.line) line += ` | ${s.line}`;
  return line;
}

function pointLine(p: Point, tz: string): string {
  let line = `- ${p.text} (point_id: ${p.id}, saved ${day(p.created, tz)})`;
  if (p.done) line += ` | discussed${p.done.callID ? ` in call_id ${p.done.callID}` : ''}${typeof p.done.at === 'number' ? ` at ${timestamp(p.done.at)}` : ''} on ${day(p.done.date, tz)}${p.done.quote ? `: "${p.done.quote}"` : ''}`;
  else if (p.carried?.length) line += ` | carried over ${p.carried.length} ${p.carried.length === 1 ? 'meeting' : 'meetings'}`;
  return line;
}

async function readSeries(env: Env, s: Series, input: Record<string, unknown>, p: Part, tz: string): Promise<string> {
  const parts = [seriesLine(s, tz), noNext];
  const book = await data<{ points: Point[] }>(env, 'next-time');
  if (book) {
    // A point keeps its series' id and keys; it belongs to the series that holds one of them.
    const keys = new Set(s.keys.map((k) => k.toLowerCase()));
    const mine = book.points.filter((x) => !x.deleted && (keys.has((x.seriesID ?? '').toLowerCase()) || (x.seriesKeys ?? []).some((k) => keys.has(k.toLowerCase()))));
    const open = mine.filter((x) => !x.done), done = mine.filter((x) => x.done);
    parts.push('Your points for next time:\n' + (open.length ? open.map((x) => pointLine(x, tz)).join('\n') : '- none open'));
    if (done.length) parts.push('Done:\n' + done.slice(0, 20).map((x) => pointLine(x, tz)).join('\n'));
  } else {
    parts.push('Your points: this server has no points for next time from your Mac yet.');
  }
  const { rows, tail } = page(s.rows, input);
  parts.push(`History (newest ${s.rows.length} of ${s.stats.meetings}; the Mac's page has every one):\n` + rows.map((r) => {
    let line = `- call_id: ${r.callID} | ${day(r.start, tz)} | ${Math.round(r.minutes)} min`;
    if ((r.lateMinutes ?? 0) >= 1) line += ` | began ${Math.round(r.lateMinutes!)} min late`;
    if ((r.overMinutes ?? 0) >= 1) line += ` | ${Math.round(r.overMinutes!)} min over`;
    if (typeof r.ownerShare === 'number') line += ` | your share ${pct(r.ownerShare)}`;
    if (typeof r.people === 'number') line += ` | ${r.people} people`;
    if (r.notesOnly) line += ' | from Gemini notes';
    if (r.headline) line += ` | ${r.headline}`;
    return line;
  }).join('\n') + tail);
  if (s.attendees.length) {
    parts.push('People:\n' + s.attendees.map((a) => `- ${a.name}: came ${a.came} of ${a.of}${typeof a.share === 'number' ? ` | talk share ${pct(a.share)}` : ''}${a.last ? ` | last ${day(a.last, tz)}` : ''}${a.trend === 'joined' ? ' | joined lately' : a.trend === 'droppedOff' ? ' | dropped off' : ''}`).join('\n'));
  }
  const st = s.stats;
  const numbers = [`${st.meetings} meetings${st.since ? ` since ${day(st.since, tz)}` : ''}`];
  if (typeof st.medianMinutes === 'number') numbers.push(`median ${mins(st.medianMinutes)}`);
  if (typeof st.medianPlannedMinutes === 'number') numbers.push(`planned ${mins(st.medianPlannedMinutes)}`);
  if (st.planned > 0) numbers.push(`ran over ${st.ranOver} of ${st.planned}`, `started late ${st.startedLate} of ${st.planned}`);
  if (st.skipped) numbers.push(st.skipped);
  if (typeof st.ownerShare === 'number') numbers.push(`your talk share ${pct(st.ownerShare)}`);
  if (st.talksMost) numbers.push(`${st.talksMost === 'You' ? 'you talk' : `${st.talksMost} talks`} most`);
  parts.push('Numbers: ' + numbers.join(' | '));
  if (s.openItems.length) {
    const label: Record<string, string> = { yourTask: 'Your task', actionItem: 'Action item', pendingDecision: 'Decision that may be open' };
    parts.push('Still open:\n' + s.openItems.map((i) => `- ${label[i.kind] ?? i.kind}${i.owner && i.kind === 'actionItem' ? ` (${i.owner})` : ''}: ${i.text}${i.callID ? ` (call_id: ${i.callID}, ${day(i.date, tz)})` : ''}`).join('\n'));
  }
  parts.push("The coach's suggested points are on your Mac. " + made(p, tz));
  return parts.join('\n\n');
}

function meetingText(m: Meeting, p: Part, tz: string): string {
  const parts = [`call_id: ${m.callID} | ${m.title} | ${day(m.start, tz)} | ${span(m.duration)}${m.byWords ? ' | shares by words, from Gemini\'s notes' : ''}`];
  if (m.sentences.length) parts.push(m.sentences.join('. ') + '.');
  parts.push('Speakers:\n' + m.speakers.map((s) => {
    let line = `- ${s.isOwner ? `You (${s.name})` : s.name}: ${span(s.seconds)}, ${pct(s.share)} of the talk`;
    if (!m.byWords) {
      line += ` | ${s.turns ?? 'not known'} turns | pace ${typeof s.wordsPerMinute === 'number' ? `${Math.round(s.wordsPerMinute)} words a minute` : 'not known'}`;
      line += ` | fillers ${typeof s.fillersPerMinute === 'number' ? `${s.fillersPerMinute.toFixed(1)} a minute` : 'not known'}`;
      line += ` | cut in ${s.cutIn ?? 'not known'}, cut off ${s.cutOff ?? 'not known'} | reply after ${typeof s.reply === 'number' ? `${s.reply.toFixed(1)} s` : 'not known'}`;
    }
    return line + ` | ${s.questions} questions`;
  }).join('\n'));
  if (m.participation) parts.push(`Who came: ${m.participation}`);
  if (m.outcomes) parts.push(`Outcomes: ${m.outcomes}` + m.owners.map((o) => `\n- ${o.name ?? 'No owner'}: ${o.tasks.join('; ')}`).join(''));
  if (m.coach) parts.push(`The coach: ${m.coach}`);
  if (m.screens) parts.push(`Screens: ${m.screens}`);
  if (m.standouts.length) parts.push(`What stood out against your earlier meetings (${m.earlier} to compare with):\n` + m.standouts.map((x) => `- ${x}`).join('\n'));
  if (m.cost) parts.push(`Cost: $${m.cost.total.toFixed(2)} (transcription $${m.cost.transcription.toFixed(2)}, AI $${m.cost.ai.toFixed(2)})${m.cost.estimated ? ', estimated from the length' : ''}`);
  parts.push(made(p, tz));
  return parts.join('\n\n');
}

function periodText(x: Period): string {
  const lines = [`Last ${x.days} days: ${x.calls} ${x.calls === 1 ? 'call' : 'calls'}, ${span(x.callSeconds)} in calls, average ${span(x.averageSeconds)}, ${x.callsPerDay.toFixed(1)} a day`];
  if (typeof x.talkShare === 'number') lines.push(`Talk share ${pct(x.talkShare)}`);
  lines.push(`Scheduled ${x.scheduled}, unscheduled ${x.unscheduled}`);
  if (x.valueHours.length) lines.push('Meeting value hours: ' + x.valueHours.map((v) => `${v.name} ${(v.seconds / 3600).toFixed(1)}`).join(', '));
  if (x.topics.length) lines.push('Top topics: ' + x.topics.map((t) => `${t.name} ${Math.round(t.seconds / 60)}m`).join(', '));
  if (x.people.length) lines.push('Most time with: ' + x.people.map((t) => `${t.name} ${Math.round(t.seconds / 60)}m`).join(', '));
  if (x.workdays > 0) lines.push(`Workdays: ${x.hoursPerWorkday.toFixed(1)} h in calls a work day, ${pct(x.coreHoursShare)} of 8 to 6 in calls, ${typeof x.backToBackShare === 'number' ? `${pct(x.backToBackShare)} of calls back to back, ` : ''}${x.callFreeDays} of ${x.workdays} work days with no calls`);
  lines.push(`Outcomes: ${x.itemsPerHour.toFixed(1)} action items and ${x.decisionsPerHour.toFixed(1)} decisions an hour${typeof x.withOutcomesShare === 'number' ? `, ${pct(x.withOutcomesShare)} of calls with an item or a decision` : ''}, items yours ${x.itemsMine} and others' ${x.itemsOthers}${x.tasksMade > 0 ? `, ${x.tasksDone} of your ${x.tasksMade} tasks done` : ''}`);
  const talk: string[] = [];
  if (typeof x.questionsPerHour === 'number') talk.push(`${x.questionsPerHour.toFixed(1)} questions an hour`);
  if (typeof x.cutInPerHour === 'number') talk.push(`you cut in ${x.cutInPerHour.toFixed(1)} an hour`);
  if (typeof x.cutOffPerHour === 'number') talk.push(`you were cut off ${x.cutOffPerHour.toFixed(1)} an hour`);
  if (typeof x.oneOnOneShare === 'number') talk.push(`talk share ${pct(x.oneOnOneShare)} in 1:1s`);
  if (typeof x.groupShare === 'number') talk.push(`${pct(x.groupShare)} in groups`);
  if (talk.length) lines.push('How you talk: ' + talk.join(', '));
  for (const t of x.trends) lines.push(`Trend, ${t.metric.toLowerCase()}: ${t.sentence}${t.usual ? `. ${t.usual}` : ''}`);
  lines.push(`API cost $${x.cost.toFixed(2)}${x.costParts.length ? ` (${x.costParts.map((c) => `${c.name} $${c.dollars.toFixed(2)}`).join(', ')})` : ''}`);
  return lines.join('\n');
}

function cardText(c: Card, tz: string): string {
  let line = `- ${c.title}: ${c.text} (call_id: ${c.callID}, ${day(c.date, tz)}${typeof c.at === 'number' ? `, at_seconds: ${Math.round(c.at)}` : ''})`;
  if (c.quote) line += `\n  Quote: "${c.quote}"`;
  if (c.number) line += `\n  Number: ${c.number}${c.usual ? `, usually ${c.usual}` : ''}`;
  if (c.say) line += `\n  Say instead: "${c.say}"`;
  if (c.why) line += `\n  Why it matters: ${c.why}`;
  return line + `\n  It asks: ${c.question} (${c.answers.join(' or ')})`;
}

function goalText(g: Goal, tz: string, label: string): string {
  const lines = [`${label}: ${g.plan}`];
  if (g.why) lines.push(`Why: ${g.why}`);
  if (g.target) lines.push(`Target: ${g.target} of the talk in your 1:1s. Before the goal: ${g.before ?? 'not known'}.`);
  if (g.progress) lines.push(`Progress: ${g.progress}.`);
  if (g.review) lines.push(`Look at the goal again on ${day(g.review, tz)}.`);
  if (g.status === 'active') {
    lines.push(`Call by call (${g.hits}):\n` + (g.results.length ? g.results.map((r) => `- ${day(r.date, tz)} | ${r.outcome} | call_id: ${r.callID}${typeof r.at === 'number' ? ` at_seconds: ${Math.round(r.at)}` : ''} | ${r.evidence}`).join('\n') : '- none yet'));
  }
  return lines.join('\n');
}

/** Runs one digest tool. */
export async function runDigestTool(env: Env, name: string, input: Record<string, unknown>, config: Record<string, string>): Promise<string> {
  const tz = safeZone(config.timeZone);
  switch (name) {
    case 'recurring':
    case 'read_series': {
      const p = await part<Part & { series: Series[] }>(env, 'digest-series');
      if (!p) return absent(kinds['digest-series']);
      if (name === 'read_series') {
        const found = findSeries(p.series, input.series);
        if (found.length > 1) return `Several recurring meetings match; ask which one: ${found.map((s) => `${s.title} (series_id: ${s.id})`).join('; ')}.`;
        if (!found.length) return 'No recurring meeting matches. Use recurring for the list.';
        return readSeries(env, found[0], input, p, tz);
      }
      const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
      const list = q ? p.series.filter((s) => s.title.toLowerCase().includes(q) || s.usualPeople.some((x) => x.name.toLowerCase().includes(q))) : p.series;
      if (!list.length) return `No recurring meeting matches. ${made(p, tz)}`;
      const { rows, tail } = page(list, input);
      return rows.map((s) => seriesLine(s, tz)).join('\n') + tail + `\n${noNext}\n${made(p, tz)}`;
    }
    case 'bookmarks': {
      const p = await part<Part & { bookmarks: Bookmark[] }>(env, 'digest-bookmarks');
      if (!p) return absent(kinds['digest-bookmarks']);
      const q = typeof input.query === 'string' ? input.query.trim().toLowerCase() : '';
      const id = typeof input.call_id === 'string' ? input.call_id : '';
      const list = p.bookmarks.filter((b) => (!id || b.callID === id) && (!q || [b.title, b.note ?? '', b.said ?? '', b.speaker ?? ''].some((x) => x.toLowerCase().includes(q))));
      if (!list.length) return `No bookmarks match. ${made(p, tz)}`;
      const { rows, tail } = page(list, input, 40);
      return rows.map((b) => `call_id: ${b.callID} | ${b.title} | ${day(b.start, tz)} | at_seconds: ${Math.round(b.at)} [${timestamp(b.at)}]${b.note ? ` | note: ${b.note}` : ''}${b.said ? ` | ${b.speaker ?? 'Someone'}: ${b.said}` : ''}`).join('\n') + tail + `\n${made(p, tz)}`;
    }
    case 'meeting_analytics': {
      const id = typeof input.call_id === 'string' ? input.call_id : '';
      const month = /^\d{6}/.test(id) ? `${id.slice(0, 4)}-${id.slice(4, 6)}` : 'other';
      const p = await part<Part & { meetings: Meeting[] }>(env, `digest-meetings-${month}`);
      const any = p ?? (await env.DB.prepare("SELECT name FROM records WHERE name LIKE 'digest-meetings-%' AND deleted = 0 LIMIT 1").first<{ name: string }>());
      if (!any) return absent(kinds.meetings);
      const m = p?.meetings.find((x) => x.callID === id);
      return m && p ? meetingText(m, p, tz) : 'No numbers on this server for that call_id: the meeting is not here, or it has no speech.';
    }
    case 'analytics': {
      const p = await part<Part & { periods: Period[] }>(env, 'digest-analytics');
      if (!p) return absent(kinds['digest-analytics']);
      const want = typeof input.days === 'number' ? input.days : 30;
      // The nearest of the periods the Mac made: 7, 30, 90, or 365 days.
      const x = [...p.periods].sort((a, b) => Math.abs(a.days - want) - Math.abs(b.days - want))[0];
      return x ? `${periodText(x)}\n${made(p, tz)}` : `No numbers. ${made(p, tz)}`;
    }
    case 'coach_findings':
    case 'coach_goals': {
      const p = await part<Part & { findings: Card[]; goal?: Goal; learned: Goal[]; ended: Goal[]; notTaken: Goal[] }>(env, 'digest-coach');
      if (!p) return absent(kinds['digest-coach']);
      if (name === 'coach_findings') {
        const id = typeof input.call_id === 'string' ? input.call_id : '';
        const list = p.findings.filter((c) => !id || c.callID === id);
        if (!list.length) return `No cards wait for an answer. ${made(p, tz)}`;
        const { rows, tail } = page(list, input);
        return rows.map((c) => cardText(c, tz)).join('\n') + tail + `\n${made(p, tz)}`;
      }
      const parts: string[] = [];
      if (p.goal) parts.push(goalText(p.goal, tz, p.goal.status === 'active' ? 'Your goal' : 'Offered goal, waiting for the owner'));
      if (p.learned.length) parts.push('Learned:\n' + p.learned.map((g) => `- ${g.plan} (learned ${day(g.date, tz)}, ${g.hits})`).join('\n'));
      if (p.ended.length) parts.push('Ended:\n' + p.ended.map((g) => `- ${g.plan} (ended ${day(g.date, tz)}, ${g.hits})`).join('\n'));
      if (p.notTaken.length) parts.push('Not taken:\n' + p.notTaken.map((g) => `- ${g.plan}`).join('\n'));
      return (parts.length ? parts.join('\n\n') : 'No goal yet.') + `\n${made(p, tz)}`;
    }
    default:
      return `Unknown tool ${name}.`;
  }
}

/** ChatGPT's search over the series and the bookmarks. */
export async function digestSearch(env: Env, query: string): Promise<{ id: string; title: string; url: string }[]> {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  const [series, marks] = await Promise.all([part<Part & { series: Series[] }>(env, 'digest-series'), part<Part & { bookmarks: Bookmark[] }>(env, 'digest-bookmarks')]);
  const s = (series?.series ?? []).filter((x) => x.title.toLowerCase().includes(q)).slice(0, 10)
    .map((x) => ({ id: `series:${x.id}`, title: `Recurring: ${x.title}`, url: `mossad://series/${encodeURIComponent(x.id)}` }));
  const b = (marks?.bookmarks ?? []).filter((x) => [x.note ?? '', x.said ?? '', x.title].some((t) => t.toLowerCase().includes(q))).slice(0, 10)
    .map((x) => ({ id: `bookmark:${x.callID}#${Math.round(x.at)}`, title: `Bookmark: ${x.note ?? x.title}`, url: `mossad://call/${encodeURIComponent(x.callID)}?t=${Math.round(x.at)}` }));
  return [...s, ...b];
}

export async function digestFetch(env: Env, id: string, config: Record<string, string>): Promise<{ id: string; title: string; text: string; url: string; metadata: Record<string, string> } | null> {
  const tz = safeZone(config.timeZone);
  if (id.startsWith('series:')) {
    const p = await part<Part & { series: Series[] }>(env, 'digest-series');
    const s = p ? findSeries(p.series, id.slice(7)) : [];
    if (!p || s.length !== 1) return null;
    return { id, title: s[0].title, text: await readSeries(env, s[0], {}, p, tz), url: `mossad://series/${encodeURIComponent(s[0].id)}`, metadata: { kind: 'series' } };
  }
  if (id.startsWith('bookmark:')) {
    const [callID, at] = id.slice(9).split('#');
    const p = await part<Part & { bookmarks: Bookmark[] }>(env, 'digest-bookmarks');
    const b = p?.bookmarks.find((x) => x.callID === callID && Math.round(x.at) === Number(at));
    if (!b) return null;
    return { id, title: b.note ?? b.title, text: `${b.title} | ${day(b.start, tz)} | [${timestamp(b.at)}]${b.note ? ` ${b.note}` : ''}${b.said ? `\n${b.speaker ?? 'Someone'}: ${b.said}` : ''}`,
      url: `mossad://call/${encodeURIComponent(callID)}?t=${Math.round(b.at)}`, metadata: { kind: 'bookmark' } };
  }
  return null;
}

const limits = { limit: { type: 'integer' }, offset: { type: 'integer' } };

export const digestToolDefinitions = [
  {
    name: 'recurring',
    description: "The owner's recurring meetings (series): series_id, title, when it usually is, the last meeting, how many were recorded, who usually comes, and one line such as \"Usually 5 people, runs 8 min over; 3 open items\". The next date is only on the owner's Mac. query narrows by title words or a usual person. Read one with read_series.",
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, ...limits } },
  },
  {
    name: 'read_series',
    description: "Reads one recurring meeting: the owner's points for next time, the newest meetings (call_id, length, late, over time, the owner's talk share, people), who comes and who joined or dropped off, the numbers, and what is still open. series is a series_id or words of its title. limit and offset page the history.",
    inputSchema: { type: 'object', properties: { series: { type: 'string' }, ...limits }, required: ['series'] },
  },
  {
    name: 'bookmarks',
    description: "The owner's bookmarks across meetings: call_id, the moment, the owner's note, and what was being said then. query narrows by words; call_id narrows to one meeting.",
    inputSchema: { type: 'object', properties: { query: { type: 'string' }, call_id: { type: 'string' }, ...limits } },
  },
  {
    name: 'meeting_analytics',
    description: "One meeting's numbers: each speaker's talk time and share, turns, pace, fillers, questions, cut-ins, reply times; who came; outcomes; the coach's rating; screens shared (text, never a picture); the cost; and what stood out against the owner's earlier meetings. A number the call cannot give is \"not known\".",
    inputSchema: { type: 'object', properties: { call_id: { type: 'string' } }, required: ['call_id'] },
  },
  {
    name: 'analytics',
    description: 'The Analytics page for the last 7, 30, 90, or 365 days (days, default 30): calls, hours, talk share, scheduled share, meeting value, topics, people, the working week, outcomes, how the owner talks, the trend of each number with its sentence, and API cost.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', enum: [7, 30, 90, 365] } } },
  },
  {
    name: 'coach_findings',
    description: "The coach's cards that wait for the owner's answer: what the owner did well, missed, or could do better, a conclusion to confirm, or a goal offer, each with its call_id, moment, quote or number, why it matters, and its question. call_id gives one call's cards.",
    inputSchema: { type: 'object', properties: { call_id: { type: 'string' }, ...limits } },
  },
  {
    name: 'coach_goals',
    description: "The owner's coaching goal: the goal, why, the target and what was usual before, the progress over the 1:1s since it began, each call's result, and the goals learned, ended, or not taken.",
    inputSchema: { type: 'object', properties: {} },
  },
].map((t) => ({ ...t, annotations: { readOnlyHint: true } }));

export const digestToolNames = new Set(digestToolDefinitions.map((t) => t.name));
