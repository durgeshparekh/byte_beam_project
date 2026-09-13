# 03 — Vehicle detail

One vehicle: a status header, a readings register with a verdict per signal,
and battery history queried out of the event log.

Covers the brief's §3 B.

## Files

```
lib/features/vehicle_detail/
  domain/entities/         reading_verdict · signal_reading_row
                           soc_history (+ soc_point) · vehicle_detail
  domain/repositories/     vehicle_detail_repository
  domain/usecases/         get_vehicle_detail
  data/models/             signal_reading_row_model
  data/datasources/        vehicle_detail_local_data_source (interface + DuckDB impl)
  data/repositories/       vehicle_detail_repository_impl
  presentation/            vehicle_detail_controller · vehicle_detail_binding
                           vehicle_detail_page
  presentation/widgets/    verdict_pill · reading_row_tile · soc_sparkline
```

## The readings register

One row per signal, driven by a LEFT JOIN **from `signal_spec`**, so the
register is generated from configuration rather than from a hard-coded list.
Adding a signal to `signal_spec` adds a register row with no code change, and a
signal that has never reported still gets a row — which is exactly the "—, no
pill" case the brief calls for.

```sql
SELECT s.signal, s.label, s.unit, s.max_age_sec, l.value, l.event_ts,
       CASE
         WHEN l.event_ts IS NULL THEN NULL
         WHEN l.event_ts < $1 - to_seconds(s.max_age_sec) THEN 'STALE'
         WHEN (s.crit_lo IS NOT NULL AND l.value < s.crit_lo)
           OR (s.crit_hi IS NOT NULL AND l.value > s.crit_hi)
           OR (s.warn_lo IS NOT NULL AND l.value < s.warn_lo)
           OR (s.warn_hi IS NOT NULL AND l.value > s.warn_hi) THEN 'ALERT'
         ELSE 'NORMAL'
       END AS verdict
FROM signal_spec s
LEFT JOIN vehicle_signal_latest l
  ON l.signal = s.signal AND l.vehicle_id = $2
ORDER BY list_position(
  ['soc', 'range_km', 'speed', 'battery_temp', 'odometer', 'ignition'], s.signal)
```

Order matters and it is deliberate: **staleness is checked before the
thresholds.** A reading of 4 % SOC that arrived forty minutes ago is STALE, not
ALERT. Saying "alert" would assert something about a value we no longer trust,
and saying "normal" would assert the opposite — so STALE refuses to make either
claim. That is why it is a third verdict rather than a flag on the other two,
and why the pill is grey: it is not a milder alert, it is "we do not know".

A signal with no thresholds configured (speed, range, odometer, ignition) can
never be ALERT; it is NORMAL whenever it is fresh.

Display order is a `list_position` expression rather than a `sort_order`
column: ordering is a presentation concern that does not justify a migration.

### The rows

| Row | Notes |
|---|---|
| State of charge, Range, Speed, Battery temperature, Odometer | The five the brief names |
| Ignition | Stored and drives the status ladder, so it is shown. Rendered "On"/"Off" — it rides in a `DOUBLE` column and "1.0" would be technically true and useless |
| Last ping | Rendered in the header, with an age but **no verdict pill** — the status chip beside it already makes the liveness claim, and a second one could contradict it |

Every age on the screen is rendered from the same clock reading the verdicts
were computed against, held on the controller as `evaluatedAt`. A row whose
pill says STALE while its age reads "2s ago" is worse than a clock that only
ticks on refresh.

## Battery history

The one query in the app that touches the multi-million-row event log — which
is the point of the section. The latest-value table cannot answer it.

```sql
SELECT min(event_ts) AS at, avg(value) AS value, count(*) AS n
FROM signal_reading
WHERE vehicle_id = $1 AND signal = 'soc' AND event_ts >= $2
GROUP BY floor((epoch(event_ts) - epoch($3)) / <bucket>)
ORDER BY at
```

Bucketing happens in SQL. Pulling a day of raw readings into Dart to thin them
there would defeat the exercise and would not survive the retained window
growing.

Two details that took a correction each:

* **Bucket width comes from the span the data actually covers**, not from the
  requested window. A vehicle with twenty seconds of history inside a 24-hour
  window otherwise collapses into a single point — which is exactly what the
  first version did on a freshly started app.
* **Buckets are aligned to the first reading**, and the width divides by one
  fewer than the point cap. Aligning to absolute epoch leaves a partial bucket
  at each end, which puts the point count one over the cap. A test caught it.

The chart reports "*N* readings · *M* points · *lo*–*hi* %". Saying how many
raw log rows fed how many plotted points is the honest way to present a
bucketed summary, and it is the visible proof that this came out of the log.

The sparkline is a hand-written `CustomPainter` — one polyline with a fill,
about forty lines. A charting dependency would be more code to audit than the
code it replaces. Its axis is fixed at 0–100 %, not scaled to the data: auto
scaling makes a battery drifting between 61 % and 63 % look like a cliff.

## Controller

One permanent controller whose `open(id)` switches the subject, rather than a
tagged instance per vehicle. Only one detail screen is open at a time, so this
is simpler and leaves nothing to dispose. Opening a different vehicle clears
the previous detail first, so the old vehicle never lingers under the new
header.

An unknown vehicle is `Ok(null)`, not a failure — "no such vehicle" is a normal
answer and gets a not-found message rather than an error screen.

Refresh is the same debounced `DatabasePulse` the fleet list uses.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| Register driven from `signal_spec` | Config adds rows without code; never-reported signals get a row for free | A hard-coded list of six rows |
| Staleness checked before thresholds | A value too old to trust must not claim normal *or* alert | Comparing thresholds first and marking staleness separately |
| STALE as a verdict, not a modifier | It is a refusal to judge, not a severity | A `isStale` boolean alongside normal/alert |
| No pill on last ping | The status chip already makes that claim | A second liveness pill that can disagree |
| One clock reading per refresh | Pills and ages must agree | `DateTime.now()` per row |
| Bucket from data span, aligned to first reading | Correct for both a 20-second and a 24-hour history, and honours the cap | Fixed bucket from the window; epoch-aligned buckets |
| Hand-painted sparkline | ~40 lines against a dependency | `fl_chart` or similar |
| Single controller with `open()` | One screen at a time; no tags, no disposal | `Get.put(tag: vehicleId)` per vehicle |

## Tests

| Claim | Test |
|---|---|
| Every configured signal gets a row, in display order, with label/unit from `signal_spec` | `vehicle_detail_query_test.dart` |
| NORMAL / ALERT on both low and high thresholds; the freshness boundary is inclusive | same |
| A stale out-of-range reading is STALE and still shows its value | same |
| A never-reported signal has no value and no verdict | same |
| The header reuses the fleet ladder; last ping spans signals and position reports | same |
| History reads the log, respects the window, is ordered, and never exceeds the point cap | same |
| Unknown vehicle is not-found rather than an error; switching vehicles clears the previous | `vehicle_detail_controller_test.dart` |
| One refresh per burst; refreshing re-reads the clock | same |
| Pills, dashes, "On"/"Off", the history summary line, and the not-found message render | `vehicle_detail_page_test.dart` |

Verified against real data too: the macOS app was run, and the register queried
straight from the database it left behind — SOC 14.7 % → ALERT with every other
row NORMAL, and 35 log readings bucketed into 26 points.

## Known limits

* History is SOC only. The query is signal-agnostic apart from a literal; a
  signal picker is a parameter, not a redesign.
* The window is a fixed 24 hours with no zoom or pan.
* The sparkline has no axis labels, no tooltip and no point inspection — it is
  a sparkline, and the summary line carries the numbers that matter.
* Ages are computed at refresh, so they do not tick between refreshes. With a
  250 ms pulse on a live feed this is invisible; on a paused feed the ages sit
  still until the next refresh.
