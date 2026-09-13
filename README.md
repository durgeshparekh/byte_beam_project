# Fleet Console

Local-first fleet telemetry console for 500 electric trucks. Flutter UI over an
embedded DuckDB database on device — the UI reads from DuckDB, not from an
in-memory list, and everything the app knows comes back off disk after a kill.

Design and the reasoning behind every ambiguous call:
**[ARCHITECTURE.md](ARCHITECTURE.md)**. Per-feature technical documentation:
**[docs/](docs/README.md)**.

## Run the app

```bash
flutter pub get
flutter run -d macos
```

Android works too (`flutter run -d <device>`); there is no `ios/` directory in
this project, so iOS does not. Nothing else to set up — the database is created
in application support on first launch, the roster is seeded, and the simulated
feed starts before the first frame. Kill the app and relaunch it: the fleet
list comes back off disk, which is the point of the exercise.

### The scale exercise, headless

The three debug actions on the **Scale exercise** screen also run from the
command line, printing their results to stdout as `[scale] …`. They are
compile-time constants, so a build without the defines contains none of them.

```bash
# 500 vehicles, 2.1 M signal rows, generated inside DuckDB
flutter run -d macos --release --dart-define=SCALE_BACKFILL=true

# 100 warm runs of the fleet-list query, timed in the writer isolate
flutter run -d macos --release --dart-define=SCALE_BENCH=true

# retention: summarise, drop, checkpoint (the policy is 7 days; the demo
# database only holds a couple of hours, hence the override)
flutter run -d macos --release --dart-define=SCALE_COMPACT=true \
                               --dart-define=SCALE_KEEP_MINUTES=60
```

Measured numbers, method and device: **[docs/07-scale.md](docs/07-scale.md)**.

## Run the tests

`dart_duckdb` bundles its native library into the app for Android and macOS
builds, but `flutter test` runs on the host Dart VM where nothing has loaded
it. Fetch a host copy once:

```bash
tool/fetch_duckdb_lib.sh
flutter test
```

## 30-second tour

Everything below is reachable from the fleet list, and every screen is reading
DuckDB rather than a list in memory.

1. **Fleet list.** Filter chips carry live counts; both the counts and the
   status behind them are decided in SQL, not in Dart. A red dot on a row means
   an open alert.
2. **Tap a vehicle.** The register gives every configured signal its own
   NORMAL / ALERT / STALE verdict against its own freshness window — including
   the ones that have never reported. Below it: the current geofence and recent
   crossings, the trips derived from them, and a battery history bucketed out
   of the event log by SQL.
3. **Alerts** (bell, top right). Dismiss one, pick a reason, and the UNDO
   snackbar stands for five seconds — the dismissal is already on disk, so
   killing the app mid-window keeps it.
4. **Geofences** (map). Four seeded fences with live occupancy, including
   a bay nested inside a depot. Edit or deactivate one and every crossing and
   trip is re-derived.
5. **Trips** (route). Legs between fences, running ones first. A trip starts
   when a vehicle leaves the *last* fence it was inside, so crossing the depot
   yard manufactures nothing.
6. **Ingest monitor** (heart rate) → **Scale exercise** (gauge). Session
   counters beside what a fresh query returns, then the backfill, the
   benchmark and the retention action.

## Dependency pin

`dart_duckdb` is pinned to **1.2.2**, not a caret range. Packages 1.4.1–1.4.4
point their Android Gradle task at GitHub release tags that carry no Android
binaries (`v1.4.1` and `v1.4.4` both 404), so the APK cannot build on them.
1.2.2 downloads from `v1.2.0`, which exists — which is presumably why the brief
names `^1.2.0`. It bundles the DuckDB **1.2.1** engine, so
`tool/fetch_duckdb_lib.sh` fetches that same engine version for host tests.
Re-check when 1.4.5 lands.

Verified: `flutter test`, `flutter build macos`, `flutter build apk`
(`libduckdb.so` present for arm64-v8a and armeabi-v7a), and the macOS app
creating and reopening its database in Application Support.

## AI conversation logs

Deliverable 3, uncurated, in [`ai-logs/`](ai-logs) — full turns, tool calls and
tool results, dead ends included. Regenerate after a session:

```bash
tool/export_ai_logs.sh
```

Claude Code groups transcripts by the directory it was launched from. Sessions
started from a parent directory land in that group next to unrelated work, so
`--src` points at another group and `--match` keeps only this project's
conversations:

```bash
tool/export_ai_logs.sh --src ~/.claude/projects/<group> --match byte_beam_project
```

## Architecture

Clean architecture per feature (`domain` / `data` / `presentation`) with GetX
for state and dependency injection. `domain` imports nothing outward, so
`IngestController` is unit-tested against a fake repository with no database
involved. See [ARCHITECTURE.md](ARCHITECTURE.md) §1.

## Status

Built — each with its own document under [docs/](docs/README.md):

* **[Telemetry ingest](docs/01-telemetry-ingest.md)** — packet simulator,
  long-lived writer isolate, staging-table bulk append, duplicate rejection,
  late-packet handling, ingest monitor screen.
* **[Fleet home](docs/02-fleet-home.md)** — vehicle list with registration,
  model, SOC, range, alert badge and status chip; filter chips with live
  counts; empty states. Status and counts are both decided in SQL.
* **[Vehicle detail](docs/03-vehicle-detail.md)** — readings register with a
  NORMAL / ALERT / STALE verdict per signal, and SOC history queried and
  bucketed out of the event log.
* **[Alerts](docs/04-alerts.md)** — an alert lifecycle over the event log:
  raise, escalate in place, resolve on observed recovery, dismiss with a
  reason, undo for five seconds. Alerts are episodes, not flags.
* **[Geofences](docs/05-geofences.md)** — create, edit and deactivate circular
  fences; entry/exit detected in SQL from event-time position history with a
  hysteresis band, two-fix confirmation and a resumable containment state.
* **[Automatic trips](docs/06-trips.md)** — legs derived from those crossings
  on every batch: a trip starts when a vehicle's containment count reaches
  zero, completes when it leaves zero, and carries an odometer distance. A
  nested bay manufactures nothing.
* **[Scale exercise](docs/07-scale.md)** — a debug action that backfills 500
  vehicles and 2.17 M signal rows inside DuckDB, the three measurements the
  brief asks for on a named machine, and a retention policy that is executed
  rather than described.

272 tests pass. Five carry the design:

* `test/features/telemetry_ingest/ingest_pipeline_test.dart` — the same feed
  reversed, re-batched and partially redelivered produces byte-identical state
  to the in-order replay.
* `test/features/telemetry_ingest/ingest_binding_test.dart` — building the
  binding actually starts the pipeline and rows reach disk. Every other test
  passed while a running app ingested nothing.
* `test/features/fleet/fleet_end_to_end_test.dart` — simulator to writer
  isolate to DuckDB to the fleet query with nothing stubbed, asserting every
  vehicle lands in exactly one chip.
* `test/features/alerts/alert_evaluator_test.dart` — the alert state machine:
  escalation in place, recovery that must be *observed*, a hysteresis band, and
  a dismissal that survives resolution but not escalation. Two of its rules
  exist because running the real app disproved the first version.
* `test/features/geofence/geofence_detector_test.dart` — deriving crossings one
  fix at a time lands on byte-identical state to one pass over the finished
  log, and a late fix replayed from scratch is indistinguishable from having
  had the log in order.
