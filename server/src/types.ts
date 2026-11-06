/** Records synced before decisions had times hold plain strings; newer ones hold an object. */
export type Decision = string | { text: string; at?: number };

export interface Env {
  DB: D1Database;
  FILES: R2Bucket;
  OAUTH_KV: KVNamespace;
  SHARE_HOST: string;
  MCP_HOST: string;
  /** The path of the MCP on MCP_HOST, such as "/mossad", so other MCP servers can share the host. */
  MCP_PATH?: string;
  REPO_URL: string;
  OWNER_SECRET: string;
  ANTHROPIC_API_KEY?: string;
  /** The model for share-page chats when a share does not name one. */
  SHARE_MODEL?: string;
}

/** One transcript line, as the Mac's notes show it. `at` is seconds from the start of the meeting. */
export interface Line {
  at: number;
  speaker: string;
  text: string;
}

export interface ActionItem {
  task: string;
  owner?: string;
  /** "Owner: task", as the notes write it. */
  text: string;
}

/** A meeting as the MCP reads it. The Mac builds it, so the naming rules live in one place. */
export interface MeetingView {
  id: string;
  title: string;
  /** ISO 8601. */
  start: string;
  end: string;
  platform?: string;
  kind?: string;
  headline?: string;
  tags: string[];
  people: string[];
  attendees: string[];
  summary?: string;
  topics: { title: string; summary: string }[];
  decisions: Decision[];
  actionItems: ActionItem[];
  lines: Line[];
  /** The owner's time zone, such as "America/Chicago": dates in tool inputs are local days. */
  timeZone?: string;
}

/** The copy of one meeting behind a share link: only the parts the owner turned on. */
export interface Share {
  title: string;
  start: string;
  end: string;
  people: string[];
  owner: string;
  summary?: string;
  topics?: { title: string; summary: string }[];
  decisions?: Decision[];
  actionItems?: ActionItem[];
  lines?: Line[];
  audio: boolean;
  chat: boolean;
  /** ISO 8601, or null for no expiry. */
  expires: string | null;
  timeZone?: string;
  /** The Claude model the owner's app uses, for the chat. */
  model?: string;
}
