import { readFileSync } from 'node:fs';

/** A payload as the Mac's Swift code encodes it, written by `ServerPayloadFixtureTests`. */
export function fixture(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), 'utf8'));
}
