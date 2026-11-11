type Value = string | number | null;
interface Statement {
  run(...params: Value[]): { changes: number | bigint };
  get(...params: Value[]): unknown;
  all(...params: Value[]): unknown[];
}
export interface Database {
  exec(sql: string): void;
  prepare(sql: string): Statement;
}
/** SQLite in memory with the first `migrations` migration files applied; all of them by default. */
export function openDatabase(migrations?: number): Database;
/** The migration files in the order Wrangler applies them. */
export function migrationFiles(): { name: string; sql: string }[];
