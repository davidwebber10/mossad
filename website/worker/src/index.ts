import { verifyAccess } from './access';
import { CLICK_TARGETS, countClick, countView, viewOf } from './pageviews';
import { allowInstall, CacheIpLimiter, DAY, knownInstall, MemoryIpLimiter, networkOf, NEW_INSTALLS_PER_DAY, VIEWS_PER_HOUR, type IpLimiter } from './ratelimit';
import { loadStats, renderStats } from './stats';
import { countryOf, dayOf, Invalid, parseReport, readLimited, reportRow } from './telemetry';
import type { Env } from './types';

export interface Deps {
  now?: () => Date;
  ipLimiter?: IpLimiter;
  newInstallLimiter?: IpLimiter;
  viewLimiter?: IpLimiter;
  fetchCerts?: (url: string) => Promise<Response>;
}

const empty = (status: number, headers: HeadersInit = {}) => new Response(null, { status, headers: { 'Cache-Control': 'no-store', ...headers } });

function ownHosts(env: Env): string[] {
  return [env.CANONICAL_HOST, ...(env.REDIRECT_HOSTS ?? '').split(',')].map((h) => h.trim().toLowerCase()).filter(Boolean);
}

const SECURITY_HEADERS: Record<string, string> = {
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'X-Content-Type-Options': 'nosniff',
};

function secured(response: Response): Response {
  const out = new Response(response.body, response);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) if (!out.headers.has(k)) out.headers.set(k, v);
  return out;
}

const networkOfRequest = (request: Request) => networkOf(request.headers.get('cf-connecting-ip') ?? 'unknown');

interface Limits { ip: IpLimiter; newInstall: IpLimiter; view: IpLimiter }

async function telemetry(request: Request, env: Env, limits: Limits, now: Date): Promise<Response> {
  if (request.method !== 'POST') return empty(405, { Allow: 'POST' });
  const type = (request.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') return empty(415);
  const network = networkOfRequest(request);
  if (!(await limits.ip.hit(network, now))) return empty(429);
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
  if (!(await knownInstall(env.DB, report.installID)) && !(await limits.newInstall.hit(network, now))) return empty(429);
  if (!(await allowInstall(env.DB, report.installID, now))) return empty(429);
  const row = reportRow(report, dayOf(now), countryOf(request));
  const columns = Object.keys(row);
  await env.DB.prepare(`INSERT INTO telemetry (${columns.join(', ')}) VALUES (${columns.map(() => '?').join(', ')})`).bind(...Object.values(row)).run();
  return empty(204);
}

async function click(request: Request, env: Env, limiter: IpLimiter, now: Date): Promise<Response> {
  if (request.method !== 'POST') return empty(405, { Allow: 'POST' });
  if (request.headers.get('sec-fetch-site') !== 'same-origin') return empty(403);
  if (!(await limiter.hit(networkOfRequest(request), now))) return empty(429);
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

const shared: Partial<Limits> = {};

function limitsFor(deps: Deps): Limits {
  return {
    ip: deps.ipLimiter ?? (shared.ip ??= new CacheIpLimiter(caches.default)),
    newInstall: deps.newInstallLimiter ?? (shared.newInstall ??= new CacheIpLimiter(caches.default, NEW_INSTALLS_PER_DAY, DAY, 'new-install')),
    view: deps.viewLimiter ?? (shared.view ??= new MemoryIpLimiter(VIEWS_PER_HOUR, 3_600_000, 'view')),
  };
}

async function route(request: Request, env: Env, ctx: ExecutionContext, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const host = url.hostname.toLowerCase();
  const local = host === 'localhost' || host === '127.0.0.1';
  const redirects = (env.REDIRECT_HOSTS ?? '').split(',').map((h) => h.trim().toLowerCase()).filter(Boolean);
  if (redirects.includes(host) || (url.protocol === 'http:' && !local)) {
    const target = redirects.includes(host) ? env.CANONICAL_HOST : host;
    return new Response(null, { status: 301, headers: { Location: `https://${target}${url.pathname}${url.search}` } });
  }
  const now = deps.now?.() ?? new Date();
  const limits = limitsFor(deps);
  const path = url.pathname;
  if (path === '/api/telemetry') return telemetry(request, env, limits, now);
  if (path === '/api/click') return click(request, env, limits.ip, now);
  if (path.startsWith('/api/')) return empty(404);
  if (path === '/stats' || path.startsWith('/stats/')) return stats(request, env, deps, now);

  const response = await env.ASSETS.fetch(request);
  if (response.status === 200) {
    const view = viewOf(request, dayOf(now), countryOf(request), ownHosts(env));
    if (view) {
      ctx.waitUntil((async () => {
        if (await limits.view.hit(networkOfRequest(request), now)) await countView(env.DB, view);
      })().catch(() => undefined));
    }
  }
  return response;
}

export async function handle(request: Request, env: Env, ctx: ExecutionContext, deps: Deps = {}): Promise<Response> {
  return secured(await route(request, env, ctx, deps));
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext) {
    return handle(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
