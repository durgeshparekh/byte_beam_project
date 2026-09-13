/// The alert lifecycle, in SQL.
///
/// Beside the schema rather than inside the alerts feature for the same reason
/// as `vehicle_status_sql.dart`: the *evaluator* runs on the writer isolate
/// (which belongs to ingest) while the *badge* is read by the fleet query and
/// the *list* by the alerts screen. Three callers, one definition of what an
/// open alert is.
///
/// **Parameter contract: `\$1` is the instant to evaluate against.** Positional
/// rather than named because these statements open with `WITH` and DuckDB
/// 1.2.1 cannot resolve a second *named* parameter in one — see `scoredCte`.
/// A repeated `\$1` still counts as a single parameter.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

/// What makes an alert visible: not yet resolved, not yet dismissed.
///
/// Resolution and dismissal are independent on purpose (ARCHITECTURE.md §6).
/// Resolution says the condition went away; dismissal says a human looked at
/// it. Either one hides the row, and only resolution ends the episode.
const openAlertPredicate = 'resolved_at IS NULL AND dismissed_at IS NULL';

/// How far back inside a threshold a reading must come before the episode is
/// closed: 2 percentage points of SOC, 2 degrees of battery temperature.
///
/// Without a band, a truck idling at 45.2 C opens and closes the same alert
/// every time the reading wobbles across the line. A real simulator run
/// produced **seven episodes on one vehicle in 114 seconds** — which makes the
/// record useless and makes the card say "raised 2s ago" about a truck that
/// has been hot for two minutes.
///
/// One constant rather than a column, because two signals happen to want the
/// same number in different units. The moment a third wants a different one it
/// belongs in `signal_spec`, beside the thresholds it modifies.
const alertClearBand = 2.0;

/// Scratch table holding what we can currently *see*, rebuilt every evaluation.
///
/// One row per (vehicle, alert type) for which there is a **fresh** reading:
///
/// * `severity` non-null — breached now, at that severity;
/// * `cleared` true — back inside the threshold by more than [alertClearBand];
/// * neither — fresh, but sitting in the hysteresis band. Left alone.
///
/// No row at all means no fresh reading, which is also left alone. That is the
/// staleness rule expressed as an absence: **an episode ends when we watch it
/// end, not when we stop looking.**
///
/// A table rather than a CTE shared across the three lifecycle statements,
/// because a CTE cannot span statements and repeating it three times would
/// give three chances to drift. It is TEMP, so it belongs to the writer's
/// connection and never touches the file — the same idiom as the ingest
/// staging tables.
const alertConditionDdl = '''
CREATE TEMP TABLE IF NOT EXISTS staging_alert_condition (
  vehicle_id TEXT, alert_type TEXT, severity TEXT, cleared BOOLEAN
);
''';

/// Empties the scratch table before each evaluation.
const clearAlertCondition = 'DELETE FROM staging_alert_condition';

/// Reads every vehicle's fresh battery state into the scratch table.
///
/// Fleet-wide rather than limited to the vehicles in this batch: scoping it to
/// the batch would mean a vehicle whose reading has not moved never gets
/// re-examined. At 500 vehicles it is a few thousand rows.
///
/// `fresh` nulls out any reading older than its own `signal_spec.max_age_sec`,
/// and the `WHERE ... IS NOT NULL` then drops that vehicle from the set
/// entirely. That is what makes "thresholds apply to fresh readings only" a
/// property of the data rather than a clause each rule remembers — and it is
/// what leaves an alert on a truck that has gone quiet *untouched*, instead of
/// quietly resolving it.
///
/// The two SOC bands are one row with two severities, not two alerts.
const insertAlertCondition =
    '''
INSERT INTO staging_alert_condition
WITH spec AS (
  SELECT max(max_age_sec) FILTER (WHERE signal = 'soc')          AS soc_age,
         max(max_age_sec) FILTER (WHERE signal = 'battery_temp') AS temp_age,
         max(warn_lo)     FILTER (WHERE signal = 'soc')          AS soc_warn_lo,
         max(crit_lo)     FILTER (WHERE signal = 'soc')          AS soc_crit_lo,
         max(crit_hi)     FILTER (WHERE signal = 'battery_temp') AS temp_crit_hi
  FROM signal_spec
),
fresh AS (
  SELECT l.vehicle_id,
         max(l.value) FILTER (
           WHERE l.signal = 'soc'
             AND l.event_ts >= \$1 - to_seconds(s.soc_age)
         ) AS soc,
         max(l.value) FILTER (
           WHERE l.signal = 'battery_temp'
             AND l.event_ts >= \$1 - to_seconds(s.temp_age)
         ) AS battery_temp
  FROM vehicle_signal_latest l CROSS JOIN spec s
  GROUP BY l.vehicle_id
)
SELECT f.vehicle_id,
       'battery_low',
       CASE WHEN f.soc < s.soc_crit_lo THEN 'critical'
            WHEN f.soc < s.soc_warn_lo THEN 'warning' END,
       f.soc >= s.soc_warn_lo + $alertClearBand
FROM fresh f CROSS JOIN spec s
WHERE f.soc IS NOT NULL
UNION ALL
SELECT f.vehicle_id,
       'battery_overheat',
       CASE WHEN f.battery_temp > s.temp_crit_hi THEN 'critical' END,
       f.battery_temp <= s.temp_crit_hi - $alertClearBand
FROM fresh f CROSS JOIN spec s
WHERE f.battery_temp IS NOT NULL
''';

/// Closes every open episode we have *watched* come back inside its threshold.
///
/// `EXISTS ... AND c.cleared`, not `NOT EXISTS`: a missing row means no fresh
/// reading, and no reading is not evidence of recovery. A truck that dies at
/// 5 % SOC keeps its alert — the fleet list will also show it OFFLINE, and
/// between them that is the honest picture. The cost is that a vehicle which
/// never reports again keeps its alert forever, the same call as a trip whose
/// vehicle never returns (ARCHITECTURE.md §10, ambiguities 6 and 12).
///
/// Ignores `dismissed_at` deliberately: an alert the user waved away still
/// resolves when the truck is plugged in. Dismissal suppresses the episode,
/// resolution ends it, and only an ended episode can be raised again.
const resolveClearedAlerts = r'''
UPDATE alert SET resolved_at = $1
WHERE resolved_at IS NULL
  AND EXISTS (
    SELECT 1 FROM staging_alert_condition c
    WHERE c.vehicle_id = alert.vehicle_id
      AND c.alert_type = alert.alert_type
      AND c.cleared
  )
''';

/// Moves an open episode between severities in place.
///
/// This is the escalation rule from the brief: SOC 18 % -> 8 % is the *same*
/// alert turning critical, not a second one. Recovering to 15 % walks it back
/// down the same way. `escalated_at` is stamped only on the way up and kept
/// afterwards, so "this one went critical at some point" survives a recovery.
///
/// Escalating also **undoes a dismissal**. "I am on it" at 18 % is not consent
/// to ignore 8 %: the user answered a question about a warning, and this is no
/// longer that warning. The reason is cleared with it rather than left
/// standing against a state it was never given for.
///
/// Unlike resolution, severity moves on the bare thresholds with no hysteresis
/// band. The episode exists either way, so there are no rows to churn — this
/// is a live readout inside one episode, not a decision to open or close one.
const rescoreOpenAlerts = r'''
UPDATE alert SET
  severity = c.severity,
  escalated_at = CASE
    WHEN c.severity = 'critical' AND alert.severity <> 'critical' THEN $1
    ELSE alert.escalated_at
  END,
  dismissed_at = CASE
    WHEN c.severity = 'critical' AND alert.severity <> 'critical' THEN NULL
    ELSE alert.dismissed_at
  END,
  dismiss_reason = CASE
    WHEN c.severity = 'critical' AND alert.severity <> 'critical' THEN NULL
    ELSE alert.dismiss_reason
  END
FROM staging_alert_condition c
WHERE c.vehicle_id = alert.vehicle_id
  AND c.alert_type = alert.alert_type
  AND c.severity IS NOT NULL
  AND alert.resolved_at IS NULL
  AND alert.severity <> c.severity
''';

/// Opens an episode for every breach that does not already have one.
///
/// `NOT EXISTS` over open episodes is what keeps this idempotent: running the
/// evaluator twice on the same state raises nothing the second time, which is
/// the property that lets it run after every batch without bookkeeping.
///
/// The id is derived rather than random so a replay produces the same row.
/// Two episodes of one type on one vehicle cannot share an instant — the first
/// has to resolve before the second can be raised, and resolution and raising
/// never happen in the same pass.
const raiseNewAlerts = r'''
INSERT INTO alert
  (alert_id, vehicle_id, alert_type, severity, raised_at, escalated_at)
SELECT c.vehicle_id || '|' || c.alert_type || '|' || CAST(epoch_ms($1) AS TEXT),
       c.vehicle_id,
       c.alert_type,
       c.severity,
       $1,
       CASE WHEN c.severity = 'critical' THEN $1 END
FROM staging_alert_condition c
WHERE c.severity IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM alert a
    WHERE a.vehicle_id = c.vehicle_id
      AND a.alert_type = c.alert_type
      AND a.resolved_at IS NULL
  )
''';

/// Hides one alert and records why. `$1` id, `$2` instant, `$3` reason.
const dismissAlert = r'''
UPDATE alert SET dismissed_at = $2, dismiss_reason = $3 WHERE alert_id = $1
''';

/// Puts a dismissed alert back. A separate statement rather than [dismissAlert]
/// with null parameters: binding a typed NULL through the prepared-statement
/// API is one more thing that can be wrong at runtime, and `SET x = NULL` in
/// the text cannot be.
const restoreAlert = r'''
UPDATE alert SET dismissed_at = NULL, dismiss_reason = NULL WHERE alert_id = $1
''';

/// Which signal each alert type watches, as a two-row inline relation.
///
/// Code-level configuration, so a table would mean a migration to say the same
/// thing. Joined into the read query to pick up the current value, its unit,
/// and the freshness window the card needs to say "no fresh reading since" —
/// rather than hard-coding "%", "C" and 300 seconds.
const alertSignalMap =
    "(VALUES ('battery_low', 'soc'), ('battery_overheat', 'battery_temp'))"
    ' AS m(alert_type, signal)';

/// Folds the current fleet state into the alert table.
///
/// Four statements in a fixed order, and the order is the whole design:
///
/// 1. read what we can currently see, from fresh readings only;
/// 2. resolve every open episode we have watched come back inside;
/// 3. move the severity of those still breached, escalating in place;
/// 4. raise an episode for any breach that has none.
///
/// Resolve runs before raise so a condition that clears and re-triggers within
/// one batch closes the old episode rather than silently extending it. The
/// whole thing is a pure function of `vehicle_signal_latest` and [now] — run
/// it twice and the second run is a no-op, which is what makes it safe to call
/// after every batch without tracking what it has already seen.
///
/// It runs inside the caller's transaction, alongside the watermark, so
/// derived state and the position it was derived from commit together.
///
/// Public, and here rather than in the writer, so the tests drive the same
/// four statements in the same order that production does. A test that
/// reimplemented this sequence would only prove the sequence it reimplemented.
Future<void> evaluateAlerts(Connection conn, DateTime now) async {
  // The DDL lives here rather than in the caller's setup so no connection can
  // reach the evaluator without the scratch table it needs.
  await conn.execute(alertConditionDdl);
  await conn.execute(clearAlertCondition);
  await execAlertSql(conn, insertAlertCondition, [now]);
  await execAlertSql(conn, resolveClearedAlerts, [now]);
  await execAlertSql(conn, rescoreOpenAlerts, [now]);
  await execAlertSql(conn, raiseNewAlerts, [now]);
}

/// Runs a parameterised statement. These take a timestamp, and interpolating
/// one into SQL text is how time zones get lost.
Future<void> execAlertSql(
  Connection conn,
  String sql,
  List<Object?> params,
) async {
  final statement = await conn.prepare(sql);
  try {
    statement.bindParams(params);
    await statement.execute();
  } finally {
    await statement.dispose();
  }
}
