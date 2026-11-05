export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Constant-time comparison of two secrets: hashing first makes the lengths equal. */
export async function sameSecret(a: string, b: string): Promise<boolean> {
  if (!a || !b) return false;
  const [x, y] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

export function bearer(request: Request): string {
  const h = request.headers.get('Authorization') ?? '';
  return h.startsWith('Bearer ') ? h.slice(7).trim() : '';
}

export const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** A share token: 43 base64url characters, from 32 random bytes. */
export const isToken = (s: string) => /^[A-Za-z0-9_-]{43}$/.test(s);

/** Headers for every response a visitor sees: not indexed, not cached, not framed, no referrer. */
export function privateHeaders(extra: Record<string, string> = {}): Headers {
  return new Headers({
    'X-Robots-Tag': 'noindex, nofollow, noarchive, nosnippet',
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    ...extra,
  });
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: privateHeaders({ 'Content-Type': 'application/json' }) });
}

/** "00:04:05" for 245 seconds, as the notes write it. */
export function timestamp(seconds: number): string {
  const s = Math.floor(seconds);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${p(Math.floor(s / 3600))}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}`;
}

/** The time-zone offset in ms at an instant: local wall time minus UTC. */
function offset(instant: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(instant));
  const v = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  return Date.UTC(v('year'), v('month') - 1, v('day'), v('hour'), v('minute'), v('second')) - instant;
}

/** Midnight at the start of a local day "YYYY-MM-DD", as epoch ms; null when the text is not a date. */
export function localDayStart(day: string, timeZone = 'UTC'): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(day.trim());
  if (!m) return null;
  const wall = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  let guess = wall - offset(wall, timeZone);
  guess = wall - offset(guess, timeZone);
  return guess;
}

/** "Tue, Nov 4, 2026, 2:00 PM" in the owner's time zone. */
export function formatDay(iso: string, timeZone = 'UTC'): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone, weekday: 'short', year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  }).format(new Date(iso));
}
