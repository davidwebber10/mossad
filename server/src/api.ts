import { checkLink, handleRecording, maxRecordingBytes, readRecording, serverID } from './recordings';
import { hashPIN, isPIN, newPIN } from './access';
import { deleteCopy, deleteShare } from './share';
import type { Env, MeetingView, Share } from './types';
import { bearer, json, sameSecret } from './util';
import { missingSchema, shareDetail, shareRows } from './views';

/** The owner API: the Mac and the iPhone sync through it and manage share links. Every call needs the secret. */

export const version = 1;
/** What the share calls can do: 2 adds the PIN, the views, the change of an expiry, and one share's numbers. */
export const sharesVersion = 2;
const name = /^[A-Za-z0-9._-]{1,200}$/;
const assetKey = /^[a-z]{1,20}$/;
const shareID = /^[0-9a-f]{64}$/;

export async function isOwner(request: Request, env: Env): Promise<boolean> {
  return sameSecret(bearer(request), env.OWNER_SECRET);
}

/** Wrong secrets from one address: 20 an hour, then a pause. `count` names what is counted, each on its own. */
export async function tooManyFailures(env: Env, request: Request, failed: boolean, count = 'fail'): Promise<boolean> {
  const key = `${count}:${request.headers.get('CF-Connecting-IP') ?? 'unknown'}:${Math.floor(Date.now() / 3_600_000)}`;
  const n = Number((await env.OAUTH_KV.get(key)) ?? 0);
  if (failed) await env.OAUTH_KV.put(key, String(n + 1), { expirationTtl: 3600 });
  return n >= 20;
}

export async function handleAPI(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  let parts: string[];
  // A path such as "/api/%E0" does not decode; that is a bad request, not a server failure.
  try { parts = url.pathname.split('/').slice(2).map(decodeURIComponent); } catch { return json({ error: 'Not found.' }, 404); }
  const owner = await isOwner(request, env);
  // A link to one recording that the owner's app signed plays without the secret in a header. It only reads.
  const signed = !owner && parts[0] === 'recordings' && parts.length === 2 && name.test(parts[1]) && url.searchParams.has('signature')
    && (request.method === 'GET' || request.method === 'HEAD');
  if (signed) {
    const link = await checkLink(env, parts[1], url);
    // Counted apart from wrong secrets: an old link in a player must not pause the owner's own sync.
    if (await tooManyFailures(env, request, link === 'wrong', 'fail-link')) return json({ error: 'Too many wrong links. Try again in an hour.' }, 429);
    if (link === 'expired') return json({ error: 'This link has expired.' }, 401);
    if (link === 'wrong') return json({ error: 'The link is wrong.' }, 401);
    try { return await readRecording(request, env, parts[1]); } catch (error) {
      console.error('recording link failed', error instanceof Error ? error.message : error);
      return json({ error: 'The server failed.' }, 500);
    }
  }
  if (await tooManyFailures(env, request, !owner && !!bearer(request))) return json({ error: 'Too many wrong secrets. Try again in an hour.' }, 429);
  if (parts[0] === 'hello' && request.method === 'GET') {
    const scheme = /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(env.MCP_HOST) ? 'http' : 'https';
    return json({
      mossad: true, version, authorized: owner, shares: sharesVersion, mcp: `${scheme}://${env.MCP_HOST}${(env.MCP_PATH || '/mossad').replace(/\/$/, '')}`, chat: !!env.ANTHROPIC_API_KEY,
      // Present on a server that keeps recordings: the Mac offers the backup only then. The id is for the owner.
      recordings: { maxBytes: maxRecordingBytes(env), ...(owner ? { id: await serverID(env).catch(() => undefined) } : {}) },
    });
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
    if (kind === 'recordings' && a && !b && parts.length === 2 && name.test(a)) {
      const answer = await handleRecording(request, env, a);
      if (answer) return answer;
    }
    if (kind === 'records' && a && name.test(a)) {
      if (m === 'PUT') return putRecord(request, env, a);
      if (m === 'DELETE') return deleteRecord(env, a);
    }
    if (kind === 'changes' && m === 'GET') return changes(env, Number(url.searchParams.get('since') ?? 0) || 0);
    if (kind === 'shares') {
      if (!a && m === 'GET') return await listShares(env);
      if (a && shareID.test(a) && parts.length <= 3) {
        if (!b && m === 'PUT') return await putShare(request, env, a);
        if (!b && m === 'GET') { const detail = await shareDetail(env, a); return detail ? json(detail) : json({ error: 'No such share.' }, 404); }
        if (!b && m === 'PATCH') return await patchShare(request, env, a);
        if (!b && m === 'DELETE') { await deleteShare(env, a); return json({ ok: true }); }
        if (b === 'audio' && m === 'PUT') { await env.FILES.put(`shares/${a}/audio.m4a`, request.body); return json({ ok: true }); }
        if (b === 'pin' && (m === 'PUT' || m === 'DELETE')) return await setPIN(request, env, a, m === 'PUT');
      }
    }
  } catch (error) {
    if (kind === 'shares' && missingSchema(error)) {
      return json({ error: 'The database of this server is from before this call. Run: npx wrangler d1 migrations apply <database name> --remote', migrate: true }, 503);
    }
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

const linesPerInsert = 25;

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
  ];
  // 25 lines per statement (D1 takes 100 values in one), so a meeting of up to about 12,000 lines is one batch. A
  // batch is one transaction: a failure leaves the old lines, not half of the new ones.
  for (let i = 0; i < lines.length; i += linesPerInsert) {
    const rows = lines.slice(i, i + linesPerInsert);
    statements.push(env.DB.prepare(`INSERT INTO lines (call_id, at, speaker, text) VALUES ${rows.map(() => '(?, ?, ?, ?)').join(', ')}`)
      .bind(...rows.flatMap((l) => [id, l.at, l.speaker, l.text])));
  }
  for (let i = 0; i < statements.length; i += 500) await env.DB.batch(statements.slice(i, i + 500));
}

async function putShare(request: Request, env: Env, id: string): Promise<Response> {
  const share = (await request.json()) as Share;
  if (typeof share.title !== 'string' || typeof share.start !== 'string') return json({ error: 'Bad share.' }, 400);
  await env.FILES.put(`shares/${id}/share.json`, JSON.stringify(share), { httpMetadata: { contentType: 'application/json' } });
  if (!share.audio) await env.FILES.delete(`shares/${id}/audio.m4a`);
  // The PIN and the views are not in this statement: sending a share again keeps them.
  const upsert = (gone: string) => env.DB.prepare(`INSERT INTO shares (id, title, created, expires, audio, chat) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, expires = excluded.expires, audio = excluded.audio, chat = excluded.chat${gone}`)
    .bind(id, share.title, new Date().toISOString(), share.expires, share.audio ? 1 : 0, share.chat ? 1 : 0).run();
  try { await upsert(', gone = 0'); } catch (error) {
    if (!missingSchema(error)) throw error;
    await upsert('');
  }
  return json({ ok: true });
}

async function listShares(env: Env): Promise<Response> {
  try {
    const now = Date.now();
    const { rows, shares } = await shareRows(env, now);
    // The copy of an expired share goes here too, not only at a visit; its row stays for the list.
    const expired = rows.filter((r) => r.gone === 0 && r.expires && Date.parse(r.expires) < now).map((r) => r.id);
    await deleteCopy(env, expired);
    return json({ shares: shares.map((s) => (expired.includes(s.id) ? { ...s, gone: true } : s)) });
  } catch (error) {
    if (!missingSchema(error)) throw error;
    const { results } = await env.DB.prepare('SELECT id, title, created, expires, audio, chat, views, questions FROM shares ORDER BY created DESC').all();
    return json({ shares: results, migrate: true });
  }
}

/** Changes when a share expires: on the row and in the copy, which is what a visit reads. */
async function patchShare(request: Request, env: Env, id: string): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { expires?: unknown } | null;
  const expires = body?.expires;
  if (expires !== null && (typeof expires !== 'string' || Number.isNaN(Date.parse(expires)))) return json({ error: 'Send expires as a date, or null for no expiry.' }, 400);
  const row = await env.DB.prepare('SELECT gone FROM shares WHERE id = ?').bind(id).first<{ gone: number }>();
  if (!row) return json({ error: 'No such share.' }, 404);
  const object = row.gone ? null : await env.FILES.get(`shares/${id}/share.json`);
  if (!object) return json({ error: 'The copy of this share was deleted after it expired. Share the meeting again.', gone: true }, 410);
  const share = (await object.json()) as Share;
  await env.FILES.put(`shares/${id}/share.json`, JSON.stringify({ ...share, expires }), { httpMetadata: { contentType: 'application/json' } });
  await env.DB.prepare('UPDATE shares SET expires = ? WHERE id = ?').bind(expires, id).run();
  return json({ ok: true, expires });
}

/**
 * Sets, changes, or removes the PIN of a share. The app may send the 4 digits that it showed its owner; with
 * none, the server makes them. The answer is the only place the PIN leaves from: the database keeps a hash.
 */
async function setPIN(request: Request, env: Env, id: string, on: boolean): Promise<Response> {
  const body = on ? ((await request.json().catch(() => ({}))) as { pin?: unknown } | null) : null;
  if (on && body?.pin !== undefined && !isPIN(body.pin)) return json({ error: 'A PIN is 4 digits.' }, 400);
  const pin = on ? (isPIN(body?.pin) ? body.pin : newPIN()) : null;
  const changed = await env.DB.prepare('UPDATE shares SET pin_hash = ?, pin_set = ? WHERE id = ? RETURNING id')
    .bind(pin ? await hashPIN(env, id, pin) : null, pin ? Date.now() : null, id).first();
  if (!changed) return json({ error: 'No such share.' }, 404);
  // A new PIN starts with no wrong tries, and ends a lock.
  await env.DB.prepare('DELETE FROM share_pin_tries WHERE share_id = ?').bind(id).run();
  return json(pin ? { ok: true, pin } : { ok: true });
}
