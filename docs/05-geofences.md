# 05 — Geofences

Circular fences that are created, edited and deactivated in the app, and
entry/exit detection folded out of the position log on every ingest batch.

Covers the brief's §3 D.

## Files

```
lib/db/geofence_sql.dart      the detector, the fence upsert, the read queries
lib/db/schema.dart            migration v2: containment table + four seed fences
lib/features/geofence/
  domain/entities/            geofence (+ geofence_occupancy · geofence_visit)
  domain/repositories/        geofence_repository
  domain/usecases/            get_geofences · save_geofence · set_geofence_active
  data/models/                geofence_model
  data/datasources/           geofence_local_data_source (interface + DuckDB impl)
  data/repositories/          geofence_repository_impl
  presentation/               geofence_controller · geofence_binding
                              geofences_page · geofence_editor_page
  presentation/widgets/       geofence_tile · zone_panel
```

## The detector

One query, eight stages, no row-at-a-time fold in Dart. That is not a
performance flourish — a Dart fold would have to re-read a vehicle's history
to resume, and the resume is the hard part of this feature.

| Stage | What it does | Brief's hard case |
|---|---|---|
| `probe` | fixes × fences, gated on accuracy and on the fence being active **at the fix's event time** | inaccurate readings, geofence edits |
| `opinion` | `IN` if `d ≤ r − h`, `OUT` if `d ≥ r + h`, `h = max(25 m, accuracy)`. In between: **no opinion at all** | GPS jitter |
| `seeded` | the previous pass's state, injected as if it were the last opinionated fix before the window | incremental derivation |
| `seq` | `lag` over the opinionated sequence only | |
| `decided` | confirmed by **two consecutive opinionated fixes agreeing**, or one fix more than `2h` clear of the boundary | jitter vs. a genuine fast crossing |
| `settled` | `last_value(… IGNORE NULLS)` carries the established zone forward | |
| emit | a confirmation that disagrees with the established zone, stamped with the **first** fix of the pair | when did it actually cross |
| confidence | `low` when the confirming pair straddles a gap > 30 min | missing intervals |

Three of those are worth spelling out.

**A fix in the band has no opinion, rather than a weak one.** That is what
makes the band genuinely inert. A truck parked on a boundary produces a run of
fixes that say nothing at all, so there is nothing to flap between — the
established zone simply persists. Carrying band fixes as votes would only move
the flapping somewhere subtler.

**The transition is stamped with the first fix of the confirming pair**, not
the second. The vehicle crossed when it was first seen on the other side; the
second fix is when *we* became sure. Stamping the second would push every
crossing late by one reporting interval, and every trip duration with it.

**The escape hatch is scaled by the fix, not by the fence.** One fix more than
`2h` past the boundary confirms alone, and because `h = max(25 m, accuracy)`, a
5 m fix needs 50 m of clearance while a 100 m fix needs 200 m. A truck doing 60
through the edge of a bay should not need a second fix to prove it left; a
truck reported vaguely should.

**A cold start emits nothing.** The first confirmation *establishes* a zone.
We have learned where the truck is, not watched it go there, and inventing an
ENTRY would put a crossing in the record that never happened.

## Resuming without re-reading the log

`geofence_containment` holds, per (vehicle, fence), the confirmed zone and the
last fix that had an opinion at all. The detector injects that as a synthetic
first row, so an ingest batch costs **two fixes of work instead of a vehicle's
whole history**. At 500 vehicles and a few thousand fixes each, the difference
between those is the difference between the feature existing and not.

The table earns its place three times: it seeds the detector, it answers
"which fence is this truck in" without touching the log, and it is what the
live per-fence counts are counted from.

```
scope → delete the range being rewritten → detect → upsert containment
```

**Late packets.** The scope query compares the batch's oldest fix against the
vehicle's `ingest_watermark`. A batch that reaches back behind it invalidates
the seed — containment is the state *at* the watermark — so that vehicle is
scoped to `-infinity` and replayed from the beginning of its log instead.
That is ARCHITECTURE.md §4 step 4 with `t0` collapsed to the whole vehicle,
because a per-fix `t0` would need a containment history we deliberately do not
keep. A full replay of one vehicle is a few thousand fixes; late packets are
rare and already counted.

This runs **before** the watermark advances, because once it has moved the
comparison that detects a late batch is always false.

The property that makes all of this trustworthy is tested directly: feeding a
route one fix at a time, deriving after each, lands on byte-identical
transitions and containment to one pass over the finished log.

## Overlapping fences

Depot Bay 3 is seeded inside Whitefield Depot on purpose. Containment is
tracked **per fence** — a truck in the bay is genuinely inside two — and there
is no "current geofence" column anywhere, because under nesting there is no
such thing.

The single value the UI wants is the **smallest radius containing the
vehicle**, tie-broken by id: the most specific true answer (§10, ambiguity 10).
It is a query, not a stored field, so it cannot go stale against containment.

This is also what stops a nested fence manufacturing a trip later: leaving a
bay while still inside the depot is not a departure, and trips will key off
containment *count* rather than individual fences (§10, ambiguity 11).

## Editing a fence

Activation is time-versioned; geometry is not.

* **Deactivating** sets `active_to`. Nothing is recomputed, because the fence
  genuinely was live before that moment. The fence is kept, not deleted — a
  trip that ended at a depot has to be able to name it a year later — and it
  stays visible on the list, marked off, because a fence you cannot see is a
  fence you cannot turn back on.
* **Reactivating** starts a *new* active window rather than resuming the old
  one, so the period it was off stays off in any recompute.
* **Moving or resizing** re-derives that fence's whole history. Two answers on
  record about whether a truck was inside would be worse than a slow save.

Saving recomputes **every** fence, not just the one that changed. That is
deliberate: derived state is dropped and rebuilt (§3.5), and one path that is
always right beats two that are usually right. A fence edit is rare and
user-initiated and can afford to be slow; a subtly wrong incremental path
cannot. The editor says so before the button is pressed, and the screen shows
a progress bar while it runs.

## The screens

| Surface | What it shows |
|---|---|
| Geofences | Every fence: name, radius, centre, and how many vehicles are inside right now. Deactivated ones sorted last and marked off. New/edit/deactivate |
| Geofence editor | Name, latitude, longitude, radius, validated rather than clamped |
| Vehicle detail | The truck's current fence, and its last eight crossings with ages and a flag on the uncertain ones |
| Fleet app bar | The way in |

An empty fence reads "empty" rather than `0`, and a truck in no fence reads
"On the road" rather than an em dash — not being in a fence is a normal place
for a truck to be, not missing data.

Deactivating asks for confirmation; reactivating does not. One stops the fence
judging fixes from that moment on and leaves a gap in the history afterwards;
the other only undoes that.

## Why no map

Typed coordinates. Picking a point on a tile layer is the better interface and
it is a cut, not an oversight (ARCHITECTURE.md §11): every geofence rule in
this app is decided without one, and a tile layer would be the largest
dependency in the project. The editor shows six decimal places so a centre can
be retyped exactly, which is the only reason the numbers are on screen.

Haversine rather than DuckDB's spatial extension, for the same shape of
reason: one expression against a loadable extension, a native dependency and a
`GEOMETRY` column, for circles. If fences ever become polygons that trade
flips.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| Band fixes have *no* opinion | Makes the band inert instead of moving the flapping | Carrying band fixes as weak votes |
| Two-fix confirmation | One fix is jitter; two agreeing is a crossing | Bare `d < r` — a parked truck becomes dozens of trips |
| Escape hatch scaled by accuracy | A fast crossing is real; a vague fix is not | A fixed metre threshold that is wrong for good and bad fixes alike |
| Stamped with the first fix of the pair | That is when it crossed, not when we knew | The confirming fix — every crossing late by one interval |
| Cold start establishes, does not emit | We learned where it is; we did not watch it arrive | An ENTRY on first sight, inventing a crossing |
| Containment table | Two fixes of work per batch instead of a history; also answers the UI's two questions | Re-deriving from the log every batch |
| Late batch replays the whole vehicle | The seed is only valid ahead of the watermark | A fixed lookback window, wrong at the edges |
| Containment per fence, current fence as a query | Under nesting there is no single current fence | A `current_geofence_id` column |
| Activation versioned, geometry not | Deactivating is free; moving is rare | Full geometry versioning — more table than this earns |
| A fence edit recomputes everything | One path that is always right | An incremental path for the changed fence only |
| Deactivated fences kept and listed | Trip history has to name them; hidden fences cannot be restored | Deleting, or hiding behind a filter |
| Coordinates validated, not clamped | A mistyped longitude silently becoming 180 puts a depot in the Pacific | `clamp()` |

## Tests

| Claim | Test |
|---|---|
| A cold start establishes a zone and emits nothing; one ambiguous fix establishes nothing, one unambiguous fix establishes alone | `geofence_detector_test.dart` |
| Two agreeing fixes confirm an entry, stamped with the first of the pair | same |
| A round trip gives an entry and an exit | same |
| One fix far past the boundary confirms alone; one just past the line does not | same |
| A vehicle parked in the band never crosses | same |
| An inaccurate fix is not evidence, and a mediocre fix widens the band it must clear | same |
| A pair straddling a long gap is `low` confidence; an ordinary pair is `high` | same |
| Fixes before a fence existed, or after it was deactivated, are not its business | same |
| **Fix-by-fix derivation matches a single full replay** | same |
| A late fix replayed from the beginning reveals the missed excursion and matches an in-order log exactly | same |
| Re-deriving the same log is idempotent; a nested fence is tracked independently | same |
| Migration v2 installs four fences, nested pair included | `geofence_store_test.dart` |
| The detector runs inside ingest, through the real writer isolate, and moves the live count | same |
| A nested fence counts the same vehicle twice over | same |
| Renaming keeps the fence and its history; shrinking re-derives the vehicle out of it | same |
| A new fence inherits no history; deactivation is kept, stops judging, and sorts last; reactivating starts a fresh window | same |
| Migrations apply once and do not duplicate seed rows | `fleet_db_test.dart` |
| The active count ignores deactivated fences; a blank fence is active from the injected clock | `geofence_controller_test.dart` |
| A save pulses the database so the vehicle screens follow; a failure surfaces and clears the progress flag | same |
| Size, centre and live count render; empty says "empty"; deactivated is listed and marked off | `geofence_page_test.dart` |
| Deactivating asks first and can be cancelled; reactivating does not ask | same |
| The editor refuses a blank name and an out-of-range coordinate; a valid fence is saved with its id kept | same |
| The zone panel names the current fence and recent crossings; no fence reads "On the road"; a gap-confirmed crossing is flagged | `vehicle_detail_page_test.dart` |

## Known limits

* **No map.** See above. The editor is four fields.
* **Circles only.** A polygon fence changes `probe` and nothing else in the
  pipeline, but it changes the schema and the editor.
* **A fence edit recomputes every fence.** Correct, and slow in proportion to
  the whole log rather than to what changed.
* **Containment has no history.** It holds the current state, which is why a
  late packet replays the vehicle rather than the affected suffix. A
  containment-at-time table would make that surgical and is the upgrade if
  replays ever become common.
* **The vehicle screen shows eight crossings.** The full history is in
  `geofence_transition`; nothing renders it.
* **`low` confidence is recorded and shown but drives nothing.** Trips will
  inherit it; no rule currently treats an uncertain crossing differently.
