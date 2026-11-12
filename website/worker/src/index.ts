import { verifyAccess } from './access';
import { CLICK_TARGETS, countClick, countView, viewOf } from './pageviews';
import { allowInstall, CacheIpLimiter, type IpLimiter } from './ratelimit';
import { loadStats, renderStats } from './stats';
import { countryOf, dayOf, Invalid, parseReport, readLimited, reportRow } from './telemetry';
import type { Env } from './types';

export interface Deps {
  now?: () => Date;
  ipLimiter?: IpLimiter;
  fetchCerts?: (url: string) => Promise<Response>;
}

const empty = (status: number, headers: HeadersInit = {}) => new Response(null, { status, headers: { 'Cache-Control': 'no-store', ...headers } });

function ownHosts(env: Env): string[] {
  return [env.CANONICAL_HOST, ...(env.REDIRECT_HOSTS ?? '').split(',')].map((h) => h.trim().toLowerCase()).filter(Boolean);
}

async function telemetry(request: Request, env: Env, limiter: IpLimiter, now: Date): Promise<Response> {
  if (request.method !== 'POST') return empty(405, { Allow: 'POST' });
  const type = (request.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') return empty(415);
  if (!(await limiter.hit(request.headers.get('cf-connecting-ip') ?? 'unknown', now))) return empty(429);
  let body: string | null;
  try { body = await readLimited(request); } catch { return empty(400); }
  if (body === null) return empty(413);
  let report;
  try {
    report = parseReport(JSON.parse(body));
  } catch (error) {
    if (error instanceof Invalid || error instanceof SyntaxError) return empty(400);
    throw error;
  }
  if (!(await allowInstall(env.DB, report.installID, now))) return empty(429);
  const row = reportRow(report, dayOf(now), countryOf(request));
  const columns = Object.keys(row);
  await env.DB.prepare(`INSERT INTO telemetry (${columns.join(', ')}) VALUES (${columns.map(() => '?').join(', ')})`).bind(...Object.values(row)).run();
  return empty(204);
}

async function click(request: Request, env: Env, limiter: IpLimiter, now: Date): Promise<Response> {
  if (request.method !== 'POST') return empty(405, { Allow: 'POST' });
  if (!(await limiter.hit(request.headers.get('cf-connecting-ip') ?? 'unknown', now))) return empty(429);
  const body = await readLimited(request, 32).catch(() => null);
  const target = (body ?? '').trim();
  if (!(CLICK_TARGETS as readonly string[]).includes(target)) return empty(400);
  await countClick(env.DB, dayOf(now), target, countryOf(request));
  return empty(204);
}

async function stats(request: Request, env: Env, deps: Deps, now: Date): Promise<Response> {
  const forbidden = () => new Response('Forbidden', { status: 403, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } });
  if (request.method !== 'GET' && request.method !== 'HEAD') return empty(405, { Allow: 'GET' });
  const email = await verifyAccess(request.headers.get('cf-access-jwt-assertion'), { teamDomain: env.ACCESS_TEAM_DOMAIN, audience: env.ACCESS_AUD, ownerEmail: env.OWNER_EMAIL }, deps.fetchCerts, now.getTime());
  if (!email) return forbidden();
  const html = renderStats(await loadStats(env.DB, dayOf(now)), email);
  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'private, no-store',
      'X-Robots-Tag': 'noindex, nofollow',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; font-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'Referrer-Policy': 'no-referrer',
    },
  });
}

let sharedLimiter: IpLimiter | undefined;

export async function handle(request: Request, env: Env, ctx: ExecutionContext, deps: Deps = {}): Promise<Response> {
  const url = new URL(request.url);
  const host = url.hostname.toLowerCase();
  const redirects = (env.REDIRECT_HOSTS ?? '').split(',').map((h) => h.trim().toLowerCase()).filter(Boolean);
  if (redirects.includes(host)) {
    return new Response(null, { status: 301, headers: { Location: `https://${env.CANONICAL_HOST}${url.pathname}${url.search}` } });
  }
  const now = deps.now?.() ?? new Date();
  const limiter = deps.ipLimiter ?? (sharedLimiter ??= new CacheIpLimiter(caches.default));
  const path = url.pathname;
  if (path === '/api/telemetry') return telemetry(request, env, limiter, now);
  if (path === '/api/click') return click(request, env, limiter, now);
  if (path.startsWith('/api/')) return empty(404);
  if (path === '/stats' || path.startsWith('/stats/')) return stats(request, env, deps, now);

  const response = await env.ASSETS.fetch(request);
  if (response.status === 200) {
    const view = viewOf(request, dayOf(now), countryOf(request), ownHosts(env));
    if (view) ctx.waitUntil(countView(env.DB, view).catch(() => undefined));
  }
  return response;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext) {
    return handle(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
