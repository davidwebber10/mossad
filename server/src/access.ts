import type { Env } from './types';

/**
 * The PIN of a share and the three cookies of the share host: the pass after a right PIN, the visitor's id for
 * the view count, and the owner's mark. Every key comes from the owner secret, which is not in the database, so
 * the database alone cannot check a PIN, make a pass, or turn a row back into an address.
 */

export const pinPolicy = {
  /** Wrong PINs that one visitor may enter before a pause. */
  freeTries: 5,
  /** The first pause; each wrong PIN after it doubles the pause, up to a day. */
  pauseSeconds: 60,
  /** Wrong PINs from all visitors together that lock the share until the owner makes a new PIN. */
  shareTries: 30,
  /**
   * The share forgets one of those wrong PINs a day, so the readers of a long-lived link do not lock it over
   * months. A lock does not wear off. Slow on purpose: someone with many addresses gains one guess a day.
   */
  shareForgetHours: 24,
  /** How long a pass lasts after the right PIN. */
  passSeconds: 12 * 3600,
  /**
   * PBKDF2 rounds. Four digits are 10,000 PINs, so no number of rounds protects a hash that someone can test at
   * will: the keyed digest under it does that. The rounds stay small enough for the CPU time of a free Worker.
   */
  rounds: 10_000,
};

const day = 86_400_000;
/** "Until the owner makes a new PIN": the largest time a Date holds. */
const forever = 8_640_000_000_000_000;
const encoder = new TextEncoder();

const b64 = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64 = (text: string) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');

function hmacKey(secret: string | ArrayBuffer): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', typeof secret === 'string' ? encoder.encode(secret) : secret, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}

/** One key per purpose, so a pass can never be taken for a PIN digest or an owner's mark. */
async function key(env: Env, purpose: string): Promise<CryptoKey> {
  if (!env.OWNER_SECRET) throw new Error('The server has no owner secret.');
  return hmacKey(await crypto.subtle.sign('HMAC', await hmacKey(env.OWNER_SECRET), encoder.encode(`share\n${purpose}`)));
}

const sign = async (k: CryptoKey, text: string) => crypto.subtle.sign('HMAC', k, encoder.encode(text));

async function verify(k: CryptoKey, signature: string, text: string): Promise<boolean> {
  try { return await crypto.subtle.verify('HMAC', k, unb64(signature), encoder.encode(text)); } catch { return false; }
}

// MARK: The PIN

/** A PIN of 4 digits, each of the 10,000 as likely as the next. */
export function newPIN(): string {
  const n = new Uint16Array(1);
  // 60,000 is the largest multiple of 10,000 that 16 bits hold: a larger draw would favor the low PINs.
  do crypto.getRandomValues(n); while (n[0] >= 60_000);
  return String(n[0] % 10_000).padStart(4, '0');
}

export const isPIN = (text: unknown): text is string => typeof text === 'string' && /^\d{4}$/.test(text);

async function stretch(env: Env, id: string, pin: string, salt: Uint8Array, rounds: number): Promise<ArrayBuffer> {
  const keyed = await sign(await key(env, 'pin'), `${id}\n${pin}`);
  const material = await crypto.subtle.importKey('raw', keyed, 'PBKDF2', false, ['deriveBits']);
  return crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: rounds }, material, 256);
}

/** What the database keeps of a PIN: the rounds, a salt of its own, and the hash. */
export async function hashPIN(env: Env, id: string, pin: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return `pbkdf2-sha256$${pinPolicy.rounds}$${b64(salt)}$${b64(await stretch(env, id, pin, salt, pinPolicy.rounds))}`;
}

export async function checkPIN(env: Env, id: string, pin: string, stored: string): Promise<boolean> {
  const [scheme, rounds, salt, hash] = stored.split('$');
  if (scheme !== 'pbkdf2-sha256' || !Number(rounds) || !salt || !hash) return false;
  const made = new Uint8Array(await stretch(env, id, pin, unb64(salt), Number(rounds)));
  const kept = unb64(hash);
  let diff = made.length ^ kept.length;
  for (let i = 0; i < made.length; i++) diff |= made[i] ^ (kept[i] ?? 0);
  return diff === 0;
}

// MARK: Wrong tries

/** The visitor as the tries table names them: a keyed hash of the share and the address, never the address. */
export async function clientKey(env: Env, id: string, request: Request): Promise<string> {
  return hex(await sign(await key(env, 'client'), `${id}\n${request.headers.get('CF-Connecting-IP') ?? 'unknown'}`)).slice(0, 32);
}

export type Try = { allowed: true; left: number } | { allowed: false; locked: true } | { allowed: false; locked: false; seconds: number };

/**
 * Takes one try before the PIN is looked at, and counts it as wrong; a right PIN gives it back. Each statement is
 * one write, so many requests at once cannot all read the same count and pass together.
 */
export async function takeTry(env: Env, id: string, client: string, now = Date.now()): Promise<Try> {
  const p = pinPolicy, stale = now - day;
  const mine = await env.DB.prepare(`INSERT INTO share_pin_tries (share_id, client, fails, locked_until, updated) VALUES (?, ?, 1, 0, ?)
      ON CONFLICT(share_id, client) DO UPDATE SET
        fails = CASE WHEN max(updated, locked_until) < ? THEN 1 ELSE fails + 1 END,
        locked_until = CASE WHEN max(updated, locked_until) < ? OR fails + 1 < ? THEN 0
          ELSE ? + min(?, ? * (1 << min(fails + 1 - ?, 20))) END,
        updated = ?
      WHERE locked_until <= ?
      RETURNING fails, locked_until`)
    .bind(id, client, now, stale, stale, p.freeTries, now, day, p.pauseSeconds * 1000, p.freeTries, now, now)
    .first<{ fails: number; locked_until: number }>();
  if (!mine) {
    const row = await env.DB.prepare('SELECT locked_until FROM share_pin_tries WHERE share_id = ? AND client = ?').bind(id, client).first<{ locked_until: number }>();
    return { allowed: false, locked: false, seconds: Math.max(1, Math.ceil(((row?.locked_until ?? now) - now) / 1000)) };
  }
  const kept = `max(0, fails - CAST((? - updated) / ? AS INTEGER))`;
  const all = await env.DB.prepare(`INSERT INTO share_pin_tries (share_id, client, fails, locked_until, updated) VALUES (?, '', 1, 0, ?)
      ON CONFLICT(share_id, client) DO UPDATE SET fails = ${kept} + 1, locked_until = CASE WHEN ${kept} + 1 >= ? THEN ? ELSE 0 END, updated = ?
      WHERE locked_until <= ?
      RETURNING fails`)
    .bind(id, now, now, forgetMs(), now, forgetMs(), p.shareTries, forever, now, now).first<{ fails: number }>();
  if (!all) return { allowed: false, locked: true };
  return { allowed: true, left: Math.max(0, p.freeTries - mine.fails) };
}

const forgetMs = () => pinPolicy.shareForgetHours * 3_600_000;

/** The wrong PINs that a share still holds against it: all of them while it is locked, else less one a day. */
export function shareFails(fails: number, updated: number, locked: boolean, now = Date.now()): number {
  return locked ? fails : Math.max(0, fails - Math.floor(Math.max(0, now - updated) / forgetMs()));
}

/** After a wrong PIN: what the visitor is told. The try is already counted. */
export async function afterWrong(env: Env, id: string, client: string, now = Date.now()): Promise<Try> {
  const { results } = await env.DB.prepare('SELECT client, fails, locked_until FROM share_pin_tries WHERE share_id = ? AND client IN (?, ?)')
    .bind(id, client, '').all<{ client: string; fails: number; locked_until: number }>();
  const all = results.find((r) => r.client === ''), mine = results.find((r) => r.client === client);
  if (all && all.locked_until > now) return { allowed: false, locked: true };
  if (mine && mine.locked_until > now) return { allowed: false, locked: false, seconds: Math.ceil((mine.locked_until - now) / 1000) };
  return { allowed: true, left: Math.max(0, pinPolicy.freeTries - (mine?.fails ?? 0)) };
}

/** After the right PIN: the visitor's wrong tries are forgotten, and no longer count against the share. */
export async function afterRight(env: Env, id: string, client: string): Promise<void> {
  const mine = await env.DB.prepare('DELETE FROM share_pin_tries WHERE share_id = ? AND client = ? RETURNING fails').bind(id, client).first<{ fails: number }>();
  await env.DB.prepare(`UPDATE share_pin_tries SET fails = max(0, fails - ?), locked_until = 0 WHERE share_id = ? AND client = ''`).bind(mine?.fails ?? 1, id).run();
}

// MARK: Cookies

export function cookie(request: Request, name: string): string {
  for (const part of (request.headers.get('Cookie') ?? '').split(';')) {
    const at = part.indexOf('=');
    if (at > 0 && part.slice(0, at).trim() === name) return part.slice(at + 1).trim();
  }
  return '';
}

/** Never readable by a script, only over TLS, and not sent with a request that another site makes. */
function setCookie(name: string, value: string, path: string, seconds: number): string {
  return `${name}=${value}; Path=${path}; Max-Age=${seconds}; HttpOnly; Secure; SameSite=Lax`;
}

const passText = (id: string, pinSet: number, expires: number) => `pass\n${id}\n${pinSet}\n${expires}`;

/** The pass after a right PIN: for one share and one PIN, until a time that the signature covers. */
export async function passCookie(env: Env, id: string, token: string, pinSet: number, now = Date.now()): Promise<string> {
  const expires = Math.floor(now / 1000) + pinPolicy.passSeconds;
  return setCookie('a', `${expires}.${b64(await sign(await key(env, 'pass'), passText(id, pinSet, expires)))}`, `/${token}`, pinPolicy.passSeconds);
}

export async function hasPass(env: Env, request: Request, id: string, pinSet: number, now = Date.now()): Promise<boolean> {
  const [expires, signature] = cookie(request, 'a').split('.');
  if (!signature || !/^\d{1,12}$/.test(expires) || Number(expires) * 1000 <= now) return false;
  return verify(await key(env, 'pass'), signature, passText(id, pinSet, Number(expires)));
}

/** A visitor's id for one share: random, a year long, and no use on any other share. */
export function newViewer(token: string): { value: string; header: string } {
  const value = b64(crypto.getRandomValues(new Uint8Array(16)));
  return { value, header: setCookie('v', value, `/${token}`, 365 * 86_400) };
}

export const isViewer = (value: string) => /^[A-Za-z0-9_-]{22}$/.test(value);

/** The visitor as the views table names them: a hash, so the table does not hold what the browser holds. */
export async function viewerKey(id: string, value: string): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', encoder.encode(`viewer\n${id}\n${value}`))).slice(0, 32);
}

const markText = (id: string, expires: number) => `owner-view\n${id}\n${expires}`;

/** The key of the owner's mark, made from the owner secret for that one purpose, as the Mac makes it. */
async function markKey(secret: string): Promise<CryptoKey> {
  return hmacKey(await sign(await hmacKey(secret), 'share\nowner-mark'));
}

/**
 * What the owner's app puts on a link that it opens in the browser: "<unix seconds>.<hex HMAC-SHA256 of
 * "owner-view\n<share id>\n<seconds>">", for a few minutes, with a key of its own from the owner secret, so the
 * address holds nothing to test a guess of the secret with. The Mac makes the same.
 */
export async function ownerMark(secret: string, id: string, expires: number): Promise<string> {
  return `${expires}.${hex(await sign(await markKey(secret), markText(id, expires)))}`;
}

/** Trades a mark from the app for a cookie that keeps the owner's own visits out of the count. Null for no mark. */
export async function ownerCookie(env: Env, mark: string, id: string, now = Date.now()): Promise<string | null> {
  const [expires, signature] = mark.split('.');
  const at = Number(expires);
  if (!signature || !Number.isInteger(at) || at * 1000 <= now || at * 1000 > now + 3_600_000) return null;
  const made = await ownerMark(env.OWNER_SECRET, id, at);
  let diff = made.length ^ mark.length;
  for (let i = 0; i < made.length; i++) diff |= made.charCodeAt(i) ^ mark.charCodeAt(i);
  if (diff !== 0) return null;
  const until = Math.floor(now / 1000) + 365 * 86_400;
  return setCookie('o', `${until}.${b64(await sign(await key(env, 'owner'), `owner\n${until}`))}`, '/', 365 * 86_400);
}

export async function isOwnerBrowser(env: Env, request: Request, now = Date.now()): Promise<boolean> {
  const [until, signature] = cookie(request, 'o').split('.');
  if (!signature || !/^\d{1,12}$/.test(until) || Number(until) * 1000 <= now) return false;
  return verify(await key(env, 'owner'), signature, `owner\n${until}`);
}
