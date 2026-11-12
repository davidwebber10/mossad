import { describe, expect, it } from 'vitest';
import { handle } from '../src/index';
import { MemoryIpLimiter, networkOf } from '../src/ratelimit';
import { fakeContext, fakeEnv, limiter, post, validReport } from './fakes';

const now = () => new Date('2026-11-12T10:00:00Z');

describe('networkOf', () => {
  it('keeps an IPv4 address whole and cuts IPv6 to its /64', () => {
    expect(networkOf('203.0.113.9')).toBe('203.0.113.9');
    expect(networkOf('2001:db8:1:2:aaaa:bbbb:cccc:dddd')).toBe('2001:db8:1:2::/64');
    expect(networkOf('2001:db8:1:2::1')).toBe('2001:db8:1:2::/64');
    expect(networkOf('2001:DB8::1')).toBe('2001:db8:0:0::/64');
    expect(networkOf('::ffff:203.0.113.9')).toBe('203.0.113.9');
  });
});

describe('the limits of one network', () => {
  it('counts every address of one IPv6 /64 as one', async () => {
    const ip = new MemoryIpLimiter(3);
    const results = [];
    for (let i = 1; i <= 4; i++) results.push(await ip.hit(networkOf(`2001:db8:1:2::${i}`), now()));
    expect(results).toEqual([true, true, true, false]);
  });

  it('takes at most 10 new installs a day from one network, and keeps taking reports from installs it knows', async () => {
    const { env, db } = fakeEnv();
    const deps = { now, ipLimiter: limiter(), newInstallLimiter: new MemoryIpLimiter(10, 86_400_000) };
    const statuses = [];
    const ids: string[] = [];
    for (let i = 0; i < 12; i++) {
      const id = crypto.randomUUID();
      ids.push(id);
      statuses.push((await handle(post('/api/telemetry', JSON.stringify({ ...validReport(), installID: id }), { 'CF-Connecting-IP': `2001:db8:9:9::${i + 1}` }), env, fakeContext().ctx, deps)).status);
    }
    expect(statuses.filter((s) => s === 204)).toHaveLength(10);
    expect(statuses.slice(10)).toEqual([429, 429]);
    expect((db.raw.prepare('SELECT COUNT(*) AS n FROM install_limit').get() as { n: number }).n).toBe(10);
    const later = { ...deps, now: () => new Date('2026-11-12T11:30:00Z') };
    const known = await handle(post('/api/telemetry', JSON.stringify({ ...validReport(), installID: ids[0] }), { 'CF-Connecting-IP': '2001:db8:9:9::77' }), env, fakeContext().ctx, later);
    expect(known.status).toBe(204);
  });
});

describe('page views from one network', () => {
  it('serves the page but stops counting over the limit', async () => {
    const { env, db } = fakeEnv();
    const deps = { now, ipLimiter: limiter(), viewLimiter: new MemoryIpLimiter(5), newInstallLimiter: limiter() };
    for (let i = 0; i < 8; i++) {
      const { ctx, settle } = fakeContext();
      const request = new Request('https://getmossad.com/', { headers: { 'CF-Connecting-IP': '198.51.100.4', 'User-Agent': 'Mozilla/5.0 (Macintosh)' } });
      expect((await handle(request, env, ctx, deps)).status).toBe(200);
      await settle();
    }
    expect((db.raw.prepare('SELECT SUM(views) AS n FROM page_views').get() as { n: number }).n).toBe(5);
  });

  it('keeps at most 200 referrers a day and counts the rest as other', async () => {
    const { env, db } = fakeEnv();
    for (let i = 0; i < 1000; i++) {
      const { ctx, settle } = fakeContext();
      const request = new Request('https://getmossad.com/', { headers: { 'CF-Connecting-IP': `198.51.${i >> 8}.${i & 255}`, 'User-Agent': 'Mozilla/5.0 (Macintosh)', Referer: `https://spam${i}.example.com/` } });
      await handle(request, env, ctx, { now, ipLimiter: limiter(), viewLimiter: limiter(), newInstallLimiter: limiter() });
      await settle();
    }
    const referrers = (db.raw.prepare(`SELECT COUNT(DISTINCT referrer) AS n FROM page_views WHERE day = '2026-11-12'`).get() as { n: number }).n;
    expect(referrers).toBe(201);
    expect((db.raw.prepare(`SELECT views FROM page_views WHERE referrer = 'other'`).get() as { views: number }).views).toBe(800);
    expect((db.raw.prepare('SELECT COUNT(*) AS n FROM page_views').get() as { n: number }).n).toBe(201);
  });
});

describe('transport', () => {
  it('redirects plain HTTP to HTTPS and adds security headers to its own answers', async () => {
    const { env } = fakeEnv();
    const plain = await handle(new Request('http://getmossad.com/privacy?a=1'), env, fakeContext().ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter() });
    expect(plain.status).toBe(301);
    expect(plain.headers.get('Location')).toBe('https://getmossad.com/privacy?a=1');
    expect(plain.headers.get('Strict-Transport-Security')).toContain('max-age=');
    const api = await handle(post('/api/telemetry', '{}'), env, fakeContext().ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter() });
    expect(api.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(api.headers.get('Strict-Transport-Security')).toContain('max-age=');
  });

  it('refuses a click from another site', async () => {
    const { env, db } = fakeEnv();
    const click = (site: string) => handle(new Request('https://getmossad.com/api/click', { method: 'POST', body: 'hero', headers: { 'Sec-Fetch-Site': site } }), env, fakeContext().ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter() });
    expect((await click('cross-site')).status).toBe(403);
    expect((await click('same-origin')).status).toBe(204);
    expect((db.raw.prepare('SELECT SUM(clicks) AS n FROM clicks').get() as { n: number }).n).toBe(1);
  });
});
