import { readFileSync } from 'node:fs';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [{
    // As Wrangler does: a .bin file is its bytes.
    name: 'bin-as-bytes',
    load(id) {
      if (!id.endsWith('.bin')) return null;
      return `export default Uint8Array.from(atob(${JSON.stringify(readFileSync(id).toString('base64'))}), (c) => c.charCodeAt(0)).buffer;`;
    },
  }],
});
