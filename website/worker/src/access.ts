// The owner check for /stats. Cloudflare Access signs a JWT for each request it lets through; the Worker checks
// the signature against the team's public keys, the audience, the issuer, the time, and the email.

export interface AccessConfig { teamDomain?: string; audience?: string; ownerEmail?: string }

interface Jwk { kid: string; kty: string; n: string; e: string; alg?: string }

type Fetch = (url: string) => Promise<Response>;

const CERTS_TTL_MS = 10 * 60 * 1000;
const RETRY_MS = 60 * 1000;
let certsCache: { url: string; at: number; keys: Jwk[] } | null = null;
let failedAt: { url: string; at: number } | null = null;

export function clearCertsCache() { certsCache = null; failedAt = null; }

function b64url(input: string): Uint8Array {
  const b64 = input.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((input.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function team(domain: string): string {
  return domain.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/+$/, '');
}

/** The team's keys. Cached for 10 minutes; read again early only for an unknown key id, at most once a minute. A failed read waits a minute. */
async function certs(url: string, fetcher: Fetch, now: number, unknownKid = false): Promise<Jwk[]> {
  if (certsCache && certsCache.url === url) {
    const age = now - certsCache.at;
    if (unknownKid ? age < RETRY_MS : age < CERTS_TTL_MS) return certsCache.keys;
  }
  if (failedAt && failedAt.url === url && now - failedAt.at < RETRY_MS) throw new Error('certs unavailable');
  let response: Response;
  try { response = await fetcher(url); } catch (error) { failedAt = { url, at: now }; throw error; }
  if (!response.ok) { failedAt = { url, at: now }; throw new Error('certs unavailable'); }
  failedAt = null;
  const body = await response.json() as { keys?: Jwk[] };
  const keys = (body.keys ?? []).filter((k) => k.kty === 'RSA');
  certsCache = { url, at: now, keys };
  return keys;
}

/** The owner's email when the token is valid and is the owner's, else null. Never throws. */
export async function verifyAccess(token: string | null, config: AccessConfig, fetcher: Fetch = (u) => fetch(u), now = Date.now()): Promise<string | null> {
  try {
    if (!token || !config.teamDomain || !config.audience || !config.ownerEmail) return null;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const header = JSON.parse(new TextDecoder().decode(b64url(parts[0]))) as { alg?: string; kid?: string };
    if (header.alg !== 'RS256' || !header.kid) return null;
    const domain = team(config.teamDomain);
    const url = `https://${domain}/cdn-cgi/access/certs`;
    let jwk = (await certs(url, fetcher, now)).find((k) => k.kid === header.kid);
    if (!jwk) jwk = (await certs(url, fetcher, now, true)).find((k) => k.kid === header.kid);
    if (!jwk) return null;
    const key = await crypto.subtle.importKey('jwk', { kty: 'RSA', n: jwk.n, e: jwk.e, alg: 'RS256', ext: true }, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!ok) return null;
    const claims = JSON.parse(new TextDecoder().decode(b64url(parts[1]))) as { aud?: string | string[]; iss?: string; exp?: number; nbf?: number; email?: string };
    const seconds = now / 1000;
    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!audiences.includes(config.audience)) return null;
    if (claims.iss !== `https://${domain}`) return null;
    if (typeof claims.exp !== 'number' || claims.exp < seconds - 30) return null;
    if (typeof claims.nbf === 'number' && claims.nbf > seconds + 30) return null;
    if (typeof claims.email !== 'string' || claims.email.toLowerCase() !== config.ownerEmail.trim().toLowerCase()) return null;
    return claims.email;
  } catch {
    return null;
  }
}
