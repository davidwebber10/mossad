# Your Mossad server

An optional Cloudflare Worker that you run in your own Cloudflare account. It gives Mossad three things:

- **Sync** between your Mac and iPhone without iCloud (iCloud stays the default).
- **Share links** for one meeting: summary, transcript, recording, and an optional AI chat about it.
- **A remote MCP server**, so ChatGPT, Claude, and other web AI apps can search and read your meetings after you sign in.

Nobody else can use your server. Every call needs your secret, and only your devices have it. A share link opens only that one meeting.

## What it costs

Cloudflare's free plan covers one person's use: Workers, D1, R2 (10 GB free), and KV. The AI chat on share pages uses your Anthropic key, so you pay for those questions. Each link allows 60 questions a day.

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

4. Set the secrets. Mossad > Settings > Sync & Server makes the owner secret for you and copies this command:

   ```sh
   npx wrangler secret put OWNER_SECRET
   npx wrangler secret put ANTHROPIC_API_KEY   # optional: only for the chat on share pages
   ```

   Use a separate Anthropic key with a spending limit for the share chat.

5. Deploy:

   ```sh
   npx wrangler deploy
   ```

6. In Mossad > Settings > Sync & Server, choose **Your server**, and enter the address (`https://notes.example.com`) and the secret. Mossad checks each step.

## Connect ChatGPT or Claude

Add a custom connector with the MCP address, such as `https://mcp.example.com/mossad`. A Mossad sign-in page opens: paste your secret (Settings > Sync & Server > Copy secret) and click Allow. The AI app can read your meetings, but it cannot change anything.

## Privacy

- Share pages send `noindex` and `no-store`, block framing, and have a `robots.txt` that blocks every crawler. No page lists shares.
- The server stores each share under a hash of its link, so the storage does not hold working links.
- People who open a link can still copy what they see. Share only what you would send by email.
- With server sync, your meetings (notes and transcripts, not the audio) are in your D1 database and R2 bucket. Phone recordings pass through R2 until the Mac imports them.

## Develop

```sh
npm test                 # the tool rules and the page parts
npx tsc --noEmit
npx wrangler d1 execute mossad-dev --local --config test/wrangler.dev.jsonc --file schema.sql
npx wrangler dev --config test/wrangler.dev.jsonc
```
