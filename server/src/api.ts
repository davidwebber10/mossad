import { deleteShare } from './share';
import type { Env, MeetingView, Share } from './types';
import { bearer, json, sameSecret } from './util';

/** The owner API: the Mac and the iPhone sync through it and manage share links. Every call needs the secret. */

export const version = 1;
const name = /^[A-Za-z0-9._-]{1,200}$/;
const assetKey = /^[a-z]{1,20}$/;
const shareID = /^[0-9a-f]{64}$/;

export async function isOwner(request: Request, env: Env): Promise<boolean> {
  return sameSecret(bearer(request), env.OWNER_SECRET);
}

/** Wrong secrets from one address: 20 an hour, then a pause. */
export async function tooManyFailures(env: Env, request: Request, failed: boolean): Promise<boolean> {
  const key = `fail:${request.headers.get('CF-Connecting-IP') ?? 'unknown'}:${Math.floor(Date.now() / 3_600_000)}`;
  const n = Number((await env.OAUTH_KV.get(key)) ?? 0);
  if (failed) await env.OAUTH_KV.put(key, String(n + 1), { expirationTtl: 3600 });
  return n >= 20;
}

export async function handleAPI(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const parts = url.pathname.split('/').slice(2).map(decodeURIComponent);
  const owner = await isOwner(request, env);
  if (await tooManyFailures(env, request, !owner && !!bearer(request))) return json({ error: 'Too many wrong secrets. Try again in an hour.' }, 429);
  if (parts[0] === 'hello' && request.method === 'GET') {
    const scheme = /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(env.MCP_HOST) ? 'http' : 'https';
    return json({ mossad: true, version, authorized: owner, mcp: `${scheme}://${env.MCP_HOST}${(env.MCP_PATH || '/mossad').replace(/\/$/, '')}`, chat: !!env.ANTHROPIC_API_KEY });
  }
  if (!owner) return json({ error: 'The secret is wrong or missing.' }, 401);

  const [kind, a, b] = parts;
  const m = request.method;
  try {
    if (kind === 'config' && m === 'PUT') return putConfig(request, env);
    if (kind === 'assets' && a && b && name.test(a) && assetKey.test(b)) {
      const key = `records/${a}/${b}`;
      if (m === 'PUT') { await env.FILES.put(key, request.body); return json({ ok: true }); }
      if (m === 'GET') {
        const object = await env.FILES.get(key);
        return object ? new Response(object.body, { headers: { 'Content-Type': 'application/octet-stream' } }) : json({ error: 'No such asset.' }, 404);
      }
    }
    if (kind === 'records' && a && name.test(a)) {
      if (m === 'PUT') return putRecord(request, env, a);
      if (m === 'DELETE') return deleteRecord(env, a);
    }
    if (kind === 'changes' && m === 'GET') return changes(env, Number(url.searchParams.get('since') ?? 0) || 0);
    if (kind === 'shares') {
      if (!a && m === 'GET') return listShares(env);
      if (a && shareID.test(a)) {
        if (!b && m === 'PUT') return putShare(request, env, a);
        if (!b && m === 'DELETE') { await deleteShare(env, a); return json({ ok: true }); }
        if (b === 'audio' && m === 'PUT') { await env.FILES.put(`shares/${a}/audio.m4a`, request.body); return json({ ok: true }); }
      }
    }
  } catch (error) {
    console.error('api failed', error instanceof Error ? error.message : error);
    return json({ error: 'The server failed.' }, 500);
  }
  return json({ error: 'Not found.' }, 404);
}

async function putConfig(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const rows = ['owner', 'timeZone'].filter((k) => typeof body[k] === 'string')
    .map((k) => env.DB.prepare('INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').bind(k, body[k] as string));
  if (rows.length) await env.DB.batch(rows);
  return json({ ok: true });
}

interface RecordBody { type: string; fields?: Record<string, unknown>; assets?: string[] }

async function putRecord(request: Request, env: Env, recordName: string): Promise<Response> {
  const body = (await request.json()) as RecordBody;
  if (typeof body.type !== 'string' || !/^[A-Za-z]{1,40}$/.test(body.type)) return json({ error: 'Bad type.' }, 400);
  const assets = (body.assets ?? []).filter((k) => assetKey.test(k));
  const result = await env.DB.prepare(`INSERT INTO records (name, type, fields, assets, seq, deleted, updated)
      VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM records), 0, ?)
      ON CONFLICT(name) DO UPDATE SET type = excluded.type, fields = excluded.fields, assets = excluded.assets,
        seq = excluded.seq, deleted = 0, updated = excluded.updated
      RETURNING seq`)
    .bind(recordName, body.type, JSON.stringify(body.fields ?? {}), JSON.stringify(assets), new Date().toISOString()).first<{ seq: number }>();
  if (body.type === 'Meeting' && assets.includes('view')) await indexMeeting(env, recordName);
  return json({ ok: true, seq: result?.seq });
}

async function deleteRecord(env: Env, recordName: string): Promise<Response> {
  const row = await env.DB.prepare('SELECT type, assets FROM records WHERE name = ?').bind(recordName).first<{ type: string; assets: string }>();
  if (row) {
    const keys = (JSON.parse(row.assets) as string[]).map((k) => `records/${recordName}/${k}`);
    if (keys.length) await env.FILES.delete(keys);
  }
  await env.DB.batch([
    env.DB.prepare(`UPDATE records SET deleted = 1, assets = '[]', fields = '{}', updated = ?,
      seq = (SELECT COALESCE(MAX(seq), 0) + 1 FROM records) WHERE name = ?`).bind(new Date().toISOString(), recordName),
    env.DB.prepare('DELETE FROM meetings WHERE id = ?').bind(recordName),
    env.DB.prepare('DELETE FROM lines WHERE call_id = ?').bind(recordName),
  ]);
  return json({ ok: true });
}

async function changes(env: Env, since: number): Promise<Response> {
  const page = 100;
  const { results } = await env.DB.prepare('SELECT name, type, fields, assets, seq, deleted FROM records WHERE seq > ? ORDER BY seq LIMIT ?')
    .bind(since, page + 1).all<{ name: string; type: string; fields: string; assets: string; seq: number; deleted: number }>();
  const rows = results.slice(0, page);
  return json({
    changes: rows.map((r) => ({ name: r.name, type: r.type, fields: JSON.parse(r.fields), assets: JSON.parse(r.assets), deleted: r.deleted === 1 })),
    token: rows.length ? rows[rows.length - 1].seq : since,
    more: results.length > page,
  });
}

/** Copies a meeting's view into the tables the MCP reads. */
export async function indexMeeting(env: Env, id: string) {
  const object = await env.FILES.get(`records/${id}/view`);
  if (!object) return;
  const view = (await object.json()) as MeetingView;
  const { lines, ...rest } = view;
  const statements = [
    env.DB.prepare('DELETE FROM lines WHERE call_id = ?').bind(id),
    env.DB.prepare('INSERT INTO meetings (id, start, view) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET start = excluded.start, view = excluded.view')
      .bind(id, Date.parse(view.start), JSON.stringify(rest)),
    ...lines.map((l) => env.DB.prepare('INSERT INTO lines (call_id, at, speaker, text) VALUES (?, ?, ?, ?)').bind(id, l.at, l.speaker, l.text)),
  ];
  for (let i = 0; i < statements.length; i += 500) await env.DB.batch(statements.slice(i, i + 500));
}

async function putShare(request: Request, env: Env, id: string): Promise<Response> {
  const share = (await request.json()) as Share;
  if (typeof share.title !== 'string' || typeof share.start !== 'string') return json({ error: 'Bad share.' }, 400);
  await env.FILES.put(`shares/${id}/share.json`, JSON.stringify(share), { httpMetadata: { contentType: 'application/json' } });
  if (!share.audio) await env.FILES.delete(`shares/${id}/audio.m4a`);
  await env.DB.prepare(`INSERT INTO shares (id, title, created, expires, audio, chat) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, expires = excluded.expires, audio = excluded.audio, chat = excluded.chat`)
    .bind(id, share.title, new Date().toISOString(), share.expires, share.audio ? 1 : 0, share.chat ? 1 : 0).run();
  return json({ ok: true });
}

async function listShares(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare('SELECT id, title, created, expires, audio, chat, views, questions FROM shares ORDER BY created DESC').all();
  return json({ shares: results });
}
