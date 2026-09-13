import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/db/retention_sql.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final now = DateTime.utc(2026, 1, 15, 12);

/// The retention policy, executed rather than described.
///
/// An append-only log grows forever, so this is the part of the design that
/// decides what the app *stops* being able to answer. These tests pin both
/// halves: what survives, and what is deliberately lost.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    conn = db.read;
    await conn.execute("INSERT INTO vehicle VALUES ('v1', 'KA01AA0001', 'eT')");
  });
  tearDown(() => db.close());

  /// A reading [daysAgo] before [now], offset by [minutes] within that day.
  Future<void> reading(
    int daysAgo,
    double value, {
    int minutes = 0,
    String signal = 'soc',
  }) {
    final ts = now
        .subtract(Duration(days: daysAgo))
        .add(Duration(minutes: minutes));
    return conn.execute(
      "INSERT INTO signal_reading VALUES ('v1', '$signal', "
      "TIMESTAMP '${ts.toIso8601String()}', $value, now())",
    );
  }

  Future<Map<String, int>> compact() => compactSignalLog(conn, now: now);

  Future<Object?> one(String sql) async =>
      (await conn.query(sql)).fetchOne()?.first;

  test('readings inside the hot window are untouched', () async {
    await reading(1, 55);
    await reading(6, 60);

    final result = await compact();

    expect(result['readings_dropped'], 0);
    expect(await one('SELECT count(*) FROM signal_reading'), 2);
    expect(await one('SELECT count(*) FROM signal_rollup'), 0);
  });

  test('older readings are summarised and then dropped', () async {
    // Three readings inside one five-minute bucket, ten days back.
    await reading(10, 40, minutes: 0);
    await reading(10, 80, minutes: 2);
    await reading(10, 60, minutes: 4);
    await reading(1, 55);

    final result = await compact();

    expect(result['readings_dropped'], 3);
    expect(await one('SELECT count(*) FROM signal_reading'), 1);

    final bucket = (await conn.query(
      'SELECT readings, min_value, max_value, avg_value, last_value '
      'FROM signal_rollup',
    )).fetchOne();
    expect(bucket, [3, 40.0, 80.0, 60.0, 60.0]);
  });

  // A rollup row carries four more columns than the raw row it replaces, so
  // summarising a lone reading makes the database bigger. The first
  // measurement of this grew the file by 126 MiB.
  test('a reading alone in its bucket is left where it is', () async {
    await reading(10, 40, minutes: 0);

    final result = await compact();

    expect(result['readings_dropped'], 0);
    expect(await one('SELECT count(*) FROM signal_rollup'), 0);
    expect(await one('SELECT count(*) FROM signal_reading'), 1);
  });

  // An average hides exactly the thing anyone looks at old battery data for.
  test('the extremes survive the average', () async {
    await reading(10, 20, minutes: 0, signal: 'battery_temp');
    await reading(10, 52, minutes: 1, signal: 'battery_temp');
    await reading(10, 36, minutes: 2, signal: 'battery_temp');

    await compact();

    expect(await one('SELECT max_value FROM signal_rollup'), 52.0);
  });

  test('readings five minutes apart land in different buckets', () async {
    await reading(10, 40, minutes: 0);
    await reading(10, 45, minutes: 1);
    await reading(10, 80, minutes: 6);
    await reading(10, 85, minutes: 7);

    await compact();

    expect(await one('SELECT count(*) FROM signal_rollup'), 2);
  });

  // The cost, stated as a test rather than only as prose: position history
  // outside the window is gone, so a crossing there can never be re-derived.
  test('position fixes outside the window are dropped, not summarised', () async {
    await conn.execute(
      "INSERT INTO location_fix VALUES ('v1', "
      "TIMESTAMP '${now.subtract(const Duration(days: 10)).toIso8601String()}',"
      ' 12.97, 77.60, 5, now())',
    );

    final result = await compact();

    expect(result['fixes_dropped'], 1);
    expect(await one('SELECT count(*) FROM location_fix'), 0);
  });

  test('compacting twice finds nothing left to do', () async {
    await reading(10, 40, minutes: 0);
    await reading(10, 60, minutes: 1);
    await compact();

    final second = await compact();

    expect(second['readings_dropped'], 0);
    expect(await one('SELECT count(*) FROM signal_rollup'), 1);
  });
}
