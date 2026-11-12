// Cookie-free counts. A view is one row increment of (day, page, country, referring site, device class).
// The user agent and the referrer are read to pick a bucket and then dropped.

/** The pages that count, by the path a browser asks for, and the name each is counted under. */
export const COUNTED_PAGES: Record<string, string> = {
  '/': '/',
  '/index.html': '/',
  '/privacy': '/privacy',
  '/privacy.html': '/privacy',
};

/** The download buttons a click can name. */
export const CLICK_TARGETS = ['header', 'hero', 'cta', 'privacy', '404'] as const;

export type Device = 'desktop' | 'mobile' | 'tablet' | 'bot';

const BOT = /bot|crawl|spider|slurp|preview|fetch|headless|lighthouse|python|curl|wget|httpclient|go-http|okhttp|java\/|axios|node-fetch|monitor|scan/i;

export function deviceClass(userAgent: string | null): Device {
  const ua = userAgent ?? '';
  if (!ua || BOT.test(ua)) return 'bot';
  if (/iPad|Tablet|Kindle|Silk|PlayBook|Android(?!.*Mobile)/i.test(ua)) return 'tablet';
  if (/Mobi|iPhone|iPod|Android|Windows Phone|Opera Mini/i.test(ua)) return 'mobile';
  return 'desktop';
}

/** The host of a referrer from another site, lowercased and without "www.", or "" for none and for our own hosts. */
export function referrerHost(referrer: string | null, ownHosts: string[]): string {
  if (!referrer) return '';
  let host: string;
  try {
    const url = new URL(referrer);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
    host = url.hostname.toLowerCase();
  } catch {
    return '';
  }
  if (ownHosts.includes(host)) return '';
  if (!isPublicHost(host)) return '';
  return host.replace(/^www\./, '');
}

/** A host name that can be a public site: a dot, letters in its last label, and not a private or test name. */
function isPublicHost(host: string): boolean {
  if (!/^[a-z0-9.-]{1,100}$/.test(host)) return false;
  if (!host.includes('.') || /^[\d.]+$/.test(host)) return false;
  const last = host.slice(host.lastIndexOf('.') + 1);
  if (!/^[a-z][a-z0-9-]*$/.test(last)) return false;
  return !['local', 'localhost', 'internal', 'intranet', 'lan', 'home', 'corp', 'test', 'invalid', 'example', 'arpa'].includes(last);
}

/** The most referring sites a day keeps by name. Any more count as "other", so the table cannot grow without end. */
export const REFERRERS_PER_DAY = 200;

export interface View { day: string; path: string; country: string; referrer: string; device: Device }

/** The bucket of a page request, or null when the request is not a page view: not GET, a prefetch, or not a counted page. */
export function viewOf(request: Request, day: string, country: string, ownHosts: string[]): View | null {
  if (request.method !== 'GET') return null;
  const path = COUNTED_PAGES[new URL(request.url).pathname];
  if (!path) return null;
  const purpose = request.headers.get('sec-purpose') ?? request.headers.get('purpose') ?? '';
  if (/prefetch|prerender/i.test(purpose)) return null;
  return { day, path, country, referrer: referrerHost(request.headers.get('referer'), ownHosts), device: deviceClass(request.headers.get('user-agent')) };
}

export async function countView(db: D1Database, view: View): Promise<void> {
  await db.prepare(
    `INSERT INTO page_views (day, path, country, referrer, device, views) VALUES (?, ?, ?,
       CASE WHEN ? = '' OR EXISTS (SELECT 1 FROM page_views WHERE day = ? AND referrer = ?)
              OR (SELECT COUNT(DISTINCT referrer) FROM page_views WHERE day = ? AND referrer NOT IN ('', 'other')) < ?
            THEN ? ELSE 'other' END, ?, 1)
     ON CONFLICT (day, path, country, referrer, device) DO UPDATE SET views = views + 1`,
  ).bind(view.day, view.path, view.country, view.referrer, view.day, view.referrer, view.day, REFERRERS_PER_DAY, view.referrer, view.device).run();
}

export async function countClick(db: D1Database, day: string, target: string, country: string): Promise<void> {
  await db.prepare(
    `INSERT INTO clicks (day, target, country, clicks) VALUES (?, ?, ?, 1)
     ON CONFLICT (day, target, country) DO UPDATE SET clicks = clicks + 1`,
  ).bind(day, target, country).run();
}
