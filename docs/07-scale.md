# 07 — Scale exercise

500 vehicles, 2.17 million signal rows, and the three numbers the brief asks
for, measured on a named device with the method written down.

Covers the brief's §4.

## Files

```
lib/db/backfill_sql.dart      the generator, and the full re-derive after it
lib/db/retention_sql.dart     compaction, and what it deliberately will not do
lib/db/schema.dart            migration v3: signal_rollup
lib/core/utils/cold_start.dart  the stopwatch
lib/features/scale/presentation/  scale_controller · scale_page
docs/data/fleet-query-bench-macos.csv   all 100 samples behind the p95
```

## The debug action

Ingest monitor → **Scale exercise**. Three buttons: backfill, benchmark,
compact. Each one stops the telemetry feed first, because a measurement taken
while something else is writing measures both.

The same three run headless, which is how every number below was taken:

```bash
flutter run -d macos --release --dart-define=SCALE_BACKFILL=true
flutter run -d macos --release --dart-define=SCALE_BENCH=true
flutter run -d macos --release --dart-define=SCALE_COMPACT=true --dart-define=SCALE_KEEP_MINUTES=60
```

They print to stdout as `[scale] …`. Compile-time constants, so a build
without the defines contains none of it.

## The backfill

One `INSERT … SELECT` per table, `range()` cross-joined against itself. Nothing
leaves the engine — generating 2.17 M rows in Dart and pushing them across the
FFI boundary would take minutes.

Values are deterministic rather than `random()`, which buys two things: the
button is safe to press twice (every row collides with the natural key the
second time), and the fleet list fills with plausible numbers instead of noise.
The odometer is monotone in time, because a backwards odometer makes every trip
distance negative.

Reports land at a **10-second cadence**, so 700 reports per vehicle is about
two hours of dense history rather than two weeks of one reading every half
hour. Density is what makes the fleet list look like a fleet, and what gives
retention something to compress.

Loading the log is only half of it. A bulk load leaves every class D table
describing a fleet that no longer exists, so the backfill finishes by running
the same derivations ingest runs — latest values, alerts, geofences, trips,
watermark — over the whole log. §3.5 claims derived state is droppable and
rebuildable; this is that claim executed.

## The device

| | |
|---|---|
| Machine | MacBook Pro (MacBookPro18,3), Apple M1 Pro, 16 GB |
| OS | macOS 26.6.2 (25G83) |
| Build | Flutter 3.35.6, `flutter run -d macos --release` |
| Database | 540 vehicles · 2 168 764 signal rows · 361 416 location fixes |

**This is a desktop, and that matters.** An M1 Pro with 16 GB flatters every
number here — a mid-range Android phone has a fraction of the memory bandwidth
and a much smaller page cache. The project has no `ios/` directory and this
machine has no Android AVD, so macOS was the only target that could run the
real app; that is a limitation of the measurement, not a result. The numbers to
treat as load-bearing are the *ratios* and the diagnosis, not the absolutes.

## The numbers

### Cold start → first painted fleet list

`main()` starts a `Stopwatch`; the fleet page registers a one-shot
`addTimingsCallback` on the first build that has vehicles, and stops the clock
when that frame is rasterised. "With data" matters — stopping on the first
frame would measure the spinner.

| Launch | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| ms | 1318 | 1287 | 1433 | 1461 |

**≈1.3–1.5 s against a 2.17 M-row database. Target was 2.5 s.** The spread is
launch-to-launch page-cache variation, not load.

### Fleet-list query, warm

100 runs of **both** statements one refresh issues — the chip counts and the
rows — timed inside the writer isolate, rows fetched rather than merely
planned, after three untimed warm-up passes. All 100 samples are in
[`docs/data/fleet-query-bench-macos.csv`](data/fleet-query-bench-macos.csv); a
p95 with no distribution behind it is a number nobody can argue with.

| p50 | p95 | p99 | min | max |
|---|---|---|---|---|
| 10.06 ms | 12.48 ms | 15.75 ms | 8.51 ms | 20.27 ms |

**p95 12.5 ms against a target of 25 ms.** The query never touches the
2.17 M-row log: it reads `vehicle_signal_latest`, which is 3 240 rows. That is
the entire reason the number is flat — the latest-value table exists so the
fleet list's cost is a function of fleet size rather than of history.

Timed in the writer isolate on purpose. A query timed on the UI isolate between
two builds measures the frame scheduler as well.

### Memory at rest, list open

`footprint -p <pid>`, taken 90 seconds after launch with the fleet list open
and the simulator feed running — the app's actual resting state, not an idle
one.

| | |
|---|---|
| Settled | **234 MB** |
| Peak during launch | 383 MB |
| Peak during the backfill | 881 MB |

**Under the 250 MB target, but not comfortably.** `footprint` puts 150 MB of
it in `MALLOC_SMALL` with another 247 MB reclaimable — DuckDB's buffer pool and
the ART index on `signal_reading`'s three-column primary key, which is exactly
where §8 predicted it would be.

If this had to come down, the fix is the one already written down: drop the
primary key and dedupe with an ANTI JOIN against a bounded recent window.
Duplicates only ever arrive near the present, so an index over all of history
earns nothing. It is not done here because 234 MB is inside budget on this
machine and the change trades a database-enforced invariant — §0's whole
foundation — for memory that is not yet short.

The 881 MB backfill peak is a debug action loading 2.5 M rows in one
transaction, not a state the app reaches in use.

## Two things that were measured and were wrong

**The load-then-index trick could not be applied, and it is worth 4×.**
ARCHITECTURE.md §8 promised the table would be bulk-loaded without its primary
key and indexed once afterwards. Measured, on this machine, for the same
2.1 M rows:

| Method | Time |
|---|---|
| `INSERT` into a table that already has the PK | 2467 ms |
| `INSERT` into a plain table, then `CREATE UNIQUE INDEX` | 606 ms (230 + 376) |

Four times faster, and the backfill does **not** do it: `signal_reading` is
created with its primary key in migration v1, and DuckDB 1.2.1 answers
`ALTER TABLE … DROP CONSTRAINT` with *"No support for that ALTER TABLE option
yet"*. Applying the trick would mean forking the schema for a debug action. The
backfill pays 4288 ms instead, which is a one-off button press.

**The first retention implementation made the database bigger.** It rolled
every old reading into a five-minute bucket and dropped the raw rows — and on
the first backfill, whose reports were 29 minutes apart, every bucket held
exactly one reading. 1 050 000 readings became 1 050 000 buckets, each carrying
four more columns than the row it replaced, and the file grew from 148 MiB to
274.5 MiB. The fix is a `HAVING count(*) > 1`: a reading alone in its bucket is
already at the policy's resolution, so it stays where it is. There is a test
for it now.

## Retention policy

**`signal_reading` keeps 7 days at full resolution.** Everything older is
summarised per `(vehicle, signal)` into 5-minute buckets — count, min, max,
average and last — and the raw rows are dropped, followed by a `CHECKPOINT`.
min and max as well as average, because an average hides exactly the thing
anyone looks at old battery data for: how hot did it actually get.

**`location_fix` is dropped on the same horizon and not summarised.** The
average of two positions is not a position.

**Derived tables — transitions, trips, alerts, rollups — are kept
indefinitely.** They are small, and they are the only record of what the
dropped rows meant.

Measured on the real database. The demo holds about two hours of history, so
this run used a 60-minute window rather than 7 days; the policy is unchanged,
the window is a `--dart-define`:

| | |
|---|---|
| Readings dropped | 1 110 004 |
| Buckets written | 39 240 (**28:1**) |
| Position fixes dropped | 184 975 |
| Bytes in use | 185.8 MiB → **135.5 MiB** |
| File size | 260.0 MiB → 260.0 MiB |

The file does not shrink, and that is not a bug: DuckDB reuses freed blocks
rather than returning them to the operating system. *Bytes in use* is the
number that moves, which is why the screen reports both — showing only the file
size would make a working policy look broken.

### What the app loses

- **The sub-5-minute shape of old data.** A battery spike that lasted 90
  seconds nine days ago survives as that bucket's `max_value` and nothing else.
- **The ability to re-derive geofence transitions or trips outside the hot
  window.** A crossing needs individual fixes; the average of a latitude is not
  a position. This is why §10's ambiguity 5 rejects a packet older than the
  window and counts it, rather than applying it — applying it would produce
  derived state that no longer follows from the log.
- **Nothing already derived.** Trips and transitions from before the horizon
  are kept; only the ability to *recompute* them goes.

## Tests

| Claim | Test |
|---|---|
| six signals per vehicle per tick, all known to `signal_spec` | `backfill_test` |
| running the backfill twice inserts nothing | `backfill_test` |
| the odometer only ever increases | `backfill_test` |
| latest values, containment and the watermark are rebuilt from the log | `backfill_test` |
| the fleet query answers for every backfilled vehicle | `backfill_test` |
| readings inside the hot window are untouched | `retention_test` |
| older readings are summarised, then dropped | `retention_test` |
| a reading alone in its bucket is left where it is | `retention_test` |
| min and max survive the average | `retention_test` |
| position fixes are dropped, never summarised | `retention_test` |
| compacting twice finds nothing left to do | `retention_test` |

20 vehicles rather than 500 in the tests: the properties asserted are the same
at both sizes, and the numbers that only matter at 500 are measurements, which
belong in this document with the device they came from.

## Knowingly left undone

- **No phone or emulator measurement.** The project has no `ios/` directory and
  this machine has no Android AVD. Every number here is desktop, said plainly
  above rather than buried.
- **Compaction is manual.** A real build schedules it — on launch when the
  oldest row is past the horizon, or on a periodic task. The policy and the
  code are here; the trigger is a button.
- **No rollup reader.** `signal_rollup` is written and never read. The SOC
  history chart still queries `signal_reading` only, so a 30-day chart would
  show 7 days and stop. Reading both and stitching them is the obvious next
  step and is not done.
- **`vehicle_signal_latest` is why the query is fast, and it is not stressed.**
  A fleet of 50 000 vehicles would put 300 000 rows in it and this benchmark
  says nothing about that.
