/// The status ladder, in one place.
///
/// Lives beside the schema rather than inside a feature because it is a
/// property of the data, not of a screen: the fleet list and the vehicle
/// detail header both make the same claim about the same vehicle, and two
/// copies of this `CASE` would eventually disagree.
library;

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
///   `FILTER` keeps it to a single pass, and the per-signal timestamps come
///   along because freshness is judged per signal, not per vehicle.
/// * `ping`    — vehicle-level last ping is the newest event time from *any*
///   signal or position report (§10, ambiguity 2).
/// * `spec`    — alert thresholds and staleness windows read from
///   `signal_spec`, so they are configuration rather than constants buried in
///   this string.
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
/// * The **alert badge** judges freshness per signal against
///   `signal_spec.max_age_sec`, because the brief scopes thresholds to fresh
///   readings and a threshold is a claim about one signal, not the vehicle.
///
/// STOPPED is the `ELSE`: both "ignition off" and the documented fallback when
/// the deciding signals are too stale to judge.
const scoredCte =
    '''
WITH latest AS (
  SELECT vehicle_id,
         max(value)    FILTER (WHERE signal = 'soc')          AS soc,
         max(event_ts) FILTER (WHERE signal = 'soc')          AS soc_ts,
         max(value)    FILTER (WHERE signal = 'range_km')     AS range_km,
         max(value)    FILTER (WHERE signal = 'speed')        AS speed,
         max(event_ts) FILTER (WHERE signal = 'speed')        AS speed_ts,
         max(value)    FILTER (WHERE signal = 'ignition')     AS ignition,
         max(event_ts) FILTER (WHERE signal = 'ignition')     AS ignition_ts,
         max(value)    FILTER (WHERE signal = 'battery_temp') AS battery_temp,
         max(event_ts) FILTER (WHERE signal = 'battery_temp') AS battery_temp_ts,
         max(event_ts)                                        AS last_signal_ts
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
spec AS (
  SELECT max(max_age_sec) FILTER (WHERE signal = 'soc')          AS soc_age,
         max(max_age_sec) FILTER (WHERE signal = 'battery_temp') AS battery_temp_age,
         max(warn_lo)     FILTER (WHERE signal = 'soc')          AS soc_warn_lo,
         max(crit_lo)     FILTER (WHERE signal = 'soc')          AS soc_crit_lo,
         max(crit_hi)     FILTER (WHERE signal = 'battery_temp') AS temp_crit_hi
  FROM signal_spec
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
         CASE
           WHEN l.battery_temp_ts >= \$1 - to_seconds(s.battery_temp_age)
            AND l.battery_temp > s.temp_crit_hi THEN 'critical'
           WHEN l.soc_ts >= \$1 - to_seconds(s.soc_age)
            AND l.soc < s.soc_crit_lo THEN 'critical'
           WHEN l.soc_ts >= \$1 - to_seconds(s.soc_age)
            AND l.soc < s.soc_warn_lo THEN 'warning'
           ELSE NULL
         END AS alert_severity
  FROM vehicle v
  LEFT JOIN latest l USING (vehicle_id)
  LEFT JOIN ping p USING (vehicle_id)
  CROSS JOIN spec s
)
''';
