import { AuthorizationError, CimdFetchError, OAuthAuthorizationServer, OAuthResourceServer } from '@cloudflare/workers-oauth-provider';
import { handleAPI, tooManyFailures } from './api';
import { handleMCP } from './mcp';
import { signInPage } from './pages';
import { handleShareHost, html } from './share';
import type { Env } from './types';
import { escapeHtml, sameSecret } from './util';

/**
 * One Worker for one owner. On SHARE_HOST: the home page, share links, and the owner API. On MCP_HOST under
 * MCP_PATH: a read-only MCP server behind OAuth, so ChatGPT and other web AI apps can read the meetings. The
 * rest of MCP_HOST is left to other Workers.
 */

const scope = 'mossad:read';

interface OAuth {
  issuer: string;
  path: string;
  server: OAuthAuthorizationServer<Env>;
  resource: OAuthResourceServer<Env, { owner: true }>;
}

let cached: { key: string; oauth: OAuth } | undefined;

function oauth(env: Env): OAuth {
  const path = (env.MCP_PATH || '/mossad').replace(/\/$/, '');
  // `wrangler dev` serves plain http on a loopback address; everything else is https.
  const scheme = /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(env.MCP_HOST) ? 'http' : 'https';
  const issuer = `${scheme}://${env.MCP_HOST}${path}`;
  if (cached?.key === issuer) return cached.oauth;
  const server = new OAuthAuthorizationServer<Env>({
    issuer,
    resources: [issuer],
    scopesSupported: [scope],
    authorizeEndpoint: `${path}/authorize`,
    tokenEndpoint: `${path}/token`,
    clientRegistrationEndpoint: `${path}/register`,
    // ChatGPT and Claude refresh tokens; a month without use ends the grant.
    accessTokenTTL: 3600,
  });
  const resource = new OAuthResourceServer<Env, { owner: true }>({
    resourceMetadata: { resource: issuer, authorization_servers: [issuer], resource_name: 'Mossad meetings', bearer_methods_supported: ['header'] },
    validateToken: (e) => (res, token) => server.validateToken(res, token, e),
    handler: { fetch: (request, e) => handleMCP(request, e) },
  });
  cached = { key: issuer, oauth: { issuer, path, server, resource } };
  return cached.oauth;
}

async function authorize(request: Request, env: Env, o: OAuth): Promise<Response> {
  const api = o.server.getOAuthApi(env);
  try {
    if (request.method === 'GET') {
      const auth = await api.parseAuthRequest(request);
      const details = await api.describeConsent(auth);
      const consent = await api.beginConsent(auth);
      return html((n) => signInPage(n, details, consent.handle), 200, consent.headers);
    }
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
    const form = await request.formData();
    const handle = String(form.get('handle') ?? '');
    if (form.get('decision') !== 'approve') {
      const denied = await api.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    const ok = await sameSecret(String(form.get('secret') ?? ''), env.OWNER_SECRET);
    if (await tooManyFailures(env, request, !ok)) return new Response('Too many wrong secrets. Try again in an hour.', { status: 429 });
    if (!ok) {
      // The handle is not used yet, so the same page can try again.
      const auth = await api.parseAuthRequest(new Request(request.url, { headers: request.headers }));
      const details = await api.describeConsent(auth);
      return html((n) => signInPage(n, details, handle, 'That secret is not right.'), 401);
    }
    const approved = await api.approveConsent(request, handle, { scope: [scope] });
    const { redirectTo } = await api.completeAuthorization({
      request: approved.request, userId: 'owner', metadata: {}, scope: [scope], props: { owner: true },
    });
    approved.headers.set('Location', redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) {
      const message = error instanceof AuthorizationError ? error.description : 'This app could not be verified.';
      return new Response(escapeHtml(message), { status: 400, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }
    throw error;
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.host === env.MCP_HOST) {
      const o = oauth(env);
      const p = url.pathname;
      if (p === `${o.path}/authorize`) return authorize(request, env, o);
      if (p === o.path || p === `${o.path}/` || p.startsWith('/.well-known/oauth-protected-resource')) return o.resource.fetch(request, env, ctx);
      return o.server.fetch(request, env, ctx);
    }
    if (url.host === env.SHARE_HOST) {
      if (url.pathname.startsWith('/api/')) return handleAPI(request, env);
      const page = await handleShareHost(request, env, ctx);
      if (page) return page;
    }
    return new Response('Not found', { status: 404 });
  },
} satisfies ExportedHandler<Env>;
