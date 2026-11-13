# Your Mossad server

An optional Cloudflare Worker that you run in your own Cloudflare account. It gives Mossad four things:

- **Sync** between your Mac and iPhone without iCloud (iCloud stays the default).
- **Share links** for one meeting: summary, transcript, and recording, with an optional PIN, and a count of who opened the link.
- **A remote MCP server**, so ChatGPT, Claude, and other web AI apps can search and read your meetings after you sign in.
- **A backup of your recordings**, if you turn it on: each meeting's recording goes into the server's own bucket, and your Mac can then free its local copy.

Nobody else can use your server. Every call needs your secret, and only your devices have it. A share link opens only that one meeting.

## What it costs

Cloudflare's free plan covers one person's use: Workers, D1, R2 (10 GB free), and KV. With the recording backup on, a recording takes about 14 MB an hour, so the free 10 GB hold about 700 hours. The server calls no paid service. (Share links that were made with the AI chat, before Mossad 2.17, are the one exception: see "The chat of older links" below.)

## Set it up

You need a Cloudflare account with a domain on it, and Node.js.

1. Sign in to Cloudflare and make the storage:

   ```sh
   cd server
   npm install
   npx wrangler login
   npx wrangler d1 create mossad
   npx wrangler r2 bucket create mossad-files
   npx wrangler kv namespace create OAUTH_KV
   ```

2. Copy `wrangler.example.jsonc` to `wrangler.jsonc`. Put in the database ID and the KV ID from step 1, and your two host names:
   - `SHARE_HOST`: where share links live, such as `notes.example.com`.
   - `MCP_HOST` and `MCP_PATH`: where AI apps connect, such as `mcp.example.com` and `/mossad`. The Worker takes only that path, so other services can use the rest of the host.

   For the MCP host, add a proxied DNS record in Cloudflare (an `AAAA` record to `100::` is enough), and the three routes in the example file.

3. Make the tables. The files in `migrations/` run in order, and Wrangler remembers in the database which ones ran, so the same command is also the update step later:

   ```sh
   npx wrangler d1 migrations apply mossad --remote
   ```

4. Set the secret. Mossad > Settings > Storage & Sync makes the owner secret for you and copies this command:

   ```sh
   npx wrangler secret put OWNER_SECRET
   ```

5. Deploy:

   ```sh
   npx wrangler deploy
   ```

6. In Mossad > Settings > Storage & Sync, choose **Your server**, and enter the address (`https://notes.example.com`) and the secret. Mossad checks each step.

## Connect ChatGPT or Claude

Add a custom connector with the MCP address, such as `https://mcp.example.com/mossad`. A Mossad sign-in page opens: paste your secret (Settings > Storage & Sync > Copy secret) and click Allow. The AI app can read your meetings, but it cannot change anything.

The tools, all read only:

| Tool | What it reads |
| --- | --- |
| `find_meetings`, `search_transcripts`, `read_meeting`, `action_items` | The meetings and their lines. |
| `people`, `read_person` | The people the Mac sends (names, every written form, addresses, job and team), the meetings with each person by their id, the owner's points for next time with them, their action items, and the owner's promises to them. How to present to a person only when the Mac allows it (Settings > Coach > Share the reads with other AI apps, sent as the `mcpPersonas` config key; a server that never heard it gives none), and never for a person the coach keeps no read on. |
| `next_time_points` | The owner's points for next time, with what happened to each. |
| `commitments` | The owner's tasks. |
| `coach_profile`, `read_coach_review` | The coach's memory and one meeting's review. |
| `past_chats`, `read_chat` | The newest 60 chats. |
| `shares` | The share links with their expiry, PIN state, and views. Never a token or a PIN. |
| `search`, `fetch` | ChatGPT's pair: meetings (a call id, or `meeting:<id>`), people (`person:<id>`), and tasks (`task:<id>`). |

The Mac sends the people, the reads, the points, the tasks, the coach's memory, and the chats to this server with either sync choice: through this server, or iCloud with this server as a copy (Mossad after 2.24; never during a call). Until a kind has arrived, its tool says so ("This server has no tasks from your Mac yet"), and a copy older than the newest meeting by two days gives its date. What the coach learned about a person who keeps no read never leaves the Mac, and the server checks the flag again.

Recurring meetings, the prep page, upcoming meetings, each meeting's numbers, analytics, the coach's cards and goal, bookmarks, screens, the live call, and the app's settings are in `Mossad --mcp` on the Mac only: they are rules over the Mac's history and calendar that this server does not repeat.

## Share links

A share page shows the parts of one meeting that you chose, and it does not name Mossad. It asks no other site for anything: the text face comes from this Worker.

- **PIN.** A share can have a PIN of 4 digits. The page then shows only the PIN entry. After the right PIN, the visitor gets a pass for that one share for 12 hours: a signed cookie that is `HttpOnly`, `Secure`, and `SameSite=Lax`. The database keeps a salted hash of the PIN, under a key that comes from your owner secret, and never the PIN. Five wrong PINs pause that visitor for a minute, and each wrong PIN after that doubles the pause, up to a day. Thirty wrong PINs from all visitors together lock the share until you make a new PIN in Mossad; the share forgets one of them each day, but a lock does not wear off, and Mossad shows when a share was locked. A second count never fades: 100 wrong PINs over the life of one PIN lock it for good, until you make a new one. Mossad shows both counts. If the server cannot read what the PIN check needs, the page is not shown. The PIN travels in the body of a request and never in an address.
- **Views.** The server counts visits and visitors for each share, per day, with the country that Cloudflare names and the kind of device. A visitor is a random cookie that belongs to that one share. The server does not keep addresses. A client that keeps no cookie is a new visitor each time, so after 500 new visitors in a day a share counts the rest as one. Link previews and browser prefetches are not counted, and your own visits are not counted after you open a link from Mossad once in that browser.
- **Copy for your AI.** A button at the foot of the page copies the meeting as Markdown. A share with no PIN also serves that text at its link with `.md`. A share with a PIN does not.
- **Expiry.** After a link expires, the server deletes the copy of the meeting at the next visit or when Mossad next lists your shares. The row with its numbers stays until you stop the share in Mossad.

The calls, all on `SHARE_HOST` and all with `Authorization: Bearer <owner secret>`. `<id>` is the SHA-256 of the link's token, as hex.

| Call | What it does |
| --- | --- |
| `GET /api/shares` | Every share: `id`, `title`, `created`, `expires`, `audio`, `chat`, `views`, `questions`, `viewers`, `earlierViews` (views counted before the views per day), `firstView`, `lastView`, `pin`, `pinSet` (when the PIN was set, in ms), `pinLocked`, `lockedAt`, `wrongPins` (the count that fades), `wrongPinsTotal` (the count over the life of the PIN), `gone`. With `migrate: true` when the database is from before the views. |
| `GET /api/shares/<id>` | `{ share, days: [{ day, views, viewers }], countries: [{ country, viewers }], devices: [{ device, viewers }] }`. Days are in your time zone. |
| `PUT /api/shares/<id>` | Stores the copy of the meeting. Sending it again keeps the PIN and the views. Answers `{ ok, pin }`, where `pin` says whether the share has a PIN now. |
| `PUT /api/shares/<id>/audio` | Stores the recording of a share. |
| `PATCH /api/shares/<id>` | `{ "expires": "<ISO 8601>" }` or `{ "expires": null }` changes the expiry. `410` when the copy was deleted after the expiry. |
| `PUT /api/shares/<id>/pin` | `{ "pin": "4821" }` sets that PIN; `{}` makes a random one. Answers `{ ok, pin, pinSet }`. A new PIN ends every pass and every lock. |
| `DELETE /api/shares/<id>/pin` | Removes the PIN. |
| `DELETE /api/shares/<id>` | Stops the share: the copy, the recording, and the numbers go. |

`GET /api/hello` answers `shares: 2` on a server that has these calls.

## Privacy

- Share pages send `noindex` and `no-store`, block framing, and have a `robots.txt` that blocks every crawler. No page lists shares.
- The server stores each share under a hash of its link, so the storage does not hold working links.
- People who open a link can still copy what they see. Share only what you would send by email.
- A share page sets one cookie to count visitors (and a second one after a right PIN). Both belong to that one share and are not readable by scripts. There is no other tracking and no outside service.
- With server sync, your meetings (notes and transcripts, not the audio) are in your D1 database and R2 bucket. Phone recordings pass through R2 until the Mac imports them.
- With the recording backup on, each meeting's recording is in your R2 bucket under `recordings/`. Only your secret, or a link that your Mac signs with it for a few hours, can read one. Deleting a meeting in Mossad deletes its recording here.

## Recording backup

In Mossad > Settings > Storage & Sync > Recording backup, choose **Your server**. Mossad uploads each recording after the note is written, and sends its SHA-256 so R2 refuses a damaged upload.

One recording can be up to 95 MB (about seven hours), which is under Cloudflare's 100 MB request limit on the Free and Pro plans. A longer one stays on your Mac. On a plan with a larger limit, set `RECORDING_MAX_MB` in `vars`.

The calls, all on `SHARE_HOST` and all with `Authorization: Bearer <owner secret>`:

| Call | What it does |
| --- | --- |
| `PUT /api/recordings/<call id>` | Stores the body as `recordings/<call id>/recording.m4a`. Needs `Content-Length`. With `X-Recording-SHA256: <hex>`, R2 checks the bytes. Answers `{ ok, size, sha256 }`; `411` without a length, `413` over the limit (with `maxBytes`), `422` when the bytes do not match the hash. |
| `HEAD /api/recordings/<call id>` | `200` with `X-Recording-Size` and `X-Recording-SHA256`, or `404`. |
| `GET /api/recordings/<call id>` | The recording, with `Range` support. Also answers without the header for `?expires=<unix seconds>&signature=<hex>`, where the signature is HMAC-SHA256 of `mossad-recording\n<call id>\n<expires>` with the owner secret, and `expires` is at most 24 hours ahead. |
| `DELETE /api/recordings/<call id>` | Removes it. Also `200` when it was not there. |

`GET /api/hello` answers `recordings: { maxBytes }` on a server that has these calls, and `recordings.id` to the owner. Mossad offers the backup only then.

The id is made at the owner's first call and kept in the bucket as `server-id`. Mossad saves it with each recording that it sends. A recording on a server with another id (another bucket) does not count as backed up: Mossad keeps the local copy and sends it to the connected server. Do not delete `server-id`.

A link with a wrong signature is counted apart from wrong secrets (20 an hour for one address), so an old link in a player cannot pause your own sync.

## Update your server

After you update Mossad, update the Worker too. It keeps your data and your secrets. Mossad tells you when this is due: the Shares page and Settings > Storage & Sync show "Update your server" when the server is older than the app.

```sh
git pull
cd server
npm install
npx wrangler d1 migrations apply mossad --remote
npx wrangler deploy
```

Run the two `wrangler` steps in this order. Every migration only adds tables and columns, so the Worker that runs now is not disturbed by the new database, and the new Worker finds what it needs when it starts.

- **A server from before Mossad 2.17** made its tables with `schema.sql`. It takes the same command: the first migration is that file, word for word, and it changes nothing that is already there. The second one adds the columns and tables for PINs and views. A new install and an old one end with the same tables.
- **If you deploy first**, nothing breaks: share links open as before and views count the old way. Mossad then shows "Finish the update of your server" until you run the migration step.
- **Your `wrangler.jsonc`** needs no change for this update: no binding, variable, or secret is new. Wrangler finds `migrations/` next to the file. (`wrangler.example.jsonc` now names it with `migrations_dir`, which you can copy.)
- Wrangler lists the migrations that are due and asks before it applies them.
- **A new `OWNER_SECRET`** makes every PIN and every pass invalid, because their keys come from it. Mossad still shows the old PINs, and visitors who enter them use up their tries. After you change the secret, make a new PIN for each share that has one.
- **Do not go back to an older Worker** after the migration. An older Worker does not know `pin_hash`, so it opens every share that has a PIN to anyone who has the link.

### The chat of older links

Mossad 2.16 and earlier could put an AI chat on a share page. New links have no chat: the page has a "Copy for your AI" button, which costs nothing. A link that was made with the chat keeps it as long as the Worker has `ANTHROPIC_API_KEY` (`npx wrangler secret put ANTHROPIC_API_KEY`, a separate key with a spending limit). Without the secret, the chat on such a link says that it is not set up. Each link allows 60 questions a day.

## Develop

```sh
npm test                 # the tool rules, the pages, and the shares (PIN, views, Markdown) on SQLite in memory
npx tsc --noEmit
npx wrangler d1 migrations apply mossad-dev --local --config test/wrangler.dev.jsonc
npx wrangler dev --config test/wrangler.dev.jsonc
node test/e2e.mjs        # in another terminal: sync, shares, OAuth, and the MCP
```
