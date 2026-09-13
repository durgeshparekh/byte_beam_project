import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/geofence/data/datasources/geofence_local_data_source.dart';
import 'package:byte_beam_project/features/geofence/domain/entities/geofence.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/fleet_vehicle.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/telemetry_packet.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final t0 = DateTime.utc(2026, 1, 1, 8);

DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

/// The seeded Whitefield Depot, from migration v2.
const depotLat = 12.9700;
const depotLon = 77.6000;

double latOffset(double metres) => depotLat + metres / 111320.0;

/// The fence store against a real database and the real writer isolate.
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
    _source = fences;
    conn = db.read;
    await ingest.seedFleet(const [
      FleetVehicle(vehicleId: 'v1', regNo: 'KA01AA0001', model: 'eT'),
    ]);
  });

  tearDown(() async {
    await ingest.dispose();
    await db.close();
  });

  /// Pushes one position fix [metres] north of the depot centre through the
  /// real ingest path, which is also what runs the detector.
  Future<void> fix(int minute, double metres, {double accuracy = 5}) =>
      ingest.applyBatch([
        TelemetryPacketModel(
          vehicleId: 'v1',
          eventTs: at(minute),
          signals: const {'speed': 40},
          location: GeoFix(
            lat: latOffset(metres),
            lon: depotLon,
            accuracyM: accuracy,
          ),
        ),
      ], at(minute));

  group('the seed fences', () {
    test('migration v2 installs four, all active', () async {
      final all = await fences.occupancy();

      expect(all, hasLength(4));
      expect(all.every((o) => o.fence.isActive), isTrue);
      expect(all.map((o) => o.fence.name), contains('Whitefield Depot'));
    });

    // The nested pair, which is what makes "current geofence" a real question.
    test('Depot Bay 3 sits inside Whitefield Depot', () async {
      final all = await fences.occupancy();
      final depot = all.firstWhere((o) => o.fence.name == 'Whitefield Depot');
      final bay = all.firstWhere((o) => o.fence.name == 'Depot Bay 3');

      expect(bay.fence.radiusM, lessThan(depot.fence.radiusM));
    });
  });

  group('the detector runs as part of ingest', () {
    test('driving into a fence shows up in the live count', () async {
      await fix(0, 6000);
      await fix(1, 6000);
      expect(await inside('Whitefield Depot'), 0);

      await fix(2, 500);
      await fix(3, 400);

      expect(await inside('Whitefield Depot'), 1);
    });

    test('a crossing is recorded as a transition', () async {
      await fix(0, 6000);
      await fix(1, 6000);
      await fix(2, 500);
      await fix(3, 400);

      final result = await conn.query(
        'SELECT geofence_id, kind FROM geofence_transition ORDER BY event_ts',
      );
      expect(result.fetchAll(), [
        ['gf-depot', 'ENTRY'],
      ]);
    });

    test('a nested fence counts the same vehicle twice over', () async {
      await fix(0, 6000);
      await fix(1, 6000);
      await fix(2, 50);
      await fix(3, 40);

      expect(await inside('Whitefield Depot'), 1);
      expect(await inside('Depot Bay 3'), 1);
    });
  });

  group('editing a fence', () {
    /// The current state of one fence, by name.
    Future<Geofence> named(String name) async => (await fences.occupancy())
        .firstWhere((o) => o.fence.name == name)
        .fence;

    test('renaming keeps the fence and its history', () async {
      await fix(0, 6000);
      await fix(1, 6000);
      await fix(2, 400);
      await fix(3, 400);
      final depot = await named('Whitefield Depot');

      await fences.save(
        Geofence(
          geofenceId: depot.geofenceId,
          name: 'Whitefield Yard',
          lat: depot.lat,
          lon: depot.lon,
          radiusM: depot.radiusM,
          activeFrom: depot.activeFrom,
          updatedAt: at(9),
        ),
      );

      expect((await named('Whitefield Yard')).geofenceId, depot.geofenceId);
      expect(await inside('Whitefield Yard'), 1);
    });

    // ARCHITECTURE.md §10, ambiguity 9: geometry is not versioned, so moving a
    // fence re-derives its history rather than leaving two answers on record.
    test('shrinking a fence re-derives the vehicle out of it', () async {
      await fix(0, 6000);
      await fix(1, 6000);
      await fix(2, 1500);
      await fix(3, 1400);
      expect(await inside('Whitefield Depot'), 1);
      final depot = await named('Whitefield Depot');

      await fences.save(
        Geofence(
          geofenceId: depot.geofenceId,
          name: depot.name,
          lat: depot.lat,
          lon: depot.lon,
          radiusM: 800,
          activeFrom: depot.activeFrom,
          updatedAt: at(9),
        ),
      );

      expect(
        await inside('Whitefield Depot'),
        0,
        reason: '1400 m is outside an 800 m fence, and always was',
      );
    });

    test('a new fence starts from now and inherits no history', () async {
      await fix(0, 400);
      await fix(1, 400);

      await fences.save(
        Geofence(
          geofenceId: 'gf-new',
          name: 'New Pad',
          lat: depotLat,
          lon: depotLon,
          radiusM: 1000,
          activeFrom: at(5),
          updatedAt: at(5),
        ),
      );

      expect(
        await inside('New Pad'),
        0,
        reason: 'the truck was there before the fence existed',
      );
    });
  });

  group('deactivation', () {
    test('a deactivated fence is kept, not deleted', () async {
      final depot = (await fences.occupancy())
          .firstWhere((o) => o.fence.name == 'Whitefield Depot')
          .fence;

      await fences.save(depot.withActive(active: false, at: at(9)));

      final all = await fences.occupancy();
      expect(all, hasLength(4));
      final after = all.firstWhere((o) => o.fence.name == 'Whitefield Depot');
      expect(after.fence.isActive, isFalse);
      expect(after.fence.activeTo, at(9));
    });

    test('it stops judging fixes from its end date on', () async {
      final depot = (await fences.occupancy())
          .firstWhere((o) => o.fence.name == 'Whitefield Depot')
          .fence;
      await fences.save(depot.withActive(active: false, at: at(1)));

      await fix(2, 400);
      await fix(3, 400);

      expect(await inside('Whitefield Depot'), 0);
    });

    test('inactive fences sort after active ones', () async {
      final depot = (await fences.occupancy())
          .firstWhere((o) => o.fence.name == 'Whitefield Depot')
          .fence;
      await fences.save(depot.withActive(active: false, at: at(1)));

      final all = await fences.occupancy();
      expect(all.last.fence.name, 'Whitefield Depot');
    });

    test('reactivating starts a fresh active window', () async {
      final depot = (await fences.occupancy())
          .firstWhere((o) => o.fence.name == 'Whitefield Depot')
          .fence;
      await fences.save(depot.withActive(active: false, at: at(1)));

      await fences.save(
        (await fences.byId(
          depot.geofenceId,
        ))!.withActive(active: true, at: at(5)),
      );

      final after = (await fences.byId(depot.geofenceId))!;
      expect(after.isActive, isTrue);
      expect(
        after.activeFrom,
        at(5),
        reason: 'the period it was off stays off in any recompute',
      );
    });
  });
}

/// How many vehicles the fence named [name] currently holds.
Future<int> inside(String name) async {
  final source = _source!;
  final all = await source.occupancy();
  return all.firstWhere((o) => o.fence.name == name).vehiclesInside;
}

DuckDbGeofenceLocalDataSource? _source;
