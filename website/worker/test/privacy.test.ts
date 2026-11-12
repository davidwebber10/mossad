import { describe, expect, it } from 'vitest';
import { handle } from '../src/index';
import { fakeContext, fakeEnv, limiter, post, validReport } from './fakes';

const now = () => new Date('2026-11-12T10:00:00Z');

const columns = (db: ReturnType<typeof fakeEnv>['db'], table: string) =>
  (db.raw.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((c) => c.name);

describe('nothing personal is stored', () => {
  it('a report row has exactly the report, the day, and the country', async () => {
    const { env, db } = fakeEnv();
    await handle(post('/api/telemetry', JSON.stringify(validReport()), { 'User-Agent': 'Mossad/2.20.0 Sam', Referer: 'https://example.com/' }), env, fakeContext().ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter() });
    expect(columns(db, 'telemetry')).toEqual([
      'id', 'received_day', 'country', 'install_id', 'app_version', 'build', 'os', 'chip', 'locale',
      'days_active7', 'meetings7', 'meeting_minutes7',
      'p_zoom', 'p_meet', 'p_teams', 'p_in_person', 'p_gemini_notes',
      'transcription', 'summary',
      'f_coach', 'f_screens', 'f_google', 'f_server', 'f_iphone', 'f_backup', 'f_mcp', 'f_shares',
      'c_people', 'c_recurring', 'c_commitments_open',
      'e_transcribe', 'e_identify', 'e_summarize', 'e_write', 'e_detect',
    ]);
    const dump = JSON.stringify(db.raw.prepare('SELECT * FROM telemetry').all()) + JSON.stringify(db.raw.prepare('SELECT * FROM install_limit').all());
    expect(dump).not.toContain('203.0.113.9');
    expect(dump).not.toContain('Mozilla');
    expect(dump).not.toContain('Sam');
    expect(dump).not.toContain('example.com');
  });

  it('no table has a column for an address, a user agent, a header, or a time finer than a day except the rate limit minute', () => {
    const { db } = fakeEnv();
    const tables = (db.raw.prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`).all() as { name: string }[]).map((t) => t.name).sort();
    expect(tables).toEqual(['clicks', 'install_limit', 'page_views', 'telemetry']);
    expect(columns(db, 'install_limit')).toEqual(['install_id', 'last_minute']);
    expect(columns(db, 'page_views')).toEqual(['day', 'path', 'country', 'referrer', 'device', 'views']);
    expect(columns(db, 'clicks')).toEqual(['day', 'target', 'country', 'clicks']);
    for (const table of tables) for (const c of columns(db, table)) expect(c).not.toMatch(/(^|_)ip($|_)|address|agent|header|user|email|cookie|session|url|time|city|region|lat|lon/i);
  });

  it('a page view stores only its buckets', async () => {
    const { env, db } = fakeEnv();
    const { ctx, settle } = fakeContext();
    const request = new Request('https://getmossad.com/privacy?utm_source=sam', { headers: { 'CF-Connecting-IP': '203.0.113.9', 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15', Referer: 'https://news.ycombinator.com/item?id=123' } });
    Object.defineProperty(request, 'cf', { value: { country: 'US', city: 'Austin' } });
    await handle(request, env, ctx, { now, ipLimiter: limiter(), newInstallLimiter: limiter(), viewLimiter: limiter() });
    await settle();
    const rows = db.raw.prepare('SELECT * FROM page_views').all();
    expect(rows).toEqual([{ day: '2026-11-12', path: '/privacy', country: 'US', referrer: 'news.ycombinator.com', device: 'desktop', views: 1 }]);
    const dump = JSON.stringify(rows);
    for (const secret of ['203.0.113.9', 'Mozilla', 'Austin', 'item?id', 'sam']) expect(dump).not.toContain(secret);
  });
});
