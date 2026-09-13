/// Automatic trips, in SQL.
///
/// Beside the schema for the same reason as the geofence detector: the
/// derivation runs on the writer isolate, the fleet-wide list is read by the
/// trips screen, and one vehicle's legs by vehicle detail. Three callers, one
/// definition of what a trip is.
///
/// A trip is **not** its own observation. It is a reading of
/// `geofence_transition`, which is itself a reading of `location_fix`. Nothing
/// here looks at a position: if the detector is right about crossings, this is
/// right about trips, and if it is wrong there is exactly one place to fix.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

/// Removes the trips this pass is about to rewrite.
///
/// The whole vehicle, not a suffix. `geofence_transition` holds a handful of
/// rows per truck per day where `location_fix` holds thousands, so the
/// incremental-resume machinery the detector needs (ARCHITECTURE.md §7.1,
/// `geofence_containment`) buys nothing here — and a full rebuild cannot
/// disagree with itself at the seam.
///
/// ponytail: whole-vehicle rebuild every batch. If `geofence_transition` ever
/// grows past a few thousand rows per vehicle, scope this to transitions at or
/// after `staging_geo_scope.from_ts` and seed `inside_count` the way the
/// detector seeds its zone.
const deleteScopedTrips = '''
DELETE FROM trip t
WHERE EXISTS (
  SELECT 1 FROM staging_geo_scope s WHERE s.vehicle_id = t.vehicle_id
)
''';

/// The derivation, as one query. Takes no parameters: a trip is a pure
/// function of the crossings, the containment they fold up to, and the
/// odometer log. There is no "now" in it, which is what makes re-running it
/// after every batch a no-op when nothing moved.
///
/// * `crossing` — the scoped vehicles' crossings, with each fence's size.
/// * `baseline` — how many fences the vehicle was inside **before its first
///   recorded crossing**. Not zero: the detector establishes a zone on its
///   first confirmation without emitting a transition (learning where a truck
///   is is not watching it go there), so a truck that starts in the depot has
///   an EXIT with no matching ENTRY. Recovered arithmetically as *inside now
///   minus the net of every crossing since*, which needs no extra table.
/// * `instant` — crossings collapsed per event time. Leaving a bay and the
///   depot around it can land on the same fix, and a running sum that stepped
///   through them one at a time would dip through a spurious zero.
/// * `counted` / `marked` — the running containment count and its previous
///   value. §7.2's `inside_count`, seeded from `baseline`.
/// * `boundary` — the count reaching **0** is a departure; leaving 0 is an
///   arrival. Per-fence exits are never consulted, which is the whole reason
///   a nested bay manufactures nothing.
/// * `paired` — departures and arrivals strictly alternate, so the arrival
///   that closes a departure is simply the next boundary row.
///
/// Among crossings sharing one instant, the fence named is the **largest**:
/// a truck that leaves Bay 3 and Whitefield Depot on one fix departed from the
/// depot. The same rule picks the outermost fence on arrival.
const tripDerivationQuery = '''
WITH crossing AS (
  SELECT t.vehicle_id, t.event_ts, t.kind, t.confidence,
         t.geofence_id, g.radius_m
  FROM geofence_transition t
  JOIN staging_geo_scope s ON s.vehicle_id = t.vehicle_id
  JOIN geofence g USING (geofence_id)
),
baseline AS (
  SELECT s.vehicle_id,
         (SELECT count(*) FROM geofence_containment c
           WHERE c.vehicle_id = s.vehicle_id AND c.zone = 'IN')
         - coalesce((SELECT sum(CASE t.kind WHEN 'ENTRY' THEN 1 ELSE -1 END)
                       FROM geofence_transition t
                      WHERE t.vehicle_id = s.vehicle_id), 0) AS start_count
  FROM staging_geo_scope s
),
instant AS (
  SELECT vehicle_id,
         event_ts,
         sum(CASE kind WHEN 'ENTRY' THEN 1 ELSE -1 END) AS delta,
         arg_max(geofence_id, radius_m) FILTER (WHERE kind = 'EXIT')  AS exited,
         arg_max(geofence_id, radius_m) FILTER (WHERE kind = 'ENTRY') AS entered,
         bool_or(confidence = 'low') AS shaky
  FROM crossing
  GROUP BY vehicle_id, event_ts
),
counted AS (
  SELECT i.*,
         b.start_count,
         b.start_count + sum(i.delta) OVER (
           PARTITION BY i.vehicle_id ORDER BY i.event_ts
         ) AS inside_count
  FROM instant i JOIN baseline b ON b.vehicle_id = i.vehicle_id
),
marked AS (
  SELECT *,
         lag(inside_count) OVER (
           PARTITION BY vehicle_id ORDER BY event_ts
         ) AS prev_count
  FROM counted
),
boundary AS (
  SELECT vehicle_id, event_ts, exited, entered, shaky,
         inside_count = 0 AS departing
  FROM marked
  WHERE (inside_count = 0 AND coalesce(prev_count, start_count) > 0)
     OR (inside_count > 0 AND prev_count = 0)
),
paired AS (
  SELECT *,
         lead(event_ts) OVER w AS end_ts,
         lead(entered)  OVER w AS dest,
         lead(shaky)    OVER w AS end_shaky
  FROM boundary
  WINDOW w AS (PARTITION BY vehicle_id ORDER BY event_ts)
),
leg AS (SELECT * FROM paired WHERE departing),
odo AS (
  SELECT vehicle_id, event_ts, value
  FROM signal_reading WHERE signal = 'odometer'
)
''';

/// Writes the derived trips.
///
/// `trip_id` is derived from `(vehicle_id, start_ts)` rather than random, so a
/// replay reproduces the identical row and a duplicate packet cannot fork a
/// trip in two. That is the backstop; the mechanism is the delete above.
///
/// **Distance** is an `ASOF LEFT JOIN` onto the odometer log at each end —
/// "the last reading at or before this instant" — and NULL when either end has
/// none. An open trip anchors its far end at `infinity`, so its distance is
/// the distance *so far* and grows with the truck. The `o1.event_ts >=` guard
/// keeps a vehicle whose odometer stopped reporting from reporting a negative
/// one.
///
/// **Confidence** is inherited, never computed: a leg built on a crossing the
/// detector flagged `low` is itself `low`.
const insertTrips =
    '''
$tripDerivationQuery
INSERT INTO trip
SELECT leg.vehicle_id || '|' || CAST(epoch_ms(leg.event_ts) AS TEXT),
       leg.vehicle_id,
       leg.exited,
       leg.event_ts,
       leg.dest,
       leg.end_ts,
       CASE WHEN leg.end_ts IS NULL THEN 'IN_PROGRESS' ELSE 'COMPLETED' END,
       CASE WHEN o1.event_ts >= leg.event_ts THEN o1.value - o0.value END,
       CASE WHEN leg.shaky OR coalesce(leg.end_shaky, FALSE)
            THEN 'low' ELSE 'high' END
FROM leg
ASOF LEFT JOIN odo o0
  ON o0.vehicle_id = leg.vehicle_id AND o0.event_ts <= leg.event_ts
ASOF LEFT JOIN odo o1
  ON o1.vehicle_id = leg.vehicle_id
 AND o1.event_ts <= coalesce(leg.end_ts, TIMESTAMP 'infinity')
''';

/// Rebuilds trips for whatever is in `staging_geo_scope`.
///
/// Runs **after** the geofence pass, never beside it: the baseline reads
/// `geofence_containment`, which that pass has just rewritten. Public, and
/// here rather than in the writer, so the tests drive the same two statements
/// in the same order production does.
Future<void> deriveTrips(Connection conn) async {
  await conn.execute(deleteScopedTrips);
  await conn.execute(insertTrips);
}

// ------------------------------------------------------------------ reads --

/// The columns every trip read returns, in one place so the vehicle screen and
/// the fleet screen cannot drift into showing different things.
///
/// Fences are joined `LEFT`: a trip's origin can be a fence that has since
/// been deactivated — which is kept rather than deleted precisely so this join
/// still resolves — and an open trip has no destination at all yet.
const _tripColumns = '''
SELECT t.trip_id, t.vehicle_id, v.reg_no,
       o.name AS origin, d.name AS destination,
       t.start_ts, t.end_ts, t.status, t.distance_km, t.confidence
FROM trip t
JOIN vehicle v USING (vehicle_id)
LEFT JOIN geofence o ON o.geofence_id = t.origin_geofence_id
LEFT JOIN geofence d ON d.geofence_id = t.dest_geofence_id
''';

/// The fleet's trips, running ones first and then newest first.
///
/// Running first because an open trip is the only row on this screen anyone
/// can still act on; a completed one is a record.
String fleetTripsQuery(int limit) =>
    '''
$_tripColumns
ORDER BY t.status = 'COMPLETED', t.start_ts DESC
LIMIT $limit
''';

/// One vehicle's trips, newest first. `\$1` is the vehicle id.
String vehicleTripsQuery(int limit) =>
    '''
$_tripColumns
WHERE t.vehicle_id = \$1
ORDER BY t.start_ts DESC
LIMIT $limit
''';
