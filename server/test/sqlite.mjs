// The test database: SQLite in memory, made by the migration files in order, as `wrangler d1 migrations apply` does.
import { readdirSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const dir = new URL('../migrations/', import.meta.url);

/** The migration files in the order Wrangler applies them. */
export function migrationFiles() {
  return readdirSync(dir).filter((f) => f.endsWith('.sql')).sort().map((name) => ({ name, sql: readFileSync(new URL(name, dir), 'utf8') }));
}

export function openDatabase(migrations = Infinity) {
  const db = new DatabaseSync(':memory:');
  for (const file of migrationFiles().slice(0, migrations)) db.exec(file.sql);
  return db;
}
