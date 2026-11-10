import type { Share } from './types';
import { decisionLine, escapeHtml as e, formatDay, timestamp } from './util';

/** Shared look for every page: system fonts, one accent, light and dark. */
const baseCSS = `
:root{--bg:#fbfaf8;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e7e5e1;--accent:#d2452f;--soft:#f3f1ed}
@media (prefers-color-scheme:dark){:root{--bg:#121212;--card:#1c1c1e;--text:#f2f2f2;--muted:#9a9aa0;--line:#2c2c2e;--accent:#ff6a52;--soft:#232325}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif}
a{color:var(--accent)}
.wrap{max-width:760px;margin:0 auto;padding:40px 20px 120px}
.brand{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px;font-weight:600;letter-spacing:.02em;text-decoration:none}
.dot{width:10px;height:10px;border-radius:50%;background:var(--accent)}
h1{font-size:32px;line-height:1.2;margin:18px 0 6px;letter-spacing:-.01em}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:36px 0 10px}
h3{font-size:17px;margin:18px 0 4px}
.meta{color:var(--muted);font-size:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px}
ul{padding-left:20px;margin:6px 0}li{margin:4px 0}
button,input,textarea{font:inherit;color:inherit}
`;

/** The summary's small Markdown: **bold** and "- " lists, after escaping, so nothing else becomes HTML. */
export function md(text: string): string {
  const out: string[] = [];
  let list: string[] = [];
  const flush = () => { if (list.length) { out.push(`<ul>${list.map((l) => `<li>${l}</li>`).join('')}</ul>`); list = []; } };
  for (const raw of text.split('\n')) {
    const line = e(raw.trim()).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
    if (/^[-*] /.test(raw.trim())) { list.push(line.slice(2)); continue; }
    flush();
    if (line) out.push(`<p>${line}</p>`);
  }
  flush();
  return out.join('');
}

function page(title: string, nonce: string, body: string, script = ''): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
<meta name="referrer" content="no-referrer">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6' fill='%23d2452f'/%3E%3C/svg%3E">
<title>${e(title)}</title><style nonce="${nonce}">${baseCSS}${PAGE_CSS}</style></head>
<body>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ''}</body></html>`;
}

const PAGE_CSS = `
.people{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}
.chip{background:var(--soft);border-radius:999px;padding:3px 10px;font-size:13px}
.lines{display:flex;flex-direction:column;gap:2px}
.ln{display:grid;grid-template-columns:64px 1fr;gap:10px;padding:6px 8px;border-radius:8px;cursor:default}
.ln.seek{cursor:pointer}.ln.seek:hover{background:var(--soft)}
.ln time{color:var(--muted);font:12px/1.9 ui-monospace,SFMono-Regular,Menlo,monospace}
.ln b{font-weight:600}
.find{width:100%;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--card);margin-bottom:10px}
.player{position:fixed;left:0;right:0;bottom:0;background:color-mix(in srgb,var(--card) 88%,transparent);backdrop-filter:blur(14px);border-top:1px solid var(--line);padding:10px 16px}
.player audio{width:100%;max-width:760px;display:block;margin:0 auto}
.chat{display:flex;flex-direction:column;gap:12px}
.msg{white-space:pre-wrap;padding:10px 14px;border-radius:14px;max-width:90%}
.msg.q{align-self:flex-end;background:var(--accent);color:#fff}
.msg.a{align-self:flex-start;background:var(--soft)}
.ask{display:flex;gap:8px;margin-top:12px}
.ask textarea{flex:1;resize:none;border:1px solid var(--line);background:var(--card);border-radius:12px;padding:10px 12px;min-height:44px}
.ask button{border:0;border-radius:12px;background:var(--accent);color:#fff;padding:0 18px;font-weight:600;cursor:pointer}
.ask button:disabled{opacity:.5;cursor:default}
.foot{margin-top:48px;color:var(--muted);font-size:12px;text-align:center}
.hide{display:none}
.narrow{max-width:460px}.mt0{margin-top:0}.err{color:var(--accent);margin:0}
.ask button.ghost{background:var(--soft);color:var(--text)}
`;

export function sharePage(s: Share, token: string, nonce: string, repo: string): string {
  const tz = s.timeZone ?? 'UTC';
  const minutes = Math.round((Date.parse(s.end) - Date.parse(s.start)) / 60_000);
  const parts: string[] = [];
  parts.push(`<a class="brand" href="${e(repo)}" rel="noreferrer"><span class="dot"></span>Mossad</a>
<h1>${e(s.title)}</h1>
<div class="meta">${e(formatDay(s.start, tz))} · ${minutes} min · Shared by ${e(s.owner)}</div>
${s.people.length ? `<div class="people">${s.people.map((p) => `<span class="chip">${e(p)}</span>`).join('')}</div>` : ''}`);
  if (s.summary || s.topics?.length) {
    parts.push(`<h2>Summary</h2><div class="card">${s.summary ? md(s.summary) : ''}${(s.topics ?? [])
      .map((t) => `<h3>${e(t.title)}</h3>${md(t.summary)}`).join('')}</div>`);
  }
  if (s.actionItems?.length) parts.push(`<h2>Action items</h2><div class="card"><ul>${s.actionItems.map((a) => `<li>${e(a.text)}</li>`).join('')}</ul></div>`);
  if (s.decisions?.length) parts.push(`<h2>Decisions</h2><div class="card"><ul>${s.decisions.map((d, i) => `<li>${e(decisionLine(d, s.decisionTimes?.[i]))}</li>`).join('')}</ul></div>`);
  if (s.chat) {
    parts.push(`<h2>Ask about this meeting</h2><div class="card"><div class="chat" id="chat"></div>
<form class="ask" id="ask"><textarea id="q" rows="1" maxlength="2000" placeholder="What was decided?" aria-label="Your question"></textarea><button id="send">Ask</button></form></div>`);
  }
  if (s.lines?.length) {
    parts.push(`<h2>Transcript</h2><div class="card"><input class="find" id="find" type="search" placeholder="Find in transcript" aria-label="Find in transcript">
<div class="lines" id="lines">${s.lines.map((l) => `<div class="ln${s.audio ? ' seek' : ''}" data-t="${l.at}"><time>${timestamp(l.at)}</time><div><b>${e(l.speaker)}</b> ${e(l.text)}</div></div>`).join('')}</div></div>`);
  }
  parts.push(`<div class="foot">This page is private to people with the link. ${s.expires ? `The link stops working on ${e(formatDay(s.expires, tz).replace(/, \d+:\d+ [AP]M$/, ''))}.` : ''}</div>`);
  const player = s.audio ? `<div class="player"><audio id="audio" controls preload="metadata" src="/${token}/audio"></audio></div>` : '';
  return page(s.title, nonce, `<main class="wrap">${parts.join('\n')}</main>${player}`, shareScript(token));
}

function shareScript(token: string): string {
  return `
const $=id=>document.getElementById(id);
const audio=$('audio');
document.querySelectorAll('.ln.seek').forEach(el=>el.addEventListener('click',()=>{audio.currentTime=+el.dataset.t;audio.play()}));
const find=$('find');
if(find)find.addEventListener('input',()=>{const q=find.value.toLowerCase();document.querySelectorAll('.ln').forEach(el=>el.classList.toggle('hide',!!q&&!el.textContent.toLowerCase().includes(q)))});
const form=$('ask');
if(form){
  const box=$('chat'),q=$('q'),send=$('send'),turns=[];
  const add=(cls,text)=>{const d=document.createElement('div');d.className='msg '+cls;d.textContent=text;box.appendChild(d);return d};
  q.addEventListener('keydown',ev=>{if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();form.requestSubmit()}});
  form.addEventListener('submit',async ev=>{
    ev.preventDefault();const text=q.value.trim();if(!text)return;
    add('q',text);q.value='';send.disabled=true;const wait=add('a','Thinking…');
    try{
      const r=await fetch('/${token}/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:text,history:turns})});
      const body=await r.json();
      wait.textContent=body.answer||body.error||'Something went wrong.';
      if(body.answer)turns.push({role:'user',content:text},{role:'assistant',content:body.answer});
    }catch(_){wait.textContent='Something went wrong. Try again.'}
    send.disabled=false;q.focus();
  });
}`;
}

export function notFoundPage(nonce: string): string {
  return page('Not found', nonce, `<main class="wrap"><span class="brand"><span class="dot"></span>Mossad</span><h1>This link does not work</h1>
<p class="meta">The link is wrong, it has expired, or its owner stopped sharing it.</p></main>`);
}

export function homePage(nonce: string, repo: string): string {
  return page('Mossad', nonce, `<main class="wrap"><span class="brand"><span class="dot"></span>Mossad</span>
<h1>Meeting notes that write themselves.</h1>
<p>Mossad is an open-source Mac app. It records your Zoom, Meet, and Teams calls, writes the transcript and summary, and coaches you on how you communicate. Your notes stay on your own devices.</p>
<p>Links on this site open one meeting that its owner chose to share.</p>
<p><a href="${e(repo)}" rel="noreferrer">Mossad on GitHub</a></p></main>`);
}

export function signInPage(nonce: string, d: { clientName: string; clientDomain?: string; redirectHost: string; redirectIsLoopback: boolean },
  handle: string, error = ''): string {
  const name = e(d.clientName || 'An app');
  return page(`Connect ${d.clientName || 'an app'} to Mossad`, nonce, `<main class="wrap narrow">
<span class="brand"><span class="dot"></span>Mossad</span>
<h1>Connect ${name}</h1>
<p class="meta">${d.clientDomain ? `Published by <b>${e(d.clientDomain)}</b>.` : 'This app registered itself; its name is not verified.'}
Access goes to <b>${e(d.redirectHost)}</b>.</p>
${d.redirectIsLoopback ? '<p><b>This sends access to an app on your computer.</b> Continue only if you just started this from it.</p>' : ''}
<div class="card"><p class="mt0">${name} will be able to search and read your meetings: titles, summaries, action items, and transcripts. It cannot change anything.</p>
<form method="post" class="chat">
<input type="hidden" name="handle" value="${e(handle)}">
<label for="secret" class="meta">Your server secret (Mossad &gt; Settings &gt; Storage &amp; Sync &gt; Copy secret)</label>
<input id="secret" class="find" name="secret" type="password" autocomplete="current-password" required autofocus>
${error ? `<p class="err">${e(error)}</p>` : ''}
<div class="ask"><button name="decision" value="approve">Allow</button>
<button name="decision" value="deny" formnovalidate class="ghost">Deny</button></div>
</form></div></main>`);
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
