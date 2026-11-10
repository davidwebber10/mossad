import { beforeEach, describe, expect, it } from 'vitest';
import { handleAPI } from '../src/api';
import { linkSignature, recordingKey } from '../src/recordings';
import { handleShareHost } from '../src/share';
import type { Env } from '../src/types';
import { sha256Hex } from '../src/util';

async function hex(bytes: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

interface Stored { bytes: Uint8Array; customMetadata?: Record<string, string> }

async function bytesOf(body: unknown): Promise<Uint8Array> {
  if (body == null) return new Uint8Array();
  return new Uint8Array(await new Response(body as BodyInit).arrayBuffer());
}

/** An R2 stand-in: objects in memory, with the checksum check and byte ranges that the Worker relies on. */
function fakeFiles() {
  const objects = new Map<string, Stored>();
  const files = {
    objects,
    async put(key: string, body: unknown, options: { sha256?: string; customMetadata?: Record<string, string> } = {}) {
      const bytes = await bytesOf(body);
      if (options.sha256 && (await hex(bytes)) !== options.sha256) {
        throw new Error('put: The SHA-256 checksum you specified did not match what we received.');
      }
      objects.set(key, { bytes, customMetadata: options.customMetadata });
      return { key, size: bytes.length, customMetadata: options.customMetadata };
    },
    async head(key: string) {
      const o = objects.get(key);
      return o ? { key, size: o.bytes.length, customMetadata: o.customMetadata } : null;
    },
    async get(key: string, options: { range?: Headers } = {}) {
      const o = objects.get(key);
      if (!o) return null;
      const m = /^bytes=(\d+)-(\d*)$/.exec(options.range?.get('Range') ?? '');
      if (!m) return { key, size: o.bytes.length, body: new Blob([o.bytes]).stream(), customMetadata: o.customMetadata, async json() { return JSON.parse(new TextDecoder().decode(o.bytes)); } };
      const offset = Number(m[1]), end = m[2] ? Number(m[2]) : o.bytes.length - 1;
      return { key, size: o.bytes.length, range: { offset, length: end - offset + 1 }, body: new Blob([o.bytes.slice(offset, end + 1)]).stream() };
    },
    async delete(keys: string | string[]) { for (const k of [keys].flat()) objects.delete(k); },
  };
  return files;
}

function fakeEnv(extra: Partial<Env> = {}) {
  const kv = new Map<string, string>();
  const files = fakeFiles();
  const statement = { bind() { return statement; }, async run() { return {}; }, async first() { return null; }, async all() { return { results: [] }; } };
  const env = {
    FILES: files,
    OAUTH_KV: { async get(k: string) { return kv.get(k) ?? null; }, async put(k: string, v: string) { kv.set(k, v); } },
    DB: { prepare() { return statement; }, async batch() { return []; } },
    SHARE_HOST: 'notes.example.com', MCP_HOST: 'mcp.example.com', MCP_PATH: '/mossad', REPO_URL: 'https://example.com/repo', OWNER_SECRET: 'owner-secret',
    ...extra,
  };
  return { env: env as unknown as Env, files, kv };
}

const base = 'https://notes.example.com/api/recordings';
const auth = { Authorization: 'Bearer owner-secret' };
const audio = new TextEncoder().encode('recording-bytes-0123456789');
const hash = await hex(audio);

function put(name: string, body: Uint8Array = audio, headers: Record<string, string> = {}) {
  return new Request(`${base}/${name}`, { method: 'PUT', headers: { ...auth, 'Content-Length': String(body.length), 'Content-Type': 'audio/mp4', ...headers }, body });
}

describe('recording backup', () => {
  let e: ReturnType<typeof fakeEnv>;
  beforeEach(() => { e = fakeEnv(); });

  it('says in hello how large a recording can be', async () => {
    const hello = await (await handleAPI(new Request('https://notes.example.com/api/hello'), e.env)).json() as { recordings: { maxBytes: number } };
    expect(hello.recordings.maxBytes).toBe(95 * 1024 * 1024);
    const small = fakeEnv({ RECORDING_MAX_MB: '10' });
    const other = await (await handleAPI(new Request('https://notes.example.com/api/hello'), small.env)).json() as { recordings: { maxBytes: number } };
    expect(other.recordings.maxBytes).toBe(10 * 1024 * 1024);
  });

  it('needs the secret for every call', async () => {
    for (const method of ['PUT', 'HEAD', 'GET', 'DELETE']) {
      const r = await handleAPI(new Request(`${base}/m1`, { method, body: method === 'PUT' ? audio : undefined }), e.env);
      expect(r.status, method).toBe(401);
    }
    expect(e.files.objects.size).toBe(0);
  });

  it('stores a recording under recordings/ and reports its size and hash', async () => {
    const r = await handleAPI(put('20261105-090000', audio, { 'X-Recording-SHA256': hash }), e.env);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, size: audio.length, sha256: hash });
    expect(e.files.objects.get('recordings/20261105-090000/recording.m4a')?.bytes).toEqual(audio);
    expect(recordingKey('20261105-090000')).toBe('recordings/20261105-090000/recording.m4a');

    const head = await handleAPI(new Request(`${base}/20261105-090000`, { method: 'HEAD', headers: auth }), e.env);
    expect(head.status).toBe(200);
    expect(head.headers.get('X-Recording-Size')).toBe(String(audio.length));
    expect(head.headers.get('X-Recording-SHA256')).toBe(hash);
  });

  it('answers 404 for a recording it does not have', async () => {
    expect((await handleAPI(new Request(`${base}/none`, { method: 'HEAD', headers: auth }), e.env)).status).toBe(404);
    expect((await handleAPI(new Request(`${base}/none`, { headers: auth }), e.env)).status).toBe(404);
  });

  it('refuses a recording whose bytes do not match the hash, and keeps nothing', async () => {
    const r = await handleAPI(put('m1', audio, { 'X-Recording-SHA256': 'a'.repeat(64) }), e.env);
    expect(r.status).toBe(422);
    expect(e.files.objects.size).toBe(0);
    expect((await handleAPI(put('m1', audio, { 'X-Recording-SHA256': 'not-a-hash' }), e.env)).status).toBe(400);
  });

  it('refuses a recording over the limit before it reads the body', async () => {
    const small = fakeEnv({ RECORDING_MAX_MB: '1' });
    const r = await handleAPI(put('m1', audio, { 'Content-Length': String(1024 * 1024 + 1) }), small.env);
    expect(r.status).toBe(413);
    expect(((await r.json()) as { maxBytes: number }).maxBytes).toBe(1024 * 1024);
    expect(small.files.objects.size).toBe(0);
  });

  it('refuses an upload with no length, and a name that could leave the folder', async () => {
    const noLength = new Request(`${base}/m1`, { method: 'PUT', headers: auth, body: audio });
    noLength.headers.delete('Content-Length');
    expect((await handleAPI(noLength, e.env)).status).toBe(411);
    expect((await handleAPI(put('..%2F..%2Fshares'), e.env)).status).toBe(404);
    expect((await handleAPI(put('m1/extra'), e.env)).status).toBe(404);
    expect(e.files.objects.size).toBe(0);
  });

  it('gives the recording back, whole or as a byte range', async () => {
    await handleAPI(put('m1', audio, { 'X-Recording-SHA256': hash }), e.env);
    const whole = await handleAPI(new Request(`${base}/m1`, { headers: auth }), e.env);
    expect(whole.status).toBe(200);
    expect(whole.headers.get('Content-Type')).toBe('audio/mp4');
    expect(whole.headers.get('Cache-Control')).toContain('no-store');
    expect(new Uint8Array(await whole.arrayBuffer())).toEqual(audio);
    const part = await handleAPI(new Request(`${base}/m1`, { headers: { ...auth, Range: 'bytes=4-9' } }), e.env);
    expect(part.status).toBe(206);
    expect(part.headers.get('Content-Range')).toBe(`bytes 4-9/${audio.length}`);
    expect(new TextDecoder().decode(await part.arrayBuffer())).toBe('rding-');
  });

  it('deletes a recording, and a second delete is not an error', async () => {
    await handleAPI(put('m1'), e.env);
    expect((await handleAPI(new Request(`${base}/m1`, { method: 'DELETE', headers: auth }), e.env)).status).toBe(200);
    expect(e.files.objects.size).toBe(0);
    expect((await handleAPI(new Request(`${base}/m1`, { method: 'DELETE', headers: auth }), e.env)).status).toBe(200);
  });

  it('plays from a link the owner signed, until it expires, and only that recording', async () => {
    await handleAPI(put('m1'), e.env);
    await handleAPI(put('m2'), e.env);
    const expires = Math.floor(Date.now() / 1000) + 3600;
    const signature = await linkSignature('owner-secret', 'm1', expires);
    const ok = await handleAPI(new Request(`${base}/m1?expires=${expires}&signature=${signature}`), e.env);
    expect(ok.status).toBe(200);
    expect(new Uint8Array(await ok.arrayBuffer())).toEqual(audio);
    expect((await handleAPI(new Request(`${base}/m2?expires=${expires}&signature=${signature}`), e.env)).status).toBe(401);
    expect((await handleAPI(new Request(`${base}/m1?expires=${expires + 1}&signature=${signature}`), e.env)).status).toBe(401);
    // A link cannot write or delete.
    expect((await handleAPI(new Request(`${base}/m1?expires=${expires}&signature=${signature}`, { method: 'DELETE' }), e.env)).status).toBe(401);
    expect(e.files.objects.has('recordings/m1/recording.m4a')).toBe(true);
  });

  it('signs a link the same way the Mac does', async () => {
    // The same numbers are in ServerArchiveTests.swift: the two sides must agree.
    expect(await linkSignature('owner-secret', 'm1', 1_900_000_000)).toBe('b1a6528b814eb22cc4554267b696a0c5c588aba87d7ab9dcc506789e45c315ce');
  });

  it('refuses a link that expired, one that lasts too long, and one made with another secret', async () => {
    await handleAPI(put('m1'), e.env);
    const now = Math.floor(Date.now() / 1000);
    const old = now - 10, far = now + 30 * 86_400, soon = now + 60;
    expect((await handleAPI(new Request(`${base}/m1?expires=${old}&signature=${await linkSignature('owner-secret', 'm1', old)}`), e.env)).status).toBe(401);
    expect((await handleAPI(new Request(`${base}/m1?expires=${far}&signature=${await linkSignature('owner-secret', 'm1', far)}`), e.env)).status).toBe(401);
    expect((await handleAPI(new Request(`${base}/m1?expires=${soon}&signature=${await linkSignature('guess', 'm1', soon)}`), e.env)).status).toBe(401);
    expect((await handleAPI(new Request(`${base}/m1?expires=${soon}&signature=zz`), e.env)).status).toBe(401);
  });

  it('does not count a link that only expired as a wrong secret', async () => {
    // A player that still holds yesterday's link must not lock the owner's own sync out.
    const old = Math.floor(Date.now() / 1000) - 10, signature = await linkSignature('owner-secret', 'm1', old);
    let last = 0;
    for (let i = 0; i < 25; i++) last = (await handleAPI(new Request(`${base}/m1?expires=${old}&signature=${signature}`), e.env)).status;
    expect(last).toBe(401);
    expect((await handleAPI(new Request(`${base}/m1`, { method: 'HEAD', headers: auth }), e.env)).status).toBe(404);
  });

  it('counts wrong links like wrong secrets, and pauses after too many', async () => {
    const soon = Math.floor(Date.now() / 1000) + 60;
    let last = 0;
    for (let i = 0; i < 22; i++) last = (await handleAPI(new Request(`${base}/m1?expires=${soon}&signature=${'0'.repeat(64)}`), e.env)).status;
    expect(last).toBe(429);
  });
});

describe('share links still play their own audio', () => {
  it('serves the copy under shares/, with ranges', async () => {
    const { env, files } = fakeEnv();
    const token = 'A'.repeat(43), id = await sha256Hex(token);
    files.objects.set(`shares/${id}/share.json`, { bytes: new TextEncoder().encode(JSON.stringify({ title: 'T', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', people: [], owner: 'Dana', audio: true, chat: false, expires: null })) });
    files.objects.set(`shares/${id}/audio.m4a`, { bytes: audio });
    const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
    const whole = await handleShareHost(new Request(`https://notes.example.com/${token}/audio`), env, ctx);
    expect(whole?.status).toBe(200);
    expect(whole?.headers.get('Content-Length')).toBe(String(audio.length));
    const part = await handleShareHost(new Request(`https://notes.example.com/${token}/audio`, { headers: { Range: 'bytes=0-3' } }), env, ctx);
    expect(part?.status).toBe(206);
    expect(part?.headers.get('Content-Range')).toBe(`bytes 0-3/${audio.length}`);
  });
});
