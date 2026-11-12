export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  /** The one host that serves the site. Every other host of ours redirects to it. */
  CANONICAL_HOST: string;
  /** Hosts that redirect to the canonical host, separated by commas. */
  REDIRECT_HOSTS?: string;
  /** Cloudflare Access: the team domain, such as example.cloudflareaccess.com. */
  ACCESS_TEAM_DOMAIN?: string;
  /** Cloudflare Access: the Application Audience (AUD) tag of the /stats application. */
  ACCESS_AUD?: string;
  /** The one email that may open /stats. */
  OWNER_EMAIL?: string;
}
