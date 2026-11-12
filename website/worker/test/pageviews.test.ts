import { describe, expect, it } from 'vitest';
import { handle } from '../src/index';
import { deviceClass, referrerHost } from '../src/pageviews';
import { fakeContext, fakeEnv, limiter } from './fakes';

const now = () => new Date('2026-11-12T10:00:00Z');
const own = ['getmossad.com', 'www.getmossad.com', 'getmossad.app', 'www.getmossad.app'];

async function visit(env: ReturnType<typeof fakeEnv>['env'], url: string, headers: Record<string, string> = {}, init: RequestInit = {}) {
  const { ctx, settle } = fakeContext();
  const request = new Request(url, { headers, ...init });
  Object.defineProperty(request, 'cf', { value: { country: 'GB' } });
  const response = await handle(request, env, ctx, { now, ipLimiter: limiter() });
  await settle();
  return response;
}

const total = (db: ReturnType<typeof fakeEnv>['db']) => (db.raw.prepare('SELECT COALESCE(SUM(views), 0) AS n FROM page_views').get() as { n: number }).n;

describe('device classes', () => {
  it('buckets user agents', () => {
    expect(deviceClass('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148')).toBe('mobile');
    expect(deviceClass('Mozilla/5.0 (Linux; Android 14; Pixel 8) Mobile Safari/537.36')).toBe('mobile');
    expect(deviceClass('Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)')).toBe('tablet');
    expect(deviceClass('Mozilla/5.0 (Linux; Android 14; SM-X710) Safari/537.36')).toBe('tablet');
    expect(deviceClass('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15')).toBe('desktop');
    expect(deviceClass('Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)')).toBe('bot');
    expect(deviceClass('ClaudeBot/1.0')).toBe('bot');
    expect(deviceClass('curl/8.7.1')).toBe('bot');
    expect(deviceClass(null)).toBe('bot');
  });
});

describe('referrer hosts', () => {
  it('keeps only the host of another site', () => {
    expect(referrerHost('https://www.google.com/search?q=mossad', own)).toBe('google.com');
    expect(referrerHost('https://getmossad.com/privacy', own)).toBe('');
    expect(referrerHost('https://www.getmossad.app/', own)).toBe('');
    expect(referrerHost('android-app://com.slack/', own)).toBe('');
    expect(referrerHost('not a url', own)).toBe('');
    expect(referrerHost(null, own)).toBe('');
  });
});

describe('the page-view counter', () => {
  it('counts the home page and the privacy page under one name each', async () => {
    const { env, db } = fakeEnv();
    for (const path of ['/', '/index.html', '/privacy', '/privacy.html']) await visit(env, `https://getmossad.com${path}`, { 'User-Agent': 'Mozilla/5.0 (Macintosh)' });
    const rows = db.raw.prepare('SELECT path, views FROM page_views ORDER BY path').all();
    expect(rows).toEqual([{ path: '/', views: 2 }, { path: '/privacy', views: 2 }]);
  });

  it('adds to one row for the same bucket', async () => {
    const { env, db } = fakeEnv();
    for (let i = 0; i < 3; i++) await visit(env, 'https://getmossad.com/', { 'User-Agent': 'Mozilla/5.0 (Macintosh)', Referer: 'https://github.com/x' });
    expect(db.raw.prepare('SELECT * FROM page_views').all()).toEqual([{ day: '2026-11-12', path: '/', country: 'GB', referrer: 'github.com', device: 'desktop', views: 3 }]);
  });

  it('does not count other files, a missing page, a prefetch, or a HEAD', async () => {
    const { env, db } = fakeEnv();
    await visit(env, 'https://getmossad.com/robots.txt');
    await visit(env, 'https://getmossad.com/nothing');
    await visit(env, 'https://getmossad.com/', { 'Sec-Purpose': 'prefetch' });
    await visit(env, 'https://getmossad.com/', {}, { method: 'HEAD' });
    expect(total(db)).toBe(0);
  });

  it('serves the page even when counting fails', async () => {
    const { env } = fakeEnv();
    (env as unknown as { DB: unknown }).DB = { prepare() { throw new Error('down'); } };
    const response = await visit(env, 'https://getmossad.com/');
    expect(response.status).toBe(200);
  });
});

describe('download clicks', () => {
  it('counts an allowed button and refuses anything else', async () => {
    const { env, db } = fakeEnv();
    const click = (body: string) => visit(env, 'https://getmossad.com/api/click', { 'Content-Type': 'text/plain;charset=UTF-8' }, { method: 'POST', body });
    expect((await click('hero')).status).toBe(204);
    expect((await click('hero')).status).toBe(204);
    expect((await click('cta')).status).toBe(204);
    expect((await click('https://evil.example')).status).toBe(400);
    expect((await click('x'.repeat(100))).status).toBe(400);
    expect(db.raw.prepare('SELECT target, clicks FROM clicks ORDER BY target').all()).toEqual([{ target: 'cta', clicks: 1 }, { target: 'hero', clicks: 2 }]);
  });
});

describe('hosts', () => {
  it('redirects www and the .app domain to the canonical host, keeping the path', async () => {
    const { env } = fakeEnv();
    for (const host of ['www.getmossad.com', 'getmossad.app', 'www.getmossad.app']) {
      const response = await visit(env, `https://${host}/privacy?x=1`);
      expect(response.status).toBe(301);
      expect(response.headers.get('Location')).toBe('https://getmossad.com/privacy?x=1');
    }
    expect((await visit(env, 'https://getmossad.com/')).status).toBe(200);
  });
});
