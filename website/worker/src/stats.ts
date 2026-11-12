// The owner's dashboard. Server-rendered HTML in the site's style; every chart is one series, drawn as inline SVG.

type Row = Record<string, string | number | null>;

export interface Stats {
  today: string;
  activeDay: number;
  activeWeek: number;
  activeMonth: number;
  activeByDay: { day: string; n: number }[];
  newByDay: { day: string; n: number }[];
  newWeek: number;
  newMonth: number;
  versions: { key: string; n: number }[];
  oses: { key: string; n: number }[];
  chips: { key: string; n: number }[];
  countries: { key: string; n: number }[];
  transcription: { key: string; n: number }[];
  summary: { key: string; n: number }[];
  features: { key: string; n: number }[];
  latestTotal: number;
  meetingsMedian: number | null;
  meetingsBuckets: { key: string; n: number }[];
  platforms: { key: string; n: number }[];
  errors: { key: string; n: number }[];
  viewsByDay: { day: string; n: number }[];
  viewsTotal: number;
  botViews: number;
  referrers: { key: string; n: number }[];
  viewCountries: { key: string; n: number }[];
  devices: { key: string; n: number }[];
  clicksByDay: { day: string; n: number }[];
  clicksTotal: number;
  clickTargets: { key: string; n: number }[];
}

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function series(rows: Row[], from: string, to: string): { day: string; n: number }[] {
  const byDay = new Map(rows.map((r) => [String(r.day), Number(r.n)]));
  const out = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push({ day: d, n: byDay.get(d) ?? 0 });
  return out;
}

const pairs = (rows: Row[]) => rows.map((r) => ({ key: String(r.key ?? ''), n: Number(r.n) }));

/** The latest report of each install in the last 30 days, as a SQL subquery. */
const LATEST = `(SELECT t.* FROM telemetry t JOIN (SELECT install_id, MAX(id) AS mid FROM telemetry WHERE received_day >= ? GROUP BY install_id) l ON t.id = l.mid)`;

const MEETING_BUCKETS: [string, number, number][] = [['0', 0, 0], ['1-2', 1, 2], ['3-5', 3, 5], ['6-10', 6, 10], ['11-20', 11, 20], ['21+', 21, Infinity]];

export async function loadStats(db: D1Database, today: string): Promise<Stats> {
  const d30 = addDays(today, -29);
  const d7 = addDays(today, -6);
  const all = async (sql: string, ...binds: (string | number)[]) => (await db.prepare(sql).bind(...binds).all<Row>()).results ?? [];
  const one = async (sql: string, ...binds: (string | number)[]) => Number(Object.values((await db.prepare(sql).bind(...binds).first<Row>()) ?? { n: 0 })[0] ?? 0);

  const activeIn = (from: string) => one(`SELECT COUNT(DISTINCT install_id) AS n FROM telemetry WHERE received_day >= ?`, from);
  const firsts = `(SELECT install_id, MIN(received_day) AS first_day FROM telemetry GROUP BY install_id)`;
  const latest = await all(`SELECT meetings7 FROM ${LATEST}`, d30);
  const meetings = latest.map((r) => Number(r.meetings7)).sort((a, b) => a - b);
  const median = meetings.length === 0 ? null
    : meetings.length % 2 ? meetings[(meetings.length - 1) / 2] : (meetings[meetings.length / 2 - 1] + meetings[meetings.length / 2]) / 2;

  const sums = await db.prepare(`SELECT COUNT(*) AS total,
      SUM(f_coach) AS coach, SUM(f_screens) AS screens, SUM(f_google) AS google, SUM(f_server) AS server,
      SUM(f_iphone) AS iphone, SUM(f_backup) AS backup, SUM(f_mcp) AS mcp, SUM(f_shares) AS shares,
      SUM(p_zoom) AS zoom, SUM(p_meet) AS meet, SUM(p_teams) AS teams, SUM(p_in_person) AS inPerson, SUM(p_gemini_notes) AS geminiNotes,
      SUM(e_transcribe) AS transcribe, SUM(e_identify) AS identify, SUM(e_summarize) AS summarize, SUM(e_write) AS write, SUM(e_detect) AS detect
    FROM ${LATEST}`).bind(d30).first<Row>() ?? {};
  const pick = (keys: string[]) => keys.map((key) => ({ key, n: Number(sums[key] ?? 0) }));

  return {
    today,
    activeDay: await activeIn(today),
    activeWeek: await activeIn(d7),
    activeMonth: await activeIn(d30),
    activeByDay: series(await all(`SELECT received_day AS day, COUNT(DISTINCT install_id) AS n FROM telemetry WHERE received_day >= ? GROUP BY received_day`, d30), d30, today),
    newByDay: series(await all(`SELECT first_day AS day, COUNT(*) AS n FROM ${firsts} WHERE first_day >= ? GROUP BY first_day`, d30), d30, today),
    newWeek: await one(`SELECT COUNT(*) AS n FROM ${firsts} WHERE first_day >= ?`, d7),
    newMonth: await one(`SELECT COUNT(*) AS n FROM ${firsts} WHERE first_day >= ?`, d30),
    versions: pairs(await all(`SELECT app_version AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key DESC LIMIT 12`, d30)),
    oses: pairs(await all(`SELECT os AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key DESC LIMIT 12`, d30)),
    chips: pairs(await all(`SELECT CASE WHEN instr(chip, ' ') > 0 THEN substr(chip, 1, instr(chip, ' ') - 1) ELSE chip END AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key`, d30)),
    countries: pairs(await all(`SELECT country AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key LIMIT 15`, d30)),
    transcription: pairs(await all(`SELECT transcription AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key`, d30)),
    summary: pairs(await all(`SELECT summary AS key, COUNT(*) AS n FROM ${LATEST} GROUP BY key ORDER BY n DESC, key`, d30)),
    features: pick(['coach', 'screens', 'google', 'server', 'iphone', 'backup', 'mcp', 'shares']),
    latestTotal: Number(sums.total ?? 0),
    meetingsMedian: median,
    meetingsBuckets: MEETING_BUCKETS.map(([key, lo, hi]) => ({ key, n: meetings.filter((m) => m >= lo && m <= hi).length })),
    platforms: pick(['zoom', 'meet', 'teams', 'inPerson', 'geminiNotes']),
    errors: pick(['transcribe', 'identify', 'summarize', 'write', 'detect']),
    viewsByDay: series(await all(`SELECT day, SUM(views) AS n FROM page_views WHERE day >= ? AND device != 'bot' GROUP BY day`, d30), d30, today),
    viewsTotal: await one(`SELECT COALESCE(SUM(views), 0) AS n FROM page_views WHERE day >= ? AND device != 'bot'`, d30),
    botViews: await one(`SELECT COALESCE(SUM(views), 0) AS n FROM page_views WHERE day >= ? AND device = 'bot'`, d30),
    referrers: pairs(await all(`SELECT referrer AS key, SUM(views) AS n FROM page_views WHERE day >= ? AND device != 'bot' AND referrer != '' GROUP BY key ORDER BY n DESC, key LIMIT 15`, d30)),
    viewCountries: pairs(await all(`SELECT country AS key, SUM(views) AS n FROM page_views WHERE day >= ? AND device != 'bot' GROUP BY key ORDER BY n DESC, key LIMIT 15`, d30)),
    devices: pairs(await all(`SELECT device AS key, SUM(views) AS n FROM page_views WHERE day >= ? GROUP BY key ORDER BY n DESC, key`, d30)),
    clicksByDay: series(await all(`SELECT day, SUM(clicks) AS n FROM clicks WHERE day >= ? GROUP BY day`, d30), d30, today),
    clicksTotal: await one(`SELECT COALESCE(SUM(clicks), 0) AS n FROM clicks WHERE day >= ?`, d30),
    clickTargets: pairs(await all(`SELECT target AS key, SUM(clicks) AS n FROM clicks WHERE day >= ? GROUP BY key ORDER BY n DESC, key`, d30)),
  };
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const fmt = (n: number) => n.toLocaleString('en-US');

/** A column chart of one value per day: bars from a zero baseline, a native tooltip on each, first and last day labeled. */
export function dayChart(points: { day: string; n: number }[], label: string): string {
  const w = 600, h = 140, top = 10, bottom = 22;
  const max = Math.max(1, ...points.map((p) => p.n));
  const step = w / Math.max(1, points.length);
  const bar = Math.max(2, step - 2);
  const bars = points.map((p, i) => {
    const bh = p.n === 0 ? 0 : Math.max(2, (p.n / max) * (h - top - bottom));
    const x = i * step + 1, y = h - bottom - bh;
    return `<g><rect x="${x.toFixed(1)}" y="${top}" width="${step.toFixed(1)}" height="${h - top - bottom}" fill="transparent"></rect>`
      + (bh ? `<path d="M${x.toFixed(1)} ${(h - bottom).toFixed(1)}V${(y + 2).toFixed(1)}q0 -2 2 -2h${(bar - 4).toFixed(1)}q2 0 2 2V${(h - bottom).toFixed(1)}Z" fill="var(--accent)"></path>` : '')
      + `<title>${esc(p.day)}: ${fmt(p.n)}</title></g>`;
  }).join('');
  const first = points[0]?.day ?? '', last = points[points.length - 1]?.day ?? '';
  return `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${esc(label)}, by day, ${esc(first)} to ${esc(last)}. Highest: ${fmt(max === 1 && points.every((p) => p.n === 0) ? 0 : max)}." class="chart">`
    + `<path d="M0 ${h - bottom + 0.5}H${w}" stroke="var(--line2)" stroke-width="1"></path>`
    + `<text x="0" y="${h - 6}" class="axis">${esc(first.slice(5))}</text><text x="${w}" y="${h - 6}" class="axis" text-anchor="end">${esc(last.slice(5))}</text>`
    + `<text x="${w}" y="${top - 1}" class="axis" text-anchor="end">max ${fmt(points.every((p) => p.n === 0) ? 0 : max)}</text>`
    + bars + `</svg>`;
}

/** A ranked list with a bar for each row: the names and the numbers are text, the bar only shows the share. */
export function barList(rows: { key: string; n: number }[], options: { total?: number; empty?: string; percent?: boolean } = {}): string {
  if (rows.length === 0 || rows.every((r) => r.n === 0) && !options.percent) return `<p class="empty">${esc(options.empty ?? 'Nothing yet.')}</p>`;
  const max = options.total ?? Math.max(1, ...rows.map((r) => r.n));
  return `<table class="bars"><tbody>${rows.map((r) => {
    const share = max > 0 ? r.n / max : 0;
    const value = options.percent ? `${Math.round(share * 100)}%` : fmt(r.n);
    return `<tr><th scope="row">${esc(r.key || '(none)')}</th><td class="bar"><span style="width:${(share * 100).toFixed(1)}%"></span></td><td class="num">${value}</td></tr>`;
  }).join('')}</tbody></table>`;
}

export function renderStats(s: Stats, email: string): string {
  const tile = (label: string, value: string, note = '') => `<div class="tile"><p class="label">${esc(label)}</p><p class="big">${esc(value)}</p>${note ? `<p class="note">${esc(note)}</p>` : ''}</div>`;
  const panel = (title: string, body: string, wide = false) => `<section class="panel${wide ? ' wide' : ''}"><h2>${esc(title)}</h2>${body}</section>`;
  const meetingsShare = s.platforms.reduce((a, p) => a + p.n, 0);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#141210">
<title>Mossad stats</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
@font-face{font-family:'Bricolage Grotesque';font-weight:400 800;font-display:swap;src:url(/fonts/bricolage-grotesque-latin.woff2) format('woff2')}
@font-face{font-family:Inter;font-weight:400 600;font-display:swap;src:url(/fonts/inter-latin.woff2) format('woff2')}
@font-face{font-family:'IBM Plex Mono';font-weight:400;font-display:swap;src:url(/fonts/ibm-plex-mono-400-latin.woff2) format('woff2')}
:root{color-scheme:dark;--bg:#141210;--surface:#1B1815;--line:#2E2A25;--line2:#3A342D;--text:#F4EFE7;--text2:#D9D2C7;--muted:#B8B0A4;--faint:#9A9287;--accent:#F2A05A;--d:'Bricolage Grotesque','Helvetica Neue',Arial,sans-serif;--m:'IBM Plex Mono',ui-monospace,Menlo,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1240px;margin:0 auto;padding:28px clamp(16px,4vw,40px) 56px;display:flex;flex-direction:column;gap:28px}
header{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:8px 24px}
h1{margin:0;font:600 clamp(32px,4vw,48px)/1.05 var(--d);letter-spacing:-.03em}
h2{margin:0 0 14px;font:600 20px/1.2 var(--d);letter-spacing:-.01em}
.label{margin:0;font:12px var(--m);letter-spacing:.08em;color:var(--faint);text-transform:uppercase}
.who{margin:0;font:12.5px var(--m);color:var(--faint)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(170px,100%),1fr));gap:12px}
.tile{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:16px}
.big{margin:4px 0 0;font:600 34px/1.1 var(--d);letter-spacing:-.02em}
.note{margin:2px 0 0;font-size:13px;color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(340px,100%),1fr));gap:16px}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:20px;padding:20px;min-width:0}
.panel.wide{grid-column:1/-1}
.chart{display:block;width:100%;height:auto}
.axis{font:11px var(--m);fill:var(--faint)}
.chart g:hover path{fill:#F7BC86}
.bars{width:100%;border-collapse:collapse;font-size:14px}
.bars th{text-align:left;font-weight:500;color:var(--text2);padding:5px 12px 5px 0;white-space:nowrap;width:1%}
.bars td.bar{width:100%;padding:5px 0}
.bars td.bar span{display:block;height:10px;border-radius:0 4px 4px 0;background:var(--accent);min-width:2px}
.bars td.num{font-family:var(--m);font-size:13px;color:var(--text2);text-align:right;padding-left:12px;white-space:nowrap}
.empty{margin:0;color:var(--faint)}
.sub{margin:16px 0 8px}
p.small{margin:10px 0 0;font-size:13px;color:var(--faint)}
</style>
</head>
<body>
<main>
<header><div><p class="label">Owner only · last 30 days, UTC · ${esc(s.today)}</p><h1>Mossad stats</h1></div><p class="who">${esc(email)}</p></header>

<div class="tiles">
${tile('Active today', fmt(s.activeDay))}
${tile('Active this week', fmt(s.activeWeek), 'last 7 days')}
${tile('Active this month', fmt(s.activeMonth), 'last 30 days')}
${tile('New this week', fmt(s.newWeek), `${fmt(s.newMonth)} in 30 days`)}
${tile('Meetings a week', s.meetingsMedian === null ? 'None' : fmt(s.meetingsMedian), 'median for each install')}
${tile('Page views', fmt(s.viewsTotal), `${fmt(s.botViews)} more from bots`)}
${tile('Download clicks', fmt(s.clicksTotal))}
</div>

<div class="grid">
${panel('Active installs by day', dayChart(s.activeByDay, 'Active installs'), true)}
${panel('New installs by day', dayChart(s.newByDay, 'New installs'))}
${panel('Meetings for each install, last 7 days', barList(s.meetingsBuckets, { empty: 'No reports yet.' }) + `<p class="small">From each install's latest report.</p>`)}
${panel('App versions', barList(s.versions, { empty: 'No reports yet.' }))}
${panel('macOS versions', barList(s.oses, { empty: 'No reports yet.' }))}
${panel('Apple silicon', barList(s.chips, { empty: 'No reports yet.' }))}
${panel('Countries of installs', barList(s.countries, { empty: 'No reports yet.' }))}
${panel('Providers', `<p class="label sub">Transcription</p>${barList(s.transcription, { empty: 'No reports yet.' })}<p class="label sub">Notes</p>${barList(s.summary, { empty: 'No reports yet.' })}`)}
${panel('Features turned on', s.latestTotal ? barList(s.features, { total: s.latestTotal, percent: true }) : '<p class="empty">No reports yet.</p>')}
${panel('Meetings by platform, last 7 days', meetingsShare ? barList(s.platforms.map((p) => ({ key: p.key, n: p.n })), { total: meetingsShare, percent: true }) + `<p class="small">${fmt(meetingsShare)} meetings.</p>` : '<p class="empty">No meetings reported yet.</p>')}
${panel('Errors by step, last 7 days', barList(s.errors, { empty: 'No errors reported.' }))}
${panel('Site page views by day', dayChart(s.viewsByDay, 'Page views'), true)}
${panel('Top referrers', barList(s.referrers, { empty: 'No referrers yet.' }))}
${panel('Top countries of visitors', barList(s.viewCountries, { empty: 'No views yet.' }))}
${panel('Devices', barList(s.devices, { empty: 'No views yet.' }))}
${panel('Download clicks by day', dayChart(s.clicksByDay, 'Download clicks'))}
${panel('Download clicks by button', barList(s.clickTargets, { empty: 'No clicks yet.' }))}
</div>
</main>
</body>
</html>`;
}
