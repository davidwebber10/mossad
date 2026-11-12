// Builds website/site from website/src and website/content/site.json. Static output only: the pages read nothing at run time.
// Usage: node website/scripts/build-site.mjs [--images]   (--images renders og.png and the PNG icons with Chrome)
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const src = join(root, 'src');
const out = join(root, 'site');
const read = (p) => readFileSync(p, 'utf8');
const site = JSON.parse(read(join(root, 'content', 'site.json')));

const ORIGIN = `https://${site.site.domain}`;
const REPO = site.site.repository;
const DOWNLOAD = site.hero.primaryAction.href;

function git(...args) {
  try { return execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; }
}

/** The latest release: the newest v* tag, else the newest entry of changelog.json, else site.json's softwareVersion. */
function latestVersion() {
  const tag = git('tag', '--list', 'v*', '--sort=-v:refname').split('\n')[0];
  if (/^v\d+\.\d+(\.\d+)?$/.test(tag)) return tag.slice(1);
  const log = JSON.parse(read(join(root, 'content', 'changelog.json')));
  if (log.releases?.[0]?.version) return String(log.releases[0].version).replace(/^v/, '');
  return site.site.softwareVersion;
}
const VERSION = latestVersion();
/** The day the site's sources last changed, so a rebuild with no change writes the same files. */
const UPDATED = git('log', '-1', '--format=%cs', '--', 'website/src', 'website/content/site.json') || new Date().toISOString().slice(0, 10);

// Comments and line breaks out. The source never has a space before ':' in a selector, so trimming around ':' is safe.
const minifyCSS = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\s*\n\s*/g, '').replace(/\s*([{};:,>])\s*/g, '$1').replace(/;}/g, '}').trim();
const CSS = minifyCSS(read(join(src, 'site.css')));

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const strip = (html) => html.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

// The line under the hero, as the design's build.py draws it: speech on the left settles into even marks on the right.
function waves() {
  const w1 = [], w2 = [];
  const f = (n) => (Math.round(n * 10) / 10).toFixed(1);
  for (let i = 0; i < 145; i++) {
    const x = 4 + 8 * i;
    if (i < 106) {
      const a = Math.abs(Math.sin(i * 0.37) * Math.sin(i * 0.11 + 1.0)) * (0.62 + 0.38 * Math.sin(i * 1.7));
      const fade = i < 84 ? 1.0 : Math.max(0.0, (106 - i) / 22.0);
      const h = 5 + 42 * Math.abs(a) * fade;
      w1.push(`M${x} ${f(28 - h / 2)}V${f(28 + h / 2)}`);
    } else {
      const h = (i - 106) % 6 === 0 ? 16 : 8;
      w2.push(`M${x} ${f(28 - h / 2)}V${f(28 + h / 2)}`);
    }
  }
  return [w1.join(''), w2.join('')];
}
const [WAVE1, WAVE2] = waves();

const logo = (size) => read(join(src, 'partials', 'logo.svg.html')).trim().replaceAll('{{SIZE}}', String(size));
const BOX = '<span class="box" aria-hidden="true"></span>';
const CHK = '<svg class="chk" width="16" height="16" viewBox="0 0 16 16" role="img" aria-label="Done"><rect width="16" height="16" rx="5" fill="#F2A05A"></rect><path d="M4.5 8.2l2.3 2.3 4.7-5" fill="none" stroke="#141210" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"></path></svg>';
const DOWNLOAD_ICON = '<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" fill="none" stroke="#141210" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2.5v9M5 8l4 4 4-4M3 15.5h12"></path></svg>';

/** The FAQ as the page shows it, read from the page's own source, so the structured data always matches what people see. */
function pageFAQ(html) {
  return [...html.matchAll(/<details[^>]*><summary><h3>([\s\S]*?)<\/h3><\/summary><p>([\s\S]*?)<\/p><\/details>/g)].map((m) => ({ q: strip(m[1]), a: strip(m[2]) }));
}

const pages = {
  'index.html': {
    path: '/',
    title: site.site.title,
    ogTitle: 'Mossad: intelligence on your own work',
    description: site.site.description,
    robots: 'index, follow, max-image-preview:large, max-snippet:-1',
    home: '#top',
  },
  'privacy.html': {
    path: '/privacy',
    title: 'Privacy: your meetings stay on your Mac | Mossad',
    ogTitle: 'Mossad privacy: your meetings stay on your Mac',
    description: 'Mossad keeps your meetings, recordings, names, and words on your Mac. See what stays there, where your meetings can go when you choose, and how you stay in control.',
    robots: 'index, follow',
    home: '/',
  },
  '404.html': {
    path: null,
    title: 'Page not found: Mossad',
    ogTitle: 'Mossad',
    description: site.site.description,
    robots: 'noindex, follow',
    home: '/',
  },
};

function jsonLD(faq) {
  const org = { '@type': 'Organization', '@id': `${ORIGIN}/#organization`, name: 'Mossad', url: `${ORIGIN}/`, logo: { '@type': 'ImageObject', url: `${ORIGIN}/icon-512.png`, width: 512, height: 512 }, sameAs: [REPO] };
  const website = { '@type': 'WebSite', '@id': `${ORIGIN}/#website`, name: 'Mossad', url: `${ORIGIN}/`, description: site.site.description, inLanguage: 'en', publisher: { '@id': `${ORIGIN}/#organization` } };
  const app = {
    '@type': ['SoftwareApplication', 'SoftwareSourceCode'],
    '@id': `${ORIGIN}/#app`,
    name: 'Mossad',
    description: site.site.description,
    url: `${ORIGIN}/`,
    image: `${ORIGIN}/og.png`,
    applicationCategory: 'BusinessApplication',
    applicationSubCategory: 'Meeting notes',
    operatingSystem: 'macOS 26',
    processorRequirements: 'Apple silicon',
    softwareVersion: VERSION,
    downloadUrl: DOWNLOAD,
    installUrl: DOWNLOAD,
    releaseNotes: `${site.site.releases}/tag/v${VERSION}`,
    license: 'https://opensource.org/licenses/MIT',
    isAccessibleForFree: true,
    codeRepository: REPO,
    programmingLanguage: 'Swift',
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    featureList: site.featureGroups.flatMap((g) => g.features.filter((f) => !f.comingSoon).map((f) => f.title)),
    author: { '@id': `${ORIGIN}/#organization` },
    publisher: { '@id': `${ORIGIN}/#organization` },
  };
  const faqPage = { '@type': 'FAQPage', '@id': `${ORIGIN}/#faq`, mainEntity: faq.map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) };
  return JSON.stringify({ '@context': 'https://schema.org', '@graph': [org, website, app, faqPage] }).replace(/</g, '\\u003c');
}

function fill(template, values) {
  let html = template;
  for (let pass = 0; pass < 3; pass++) for (const [k, v] of Object.entries(values)) html = html.replaceAll(`{{${k}}}`, v);
  const left = html.match(/\{\{[A-Z0-9_]+\}\}/g);
  if (left) throw new Error(`unfilled: ${[...new Set(left)].join(', ')}`);
  return html;
}

mkdirSync(join(out, 'fonts'), { recursive: true });
const indexSource = read(join(src, 'index.html'));
const FAQ = pageFAQ(indexSource);

for (const [file, page] of Object.entries(pages)) {
  let head = read(join(src, 'partials', 'head.html'));
  if (!page.path) head = head.split('\n').filter((l) => !/rel="canonical"|og:url/.test(l)).join('\n');
  const values = {
    HEAD: head.trim(),
    HEADER: read(join(src, 'partials', 'header.html')).trim(),
    FOOTER: read(join(src, 'partials', 'footer.html')).trim(),
    CSS,
    TITLE: esc(page.title),
    OG_TITLE: esc(page.ogTitle),
    DESCRIPTION: esc(page.description),
    URL: page.path ? `${ORIGIN}${page.path}` : '',
    ROBOTS: page.robots,
    ORIGIN,
    HOME: page.home,
    REPO,
    DOWNLOAD,
    DOWNLOAD_ICON,
    LOGO28: logo(28),
    LOGO22: logo(22),
    BOX,
    CHK,
    WAVE1,
    WAVE2,
    UPDATED,
    JSONLD: file === 'index.html' ? jsonLD(FAQ) : '',
    PRIVACY_INTRO: esc(site.privacy.intro),
    PRIVACY_POINTS: `<ul>${site.privacy.points.map((p) => `<li><strong>${esc(p.title)}.</strong> ${esc(p.body)}</li>`).join('')}</ul>`,
    LEAVES_TITLE: esc(site.privacy.leavesTheMac.title),
    LEAVES_ITEMS: `<ul>${site.privacy.leavesTheMac.items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>`,
    NEVER_LEAVES: esc(site.privacy.leavesTheMac.neverLeaves),
  };
  writeFileSync(join(out, file), fill(read(join(src, file)), values));
}

// The download beacon: one word to /api/click, no cookie, no identifier.
writeFileSync(join(out, 'beacon.js'), `document.addEventListener('click',function(e){var a=e.target&&e.target.closest&&e.target.closest('a[data-download]');if(!a||!navigator.sendBeacon)return;try{navigator.sendBeacon('/api/click',a.getAttribute('data-download'))}catch(_){}});\n`);

writeFileSync(join(out, 'favicon.svg'), `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><rect width="28" height="28" rx="8" fill="#F2A05A"/><path d="M8 17v-6M12 20V8M16 18v-8M20 15v-2" stroke="#141210" stroke-width="2.4" stroke-linecap="round"/></svg>\n`);

writeFileSync(join(out, 'site.webmanifest'), JSON.stringify({
  name: 'Mossad', short_name: 'Mossad', description: site.site.description, start_url: '/', display: 'browser',
  background_color: '#141210', theme_color: '#141210',
  icons: [{ src: '/icon-192.png', sizes: '192x192', type: 'image/png' }, { src: '/icon-512.png', sizes: '512x512', type: 'image/png' }, { src: '/favicon.svg', sizes: 'any', type: 'image/svg+xml' }],
}, null, 2) + '\n');

const crawlers = ['GPTBot', 'OAI-SearchBot', 'ChatGPT-User', 'ClaudeBot', 'Claude-User', 'Claude-SearchBot', 'anthropic-ai', 'PerplexityBot', 'Perplexity-User', 'Google-Extended', 'Googlebot', 'Bingbot', 'Applebot', 'Applebot-Extended', 'DuckDuckBot', 'CCBot', 'Meta-ExternalAgent', 'Amazonbot', 'cohere-ai', 'MistralAI-User', 'YouBot', 'Bytespider'];
writeFileSync(join(out, 'robots.txt'), [
  '# Every search engine and AI crawler is welcome. Only the owner dashboard and the API are off limits.',
  ...crawlers.flatMap((c) => [`User-agent: ${c}`, 'Allow: /', 'Disallow: /stats', 'Disallow: /api/', '']),
  'User-agent: *', 'Allow: /', 'Disallow: /stats', 'Disallow: /api/', '',
  `Sitemap: ${ORIGIN}/sitemap.xml`, '',
].join('\n'));

writeFileSync(join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${Object.values(pages).filter((p) => p.path).map((p) => `  <url><loc>${ORIGIN}${p.path}</loc><lastmod>${UPDATED}</lastmod></url>`).join('\n')}
</urlset>
`);

writeFileSync(join(out, 'humans.txt'), `/* TEAM */
Maker: the Mossad contributors
Source: ${REPO}

/* SITE */
Last update: ${UPDATED}
Standards: HTML, CSS
Fonts: Bricolage Grotesque, Inter, IBM Plex Mono (SIL Open Font License, in /fonts)
Components: none. No cookies, no third-party requests.
`);

// llms.txt (https://llmstxt.org): what Mossad is, in Markdown, for AI tools.
const live = (g) => g.features.filter((f) => !f.comingSoon);
const privacyLines = [
  ...site.privacy.points.map((p) => `- **${p.title}.** ${p.body}`),
];
const intro = `> ${site.site.description}`;
const summaryLines = [
  `Mossad is work intelligence for your Mac. It records your calls without a bot, then keeps meeting notes, transcripts that know who spoke, decisions, action items, the promises you made, and a page for each person you meet. Before a meeting, it shows who is coming, what happened last time, and what you still owe. It is free and open source under the ${site.site.license} License.`,
  '',
  `- Latest version: ${VERSION}`,
  `- Requires: ${site.requirements.items.find((i) => i.label === 'Mac').value}`,
  `- Price: free. Cloud AI providers that you connect bill you directly; models on your Mac cost nothing.`,
  `- Website: ${ORIGIN}/`,
  `- Source: ${REPO}`,
];
const links = [
  '## Links',
  '',
  `- [Download the latest release](${DOWNLOAD}): the Mac app`,
  `- [Source code](${REPO}): the Mac app, the iPhone app, and the optional server, in one repository`,
  `- [README](${REPO}#readme): setup, providers, and limits`,
  `- [Where your data lives](${REPO}#where-your-data-lives): the folders on your Mac`,
  `- [Lawful use](${REPO}#lawful-use): recording consent`,
  `- [Privacy](${ORIGIN}/privacy): what stays on your Mac, and where your meetings can go when you choose`,
  `- [Full text for AI tools](${ORIGIN}/llms-full.txt): every feature, install, privacy, and FAQ`,
];

const llms = [
  '# Mossad', '', intro, '', ...summaryLines, '',
  '## Features', '',
  ...site.featureGroups.map((g) => `- **${g.title}.** ${g.intro} ${live(g).map((f) => f.title).join('; ')}.`), '',
  '## Privacy', '', site.privacy.intro, '', ...privacyLines, `- ${site.privacy.leavesTheMac.neverLeaves}`, '',
  '## Install', '',
  `1. Download the latest release from ${DOWNLOAD} and move Mossad to Applications, or build it from the source with Xcode (see the README).`,
  '2. Open it, and follow setup: pick a transcription provider and a notes model, or models that run on your Mac, and grant the permissions it asks for.',
  '3. Take your calls as usual. Notes appear in ~/Mossad/Meetings.', '',
  '## FAQ', '', ...FAQ.flatMap(({ q, a }) => [`### ${q}`, '', a, '']),
  ...links, '',
].join('\n');
writeFileSync(join(out, 'llms.txt'), llms);

function readmeSection(title) {
  const text = read(join(repo, 'README.md'));
  const start = text.indexOf(`\n## ${title}\n`);
  if (start < 0) throw new Error(`README has no section ${title}`);
  const rest = text.slice(start + 1);
  const end = rest.indexOf('\n## ', 4);
  return rest.slice(rest.indexOf('\n') + 1, end < 0 ? undefined : end).trim().replace(/^#/gm, '##').replace(/\]\(#/g, `](${REPO}#`);
}

const full = [
  '# Mossad', '', intro, '', ...summaryLines, '',
  '## How it works', '', site.howItWorks.intro, '',
  ...site.howItWorks.steps.map((s, i) => `${i + 1}. **${s.title}.** ${s.body}`), '',
  '## Features', '',
  ...site.featureGroups.flatMap((g) => [
    `### ${g.title}`, '', g.intro, '',
    ...g.features.flatMap((f) => [
      `- **${f.title}${f.comingSoon ? ' (coming soon)' : ''}.** ${f.body}`,
      ...f.details.map((d) => `  - ${d}`),
    ]), '',
  ]),
  '## Requirements', '', ...site.requirements.items.map((i) => `- **${i.label}:** ${i.value}`), '',
  '## Install', '',
  `Download the latest release from ${DOWNLOAD}, or build it from the source. The README's steps to build it:`, '',
  readmeSection('Setup'), '',
  '## Privacy', '', site.privacy.intro, '',
  ...privacyLines, '',
  `### ${site.privacy.leavesTheMac.title}`, '', ...site.privacy.leavesTheMac.items.map((i) => `- ${i}`), '', site.privacy.leavesTheMac.neverLeaves, '',
  '### Where your data lives (from the README)', '', readmeSection('Where your data lives'), '',
  '## Open source', '', site.openSource.body, '', ...site.openSource.points.map((p) => `- ${p}`), '',
  '## FAQ', '', ...site.faq.flatMap((f) => [`### ${f.question}`, '', f.answer, '']),
  ...FAQ.filter((f) => !site.faq.some((s) => s.question === f.q)).flatMap(({ q, a }) => [`### ${q}`, '', a, '']),
  '## Recording consent', '', 'Mossad does not announce itself on a call. Tell the people you record, and get consent where the law requires it. Voice fingerprints can be biometric data under some laws.', '',
  '## Legal', '', site.footer.text, '',
  ...links, '',
].join('\n');
writeFileSync(join(out, 'llms-full.txt'), full);

writeFileSync(join(out, '_headers'), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=(), browsing-topics=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Cross-Origin-Opener-Policy: same-origin
  Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; object-src 'none'

/fonts/*
  Cache-Control: public, max-age=31536000, immutable

/*.png
  Cache-Control: public, max-age=86400

/*.txt
  Content-Type: text/plain; charset=utf-8
`);

if (process.argv.includes('--images')) renderImages();

function chrome() {
  const candidates = [process.env.CHROME, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium', '/usr/bin/google-chrome', '/usr/bin/chromium'];
  const found = candidates.find((c) => c && existsSync(c));
  if (!found) throw new Error('--images needs Chrome or Chromium (set CHROME to its path)');
  return found;
}

function shot(input, output, width, height) {
  execFileSync(chrome(), ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1', '--default-background-color=00000000', `--window-size=${width},${height}`, `--screenshot=${output}`, `file://${input}`], { stdio: 'ignore' });
}

function renderImages() {
  const tmp = join(root, '.render');
  mkdirSync(tmp, { recursive: true });
  // og.svg links the fonts by a path relative to website/src, so render it from there through a page that shows it at full size.
  const og = read(join(src, 'og.svg')).replaceAll('../site/fonts/', `file://${out}/fonts/`);
  writeFileSync(join(tmp, 'og.svg'), og);
  shot(join(tmp, 'og.svg'), join(out, 'og.png'), 1200, 630);
  const icon = (size, padded) => `<!doctype html><html><body style="margin:0;background:${padded ? '#F2A05A' : 'transparent'}"><svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 28 28" style="display:block">${padded ? '' : '<rect width="28" height="28" rx="8" fill="#F2A05A"/>'}<path d="M8 17v-6M12 20V8M16 18v-8M20 15v-2" stroke="#141210" stroke-width="2.4" stroke-linecap="round" ${padded ? 'transform="translate(2.8 2.8) scale(0.8)"' : ''}/></svg></body></html>`;
  for (const [name, size, padded] of [['favicon-32.png', 32, false], ['icon-192.png', 192, false], ['icon-512.png', 512, false], ['apple-touch-icon.png', 180, true]]) {
    writeFileSync(join(tmp, `${name}.html`), icon(size, padded));
    shot(join(tmp, `${name}.html`), join(out, name), size, size);
  }
  execFileSync('rm', ['-rf', tmp]);
}

console.log(`built ${Object.keys(pages).length} pages, version ${VERSION}, updated ${UPDATED}`);
