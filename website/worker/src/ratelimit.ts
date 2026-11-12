// Two limits. One report an hour for each install, kept in D1 by install id. A cap for each IP address,
// kept only in memory and in the Cache API under a one-way hash of the address and the hour, never stored.

export const INSTALL_INTERVAL_MINUTES = 60;
export const IP_LIMIT_PER_HOUR = 60;

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
  /** Counts one request from this address in this hour and says whether it is under the cap. */
  hit(ip: string, now: Date): Promise<boolean>;
}

async function bucketKey(ip: string, hour: number): Promise<string> {
  const bytes = new TextEncoder().encode(`getmossad-rate|${hour}|${ip}`);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...digest.slice(0, 16)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** In memory, for one isolate. Old hours are dropped as the hour turns. */
export class MemoryIpLimiter implements IpLimiter {
  private hour = -1;
  private counts = new Map<string, number>();
  constructor(private limit = IP_LIMIT_PER_HOUR) {}
  async hit(ip: string, now: Date): Promise<boolean> {
    const hour = Math.floor(now.getTime() / 3_600_000);
    if (hour !== this.hour) { this.hour = hour; this.counts.clear(); }
    const key = await bucketKey(ip, hour);
    const n = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, n);
    return n <= this.limit;
  }
}

/** The memory count, shared with the other isolates of a data center through the Cache API. */
export class CacheIpLimiter implements IpLimiter {
  private memory: MemoryIpLimiter;
  constructor(private cache: Cache, private limit = IP_LIMIT_PER_HOUR) { this.memory = new MemoryIpLimiter(limit); }
  async hit(ip: string, now: Date): Promise<boolean> {
    if (!(await this.memory.hit(ip, now))) return false;
    const hour = Math.floor(now.getTime() / 3_600_000);
    const url = `https://rate.getmossad.invalid/${await bucketKey(ip, hour)}`;
    const cached = await this.cache.match(url);
    const n = (cached ? Number(await cached.text()) || 0 : 0) + 1;
    await this.cache.put(url, new Response(String(n), { headers: { 'Cache-Control': 'max-age=3600' } }));
    return n <= this.limit;
  }
}
