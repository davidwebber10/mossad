import { isOwnerBrowser, shareFails, viewerKey } from './access';
import type { Env, Share } from './types';

/**
 * Who opened a share, and when: a count of visits and visitors, per day, with the country that Cloudflare names
 * and the kind of device. A visitor is a random cookie of that one share. No address is read or kept.
 */

/** A reload or a way back within this time is the same visit. */
const visitMinutes = 30;

export const viewPolicy = {
  /**
   * New visitor rows per share per day. A client that keeps no cookie is a new visitor at each request; past this
   * number they share one row, so nobody can fill the table through one link.
   */
  newVisitorsPerDay: 500,
};

/** Programs that open a link to show a preview of it in a chat or a mail. They are not readers. */
const previews = /bot\b|bot[/;) ]|crawler|spider|preview|facebookexternalhit|whatsapp|telegram|discord|skype|embedly|slack|linkedin|pinterest|vkshare|snippet|unfurl|headless|lighthouse|monitor|curl\/|wget\/|python-|go-http-client|okhttp|java\/|axios|node-fetch|undici/i;

export const isPreview = (agent: string) => !agent || previews.test(agent);

/** Programs that show a preview of a link in a chat or a mail. An AI app that reads the Markdown is not one. */
const linkPreviews = /bot\b|bot[/;) ]|crawler|spider|preview|facebookexternalhit|whatsapp|telegram|discord|skype|embedly|slack|linkedin|pinterest|vkshare|snippet|unfurl/i;

export const isLinkPreview = (agent: string) => linkPreviews.test(agent);

/** "phone", "tablet", "computer", or "other" for anything that is not a browser a person holds. */
export function deviceClass(agent: string): string {
  if (!/Mozilla\//.test(agent) || isPreview(agent)) return 'other';
  if (/iPad|Tablet|Android(?!.*Mobile)/i.test(agent)) return 'tablet';
  if (/iPhone|iPod|Mobile|Android/i.test(agent)) return 'phone';
  return 'computer';
}

/** The day "YYYY-MM-DD" in the owner's time zone, so the chart's days are the owner's days. */
export function localDay(instant: number, timeZone = 'UTC'): string {
  const format = (zone: string) => new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(instant));
  try { return format(timeZone); } catch { return format('UTC'); }
}

/** Whether an error says that the tables of the newest migration are not there. */
export const missingSchema = (error: unknown) => /no such (table|column)|has no column named/i.test(error instanceof Error ? error.message : String(error));

/**
 * Counts one opening of a share. `viewer` is the value of the visitor's cookie, or '' for a program that sends
 * none (an AI app that reads the Markdown): those are one visitor together.
 */
export async function recordView(env: Env, id: string, share: Share, request: Request, viewer: string, now = Date.now()): Promise<void> {
  try {
    if (await isOwnerBrowser(env, request, now)) return;
    let key = viewer ? await viewerKey(id, viewer) : 'apps';
    const at = new Date(now).toISOString();
    const day = localDay(now, share.timeZone);
    let seen = await env.DB.prepare('SELECT last FROM share_viewers WHERE share_id = ? AND viewer = ?').bind(id, key).first<{ last: string }>();
    if (!seen && viewer) {
      const today = await env.DB.prepare('SELECT viewers FROM share_days WHERE share_id = ? AND day = ?').bind(id, day).first<{ viewers: number }>();
      if ((today?.viewers ?? 0) >= viewPolicy.newVisitorsPerDay) {
        key = 'many';
        seen = await env.DB.prepare('SELECT last FROM share_viewers WHERE share_id = ? AND viewer = ?').bind(id, key).first<{ last: string }>();
      }
    }
    if (seen && now - Date.parse(seen.last) < visitMinutes * 60_000) {
      await env.DB.batch([
        env.DB.prepare('UPDATE share_viewers SET last = ? WHERE share_id = ? AND viewer = ?').bind(at, id, key),
        env.DB.prepare('UPDATE shares SET last_view = ? WHERE id = ?').bind(at, id),
      ]);
      return;
    }
    const fresh = seen ? 0 : 1;
    const agent = request.headers.get('User-Agent') ?? '';
    const country = (request as { cf?: { country?: unknown } }).cf?.country;
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO share_viewers (share_id, viewer, first, last, views, country, device) VALUES (?, ?, ?, ?, 1, ?, ?)
          ON CONFLICT(share_id, viewer) DO UPDATE SET last = excluded.last, views = views + 1`)
        .bind(id, key, at, at, typeof country === 'string' && /^[A-Z]{2}$/.test(country) ? country : null, viewer ? deviceClass(agent) : 'other'),
      env.DB.prepare(`INSERT INTO share_days (share_id, day, views, viewers) VALUES (?, ?, 1, ?)
          ON CONFLICT(share_id, day) DO UPDATE SET views = views + 1, viewers = viewers + excluded.viewers`)
        .bind(id, day, fresh),
      env.DB.prepare('UPDATE shares SET views = views + 1, viewers = viewers + ?, first_view = COALESCE(first_view, ?), last_view = ? WHERE id = ?')
        .bind(fresh, at, at, id),
    ]);
  } catch (error) {
    // A database from before the views tables still has the plain count.
    if (missingSchema(error)) await env.DB.prepare('UPDATE shares SET views = views + 1 WHERE id = ?').bind(id).run().catch(() => {});
    else console.error('share view not counted', error instanceof Error ? error.message : error);
  }
}

// People are counted from their rows, so the number always agrees with the rows by device and country. Views
// from before the views per day (an older Worker, or before the migration) are counted apart.
const columns = `s.id, s.title, s.created, s.expires, s.audio, s.chat, s.views, s.questions,
  (SELECT count(*) FROM share_viewers v WHERE v.share_id = s.id) AS viewers,
  s.views - COALESCE((SELECT sum(d.views) FROM share_days d WHERE d.share_id = s.id), 0) AS earlier, s.first_view, s.last_view,
  s.pin_hash IS NOT NULL AS pin, s.pin_set, s.gone, COALESCE(t.fails, 0) AS wrong, COALESCE(t.locked_until, 0) AS locked_until, COALESCE(t.updated, 0) AS tried`;
const from = `FROM shares s LEFT JOIN share_pin_tries t ON t.share_id = s.id AND t.client = ''`;

interface Row {
  id: string; title: string; created: string; expires: string | null; audio: number; chat: number; views: number; questions: number; viewers: number;
  earlier: number; first_view: string | null; last_view: string | null; pin: number; pin_set: number | null; gone: number; wrong: number;
  locked_until: number; tried: number;
}

/** A share as the owner's app lists it. The first eight fields are as they were before the views. */
function listed(r: Row, now: number) {
  const locked = r.pin === 1 && r.locked_until > now;
  return {
    id: r.id, title: r.title, created: r.created, expires: r.expires, audio: r.audio, chat: r.chat, views: r.views, questions: r.questions,
    viewers: r.viewers, earlierViews: Math.max(0, r.earlier), firstView: r.first_view, lastView: r.last_view, pin: r.pin === 1,
    pinSet: r.pin === 1 ? r.pin_set : null, pinLocked: locked, lockedAt: locked ? new Date(r.tried).toISOString() : null,
    wrongPins: r.pin === 1 ? shareFails(r.wrong, r.tried, locked, now) : 0, gone: r.gone === 1,
  };
}

export async function shareRows(env: Env, now = Date.now()) {
  const { results } = await env.DB.prepare(`SELECT ${columns} ${from} ORDER BY s.created DESC`).all<Row>();
  return { rows: results, shares: results.map((r) => listed(r, now)) };
}

/** One share for the owner: its row, the days with views, and the visitors by country and by device. */
export async function shareDetail(env: Env, id: string, now = Date.now()) {
  const row = await env.DB.prepare(`SELECT ${columns} ${from} WHERE s.id = ?`).bind(id).first<Row>();
  if (!row) return null;
  const [days, countries, devices] = await Promise.all([
    env.DB.prepare('SELECT day, views, viewers FROM share_days WHERE share_id = ? ORDER BY day').bind(id).all(),
    env.DB.prepare(`SELECT country, count(*) AS viewers FROM share_viewers WHERE share_id = ? AND country IS NOT NULL
        GROUP BY country ORDER BY viewers DESC, country`).bind(id).all(),
    env.DB.prepare('SELECT device, count(*) AS viewers FROM share_viewers WHERE share_id = ? GROUP BY device ORDER BY viewers DESC, device').bind(id).all(),
  ]);
  return { share: listed(row, now), days: days.results, countries: countries.results, devices: devices.results };
}
