/// Schema lives as Dart strings, not as a bundled `.sql` asset, so that the
/// writer isolate can migrate without `rootBundle` — an isolate has no access
/// to the asset bundle, and migrations run there.
library;

/// Forward-only. Append a new entry; never edit a shipped one.
/// See ARCHITECTURE.md §3.5 — class D tables are dropped and rebuilt rather
/// than migrated, so most schema changes add nothing here.
const List<String> migrations = [_v1, _v2, _v3];

const _v1 = r'''
-- ---------------------------------------------------------------- class R --
-- Remote-authoritative, immutable, natural-keyed. Never row-updated.
CREATE TABLE vehicle (
  vehicle_id TEXT PRIMARY KEY,
  reg_no     TEXT NOT NULL,
  model      TEXT NOT NULL
);

CREATE TABLE signal_reading (
  vehicle_id TEXT      NOT NULL,
  signal     TEXT      NOT NULL,
  event_ts   TIMESTAMP NOT NULL,
  value      DOUBLE    NOT NULL,
  ingest_ts  TIMESTAMP NOT NULL,
  PRIMARY KEY (vehicle_id, signal, event_ts)
);

CREATE TABLE location_fix (
  vehicle_id TEXT      NOT NULL,
  event_ts   TIMESTAMP NOT NULL,
  lat        DOUBLE    NOT NULL,
  lon        DOUBLE    NOT NULL,
  accuracy_m DOUBLE,
  ingest_ts  TIMESTAMP NOT NULL,
  PRIMARY KEY (vehicle_id, event_ts)
);

-- ---------------------------------------------------------------- class L --
-- Device-authored intent. The only rows with no upstream copy.
CREATE TABLE geofence (
  geofence_id TEXT PRIMARY KEY,
  name        TEXT   NOT NULL,
  lat         DOUBLE NOT NULL,
  lon         DOUBLE NOT NULL,
  radius_m    DOUBLE NOT NULL,
  active_from TIMESTAMP NOT NULL,
  active_to   TIMESTAMP,
  updated_at  TIMESTAMP NOT NULL
);

-- ---------------------------------------------------------------- config ---
-- Thresholds as data: the verdict pills, the alert evaluator and the UI all
-- read these rows rather than duplicating constants.
CREATE TABLE signal_spec (
  signal      TEXT PRIMARY KEY,
  label       TEXT NOT NULL,
  unit        TEXT NOT NULL,
  max_age_sec INTEGER NOT NULL,
  warn_lo DOUBLE, warn_hi DOUBLE,
  crit_lo DOUBLE, crit_hi DOUBLE
);

INSERT INTO signal_spec VALUES
  ('soc',          'State of charge',    '%',    300, 20,   NULL, 10,   NULL),
  ('range_km',     'Range',              'km',   300, NULL, NULL, NULL, NULL),
  ('speed',        'Speed',              'km/h', 300, NULL, NULL, NULL, NULL),
  ('battery_temp', 'Battery temperature','C',    300, NULL, NULL, NULL, 45),
  ('odometer',     'Odometer',           'km',  3600, NULL, NULL, NULL, NULL),
  ('ignition',     'Ignition',           '',     300, NULL, NULL, NULL, NULL);

-- ---------------------------------------------------------------- class D --
-- Derived from R + L. Never synced, never backed up, always rebuildable.
CREATE TABLE vehicle_signal_latest (
  vehicle_id TEXT      NOT NULL,
  signal     TEXT      NOT NULL,
  event_ts   TIMESTAMP NOT NULL,
  value      DOUBLE    NOT NULL,
  PRIMARY KEY (vehicle_id, signal)
);

CREATE TABLE alert (
  alert_id       TEXT PRIMARY KEY,
  vehicle_id     TEXT NOT NULL,
  alert_type     TEXT NOT NULL,
  severity       TEXT NOT NULL,
  raised_at      TIMESTAMP NOT NULL,
  escalated_at   TIMESTAMP,
  resolved_at    TIMESTAMP,
  dismissed_at   TIMESTAMP,
  dismiss_reason TEXT
);

CREATE TABLE geofence_transition (
  vehicle_id  TEXT      NOT NULL,
  geofence_id TEXT      NOT NULL,
  event_ts    TIMESTAMP NOT NULL,
  kind        TEXT      NOT NULL,
  confidence  TEXT      NOT NULL,
  PRIMARY KEY (vehicle_id, geofence_id, event_ts)
);

CREATE TABLE trip (
  trip_id            TEXT PRIMARY KEY,
  vehicle_id         TEXT      NOT NULL,
  origin_geofence_id TEXT,
  start_ts           TIMESTAMP NOT NULL,
  dest_geofence_id   TEXT,
  end_ts             TIMESTAMP,
  status             TEXT      NOT NULL,
  distance_km        DOUBLE,
  confidence         TEXT      NOT NULL
);

-- Derivation position. Advanced in its own transaction, after the log is
-- committed, so derived state is always behind the log and never ahead.
CREATE TABLE ingest_watermark (
  vehicle_id        TEXT PRIMARY KEY,
  processed_through TIMESTAMP NOT NULL
);
''';

/// Geofences: the containment state table, and the seed fences.
///
/// A second migration rather than an edit to [_v1], because [_v1] has shipped
/// to a database on my machine and forward-only means forward-only. The rule
/// costs one extra string and buys the guarantee that a running install
/// upgrades rather than resets.
const _v2 = r'''
-- ---------------------------------------------------------------- class D --
-- Where each vehicle stands relative to each fence, as of the last derivation.
--
-- Earns its place three times over: it seeds the incremental detector (so a
-- batch re-derives two fixes instead of a vehicle's whole history), it answers
-- "which fence is this truck in" without touching the log, and it is what the
-- live per-fence counts are counted from.
--
-- `zone` is the *confirmed* side. `pending_zone` is the last fix that had an
-- opinion at all, which may be an unconfirmed candidate — the detector needs
-- both to resume mid-stream without re-reading what it already folded.
CREATE TABLE geofence_containment (
  vehicle_id   TEXT NOT NULL,
  geofence_id  TEXT NOT NULL,
  zone         TEXT,
  pending_zone TEXT,
  pending_ts   TIMESTAMP,
  PRIMARY KEY (vehicle_id, geofence_id)
);

-- ---------------------------------------------------------------- class L --
-- Seed fences. Device-authored like any other fence: editable, deactivatable,
-- and deleted by nothing. `active_from` predates the log so they see all of
-- it; a fence created in the app starts active from the moment it is saved,
-- which is why a new fence has no back-history.
--
-- Depot Bay 3 sits inside Whitefield Depot on purpose. A nested pair is the
-- case that breaks a naive "current geofence" column and the case that
-- manufactures a phantom trip out of a truck moving across its own yard
-- (ARCHITECTURE.md §10, ambiguities 10 and 11).
INSERT INTO geofence VALUES
  ('gf-depot',  'Whitefield Depot',     12.9700, 77.6000, 2500,
   TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01'),
  ('gf-bay3',   'Depot Bay 3',          12.9710, 77.6015,  350,
   TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01'),
  ('gf-ecity',  'Electronic City Hub',  12.9250, 77.5600, 1800,
   TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01'),
  ('gf-hebbal', 'Hebbal Yard',          13.0200, 77.6500, 1500,
   TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01');
''';

/// Retention: the bucket table old readings are compacted into.
///
/// A third migration rather than an edit to [_v2], for the same reason [_v2]
/// was not an edit to [_v1] — forward-only means forward-only, and a database
/// that already exists has to upgrade rather than reset.
const _v3 = r'''
-- ---------------------------------------------------------------- class D --
-- Five-minute summaries of readings older than the hot window, written as the
-- raw rows are dropped. Derived like everything else in class D, but derived
-- from data that no longer exists — which makes it the one class D table that
-- cannot be rebuilt, and the reason §8 spells out what is lost.
--
-- min/max as well as avg because an average hides exactly the thing anyone
-- looks at old battery data for: how hot did it actually get.
CREATE TABLE signal_rollup (
  vehicle_id TEXT      NOT NULL,
  signal     TEXT      NOT NULL,
  bucket_ts  TIMESTAMP NOT NULL,
  readings   BIGINT    NOT NULL,
  min_value  DOUBLE    NOT NULL,
  max_value  DOUBLE    NOT NULL,
  avg_value  DOUBLE    NOT NULL,
  last_value DOUBLE    NOT NULL,
  PRIMARY KEY (vehicle_id, signal, bucket_ts)
);
''';
