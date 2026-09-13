/// The status ladder, in one place.
///
/// Lives beside the schema rather than inside a feature because it is a
/// property of the data, not of a screen: the fleet list and the vehicle
/// detail header both make the same claim about the same vehicle, and two
/// copies of this `CASE` would eventually disagree.
library;

import 'alert_sql.dart';

/// How long without any report before a vehicle counts as offline.
const offlineAfter = 'INTERVAL 10 MINUTE';

/// The shared prefix: every fleet query selects from `scored`.
///
/// **Parameter contract: `$1` is the instant to evaluate freshness against**,
/// and a statement built on this CTE binds it first. Numbered parameters
/// rather than named ones because DuckDB 1.2.1 cannot resolve a *second*
/// named parameter in a statement that opens with `WITH` — it reports two
/// parameters and then fails the name lookup for the one outside the CTE.
/// Numbered binding has no such problem, and a repeated `$1` still counts
/// once.
///
/// Four stages, each earning its place:
///
/// * `latest`  — pivots the long-format latest table into one row per vehicle.
///   `FILTER` keeps it to a single pass. Only the signals the ladder actually
///   consults are pivoted; battery temperature left when the badge stopped
///   being computed here.
/// * `ping`    — vehicle-level last ping is the newest event time from *any*
///   signal or position report (§10, ambiguity 2).
/// * `badge`   — the worst open alert per vehicle, read from the `alert`
///   table rather than recomputed from thresholds here. The badge and the
///   alerts screen therefore cannot disagree, and a dismissed alert stops
///   showing a red dot on the list.
/// * `scored`  — the first-match-wins status and the alert badge.
///
/// Two windows, deliberately different, because they back claims of different
/// scope:
///
/// * The **status ladder** judges freshness against the same 10-minute window
///   that decides OFFLINE. Status is a vehicle-level claim, so its inputs get
///   the vehicle's own liveness window. A speed 40 minutes old cannot claim
///   MOVING, but a truck reporting every six minutes is still MOVING —
///   scoring the ladder against the 5-minute per-signal window instead would
///   leave a dead band between 5 and 10 minutes where every online vehicle
///   reads STOPPED (§10, ambiguity 1).
/// * The **alert badge** carries no window of its own. Freshness was already
///   applied per signal, against `signal_spec.max_age_sec`, when the evaluator
///   raised the alert (see `alert_sql.dart`) — the badge only reports what the
///   evaluator concluded. That makes the badge *derived state*: it lags the
///   log by one ingest batch and can never lead it, which is the rule for
///   every class D table (§3.4).
///
/// STOPPED is the `ELSE`: both "ignition off" and the documented fallback when
/// the deciding signals are too stale to judge.
const scoredCte =
    '''
WITH latest AS (
  SELECT vehicle_id,
         max(value)    FILTER (WHERE signal = 'soc')      AS soc,
         max(value)    FILTER (WHERE signal = 'range_km') AS range_km,
         max(value)    FILTER (WHERE signal = 'speed')    AS speed,
         max(event_ts) FILTER (WHERE signal = 'speed')    AS speed_ts,
         max(value)    FILTER (WHERE signal = 'ignition') AS ignition,
         max(event_ts) FILTER (WHERE signal = 'ignition') AS ignition_ts,
         max(event_ts)                                    AS last_signal_ts
  FROM vehicle_signal_latest
  GROUP BY vehicle_id
),
ping AS (
  SELECT vehicle_id, max(event_ts) AS last_ping
  FROM (
    SELECT vehicle_id, last_signal_ts AS event_ts FROM latest
    UNION ALL
    SELECT vehicle_id, max(event_ts) AS event_ts FROM location_fix GROUP BY vehicle_id
  )
  GROUP BY vehicle_id
),
badge AS (
  SELECT vehicle_id,
         CASE WHEN bool_or(severity = 'critical') THEN 'critical' ELSE 'warning' END
           AS alert_severity
  FROM alert
  WHERE $openAlertPredicate
  GROUP BY vehicle_id
),
scored AS (
  SELECT v.vehicle_id,
         v.reg_no,
         v.model,
         l.soc,
         l.range_km,
         l.speed,
         p.last_ping,
         CASE
           WHEN p.last_ping IS NULL OR p.last_ping < \$1 - $offlineAfter
             THEN 'OFFLINE'
           WHEN l.speed_ts >= \$1 - $offlineAfter AND l.speed > 0
             THEN 'MOVING'
           WHEN l.speed_ts >= \$1 - $offlineAfter AND l.speed = 0
            AND l.ignition_ts >= \$1 - $offlineAfter
            AND l.ignition = 1
             THEN 'IDLE'
           ELSE 'STOPPED'
         END AS status,
         b.alert_severity
  FROM vehicle v
  LEFT JOIN latest l USING (vehicle_id)
  LEFT JOIN ping p USING (vehicle_id)
  LEFT JOIN badge b USING (vehicle_id)
)
''';

/// The two statements one fleet-list refresh runs: the chip counts, and the
/// rows for the selected chip.
///
/// Here rather than inline in the data source because the scale exercise
/// benchmarks them (§8). A benchmark of a *different* query is worth less than
/// no benchmark, and two copies of a statement are two chances to drift.
const fleetCountsQuery =
    '$scoredCte SELECT status, count(*) FROM scored GROUP BY status';

/// Rows for one chip, or all of them when [where] is empty.
///
/// Ordered by registration so the list is stable between refreshes — an order
/// that jumps as speeds change is unreadable.
String fleetRowsQuery([String where = '']) =>
    '$scoredCte SELECT vehicle_id, reg_no, model, status, soc, range_km, '
    'speed, last_ping, alert_severity FROM scored $where ORDER BY reg_no';
