import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/geofence/data/datasources/geofence_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulated_packet_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulator_config.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

/// The simulator through the real writer into the real detector, nothing
/// stubbed.
///
/// The unit tests prove the detector is right about a route someone wrote by
/// hand. This proves the two halves meet: that a fleet wandering around the
/// seeded fences actually produces crossings, and that the containment table
/// and the transition log tell the same story afterwards.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbTelemetryLocalDataSource ingest;
  late DuckDbGeofenceLocalDataSource fences;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    ingest = await DuckDbTelemetryLocalDataSource.create(db);
    fences = DuckDbGeofenceLocalDataSource(db.read, ingest.writer);
    conn = db.read;

    final clock = FakeClock(DateTime.utc(2026, 1, 1, 10));
    final source = SimulatedPacketSource(
      clock: clock,
      config: const SimulatorConfig(vehicleCount: 30, seed: 4242),
    );
    await ingest.seedFleet(source.fleet);

    for (var tick = 0; tick < 150; tick++) {
      final batch = source.generateTick();
      if (batch.isNotEmpty) {
        await ingest.applyBatch([
          for (final p in batch) TelemetryPacketModel.fromEntity(p),
        ], clock.nowUtc());
      }
      clock.advance(source.config.tick);
    }
  });

  tearDown(() async {
    await ingest.dispose();
    await db.close();
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await conn.query(sql)).fetchAll();

  test('a wandering fleet produces crossings', () async {
    final crossings = await rows('SELECT count(*) FROM geofence_transition');

    expect(
      (crossings.single.first as num).toInt(),
      greaterThan(0),
      reason:
          'if this is zero the fleet never reaches a fence, and the demo '
          'shows an empty crossings list — see SimulatorConfig.groundScale',
    );
  });

  test('every vehicle has a containment row for every fence', () async {
    final counts = await rows(
      'SELECT (SELECT count(*) FROM geofence_containment), '
      '(SELECT count(*) FROM vehicle) * (SELECT count(*) FROM geofence)',
    );

    expect(counts.single[0], counts.single[1]);
  });

  // Containment is the transition log folded up, so the last crossing for a
  // (vehicle, fence) has to agree with the zone recorded for it. If these ever
  // disagree, one of the two is lying about where a truck is.
  test('containment agrees with the last transition', () async {
    final disagreements = await rows('''
      SELECT count(*)
      FROM geofence_containment c
      JOIN (
        SELECT vehicle_id, geofence_id, kind
        FROM geofence_transition
        QUALIFY row_number() OVER (
          PARTITION BY vehicle_id, geofence_id ORDER BY event_ts DESC
        ) = 1
      ) t USING (vehicle_id, geofence_id)
      WHERE c.zone <> CASE t.kind WHEN 'ENTRY' THEN 'IN' ELSE 'OUT' END
    ''');

    expect((disagreements.single.first as num).toInt(), 0);
  });

  test('crossings alternate entry and exit per vehicle and fence', () async {
    final repeats = await rows('''
      SELECT count(*) FROM (
        SELECT kind, lag(kind) OVER (
          PARTITION BY vehicle_id, geofence_id ORDER BY event_ts
        ) AS previous
        FROM geofence_transition
      ) WHERE previous IS NOT NULL AND kind = previous
    ''');

    expect(
      (repeats.single.first as num).toInt(),
      0,
      reason: 'two entries in a row means a crossing was invented',
    );
  });

  test('the live counts match the containment table', () async {
    final occupancy = await fences.occupancy();

    for (final fence in occupancy) {
      final counted = await rows(
        "SELECT count(*) FROM geofence_containment WHERE zone = 'IN' "
        "AND geofence_id = '${fence.fence.geofenceId}'",
      );
      expect(fence.vehiclesInside, (counted.single.first as num).toInt());
    }
  });

  test('re-deriving the whole fleet changes nothing', () async {
    final before = await rows(
      'SELECT vehicle_id, geofence_id, event_ts, kind, confidence '
      'FROM geofence_transition ORDER BY 1, 2, 3',
    );

    await fences.save((await fences.byId('gf-hebbal'))!);

    expect(
      await rows(
        'SELECT vehicle_id, geofence_id, event_ts, kind, confidence '
        'FROM geofence_transition ORDER BY 1, 2, 3',
      ),
      before,
      reason: 'a save with no change re-derives to the same answer',
    );
  });
}
