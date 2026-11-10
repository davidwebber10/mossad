// End to end against `wrangler dev --config test/wrangler.dev.jsonc` (see README.md): node test/e2e.mjs
import crypto from 'node:crypto';
const share = 'http://localhost:8787', mcp = 'http://127.0.0.1:8787';
const auth = { Authorization: 'Bearer dev-secret' };
const ok = (c, m) => { if (!c) { console.error('FAIL', m); process.exitCode = 1 } else console.log('ok', m) };
const view = { id: 'm1', title: 'Budget review', start: '2026-11-03T15:00:00Z', end: '2026-11-03T15:30:00Z', tags: ['Budget'], people: ['Dana', 'Jennifer Lee'], attendees: [], topics: [{ title: 'Q1', summary: 'Spend is flat.' }], decisions: ['Hold spend'], actionItems: [{ task: 'Send numbers', owner: 'Jennifer Lee', text: 'Jennifer Lee: Send numbers' }], lines: [{ at: 65, speaker: 'Jennifer Lee', text: 'I need the numbers by Friday.' }], timeZone: 'America/Chicago' };
let r = await fetch(`${share}/api/assets/m1/view`, { method: 'PUT', headers: auth, body: JSON.stringify(view) }); ok(r.ok, 'asset put');
r = await fetch(`${share}/api/records/m1`, { method: 'PUT', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify({ type: 'Meeting', fields: { title: 'Budget review' }, assets: ['view'] }) }); ok(r.ok, 'record put ' + r.status);
await fetch(`${share}/api/config`, { method: 'PUT', headers: auth, body: JSON.stringify({ owner: 'Dana', timeZone: 'America/Chicago' }) });
r = await fetch(`${share}/api/changes?since=0`, { headers: auth }); const ch = await r.json(); ok(ch.changes.length >= 1 && ch.token >= 1, 'changes ' + JSON.stringify(ch).slice(0, 120));
r = await fetch(`${share}/api/changes?since=0`); ok(r.status === 401, 'changes need the secret');
// Share
const token = crypto.randomBytes(32).toString('base64url'), id = crypto.createHash('sha256').update(token).digest('hex');
r = await fetch(`${share}/api/shares/${id}`, { method: 'PUT', headers: auth, body: JSON.stringify({ title: 'Budget review', start: view.start, end: view.end, people: view.people, owner: 'Dana', summary: 'We held spend.', lines: view.lines, audio: false, chat: true, expires: null, timeZone: 'America/Chicago' }) }); ok(r.ok, 'share put');
r = await fetch(`${share}/${token}`); const page = await r.text(); ok(r.ok && page.includes('Budget review') && r.headers.get('x-robots-tag')?.includes('noindex'), 'share page');
ok(r.headers.get('content-security-policy')?.includes("script-src 'nonce-"), 'csp');
r = await fetch(`${share}/${crypto.randomBytes(32).toString('base64url')}`); ok(r.status === 404, 'unknown link 404');
r = await fetch(`${share}/${token}/chat`, { method: 'POST', body: JSON.stringify({ question: 'hi' }) }); ok(r.status === 503, 'chat without key ' + r.status);
r = await fetch(`${share}/api/shares`, { headers: auth }); ok((await r.json()).shares[0].views === 1, 'views counted');
// MCP OAuth
r = await fetch(`${mcp}/mossad`, { method: 'POST', body: '{}' }); ok(r.status === 401, 'mcp needs a token'); const www = r.headers.get('www-authenticate'); console.log(' ', www);
const prmURL = /resource_metadata="([^"]+)"/.exec(www)[1];
const prm = await (await fetch(prmURL)).json(); console.log(' ', JSON.stringify(prm));
const asURL = `${mcp}/.well-known/oauth-authorization-server/mossad`;
r = await fetch(asURL); const as = await r.json(); ok(r.ok, 'as metadata ' + JSON.stringify(as).slice(0, 300));
r = await fetch(as.registration_endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ client_name: 'Test GPT', redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'], token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] }) });
const client = await r.json(); ok(client.client_id, 'registered');
const verifier = crypto.randomBytes(32).toString('base64url'), challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
const authURL = `${as.authorization_endpoint}?response_type=code&client_id=${encodeURIComponent(client.client_id)}&redirect_uri=${encodeURIComponent('https://chatgpt.com/connector_platform_oauth_redirect')}&state=s1&code_challenge=${challenge}&code_challenge_method=S256&scope=mossad:read&resource=${encodeURIComponent(prm.resource)}`;
r = await fetch(authURL); const html = await r.text(); ok(r.ok && html.includes('Connect Test GPT'), 'sign-in page ' + r.status);
const cookie = r.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
const handle = /name="handle" value="([^"]+)"/.exec(html)[1];
r = await fetch(authURL, { method: 'POST', headers: { cookie, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ handle, secret: 'wrong', decision: 'approve' }), redirect: 'manual' }); ok(r.status === 401, 'wrong secret refused');
r = await fetch(authURL, { method: 'POST', headers: { cookie, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ handle, secret: 'dev-secret', decision: 'approve' }), redirect: 'manual' }); ok(r.status === 302, 'approved ' + r.status);
const code = new URL(r.headers.get('location')).searchParams.get('code');
r = await fetch(as.token_endpoint, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: 'https://chatgpt.com/connector_platform_oauth_redirect', client_id: client.client_id, code_verifier: verifier, resource: prm.resource }) });
const tok = await r.json(); ok(tok.access_token, 'token ' + JSON.stringify(tok).slice(0, 80));
const call = async (method, params) => (await (await fetch(`${mcp}/mossad`, { method: 'POST', headers: { Authorization: `Bearer ${tok.access_token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) })).json());
ok((await call('initialize', { protocolVersion: '2025-06-18' })).result.instructions.includes('Dana'), 'initialize');
ok((await call('tools/list', {})).result.tools.length === 6, 'tools/list');
const found = await call('tools/call', { name: 'find_meetings', arguments: { people: ['Jen'] } }); ok(found.result.content[0].text.includes('call_id: m1'), 'find_meetings ' + found.result.content[0].text);
const read = await call('tools/call', { name: 'read_meeting', arguments: { call_id: 'm1' } }); ok(read.result.content[0].text.includes('[00:01:05] Jennifer Lee'), 'read_meeting');
const s = await call('tools/call', { name: 'search', arguments: { query: 'friday' } }); ok(s.result.structuredContent.results[0].id === 'm1', 'search');
// Recording backup
const rec = crypto.randomBytes(300_000), recHash = crypto.createHash('sha256').update(rec).digest('hex');
r = await fetch(`${share}/api/hello`); const open = await r.json(); ok(open.recordings?.maxBytes > 0 && !open.recordings.id, 'hello names the recording limit, and no id without the secret');
const id1 = (await (await fetch(`${share}/api/hello`, { headers: auth })).json()).recordings.id, id2 = (await (await fetch(`${share}/api/hello`, { headers: auth })).json()).recordings.id;
ok(/^[0-9a-f-]{36}$/.test(id1) && id1 === id2, 'the server id is the same each time');
r = await fetch(`${share}/api/recordings/m1`, { method: 'PUT', headers: { ...auth, 'Content-Type': 'audio/mp4', 'X-Recording-SHA256': recHash }, body: rec }); const put = await r.json(); ok(r.ok && put.size === rec.length && put.sha256 === recHash, 'recording put ' + r.status);
r = await fetch(`${share}/api/recordings/m1`, { method: 'PUT', headers: { ...auth, 'X-Recording-SHA256': 'a'.repeat(64) }, body: rec.subarray(0, 100) }); ok(r.status === 422, 'recording with a wrong hash refused ' + r.status);
r = await fetch(`${share}/api/recordings/m1`, { method: 'HEAD', headers: auth }); ok(r.ok && r.headers.get('x-recording-size') === String(rec.length) && r.headers.get('x-recording-sha256') === recHash, 'recording head, still the first upload');
r = await fetch(`${share}/api/recordings/m1`, { headers: { ...auth, Range: 'bytes=1000-1999' } }); const slice = Buffer.from(await r.arrayBuffer()); ok(r.status === 206 && slice.equals(rec.subarray(1000, 2000)) && r.headers.get('content-range') === `bytes 1000-1999/${rec.length}`, 'recording range');
r = await fetch(`${share}/api/recordings/m1`); ok(r.status === 401, 'recording needs the secret');
const expires = Math.floor(Date.now() / 1000) + 600, sig = crypto.createHmac('sha256', 'dev-secret').update(`mossad-recording\nm1\n${expires}`).digest('hex');
r = await fetch(`${share}/api/recordings/m1?expires=${expires}&signature=${sig}`); ok(r.ok && Buffer.from(await r.arrayBuffer()).equals(rec), 'signed link plays');
r = await fetch(`${share}/api/recordings/m2?expires=${expires}&signature=${sig}`); ok(r.status === 401, 'signed link is for one recording');
r = await fetch(`${share}/api/recordings/m1`, { method: 'DELETE', headers: auth }); r = await fetch(`${share}/api/recordings/m1`, { method: 'HEAD', headers: auth }); ok(r.status === 404, 'recording deleted');
// Share audio keeps its own copy
r = await fetch(`${share}/api/shares/${id}`, { method: 'PUT', headers: auth, body: JSON.stringify({ title: 'Budget review', start: view.start, end: view.end, people: view.people, owner: 'Dana', audio: true, chat: false, expires: null }) });
r = await fetch(`${share}/api/shares/${id}/audio`, { method: 'PUT', headers: auth, body: rec }); ok(r.ok, 'share audio put');
r = await fetch(`${share}/${token}/audio`, { headers: { Range: 'bytes=0-99' } }); ok(r.status === 206 && Buffer.from(await r.arrayBuffer()).equals(rec.subarray(0, 100)), 'share audio range');
// Delete
r = await fetch(`${share}/api/shares/${id}`, { method: 'DELETE', headers: auth }); r = await fetch(`${share}/${token}`); ok(r.status === 404, 'stopped share 404');
r = await fetch(`${share}/api/records/m1`, { method: 'DELETE', headers: auth }); const ch2 = await (await fetch(`${share}/api/changes?since=${ch.token}`, { headers: auth })).json(); ok(ch2.changes[0]?.deleted, 'tombstone');
ok(!(await call('tools/call', { name: 'find_meetings', arguments: {} })).result.content[0].text.includes('m1'), 'deleted from mcp');
