import { describe, expect, it } from 'vitest';
import { handle } from '../src/index';
import { Invalid, parseReport } from '../src/telemetry';
import { fakeContext, fakeEnv, limiter, post, validReport } from './fakes';

const now = () => new Date('2026-11-12T10:00:00Z');

function send(env: ReturnType<typeof fakeEnv>['env'], body: unknown, headers: Record<string, string> = {}, at = now) {
  return handle(post('/api/telemetry', typeof body === 'string' ? body : JSON.stringify(body), headers), env, fakeContext().ctx, { now: at, ipLimiter: limiter(), newInstallLimiter: limiter() });
}

describe('parseReport', () => {
  it('accepts the version 1 payload and lowercases the install id', () => {
    const r = parseReport(validReport());
    expect(r.installID).toBe('3f2504e0-4f89-41d3-9a0c-0305e82c3301');
    expect(r.providers).toEqual({ transcription: 'assemblyai', summary: 'anthropic' });
  });

  it('accepts every allowed provider, bucket, and chip family', () => {
    for (const transcription of ['assemblyai', 'deepgram', 'elevenlabs', 'openai', 'local', 'none'])
      for (const summary of ['anthropic', 'openai', 'openrouter', 'localServer', 'apple', 'none'])
        expect(() => parseReport({ ...validReport(), providers: { transcription, summary } })).not.toThrow();
    for (const bucket of ['0', '1-5', '6-20', '21-100', '100+'])
      expect(() => parseReport({ ...validReport(), counts: { people: bucket, recurring: bucket, commitmentsOpen: bucket } })).not.toThrow();
    for (const chip of ['M1', 'M2 Pro', 'M4 Max', 'M3 Ultra', 'M10', 'Other', 'other']) expect(() => parseReport({ ...validReport(), chip })).not.toThrow();
  });

  it('stores other chips as Other, whatever the case', () => {
    expect(parseReport({ ...validReport(), chip: 'other' }).chip).toBe('Other');
    expect(parseReport({ ...validReport(), chip: 'OTHER' }).chip).toBe('Other');
    expect(() => parseReport({ ...validReport(), chip: 'm3' })).toThrow(Invalid);
  });

  const bad: [string, (r: Record<string, any>) => void][] = [
    ['an unknown top key', (r) => { r.email = 'a@b.c'; }],
    ['an unknown nested key', (r) => { r.features.recording = true; }],
    ['a missing key', (r) => { delete r.locale; }],
    ['a missing nested key', (r) => { delete r.errors7.detect; }],
    ['another version', (r) => { r.v = 2; }],
    ['a version as text', (r) => { r.v = '1'; }],
    ['an install id that is not a UUID v4', (r) => { r.installID = '3F2504E0-4F89-11D3-9A0C-0305E82C3301'; }],
    ['a name as install id', (r) => { r.installID = 'Sam Carter'; }],
    ['a free-text app version', (r) => { r.appVersion = '2.20.0 (Sam)'; }],
    ['a build out of range', (r) => { r.build = 0; }],
    ['a fractional build', (r) => { r.build = 6.5; }],
    ['an old macOS', (r) => { r.os = '15.4'; }],
    ['an Intel chip', (r) => { r.chip = 'Intel Core i9'; }],
    ['a free-text locale', (r) => { r.locale = 'en_US.UTF-8'; }],
    ['eight active days', (r) => { r.daysActive7 = 8; }],
    ['negative meetings', (r) => { r.meetings7 = -1; }],
    ['too many meetings', (r) => { r.meetings7 = 501; }],
    ['too many minutes', (r) => { r.meetingMinutes7 = 20001; }],
    ['a platform count as text', (r) => { r.platforms7.zoom = '4'; }],
    ['an unknown provider', (r) => { r.providers.summary = 'gemini'; }],
    ['a feature as a number', (r) => { r.features.coach = 1; }],
    ['an exact count instead of a bucket', (r) => { r.counts.people = '42'; }],
    ['an error count out of range', (r) => { r.errors7.write = 10001; }],
    ['an array', (r) => { r.platforms7 = [1, 2, 3, 4, 5]; }],
    ['null', (r) => { r.providers = null; }],
  ];
  for (const [name, change] of bad) {
    it(`refuses ${name}`, () => {
      const r = structuredClone(validReport());
      change(r);
      expect(() => parseReport(r)).toThrow(Invalid);
    });
  }

  it('refuses a payload that is not an object', () => {
    for (const v of [null, [], 'text', 1]) expect(() => parseReport(v)).toThrow(Invalid);
  });
});

describe('POST /api/telemetry', () => {
  it('stores a valid report and answers 204 with no body', async () => {
    const { env, db } = fakeEnv();
    const response = await send(env, validReport());
    expect(response.status).toBe(204);
    expect(await response.text()).toBe('');
    const row = db.raw.prepare('SELECT * FROM telemetry').get() as Record<string, unknown>;
    expect(row.received_day).toBe('2026-11-12');
    expect(row.country).toBe('DE');
    expect(row.install_id).toBe('3f2504e0-4f89-41d3-9a0c-0305e82c3301');
    expect(row.meetings7).toBe(12);
    expect(row.f_coach).toBe(1);
    expect(row.c_people).toBe('21-100');
  });

  it('answers 400 to an invalid report and to JSON that does not parse, and stores nothing', async () => {
    const { env, db } = fakeEnv();
    expect((await send(env, { ...validReport(), extra: 1 })).status).toBe(400);
    expect((await send(env, '{"v":1,')).status).toBe(400);
    expect((db.raw.prepare('SELECT COUNT(*) AS n FROM telemetry').get() as { n: number }).n).toBe(0);
  });

  it('answers 413 to a body over the limit', async () => {
    const { env } = fakeEnv();
    expect((await send(env, JSON.stringify({ ...validReport(), pad: 'x'.repeat(5000) }))).status).toBe(413);
  });

  it('answers 415 without a JSON content type, and 405 to a GET', async () => {
    const { env } = fakeEnv();
    expect((await send(env, validReport(), { 'Content-Type': 'text/plain' })).status).toBe(415);
    const get = await handle(new Request('https://getmossad.com/api/telemetry'), env, fakeContext().ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter() });
    expect(get.status).toBe(405);
  });

  it('keeps one report an hour for each install', async () => {
    const { env, db } = fakeEnv();
    expect((await send(env, validReport())).status).toBe(204);
    expect((await send(env, validReport(), {}, () => new Date('2026-11-12T10:59:00Z'))).status).toBe(429);
    expect((await send(env, validReport(), {}, () => new Date('2026-11-12T11:00:00Z'))).status).toBe(204);
    const other = { ...validReport(), installID: '9b2f8c1e-1d2a-4c3b-8e4f-5a6b7c8d9e0f' };
    expect((await send(env, other, {}, () => new Date('2026-11-12T11:01:00Z'))).status).toBe(204);
    expect((db.raw.prepare('SELECT COUNT(*) AS n FROM telemetry').get() as { n: number }).n).toBe(3);
  });

  it('caps the requests from one address in an hour', async () => {
    const { env } = fakeEnv();
    const ip = limiter();
    let last = 0;
    for (let i = 0; i < 61; i++) {
      const report = { ...validReport(), installID: crypto.randomUUID() };
      last = (await handle(post('/api/telemetry', JSON.stringify(report)), env, fakeContext().ctx, { now, ipLimiter: ip, newInstallLimiter: limiter() })).status;
    }
    expect(last).toBe(429);
    const elsewhere = post('/api/telemetry', JSON.stringify({ ...validReport(), installID: crypto.randomUUID() }), { 'CF-Connecting-IP': '198.51.100.7' });
    expect((await handle(elsewhere, env, fakeContext().ctx, { now, ipLimiter: ip, newInstallLimiter: limiter() })).status).toBe(204);
  });
});
