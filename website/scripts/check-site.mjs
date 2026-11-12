// A small local check of website/site: HTML structure, links, JSON-LD, SEO tags, and no outside requests.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = join(dirname(fileURLToPath(import.meta.url)), '..', 'site');
const errors = [];
const fail = (file, message) => errors.push(`${file}: ${message}`);
const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
const SVG_SELF = /\/>$/;

function checkHTML(file) {
  const html = readFileSync(join(site, file), 'utf8');
  if (!html.startsWith('<!doctype html>')) fail(file, 'no doctype');
  if (!/<html lang="en">/.test(html)) fail(file, 'no lang');
  if (!/<meta name="viewport"/.test(html)) fail(file, 'no viewport');
  if (!/<meta name="description" content="[^"]{50,155}">/.test(html)) fail(file, 'description missing or not 50 to 155 characters');
  const title = html.match(/<title>([^<]*)<\/title>/)?.[1] ?? '';
  if (title.length < 10 || title.length > 65) fail(file, `title length ${title.length}`);
  if (/[\u2013\u2014]/.test(html)) fail(file, 'an en or em dash');
  if (/\{\{[A-Z0-9_]+\}\}/.test(html)) fail(file, 'an unfilled placeholder');

  // Tags open and close in order. Script and style bodies are skipped.
  const body = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '<script></script>').replace(/<style\b[^>]*>[\s\S]*?<\/style>/g, '<style></style>').replace(/<!--[\s\S]*?-->/g, '');
  const stack = [];
  for (const m of body.matchAll(/<(\/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*)>/g)) {
    const [, close, rawName, rest] = m;
    const name = rawName.toLowerCase();
    if (name === '!doctype') continue;
    if (close) {
      const open = stack.pop();
      if (open !== name) { fail(file, `</${name}> closes <${open}>`); return; }
    } else if (!VOID.has(name) && !SVG_SELF.test(rest)) stack.push(name);
  }
  if (stack.length) fail(file, `unclosed: ${stack.join(' ')}`);

  const ids = [...body.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  if (dup.length) fail(file, `duplicate ids: ${dup.join(', ')}`);

  const h1 = (body.match(/<h1[\s>]/g) ?? []).length;
  if (h1 !== 1) fail(file, `${h1} h1 elements`);
  let level = 0;
  for (const m of body.matchAll(/<h([1-6])[\s>]/g)) {
    const n = Number(m[1]);
    if (n > level + 1) fail(file, `heading jumps from h${level} to h${n}`);
    level = n;
  }
  for (const m of body.matchAll(/<img\b[^>]*>/g)) {
    if (!/\salt="/.test(m[0])) fail(file, `img without alt: ${m[0]}`);
    if (!/\swidth="\d+"/.test(m[0]) || !/\sheight="\d+"/.test(m[0])) fail(file, `img without size: ${m[0]}`);
  }
  for (const m of body.matchAll(/<svg\b[^>]*>/g)) {
    if (!/aria-hidden="true"|role="img"/.test(m[0]) && !/aria-hidden="true"/.test(body.slice(Math.max(0, m.index - 300), m.index))) fail(file, `svg without role or aria-hidden: ${m[0].slice(0, 80)}`);
  }

  // No outside requests: every resource is this site's own.
  for (const m of body.matchAll(/<(link|script|img|source|iframe)\b[^>]*\s(?:href|src)="([^"]+)"/g)) {
    const [, tag, url] = m;
    if (tag === 'link' && /rel="(canonical|alternate)"/.test(m[0])) continue;
    if (/^https?:|^\/\//.test(url)) fail(file, `outside ${tag}: ${url}`);
  }
  if (/@import|url\(https?:/.test(html)) fail(file, 'outside CSS');

  // Local links point at files that exist, and fragments at ids that exist.
  for (const m of body.matchAll(/\shref="([^"]+)"/g)) {
    const href = m[1];
    if (/^(https?:|mailto:)/.test(href)) continue;
    if (href.startsWith('#')) {
      if (href !== '#top' && href !== '#' && !ids.includes(href.slice(1))) fail(file, `no target for ${href}`);
      continue;
    }
    const path = href.split('#')[0].split('?')[0];
    const candidates = path === '/' ? ['index.html'] : [path.slice(1), `${path.slice(1)}.html`, join(path.slice(1), 'index.html')];
    if (!candidates.some((c) => existsSync(join(site, c)))) fail(file, `broken link ${href}`);
  }

  for (const m of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
    try {
      const data = JSON.parse(m[1]);
      const types = (data['@graph'] ?? [data]).flatMap((n) => [n['@type']].flat());
      for (const t of ['Organization', 'WebSite', 'SoftwareApplication', 'FAQPage']) if (!types.includes(t)) fail(file, `JSON-LD has no ${t}`);
      const app = data['@graph'].find((n) => [n['@type']].flat().includes('SoftwareApplication'));
      for (const k of ['name', 'operatingSystem', 'applicationCategory', 'offers', 'license', 'downloadUrl', 'softwareVersion', 'codeRepository']) if (!app[k]) fail(file, `SoftwareApplication has no ${k}`);
      const faq = data['@graph'].find((n) => n['@type'] === 'FAQPage');
      const shown = (html.match(/<details/g) ?? []).length;
      if (faq.mainEntity.length !== shown) fail(file, `FAQPage has ${faq.mainEntity.length} questions, the page shows ${shown}`);
    } catch (e) {
      fail(file, `JSON-LD does not parse: ${e.message}`);
    }
  }
  return html;
}

const pages = readdirSync(site).filter((f) => f.endsWith('.html'));
for (const p of ['index.html', 'privacy.html', '404.html']) if (!pages.includes(p)) fail(p, 'missing');
const htmls = Object.fromEntries(pages.map((p) => [p, checkHTML(p)]));

const index = htmls['index.html'] ?? '';
for (const tag of ['rel="canonical" href="https://getmossad.com/"', 'property="og:image" content="https://getmossad.com/og.png"', 'name="twitter:card" content="summary_large_image"', 'rel="apple-touch-icon"', 'rel="icon" href="/favicon.svg"', 'name="theme-color"', 'rel="preload" href="/fonts/bricolage-grotesque-latin.woff2"']) {
  if (!index.includes(tag)) fail('index.html', `missing ${tag}`);
}
if (!/noindex/.test(htmls['404.html'] ?? '')) fail('404.html', 'not noindex');

for (const f of ['og.png', 'favicon.svg', 'favicon-32.png', 'apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'robots.txt', 'sitemap.xml', 'llms.txt', 'llms-full.txt', 'humans.txt', 'site.webmanifest', 'beacon.js', '_headers',
  'fonts/bricolage-grotesque-latin.woff2', 'fonts/inter-latin.woff2', 'fonts/ibm-plex-mono-400-latin.woff2', 'fonts/ibm-plex-mono-500-latin.woff2', 'fonts/OFL-BricolageGrotesque.txt', 'fonts/OFL-Inter.txt', 'fonts/OFL-IBMPlexMono.txt']) {
  if (!existsSync(join(site, f))) fail(f, 'missing');
}
const png = readFileSync(join(site, 'og.png'));
if (png.readUInt32BE(16) !== 1200 || png.readUInt32BE(20) !== 630) fail('og.png', 'is not 1200 by 630');

const robots = readFileSync(join(site, 'robots.txt'), 'utf8');
if (!robots.includes('Sitemap: https://getmossad.com/sitemap.xml')) fail('robots.txt', 'no sitemap');
for (const bot of ['GPTBot', 'ClaudeBot', 'PerplexityBot', 'Google-Extended']) if (!robots.includes(`User-agent: ${bot}`)) fail('robots.txt', `no ${bot}`);
if (/Disallow: \/\s*$/m.test(robots)) fail('robots.txt', 'disallows the whole site');
const sitemap = readFileSync(join(site, 'sitemap.xml'), 'utf8');
for (const m of sitemap.matchAll(/<loc>https:\/\/getmossad\.com(\/[^<]*)<\/loc>/g)) {
  const p = m[1] === '/' ? 'index.html' : `${m[1].slice(1)}.html`;
  if (!existsSync(join(site, p))) fail('sitemap.xml', `no page for ${m[1]}`);
}
for (const f of ['llms.txt', 'llms-full.txt']) {
  const text = readFileSync(join(site, f), 'utf8');
  if (!text.startsWith('# Mossad\n\n> ')) fail(f, 'not in the llms.txt format');
  if (/[\u2013\u2014]/.test(text)) fail(f, 'an en or em dash');
  if (/getmossad\.app/.test(text)) fail(f, 'the old domain');
}
JSON.parse(readFileSync(join(site, 'site.webmanifest'), 'utf8'));

// Claims that anonymous usage statistics would make false.
const claims = /nothing (else )?leaves|no tracking|no telemetry|no analytics|sends no (analytics|usage|data)|never contacts|the one thing mossad does|nothing else leaves|no cloud|without the cloud/i;
for (const f of [...pages, 'llms.txt', 'llms-full.txt']) if (claims.test(readFileSync(join(site, f), 'utf8'))) fail(f, `a claim the usage statistics would make false: ${readFileSync(join(site, f), 'utf8').match(claims)[0]}`);

const content = readFileSync(join(site, '..', 'content', 'site.json'), 'utf8');
if (claims.test(content)) fail('site.json', `a claim the usage statistics would make false: ${content.match(claims)[0]}`);

if (errors.length) {
  console.error(errors.join('\n'));
  console.error(`\n${errors.length} problems`);
  process.exit(1);
}
console.log(`site check passed: ${pages.length} pages, links, JSON-LD, SEO tags, files`);
