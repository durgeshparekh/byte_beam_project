/// Geofence containment and entry/exit detection, in SQL.
///
/// Beside the schema for the same reason as the status ladder and the alert
/// lifecycle: the detector runs on the writer isolate, the counts are read by
/// the geofence screen, and the current fence by vehicle detail.
///
/// The whole pipeline is set-based — window functions over event-time-ordered
/// fixes, no row-at-a-time fold in Dart. That is not a performance flourish:
/// a Dart fold would have to re-read a vehicle's history to resume, and the
/// resume is the hard part.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

/// Fixes worse than this are not evidence of anything. Filtered at read —
/// nothing is ever deleted from the log (ARCHITECTURE.md §7 step 1).
const accuracyGateMetres = 100.0;

/// Minimum hysteresis band around a boundary. A fix reporting 5 m accuracy is
/// still only worth so much, so the band never drops below this.
const minimumBandMetres = 25.0;

/// A confirming pair straddling a gap longer than this is recorded but flagged
/// `low` — the vehicle may have crossed and come back while we were not
/// looking. Nothing is synthesised across the gap either way.
const gapConfidenceCutoff = 'INTERVAL 30 MINUTE';

/// Great-circle distance in metres from fix `l` to fence centre `g`.
///
/// Haversine rather than the spatial extension: this is one expression against
/// a loadable extension, an extra native dependency and a `GEOMETRY` column,
/// for circles. If fences ever become polygons that trade flips.
const _distanceMetres = '''
2 * 6371000 * asin(sqrt(
  pow(sin(radians(l.lat - g.lat) / 2), 2) +
  cos(radians(g.lat)) * cos(radians(l.lat)) *
  pow(sin(radians(l.lon - g.lon) / 2), 2)
))''';

/// Which vehicles to re-derive, and from when.
const geofenceScopeDdl = '''
CREATE TEMP TABLE IF NOT EXISTS staging_geo_scope (
  vehicle_id TEXT, from_ts TIMESTAMP
);
''';

/// Empties the scope table before each derivation.
const clearGeofenceScope = 'DELETE FROM staging_geo_scope';

/// Scopes the derivation to the vehicles in this batch.
///
/// A vehicle whose batch reaches back **behind its own watermark** is replayed
/// from the beginning of its log rather than from the batch: the containment
/// state is the state at the watermark, and a fix from before it invalidates
/// that seed. This is §4 step 4 — "delete derived rows at or after t0,
/// re-derive" — with t0 collapsed to the whole vehicle, because a per-fix t0
/// would need a containment history we do not keep.
///
/// A full replay of one vehicle is a few thousand fixes. A late packet is rare
/// and already counted; paying for it exactly is better than approximating it
/// with a fixed lookback that is wrong at the edges.
const insertGeofenceScope = r'''
INSERT INTO staging_geo_scope
SELECT s.vehicle_id,
       CASE
         WHEN min(s.event_ts) <= max(w.processed_through) THEN TIMESTAMP '-infinity'
         ELSE min(s.event_ts)
       END
FROM staging_location s
LEFT JOIN ingest_watermark w USING (vehicle_id)
GROUP BY s.vehicle_id
''';

/// Puts every vehicle in scope for a full replay. Used when a fence changes.
const insertGeofenceScopeAll = r'''
INSERT INTO staging_geo_scope
SELECT vehicle_id, TIMESTAMP '-infinity' FROM vehicle
''';

/// Removes the derived rows the next pass is about to rewrite.
const deleteScopedTransitions = '''
DELETE FROM geofence_transition t
WHERE EXISTS (
  SELECT 1 FROM staging_geo_scope s
  WHERE s.vehicle_id = t.vehicle_id AND t.event_ts >= s.from_ts
)
''';

/// Clears containment for vehicles being replayed from the beginning.
///
/// Only the full replays: an incremental pass rewrites its rows through the
/// upsert below, and wiping them first would throw away the seed it needs.
const deleteReplayedContainment = r'''
DELETE FROM geofence_containment c
WHERE EXISTS (
  SELECT 1 FROM staging_geo_scope s
  WHERE s.vehicle_id = c.vehicle_id AND s.from_ts = TIMESTAMP '-infinity'
)
''';

/// The detector, as one query. Every stage is a numbered step of §7.1.
///
/// * `probe`   — fixes × fences, gated on accuracy and on the fence having
///   been active **at the fix's event time**, so activation is time-versioned
///   and a recompute is pure (step 8).
/// * `opinion` — inside if `d ≤ r − h`, outside if `d ≥ r + h`. A fix in the
///   band has *no opinion* and is dropped rather than carried as a weak vote;
///   that is what makes the band genuinely inert instead of a source of
///   flapping (step 2).
/// * `seeded`  — the state left by the previous pass, injected as if it were
///   the last opinionated fix before the window. This is what lets an
///   incremental pass read two fixes instead of a whole history.
/// * `seq`     — `lag` over the opinionated sequence only.
/// * `decided` — a crossing is confirmed by **two consecutive opinionated
///   fixes agreeing**, or by a single fix more than `2h` clear of the boundary
///   (step 4: a truck doing 60 through a fence edge should not need a second
///   fix to prove it left).
/// * `settled` — carry the confirmed zone forward with `last_value ... IGNORE
///   NULLS`, so each row knows the zone that was established *before* it.
///
/// A transition is emitted where a confirmation disagrees with the established
/// zone. It is stamped with the **first** fix of the confirming pair, which is
/// when the vehicle actually crossed, not when we became sure (step 5).
///
/// The first confirmation on a cold start establishes a zone and emits
/// nothing: we have learned where the truck is, not watched it go there.
const geofenceTransitionQuery =
    '''
WITH probe AS (
  SELECT l.vehicle_id,
         g.geofence_id,
         l.event_ts,
         $_distanceMetres AS d,
         g.radius_m,
         greatest($minimumBandMetres, coalesce(l.accuracy_m, 0)) AS band
  FROM location_fix l
  JOIN staging_geo_scope s
    ON s.vehicle_id = l.vehicle_id AND l.event_ts >= s.from_ts
  JOIN geofence g
    ON l.event_ts >= g.active_from
   AND (g.active_to IS NULL OR l.event_ts < g.active_to)
  WHERE coalesce(l.accuracy_m, 0) <= $accuracyGateMetres
),
opinion AS (
  SELECT vehicle_id,
         geofence_id,
         event_ts,
         CASE WHEN d <= radius_m - band THEN 'IN'
              WHEN d >= radius_m + band THEN 'OUT' END AS zone,
         abs(d - radius_m) > 2 * band AS decisive,
         FALSE AS is_seed,
         CAST(NULL AS TEXT) AS seed_zone
  FROM probe
),
seeded AS (
  SELECT c.vehicle_id,
         c.geofence_id,
         c.pending_ts AS event_ts,
         c.pending_zone AS zone,
         FALSE AS decisive,
         TRUE AS is_seed,
         c.zone AS seed_zone
  FROM geofence_containment c
  JOIN staging_geo_scope s ON s.vehicle_id = c.vehicle_id
  WHERE c.pending_zone IS NOT NULL AND c.pending_ts < s.from_ts
),
ordered AS (
  SELECT * FROM opinion WHERE zone IS NOT NULL
  UNION ALL
  SELECT * FROM seeded
),
seq AS (
  SELECT *,
         lag(zone)     OVER w AS prev_zone,
         lag(event_ts) OVER w AS prev_ts
  FROM ordered
  WINDOW w AS (PARTITION BY vehicle_id, geofence_id ORDER BY event_ts)
),
decided AS (
  SELECT *,
         CASE
           WHEN is_seed THEN seed_zone
           WHEN zone = prev_zone OR decisive THEN zone
         END AS confirmed_zone,
         CASE WHEN zone = prev_zone THEN prev_ts ELSE event_ts END AS crossed_ts
  FROM seq
),
settled AS (
  SELECT *,
         last_value(confirmed_zone IGNORE NULLS) OVER (
           PARTITION BY vehicle_id, geofence_id ORDER BY event_ts
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
         ) AS prior_zone
  FROM decided
)
''';

/// Writes the confirmed crossings.
///
/// `ON CONFLICT DO NOTHING` against `(vehicle_id, geofence_id, event_ts)`
/// rather than as the deduplication mechanism: the delete above already
/// cleared the range being rewritten. What this catches is the one transition
/// that can land *before* the window — a pair whose first fix was already
/// folded in as the seed — which is a genuine crossing we simply could not
/// confirm last time.
const insertGeofenceTransitions =
    '''
$geofenceTransitionQuery
INSERT INTO geofence_transition
SELECT vehicle_id,
       geofence_id,
       crossed_ts,
       CASE confirmed_zone WHEN 'IN' THEN 'ENTRY' ELSE 'EXIT' END,
       CASE WHEN prev_ts IS NULL
                 OR event_ts - prev_ts > $gapConfidenceCutoff
            THEN 'low' ELSE 'high' END
FROM settled
WHERE NOT is_seed
  AND confirmed_zone IS NOT NULL
  AND prior_zone IS NOT NULL
  AND confirmed_zone <> prior_zone
ON CONFLICT DO NOTHING
''';

/// Folds the pass's end state back into the containment table.
///
/// One row per (vehicle, fence): the zone established by the end of the
/// window, and the last fix that had an opinion at all. The next pass resumes
/// from exactly here, which is the entire reason an ingest batch costs two
/// fixes of work rather than a history.
const upsertGeofenceContainment =
    '''
$geofenceTransitionQuery
INSERT INTO geofence_containment AS c
SELECT vehicle_id,
       geofence_id,
       coalesce(confirmed_zone, prior_zone),
       zone,
       event_ts
FROM settled
QUALIFY row_number() OVER (
  PARTITION BY vehicle_id, geofence_id ORDER BY event_ts DESC
) = 1
ON CONFLICT (vehicle_id, geofence_id) DO UPDATE
  SET zone = excluded.zone,
      pending_zone = excluded.pending_zone,
      pending_ts = excluded.pending_ts
''';

/// Runs one derivation pass over whatever is in `staging_geo_scope`.
///
/// Public, and here rather than in the writer, so the tests drive the same
/// four statements in the same order production does.
Future<void> deriveGeofences(Connection conn) async {
  await conn.execute(deleteScopedTransitions);
  await conn.execute(deleteReplayedContainment);
  await conn.execute(insertGeofenceTransitions);
  await conn.execute(upsertGeofenceContainment);
}

/// Scopes every vehicle for a full replay and re-derives.
///
/// What a fence edit triggers. It recomputes *all* fences, not just the one
/// that changed, and that is deliberate: derived state is dropped and rebuilt
/// (§3.5), and one path that is always right beats two that are usually
/// right. Editing a fence is rare, user-initiated, and can afford to be slow;
/// a subtly wrong incremental path cannot.
Future<void> recomputeAllGeofences(Connection conn) async {
  await conn.execute(geofenceScopeDdl);
  await conn.execute(clearGeofenceScope);
  await conn.execute(insertGeofenceScopeAll);
  await deriveGeofences(conn);
}

// ------------------------------------------------------------- fence CRUD --

/// Writes a fence, creating or replacing it.
///
/// The caller always sends the **whole** fence, including its active window,
/// so creating, renaming, moving, deactivating and reactivating are one
/// statement rather than five. The UI is the only writer of this table and it
/// reads before it writes, so a read-modify-write here loses nothing.
const upsertGeofence = r'''
INSERT INTO geofence VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (geofence_id) DO UPDATE SET
  name = excluded.name,
  lat = excluded.lat,
  lon = excluded.lon,
  radius_m = excluded.radius_m,
  active_from = excluded.active_from,
  active_to = excluded.active_to,
  updated_at = excluded.updated_at
''';

// ------------------------------------------------------------------ reads --

/// Every fence with how many vehicles are inside it right now.
///
/// Active fences first, then deactivated ones — which are kept rather than
/// deleted, because a trip that ended at a depot still has to be able to name
/// it a year later.
const geofenceOccupancyQuery = '''
SELECT g.*,
       (SELECT count(*) FROM geofence_containment c
        WHERE c.geofence_id = g.geofence_id AND c.zone = 'IN') AS inside
FROM geofence g
ORDER BY g.active_to IS NOT NULL, g.name
''';

/// The one fence to name as a vehicle's location.
///
/// Containment is tracked per fence, so a truck in a bay inside a depot is
/// genuinely inside two. The single value the UI wants is the **smallest
/// radius** containing it, tie-broken by id — the most specific true answer
/// (ARCHITECTURE.md §10, ambiguity 10). There is no "current fence" column
/// anywhere, because under nesting there is no such thing.
const currentGeofenceQuery = r'''
SELECT g.name, g.radius_m
FROM geofence_containment c
JOIN geofence g USING (geofence_id)
WHERE c.vehicle_id = $1 AND c.zone = 'IN' AND g.active_to IS NULL
QUALIFY row_number() OVER (ORDER BY g.radius_m, g.geofence_id) = 1
''';

/// One vehicle's most recent crossings, newest first.
///
/// Joins deactivated fences too: a crossing that happened while the fence was
/// live is still a fact about the truck.
String recentTransitionsQuery(int limit) =>
    '''
SELECT g.name, t.kind, t.event_ts, t.confidence
FROM geofence_transition t
JOIN geofence g USING (geofence_id)
WHERE t.vehicle_id = \$1
ORDER BY t.event_ts DESC
LIMIT $limit
''';
