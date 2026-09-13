import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:flutter_test/flutter_test.dart';

import '../duckdb_support.dart';

/// ARCHITECTURE.md leans on a handful of DuckDB features. If a version bump
/// ever removes or changes one, this file fails instead of the whole app
/// quietly going wrong.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  setUp(() async => db = await FleetDb.open(':memory:'));
  tearDown(() => db.close());

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.read.query(sql)).fetchAll();

  test('natural-key PK makes duplicate packets a no-op (§4 step 2)', () async {
    const packet = "('v1', 'soc', TIMESTAMP '2026-01-01 10:00:00', 55, now())";
    await db.read.execute('INSERT INTO signal_reading VALUES $packet');
    await db.read.execute(
      'INSERT INTO signal_reading VALUES $packet ON CONFLICT DO NOTHING',
    );

    expect(await rows('SELECT count(*) FROM signal_reading'), [
      [1],
    ]);
  });

  test(
    'conditional ON CONFLICT keeps a late packet from clobbering (§4 step 3)',
    () async {
      Future<void> upsert(String ts, num value) => db.read.execute('''
      INSERT INTO vehicle_signal_latest AS l VALUES
        ('v1', 'soc', TIMESTAMP '$ts', $value)
      ON CONFLICT (vehicle_id, signal) DO UPDATE
        SET value = excluded.value, event_ts = excluded.event_ts
        WHERE excluded.event_ts > l.event_ts
    ''');

      await upsert('2026-01-01 10:00:00', 55);
      await upsert('2026-01-01 10:05:00', 54); // newer, applies
      await upsert('2026-01-01 09:55:00', 99); // late, must be ignored

      expect(await rows('SELECT event_ts, value FROM vehicle_signal_latest'), [
        [DateTime.utc(2026, 1, 1, 10, 5), 54.0],
      ]);
    },
  );

  test(
    'last_value IGNORE NULLS carries a zone across the hysteresis band (§7.1)',
    () async {
      // NULL = fix landed inside the band and has no opinion.
      const fixes =
          "VALUES (1, 'out'), (2, NULL), (3, NULL), (4, 'in'), (5, NULL)";
      final carried = await rows('''
      SELECT t, last_value(zone IGNORE NULLS) OVER (ORDER BY t) AS zone_ff
      FROM ($fixes) AS f(t, zone) ORDER BY t
    ''');

      expect(carried.map((r) => r[1]), ['out', 'out', 'out', 'in', 'in']);
    },
  );

  test('FILTER pivots the latest table in one pass (§5)', () async {
    await db.read.execute('''
      INSERT INTO vehicle_signal_latest VALUES
        ('v1', 'soc',   TIMESTAMP '2026-01-01 10:00:00', 42),
        ('v1', 'speed', TIMESTAMP '2026-01-01 10:00:30', 0)
    ''');

    expect(
      await rows('''
        SELECT max(value) FILTER (WHERE signal = 'soc')   AS soc,
               max(value) FILTER (WHERE signal = 'speed') AS speed
        FROM vehicle_signal_latest GROUP BY vehicle_id
      '''),
      [
        [42.0, 0.0],
      ],
    );
  });

  test('ASOF JOIN reads the odometer as of a trip boundary (§7.2)', () async {
    await db.read.execute('''
      INSERT INTO signal_reading VALUES
        ('v1', 'odometer', TIMESTAMP '2026-01-01 09:00:00', 1000, now()),
        ('v1', 'odometer', TIMESTAMP '2026-01-01 10:00:00', 1120, now()),
        ('v1', 'odometer', TIMESTAMP '2026-01-01 11:00:00', 1250, now())
    ''');

    // The reading in force at 10:30 is the 10:00 one, not the 11:00 one.
    expect(
      await rows('''
        SELECT o.value
        FROM (SELECT TIMESTAMP '2026-01-01 10:30:00' AS at) b
        ASOF JOIN signal_reading o ON o.event_ts <= b.at
        WHERE o.signal = 'odometer'
      '''),
      [
        [1120.0],
      ],
    );
  });

  test('range() generates the backfill server-side (§8)', () async {
    await db.read.execute(
      "INSERT INTO vehicle VALUES ('v1', 'KA01AB1234', 'eT')",
    );
    await db.read.execute('''
      INSERT INTO signal_reading
      SELECT v.vehicle_id, 'soc',
             TIMESTAMP '2026-01-01 00:00:00' + INTERVAL (i * 30) SECOND,
             100 - (i % 100), now()
      FROM range(0, 1000) t(i), vehicle v
    ''');

    expect(await rows('SELECT count(*) FROM signal_reading'), [
      [1000],
    ]);
  });
}
