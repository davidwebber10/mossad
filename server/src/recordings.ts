import type { Env } from './types';
import { json, privateHeaders } from './util';

/**
 * The recording backup: each meeting's recording.m4a in FILES under recordings/. The Mac uploads it after the
 * note is written, plays it from here when its local copy is gone, and deletes it with the meeting.
 */

/** Under Cloudflare's 100 MB request limit on the Free and Pro plans. About seven hours of a meeting. */
const defaultMaxMB = 95;
/** The longest a signed link may last. The Mac asks for a few hours. */
export const maxLinkSeconds = 24 * 3600;
const sha = /^[0-9a-f]{64}$/;

export const recordingKey = (name: string) => `recordings/${name}/recording.m4a`;

export function maxRecordingBytes(env: Env): number {
  const mb = Number(env.RECORDING_MAX_MB);
  return (Number.isFinite(mb) && mb > 0 ? mb : defaultMaxMB) * 1024 * 1024;
}

/**
 * This server's own id, made at the owner's first call and kept in the bucket that holds the recordings. The Mac
 * saves it with each recording it sends, so a recording on another server (another bucket) is never taken for one
 * that is here.
 */
export async function serverID(env: Env): Promise<string> {
  const key = 'server-id';
  const found = await env.FILES.get(key);
  if (found) return (await found.text()).trim();
  // Only the first writer wins, and each caller reads what was kept, so two first calls at once get one id.
  await env.FILES.put(key, crypto.randomUUID(), { onlyIf: new Headers({ 'If-None-Match': '*' }) });
  const kept = await env.FILES.get(key);
  if (!kept) throw new Error('The server id could not be saved.');
  return (await kept.text()).trim();
}

function hmacKey(secret: string, usage: 'sign' | 'verify'): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [usage]);
}

const linkText = (name: string, expires: number) => new TextEncoder().encode(`mossad-recording\n${name}\n${expires}`);

/** The signature of a link to one recording until `expires` (seconds since 1970), as hex. The Mac makes the same. */
export async function linkSignature(secret: string, name: string, expires: number): Promise<string> {
  const mac = await crypto.subtle.sign('HMAC', await hmacKey(secret, 'sign'), linkText(name, expires));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * What a signed address is: 'valid'; 'expired' when the owner's signature is right and its time is over; 'wrong'
 * for anything else. Only 'wrong' is a failed try at the secret: an old link in a player proves the secret was known.
 */
export async function checkLink(env: Env, name: string, url: URL): Promise<'valid' | 'expired' | 'wrong'> {
  const expires = Number(url.searchParams.get('expires'));
  const signature = url.searchParams.get('signature') ?? '';
  const now = Math.floor(Date.now() / 1000);
  if (!env.OWNER_SECRET || !Number.isInteger(expires) || expires > now + maxLinkSeconds + 300 || !sha.test(signature)) return 'wrong';
  const bytes = new Uint8Array(signature.match(/../g)!.map((h) => parseInt(h, 16)));
  const signed = await crypto.subtle.verify('HMAC', await hmacKey(env.OWNER_SECRET, 'verify'), bytes, linkText(name, expires));
  if (!signed) return 'wrong';
  return expires < now ? 'expired' : 'valid';
}

/** An audio file from FILES, with byte ranges so a player can seek. Null when it is not there. */
export async function audioResponse(request: Request, env: Env, key: string): Promise<Response | null> {
  const range = request.headers.get('Range');
  const object = await env.FILES.get(key, range ? { range: request.headers } : {});
  if (!object) return null;
  const headers = privateHeaders({ 'Content-Type': 'audio/mp4', 'Accept-Ranges': 'bytes', 'Content-Disposition': 'inline' });
  const body = request.method === 'HEAD' ? null : (object as R2ObjectBody).body;
  const r = (object as R2ObjectBody).range as { offset?: number; length?: number } | undefined;
  if (range && r && r.offset !== undefined) {
    const length = r.length ?? object.size - r.offset;
    headers.set('Content-Range', `bytes ${r.offset}-${r.offset + length - 1}/${object.size}`);
    headers.set('Content-Length', String(length));
    return new Response(body, { status: 206, headers });
  }
  headers.set('Content-Length', String(object.size));
  return new Response(body, { headers });
}

/** A recording for the owner, or for a link the owner signed. */
export async function readRecording(request: Request, env: Env, name: string): Promise<Response> {
  return (await audioResponse(request, env, recordingKey(name))) ?? json({ error: 'No such recording.' }, 404);
}

/** The owner's calls on one recording: PUT, HEAD, GET, DELETE. Null for another method. */
export async function handleRecording(request: Request, env: Env, name: string): Promise<Response | null> {
  const key = recordingKey(name);
  switch (request.method) {
    case 'PUT': return put(request, env, key);
    case 'HEAD': {
      const object = await env.FILES.head(key);
      if (!object) return json({ error: 'No such recording.' }, 404);
      // The size and the hash in headers of their own: a HEAD answer has no body, and a proxy may drop its length.
      const headers = privateHeaders({ 'Content-Type': 'audio/mp4', 'X-Recording-Size': String(object.size) });
      const hash = object.customMetadata?.sha256;
      if (hash) headers.set('X-Recording-SHA256', hash);
      return new Response(null, { headers });
    }
    case 'GET': return readRecording(request, env, name);
    case 'DELETE':
      await env.FILES.delete(key);
      return json({ ok: true });
    default: return null;
  }
}

async function put(request: Request, env: Env, key: string): Promise<Response> {
  const length = Number(request.headers.get('Content-Length') ?? NaN);
  if (!request.body || !Number.isInteger(length) || length <= 0) return json({ error: 'Send the recording with its length.' }, 411);
  const max = maxRecordingBytes(env);
  // Before the body is read: a file over the limit costs no upload.
  if (length > max) return json({ error: `A recording can be up to ${Math.floor(max / 1024 / 1024)} MB on this server.`, maxBytes: max }, 413);
  const hash = (request.headers.get('X-Recording-SHA256') ?? '').toLowerCase();
  if (hash && !sha.test(hash)) return json({ error: 'Bad checksum.' }, 400);
  let object: R2Object;
  try {
    // The body streams into the bucket. With a hash, R2 checks the bytes itself and stores nothing on a mismatch.
    object = await env.FILES.put(key, request.body, {
      httpMetadata: { contentType: 'audio/mp4' },
      ...(hash ? { sha256: hash, customMetadata: { sha256: hash } } : {}),
    });
  } catch (error) {
    if (hash && /checksum|sha-?256|digest/i.test(error instanceof Error ? error.message : '')) {
      return json({ error: 'The recording did not arrive whole. Send it again.' }, 422);
    }
    throw error;
  }
  if (object.size !== length) {
    await env.FILES.delete(key);
    return json({ error: 'The recording did not arrive whole. Send it again.' }, 422);
  }
  return json({ ok: true, size: object.size, ...(hash ? { sha256: hash } : {}) });
}
