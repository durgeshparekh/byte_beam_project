/// The scale exercise's backfill: 500 vehicles and a couple of million signal
/// rows, generated **inside DuckDB**.
///
/// Generating the rows in Dart and pushing them across the FFI boundary would
/// take minutes; `range()` cross-joined against itself takes seconds, because
/// nothing ever leaves the engine. That is the whole technique — one statement
/// per table, no loop anywhere.
///
/// Values are deterministic rather than `random()`. Two reasons: re-running
/// the backfill then inserts nothing, because every row collides with the
/// natural key; and a fleet list of plausible numbers is a demo, where one
/// full of noise is a screenshot of a bug report.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

import 'alert_sql.dart';
import 'geofence_sql.dart';
import 'trip_sql.dart';

/// The six signals from `signal_spec`.
///
/// All six, because the register, the verdict pills and the alert evaluator
/// all read that table, and a backfill that skipped one would leave a
/// permanent "—" on every vehicle detail screen.
const _signals =
    "(VALUES ('soc'), ('range_km'), ('speed'), "
    "('battery_temp'), ('odometer'), ('ignition')) AS s(signal)";

/// Per-signal value, as a function of vehicle index and tick.
///
/// `sin` of a stride coprime with the tick count gives each vehicle its own
/// slow wander rather than 500 copies of one curve. The odometer is monotone
/// in *time* — `ticks - t.i`, since tick 0 is the newest — because an odometer
/// that runs backwards makes every trip distance negative.
String _valueExpr(int ticks) =>
    '''
    CASE s.signal
      WHEN 'odometer' THEN round(80000 + v.i * 137 + ($ticks - t.i) * 1.7, 1)
      WHEN 'ignition' THEN CASE WHEN (v.i + t.i) % 11 = 0 THEN 0 ELSE 1 END
      WHEN 'soc'      THEN round(12 + 76 * abs(sin((v.i * 7 + t.i) / 53.0)), 1)
      WHEN 'range_km' THEN round(35 + 380 * abs(sin((v.i * 7 + t.i) / 53.0)), 1)
      WHEN 'speed'    THEN round(78 * abs(sin((v.i * 3 + t.i) / 17.0)), 1)
      ELSE                 round(21 + 27 * abs(sin((v.i + t.i) / 29.0)), 1)
    END''';

/// Backfills [vehicles] trucks with [ticks] reports each, ending at [now].
///
/// Reports land at [interval], the cadence a real feed would use, so the log
/// is *dense*: 500 vehicles x 700 reports at ten seconds is about two hours of
/// history, not two weeks of one reading every half hour. Density is what
/// makes the fleet list look like a fleet and what gives retention something
/// to compress — a log sparser than the rollup bucket compacts nothing.
///
/// Returns row counts and the wall-clock split between loading the log and
/// re-deriving everything on top of it. The second number is the interesting
/// one, and the one a reader would otherwise assume was zero.
///
/// Runs in the caller's transaction. The caller is the writer isolate, which
/// is the only thing in the process allowed to write at all.
Future<Map<String, int>> backfillFleet(
  Connection conn, {
  required DateTime now,
  int vehicles = 500,
  int ticks = 700,
  Duration interval = const Duration(seconds: 10),
}) async {
  final step = interval.inSeconds;
  // The instant is spliced in as a SQL literal rather than bound. These are
  // one-shot statements built here and nowhere else, and a UTC ISO-8601
  // timestamp is unambiguous — the reason to bind (losing a time zone) does
  // not apply to a value that carries none.
  final end = "TIMESTAMP '${now.toIso8601String()}'";
  final loading = Stopwatch()..start();

  // Plates are the backfill's own series, so a backfilled fleet is
  // distinguishable from a simulated one at a glance and the two can share a
  // database without colliding.
  await conn.execute('''
    INSERT INTO vehicle
    SELECT 'bf-' || i, 'KA99BF' || lpad(CAST(i AS TEXT), 4, '0'), 'eT 1000'
    FROM range(0, $vehicles) r(i)
    ON CONFLICT DO NOTHING
  ''');

  await conn.execute('''
    INSERT INTO signal_reading
    SELECT 'bf-' || v.i,
           s.signal,
           $end - to_seconds(t.i * $step),
           ${_valueExpr(ticks)},
           CAST(now() AS TIMESTAMP)
    FROM range(0, $vehicles) v(i)
    CROSS JOIN $_signals
    CROSS JOIN range(0, $ticks) t(i)
    ON CONFLICT DO NOTHING
  ''');

  // One position per report, the way the simulator emits them. Vehicles are
  // spread over a patch a few kilometres across, centred between the seeded
  // fences, so a real proportion of them are inside one and the geofence and
  // trip derivations get something to chew on instead of an empty scope.
  await conn.execute('''
    INSERT INTO location_fix
    SELECT 'bf-' || v.i,
           $end - to_seconds(t.i * $step),
           12.9600 + 0.055 * sin((v.i * 11 + t.i) / 41.0),
           77.6000 + 0.055 * cos((v.i * 13 + t.i) / 37.0),
           8,
           CAST(now() AS TIMESTAMP)
    FROM range(0, $vehicles) v(i)
    CROSS JOIN range(0, $ticks) t(i)
    ON CONFLICT DO NOTHING
  ''');

  loading.stop();
  final deriving = Stopwatch()..start();
  await rebuildDerivedState(conn, now);
  deriving.stop();

  final counts = await conn.query('''
    SELECT (SELECT count(*) FROM vehicle),
           (SELECT count(*) FROM signal_reading),
           (SELECT count(*) FROM location_fix)
  ''');
  final row = counts.fetchOne()!;
  return {
    'vehicles': (row[0]! as num).toInt(),
    'signal_rows': (row[1]! as num).toInt(),
    'location_rows': (row[2]! as num).toInt(),
    'load_ms': loading.elapsedMilliseconds,
    'derive_ms': deriving.elapsedMilliseconds,
  };
}

/// Rebuilds every class D table from the log, then parks the watermark at the
/// end of it.
///
/// Bulk-loading the log leaves the derived tables describing a fleet that no
/// longer exists. §3.5's whole claim is that derived state is droppable and
/// rebuildable; this is that claim executed — the same derivations ingest
/// runs, over the whole log instead of one batch.
Future<void> rebuildDerivedState(Connection conn, DateTime now) async {
  await conn.execute('''
    INSERT INTO vehicle_signal_latest AS l
    SELECT vehicle_id, signal, event_ts, value
    FROM (
      SELECT DISTINCT ON (vehicle_id, signal)
             vehicle_id, signal, event_ts, value
      FROM signal_reading
      ORDER BY vehicle_id, signal, event_ts DESC
    )
    ON CONFLICT (vehicle_id, signal) DO UPDATE
      SET value = excluded.value, event_ts = excluded.event_ts
      WHERE excluded.event_ts > l.event_ts
  ''');

  await evaluateAlerts(conn, now);
  await recomputeAllGeofences(conn);
  await deriveTrips(conn);

  await conn.execute('''
    INSERT INTO ingest_watermark AS w
    SELECT vehicle_id, max(event_ts) FROM (
      SELECT vehicle_id, event_ts FROM signal_reading
      UNION ALL
      SELECT vehicle_id, event_ts FROM location_fix
    ) GROUP BY vehicle_id
    ON CONFLICT (vehicle_id) DO UPDATE
      SET processed_through = excluded.processed_through
      WHERE excluded.processed_through > w.processed_through
  ''');
}
