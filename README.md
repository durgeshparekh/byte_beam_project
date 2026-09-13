# Fleet Console

Local-first fleet telemetry console for 500 electric trucks. Flutter UI over an
embedded DuckDB database on device — the UI reads from DuckDB, not from an
in-memory list, and everything the app knows comes back off disk after a kill.

Design and the reasoning behind every ambiguous call:
**[ARCHITECTURE.md](ARCHITECTURE.md)**. Per-feature technical documentation:
**[docs/](docs/README.md)**.

## Run

```bash
flutter pub get
flutter run -d macos      # or: flutter run -d <android device>
```

## Test

`dart_duckdb` bundles its native library into the app for Android/iOS/macOS
builds, but `flutter test` runs on the host Dart VM where nothing has loaded
it. Fetch a host copy once:

```bash
tool/fetch_duckdb_lib.sh
flutter test
```

## Dependency pin

`dart_duckdb` is pinned to **1.2.2**, not a caret range. Packages 1.4.1–1.4.4
point their Android Gradle task at GitHub release tags that carry no Android
binaries (`v1.4.1` and `v1.4.4` both 404), so the APK cannot build on them.
1.2.2 downloads from `v1.2.0`, which exists — which is presumably why the brief
names `^1.2.0`. It bundles the DuckDB **1.2.1** engine, so
`tool/fetch_duckdb_lib.sh` fetches that same engine version for host tests.
Re-check when 1.4.5 lands.

Verified: `flutter test` (9 passing), `flutter build macos`, `flutter build apk`
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

Not built: automatic trips, the scale exercise (§7.2 and §8–§9 of
ARCHITECTURE.md).

229 tests pass. Five carry the design:

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
