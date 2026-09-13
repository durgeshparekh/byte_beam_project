import 'package:byte_beam_project/db/backfill_sql.dart';
import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/db/vehicle_status_sql.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final now = DateTime.utc(2026, 1, 8, 12);

/// The scale exercise's backfill, at a size a test can afford.
///
/// 20 vehicles rather than 500: the properties asserted here — row count,
/// idempotence, derived state rebuilt, odometer monotone — are the same at
/// both sizes, and the numbers that only matter at 500 are measurements
/// rather than assertions. Those are in `docs/07-scale.md`, with the device
/// they came from.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    conn = db.read;
  });
  tearDown(() => db.close());

  Future<Map<String, int>> backfill() =>
      backfillFleet(conn, now: now, vehicles: 20, ticks: 30);

  Future<Object?> one(String sql) async =>
      (await conn.query(sql)).fetchOne()?.first;

  test('generates six signals per vehicle per tick', () async {
    final result = await backfill();

    expect(result['vehicles'], 20);
    expect(result['signal_rows'], 20 * 30 * 6);
    expect(result['location_rows'], 20 * 30);
  });

  // Deterministic values plus a natural key: the second run has nothing new to
  // say. That is what makes the button safe to press twice.
  test('running it again inserts nothing', () async {
    await backfill();
    final second = await backfill();

    expect(second['signal_rows'], 20 * 30 * 6);
    expect(second['location_rows'], 20 * 30);
  });

  test('every generated signal is one the spec table knows about', () async {
    await backfill();

    expect(
      await one('''
        SELECT count(*) FROM (
          SELECT DISTINCT signal FROM signal_reading
          WHERE signal NOT IN (SELECT signal FROM signal_spec)
        )
      '''),
      0,
      reason: 'a signal outside signal_spec gets no register row and no pill',
    );
  });

  // A backwards odometer makes every trip distance negative.
  test('the odometer only ever increases', () async {
    await backfill();

    expect(
      await one('''
        SELECT count(*) FROM (
          SELECT value - lag(value) OVER (
                   PARTITION BY vehicle_id ORDER BY event_ts
                 ) AS delta
          FROM signal_reading WHERE signal = 'odometer'
        ) WHERE delta < 0
      '''),
      0,
    );
  });

  group('derived state', () {
    // §3.5's claim is that class D is droppable and rebuildable. A bulk load
    // straight into the log is the case that proves it or does not.
    test('the latest-value table is rebuilt from the log', () async {
      await backfill();

      expect(await one('SELECT count(*) FROM vehicle_signal_latest'), 20 * 6);
      expect(
        await one('''
          SELECT count(*) FROM vehicle_signal_latest l
          WHERE l.event_ts <> (
            SELECT max(event_ts) FROM signal_reading r
            WHERE r.vehicle_id = l.vehicle_id AND r.signal = l.signal
          )
        '''),
        0,
      );
    });

    test('the fleet query answers for every backfilled vehicle', () async {
      await backfill();

      final statement = await conn.prepare(fleetRowsQuery());
      addTearDown(statement.dispose);
      statement.bindParams([now]);
      expect((await statement.execute()).fetchAll(), hasLength(20));
    });

    test('containment and the watermark are both populated', () async {
      await backfill();

      expect(
        (await one('SELECT count(*) FROM geofence_containment'))! as int,
        greaterThan(0),
      );
      expect(await one('SELECT count(*) FROM ingest_watermark'), 20);
    });
  });
}
