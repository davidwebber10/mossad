# Your own server: sync, share links, and a remote MCP

## Why

Mossad is open source. The owner wants three things that need a server on the internet:

1. Public share links for one meeting (summary, transcript, recording, and an optional AI chat), at an address like `notes.dispatchd.app/<code>`.
2. An MCP server that ChatGPT and other web AI apps can connect to, with a login, at `mcp.dispatchd.app`.
3. A sync choice: iCloud (as today), the owner's own server, or off. Then the iPhone app works without iCloud, and the Mac can use the server as its sync store.

Nobody runs a shared server for all users. Each user deploys their own copy of one Cloudflare Worker from `server/` in this repo ("bring your own server"). The app works with no server at all: iCloud stays the default, and share links and the remote MCP stay hidden until a server is set up.

## Non-goals

- A hosted service for other people.
- The coach on share pages or in the remote MCP. The coach's reviews and memory stay private to the owner's devices. (They do sync through the server when the owner picks server sync, because that is the owner's own store.)
- Writing through the MCP. It is read-only, like `Mossad --mcp`.

## One Worker, two host names

The Worker answers on two host names that the owner picks, set as variables in `wrangler.jsonc`:

- `SHARE_HOST` (`notes.dispatchd.app`): `/` is a short page about Mossad with a link to the repo; `/<token>` is a share page; `/api/...` is the owner API.
- `MCP_HOST` (`mcp.dispatchd.app`): `/mcp` is the MCP endpoint behind OAuth 2.1; `/authorize` is the sign-in page.

Storage: D1 (records, the meeting index for the MCP, and shares), R2 (record assets, share copies, share audio), and KV (OAuth grants, rate counters).

## The owner secret

One random secret (`OWNER_SECRET`, a Worker secret) proves the owner. The app keeps it in the Keychain and sends it as `Authorization: Bearer` on every `/api` call. The MCP sign-in page asks for it once per AI app; after that the AI app holds an OAuth token. Comparisons are constant time. A wrong secret on the sign-in page counts against a per-IP limit.

## Sync through the server

The sync code keeps one shape for both stores. A record has a name, a type (`Meeting`, `Chat`, `CoachNotes`, `CoachProfile`, `Commitments`, `Recording`), small fields, and assets (blobs). The store gives:

- save records, delete records by name,
- the changes since a token (records changed and records deleted, each with its type), with a new token and a "more" flag.

CloudKit is one store. The server is the other:

- `PUT /api/assets/<name>/<key>` (raw bytes) for each asset, then `PUT /api/records/<name>` with `{type, fields, assets}` commits the record and gives it the next sequence number.
- `DELETE /api/records/<name>` leaves a tombstone with the next sequence number.
- `GET /api/changes?since=<seq>` returns up to 100 changes in order, and `more`.
- `GET /api/assets/<name>/<key>` returns an asset.

The token for the server is the last sequence number. Each store has its own sync state file, so a switch between stores starts clean.

A `Meeting` record that goes to the server has one more asset, `view`: the meeting as the MCP reads it (title, times, people, tags, summary, topics, decisions, action items, and the transcript lines with display names). The Swift side builds it with the same code as the notes, so the Worker does not copy the naming rules. When the Worker commits a `Meeting` record, it writes the view into the D1 meeting index and transcript lines.

The iPhone reads the server address and secret from iCloud Keychain when the Mac shares them (like the AI key today), or the owner pastes them in the phone's settings.

## Share links

- The app makes a 32-byte random token. The link is `https://<SHARE_HOST>/<token>` (base64url). The server stores the share under the SHA-256 of the token, so stored data and the API never show working links.
- `PUT /api/shares/<id>` stores `{title, start, end, people, summary?, topics?, decisions?, actionItems?, lines?, audio, chat, expires}`. Only the parts the owner turned on are in the copy. `PUT /api/shares/<id>/audio` stores the recording. `DELETE /api/shares/<id>` removes the copy and the audio at once. `GET /api/shares` lists the owner's shares with views.
- Expiry: 30 days by default; 7 days, 90 days, or never in the Share sheet. An expired link answers 404 and the copy is deleted.
- Every share response has `X-Robots-Tag: noindex, nofollow, noarchive`, `Referrer-Policy: no-referrer`, `Cache-Control: private, no-store`, and a strict CSP. `robots.txt` disallows everything. No page lists shares. Unknown and expired tokens give the same 404.
- The chat on a share page (when on) sends the question and the earlier turns to `POST /<token>/chat`. The Worker calls Anthropic with the Worker's own `ANTHROPIC_API_KEY` and a system prompt with only the shared parts. Limits: 60 questions per link per day, 10 per visitor per minute, 2,000 characters per question.
- The app keeps its shares (token, call ID, options, expiry) in `~/Mossad/Shares/shares.json` so it can update or stop them, and shows them in Settings.

## The remote MCP

- OAuth 2.1 by `@cloudflare/workers-oauth-provider` with dynamic client registration, which ChatGPT and Claude use.
- Tools: `find_meetings`, `search_transcripts`, `read_meeting`, `action_items` with the same inputs and the same text output shape as the local MCP, plus `search` and `fetch` in the shape ChatGPT expects.
- Stateless Streamable HTTP: each POST gets one JSON reply.

## Settings (the owner asked for this to be excellent, not a list of fields)

Mac: a new Settings page, "Sync & Server".
- At the top, two large choice cards side by side: **iCloud** ("Your Apple devices. Nothing to set up.") and **Your server** ("Your Cloudflare. Share links and ChatGPT."). Each shows a state line ("Syncing", "Last sync 2 min ago", "Not set up"). A small "Don't sync" link under them turns sync off.
- Picking Your server for the first time opens a setup sheet with numbered steps, each with a live check mark:
  1. Deploy the server: a button opens the README's deploy steps; a copy button copies the commands.
  2. The address: one field; the app checks it at once (`GET /api/hello`) and shows "Found your Mossad server".
  3. The secret: the app makes one and copies the `wrangler secret put` command; or the owner pastes an existing one. The app checks it (an authorized `GET /api/hello`).
  4. Move your data: the first upload, with a progress bar.
  The sheet ends on a summary with the share and MCP addresses.
- Once set up, the page shows: the connection (address, a green state line, Check now, Disconnect), "Connect your iPhone" (a QR code), Share links (a list with copy and stop), and ChatGPT and other AI apps (the MCP address with a copy button and a two-line how-to).

iPhone: Settings (a gear on the Meetings screen) has the same two choice cards. Your server opens a sheet: "Scan the code in Mossad on your Mac" with the camera, or "Enter it by hand". After a scan, it checks the server and shows a check mark, then pulls.

## The builder decides

Page styling, the exact sign-in page copy, and how the share chat streams.
