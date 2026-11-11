-- Share links: an optional PIN, who viewed a link and when, and a row that stays after the expiry.
-- Additive: a server from before this file reads and writes the old columns as it did.

-- The PIN as "pbkdf2-sha256$<rounds>$<salt>$<hash>" over a keyed digest, or NULL for no PIN. Never the PIN itself.
ALTER TABLE shares ADD COLUMN pin_hash TEXT;
-- When the PIN was made, in ms since 1970. A pass that a visitor holds names it, so a new PIN ends every pass.
ALTER TABLE shares ADD COLUMN pin_set INTEGER;
ALTER TABLE shares ADD COLUMN viewers INTEGER NOT NULL DEFAULT 0;
ALTER TABLE shares ADD COLUMN first_view TEXT;
ALTER TABLE shares ADD COLUMN last_view TEXT;
-- 1 when the copy in R2 was deleted after the expiry. The row stays, so the owner sees the link as expired.
ALTER TABLE shares ADD COLUMN gone INTEGER NOT NULL DEFAULT 0;

-- One row per visitor of one share. `viewer` is a hash of a random cookie that belongs to that share only; no
-- address is kept. The country is the one Cloudflare names; the device is "phone", "tablet", "computer", or "other".
CREATE TABLE IF NOT EXISTS share_viewers (
  share_id TEXT NOT NULL,
  viewer TEXT NOT NULL,
  first TEXT NOT NULL,
  last TEXT NOT NULL,
  views INTEGER NOT NULL DEFAULT 1,
  country TEXT,
  device TEXT,
  PRIMARY KEY (share_id, viewer)
);

-- Views and new visitors per day, in the owner's time zone.
CREATE TABLE IF NOT EXISTS share_days (
  share_id TEXT NOT NULL,
  day TEXT NOT NULL,
  views INTEGER NOT NULL DEFAULT 0,
  viewers INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (share_id, day)
);

-- Wrong PINs. `client` is a keyed hash of the share and the visitor's address, or '' for the share as a whole.
-- Times are ms since 1970. A right PIN deletes the visitor's row; a new PIN deletes every row of the share.
CREATE TABLE IF NOT EXISTS share_pin_tries (
  share_id TEXT NOT NULL,
  client TEXT NOT NULL,
  fails INTEGER NOT NULL DEFAULT 0,
  locked_until INTEGER NOT NULL DEFAULT 0,
  updated INTEGER NOT NULL,
  PRIMARY KEY (share_id, client)
);
