// The limits. One report an hour for each install, kept in D1 by install id. Caps for each network (an IPv4 address,
// or an IPv6 /64), kept only in memory and in the Cache API under a one-way hash of the network and the window, never stored.

export const INSTALL_INTERVAL_MINUTES = 60;
export const IP_LIMIT_PER_HOUR = 60;
export const NEW_INSTALLS_PER_DAY = 10;
export const VIEWS_PER_HOUR = 120;
const HOUR = 3_600_000;
export const DAY = 86_400_000;

/** The network a limit counts by: an IPv4 address as it is, an IPv6 address by its first 64 bits. */
export function networkOf(ip: string): string {
  const v4 = ip.match(/^(?:::ffff:)?(\d{1,3}(?:\.\d{1,3}){3})$/i);
  if (v4) return v4[1];
  if (!ip.includes(':')) return ip;
  const [head, tail = ''] = ip.toLowerCase().split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups = ip.includes('::') ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill('0'), ...right] : left;
  return `${groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, '')).join(':')}::/64`;
}

/** True when this install already sent a report that was kept. */
export async function knownInstall(db: D1Database, installID: string): Promise<boolean> {
  return (await db.prepare('SELECT 1 AS known FROM install_limit WHERE install_id = ?').bind(installID).first()) !== null;
}

/** True when the install may send a report now, and then records the time. One statement, so two at once cannot both pass. */
export async function allowInstall(db: D1Database, installID: string, now: Date): Promise<boolean> {
  const minute = Math.floor(now.getTime() / 60000);
  const result = await db.prepare(
    `INSERT INTO install_limit (install_id, last_minute) VALUES (?, ?)
     ON CONFLICT (install_id) DO UPDATE SET last_minute = excluded.last_minute
     WHERE excluded.last_minute - install_limit.last_minute >= ?`,
  ).bind(installID, minute, INSTALL_INTERVAL_MINUTES).run();
  return (result.meta?.changes ?? 0) > 0;
}

export interface IpLimiter {
  /** Counts one request from this network in this window and says whether it is under the cap. */
  hit(network: string, now: Date): Promise<boolean>;
}

async function bucketKey(network: string, window: number, namespace: string): Promise<string> {
  const bytes = new TextEncoder().encode(`getmossad-rate|${namespace}|${window}|${network}`);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...digest.slice(0, 16)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** In memory, for one isolate. Old windows are dropped as the window turns. */
export class MemoryIpLimiter implements IpLimiter {
  private window = -1;
  private counts = new Map<string, number>();
  constructor(private limit = IP_LIMIT_PER_HOUR, private windowMs = HOUR, private namespace = 'report') {}
  async hit(network: string, now: Date): Promise<boolean> {
    const window = Math.floor(now.getTime() / this.windowMs);
    if (window !== this.window) { this.window = window; this.counts.clear(); }
    const key = await bucketKey(network, window, this.namespace);
    const n = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, n);
    return n <= this.limit;
  }
}

/** The memory count, shared with the other isolates of a data center through the Cache API. */
export class CacheIpLimiter implements IpLimiter {
  private memory: MemoryIpLimiter;
  constructor(private cache: Cache, private limit = IP_LIMIT_PER_HOUR, private windowMs = HOUR, private namespace = 'report') {
    this.memory = new MemoryIpLimiter(limit, windowMs, namespace);
  }
  async hit(network: string, now: Date): Promise<boolean> {
    if (!(await this.memory.hit(network, now))) return false;
    const window = Math.floor(now.getTime() / this.windowMs);
    const url = `https://rate.getmossad.invalid/${await bucketKey(network, window, this.namespace)}`;
    const cached = await this.cache.match(url);
    const n = (cached ? Number(await cached.text()) || 0 : 0) + 1;
    await this.cache.put(url, new Response(String(n), { headers: { 'Cache-Control': `max-age=${Math.ceil(this.windowMs / 1000)}` } }));
    return n <= this.limit;
  }
}
