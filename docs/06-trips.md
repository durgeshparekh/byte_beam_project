# 06 — Automatic trips

Legs between geofences, derived on every ingest batch from the crossings the
detector produces. Nothing in the packet stream says "departed".

Covers the brief's §3 E.

## Files

```
lib/db/trip_sql.dart          the derivation, and the two read queries
lib/features/trips/
  domain/entities/            trip
  domain/repositories/        trip_repository
  domain/usecases/            get_recent_trips
  data/models/                trip_model
  data/datasources/           trip_local_data_source (interface + DuckDB impl)
  data/repositories/          trip_repository_impl
  presentation/               trips_controller · trips_binding · trips_page
  presentation/widgets/       trip_tile
```

No migration. `trip` has been in the schema since v1.

## What a trip is

**Containment count reaching zero.** Not a fence exit — a fence exit is what a
nested bay produces every time a truck crosses its own yard, and keying off one
would turn a single departure into two trips.

| Event | Meaning |
|---|---|
| count falls to **0** | a trip starts; origin is the fence just left |
| count rises **off 0** | the open trip completes; destination is the fence just entered |
| still 0 at the end of the log | `IN_PROGRESS`. No timeout |
| an arrival with no departure | nothing. We never watched it leave |

One open trip per vehicle falls out of the model rather than being enforced: a
count cannot be at zero twice without leaving zero in between. The real run
below confirms it rather than the schema.

## The derivation

One query, no parameters. A trip is a pure function of the crossings, the
containment they fold up to, and the odometer log — there is no "now" in it,
which is what makes re-running it after every batch a no-op when nothing moved.

| Stage | What it does |
|---|---|
| `crossing` | the scoped vehicles' crossings, with each fence's size |
| `baseline` | how many fences the vehicle was inside **before its first recorded crossing** |
| `instant` | crossings collapsed per event time |
| `counted` · `marked` | the running count and its previous value |
| `boundary` | count at 0 is a departure; leaving 0 is an arrival |
| `paired` | the arrival closing a departure is the next boundary row |

Three of those carry the design.

**The baseline is not zero, and recovering it needs no table.** The detector
emits no transition for the zone it establishes on a cold start — learning
where a truck is is not watching it go there — so a truck that was already in
the depot has an EXIT with no matching ENTRY. Counting from zero would take it
to −1 and lose the trip entirely. The count before the first crossing is
recovered arithmetically as *inside now, minus the net of every crossing
since*, which is exact and costs one scalar subquery.

**Simultaneous crossings collapse into one instant.** Leaving Bay 3 and
Whitefield Depot can be confirmed off the same fix. A running sum stepping
through them one at a time would dip through a spurious zero and manufacture a
zero-length trip, so the count only ever takes its post-instant value. Among
crossings sharing an instant the fence named is the **largest** — a truck that
leaves the bay and the depot together departed from the depot, and the same
rule picks the outermost fence on arrival.

**Distance is an `ASOF LEFT JOIN` onto the odometer log** at each end: the last
reading at or before that instant, and NULL when there is none. An open trip
anchors its far end at `infinity`, so its distance is the distance *so far* and
grows with the truck. NULL rather than 0 when the odometer never reported —
"we do not know" and "it did not move" are different answers, and the UI says
`distance unknown` rather than inventing the cheaper one.

## Recompute, and what it costs

Whole vehicle, every time, for every vehicle the batch touched. The detector
needs `geofence_containment` to resume mid-stream because `location_fix` holds
thousands of rows per truck; `geofence_transition` holds a handful, so the
same machinery here would buy nothing and add a seam that can disagree with
itself. Delete the vehicle's trips, rebuild from its whole crossing log.

That makes the hard cases somebody else's problem, which is the point:

- **a duplicate packet** changes no crossing, so it changes no trip;
- **a late packet** already forces the detector to replay that vehicle, and the
  trips fall out of the replayed crossings;
- **a fence edit** re-derives every crossing, and trips are re-derived right
  after it in the same transaction.

`trip_id` is `vehicle_id|epoch_ms(start_ts)` — derived, so a replay reproduces
the identical row. That is the backstop, not the mechanism.

Order matters, and it is pinned by a test rather than by a comment: detect,
then derive trips, then move the watermark. The baseline reads containment the
detector has just rewritten, and the detector reads the watermark to decide
which vehicles went backwards.

## What the real app produced

40 vehicles, a few minutes of simulated driving, read straight out of the
database afterwards:

```
8655 location fixes · 18 crossings · 8 trips (5 running, 1 low confidence)
overlapping trips per vehicle ........ 0
open trips followed by another ....... 0
max open trips on any one vehicle .... 1
```

Completed legs included `Whitefield Depot → Whitefield Depot` and
`Hebbal Yard → Hebbal Yard` — return-to-origin, which is an ordinary
completion here and not a special case in the code.

The distances are honest and tiny (tens of metres). That is
`SimulatorConfig.groundScale` showing through: the simulator moves vehicles
across the ground 30× faster than their speed signal implies so that a geofence
demo produces crossings in a minute instead of twenty, and the odometer stays
consistent with the *honest* speed. Geography is scaled; the odometer is not.
Set `groundScale` to 1 and the two agree again, at the cost of a demo nobody
can watch.

## Tests

| Claim | Test |
|---|---|
| leaving the last fence starts a running trip | `trip_derivation_test` |
| arriving completes it; returning to origin is ordinary | `trip_derivation_test` |
| an arrival with no departure makes nothing | `trip_derivation_test` |
| leaving a bay inside a depot starts nothing | `trip_derivation_test`, `trip_store_test` |
| bay + depot on one fix is one trip, from the depot | `trip_derivation_test` |
| a cold start inside a fence still produces the trip | `trip_derivation_test` |
| distance is the odometer delta, and NULL when absent | `trip_derivation_test` |
| a running trip measures distance so far | `trip_derivation_test`, `trip_store_test` |
| a low-confidence crossing makes a low-confidence trip | `trip_derivation_test` |
| deriving twice changes nothing | `trip_derivation_test` |
| a late fix moves the departure instead of adding a trip | `trip_store_test` |
| one vehicle's list agrees with the fleet list | `trip_store_test` |
| the screen says what would make a trip when there are none | `trip_page_test` |

`trip_derivation_test` states crossing sequences directly and asks what they
mean; `trip_store_test` drives a truck around through the real writer isolate
and asks whether a trip comes out. The first would pass if the detector were
broken, the second would not, and neither would catch what the other does.

## Knowingly left undone

- **A fence deactivated while a vehicle is inside it holds that vehicle's count
  above zero forever**, so the truck starts no further trips. Containment keeps
  the last zone it was confirmed in and the fence stops producing opinions,
  which is the same principle the alerts use — an episode ends when we watch it
  end. Here the principle costs something real. Every alternative invents a
  fact: an implicit exit at `active_to` manufactures a departure out of a
  fence edit, and excluding deactivated fences retroactively deletes the trips
  that named them. The fix, if it matters, is to purge containment rows on
  deactivation and accept that the fence's live count goes to zero with them.
  Recorded as ARCHITECTURE.md §10, ambiguity 16.
- **No trip route.** The fixes between the two ends are in `location_fix` and
  nothing reads them. A route needs a map, which is the §11 cut.
- **No per-trip driver, load or purpose.** Nothing in the packet stream carries
  them.
- **The whole-vehicle rebuild is bounded by transition volume, not measured.**
  It is a `ponytail:` comment on `deleteScopedTrips` with the upgrade path,
  not a benchmark.
