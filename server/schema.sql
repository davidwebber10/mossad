-- Synced records: the same shape as the iCloud records. seq orders every change; a delete keeps a tombstone.
CREATE TABLE IF NOT EXISTS records (
  name TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  fields TEXT NOT NULL DEFAULT '{}',
  assets TEXT NOT NULL DEFAULT '[]',
  seq INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  updated TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS records_seq ON records (seq);

-- The meetings as the MCP reads them, from each Meeting record's view asset.
CREATE TABLE IF NOT EXISTS meetings (
  id TEXT PRIMARY KEY,
  start INTEGER NOT NULL,
  view TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS meetings_start ON meetings (start);

CREATE TABLE IF NOT EXISTS lines (
  call_id TEXT NOT NULL,
  at REAL NOT NULL,
  speaker TEXT NOT NULL,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS lines_call ON lines (call_id);

-- Shares, by the SHA-256 of the link's token. The copy itself is in R2.
CREATE TABLE IF NOT EXISTS shares (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  created TEXT NOT NULL,
  expires TEXT,
  audio INTEGER NOT NULL DEFAULT 0,
  chat INTEGER NOT NULL DEFAULT 0,
  views INTEGER NOT NULL DEFAULT 0,
  questions INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
