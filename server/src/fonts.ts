import italic from './fonts/literata-italic.woff2.bin';
import roman from './fonts/literata.woff2.bin';
import { fonts } from './pages';

/**
 * The text face of the pages: Literata, the Latin subset of the variable font, under the SIL Open Font License
 * (fonts/LICENSE.txt). It comes from this Worker, so a page asks no other site for anything.
 */
const files: Record<string, ArrayBuffer> = { [fonts.roman]: roman, [fonts.italic]: italic };

/** A font file never changes under its name, so a browser keeps it for a year. */
export function fontResponse(path: string): Response | null {
  const bytes = files[path];
  if (!bytes) return null;
  return new Response(bytes, { headers: { 'Content-Type': 'font/woff2', 'Cache-Control': 'public, max-age=31536000, immutable', 'X-Content-Type-Options': 'nosniff' } });
}
