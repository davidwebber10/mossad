// The owner check for /stats. Cloudflare Access signs a JWT for each request it lets through; the Worker checks
// the signature against the team's public keys, the audience, the issuer, the time, and the email.

export interface AccessConfig { teamDomain?: string; audience?: string; ownerEmail?: string }

interface Jwk { kid: string; kty: string; n: string; e: string; alg?: string }

type Fetch = (url: string) => Promise<Response>;

const CERTS_TTL_MS = 10 * 60 * 1000;
let certsCache: { url: string; at: number; keys: Jwk[] } | null = null;

export function clearCertsCache() { certsCache = null; }

function b64url(input: string): Uint8Array {
  const b64 = input.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((input.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function team(domain: string): string {
  return domain.replace(/^https?:\/\//, '').replace(/\/+$/, '');
}

async function certs(url: string, fetcher: Fetch, now: number): Promise<Jwk[]> {
  if (certsCache && certsCache.url === url && now - certsCache.at < CERTS_TTL_MS) return certsCache.keys;
  const response = await fetcher(url);
  if (!response.ok) throw new Error('certs unavailable');
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
    const keys = await certs(`https://${domain}/cdn-cgi/access/certs`, fetcher, now);
    const jwk = keys.find((k) => k.kid === header.kid);
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
