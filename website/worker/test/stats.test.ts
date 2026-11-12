import { describe, expect, it } from 'vitest';
import { handle } from '../src/index';
import { barList, dayChart, loadStats } from '../src/stats';
import { fakeContext, fakeEnv, limiter, post, validReport } from './fakes';

async function report(env: ReturnType<typeof fakeEnv>['env'], at: string, change: Record<string, unknown> = {}) {
  const r = await handle(post('/api/telemetry', JSON.stringify({ ...validReport(), ...change })), env, fakeContext().ctx, { now: () => new Date(at), ipLimiter: limiter() });
  expect(r.status).toBe(204);
}

describe('loadStats', () => {
  it('counts installs, new installs, the latest report of each, and the median of meetings', async () => {
    const { env, db } = fakeEnv();
    const a = '11111111-1111-4111-8111-111111111111', b = '22222222-2222-4222-8222-222222222222', c = '33333333-3333-4333-8333-333333333333';
    await report(env, '2026-10-01T10:00:00Z', { installID: a, appVersion: '2.18.0', meetings7: 2 });
    await report(env, '2026-11-10T10:00:00Z', { installID: a, appVersion: '2.20.0', meetings7: 4, chip: 'M3 Pro' });
    await report(env, '2026-11-12T08:00:00Z', { installID: b, meetings7: 10, providers: { transcription: 'local', summary: 'apple' } });
    await report(env, '2026-11-12T09:00:00Z', { installID: c, meetings7: 30, os: '26.2' });
    const s = await loadStats(db as unknown as D1Database, '2026-11-12');
    expect(s.activeDay).toBe(2);
    expect(s.activeWeek).toBe(3);
    expect(s.activeMonth).toBe(3);
    expect(s.newWeek).toBe(2);
    expect(s.newMonth).toBe(2);
    expect(s.versions).toEqual([{ key: '2.20.0', n: 3 }]);
    expect(s.chips).toEqual([{ key: 'M3', n: 3 }]);
    expect(s.meetingsMedian).toBe(10);
    expect(s.meetingsBuckets.find((x) => x.key === '3-5')?.n).toBe(1);
    expect(s.meetingsBuckets.find((x) => x.key === '21+')?.n).toBe(1);
    expect(s.transcription).toEqual([{ key: 'assemblyai', n: 2 }, { key: 'local', n: 1 }]);
    expect(s.features.find((f) => f.key === 'coach')?.n).toBe(3);
    expect(s.latestTotal).toBe(3);
    expect(s.platforms.find((p) => p.key === 'meet')?.n).toBe(15);
    expect(s.activeByDay).toHaveLength(30);
    expect(s.activeByDay.at(-1)).toEqual({ day: '2026-11-12', n: 2 });
  });

  it('works on an empty database', async () => {
    const { db } = fakeEnv();
    const s = await loadStats(db as unknown as D1Database, '2026-11-12');
    expect(s.activeMonth).toBe(0);
    expect(s.meetingsMedian).toBeNull();
  });
});

describe('charts', () => {
  it('draws one bar for each day with a tooltip, and escapes text', () => {
    const svg = dayChart([{ day: '2026-11-11', n: 0 }, { day: '2026-11-12', n: 3 }], 'Views <x>');
    expect(svg).toContain('<title>2026-11-12: 3</title>');
    expect(svg).toContain('Views &lt;x&gt;');
    expect(barList([{ key: '<b>', n: 1 }])).toContain('&lt;b&gt;');
    expect(barList([])).toContain('Nothing yet.');
  });
});
