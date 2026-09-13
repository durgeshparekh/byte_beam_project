# 02 — Fleet home

The screen the brief opens with: where are my vehicles, are they okay, what
needs attention now. A list of every vehicle with registration, model, SOC,
range, an alert badge and a status chip, above filter chips carrying live
counts.

Covers the brief's §3 A.

## Files

```
lib/db/vehicle_status_sql.dart          the status ladder, shared
lib/features/fleet/
  domain/entities/         vehicle_status (+ alert_severity) · fleet_filter
                           fleet_vehicle_summary · fleet_overview
  domain/repositories/     fleet_repository
  domain/usecases/         get_fleet_overview
  data/models/             fleet_vehicle_summary_model
  data/datasources/        fleet_local_data_source (interface + DuckDB impl)
  data/repositories/       fleet_repository_impl
  presentation/            fleet_controller · fleet_binding · fleet_page
  presentation/widgets/    status_chip (+ alert_badge) · fleet_filter_bar
                           vehicle_tile · fleet_empty_state
```

## What the query touches

`vehicle` (500 rows) joined to `vehicle_signal_latest` (500 × 6) and
`signal_spec` (6). **The multi-million-row event log is never scanned here.**
That is the whole reason `vehicle_signal_latest` is maintained on ingest, and
why the fleet list stays fast as the log grows.

## The status ladder

Lives in `lib/db/vehicle_status_sql.dart`, beside the schema rather than inside
this feature, because it is a property of the data and not of a screen — the
vehicle detail header makes the same claim about the same vehicle, and two
copies of the `CASE` would eventually disagree.

Four CTEs:

* `latest` — pivots the long-format latest table into one row per vehicle with
  `FILTER`, carrying each signal's own timestamp.
* `ping` — vehicle-level last ping is the newest event time from *any* signal
  **or position report**.
* `spec` — thresholds and staleness windows read from `signal_spec`, so they
  are configuration rather than constants buried in a SQL string.
* `scored` — the first-match-wins status and the alert badge.

```sql
CASE
  WHEN p.last_ping IS NULL OR p.last_ping < $1 - INTERVAL 10 MINUTE THEN 'OFFLINE'
  WHEN l.speed_ts    >= $1 - INTERVAL 10 MINUTE AND l.speed > 0     THEN 'MOVING'
  WHEN l.speed_ts    >= $1 - INTERVAL 10 MINUTE AND l.speed = 0
   AND l.ignition_ts >= $1 - INTERVAL 10 MINUTE AND l.ignition = 1  THEN 'IDLE'
  ELSE 'STOPPED'
END
```

Each branch below OFFLINE checks its own signal's freshness first, so a vehicle
that is online but whose speed is 40 minutes old cannot claim MOVING. STOPPED
is the `ELSE`: both "ignition off" and the documented fallback when the
deciding signals are too stale to judge.

### Two freshness windows, on purpose

The ladder scores freshness against the **10-minute OFFLINE window**. The alert
badge scores it against the **per-signal `signal_spec.max_age_sec`** (5 minutes
for SOC and battery temperature).

They differ because the claims differ in scope. Status is a vehicle-level
claim, so its inputs get the vehicle's own liveness window; a threshold is a
claim about one signal, and the brief scopes thresholds to fresh readings.

This was a correction, not a plan. Scoring the ladder against the 5-minute
window leaves a dead band between 5 and 10 minutes in which a truck that is
online and visibly moving reads STOPPED, because every signal is stale while
the vehicle is not yet offline. A test caught it. It is written up as ambiguity
14 in ARCHITECTURE.md.

## Counts

```sql
<scored CTE> SELECT status, count(*) FROM scored GROUP BY status
```

Counts span the whole fleet; rows are a second query over the same CTE with
`WHERE status = …`. Counting the returned rows instead would make every chip
read "the number you can already see", which is the easy bug here and has its
own test.

## The alert badge

Computed from `signal_spec` thresholds against fresh readings: SOC below 10 %
or battery over 45 °C is critical, SOC below 20 % is a warning.

This is a placeholder with a defined end. Once the alerts feature owns an alert
lifecycle — raise, escalate, dismiss, resolve — the badge reads open alerts
from the `alert` table instead. The thresholds stay in `signal_spec` either
way, so there is one definition throughout, and only the "which vehicles have
something wrong" query moves.

## Refresh

The writer bumps `DatabasePulse` after each commit; the controller debounces it
at 250 ms. A vehicle leaving a basement commits several batches back to back,
and the list only needs to land once.

Switching a chip re-queries rather than filtering in memory — the counts are
SQL-side and a chip's row set is a different query, not a subset of one already
held.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| Status ladder in shared SQL | Two screens make the same claim | A copy per feature, or a Dart helper (moves the fold into memory) |
| Counts and rows as two queries | Chips must count the fleet, not the page | One query plus in-memory grouping |
| Positional `$1` binding | DuckDB 1.2.1 cannot resolve a *second* named parameter in a statement that opens with `WITH` | Named parameters — they fail at run time, not compile time |
| `all` inside `FleetFilter` | The UI needs a fifth chip with its own count | A nullable status, which special-cases every call site |
| Order by registration | A list that reorders as speeds change is unreadable | Order by status or SOC |
| Two distinct empty states | "No vehicle is moving" and "no telemetry at all" need different words | One generic empty widget |
| Em dash, never zero | A fabricated `0%` reads as an empty battery | Coalescing nulls to zero in SQL |

## Tests

| Claim | Test |
|---|---|
| Each rung of the ladder, including both stale-signal fallthroughs and the 9- and 6-minute boundaries | `fleet_query_test.dart` |
| Badge thresholds, including that a stale low battery raises nothing | same |
| Counts span the fleet while rows narrow to the chip | same |
| Filtered-empty is distinguishable from fleet-empty | same |
| One reload per burst of writes, not one per write | `fleet_controller_test.dart` |
| Chips render their counts; rows render values, dashes and pills; tapping switches filter | `fleet_page_test.dart` |
| Simulator → writer isolate → DuckDB → fleet query, nothing stubbed; every vehicle lands in exactly one chip; the whole fleet reads offline 11 minutes later | `fleet_end_to_end_test.dart` |

## Known limits

* The badge is threshold-derived, not alert-derived (see above).
* Counts and rows are two round trips. Both are small; if it ever matters they
  merge into one query returning rows plus a window-function count.
* No search, no sort control, no pagination. 500 rows in a `ListView.separated`
  is fine; a larger fleet wants `LIMIT`/`OFFSET`, which the query already
  supports shape-wise.
