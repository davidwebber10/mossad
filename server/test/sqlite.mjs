// The test database: SQLite in memory, made by the migration files in order, as `wrangler d1 migrations apply` does.
import { readdirSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

export function openDatabase(migrations = Infinity) {
  const db = new DatabaseSync(':memory:');
  const dir = new URL('../migrations/', import.meta.url);
  for (const file of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort().slice(0, migrations)) db.exec(readFileSync(new URL(file, dir), 'utf8'));
  return db;
}
