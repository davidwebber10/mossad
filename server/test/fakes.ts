import type { Env } from '../src/types';
import { openDatabase } from './sqlite.mjs';

/** Stand-ins for the Worker's bindings. The database is SQLite in memory, made by the migration files. */

type Value = string | number | null;

export function fakeDB(migrations = Infinity) {
  const db = openDatabase(migrations);
  const prepare = (sql: string) => {
    let params: Value[] = [];
    const statement = {
      sql,
      bind(...values: Value[]) { params = values; return statement; },
      async run() { const r = db.prepare(sql).run(...params); return { success: true, meta: { changes: Number(r.changes) } }; },
      async first<T>() { return (db.prepare(sql).get(...params) as T | undefined) ?? null; },
      async all<T>() { return { results: db.prepare(sql).all(...params) as T[] }; },
    };
    return statement;
  };
  return {
    raw: db,
    prepare,
    async batch(list: { run(): Promise<unknown> }[]) {
      db.exec('BEGIN');
      try { const out = []; for (const s of list) out.push(await s.run()); db.exec('COMMIT'); return out; } catch (error) { db.exec('ROLLBACK'); throw error; }
    },
  };
}

export function fakeFiles() {
  const objects = new Map<string, Uint8Array>();
  return {
    objects,
    async put(key: string, body: string | ArrayBuffer | Uint8Array | ReadableStream | null) {
      const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : new Uint8Array(await new Response(body).arrayBuffer());
      objects.set(key, bytes);
      return { key, size: bytes.length };
    },
    async head(key: string) { const o = objects.get(key); return o ? { key, size: o.length } : null; },
    async get(key: string) {
      const o = objects.get(key);
      if (!o) return null;
      return { key, size: o.length, body: new Blob([o]).stream(), async json() { return JSON.parse(new TextDecoder().decode(o)); }, async text() { return new TextDecoder().decode(o); } };
    },
    async delete(keys: string | string[]) { for (const k of [keys].flat()) objects.delete(k); },
  };
}

export function fakeEnv(extra: Partial<Env> = {}, migrations = Infinity) {
  const kv = new Map<string, string>();
  const files = fakeFiles();
  const db = fakeDB(migrations);
  const env = {
    FILES: files,
    OAUTH_KV: { async get(k: string) { return kv.get(k) ?? null; }, async put(k: string, v: string) { kv.set(k, v); } },
    DB: db,
    SHARE_HOST: 'notes.example.com', MCP_HOST: 'mcp.example.com', MCP_PATH: '/mossad', REPO_URL: 'https://example.com/repo', OWNER_SECRET: 'owner-secret',
    ...extra,
  };
  return { env: env as unknown as Env, files, kv, db };
}

/** Runs what a request left for after its answer, as the Worker does. */
export function fakeContext() {
  const waiting: Promise<unknown>[] = [];
  const ctx = { waitUntil(p: Promise<unknown>) { waiting.push(p); }, passThroughOnException() {} } as unknown as ExecutionContext;
  return { ctx, async settle() { await Promise.all(waiting.splice(0)); } };
}

/** The cookies a response set, as the header a browser would send back. */
export function cookies(response: Response, before = ''): string {
  const jar = new Map(before.split('; ').filter(Boolean).map((c) => [c.slice(0, c.indexOf('=')), c.slice(c.indexOf('=') + 1)] as const));
  for (const line of response.headers.getSetCookie()) {
    const [pair] = line.split(';');
    jar.set(pair.slice(0, pair.indexOf('=')), pair.slice(pair.indexOf('=') + 1));
  }
  return [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
}
