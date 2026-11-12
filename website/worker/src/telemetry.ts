// The app's anonymous usage report, version 1. Anything that is not exactly this shape is refused.

export const BUCKETS = ['0', '1-5', '6-20', '21-100', '100+'] as const;
export const TRANSCRIPTION = ['assemblyai', 'deepgram', 'elevenlabs', 'openai', 'local', 'none'] as const;
export const SUMMARY = ['anthropic', 'openai', 'openrouter', 'localServer', 'apple', 'none'] as const;
export const PLATFORMS = ['zoom', 'meet', 'teams', 'inPerson', 'geminiNotes'] as const;
export const FEATURES = ['coach', 'screens', 'google', 'server', 'iphone', 'backup', 'mcp', 'shares'] as const;
export const COUNTS = ['people', 'recurring', 'commitmentsOpen'] as const;
export const ERROR_STEPS = ['transcribe', 'identify', 'summarize', 'write', 'detect'] as const;

/** The largest body the endpoint reads. A real report is about 600 bytes. */
export const MAX_BODY_BYTES = 4096;

type Bucket = (typeof BUCKETS)[number];

export interface Report {
  v: 1;
  installID: string;
  appVersion: string;
  build: number;
  os: string;
  chip: string;
  locale: string;
  daysActive7: number;
  meetings7: number;
  meetingMinutes7: number;
  platforms7: Record<(typeof PLATFORMS)[number], number>;
  providers: { transcription: (typeof TRANSCRIPTION)[number]; summary: (typeof SUMMARY)[number] };
  features: Record<(typeof FEATURES)[number], boolean>;
  counts: Record<(typeof COUNTS)[number], Bucket>;
  errors7: Record<(typeof ERROR_STEPS)[number], number>;
}

const TOP_KEYS = ['v', 'installID', 'appVersion', 'build', 'os', 'chip', 'locale', 'daysActive7', 'meetings7', 'meetingMinutes7', 'platforms7', 'providers', 'features', 'counts', 'errors7'] as const;

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const APP_VERSION = /^\d{1,3}\.\d{1,3}(\.\d{1,3})?$/;
const OS = /^(2[6-9]|[3-9]\d)(\.\d{1,2}){0,2}$/;
const CHIP = /^(M\d{1,2}( Pro| Max| Ultra)?|Other)$/;
const LOCALE = /^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|\d{3}))?$/;

export class Invalid extends Error {}

function object(value: unknown, keys: readonly string[], name: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Invalid(`${name} is not an object`);
  const own = Object.keys(value);
  for (const k of own) if (!keys.includes(k)) throw new Invalid(`${name} has an unknown key`);
  for (const k of keys) if (!Object.hasOwn(value, k)) throw new Invalid(`${name}.${k} is missing`);
  return value as Record<string, unknown>;
}

function int(value: unknown, min: number, max: number, name: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) throw new Invalid(`${name} is out of range`);
  return value;
}

function text(value: unknown, pattern: RegExp, max: number, name: string): string {
  if (typeof value !== 'string' || value.length > max || !pattern.test(value)) throw new Invalid(`${name} is not valid`);
  return value;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], name: string): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) throw new Invalid(`${name} is not an allowed value`);
  return value as T;
}

function bool(value: unknown, name: string): boolean {
  if (typeof value !== 'boolean') throw new Invalid(`${name} is not a boolean`);
  return value;
}

/** The report, or an Invalid error that says which part is wrong. Never returns a value it did not check. */
export function parseReport(input: unknown): Report {
  const o = object(input, TOP_KEYS, 'report');
  if (o.v !== 1) throw new Invalid('v is not 1');
  const platforms = object(o.platforms7, PLATFORMS, 'platforms7');
  const providers = object(o.providers, ['transcription', 'summary'], 'providers');
  const features = object(o.features, FEATURES, 'features');
  const counts = object(o.counts, COUNTS, 'counts');
  const errors = object(o.errors7, ERROR_STEPS, 'errors7');
  return {
    v: 1,
    installID: text(o.installID, UUID_V4, 36, 'installID').toLowerCase(),
    appVersion: text(o.appVersion, APP_VERSION, 11, 'appVersion'),
    build: int(o.build, 1, 1_000_000, 'build'),
    os: text(o.os, OS, 8, 'os'),
    chip: text(o.chip, CHIP, 8, 'chip'),
    locale: text(o.locale, LOCALE, 16, 'locale'),
    daysActive7: int(o.daysActive7, 0, 7, 'daysActive7'),
    meetings7: int(o.meetings7, 0, 500, 'meetings7'),
    meetingMinutes7: int(o.meetingMinutes7, 0, 20000, 'meetingMinutes7'),
    platforms7: Object.fromEntries(PLATFORMS.map((k) => [k, int(platforms[k], 0, 500, `platforms7.${k}`)])) as Report['platforms7'],
    providers: {
      transcription: oneOf(providers.transcription, TRANSCRIPTION, 'providers.transcription'),
      summary: oneOf(providers.summary, SUMMARY, 'providers.summary'),
    },
    features: Object.fromEntries(FEATURES.map((k) => [k, bool(features[k], `features.${k}`)])) as Report['features'],
    counts: Object.fromEntries(COUNTS.map((k) => [k, oneOf(counts[k], BUCKETS, `counts.${k}`)])) as Report['counts'],
    errors7: Object.fromEntries(ERROR_STEPS.map((k) => [k, int(errors[k], 0, 10000, `errors7.${k}`)])) as Report['errors7'],
  };
}

/** The country Cloudflare gives a request, as two characters, or XX when it gives none. */
export function countryOf(request: Request): string {
  const c = (request as { cf?: { country?: unknown } }).cf?.country;
  return typeof c === 'string' && /^[A-Z][A-Z0-9]$/.test(c) ? c : 'XX';
}

export function dayOf(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/** The columns of a stored report: the report, the day it came, and the country. Nothing about the request. */
export function reportRow(report: Report, day: string, country: string): Record<string, string | number> {
  return {
    received_day: day,
    country,
    install_id: report.installID,
    app_version: report.appVersion,
    build: report.build,
    os: report.os,
    chip: report.chip,
    locale: report.locale,
    days_active7: report.daysActive7,
    meetings7: report.meetings7,
    meeting_minutes7: report.meetingMinutes7,
    p_zoom: report.platforms7.zoom,
    p_meet: report.platforms7.meet,
    p_teams: report.platforms7.teams,
    p_in_person: report.platforms7.inPerson,
    p_gemini_notes: report.platforms7.geminiNotes,
    transcription: report.providers.transcription,
    summary: report.providers.summary,
    f_coach: +report.features.coach,
    f_screens: +report.features.screens,
    f_google: +report.features.google,
    f_server: +report.features.server,
    f_iphone: +report.features.iphone,
    f_backup: +report.features.backup,
    f_mcp: +report.features.mcp,
    f_shares: +report.features.shares,
    c_people: report.counts.people,
    c_recurring: report.counts.recurring,
    c_commitments_open: report.counts.commitmentsOpen,
    e_transcribe: report.errors7.transcribe,
    e_identify: report.errors7.identify,
    e_summarize: report.errors7.summarize,
    e_write: report.errors7.write,
    e_detect: report.errors7.detect,
  };
}

/** Reads at most MAX_BODY_BYTES of the body, or null when it is longer. */
export async function readLimited(request: Request, limit = MAX_BODY_BYTES): Promise<string | null> {
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (declared > limit) return null;
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.byteLength; }
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(all);
}
