import { copyText, minutesText, when } from './markdown';
import type { ActionItem, Decision, Share } from './types';
import { decisionLine, escapeHtml as e, formatDay, timestamp } from './util';

/**
 * The pages a visitor sees. They are set as a document, not as an app: one text face with its italic, a margin
 * column for labels and a text column of about 70 characters, hairlines where a group starts, and no boxes. A
 * page does not name the software that serves it.
 */

export const fonts = { roman: '/f/literata-v1.woff2', italic: '/f/literata-italic-v1.woff2' };

const CSS = `
@font-face{font-family:Literata;src:url(${fonts.roman}) format("woff2");font-weight:200 900;font-style:normal;font-display:swap}
@font-face{font-family:Literata;src:url(${fonts.italic}) format("woff2");font-weight:200 900;font-style:italic;font-display:swap}
:root{color-scheme:light dark;--paper:#fbfbf9;--ink:#17191c;--soft:#565a61;--faint:#8b8f96;--rule:#d3d4cf;--hair:#e7e7e2;--mark:#efeee4;--accent:#17594a;
--serif:Literata,Charter,"Iowan Old Style","Sitka Text",Cambria,Georgia,serif;--margin:10.5rem;--gap:2.75rem;--measure:37.5rem;--page:calc(var(--margin) + var(--gap) + var(--measure))}
@media (prefers-color-scheme:dark){:root{--paper:#121314;--ink:#e8e6e1;--soft:#a6a8ab;--faint:#75787c;--rule:#35373b;--hair:#242628;--mark:#1c2321;--accent:#86c9b1}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%;scroll-padding-top:1.5rem}
body{margin:0;background:var(--paper);color:var(--ink);font:400 1.0625rem/1.62 var(--serif);font-kerning:normal;text-rendering:optimizeLegibility;-webkit-font-smoothing:antialiased;hanging-punctuation:first}
::selection{background:color-mix(in srgb,var(--accent) 24%,transparent)}
:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:1px}
a{color:inherit;text-decoration-thickness:1px;text-underline-offset:.2em;text-decoration-color:var(--faint)}
button,input,textarea{font:inherit;color:inherit}
h1,h2,h3,p{margin:0}
.doc{max-width:var(--page);margin:0 auto;padding:clamp(2.25rem,8vh,5.5rem) 1.375rem 4rem}
.has-player .doc{padding-bottom:8rem}
.label,.sec h2,.toc a,.btn,.who{font-size:.71875rem;font-weight:650;letter-spacing:.115em;text-transform:uppercase;line-height:1.5}
.nums,.t,.meta,.pt{font-variant-numeric:tabular-nums lining-nums}

.head h1{font-size:clamp(2rem,1.25rem + 3.4vw,3.05rem);line-height:1.07;font-weight:500;letter-spacing:-.019em;text-wrap:balance}
.by{margin-top:.95rem;font-style:italic;color:var(--soft)}
.meta{margin-top:1.15rem;font-size:.8125rem;line-height:1.6;color:var(--soft);display:flex;flex-wrap:wrap;column-gap:1.1rem}
.meta p:first-child{color:var(--ink);font-weight:600}
.toc{display:flex;flex-wrap:wrap;gap:.35rem 1.35rem;margin-top:1.75rem}
.toc a{color:var(--soft);text-decoration:none;padding:.2rem 0}
.toc a:hover{color:var(--ink)}

.sec{border-top:1px solid var(--rule);padding:1.3rem 0 2.5rem}
.head + .sec{margin-top:2.6rem}
.sec h2{color:var(--soft);margin:.1rem 0 .9rem}
.sec.slim{padding-bottom:1.35rem}
.names{text-wrap:pretty}

.prose p{margin:0 0 .85em;text-wrap:pretty}
.prose > :last-child{margin-bottom:0}
.prose .lead{font-size:1.17em;line-height:1.5;letter-spacing:-.004em;margin-bottom:1em}
.prose h3{font-size:1em;font-weight:650;line-height:1.4;margin:1.85em 0 .3em}
.prose b{font-weight:650}
.prose ul{list-style:none;margin:0 0 .85em;padding:0 0 0 1.25em}
.prose li{position:relative;margin:.28em 0;text-wrap:pretty}
.prose li::before{content:"\\2013";position:absolute;left:-1.25em;color:var(--faint)}

.dec{list-style:none;margin:0;padding:0;counter-reset:d}
.dec li{counter-increment:d;position:relative;padding-left:1.9em;margin:0 0 .65em;text-wrap:pretty}
.dec li:last-child{margin-bottom:0}
.dec li::before{content:counter(d);position:absolute;left:0;top:.28em;font-size:.78em;font-weight:650;color:var(--faint);font-variant-numeric:tabular-nums lining-nums}
.t{background:none;border:0;padding:0;margin:0;font-size:.75rem;color:var(--faint);white-space:nowrap}
.dec .t{margin-left:.45em}
button.t{cursor:pointer}
button.t:hover{color:var(--accent);text-decoration:underline;text-underline-offset:.2em}

.grp{display:grid;grid-template-columns:8.25rem minmax(0,1fr);column-gap:1.25rem;padding:.7rem 0;border-top:1px solid var(--hair)}
.grp:first-child{border-top:0;padding-top:0}.grp:last-child{padding-bottom:0}
.grp h3{font-size:.875rem;font-weight:650;line-height:1.97}
.grp h3.none{font-weight:400;font-style:italic;color:var(--faint)}
.grp ul{list-style:none;margin:0;padding:0}
.grp li{position:relative;padding-left:1.55em;margin:0 0 .3em;text-wrap:pretty}
.grp li:last-child{margin-bottom:0}
.grp li::before{content:"";position:absolute;left:.05em;top:.46em;width:.66em;height:.66em;border:1.25px solid var(--soft);border-radius:1.5px}

.find{display:block;width:100%;font-size:.875rem;background:none;border:0;border-bottom:1px solid var(--rule);border-radius:0;padding:.3rem 0;-webkit-appearance:none;appearance:none}
.find::placeholder,.ask textarea::placeholder{color:var(--faint);font-style:italic;opacity:1}
.find:focus,.ask textarea:focus{outline:0}
.find:focus{border-bottom-color:var(--ink)}
.count{font-size:.75rem;color:var(--faint);min-height:1.35rem;padding-top:.3rem;font-variant-numeric:tabular-nums lining-nums}
.ln{display:grid;grid-template-columns:3.1rem minmax(0,1fr);column-gap:.95rem;align-items:baseline;padding:.14rem .55rem;margin:0 -.55rem;border-radius:2px}
.ln.turn{margin-top:.95rem}
.ln.turn:first-child{margin-top:0}
.ln .t{justify-self:end}
.who{display:block;line-height:1.75}
.ln.same .who{display:none}
.finding .ln.same .who{display:block}
.finding .ln{margin-top:.8rem}
.ln p{text-wrap:pretty}
.seek .ln{cursor:pointer}
.seek .ln:hover,.ln.now,.ln.flash{background:var(--mark)}
.ln.now{box-shadow:inset 2px 0 0 var(--accent)}
.ln.now .t{color:var(--accent)}
.hide{display:none}

.qa .q{font-weight:650;margin:0 0 .25em}
.qa .a{white-space:pre-wrap;margin:0 0 1.3em;text-wrap:pretty}
.qa .wait{color:var(--faint);font-style:italic}
.ask{display:flex;align-items:flex-end;gap:.9rem;border-bottom:1px solid var(--ink);padding-bottom:.45rem}
.ask textarea{flex:1;min-width:0;resize:none;background:none;border:0;border-radius:0;padding:.2rem 0;line-height:1.5}
.note{font-size:.8125rem;line-height:1.55;color:var(--faint);margin-top:.7rem;text-wrap:pretty}
.btn{flex:none;color:var(--ink);background:none;border:1px solid var(--ink);border-radius:2px;padding:.6rem .85rem .56rem;cursor:pointer;line-height:1}
.btn:hover,.btn.done{background:var(--ink);color:var(--paper)}
.btn:disabled{opacity:.4;cursor:default}
.btn.ghost{border-color:var(--rule);color:var(--soft)}

.foot{border-top:1px solid var(--rule);padding-top:1.4rem}
.ai{display:flex;flex-wrap:wrap;align-items:center;gap:.7rem 1.1rem}
.ai .note{margin:0;flex:1 1 14rem}
.foot .fine{font-size:.8125rem;line-height:1.55;color:var(--faint);margin-top:1.5rem;text-wrap:pretty}
.off{position:fixed;left:-99rem;top:0;opacity:0}

.player{position:fixed;left:0;right:0;bottom:0;background:var(--paper);border-top:1px solid var(--rule);padding:.55rem 0 calc(.55rem + env(safe-area-inset-bottom))}
.player audio{display:block;width:100%;max-width:var(--page);margin:0 auto;padding:0 1.375rem}
.ctl{display:flex;align-items:center;gap:.85rem;max-width:var(--page);margin:0 auto;padding:0 1.375rem}
.ctl[hidden]{display:none}
.pp{flex:none;width:2.3rem;height:2.3rem;border-radius:50%;border:1px solid var(--ink);background:none;display:grid;place-items:center;cursor:pointer;padding:0}
.pp:hover{background:var(--ink);color:var(--paper)}
.pp svg{width:.95rem;height:.95rem;fill:currentColor}
.pp .i-pause,.playing .i-play{display:none}
.playing .i-pause{display:block}
.pt{font-size:.75rem;color:var(--soft);min-width:2.4rem}
.pt + input + .pt{text-align:right}
.ctl input{flex:1;min-width:3rem;-webkit-appearance:none;appearance:none;background:none;height:1.6rem;margin:0;cursor:pointer}
.ctl input::-webkit-slider-runnable-track{height:2px;background:linear-gradient(var(--ink),var(--ink)) 0/var(--p,0%) 100% no-repeat,var(--rule)}
.ctl input::-webkit-slider-thumb{-webkit-appearance:none;width:.72rem;height:.72rem;border-radius:50%;background:var(--ink);margin-top:calc(1px - .36rem)}
.ctl input::-moz-range-track{height:2px;background:var(--rule)}
.ctl input::-moz-range-progress{height:2px;background:var(--ink)}
.ctl input::-moz-range-thumb{width:.72rem;height:.72rem;border:0;border-radius:50%;background:var(--ink)}
.rate{flex:none;min-width:2.6rem;background:none;border:0;padding:.3rem 0;font-size:.8125rem;font-weight:650;color:var(--soft);cursor:pointer;text-align:right;font-variant-numeric:tabular-nums lining-nums}
.rate:hover{color:var(--ink)}

.gate{padding-top:clamp(3rem,18vh,9rem);max-width:33rem}
.gate .label{color:var(--soft);margin-bottom:1.1rem}
.gate h1{font-size:clamp(1.9rem,1.4rem + 2.4vw,2.5rem);line-height:1.1;font-weight:500;letter-spacing:-.017em;text-wrap:balance}
.gate .lede{margin-top:1rem;color:var(--soft);text-wrap:pretty}
.gate .lede b{color:var(--ink);font-weight:650}
.pinform{display:flex;align-items:flex-end;gap:1.25rem;margin-top:2.4rem}
.pinform input{width:4.35em;font-size:2.5rem;font-weight:500;line-height:1.1;letter-spacing:.4em;font-variant-numeric:tabular-nums lining-nums;background:none;border:0;border-bottom:2px solid var(--ink);border-radius:0;padding:0 0 .3rem .08em;caret-color:var(--accent);-webkit-appearance:none;appearance:none}
.pinform input:focus{outline:0;border-bottom-color:var(--accent)}
.pinform input::placeholder{color:var(--rule);opacity:1}
.pinform .btn{margin-bottom:.55rem}
.msg{margin-top:1.3rem;font-size:.9375rem;min-height:1.6em;text-wrap:pretty}
.field{display:block;margin-top:1.9rem}
.field input{display:block;width:100%;margin-top:.5rem;background:none;border:0;border-bottom:1px solid var(--ink);border-radius:0;padding:.35rem 0;font-size:1rem}
.field input:focus{outline:0;border-bottom-color:var(--accent)}
.row2{display:flex;gap:.75rem;margin-top:1.6rem}

@media (min-width:52rem){
body{font-size:1.125rem}
.doc,.ctl,.player audio{padding-left:2rem;padding-right:2rem}
.row{display:grid;grid-template-columns:var(--margin) minmax(0,1fr);column-gap:var(--gap)}
.row > .side{grid-column:1;grid-row:1}
.row > .main{grid-column:2;grid-row:1;min-width:0}
.row > .toc{grid-column:2;grid-row:2}
.sec > .side{position:sticky;top:1.5rem;align-self:start}
.head .meta{display:block;margin-top:0;padding-top:.85rem}
.sec{padding:1.2rem 0 3rem}
.sec.slim{padding-bottom:1.3rem}
.sec h2{margin:.42rem 0 .8rem}
.prose ul{padding-left:0}
.dec li{padding-left:0}
.dec li::before{left:-1.75em}
.foot{padding-top:1.5rem}
}
@media (min-width:74rem){.doc,.ctl,.player audio{position:relative;left:-2.5rem}}
@media (max-width:33.99rem){
.grp{display:block}
.grp h3{line-height:1.5;margin-bottom:.3rem}
.ln{grid-template-columns:2.7rem minmax(0,1fr);column-gap:.75rem}
.pinform input{font-size:2.2rem}
}
@media print{
@page{margin:18mm 17mm 20mm}
:root{--paper:#fff;--ink:#000;--soft:#333;--faint:#555;--rule:#999;--hair:#ccc;--mark:transparent}
body{font-size:10.5pt;line-height:1.5}
.doc{max-width:none;padding:0;left:0}
.row{display:grid;grid-template-columns:7rem minmax(0,1fr);column-gap:1.5rem}
.row > .side{grid-column:1;grid-row:1}
.row > .main{grid-column:2;grid-row:1;min-width:0}
.head .meta{display:block;margin-top:0;padding-top:.45rem}
.player,.toc,.find,.count,.ask,.ai,#questions .note{display:none}
.sec > .side{position:static}
.sec{padding-bottom:1.6rem}
h1,h2,h3,.who{break-after:avoid}
.ln,.grp li,.dec li{break-inside:avoid}
.hide{display:grid}
.ln.now,.ln.flash{background:none;box-shadow:none}
}
`;

/** The summary's small Markdown: **bold** and "- " lists, after escaping, so nothing else becomes HTML. */
export function md(text: string, lead = false): string {
  const out: string[] = [];
  let list: string[] = [];
  const flush = () => { if (list.length) { out.push(`<ul>${list.map((l) => `<li>${l}</li>`).join('')}</ul>`); list = []; } };
  for (const raw of text.split('\n')) {
    const line = e(raw.trim()).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
    if (/^[-*] /.test(raw.trim())) { list.push(line.slice(2)); continue; }
    flush();
    if (line) out.push(lead && !out.length ? `<p class="lead">${line}</p>` : `<p>${line}</p>`);
  }
  flush();
  return out.join('');
}

interface Head { title: string; description?: string; preload?: boolean; bodyClass?: string }

function page(head: Head, nonce: string, body: string, script = ''): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#fbfbf9" media="(prefers-color-scheme:light)"><meta name="theme-color" content="#121314" media="(prefers-color-scheme:dark)">
<title>${e(head.title)}</title>${head.description ? `
<meta name="description" content="${e(head.description)}">
<meta property="og:type" content="article"><meta property="og:title" content="${e(head.title)}"><meta property="og:description" content="${e(head.description)}">` : ''}
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect x='3' y='1.5' width='10' height='13' rx='1' fill='%2317594a'/%3E%3Cpath d='M5.5 5.5h5M5.5 8h5M5.5 10.5h3' stroke='%23fff' stroke-width='1'/%3E%3C/svg%3E">${head.preload ? `
<link rel="preload" href="${fonts.roman}" as="font" type="font/woff2" crossorigin>` : ''}
<style nonce="${nonce}">${CSS}</style></head>
<body${head.bodyClass ? ` class="${head.bodyClass}"` : ''}>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ''}</body></html>`;
}

/** "1:05" in a meeting under an hour, "1:01:05" in a longer one: the times of one transcript are one width. */
export function clock(seconds: number, long: boolean): string {
  const s = Math.max(0, Math.floor(seconds));
  const two = (n: number) => String(n).padStart(2, '0');
  return long ? `${Math.floor(s / 3600)}:${two(Math.floor((s % 3600) / 60))}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`;
}

const section = (id: string, title: string, main: string, side = '', extra = '') =>
  `<section class="sec row${extra}" id="${id}"><div class="side"><h2>${title}</h2>${side}</div><div class="main">${main}</div></section>`;

/** Tasks under the person who has them, in the order the people first come up; tasks with no owner are last. */
function actionGroups(items: ActionItem[]): string {
  const groups = new Map<string, string[]>();
  for (const a of items) {
    const owner = a.owner?.trim() ?? '';
    groups.set(owner, [...(groups.get(owner) ?? []), owner ? a.task : a.text]);
  }
  const ordered = [...groups].sort((a, b) => Number(!a[0]) - Number(!b[0]));
  return ordered.map(([owner, tasks]) => `<div class="grp"><h3${owner ? '' : ' class="none"'}>${owner ? e(owner) : 'No owner'}</h3><ul>${tasks.map((t) => `<li>${e(t)}</li>`).join('')}</ul></div>`).join('');
}

export interface PageOptions {
  /** "https://notes.example.com", for the address of the Markdown. */
  origin: string;
  /** A share with a PIN has no Markdown address. */
  pin: boolean;
}

export function sharePage(s: Share, token: string, nonce: string, o: PageOptions): string {
  const w = when(s);
  const long = (s.lines?.at(-1)?.at ?? 0) >= 3600 || w.minutes >= 60;
  const canGo = s.audio || !!s.lines?.length;
  const time = (at: number | null | undefined) => at == null ? ''
    : canGo ? ` <button class="t" type="button" data-go="${at}" aria-label="Go to ${timestamp(at)}">${clock(at, long)}</button>` : ` <span class="t">${clock(at, long)}</span>`;
  const decisionAt = (d: Decision, i: number) => (typeof d === 'string' ? s.decisionTimes?.[i] : (d.at ?? s.decisionTimes?.[i]));
  const hasSummary = !!(s.summary || s.topics?.length);

  const toc: [string, string][] = [];
  const parts: string[] = [];
  if (s.people.length) parts.push(section('present', 'Present', `<p class="names">${s.people.map(e).join(', ')}</p>`, '', ' slim'));
  if (hasSummary) {
    toc.push(['summary', 'Summary']);
    parts.push(section('summary', 'Summary', `<div class="prose">${s.summary ? md(s.summary, true) : ''}${(s.topics ?? []).map((t) => `<h3>${e(t.title)}</h3>${md(t.summary)}`).join('')}</div>`));
  }
  if (s.decisions?.length) {
    toc.push(['decisions', 'Decisions']);
    parts.push(section('decisions', 'Decisions', `<ol class="dec">${s.decisions.map((d, i) => `<li>${e(typeof d === 'string' ? d : d.text)}${time(decisionAt(d, i))}</li>`).join('')}</ol>`));
  }
  if (s.actionItems?.length) {
    toc.push(['actions', 'Action items']);
    parts.push(section('actions', 'Action items', actionGroups(s.actionItems)));
  }
  if (s.chat) {
    toc.push(['questions', 'Questions']);
    parts.push(section('questions', 'Questions', `<div class="qa" id="chat" aria-live="polite"></div>
<form class="ask" id="ask"><textarea id="q" rows="1" maxlength="2000" placeholder="Ask about this meeting" aria-label="Your question"></textarea><button class="btn" id="send">Ask</button></form>
<p class="note">An AI answers from this page only. Check an answer against the transcript.</p>`));
  }
  if (s.lines?.length) {
    toc.push(['transcript', 'Transcript']);
    let last = '';
    const lines = s.lines.map((l) => {
      const turn = l.speaker !== last;
      last = l.speaker;
      return `<div class="ln ${turn ? 'turn' : 'same'}" data-t="${l.at}">${s.audio ? `<button class="t" type="button" data-go="${l.at}" aria-label="Play from ${timestamp(l.at)}">${clock(l.at, long)}</button>` : `<span class="t">${clock(l.at, long)}</span>`}<div><b class="who">${e(l.speaker)}</b><p>${e(l.text)}</p></div></div>`;
    }).join('');
    parts.push(section('transcript', 'Transcript', `<div class="lines${s.audio ? ' seek' : ''}" id="lines">${lines}</div>`,
      `<input class="find" id="find" type="search" placeholder="Find in transcript" aria-label="Find in transcript" autocomplete="off"><p class="count" id="count" aria-live="polite"></p>`));
  }

  const until = s.expires ? ` The link stops working on ${e(new Intl.DateTimeFormat('en-US', { timeZone: s.timeZone ?? 'UTC', year: 'numeric', month: 'long', day: 'numeric' }).format(new Date(s.expires)))}.` : '';
  const header = `<header class="head row"><div class="main"><h1>${e(s.title)}</h1><p class="by">Shared by ${e(s.owner)}</p></div>
<div class="side meta"><p>${e(w.day.replace(/^\w+, /, ''))}</p><p>${e(w.time)}</p><p>${minutesText(w.minutes)}</p></div>${toc.length > 1 ? `
<nav class="toc" aria-label="On this page">${toc.map(([id, name]) => `<a href="#${id}">${name}</a>`).join('')}</nav>` : ''}</header>`;
  const footer = `<footer class="foot row"><div class="side"></div><div class="main">
<div class="ai"><button class="btn" id="copy" type="button">Copy for your AI</button><p class="note">Puts these notes and the transcript on your clipboard as text, to paste into an AI assistant.</p></div>
<textarea id="md" hidden readonly aria-hidden="true">${e(copyText(s, o.pin ? null : `${o.origin}/${token}.md`))}</textarea>
<p class="fine">This page is private. Only people who have the link${o.pin ? ' and the PIN' : ''} can open it.${until}</p></div></footer>`;
  const player = s.audio ? `<div class="player" id="player"><audio id="audio" controls preload="metadata" src="/${token}/audio"></audio>
<div class="ctl" id="ctl" hidden><button class="pp" id="pp" type="button" aria-label="Play"><svg class="i-play" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.6 2.6v10.8L13.4 8z"/></svg><svg class="i-pause" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.8 2.8h3v10.4h-3zM9.2 2.8h3v10.4h-3z"/></svg></button>
<span class="pt" id="pt">${clock(0, long)}</span><input id="pos" type="range" min="0" max="1000" value="0" aria-label="Position"><span class="pt" id="pd">${clock(w.minutes * 60, long)}</span>
<button class="rate" id="rate" type="button" aria-label="Speed">1×</button></div></div>` : '';
  return page({ title: s.title, description: `Shared by ${s.owner}. ${w.day}, ${minutesText(w.minutes)}.`, preload: true, bodyClass: s.audio ? 'has-player' : '' }, nonce,
    `<main class="doc">${header}\n${parts.join('\n')}\n${footer}</main>${player}`, shareScript(token, long));
}

function shareScript(token: string, long: boolean): string {
  return `
const $=id=>document.getElementById(id),A=$('audio'),L=[...document.querySelectorAll('.ln')],LONG=${long};
const two=n=>String(n).padStart(2,'0');
const fmt=s=>{s=Math.max(0,Math.floor(s));return LONG?Math.floor(s/3600)+':'+two(Math.floor(s%3600/60))+':'+two(s%60):Math.floor(s/60)+':'+two(s%60)};
const lineAt=t=>{let f=L[0];for(const el of L){if(+el.dataset.t<=t+.5)f=el;else break}return f};
const go=(t,show)=>{const el=lineAt(t);if(el&&show){el.classList.remove('hide');el.scrollIntoView({block:'center'});el.classList.add('flash');setTimeout(()=>el.classList.remove('flash'),1800)}if(A){A.currentTime=t;A.play()}};
document.addEventListener('click',ev=>{
  const b=ev.target.closest('[data-go]');if(b){go(+b.dataset.go,!b.closest('.ln'));return}
  const l=A&&ev.target.closest('.ln');if(l&&!String(getSelection()))go(+l.dataset.t,false);
});
const find=$('find');
if(find)find.addEventListener('input',()=>{
  const q=find.value.trim().toLowerCase();let n=0;
  for(const el of L){const hit=!q||el.textContent.toLowerCase().includes(q);el.classList.toggle('hide',!hit);if(hit)n++}
  $('lines').classList.toggle('finding',!!q);$('count').textContent=q?(n===1?'1 line':n+' lines'):'';
});
if(A){
  const ctl=$('ctl'),pp=$('pp'),pos=$('pos'),pt=$('pt'),pd=$('pd'),rate=$('rate'),rates=[1,1.25,1.5,2];let now=null,drag=false;
  A.controls=false;A.hidden=true;ctl.hidden=false;
  const len=()=>isFinite(A.duration)&&A.duration>0?A.duration:0;
  const draw=()=>{const d=len(),t=A.currentTime;if(d)pd.textContent=fmt(d);pt.textContent=fmt(t);
    if(!drag){pos.value=d?Math.round(t/d*1000):0;pos.style.setProperty('--p',(d?t/d*100:0)+'%')}
    const el=A.paused&&!t?null:lineAt(t);if(el!==now){if(now)now.classList.remove('now');if(el)el.classList.add('now');now=el}};
  pp.addEventListener('click',()=>A.paused?A.play():A.pause());
  for(const name of ['play','pause','ended'])A.addEventListener(name,()=>{ctl.classList.toggle('playing',!A.paused);pp.setAttribute('aria-label',A.paused?'Play':'Pause')});
  for(const name of ['timeupdate','loadedmetadata','seeked'])A.addEventListener(name,draw);
  pos.addEventListener('input',()=>{drag=true;pos.style.setProperty('--p',pos.value/10+'%');pt.textContent=fmt(pos.value/1000*len())});
  pos.addEventListener('change',()=>{drag=false;if(len())A.currentTime=pos.value/1000*len()});
  rate.addEventListener('click',()=>{const r=rates[(rates.indexOf(A.playbackRate)+1)%rates.length];A.playbackRate=r;rate.textContent=r+'\\u00d7'});
}
const copy=$('copy');
if(copy)copy.addEventListener('click',async()=>{
  const text=$('md').value;
  try{await navigator.clipboard.writeText(text)}catch(_){const t=document.createElement('textarea');t.value=text;t.className='off';document.body.appendChild(t);t.select();document.execCommand('copy');t.remove()}
  copy.textContent='Copied';copy.classList.add('done');setTimeout(()=>{copy.textContent='Copy for your AI';copy.classList.remove('done')},2200);
});
const form=$('ask');
if(form){
  const box=$('chat'),q=$('q'),send=$('send'),turns=[];
  const add=(cls,text)=>{const p=document.createElement('p');p.className=cls;p.textContent=text;box.appendChild(p);return p};
  const answer=(p,text)=>{p.textContent='';p.className='a';
    for(const part of text.split(/(\\[\\d\\d:\\d\\d:\\d\\d\\])/)){const m=/^\\[(\\d\\d):(\\d\\d):(\\d\\d)\\]$/.exec(part);
      if(m&&L.length){const b=document.createElement('button');b.type='button';b.className='t';b.dataset.go=+m[1]*3600+ +m[2]*60+ +m[3];b.textContent=fmt(+b.dataset.go);p.appendChild(b)}else p.appendChild(document.createTextNode(part))}};
  q.addEventListener('keydown',ev=>{if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();form.requestSubmit()}});
  form.addEventListener('submit',async ev=>{
    ev.preventDefault();const text=q.value.trim();if(!text)return;
    add('q',text);q.value='';send.disabled=true;const wait=add('a wait','Reading the meeting\\u2026');
    try{
      const r=await fetch('/${token}/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:text,history:turns})});
      const body=await r.json();
      if(body.answer){answer(wait,body.answer);turns.push({role:'user',content:text},{role:'assistant',content:body.answer})}
      else wait.textContent=body.error||'Something went wrong.';
    }catch(_){wait.textContent='Something went wrong. Try again.'}
    send.disabled=false;q.focus();
  });
}`;
}

/** A page with one message, in the place of a share that cannot be shown. It says nothing about any share. */
function notice(nonce: string, label: string, title: string, text: string): string {
  return page({ title }, nonce, `<main class="doc gate"><p class="label">${label}</p><h1>${title}</h1><p class="lede">${text}</p></main>`);
}

export const notFoundPage = (nonce: string) =>
  notice(nonce, 'Not available', 'This link does not work', 'The link is wrong, it has expired, or its owner stopped sharing it.');

export const unavailablePage = (nonce: string) =>
  notice(nonce, 'Not available', 'This page cannot be shown now', 'Try again in a minute.');

export const lockedPage = (nonce: string) =>
  notice(nonce, 'Private page', 'This page is locked', 'Too many wrong PINs were entered. Ask the person who sent you the link for a new PIN.');

/** The PIN entry. It shows nothing of the share: not its title, its owner, or its date. */
export function pinPage(nonce: string, token: string, message = '', paused = false): string {
  return page({ title: 'Private page', preload: true }, nonce, `<main class="doc gate"><p class="label">Private page</p><h1>Enter the PIN</h1>
<p class="lede">This page is protected. Enter the <b>4-digit PIN</b> that came with the link.</p>
<form class="pinform" id="pf" method="post" action="/${token}/pin" autocomplete="off">
<input id="pin" name="pin" type="text" inputmode="numeric" pattern="[0-9]{4}" maxlength="4" autocomplete="one-time-code" placeholder="&#183;&#183;&#183;&#183;" aria-label="PIN" aria-describedby="msg" required${paused ? '' : ' autofocus'}>
<button class="btn">Open</button></form>
<p class="msg" id="msg" role="alert">${e(message)}</p></main>`,
  `const p=document.getElementById('pin');p.addEventListener('input',()=>{p.value=p.value.replace(/\\D/g,'').slice(0,4);if(p.value.length===4)p.form.requestSubmit()});`);
}

export function homePage(nonce: string): string {
  return notice(nonce, 'Private pages', 'Nothing to see here', 'This site holds private pages. A link from the person who shared a page opens that one page.');
}

export function signInPage(nonce: string, d: { clientName: string; clientDomain?: string; redirectHost: string; redirectIsLoopback: boolean },
  handle: string, error = ''): string {
  const name = e(d.clientName || 'An app');
  return page({ title: `Connect ${d.clientName || 'an app'} to Mossad` }, nonce, `<main class="doc gate">
<p class="label">Mossad</p>
<h1>Connect ${name}</h1>
<p class="lede">${d.clientDomain ? `Published by <b>${e(d.clientDomain)}</b>.` : 'This app registered itself; its name is not verified.'}
Access goes to <b>${e(d.redirectHost)}</b>.</p>
${d.redirectIsLoopback ? '<p class="lede"><b>This sends access to an app on your computer.</b> Continue only if you just started this from it.</p>' : ''}
<p class="lede">${name} will be able to search and read your meetings: titles, summaries, action items, and transcripts. It cannot change anything.</p>
<form method="post">
<input type="hidden" name="handle" value="${e(handle)}">
<label class="field"><span class="label">Your server secret</span>
<input id="secret" name="secret" type="password" autocomplete="current-password" required autofocus></label>
<p class="note">Mossad &gt; Settings &gt; Storage &amp; Sync &gt; Copy secret</p>
${error ? `<p class="msg" role="alert">${e(error)}</p>` : ''}
<div class="row2"><button class="btn" name="decision" value="approve">Allow</button>
<button class="btn ghost" name="decision" value="deny" formnovalidate>Deny</button></div>
</form></main>`);
}

/** The visitor-facing text a share chat answers from: only what the owner shared. */
export function shareContext(s: Share): string {
  const out = [`Meeting: ${s.title}`, `When: ${formatDay(s.start, s.timeZone ?? 'UTC')}`, `People: ${s.people.join(', ')}`];
  if (s.summary) out.push(`Summary:\n${s.summary}`);
  for (const t of s.topics ?? []) out.push(`### ${t.title}\n${t.summary}`);
  if (s.decisions?.length) out.push('Decisions:\n' + s.decisions.map((d, i) => `- ${decisionLine(d, s.decisionTimes?.[i])}`).join('\n'));
  if (s.actionItems?.length) out.push('Action items:\n' + s.actionItems.map((a) => `- ${a.text}`).join('\n'));
  if (s.lines?.length) out.push('Transcript:\n' + s.lines.map((l) => `[${timestamp(l.at)}] ${l.speaker}: ${l.text}`).join('\n').slice(0, 400_000));
  return out.join('\n\n');
}
