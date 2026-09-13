# 01 — Telemetry ingest

Takes packets from a flaky link and gets them onto disk exactly once, in a way
that survives duplicates, reordering, dropped packets and hours-long backlogs.

Covers the brief's §2 (local-first over DuckDB) and supplies the data every
other feature reads.

## Files

```
lib/features/telemetry_ingest/
  domain/entities/         telemetry_packet · ingest_receipt · ingest_snapshot · fleet_vehicle
  domain/repositories/     telemetry_repository
  domain/usecases/         seed_fleet · observe_telemetry · ingest_packet_batch · get_ingest_snapshot
  data/models/             telemetry_packet_model (+ ingest_receipt_model)
  data/datasources/        telemetry_packet_source (interface)
                           simulated_packet_source + simulator_config
                           telemetry_writer_isolate
                           telemetry_local_data_source (interface + DuckDB impl)
  data/repositories/       telemetry_repository_impl
  presentation/            ingest_controller · ingest_binding · ingest_page
lib/core/db/database_pulse.dart
```

## Data flow

```
SimulatedPacketSource ──batch──▶ IngestController ──▶ IngestPacketBatch
  (Timer, UI isolate)                                      │
                                                           ▼
                                            TelemetryRepositoryImpl
                                                           │
                                            DuckDbTelemetryLocalDataSource
                                                           │
                                          ┌────────────────┴──────────────┐
                                          ▼                               ▼
                                  TelemetryWriter                   db.read
                                (writer isolate)                (UI isolate, MVCC)
                                          │                               ▲
                                          ▼                               │
                                       DuckDB ──────── DatabasePulse.ping ┘
```

## The writer

DuckDB permits one writer, so every mutation in the app funnels through one
long-lived isolate. It is spawned once at startup and kept — `Isolate.run` per
batch would cost more than the write it performs. Each request carries its own
reply port, which removes request-id bookkeeping entirely.

Reads use the UI isolate's own connection. DuckDB is MVCC, so a read sees a
consistent snapshot while the writer commits; the fleet list never blocks on a
backlog dump.

## One batch, step by step

The batch lands in two TEMP staging tables through DuckDB's row-wise appender —
no statement per row, no parameter binding, no escaping vehicle ids into SQL
text. Everything after that is set-based.

**Transaction 1 — the log and the latest values**

```sql
INSERT INTO signal_reading
SELECT vehicle_id, signal, event_ts, value, CAST(now() AS TIMESTAMP)
FROM (SELECT DISTINCT ON (vehicle_id, signal, event_ts) * FROM staging_signal
      ORDER BY vehicle_id, signal, event_ts)
ON CONFLICT DO NOTHING;
```

`DISTINCT ON` collapses duplicates *within* the batch. `ON CONFLICT DO NOTHING`
against the natural primary key `(vehicle_id, signal, event_ts)` collapses them
against everything already on disk. Re-delivering a packet is a no-op enforced
by the database, not by application code — which is why at-least-once delivery
is all this pipeline ever needs.

```sql
INSERT INTO vehicle_signal_latest AS l
SELECT vehicle_id, signal, event_ts, value
FROM (SELECT DISTINCT ON (vehicle_id, signal) * FROM staging_signal
      ORDER BY vehicle_id, signal, event_ts DESC)
ON CONFLICT (vehicle_id, signal) DO UPDATE
  SET value = excluded.value, event_ts = excluded.event_ts
  WHERE excluded.event_ts > l.event_ts;
```

That `WHERE` is the entire late-packet story for the read path. A packet that
arrives late but measures an older moment is appended to the log and leaves the
current value alone.

**Transaction 2 — the derivation position**

Counts the vehicles whose batch reaches back behind the watermark (the replays
geofences and trips will need), then advances the watermark, guarded the same
way so a late batch cannot drag it backwards.

Splitting the two keeps a long recompute from holding a write lock across the
whole batch, and enforces the ordering that matters: **the watermark advances
last, so derived state is always behind the log and never ahead of it.** A
crash between the two leaves log rows with no derivation — which is identical
to the state during normal operation and is repaired by the same "derive from
watermark" call every batch makes. There is no recovery routine.

## The simulator

A fake fleet on a deliberately bad link. Every random decision comes from one
seeded generator, so a run replays exactly and a failing test can be repeated.

| Fault | How it is produced | What it tests |
|---|---|---|
| Retransmit | The same packet queued for release a tick or two later | Cross-batch dedupe, not just the easy within-batch case |
| Out of order | Packet held back, original `event_ts` kept | The conditional upsert and the late-vehicle counter |
| Loss | Packet never emitted | That gaps are tolerated rather than interpolated |
| Backlog | Vehicle goes dark for N ticks, buffers, then dumps in one burst | Bounded batches, and the UI surviving a burst |

Vehicles report signals on different cadences — speed and ignition every tick,
SOC every second, battery temperature every third, odometer every fourth — so a
packet carries a *subset* of signals. That is not decoration: it is the reason
freshness has to be tracked per signal rather than per vehicle. Every seventh
truck starts near the low-battery threshold and every eleventh runs hot, so the
threshold paths have material without waiting for a lucky random walk.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| Natural-key PK on the log | Makes idempotency a database constraint instead of a code path, so at-least-once delivery suffices | Dedupe in Dart against a recent-packet set — correct until the set is evicted |
| Staging tables + appender | One `INSERT … SELECT` per target instead of a statement per row; no SQL string building around vehicle ids | Multi-row `VALUES` built by string concatenation |
| Two transactions per batch | Short write locks, and derived state can only lag the log | One transaction — a long recompute would block readers for its whole duration |
| Long-lived writer isolate | Spawn cost paid once | `Isolate.run` per batch |
| Location in its own table | A fix is a triple, not a scalar; pairing lat/lon rows by timestamp is pointless work | `lat` and `lon` as two signals in the log |
| Start the pipeline from the binding | It must run whether or not its monitor screen is mounted, and `main` can `await` it before `runApp` | `onInit` — a hook that cannot be awaited, so the first frame could race the roster seed |

## Tests

| Claim | Test |
|---|---|
| A redelivered packet applies nothing | `ingest_pipeline_test.dart` |
| Duplicates inside one batch collapse before the log | same |
| A late packet lands in the log but never clobbers the latest value | same |
| A batch behind the watermark is reported late; the watermark never reverses | same |
| **Any shuffling or repetition of a feed produces identical final state** | same — the invariant the whole design rests on |
| The simulator actually injects all four faults, and replays under one seed | `simulated_packet_source_test.dart` |
| Counters fold receipts correctly; failures surface without killing the feed | `ingest_controller_test.dart` |
| Building the binding really starts the pipeline and rows reach disk | `ingest_binding_test.dart` |

That last one exists because every other test passed while a running app
ingested nothing. Unit tests cannot see wiring.

## Known limits

* No backend, so no outbox — see ARCHITECTURE.md §3.7. The cursor mechanism is
  real because the simulator is a positioned, replayable source.
* The watermark advances with no derivation behind it yet. Derived tables are
  class D — dropped and rebuilt — so the first derivation pass rebuilds from
  the log regardless.
* `DatabasePulse` is a counter, not a change feed. It says "something was
  written", not what; every reader re-queries. Fine at this scale, and the
  place to look first if refresh cost ever matters.
