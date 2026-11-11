import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { handleAPI } from '../src/api';
import { ownerMark, pinPolicy } from '../src/access';
import { handleShareHost } from '../src/share';
import type { Share } from '../src/types';
import { sha256Hex } from '../src/util';
import { cookies, fakeContext, fakeEnv } from './fakes';
import { migrationFiles, openDatabase } from './sqlite.mjs';

const host = 'https://notes.example.com';
const auth = { Authorization: 'Bearer owner-secret' };
const token = 'A'.repeat(43), other = 'B'.repeat(43);
const id = await sha256Hex(token), otherID = await sha256Hex(other);

const meeting: Share = {
  title: 'Budget review', start: '2026-11-03T21:00:00Z', end: '2026-11-03T21:47:00Z', people: ['Dana Lee', 'Jennifer Lee'], owner: 'Dana Lee',
  summary: 'We held spend flat.', topics: [{ title: 'First quarter', summary: 'Spend is **flat**.' }],
  decisions: [{ text: 'Hold spend', at: 3128 }], actionItems: [{ task: 'Send the numbers', owner: 'Jennifer Lee', text: 'Jennifer Lee: Send the numbers' }],
  lines: [{ at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' }], audio: false, chat: false, expires: null, timeZone: 'America/Chicago',
};

type World = ReturnType<typeof fakeEnv> & ReturnType<typeof fakeContext>;

function world(migrations = Infinity): World { return { ...fakeEnv({}, migrations), ...fakeContext() }; }

async function api(w: World, method: string, path: string, body?: unknown, headers: Record<string, string> = auth) {
  return handleAPI(new Request(`${host}/api/${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }), w.env);
}

async function share(w: World, shareID = id, body: Partial<Share> = {}) {
  expect((await api(w, 'PUT', `shares/${shareID}`, { ...meeting, ...body })).status).toBe(200);
}

async function setPIN(w: World, pin?: string, shareID = id): Promise<string> {
  const r = await api(w, 'PUT', `shares/${shareID}/pin`, pin ? { pin } : {});
  expect(r.status).toBe(200);
  return ((await r.json()) as { pin: string }).pin;
}

interface Visit { cookie?: string; method?: string; form?: Record<string, string>; ip?: string; agent?: string; country?: string; body?: string }

async function visit(w: World, path: string, v: Visit = {}): Promise<Response> {
  const headers = new Headers({ 'CF-Connecting-IP': v.ip ?? '203.0.113.9', 'User-Agent': v.agent ?? 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15' });
  if (v.cookie) headers.set('Cookie', v.cookie);
  let body: BodyInit | undefined = v.body;
  if (v.form) { body = new URLSearchParams(v.form); headers.set('Content-Type', 'application/x-www-form-urlencoded'); }
  const request = new Request(`${host}${path}`, { method: v.method ?? (body ? 'POST' : 'GET'), headers, body });
  Object.defineProperty(request, 'cf', { value: { country: v.country ?? 'US' } });
  const response = await handleShareHost(request, w.env, w.ctx);
  await w.settle();
  return response!;
}

const enter = (w: World, pin: string, v: Visit = {}, t = token) => visit(w, `/${t}/pin`, { ...v, form: { pin } });

async function row(w: World, shareID = id) {
  return w.db.raw.prepare('SELECT * FROM shares WHERE id = ?').get(shareID) as Record<string, number | string | null>;
}

beforeEach(() => { vi.useFakeTimers({ toFake: ['Date'] }); vi.setSystemTime(new Date('2026-11-05T18:00:00Z')); });
afterEach(() => { vi.useRealTimers(); });

describe('a share with no PIN', () => {
  it('opens as it did, and says nothing of the software that serves it', async () => {
    const w = world();
    await share(w);
    const r = await visit(w, `/${token}`);
    expect(r.status).toBe(200);
    const html = await r.text();
    expect(html).toContain('Budget review');
    expect(html).toContain('I need the numbers by Friday.');
    expect(html).not.toMatch(/mossad/i);
    expect(r.headers.get('X-Robots-Tag')).toContain('noindex');
    expect(r.headers.get('Cache-Control')).toContain('no-store');
  });

  it('answers an unknown link, a wrong shape, and an expired link the same way', async () => {
    const w = world();
    await share(w, id, { expires: '2026-11-05T17:00:00Z' });
    const pages = await Promise.all([visit(w, `/${token}`), visit(w, `/${other}`), visit(w, '/short')]);
    expect(pages.map((p) => p.status)).toEqual([404, 404, 404]);
    const [a, b, c] = await Promise.all(pages.map(async (p) => (await p.text()).replace(/nonce="[^"]+"/g, '')));
    expect(a).toBe(b);
    expect(b).toBe(c);
    expect(a).not.toMatch(/mossad/i);
  });
});

describe('a PIN on a share', () => {
  it('is 4 digits, made by the server or taken from the app, and only 4 digits', async () => {
    const w = world();
    await share(w);
    expect(await setPIN(w)).toMatch(/^\d{4}$/);
    expect(await setPIN(w, '0042')).toBe('0042');
    for (const bad of ['123', '12345', 'abcd', '12 4']) expect((await api(w, 'PUT', `shares/${id}/pin`, { pin: bad })).status).toBe(400);
    expect((await api(w, 'PUT', `shares/${otherID}/pin`, {})).status).toBe(404);
  });

  it('keeps only a salted hash, never the PIN', async () => {
    const w = world();
    await share(w);
    await share(w, otherID);
    await setPIN(w, '4821');
    await setPIN(w, '4821', otherID);
    const a = (await row(w)).pin_hash as string, b = (await row(w, otherID)).pin_hash as string;
    expect(a).toMatch(/^pbkdf2-sha256\$\d+\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}$/);
    expect(a).not.toBe(b);
    const stored = JSON.parse(new TextDecoder().decode(w.files.objects.get(`shares/${id}/share.json`)!));
    expect(JSON.stringify(stored)).not.toContain('4821');
    expect(Object.keys(stored)).not.toContain('pin');
  });

  it('shows only the PIN entry until the PIN is right', async () => {
    const w = world();
    await share(w, id, { audio: true, chat: true });
    await w.files.put(`shares/${id}/audio.m4a`, 'audio');
    await setPIN(w, '4821');
    const r = await visit(w, `/${token}`);
    expect(r.status).toBe(401);
    const html = await r.text();
    expect(html).toContain('name="pin"');
    for (const secret of ['Budget review', 'Dana', 'Jennifer', 'numbers', '4821']) expect(html).not.toContain(secret);
    expect(r.headers.getSetCookie()).toEqual([]);
    expect((await visit(w, `/${token}/audio`)).status).toBe(401);
    expect((await visit(w, `/${token}/chat`, { body: JSON.stringify({ question: 'What was decided?' }) })).status).toBe(401);
    expect((await row(w)).views).toBe(0);
  });

  it('gives a pass for that share after the right PIN: signed, HttpOnly, Secure, SameSite, and for a limited time', async () => {
    const w = world();
    await share(w);
    await share(w, otherID);
    await setPIN(w, '4821');
    await setPIN(w, '4821', otherID);
    const r = await enter(w, '4821');
    expect(r.status).toBe(303);
    // The PIN is in the body of the request only: the way back is the plain link.
    expect(r.headers.get('Location')).toBe(`/${token}`);
    const pass = r.headers.getSetCookie().find((c) => c.startsWith('a='))!;
    for (const part of ['HttpOnly', 'Secure', 'SameSite=Lax', `Path=/${token}`, `Max-Age=${pinPolicy.passSeconds}`]) expect(pass).toContain(part);
    expect(pass).not.toContain('4821');
    const jar = cookies(r);
    const page = await visit(w, `/${token}`, { cookie: jar });
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('Budget review');
    // The pass of one share is not a pass of another, and a changed pass is none.
    expect((await visit(w, `/${other}`, { cookie: jar })).status).toBe(401);
    expect((await visit(w, `/${token}`, { cookie: jar.replace(/a=(\d+)/, (_, t) => `a=${Number(t) + 1}`) })).status).toBe(401);
    vi.setSystemTime(Date.now() + (pinPolicy.passSeconds + 60) * 1000);
    expect((await visit(w, `/${token}`, { cookie: jar })).status).toBe(401);
  });

  it('says how many tries are left, then pauses that visitor for a time that grows', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    for (let i = 1; i < pinPolicy.freeTries; i++) {
      const r = await enter(w, '0000');
      expect(r.status).toBe(401);
      expect(await r.text()).toContain(`${pinPolicy.freeTries - i} ${pinPolicy.freeTries - i === 1 ? 'try' : 'tries'} left`);
    }
    const fifth = await enter(w, '0000');
    expect(fifth.status).toBe(429);
    expect(await fifth.text()).toContain('1 minute');
    // The right PIN does not get through a pause, and the answer does not say that it was right.
    const paused = await enter(w, '4821');
    expect(paused.status).toBe(429);
    expect(paused.headers.getSetCookie().some((c) => c.startsWith('a='))).toBe(false);
    vi.setSystemTime(Date.now() + 61_000);
    const sixth = await enter(w, '0000');
    expect(sixth.status).toBe(429);
    expect(await sixth.text()).toContain('2 minutes');
    vi.setSystemTime(Date.now() + 121_000);
    expect((await enter(w, '4821')).status).toBe(303);
    // A right PIN clears that visitor's count.
    const again = await enter(w, '0000');
    expect(await again.text()).toContain(`${pinPolicy.freeTries - 1} tries left`);
  });

  it('pauses one visitor without pausing another', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    for (let i = 0; i < pinPolicy.freeTries; i++) await enter(w, '0000', { ip: '198.51.100.1' });
    expect((await enter(w, '4821', { ip: '198.51.100.1' })).status).toBe(429);
    expect((await enter(w, '4821', { ip: '198.51.100.2' })).status).toBe(303);
  });

  it('does not count an entry that is not 4 digits', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    for (let i = 0; i < 10; i++) expect((await enter(w, '12')).status).toBe(401);
    expect(await (await enter(w, '0000')).text()).toContain(`${pinPolicy.freeTries - 1} tries left`);
  });

  it('locks the share after too many wrong PINs from many visitors, until the owner makes a new PIN', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    for (let i = 0; i < pinPolicy.shareTries; i++) expect((await enter(w, '0000', { ip: `198.51.100.${i}` })).status).toBe(i === pinPolicy.shareTries - 1 ? 403 : 401);
    const locked = await enter(w, '4821', { ip: '192.0.2.77' });
    expect(locked.status).toBe(403);
    expect(await locked.text()).toContain('new PIN');
    expect((await visit(w, `/${token}`)).status).toBe(403);
    const list = (await (await api(w, 'GET', 'shares')).json()) as { shares: { pin: boolean; pinLocked: boolean; wrongPins: number }[] };
    expect(list.shares[0]).toMatchObject({ pin: true, pinLocked: true, wrongPins: pinPolicy.shareTries });
    const fresh = await setPIN(w);
    expect((await enter(w, fresh, { ip: '192.0.2.77' })).status).toBe(303);
  });

  it('does not hold the wrong tries of a visitor who then enters the right PIN against the share', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    for (let i = 0; i < 20; i++) {
      await enter(w, '0000', { ip: `198.51.100.${i}` });
      await enter(w, '0001', { ip: `198.51.100.${i}` });
      expect((await enter(w, '4821', { ip: `198.51.100.${i}` })).status).toBe(303);
    }
    expect((await enter(w, '4821', { ip: '192.0.2.1' })).status).toBe(303);
  });

  it('ends every pass when the PIN changes, and opens the page again when the PIN is removed', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    const jar = cookies(await enter(w, '4821'));
    expect((await visit(w, `/${token}`, { cookie: jar })).status).toBe(200);
    vi.setSystemTime(Date.now() + 1000);
    await setPIN(w, '4821');
    expect((await visit(w, `/${token}`, { cookie: jar })).status).toBe(401);
    expect((await api(w, 'DELETE', `shares/${id}/pin`)).status).toBe(200);
    expect((await visit(w, `/${token}`)).status).toBe(200);
    expect((await row(w)).pin_hash).toBeNull();
  });

  it('stays when the app sends the share again', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    await share(w, id, { title: 'Budget review, corrected' });
    expect((await visit(w, `/${token}`)).status).toBe(401);
  });

  it('refuses when the database cannot be read, and does not open the page', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    w.db.prepare = () => { throw new Error('D1_ERROR: the database is not available'); };
    const r = await visit(w, `/${token}`);
    expect(r.status).toBe(503);
    expect(await r.text()).not.toContain('Budget review');
  });
});

describe('views of a share', () => {
  const list = async (w: World) => ((await (await api(w, 'GET', 'shares')).json()) as { shares: Record<string, unknown>[] }).shares;

  it('counts a visit and a visitor: a reload within 30 minutes is the same visit', async () => {
    const w = world();
    await share(w);
    const first = await visit(w, `/${token}`);
    const viewer = first.headers.getSetCookie().find((c) => c.startsWith('v='))!;
    for (const part of ['HttpOnly', 'Secure', 'SameSite=Lax', `Path=/${token}`]) expect(viewer).toContain(part);
    const jar = cookies(first);
    await visit(w, `/${token}`, { cookie: jar });
    expect(await list(w)).toMatchObject([{ views: 1, viewers: 1, firstView: '2026-11-05T18:00:00.000Z', lastView: '2026-11-05T18:00:00.000Z' }]);
    vi.setSystemTime(new Date('2026-11-05T18:31:00Z'));
    await visit(w, `/${token}`, { cookie: jar });
    vi.setSystemTime(new Date('2026-11-07T02:00:00Z'));
    await visit(w, `/${token}`, { agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) Mobile/15E148', country: 'CA' });
    expect(await list(w)).toMatchObject([{ views: 3, viewers: 2, firstView: '2026-11-05T18:00:00.000Z', lastView: '2026-11-07T02:00:00.000Z' }]);

    const detail = (await (await api(w, 'GET', `shares/${id}`)).json()) as Record<string, unknown>;
    // Days are the owner's days: 02:00 UTC on the 7th is the evening of the 6th in Chicago.
    expect(detail.days).toEqual([{ day: '2026-11-05', views: 2, viewers: 1 }, { day: '2026-11-06', views: 1, viewers: 1 }]);
    expect(detail.devices).toEqual([{ device: 'computer', viewers: 1 }, { device: 'phone', viewers: 1 }]);
    expect(detail.countries).toEqual([{ country: 'CA', viewers: 1 }, { country: 'US', viewers: 1 }]);
    expect(detail.share).toMatchObject({ id, title: 'Budget review', views: 3, viewers: 2, pin: false });
  });

  it('keeps no address, and no cookie as the browser holds it', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    await enter(w, '0000', { ip: '203.0.113.9' });
    const jar = cookies(await enter(w, '4821', { ip: '203.0.113.9' }));
    const page = await visit(w, `/${token}`, { cookie: jar, ip: '203.0.113.9' });
    await enter(w, '0000', { ip: '203.0.113.9' });
    const value = /v=([^;]+)/.exec(cookies(page))![1];
    const dump = ['shares', 'share_viewers', 'share_days', 'share_pin_tries'].map((t) => JSON.stringify(w.db.raw.prepare(`SELECT * FROM ${t}`).all())).join('\n')
      + [...w.kv].join('\n');
    expect(dump).toContain(id);
    expect(dump).not.toContain('203.0.113.9');
    expect(dump).not.toContain(value);
  });

  it('does not count a link preview, a HEAD, or the PIN entry', async () => {
    const w = world();
    await share(w);
    await visit(w, `/${token}`, { agent: 'Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)' });
    await visit(w, `/${token}`, { agent: 'facebookexternalhit/1.1' });
    await visit(w, `/${token}`, { method: 'HEAD' });
    expect((await row(w)).views).toBe(0);
    await setPIN(w, '4821');
    await visit(w, `/${token}`);
    expect((await row(w)).views).toBe(0);
    await visit(w, `/${token}`, { cookie: cookies(await enter(w, '4821')) });
    expect((await row(w)).views).toBe(1);
  });

  it('makes the owner\'s mark the same way the Mac does', async () => {
    // The same numbers are in SharesTests.swift: the two sides must agree.
    expect(await ownerMark('owner-secret', 1_900_000_000)).toBe('1900000000.9fdf58efd4b92221f7302285c0fb95c79766610af09165cf88fc57ed87ff2305');
  });

  it('does not count the owner, who comes with a mark that the app signed', async () => {
    const w = world();
    await share(w);
    const mark = await ownerMark('owner-secret', Math.floor(Date.now() / 1000) + 300);
    const r = await visit(w, `/${token}?owner=${mark}`);
    expect(r.status).toBe(302);
    expect(r.headers.get('Location')).toBe(`/${token}`);
    const jar = cookies(r);
    expect(jar).toMatch(/^o=/);
    await visit(w, `/${token}`, { cookie: jar });
    await visit(w, `/${token}.md`, { cookie: jar });
    expect((await row(w)).views).toBe(0);
    // A mark made with another secret, or an old one, is no mark: the visit counts.
    const wrong = await visit(w, `/${token}?owner=${await ownerMark('guess', Math.floor(Date.now() / 1000) + 300)}`);
    expect(wrong.status).toBe(200);
    const old = await visit(w, `/${token}?owner=${await ownerMark('owner-secret', Math.floor(Date.now() / 1000) - 5)}`);
    expect(old.status).toBe(200);
    expect((await row(w)).views).toBe(2);
  });
});

describe('the Markdown of a share', () => {
  it('is served as text at the link with .md, for a share with no PIN, and counts as a view', async () => {
    const w = world();
    await share(w);
    const r = await visit(w, `/${token}.md`, { agent: 'ChatGPT-User/1.0' });
    expect(r.status).toBe(200);
    expect(r.headers.get('Content-Type')).toBe('text/markdown; charset=utf-8');
    expect(r.headers.get('X-Robots-Tag')).toContain('noindex');
    const text = await r.text();
    expect(text.startsWith('# Budget review\n')).toBe(true);
    expect(text).toContain('[00:01:05] Jennifer Lee: I need the numbers by Friday.');
    await visit(w, `/${token}.md`, { agent: 'Claude-User/1.0', ip: '192.0.2.4' });
    // Apps that fetch the text send no cookie: together they are one visitor, "other".
    expect(await row(w)).toMatchObject({ views: 1, viewers: 1 });
    const detail = (await (await api(w, 'GET', `shares/${id}`)).json()) as { devices: unknown };
    expect(detail.devices).toEqual([{ device: 'other', viewers: 1 }]);
  });

  it('is not served for a share with a PIN, with or without a pass, and not after the expiry', async () => {
    const w = world();
    await share(w);
    await setPIN(w, '4821');
    expect((await visit(w, `/${token}.md`)).status).toBe(404);
    expect((await visit(w, `/${token}.md`, { cookie: cookies(await enter(w, '4821')) })).status).toBe(404);
    await share(w, otherID, { expires: '2026-11-05T17:00:00Z' });
    expect((await visit(w, `/${other}.md`)).status).toBe(404);
  });

  it('is on the page for the copy button, with its address only when the share has no PIN', async () => {
    const w = world();
    await share(w);
    const open = await (await visit(w, `/${token}`)).text();
    expect(open).toContain('Copy for your AI');
    expect(open).toContain('Here is a meeting transcript and its notes. Use it as context for my questions.');
    expect(open).toContain(`${host}/${token}.md`);
    await setPIN(w, '4821');
    const closed = await (await visit(w, `/${token}`, { cookie: cookies(await enter(w, '4821')) })).text();
    expect(closed).toContain('Here is a meeting transcript and its notes. Use it as context for my questions.');
    expect(closed).toContain('[00:01:05] Jennifer Lee: I need the numbers by Friday.');
    expect(closed).not.toContain('.md');
  });
});

describe('the owner API for shares', () => {
  it('needs the secret for every call', async () => {
    const w = world();
    await share(w);
    const calls: [string, string][] = [['GET', 'shares'], ['GET', `shares/${id}`], ['PUT', `shares/${id}/pin`], ['DELETE', `shares/${id}/pin`], ['PATCH', `shares/${id}`], ['DELETE', `shares/${id}`]];
    for (const [method, path] of calls) {
      expect((await api(w, method, path, method === 'GET' || method === 'DELETE' ? undefined : {}, {})).status, `${method} ${path}`).toBe(401);
      expect((await api(w, method, path, method === 'GET' || method === 'DELETE' ? undefined : {}, { Authorization: 'Bearer guess' })).status, `${method} ${path}`).toBe(401);
    }
    expect((await visit(w, `/${token}`)).status).toBe(200);
  });

  it('says in hello that it has these calls', async () => {
    const w = world();
    expect(await (await api(w, 'GET', 'hello', undefined, {})).json()).toMatchObject({ shares: 2 });
  });

  it('lists every share with its expiry, PIN, and views', async () => {
    const w = world();
    await share(w, id, { expires: '2026-12-01T00:00:00Z' });
    await setPIN(w, '4821');
    const body = (await (await api(w, 'GET', 'shares')).json()) as { shares: unknown[] };
    expect(body.shares).toEqual([{ id, title: 'Budget review', created: '2026-11-05T18:00:00.000Z', expires: '2026-12-01T00:00:00Z', audio: 0, chat: 0,
      views: 0, questions: 0, viewers: 0, firstView: null, lastView: null, pin: true, pinLocked: false, wrongPins: 0, gone: false }]);
  });

  it('changes the expiry on the row and in the copy, so the link stops or goes on', async () => {
    const w = world();
    await share(w);
    expect((await api(w, 'PATCH', `shares/${id}`, { expires: '2026-11-05T17:59:00Z' })).status).toBe(200);
    expect((await row(w)).expires).toBe('2026-11-05T17:59:00Z');
    expect((await api(w, 'PATCH', `shares/${id}`, { expires: null })).status).toBe(200);
    expect((await visit(w, `/${token}`)).status).toBe(200);
    expect((await api(w, 'PATCH', `shares/${id}`, { expires: 'soon' })).status).toBe(400);
    expect((await api(w, 'PATCH', `shares/${otherID}`, { expires: null })).status).toBe(404);
  });

  it('keeps the row of an expired share for the list, and deletes its copy', async () => {
    const w = world();
    await share(w, id, { expires: '2026-11-06T00:00:00Z', audio: true });
    await w.files.put(`shares/${id}/audio.m4a`, 'audio');
    await visit(w, `/${token}`);
    vi.setSystemTime(new Date('2026-11-06T00:00:01Z'));
    // The owner's list finds it first: the copy goes, the numbers stay.
    const listed = (await (await api(w, 'GET', 'shares')).json()) as { shares: Record<string, unknown>[] };
    expect(listed.shares).toMatchObject([{ id, views: 1, gone: true }]);
    expect([...w.files.objects.keys()]).toEqual([]);
    expect((await visit(w, `/${token}`)).status).toBe(404);
    // With the copy gone, only the app can bring the link back: it sends the meeting again.
    expect((await api(w, 'PATCH', `shares/${id}`, { expires: null })).status).toBe(410);
    await share(w, id, { expires: null });
    expect((await visit(w, `/${token}`)).status).toBe(200);
    expect(await row(w)).toMatchObject({ gone: 0, views: 2 });
  });

  it('deletes the copy of an expired share at a visit too', async () => {
    const w = world();
    await share(w, id, { expires: '2026-11-06T00:00:00Z' });
    vi.setSystemTime(new Date('2026-11-06T00:00:01Z'));
    expect((await visit(w, `/${token}`)).status).toBe(404);
    expect([...w.files.objects.keys()]).toEqual([]);
    expect(await row(w)).toMatchObject({ gone: 1 });
  });

  it('removes everything of a share that the owner stops', async () => {
    const w = world();
    await share(w);
    await share(w, otherID);
    await setPIN(w, '4821');
    await enter(w, '0000');
    await visit(w, `/${token}`, { cookie: cookies(await enter(w, '4821')) });
    await visit(w, `/${other}`);
    expect((await api(w, 'DELETE', `shares/${id}`)).status).toBe(200);
    for (const table of ['share_viewers', 'share_days', 'share_pin_tries']) {
      expect(w.db.raw.prepare(`SELECT count(*) AS n FROM ${table} WHERE share_id = ?`).get(id)).toMatchObject({ n: 0 });
    }
    expect(w.db.raw.prepare('SELECT count(*) AS n FROM shares').get()).toMatchObject({ n: 1 });
    expect((await visit(w, `/${token}`)).status).toBe(404);
    expect((await api(w, 'GET', `shares/${id}`)).status).toBe(404);
  });
});

describe('the migrations', () => {
  const tables = (db: ReturnType<typeof openDatabase>) => db.prepare(`SELECT name, sql FROM sqlite_master WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY name`).all();
  const columns = (db: ReturnType<typeof openDatabase>) => (db.prepare(`SELECT name, type, "notnull", dflt_value FROM pragma_table_info('shares') ORDER BY name`).all());

  it('are numbered, and only add: no file drops, renames, or rewrites what an older Worker reads', () => {
    const files = migrationFiles();
    expect(files.map((f) => f.name)).toEqual([...files.map((f) => f.name)].sort());
    files.forEach((f, i) => expect(f.name.startsWith(String(i + 1).padStart(4, '0') + '_'), f.name).toBe(true));
    for (const f of files) expect(f.sql.replace(/--.*$/gm, ''), f.name).not.toMatch(/\b(DROP|RENAME|DELETE|UPDATE)\b/i);
  });

  it('bring an install that was made with the old schema.sql to the same tables as a new install, and keep its shares', () => {
    const files = migrationFiles();
    const fresh = openDatabase();
    // An old install: schema.sql is the first migration word for word, and it ran once by hand, outside the migrations.
    const old = openDatabase(0);
    old.exec(files[0].sql);
    old.prepare(`INSERT INTO shares (id, title, created, expires, audio, chat, views, questions) VALUES ('abc', 'Old share', '2026-10-01T00:00:00Z', NULL, 0, 1, 7, 2)`).run();
    for (const f of files) old.exec(f.sql);
    expect(tables(old)).toEqual(tables(fresh));
    expect(columns(old)).toEqual(columns(fresh));
    expect(old.prepare('SELECT * FROM shares').get()).toEqual({ id: 'abc', title: 'Old share', created: '2026-10-01T00:00:00Z', expires: null, audio: 0, chat: 1,
      views: 7, questions: 2, pin_hash: null, pin_set: null, viewers: 0, first_view: null, last_view: null, gone: 0 });
  });

  it('leave the first file as schema.sql was: it must stay safe to run on a database that has the tables', () => {
    const first = migrationFiles()[0].sql;
    for (const statement of first.replace(/--.*$/gm, '').split(';').map((x) => x.trim()).filter(Boolean)) expect(statement).toMatch(/^CREATE (TABLE|INDEX) IF NOT EXISTS /);
  });
});

describe('a server whose database was not updated yet', () => {
  it('serves old shares and counts views the old way', async () => {
    const w = world(1);
    await share(w);
    const r = await visit(w, `/${token}`);
    expect(r.status).toBe(200);
    expect(await r.text()).toContain('Budget review');
    expect(await row(w)).toMatchObject({ views: 1 });
    expect((await visit(w, `/${token}.md`)).status).toBe(200);
  });

  it('lists the shares with the old numbers and says what is missing', async () => {
    const w = world(1);
    await share(w);
    const body = (await (await api(w, 'GET', 'shares')).json()) as { migrate?: boolean; shares: Record<string, unknown>[] };
    expect(body.migrate).toBe(true);
    expect(body.shares).toMatchObject([{ id, title: 'Budget review', views: 0, questions: 0 }]);
    for (const [method, path] of [['PUT', `shares/${id}/pin`], ['GET', `shares/${id}`]] as const) {
      const r = await api(w, method, path, method === 'PUT' ? {} : undefined);
      expect(r.status).toBe(503);
      expect(await r.json()).toMatchObject({ migrate: true });
    }
    // The old calls work as they did.
    expect((await api(w, 'DELETE', `shares/${id}`)).status).toBe(200);
    expect((await visit(w, `/${token}`)).status).toBe(404);
  });
});
