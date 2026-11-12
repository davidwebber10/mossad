-- The site's own numbers. No table holds an IP address, a user agent, or any other request header.

-- One row for each accepted usage report from the app: the report, the day it came, and the country.
CREATE TABLE telemetry (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_day TEXT NOT NULL,
  country TEXT NOT NULL,
  install_id TEXT NOT NULL,
  app_version TEXT NOT NULL,
  build INTEGER NOT NULL,
  os TEXT NOT NULL,
  chip TEXT NOT NULL,
  locale TEXT NOT NULL,
  days_active7 INTEGER NOT NULL,
  meetings7 INTEGER NOT NULL,
  meeting_minutes7 INTEGER NOT NULL,
  p_zoom INTEGER NOT NULL,
  p_meet INTEGER NOT NULL,
  p_teams INTEGER NOT NULL,
  p_in_person INTEGER NOT NULL,
  p_gemini_notes INTEGER NOT NULL,
  transcription TEXT NOT NULL,
  summary TEXT NOT NULL,
  f_coach INTEGER NOT NULL,
  f_screens INTEGER NOT NULL,
  f_google INTEGER NOT NULL,
  f_server INTEGER NOT NULL,
  f_iphone INTEGER NOT NULL,
  f_backup INTEGER NOT NULL,
  f_mcp INTEGER NOT NULL,
  f_shares INTEGER NOT NULL,
  c_people TEXT NOT NULL,
  c_recurring TEXT NOT NULL,
  c_commitments_open TEXT NOT NULL,
  e_transcribe INTEGER NOT NULL,
  e_identify INTEGER NOT NULL,
  e_summarize INTEGER NOT NULL,
  e_write INTEGER NOT NULL,
  e_detect INTEGER NOT NULL
);
CREATE INDEX telemetry_day ON telemetry (received_day);
CREATE INDEX telemetry_install ON telemetry (install_id, id);

-- The rate limit: when each install last sent a report that was kept, in whole minutes since 1970.
CREATE TABLE install_limit (
  install_id TEXT PRIMARY KEY,
  last_minute INTEGER NOT NULL
);

-- Page views, counted: no identifier, so one person and many people look the same.
CREATE TABLE page_views (
  day TEXT NOT NULL,
  path TEXT NOT NULL,
  country TEXT NOT NULL,
  referrer TEXT NOT NULL,
  device TEXT NOT NULL,
  views INTEGER NOT NULL,
  PRIMARY KEY (day, path, country, referrer, device)
);

-- Clicks on a download button, counted the same way.
CREATE TABLE clicks (
  day TEXT NOT NULL,
  target TEXT NOT NULL,
  country TEXT NOT NULL,
  clicks INTEGER NOT NULL,
  PRIMARY KEY (day, target, country)
);
