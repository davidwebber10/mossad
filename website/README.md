# getmossad.com

The website of Mossad and its small backend: one Cloudflare Worker that serves the static site, counts page views without cookies, takes the app's usage reports, and shows the owner a private dashboard.

| Path | What it is |
| --- | --- |
| `content/site.json` | The words about the product: the privacy page, `llms.txt`, and `llms-full.txt` are built from it. The home page's own words are in `src/index.html`, so a feature change needs both. |
| `src/` | The page sources: `index.html`, `privacy.html`, `404.html`, `site.css`, the shared `partials/`, and `og.svg` (the share image). |
| `scripts/build-site.sh` | Builds `site/` from `src/` and `content/`, then checks it. |
| `site/` | The built site, committed. The Worker serves this folder as is. |
| `worker/` | The Worker (`src/`), its D1 tables (`migrations/`), its tests (`test/`), and `wrangler.jsonc`. |

## Build the site

```sh
website/scripts/build-site.sh            # pages, robots.txt, sitemap.xml, llms.txt, llms-full.txt, and the check
website/scripts/build-site.sh --images   # also renders og.png and the PNG icons with Chrome
```

The pages read nothing at run time. The build fills in the CSS (inline), the header and footer, the download link, the latest release (from the newest `v*` git tag) for the structured data, and the FAQ structured data from the FAQ that the page shows. The check fails on broken links, tags that do not close, headings out of order, JSON-LD that does not parse, a missing SEO tag or file, an outside request, an em dash, or a privacy claim that the app's usage statistics would make false.

Run the build after you change `src/` or `content/site.json`, and commit `site/` with the change. Run it with `--images` after you change `og.svg` or the logo.

The fonts in `site/fonts/` are Bricolage Grotesque, Inter, and IBM Plex Mono (latin subset), from Google Fonts, under the SIL Open Font License. Their licenses are next to them.

## Test the Worker

```sh
cd website/worker
npm ci
npm test
npx tsc --noEmit
```

`npm run dev` runs it on this Mac with a local database: `npx wrangler d1 migrations apply mossad-telemetry --local` first.

## Deploy

The coordinator deploys. Do not deploy from an agent session.

1. Create the database: `cd website/worker && npx wrangler d1 create mossad-telemetry`. Put the `database_id` it prints in `wrangler.jsonc`.
2. Make the tables: `npx wrangler d1 migrations apply mossad-telemetry --remote`. Later migrations are new numbered files in `migrations/`, additive only.
3. In the Cloudflare dashboard, turn on SSL/TLS, Edge Certificates, Always Use HTTPS for getmossad.com and getmossad.app. (The Worker also redirects plain HTTP, as a second barrier.) Add a rate limiting rule for each zone too, as a barrier in front of the Worker's own limits.
4. Deploy: `npx wrangler deploy`. The four custom domains in `wrangler.jsonc` (getmossad.com, www.getmossad.com, getmossad.app, www.getmossad.app) are all zones in the account. A custom domain fails when the host name already has a DNS record; remove that record first. www and the .app hosts answer with a 301 to https://getmossad.com and the same path.
5. Open https://getmossad.com, https://getmossad.com/privacy, and https://www.getmossad.com (it must redirect).

## Cloudflare Access for /stats

`/stats` answers 403 until all three Access variables are set, and to everyone but the owner after.

1. In the Cloudflare dashboard, open Zero Trust, then Access, then Applications. Choose Add an application, then Self-hosted.
2. Name it "Mossad stats". Add the domain `getmossad.com` with the path `stats*`.
3. Add a policy: Action Allow, Include Emails, and the owner's email address. Save the application.
4. Copy the Application Audience (AUD) tag from the application's Overview, and the team domain (such as `yourteam.cloudflareaccess.com`) from Zero Trust, Settings, Custom Pages.
5. Set the three secrets, then deploy again. They are secrets so that the owner's email is never in the public repository:

   ```sh
   cd website/worker
   npx wrangler secret put ACCESS_TEAM_DOMAIN   # yourteam.cloudflareaccess.com
   npx wrangler secret put ACCESS_AUD           # the AUD tag
   npx wrangler secret put OWNER_EMAIL          # the same email as the policy
   ```

The Worker does not trust Access alone: it checks the `Cf-Access-Jwt-Assertion` token's RS256 signature against the team's public keys at `https://<team domain>/cdn-cgi/access/certs`, the audience, the issuer, the time, and that the email is `OWNER_EMAIL`. Anything else gets 403 and no data. For a key id it does not know (after a key rotation), it reads the keys again, at most once a minute.

## The usage report (payload version 1)

The app posts JSON to `POST https://getmossad.com/api/telemetry` with `Content-Type: application/json`:

```json
{"v":1,"installID":"<random UUID v4>","appVersion":"2.20.0","build":607,"os":"26.1","chip":"M3","locale":"en-US",
 "daysActive7":5,"meetings7":12,"meetingMinutes7":540,
 "platforms7":{"zoom":4,"meet":5,"teams":2,"inPerson":1,"geminiNotes":0},
 "providers":{"transcription":"assemblyai","summary":"anthropic"},
 "features":{"coach":true,"screens":false,"google":true,"server":false,"iphone":true,"backup":false,"mcp":true,"shares":false},
 "counts":{"people":"21-100","recurring":"6-20","commitmentsOpen":"1-5"},
 "errors7":{"transcribe":0,"identify":1,"summarize":0,"write":0,"detect":2}}
```

Every key is required, and an unknown key at any level is refused. The rules, in `worker/src/telemetry.ts`:

| Key | Allowed |
| --- | --- |
| `v` | the number 1 |
| `installID` | a UUID version 4, either case |
| `appVersion` | `2.20` or `2.20.0` |
| `build` | an integer, 1 to 1,000,000 |
| `os` | the macOS version, 26 or later: `26`, `26.1`, `26.1.2` |
| `chip` | `M1` to `M99`, with ` Pro`, ` Max`, or ` Ultra` after it, or `Other` in any case (stored as `Other`) |
| `locale` | `en`, `en-US`, `zh-Hans-CN`, `es-419` |
| `daysActive7` | an integer, 0 to 7 |
| `meetings7` | an integer, 0 to 500 |
| `meetingMinutes7` | an integer, 0 to 20,000 |
| `platforms7.*` | integers, 0 to 500 |
| `providers.transcription` | `assemblyai`, `deepgram`, `elevenlabs`, `openai`, `local`, `none` |
| `providers.summary` | `anthropic`, `openai`, `openrouter`, `localServer`, `apple`, `none` |
| `features.*` | `true` or `false` |
| `counts.*` | `"0"`, `"1-5"`, `"6-20"`, `"21-100"`, `"100+"` |
| `errors7.*` | integers, 0 to 10,000 |

The answers: 204 kept; 400 not valid; 413 a body over 4 KB; 415 not JSON; 429 too soon (one report an hour for each install, 60 requests an hour from one network, and 10 new installs a day from one network; a network is an IPv4 address or an IPv6 /64); 405 not a POST. The app should not retry a 4xx.

## What the server stores

- **A usage report:** the fields above, the day it came (UTC), and the country that Cloudflare gives the request. Not the IP address, the user agent, or any other header. The rate limit keeps one row for each install with the minute of its last kept report.
- **The network limits** live only in memory and in the Cache API of one data center, under a one-way hash of the network and the window, for that window. They are never stored.
- **A page view** of the home page or the privacy page adds one to a count of (day, page, country, the host name of a public referring site, device class: desktop, mobile, tablet, or bot). A day keeps 200 referring sites by name and counts the rest as `other`; a network counts at most 120 views an hour. The user agent and the referrer are read to choose the bucket and then dropped. No cookie and no identifier.
- **A click** on a Download button sends one word (the button: `header`, `hero`, or `cta`; the code also allows `privacy` and `404`) to `/api/click` with `navigator.sendBeacon`, and adds one to a count of (day, button, country). A click from another site is refused.
- Workers observability is off, so the platform keeps no request logs for this Worker.

`worker/test/privacy.test.ts` holds these rules: it fails if a table gains a column for an address, an agent, a header, an email, or a time.
