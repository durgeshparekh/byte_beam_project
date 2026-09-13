/// Schema lives as Dart strings, not as a bundled `.sql` asset, so that the
/// writer isolate can migrate without `rootBundle` — an isolate has no access
/// to the asset bundle, and migrations run there.
library;

/// Forward-only. Append a new entry; never edit a shipped one.
/// See ARCHITECTURE.md §3.5 — class D tables are dropped and rebuilt rather
/// than migrated, so most schema changes add nothing here.
const List<String> migrations = [_v1];

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
