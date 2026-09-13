# Fleet Console — System Design

Flutter take-home, Bytebeam SDE-3. Local-first fleet telemetry console over embedded DuckDB.

Status: **design only, nothing built yet.**

---

## 0. The one idea

> **Derived state is a pure fold over an append-only event log. Late or duplicate data is handled by replaying the affected suffix, never by patching.**

Everything hard in this brief — duplicates, out-of-order packets, GPS jitter, backlog dumps, geofence edits, trip revision — collapses into that sentence. Alerts, geofence transitions and trips are *never* mutated in place by an incoming packet. They are recomputed from the log for the window the packet touches. Recompute is idempotent because the derivation is a pure function of `(event log ∩ [t0, ∞), config)`.

The corollary is the invariant worth testing above all others:

> Shuffle the packet stream arbitrarily, replay duplicates, and the final derived state must be byte-identical to the in-order replay.

---

## 1. Layout

Clean architecture, one folder per feature, with GetX for state and dependency
injection.

```
lib/
  core/
    error/        Failure (domain) · exceptions (data)
    usecases/     UseCase<T,P> · StreamUseCase<T,P> · NoParams
    utils/        Result<T> sealed union · Clock
  db/             schema.dart (DDL + migrations) · FleetDb (open, migrate, isolates)
  features/<feature>/
    domain/       entities · repository interfaces · use cases     <- no imports outward
    data/         models · data sources · repository implementations
    presentation/ GetxController · Bindings · pages
tool/
  bench.dart            cold start / p50 / p95 / memory harness
  fetch_duckdb_lib.sh   host duckdb for `flutter test`
  export_ai_logs.sh     Claude session jsonl -> ai-logs/*.md
ai-logs/                uncurated AI conversation logs (deliverable 3)
```

Features: `telemetry_ingest` (built), then `fleet`, `vehicle_detail`, `alerts`,
`geofences`, `trips`.

The dependency rule is the whole point: `domain` imports nothing from `data` or
`presentation`. `IngestController` depends on four use cases and has never heard
of DuckDB, isolates or the simulator, which is why its tests run against a fake
repository with no database in sight. The concrete classes are named in exactly
one place, the feature's `Bindings`.

`Result<T>` is a sealed union in `core/utils`, not `dartz`'s `Either`. Dart 3
sealed classes plus exhaustive `switch` give the same "you cannot read the value
without handling the failure" guarantee without a functional-programming
dependency for one type.

### State management

GetX. `GetMaterialApp`, one `GetxController` per screen, `.obs` fields read
inside `Obx`. Bindings construct the object graph; the controller receives use
cases through its constructor rather than calling `Get.find` internally, so it
is directly constructible in a unit test.

One wrinkle worth naming: opening DuckDB and spawning the writer isolate are
both async, and GetX's `Bindings.dependencies()` is not. So `IngestBinding`
exposes `dependenciesAsync()`, which `main()` awaits before `runApp`. The
alternative — a controller that builds before its writer exists — means a
"not ready" state on every screen that never means anything useful.

### Isolates

DuckDB is a single-writer, MVCC embedded engine. One process, so multiple connections against one instance are fine — readers get a snapshot while the writer commits.

- **Writer isolate** (`TelemetryWriter`) — owns ingest, derivation, backfill. Everything that mutates runs here, serialised, in transactions. Spawned once at startup and kept: `Isolate.run` per batch would cost more than the write it performs. Requests carry their own reply port, so there is no request-id bookkeeping.
- **UI isolate** — read-only connection, queries on demand and after each batch. A 3-hour backlog dump must not repaint the fleet list 500 times, so once the fleet list exists this becomes a *debounced* change ping (250 ms) rather than a refresh per batch.

`dart_duckdb` exposes a transferable database handle for exactly this. Ingest batches are bounded (≤ 5k rows / 200 ms per transaction) so a backlog dump never holds a write lock long enough to stall reads.

---

## 2. Schema

Location is deliberately **not** a signal. Pairing `lat` and `lon` rows by timestamp is pointless work, and every geofence query wants them side by side.

```sql
CREATE TABLE vehicle (
  vehicle_id TEXT PRIMARY KEY,
  reg_no     TEXT NOT NULL,
  model      TEXT NOT NULL
);

-- append-only event log; the source of truth
CREATE TABLE signal_reading (
  vehicle_id TEXT NOT NULL,
  signal     TEXT NOT NULL,        -- soc | speed | battery_temp | odometer | range_km | ignition
  event_ts   TIMESTAMP NOT NULL,   -- from the packet
  value      DOUBLE  NOT NULL,     -- booleans as 0/1
  ingest_ts  TIMESTAMP NOT NULL,   -- audit only, never drives logic
  PRIMARY KEY (vehicle_id, signal, event_ts)
);

CREATE TABLE location_fix (
  vehicle_id  TEXT NOT NULL,
  event_ts    TIMESTAMP NOT NULL,
  lat DOUBLE NOT NULL, lon DOUBLE NOT NULL,
  accuracy_m  DOUBLE,
  ingest_ts   TIMESTAMP NOT NULL,
  PRIMARY KEY (vehicle_id, event_ts)
);

-- 500 vehicles x ~6 signals = ~3k rows. The whole read path lives here.
CREATE TABLE vehicle_signal_latest (
  vehicle_id TEXT NOT NULL,
  signal     TEXT NOT NULL,
  event_ts   TIMESTAMP NOT NULL,
  value      DOUBLE NOT NULL,
  PRIMARY KEY (vehicle_id, signal)
);

-- config as data, not as Dart constants: the UI, the verdict pills and the
-- alert evaluator all read the same row.
CREATE TABLE signal_spec (
  signal TEXT PRIMARY KEY,
  label TEXT, unit TEXT,
  max_age_sec INTEGER,      -- older than this => STALE
  warn_lo DOUBLE, warn_hi DOUBLE,
  crit_lo DOUBLE, crit_hi DOUBLE
);

CREATE TABLE geofence (
  geofence_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  lat DOUBLE, lon DOUBLE, radius_m DOUBLE,
  active_from TIMESTAMP NOT NULL,     -- activation is time-versioned
  active_to   TIMESTAMP,              -- NULL = still active; deactivated fences are retained
  updated_at  TIMESTAMP NOT NULL
);

CREATE TABLE alert (
  alert_id TEXT PRIMARY KEY,          -- deterministic: hash(vehicle_id, type, raised_at)
  vehicle_id TEXT NOT NULL,
  alert_type TEXT NOT NULL,           -- battery_low (escalating) | battery_overheat
  severity   TEXT NOT NULL,           -- warning | critical
  raised_at  TIMESTAMP NOT NULL,      -- event time
  escalated_at TIMESTAMP,
  resolved_at  TIMESTAMP,
  dismissed_at TIMESTAMP,
  dismiss_reason TEXT
);

-- derived, fully recomputable
CREATE TABLE geofence_transition (
  vehicle_id TEXT, geofence_id TEXT,
  event_ts TIMESTAMP,                 -- time of the crossing fix, not the confirming fix
  kind TEXT,                          -- ENTRY | EXIT
  confidence TEXT,                    -- high | low (crossed a data gap)
  PRIMARY KEY (vehicle_id, geofence_id, event_ts)
);

CREATE TABLE trip (
  trip_id TEXT PRIMARY KEY,           -- deterministic: hash(vehicle_id, start_ts)
  vehicle_id TEXT NOT NULL,
  origin_geofence_id TEXT, start_ts TIMESTAMP NOT NULL,
  dest_geofence_id   TEXT, end_ts   TIMESTAMP,
  status TEXT NOT NULL,               -- IN_PROGRESS | COMPLETED
  distance_km DOUBLE,                 -- odometer delta, NULL if unavailable
  confidence TEXT
);

CREATE TABLE ingest_watermark (
  vehicle_id TEXT PRIMARY KEY,
  processed_through TIMESTAMP NOT NULL
);
```

`signal_reading` is the only large table. Its 3-column ART primary key is what makes duplicate rejection O(log n) instead of a table scan — and it is the first thing I will look at if memory at rest disappoints (see §8).

---

## 3. Offline-first: who owns which row

Local-first is not "a cache with a sync button". The design question is **who owns the truth for each row**, because that one classification decides the sync direction, the conflict rule, the transaction boundary, and whether the table can simply be thrown away and rebuilt. Every table in §2 belongs to exactly one of three classes.

| Class | Tables | Origin | Sync | Conflict | On migration / loss |
|---|---|---|---|---|---|
| **R** — remote-authoritative, immutable | `vehicle`, `signal_reading`, `location_fix` | the trucks | pull, cursored | impossible by construction | re-pullable |
| **L** — device-authored intent | `geofence`, `alert.dismissed_at`/`dismiss_reason` | the operator, on this device | push, via outbox | per-table rule, never a blanket policy | **the only data that can actually be lost** |
| **D** — derived | `vehicle_signal_latest`, `geofence_transition`, `trip`, alert raise/resolve state | this device, from R + L | never synced | n/a | dropped and rebuilt |

### 3.1 Class R — append-only, natural key, cursored pull

Rows are immutable and identified by a natural key (`(vehicle_id, signal, event_ts)`, `(vehicle_id, event_ts)`), written with `INSERT … ON CONFLICT DO NOTHING`, and the pull cursor advances **in the same transaction as the rows it covers**.

That combination buys the property offline-first actually needs: **at-least-once delivery is sufficient, because the write is idempotent.** No exactly-once protocol, no ack dance. Crash between fetch and commit? Re-pull the page; the constraint absorbs it. Dedupe is the *side effect* of the natural key, not its purpose.

Class R is never row-updated. DuckDB is an OLAP engine — a per-row `UPDATE` or `DELETE` against a 2 M-row table is a rewrite, not an in-place poke. Confining all mutation to tables of a few thousand rows (`vehicle_signal_latest`, `alert`, `geofence`, per-vehicle slices of the derived tables) is not incidental tidiness; it is the reason the schema is shaped this way.

### 3.2 Class L — the outbox

```sql
CREATE TABLE outbox (
  op_id      TEXT PRIMARY KEY,   -- UUIDv7: idempotency key AND total order, client-generated
  entity     TEXT NOT NULL,      -- geofence | alert_dismissal
  entity_id  TEXT NOT NULL,
  op         TEXT NOT NULL,      -- upsert | delete
  payload    JSON NOT NULL,
  created_at TIMESTAMP NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  synced_at  TIMESTAMP           -- NULL = pending
);
```

Three rules make this work:

1. **The entity row and its outbox row are written in one transaction.** This is the whole reason the outbox exists. "Saved locally but never queued" is not a state the database can be in.
2. **`op_id` is the server's idempotency key.** A retry after an ambiguous timeout is free. UUIDv7 sorts by creation time, so per-entity replay order is the key order — no sequence table.
3. **Coalesce pending ops per `entity_id`.** A week in a basement dismissing and un-dismissing the same alert must not queue a week of operations.

**Conflict resolution is per table, not global.** A blanket last-writer-wins is a smell, and the two Class L tables want opposite rules:

- **`geofence` → LWW on `updated_at`.** A fence has one current shape; the most recent edit is the intended one.
- **`alert` dismissal → earliest wins.** A dismissal is a monotonic acknowledgement — "someone was on this at T". LWW would let a device that reconnects later overwrite the fact that a colleague had already picked it up, which is exactly the information the dismissal exists to carry.

### 3.3 Class D — disposable on purpose

Derived tables are never synced, never backed up, and **never migrated**: any schema change drops and rebuilds them from R + L. That removes them from the migration surface entirely, which is most of the schema. It is also what makes the §0 replay property operationally useful rather than merely elegant — "rebuild" is a supported, exercised code path, not a theory.

### 3.4 Transaction boundaries and crash recovery

Ingest is deliberately **two** transactions, not one:

1. append Class R rows · advance `vehicle_signal_latest` · advance the pull cursor
2. derive alerts / transitions / trips · advance `ingest_watermark`

Splitting them keeps a long recompute from holding a write lock across the whole batch, and it enforces the ordering that matters: **the watermark advances last, so derived state is always behind the log and never ahead of it.**

The payoff is that there is no recovery routine. A crash between the two transactions leaves log rows with no derivation — which is byte-identical to the state during normal operation, and is repaired by the same "derive from watermark" call that every batch makes. Crash recovery is indistinguishable from ordinary incremental work, so it is tested by every test rather than by a special one nobody runs.

### 3.5 Migrations on a device you cannot reach

`schema_version` table, forward-only, applied on open before any query. The class split does most of the work: **D** is dropped and rebuilt, **R** can be re-pulled from cursor zero if a migration would be gnarly, and **L** — the only data with no upstream copy — is small enough to migrate by hand and carefully.

### 3.6 What can actually be lost

Only unsynced outbox rows, and only if the database file becomes unopenable. Everything in R is re-pullable and everything in D is re-derivable. The mitigation is draining the outbox eagerly whenever connectivity exists, not mirroring it into a second store — a second store is a second thing to corrupt.

### 3.7 The seam in this build

There is no backend (§11), so: the cursor mechanism is real, because the packet simulator is a replayable, positioned source and ingest advances a genuine cursor against it. The outbox is **designed, not built** — it is one table and one drain loop, and until a server exists it would be a queue with no consumer. Swapping the simulator for an HTTP or MQTT source is a constructor argument; adding the outbox is the second commit after that.

---

## 4. Ingest

Two transactions per batch in the writer isolate, split as in §3.4 — steps 1–3 commit, then steps 4–6 commit.

1. **Dedupe within the batch** — keep `max(event_ts)` per `(vehicle_id, signal)`.
2. **Append** — `INSERT … ON CONFLICT DO NOTHING`. Idempotency is now a database constraint, not a code path.
3. **Advance latest** — the only tricky upsert. A late packet must never clobber a newer reading:

```sql
INSERT INTO vehicle_signal_latest AS l (vehicle_id, signal, event_ts, value)
SELECT vehicle_id, signal, event_ts, value FROM batch
ON CONFLICT (vehicle_id, signal) DO UPDATE
  SET value = excluded.value, event_ts = excluded.event_ts
  WHERE excluded.event_ts > l.event_ts;
```

4. **Detect regression** — if `min(event_ts)` in the batch for a vehicle is older than its `ingest_watermark`, that vehicle needs a replay from `min(event_ts) − lookback`. Otherwise, incremental derivation from the watermark forward.
5. **Derive** — alerts, transitions, trips (§6, §7).
6. **Advance watermark**, commit, ping the UI. The watermark moves last, so a crash here leaves log rows underived — repaired by the next batch's step 4 with no special-case code.

Derivation runs **in SQL**, not Dart. Pulling the log into Dart to fold over it is precisely the in-memory-shadow the brief rules out, and it makes recompute over a large window unaffordable. The rules (hysteresis, debounce, thresholds) live in config tables so tests can vary them without touching SQL.

The batch reaches SQL through two TEMP **staging tables** that the writer bulk-appends into with DuckDB's row-wise appender — no statement per row, no parameter binding, no escaping vehicle ids into SQL text. Everything after that is set-based: intra-batch de-duplication is a `DISTINCT ON`, not a Dart loop, and `ON CONFLICT DO NOTHING` against the natural key does the rest.

---

## 5. Fleet list

The whole read path is ~3k rows, so the query is trivially fast and no caching is warranted.

```sql
WITH p AS (
  SELECT vehicle_id,
         max(event_ts)                                   AS last_ping,
         max(value)    FILTER (WHERE signal = 'soc')           AS soc,
         max(event_ts) FILTER (WHERE signal = 'soc')           AS soc_ts,
         max(value)    FILTER (WHERE signal = 'speed')         AS speed,
         max(event_ts) FILTER (WHERE signal = 'speed')         AS speed_ts,
         max(value)    FILTER (WHERE signal = 'ignition')      AS ignition,
         max(event_ts) FILTER (WHERE signal = 'ignition')      AS ignition_ts,
         max(value)    FILTER (WHERE signal = 'range_km')      AS range_km
  FROM vehicle_signal_latest GROUP BY vehicle_id
)
SELECT v.reg_no, v.model, p.soc, p.range_km,
  CASE
    WHEN p.last_ping IS NULL OR p.last_ping < $now - INTERVAL 10 MINUTE THEN 'OFFLINE'
    WHEN p.speed    > 0 AND p.speed_ts    >= $now - INTERVAL 5 MINUTE   THEN 'MOVING'
    WHEN p.speed    = 0 AND p.speed_ts    >= $now - INTERVAL 5 MINUTE
     AND p.ignition = 1 AND p.ignition_ts >= $now - INTERVAL 5 MINUTE   THEN 'IDLE'
    ELSE 'STOPPED'
  END AS status
FROM vehicle v LEFT JOIN p USING (vehicle_id);
```

`last_ping` is `max(event_ts)` over all signals **and** location fixes for that vehicle. Filter chip counts are `GROUP BY status` over the same CTE — one query, computed in SQL, never in Dart.

---

## 6. Alerts

An alert row is an **episode**: one continuous period during which a rule was
breached on a vehicle. `severity` moves within the episode; `resolved_at` ends
it. Open means `resolved_at IS NULL AND dismissed_at IS NULL`, defined once in
`alert_sql.dart` and read by the fleet badge and the alerts screen alike.

| Alert | Condition | Severity |
|---|---|---|
| `battery_low` | SOC < 20 % | warning |
| `battery_low` | SOC < 10 % | **critical** (same row, escalated) |
| `battery_overheat` | battery_temp > 45 °C | critical |

The two SOC bands are one row whose `severity` moves warning ⇄ critical.
Recovering from 8 % to 15 % de-escalates in place; it does not resolve and
re-raise. `escalated_at` is stamped on the way up and kept afterwards.

**The evaluator** runs after every ingest batch, in the same transaction as the
watermark, as four statements in a fixed order: read what we can currently see
from fresh readings, resolve what we watched come back inside, rescore what is
still breached, raise what is new. Resolve before raise, so a condition that
clears and re-triggers inside one batch closes one episode and opens another.
`raise` is guarded by `NOT EXISTS` over open episodes, so the pass is
idempotent — which is what lets it run unconditionally and what will let a
late-suffix replay reuse it.

Freshness is applied *inside* the condition set: each reading is nulled out if
it is older than its own `signal_spec.max_age_sec`, so "thresholds apply to
fresh readings only" is a property of the data the rules read rather than a
clause each rule remembers.

**An episode ends when we watch it end, not when we stop looking.** A reading
going quiet leaves the episode open — no reading is not evidence of recovery —
and the card says "no fresh reading for 20m · last known 5 %". Resolution needs
a fresh reading that is back inside the threshold by more than a hysteresis
band of 2 (points of SOC, degrees of temperature). Without the band a truck
idling at 45.2 °C opens and closes the same alert on every wobble: a measured
simulator run produced **seven episodes on one vehicle in 114 seconds**. Since
nothing in the lifecycle moves without a fresh reading, the evaluator needs no
idle timer — time alone is not evidence.

**Dismissal.** Sheet order is fixed: *I am on it* · *Wrong alert* · *Something
else…*, read straight off the enum so the screen cannot drift from it. The
dismissal is written to DuckDB immediately and UNDO clears `dismissed_at`. It
is not held in memory for 5 seconds — local-first means the database is the
truth, and if the app dies mid-window the dismissal stands. That is the honest
trade; the alternative loses a user's explicit action to a crash.

**Resolution is independent.** The evaluator clears an alert when its condition
clears, dismissed or not. A dismissed alert whose condition never clears stays
hidden until the condition clears and re-triggers — dismissal suppresses the
*episode*, not the *rule*.

**The fleet badge reads this table**, rather than recomputing thresholds in
`scoredCte`. One rule in one place, and a dismissed alert stops showing a red
dot on the list. The cost is that the badge is derived state: it lags the log
by one derivation pass and can never lead it (§3.4).

See [docs/04-alerts.md](docs/04-alerts.md).

---

## 7. Geofences and trips

### 7.1 Transition detection

Deterministic pipeline, applied per `(vehicle, geofence)` over event-time-ordered fixes:

Built, as `lib/db/geofence_sql.dart`. See [docs/05-geofences.md](docs/05-geofences.md).

1. **Accuracy gate** — discard fixes with `accuracy_m > 100`. Filtered at read; nothing is ever deleted from the log.
2. **Hysteresis** — inside if `d ≤ r − h`, outside if `d ≥ r + h`, with `h = max(25 m, accuracy_m)`. Fixes in the band produce **no zone opinion**.
3. **Carry forward** — `last_value(zone IGNORE NULLS) OVER (PARTITION BY vehicle_id, geofence_id ORDER BY event_ts)`. The band is now genuinely inert rather than a source of flapping.
4. **Confirm** — a crossing is confirmed when two consecutive opinionated fixes agree on the new zone. Escape hatch for a fast exit: one fix more than `2h` past the boundary confirms alone.
5. **Timestamp** — the transition is stamped with the **first** fix of the confirming pair. That is when the vehicle actually crossed.
6. **Gaps** — if the confirming pair straddles a gap > 30 min (the basement case), the transition is still recorded but flagged `confidence = 'low'`, and any trip built on it inherits that flag. Nothing is synthesised across a gap.
7. **Overlaps** — no single "current geofence" internally; containment is per fence. The UI's single-value *current geofence* is the **smallest radius containing the vehicle**, tie-broken by `geofence_id`.
8. **Fence activation** is time-versioned via `active_from` / `active_to`, so evaluation asks "was this fence active at the fix's event time" and recompute stays pure. **Geometry is not versioned** — editing centre or radius triggers a full recompute of that fence's transitions and the affected trips. Full geometry versioning is the upgrade if fences turn out to be edited often; it is not worth the table for this exercise.

All of steps 2–6 are expressible with `lag`/`last_value IGNORE NULLS` window functions — set-based, no row-at-a-time Dart fold. They are.

**One addition the build made.** A pass that starts at the batch would have to re-read a vehicle's whole history to know which zone was established before it, which defeats the point. `geofence_containment` holds, per (vehicle, fence), the confirmed zone *and* the last fix that had an opinion at all; the detector injects that as a synthetic first row, so a batch costs two fixes of work instead of a history. A batch reaching back behind the vehicle's watermark invalidates that seed, and the vehicle is replayed from the beginning of its log instead — §4 step 4 with `t0` collapsed to the whole vehicle, because a per-fix `t0` would need a containment *history*, which is a table this does not earn. The equivalence is asserted directly: fix-by-fix derivation lands on byte-identical state to one pass over the finished log.

The same table answers the UI's two questions — which fence a truck is in, and how many are in each fence — so it is not overhead the detector imposed on the rest of the app.

### 7.2 Trips

Built, as `lib/db/trip_sql.dart`. See [docs/06-trips.md](docs/06-trips.md).

A nested fence must not manufacture a trip: leaving a bay while still inside the depot is not a departure. So trips key off **containment count**, not individual fences:

```sql
SELECT *, sum(CASE kind WHEN 'ENTRY' THEN 1 ELSE -1 END)
            OVER (PARTITION BY vehicle_id ORDER BY event_ts) AS inside_count
FROM geofence_transition
```

- `inside_count` falling to **0** → trip starts; origin = the fence just exited.
- `inside_count` rising off 0 → active trip completes; destination = the fence just entered. Returning to origin is a normal completion.
- Still 0 at the end of the stream → `IN_PROGRESS`. No timeout; a truck that never reports again keeps an open trip, which is the truthful representation.
- One active trip per vehicle falls out of the model for free.
- Incremental recompute seeds `inside_count` from the containment state at the window start.

`distance_km` comes from an `ASOF JOIN` onto the odometer log at `start_ts` and `end_ts`; NULL when the odometer is missing rather than guessed.

**Idempotency.** `trip_id = hash(vehicle_id, start_ts)`, so a duplicate packet regenerates the identical row. A late packet that moves a boundary is handled by the replay in §4 step 4 — delete derived rows at or after `t0`, re-derive — with the deterministic id as the backstop, not the mechanism.

**Two things the build changed.** The incremental seed above was not built, and deliberately: `geofence_transition` holds a handful of rows per truck per day where `location_fix` holds thousands, so the resume machinery that earns its place in §7.1 would buy nothing here and would add a seam that can disagree with itself. Trips are deleted and rebuilt for the **whole vehicle**, from its whole crossing log, for every vehicle a batch touched. Duplicates, late packets and fence edits then need no handling at all — they are already handled one layer down, in the crossings.

The seed is still needed, just not as a table. The detector emits no transition for the zone it establishes on a cold start, so a truck that was already inside the depot has an EXIT with no matching ENTRY, and a count starting at zero would go to −1 and lose the trip. The count before the first crossing is recovered arithmetically as *inside now, minus the net of every crossing since* — exact, and one scalar subquery rather than a history.

Simultaneous crossings are collapsed per event time before the running sum, because leaving a bay and the depot around it can be confirmed off one fix and a sum stepping through them one at a time dips through a spurious zero. Among crossings sharing an instant the fence named is the largest: a truck that leaves Bay 3 and Whitefield Depot together departed from the depot.

---

## 8. Scale

Built. Measured numbers, method and device are in
[docs/07-scale.md](docs/07-scale.md); this section is the plan they were taken
against, with the two places the plan turned out to be wrong marked.

**Backfill.** 500 vehicles × 6 signals × ~700 ticks ≈ 2.1 M rows, generated **inside DuckDB** with `range()` in a single `INSERT … SELECT`. Generating rows in Dart and pushing them across the FFI boundary would take minutes; this takes seconds. Deterministic expressions rather than `random()` in the end, so re-running the backfill inserts nothing and the fleet list fills with plausible numbers instead of noise.

**Wrong, and measured:** the plan said the table would be created without its primary key, bulk-loaded, then indexed once. The trick is real — 606 ms against 2467 ms for the same 2.1 M rows on this machine, four times faster — but it cannot be applied, because `signal_reading` is created with its primary key in migration v1 and DuckDB 1.2.1 answers `ALTER TABLE … DROP CONSTRAINT` with "No support for that ALTER TABLE option yet". Forking the schema for a debug action is not worth 3.7 seconds, so the backfill keeps the constraint and pays for it.

**Measurements to report.** Taken on a MacBook Pro (M1 Pro, 16 GB, macOS 26.6.2) in release: cold start **1.3–1.5 s**, fleet query warm **p50 10.1 ms / p95 12.5 ms**, memory at rest **234 MB**. All three inside target, on a desktop — there is no `ios/` directory in this project and no Android AVD on the machine, so a phone number is missing and said to be missing. The plan:

| Metric | How | Target |
|---|---|---|
| Cold start → first painted fleet list | stopwatch from `main()`, stopped in `addTimingsCallback` on first frame with data | < 2.5 s |
| Fleet-list query p50 / p95, warm | 100 runs in the writer isolate, dumped to CSV | p95 < 25 ms |
| Memory at rest, list open | `adb shell dumpsys meminfo` PSS, DevTools cross-check | < 250 MB |

If a number is bad it gets reported as bad, with a diagnosis. The two I already expect to be the suspects:

- **Cold start** is dominated by opening the database and loading the ART index, not by the query. Mitigation: open and run the fleet query in the writer isolate before the first frame and paint a skeleton.
- **Memory at rest** is dominated by that same index on a 2 M-row table. If it dominates, the fix is to drop the primary key and dedupe with an ANTI JOIN against a bounded recent window — duplicates only ever arrive near the present, so a full-history index earns nothing.

**Retention.** An append-only log grows forever, so:

- `signal_reading` keeps 7 days at full resolution.
- Older data is downsampled into 5-minute buckets per `(vehicle, signal)` — min/max/avg/last — and the raw rows are dropped, followed by `CHECKPOINT`.
- **Wrong, and measured:** a bucket holding a *single* reading must be left alone. The first implementation rolled every old reading up regardless, and on a log sparser than the bucket width that turned 1 050 000 readings into 1 050 000 rows carrying four more columns each — the database grew by 126 MiB. Built as `HAVING count(*) > 1`.
- DuckDB reuses freed blocks rather than returning them to the OS, so the *file* never shrinks. The number that moves is bytes in use, and both are reported.
- Derived tables (transitions, trips, alerts) are small and kept indefinitely.
- **What is lost:** sub-5-minute shape of old data, and the ability to *recompute* geofence transitions outside the hot window. Trip replay is therefore bounded to 7 days; a late packet older than that is rejected and counted, not silently applied.

---

## 9. Tests

The suite is built around the invariant from §0, not around line coverage.

**The test that matters:** generate a packet stream, shuffle it, inject duplicates and delays, replay it, and assert the derived state — latest values, alerts, transitions, trips — is identical to the in-order replay. If that holds, the concurrency and late-data story holds.

Around it, fixture-driven SQL tests against an in-memory DuckDB (fast, no Flutter binding):

- duplicate packet · out-of-order packet · backlog dump
- GPS jitter parked on the boundary → **zero** transitions
- fast exit confirmed by a single distant fix
- data gap → transition present, `confidence = 'low'`
- nested fences → exiting the inner bay starts no trip
- return-to-origin trip completes
- fence geometry edit → transitions and trips recomputed
- fence deactivated → prior transitions retained, no new ones
- SOC 18 → 8 escalates in place (one alert row, not two)
- dismiss then escalate → alert reappears
- condition clears while dismissed → resolved
- signal goes stale while alerting → **not** resolved
- never-reported signal → "—", no pill

Plus widget tests for the fleet list statuses and chip counts, the dismissal sheet ordering and the 5-second undo, and one integration test that backfills 10 vehicles and asserts row counts and query sanity.

---

## 10. Ambiguities and how they are resolved

The brief says the data model has genuinely ambiguous cases. These are the ones I found and the calls I made.

| # | Ambiguity | Resolution | Rejected alternative |
|---|---|---|---|
| 1 | Vehicle is online (odometer 2 min old) but `speed` is 40 min old. MOVING? | Status only reads **fresh** signals; a stale speed cannot claim MOVING or IDLE, so it falls through to STOPPED, the documented fallback bucket. "Fresh" here means the **10-minute OFFLINE window**, not the 5-minute per-signal one — see ambiguity 14. | A sixth `UNKNOWN` chip — the brief specifies five. |
| 2 | What is "last ping"? | `max(event_ts)` across all signals *and* location fixes for the vehicle. | Per-signal freshness only — the brief says vehicle-level. |
| 3 | Event time or arrival time? | **Event time** drives every rule: freshness, status, alerts, transitions, trips. `ingest_ts` is audit only. | Arrival time — makes a backlog dump look like a fleet that just woke up. |
| 4 | What is a duplicate? | Identity is `(vehicle_id, signal, event_ts)`. Same key, different value → keep the first, increment a conflict counter surfaced in a debug view. | Last-write-wins — non-deterministic under reordering, which breaks §0. |
| 5 | Packet older than the retention window | Rejected and counted. It cannot be replayed correctly, so applying it would produce state that no longer follows from the log. | Silently inserting it and leaving derived state inconsistent. |
| 6 | Signal goes stale while an alert is open | Alert stays open; the card reads "no fresh reading for 20m · last known 5 %". Resolution requires a fresh reading back inside the threshold, so no reading is never mistaken for recovery. **Built as specified** — the first implementation auto-resolved on staleness and had to be reversed. | Auto-resolve — that hides a truck that died at 5 % SOC. |
| 7 | Dismissed at 18 %, then SOC hits 8 % | Escalating to critical clears `dismissed_at` and `dismiss_reason` on the same row. "I am on it" at 18 % is not consent to ignore 8 % — the user answered a question about a warning, and this is no longer that warning. | Staying dismissed through escalation. |
| 8 | UNDO window vs. app kill | Dismissal is persisted immediately; UNDO clears it. Killed mid-window → dismissal stands. | Holding it in memory for 5 s — loses an explicit user action to a crash. |
| 9 | Geofence edited after history exists | Activation is time-versioned; **geometry is not** — saving a fence recomputes transitions. Built to recompute *every* fence rather than only the edited one: derived state is dropped and rebuilt (§3.5), and one path that is always right beats two that are usually right. Reactivating opens a *new* active window, so the period a fence was off stays off in any recompute. | Full geometry versioning (correct, more table than this earns) or forward-only edits (cheap, but derived state stops being reproducible from the log). |
| 10 | Vehicle inside two overlapping fences | Containment tracked per fence. The UI's "current geofence" is a *query* — smallest radius containing it, tie-broken by `geofence_id` — not a stored field, so it cannot go stale against containment. | A single current-fence column — undefined under nesting, and a second thing to keep in step. |
| 11 | Exiting a bay inside a depot | Trips key off containment count reaching 0, so leaving the inner fence starts nothing. | Per-fence exit starts a trip — one departure would produce two trips. |
| 12 | Trip whose vehicle never reports again | Stays `IN_PROGRESS` forever. | A 24-hour abandonment timeout — invents an ending the data does not support. |
| 14 | Which freshness window does the status ladder use? | The **vehicle-level 10-minute** window that decides OFFLINE, because status is a vehicle-level claim. The alert badge and the detail-screen verdict pills keep the **per-signal** `signal_spec.max_age_sec`, because a threshold is a claim about one signal. | One window for everything. Scoring the ladder against the 5-minute signal window leaves a dead band between 5 and 10 minutes where an online, visibly moving truck reads STOPPED — caught by a test, not by reasoning. |
| 15 | A reading oscillating across a threshold | Resolution needs the value back inside by a **hysteresis band** of 2 (points of SOC, degrees of battery temperature); severity within an open episode moves on the bare thresholds. Found by measurement, not reasoning: a real run produced seven overheat episodes on one truck in 114 seconds. | Bare `value > threshold` for both raising and resolving — makes `raised_at` a lie and the episode record useless. |
| 13 | GPS jitter on the boundary | 25 m (or accuracy, whichever larger) hysteresis band plus two-fix confirmation; band fixes carry the previous zone forward. | Bare `d < r` — flaps a parked truck into dozens of trips. |
| 16 | Fence deactivated while a vehicle is inside it | Containment keeps the last zone it was confirmed in, so that vehicle's count never returns to zero and it starts no further trips. Same principle as ambiguity 6 — an episode ends when we watch it end — and here the principle costs something real. Recorded rather than fixed: every alternative invents a fact. | An implicit exit at `active_to` (manufactures a departure out of a fence edit) or excluding deactivated fences from derivation (retroactively deletes the trips that named them, which is exactly what keeping deactivated fences was for). |

---

## 11. Scope cuts

Stated up front, per the brief.

- **No backend, no auth, no sync.** The packet source is a simulator behind a one-method interface; a real MQTT/HTTP feed is a constructor swap.
- **No map tiles in v1.** Geofences are created and edited by name / lat / lon / radius with a schematic canvas preview. `flutter_map` goes in only if time remains after tests — it is presentation, and every ambiguity above is decided without it.
- **No background ingest while the app is killed.** No foreground service, no WorkManager.
- **No severity/escalation audit trail.** The alert row carries `escalated_at`; the full state-change log is a table I would add the moment anyone asked "why did this fire".
- **No i18n, no custom theme.** Material 3 defaults.
- **The simulator moves vehicles across the ground 30x faster than their speed signal implies** (`SimulatorConfig.groundScale`). A truck at 60 km/h really does cover eight metres in a 500 ms tick, which means a geofence demo would need twenty minutes to show one crossing. The scale applies to latitude and longitude only — speed, odometer and battery drain stay consistent with each other and with the honest figure — and setting it to 1 gives a physically consistent feed.

---

## 12. Deliverables plan

**Commits** — phased, in my own words, no squash: schema → ingest + dedupe → fleet list → vehicle detail + verdicts → alerts → geofences → transitions → trips → backfill + bench → tests → README.

**README** — run the app, run the tests, 30-second feature tour, plus the measured numbers from §8 and the device they came from.

**AI logs** — `ai-logs/`, uncurated, committed as work proceeds so the dead ends stay in the history rather than being tidied away at the end. `tool/export_ai_logs.sh` converts the raw Claude Code session transcripts (`~/.claude/projects/<slug>/*.jsonl`) into chronological markdown. Two practical notes: run Claude from the project root so its sessions land in one slug directory, and export after every session — the transcripts are the deliverable, and a curated summary is explicitly not what was asked for.
