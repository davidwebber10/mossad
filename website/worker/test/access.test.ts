import { beforeEach, describe, expect, it } from 'vitest';
import { clearCertsCache, verifyAccess } from '../src/access';
import { handle } from '../src/index';
import { fakeContext, fakeEnv, limiter, validReport } from './fakes';

const team = 'team.cloudflareaccess.com';
const config = { teamDomain: team, audience: 'aud-tag', ownerEmail: 'owner@example.com' };
const NOW = Date.parse('2026-11-12T10:00:00Z');

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

async function keyPair() {
  return crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']) as Promise<CryptoKeyPair>;
}

async function sign(key: CryptoKey, claims: Record<string, unknown>, kid = 'k1', alg = 'RS256') {
  const head = enc({ alg, kid, typ: 'JWT' });
  const body = enc(claims);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

const good = () => ({ aud: ['aud-tag'], iss: `https://${team}`, email: 'Owner@Example.com', exp: NOW / 1000 + 600, iat: NOW / 1000, nbf: NOW / 1000 - 5 });

let pair: CryptoKeyPair;
let certsFetch: (url: string) => Promise<Response>;
let fetched: string[];

beforeEach(async () => {
  clearCertsCache();
  pair = await keyPair();
  const jwk = await crypto.subtle.exportKey('jwk', pair.publicKey) as JsonWebKey;
  fetched = [];
  certsFetch = async (url: string) => { fetched.push(url); return Response.json({ keys: [{ kid: 'k1', kty: 'RSA', alg: 'RS256', n: jwk.n, e: jwk.e }] }); };
});

describe('verifyAccess', () => {
  it('accepts the owner with a valid token from the team', async () => {
    expect(await verifyAccess(await sign(pair.privateKey, good()), config, certsFetch, NOW)).toBe('Owner@Example.com');
    expect(fetched).toEqual([`https://${team}/cdn-cgi/access/certs`]);
  });

  it('refuses another email, audience, issuer, an expired or early token, and a wrong algorithm', async () => {
    const cases: Record<string, unknown>[] = [
      { ...good(), email: 'someone@example.com' },
      { ...good(), aud: ['other-aud'] },
      { ...good(), iss: 'https://evil.cloudflareaccess.com' },
      { ...good(), exp: NOW / 1000 - 120 },
      { ...good(), nbf: NOW / 1000 + 600 },
      { ...good(), email: undefined },
    ];
    for (const claims of cases) expect(await verifyAccess(await sign(pair.privateKey, claims), config, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess(await sign(pair.privateKey, good(), 'k1', 'HS256'), config, certsFetch, NOW)).toBeNull();
  });

  it('refuses a token signed by another key, or with an unknown key id', async () => {
    const other = await keyPair();
    expect(await verifyAccess(await sign(other.privateKey, good()), config, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess(await sign(pair.privateKey, good(), 'k2'), config, certsFetch, NOW)).toBeNull();
  });

  it('refuses a changed payload', async () => {
    const token = await sign(pair.privateKey, good());
    const [h, , s] = token.split('.');
    expect(await verifyAccess(`${h}.${enc({ ...good(), email: 'owner@example.com', admin: true })}.${s}`, config, certsFetch, NOW)).toBeNull();
  });

  it('refuses everything while the settings are empty, or the token is missing or broken', async () => {
    const token = await sign(pair.privateKey, good());
    expect(await verifyAccess(token, { ...config, ownerEmail: '' }, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess(token, { ...config, audience: undefined }, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess(token, { ...config, teamDomain: '' }, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess(null, config, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess('a.b', config, certsFetch, NOW)).toBeNull();
    expect(await verifyAccess('!!.??.##', config, certsFetch, NOW)).toBeNull();
  });

  it('refuses when the certs cannot be read', async () => {
    const token = await sign(pair.privateKey, good());
    expect(await verifyAccess(token, config, async () => new Response('no', { status: 500 }), NOW)).toBeNull();
  });
});

describe('the key list', () => {
  it('reads the keys again for an unknown key id, at most once a minute', async () => {
    const before = await keyPair();
    const beforeJwk = await crypto.subtle.exportKey('jwk', before.publicKey) as JsonWebKey;
    const nowJwk = await crypto.subtle.exportKey('jwk', pair.publicKey) as JsonWebKey;
    let rotated = false;
    const calls: number[] = [];
    const fetcher = async () => {
      calls.push(1);
      const keys = rotated ? [{ kid: 'k2', kty: 'RSA', n: nowJwk.n, e: nowJwk.e }] : [{ kid: 'k1', kty: 'RSA', n: beforeJwk.n, e: beforeJwk.e }];
      return Response.json({ keys });
    };
    expect(await verifyAccess(await sign(before.privateKey, good(), 'k1'), config, fetcher, NOW)).not.toBeNull();
    rotated = true;
    const token = await sign(pair.privateKey, good(), 'k2');
    expect(await verifyAccess(token, config, fetcher, NOW + 61_000)).not.toBeNull();
    expect(calls).toHaveLength(2);
    expect(await verifyAccess(await sign(pair.privateKey, good(), 'k9'), config, fetcher, NOW + 70_000)).toBeNull();
    expect(calls).toHaveLength(2);
  });

  it('remembers a failed read for a minute', async () => {
    let calls = 0;
    const down = async () => { calls++; return new Response('no', { status: 500 }); };
    const token = await sign(pair.privateKey, good());
    await verifyAccess(token, config, down, NOW);
    await verifyAccess(token, config, down, NOW + 30_000);
    expect(calls).toBe(1);
    await verifyAccess(token, config, down, NOW + 61_000);
    expect(calls).toBe(2);
  });

  it('accepts a team domain typed with capitals', async () => {
    expect(await verifyAccess(await sign(pair.privateKey, good()), { ...config, teamDomain: 'Team.CloudflareAccess.com' }, certsFetch, NOW)).not.toBeNull();
  });
});

describe('GET /stats', () => {
  const get = async (env: ReturnType<typeof fakeEnv>['env'], token?: string) => {
    const headers: Record<string, string> = token ? { 'Cf-Access-Jwt-Assertion': token } : {};
    return handle(new Request('https://getmossad.com/stats', { headers }), env, fakeContext().ctx, { now: () => new Date(NOW), ipLimiter: limiter(), newInstallLimiter: limiter(), fetchCerts: certsFetch });
  };

  it('answers 403 with no data without a valid token', async () => {
    const { env } = fakeEnv();
    await handle(Object.assign(new Request('https://getmossad.com/api/telemetry', { method: 'POST', body: JSON.stringify(validReport()), headers: { 'Content-Type': 'application/json' } })), env, fakeContext().ctx, { now: () => new Date(NOW), ipLimiter: limiter(), newInstallLimiter: limiter() });
    for (const token of [undefined, 'x.y.z', await sign(pair.privateKey, { ...good(), email: 'someone@example.com' })]) {
      const response = await get(env, token);
      expect(response.status).toBe(403);
      const text = await response.text();
      expect(text).not.toContain('2.20.0');
      expect(text).not.toContain('Active');
    }
  });

  it('answers 403 when the Access settings are not set yet', async () => {
    const { env } = fakeEnv({ ACCESS_AUD: '' });
    expect((await get(env, await sign(pair.privateKey, good()))).status).toBe(403);
  });

  it('shows the dashboard to the owner, never cached', async () => {
    const { env } = fakeEnv();
    await handle(new Request('https://getmossad.com/api/telemetry', { method: 'POST', body: JSON.stringify(validReport()), headers: { 'Content-Type': 'application/json' } }), env, fakeContext().ctx, { now: () => new Date(NOW), ipLimiter: limiter(), newInstallLimiter: limiter() });
    const response = await get(env, await sign(pair.privateKey, good()));
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toContain('no-store');
    const html = await response.text();
    expect(html).toContain('Mossad stats');
    expect(html).toContain('2.20.0');
    expect(html).toContain('assemblyai');
  });
});
