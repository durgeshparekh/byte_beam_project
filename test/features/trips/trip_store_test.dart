import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/fleet_vehicle.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/telemetry_packet.dart';
import 'package:byte_beam_project/features/trips/data/datasources/trip_local_data_source.dart';
import 'package:byte_beam_project/features/trips/domain/entities/trip.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final t0 = DateTime.utc(2026, 1, 1, 8);

DateTime at(int minutes, [int seconds = 0]) =>
    t0.add(Duration(minutes: minutes, seconds: seconds));

/// The seeded Whitefield Depot, from migration v2. Depot Bay 3 sits about
/// 200 m north-east of this point, which is why a fix at the centre is inside
/// both fences.
const depotLat = 12.9700;
const depotLon = 77.6000;

double latOffset(double metres) => depotLat + metres / 111320.0;

/// Trips through the whole machine: the real writer isolate, the real
/// detector, the real derivation, the real read query.
///
/// `trip_derivation_test.dart` states crossing sequences directly and asks
/// what they mean. This asks the question the app actually asks — drive a
/// truck around and see whether a trip comes out — and it is the only place
/// the production *order* (detect, then derive, then move the watermark) is
/// pinned.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbTelemetryLocalDataSource ingest;
  late DuckDbTripLocalDataSource trips;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    ingest = await DuckDbTelemetryLocalDataSource.create(db);
    trips = DuckDbTripLocalDataSource(db.read);
    await ingest.seedFleet(const [
      FleetVehicle(vehicleId: 'v1', regNo: 'KA01AA0001', model: 'eT'),
    ]);
  });

  tearDown(() async {
    await ingest.dispose();
    await db.close();
  });

  /// Drives the truck to [metres] north of the depot centre at [minute].
  Future<void> driveTo(
    int minute,
    double metres, {
    int second = 0,
    double odometer = 1000,
  }) => ingest.applyBatch([
    TelemetryPacketModel(
      vehicleId: 'v1',
      eventTs: at(minute, second),
      signals: {'speed': 40, 'odometer': odometer},
      location: GeoFix(lat: latOffset(metres), lon: depotLon, accuracyM: 5),
    ),
  ], at(minute, second));

  /// Parks it at the depot centre long enough to establish containment.
  Future<void> startAtDepot() async {
    await driveTo(0, 0);
    await driveTo(1, 0, odometer: 1000);
  }

  Future<List<Trip>> all() => trips.recent(50);

  test(
    'driving out of the depot starts a trip and coming back ends it',
    () async {
      await startAtDepot();
      await driveTo(
        2,
        600,
        odometer: 1001,
      ); // out of the bay, still in the depot
      await driveTo(3, 3000, odometer: 1004); // out of the depot — departure
      await driveTo(4, 0, odometer: 1012); // back in both — arrival

      final legs = await all();
      expect(legs, hasLength(1));
      expect(legs.single.origin, 'Whitefield Depot');
      expect(legs.single.destination, 'Whitefield Depot');
      expect(legs.single.startedAt, at(3));
      expect(legs.single.endedAt, at(4));
      expect(legs.single.isRunning, isFalse);
      expect(legs.single.distanceKm, closeTo(8, 0.001));
      expect(legs.single.regNo, 'KA01AA0001');
    },
  );

  test('leaving the bay without leaving the depot starts nothing', () async {
    await startAtDepot();
    await driveTo(2, 600);
    await driveTo(3, 700);

    expect(await all(), isEmpty);
  });

  test('a truck still out there keeps a running trip', () async {
    await startAtDepot();
    await driveTo(2, 3000, odometer: 1005);
    await driveTo(3, 4000, odometer: 1009);

    final legs = await all();
    expect(legs.single.isRunning, isTrue);
    expect(legs.single.destination, isNull);
    // Distance so far, measured from the departure to the newest reading
    // rather than left blank until the truck arrives somewhere.
    expect(legs.single.distanceKm, closeTo(4, 0.001));
  });

  // The late-packet story, end to end: the batch reaches behind the vehicle's
  // watermark, the detector replays the whole vehicle, and the trip is rebuilt
  // rather than joined by a second one.
  test('a late fix moves the departure instead of adding a trip', () async {
    await startAtDepot();
    await driveTo(2, 600);
    await driveTo(3, 3000);
    expect((await all()).single.startedAt, at(3));

    await driveTo(2, 3000, second: 30);

    final legs = await all();
    expect(legs, hasLength(1));
    expect(legs.single.startedAt, at(2, 30));
  });

  test('one vehicle reads the same trips as the fleet list', () async {
    await startAtDepot();
    await driveTo(2, 3000);

    expect(
      (await trips.forVehicle('v1', 50)).single.tripId,
      (await all()).single.tripId,
    );
  });
}
