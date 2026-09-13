import 'dart:io';

import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../duckdb_support.dart';

/// Top-level so it can cross the isolate boundary.
Future<void> _insertVehicle(Connection conn) async {
  await conn.execute(
    "INSERT INTO vehicle VALUES ('v1', 'KA01AB1234', 'eT 1000')",
  );
}

Future<int> _countVehicles(Connection conn) async {
  final r = await conn.query('SELECT count(*) FROM vehicle');
  return (r.fetchOne()!.first as num).toInt();
}

void main() {
  setUpAll(useHostDuckDb);

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fleetdb');
    path = '${dir.path}/fleet.duckdb';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('migrates on open and seeds signal thresholds', () async {
    final db = await FleetDb.open(path);
    addTearDown(db.close);

    final specs = await db.read.query('SELECT count(*) FROM signal_spec');
    expect((specs.fetchOne()!.first as num).toInt(), 6);

    final soc = await db.read.query(
      "SELECT max_age_sec, warn_lo, crit_lo FROM signal_spec WHERE signal = 'soc'",
    );
    expect(soc.fetchOne(), [300, 20.0, 10.0]);
  });

  test('migration is idempotent across reopens', () async {
    final first = await FleetDb.open(path);
    await first.close();
    final second = await FleetDb.open(path);
    addTearDown(second.close);

    final v = await second.read.query(
      'SELECT max(version) FROM schema_version',
    );
    expect((v.fetchOne()!.first as num).toInt(), 1);
    // A re-applied migration would have duplicated the seed rows.
    final specs = await second.read.query('SELECT count(*) FROM signal_spec');
    expect((specs.fetchOne()!.first as num).toInt(), 6);
  });

  // The three assumptions ARCHITECTURE.md §1 rests on: a writer on another
  // isolate, a reader on this one, and everything still there after a restart.
  test(
    'isolate writes are visible to the UI connection and survive a restart',
    () async {
      final db = await FleetDb.open(path);
      await FleetDb.inIsolate(db.transferable, _insertVehicle);

      expect(await _countVehicles(db.read), 1);
      await db.close();

      final reopened = await FleetDb.open(path);
      addTearDown(reopened.close);
      expect(
        await _countVehicles(reopened.read),
        1,
        reason: 'kill and relaunch must come back off disk',
      );
    },
  );
}
