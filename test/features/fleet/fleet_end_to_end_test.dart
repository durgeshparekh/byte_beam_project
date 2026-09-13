import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/fleet/data/datasources/fleet_local_data_source.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_filter.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_overview.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulated_packet_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulator_config.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

/// The fleet list read off a database the real ingest pipeline filled.
///
/// The unit tests above insert `vehicle_signal_latest` rows by hand, which is
/// the right way to pin the status ladder. This one closes the loop: simulator
/// to writer isolate to DuckDB to the fleet query, with nothing stubbed.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbTelemetryLocalDataSource ingest;
  late DuckDbFleetLocalDataSource fleet;
  late FakeClock clock;
  late DateTime lastTick;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    ingest = await DuckDbTelemetryLocalDataSource.create(db);
    fleet = DuckDbFleetLocalDataSource(db.read);

    clock = FakeClock(DateTime.utc(2026, 1, 1, 10));
    final source = SimulatedPacketSource(
      clock: clock,
      config: const SimulatorConfig(vehicleCount: 30, seed: 4242),
    );
    await ingest.seedFleet(source.fleet);

    for (var tick = 0; tick < 60; tick++) {
      final batch = source.generateTick();
      if (batch.isNotEmpty) {
        await ingest.applyBatch([
          for (final p in batch) TelemetryPacketModel.fromEntity(p),
        ]);
      }
      clock.advance(source.config.tick);
    }
    lastTick = clock.nowUtc();
  });

  tearDown(() async {
    await ingest.dispose();
    await db.close();
  });

  test('every vehicle lands in exactly one chip', () async {
    final overview = await fleet.overview(FleetFilter.all, lastTick);

    final perStatus = [
      FleetFilter.moving,
      FleetFilter.idle,
      FleetFilter.stopped,
      FleetFilter.offline,
    ].map(overview.countFor).fold(0, (a, b) => a + b);

    expect(overview.countFor(FleetFilter.all), 30);
    expect(
      perStatus,
      30,
      reason: 'the ladder is first-match-wins, not overlapping',
    );
    expect(overview.vehicles, hasLength(30));
  });

  test('a live fleet is not all in one state', () async {
    final overview = await fleet.overview(FleetFilter.all, lastTick);
    final occupied = [
      FleetFilter.moving,
      FleetFilter.idle,
      FleetFilter.stopped,
    ].where((f) => overview.countFor(f) > 0);

    expect(occupied, hasLength(greaterThan(1)));
  });

  test('rows carry the values the list renders', () async {
    final overview = await fleet.overview(FleetFilter.all, lastTick);
    final reported = overview.vehicles.where((v) => !v.hasNeverReported);

    expect(reported, isNotEmpty);
    for (final vehicle in reported) {
      expect(vehicle.soc, isNotNull);
      expect(vehicle.rangeKm, isNotNull);
      expect(vehicle.regNo, startsWith('KA01'));
    }
  });

  test('the low-battery trucks the simulator plants get a badge', () async {
    final overview = await fleet.overview(FleetFilter.all, lastTick);
    final badged = overview.vehicles.where((v) => v.alertSeverity != null);

    expect(
      badged,
      isNotEmpty,
      reason: 'every seventh vehicle starts near the low-battery threshold',
    );
    for (final vehicle in badged) {
      expect(
        vehicle.soc! < 20 || vehicle.status == VehicleStatus.offline,
        isTrue,
      );
    }
  });

  test('filtering returns exactly the rows with that status', () async {
    for (final filter in FleetFilter.values.where(
      (f) => f != FleetFilter.all,
    )) {
      final overview = await fleet.overview(filter, lastTick);

      expect(overview.vehicles, hasLength(overview.countFor(filter)));
      expect(
        overview.vehicles.every((v) => v.status == filter.status),
        isTrue,
        reason: 'the $filter chip returned a row in another state',
      );
    }
  });

  test('eleven minutes later the whole fleet reads offline', () async {
    final overview = await fleet.overview(
      FleetFilter.all,
      lastTick.add(const Duration(minutes: 11)),
    );

    expect(overview.countFor(FleetFilter.offline), 30);
    expect(overview.countFor(FleetFilter.moving), 0);
  });

  test('an offline vehicle shows no alert badge', () async {
    final overview = await fleet.overview(
      FleetFilter.offline,
      lastTick.add(const Duration(minutes: 11)),
    );

    expect(
      overview.vehicles.every((v) => v.alertSeverity == null),
      isTrue,
      reason: 'stale readings must not raise thresholds',
    );
  });

  test(
    'the overview reports a filtered-empty state, not a blank list',
    () async {
      final FleetOverview overview = await fleet.overview(
        FleetFilter.moving,
        lastTick.add(const Duration(minutes: 11)),
      );

      expect(overview.vehicles, isEmpty);
      expect(overview.isFilteredEmpty, isTrue);
      expect(overview.isFleetEmpty, isFalse);
    },
  );
}
