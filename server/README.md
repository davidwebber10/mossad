# Your Mossad server

An optional Cloudflare Worker that you run in your own Cloudflare account. It gives Mossad four things:

- **Sync** between your Mac and iPhone without iCloud (iCloud stays the default).
- **Share links** for one meeting: summary, transcript, recording, and an optional AI chat about it.
- **A remote MCP server**, so ChatGPT, Claude, and other web AI apps can search and read your meetings after you sign in.
- **A backup of your recordings**, if you turn it on: each meeting's recording goes into the server's own bucket, and your Mac can then free its local copy.

Nobody else can use your server. Every call needs your secret, and only your devices have it. A share link opens only that one meeting.

## What it costs

Cloudflare's free plan covers one person's use: Workers, D1, R2 (10 GB free), and KV. With the recording backup on, a recording takes about 14 MB an hour, so the free 10 GB hold about 700 hours. The AI chat on share pages uses your Anthropic key, so you pay for those questions. Each link allows 60 questions a day.

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

3. Make the tables:

   ```sh
   npx wrangler d1 execute mossad --remote --file schema.sql
   ```

4. Set the secrets. Mossad > Settings > Storage & Sync makes the owner secret for you and copies this command:

   ```sh
   npx wrangler secret put OWNER_SECRET
   npx wrangler secret put ANTHROPIC_API_KEY   # optional: only for the chat on share pages
   ```

   Use a separate Anthropic key with a spending limit for the share chat.

5. Deploy:

   ```sh
   npx wrangler deploy
   ```

6. In Mossad > Settings > Storage & Sync, choose **Your server**, and enter the address (`https://notes.example.com`) and the secret. Mossad checks each step.

## Connect ChatGPT or Claude

Add a custom connector with the MCP address, such as `https://mcp.example.com/mossad`. A Mossad sign-in page opens: paste your secret (Settings > Storage & Sync > Copy secret) and click Allow. The AI app can read your meetings, but it cannot change anything.

## Privacy

- Share pages send `noindex` and `no-store`, block framing, and have a `robots.txt` that blocks every crawler. No page lists shares.
- The server stores each share under a hash of its link, so the storage does not hold working links.
- People who open a link can still copy what they see. Share only what you would send by email.
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

After you update Mossad, update the Worker too. It keeps your data and your secrets:

```sh
git pull
cd server
npm install
npx wrangler deploy
```

## Develop

```sh
npm test                 # the tool rules and the page parts
npx tsc --noEmit
npx wrangler d1 execute mossad-dev --local --config test/wrangler.dev.jsonc --file schema.sql
npx wrangler dev --config test/wrangler.dev.jsonc
node test/e2e.mjs        # in another terminal: sync, shares, OAuth, and the MCP
```
