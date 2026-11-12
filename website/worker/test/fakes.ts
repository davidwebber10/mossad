import type { Env } from '../src/types';
import { MemoryIpLimiter } from '../src/ratelimit';
import { openDatabase } from './sqlite.mjs';

type Value = string | number | null;

/** D1 as SQLite in memory, made by the migration files. */
export function fakeDB() {
  const db = openDatabase();
  const prepare = (sql: string) => {
    let params: Value[] = [];
    const statement = {
      bind(...values: Value[]) { params = values; return statement; },
      async run() { const r = db.prepare(sql).run(...params); return { success: true, meta: { changes: Number(r.changes) } }; },
      async first<T>() { return (db.prepare(sql).get(...params) as T | undefined) ?? null; },
      async all<T>() { return { results: db.prepare(sql).all(...params) as T[] }; },
    };
    return statement;
  };
  return { raw: db, prepare };
}

export function fakeEnv(extra: Partial<Env> = {}) {
  const db = fakeDB();
  const assets = {
    async fetch(request: Request) {
      const path = new URL(request.url).pathname;
      if (['/', '/index.html', '/privacy', '/privacy.html', '/robots.txt'].includes(path)) return new Response('<!doctype html><title>page</title>', { status: 200, headers: { 'Content-Type': 'text/html' } });
      return new Response('not here', { status: 404 });
    },
  };
  const env = {
    DB: db,
    ASSETS: assets,
    CANONICAL_HOST: 'getmossad.com',
    REDIRECT_HOSTS: 'www.getmossad.com,getmossad.app,www.getmossad.app',
    ACCESS_TEAM_DOMAIN: 'team.cloudflareaccess.com',
    ACCESS_AUD: 'aud-tag',
    OWNER_EMAIL: 'owner@example.com',
    ...extra,
  };
  return { env: env as unknown as Env, db };
}

export function fakeContext() {
  const waiting: Promise<unknown>[] = [];
  const ctx = { waitUntil(p: Promise<unknown>) { waiting.push(p); }, passThroughOnException() {} } as unknown as ExecutionContext;
  return { ctx, async settle() { await Promise.all(waiting.splice(0)); } };
}

export const limiter = () => new MemoryIpLimiter();

export function validReport(): Record<string, unknown> {
  return {
    v: 1,
    installID: '3F2504E0-4F89-41D3-9A0C-0305E82C3301',
    appVersion: '2.20.0',
    build: 607,
    os: '26.1',
    chip: 'M3',
    locale: 'en-US',
    daysActive7: 5,
    meetings7: 12,
    meetingMinutes7: 540,
    platforms7: { zoom: 4, meet: 5, teams: 2, inPerson: 1, geminiNotes: 0 },
    providers: { transcription: 'assemblyai', summary: 'anthropic' },
    features: { coach: true, screens: false, google: true, server: false, iphone: true, backup: false, mcp: true, shares: false },
    counts: { people: '21-100', recurring: '6-20', commitmentsOpen: '1-5' },
    errors7: { transcribe: 0, identify: 1, summarize: 0, write: 0, detect: 2 },
  };
}

export function post(path: string, body: string, headers: Record<string, string> = {}, cf: Record<string, unknown> = { country: 'DE' }) {
  const request = new Request(`https://getmossad.com${path}`, { method: 'POST', body, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.9', 'User-Agent': 'Mossad/2.20.0', ...headers } });
  Object.defineProperty(request, 'cf', { value: cf });
  return request;
}
