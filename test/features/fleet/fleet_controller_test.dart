import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/error/failures.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_filter.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_overview.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_vehicle_summary.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/fleet/domain/repositories/fleet_repository.dart';
import 'package:byte_beam_project/features/fleet/domain/usecases/get_fleet_overview.dart';
import 'package:byte_beam_project/features/fleet/presentation/controllers/fleet_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what was asked for and returns whatever the test set up.
class FakeFleetRepository implements FleetRepository {
  final calls = <(FleetFilter, DateTime)>[];
  Failure? failure;

  @override
  Future<Result<FleetOverview>> overview(
    FleetFilter filter,
    DateTime now,
  ) async {
    calls.add((filter, now));
    final f = failure;
    if (f != null) return Err(f);
    return Ok(
      FleetOverview(
        filter: filter,
        vehicles: [
          const FleetVehicleSummaryStub(
            vehicleId: 'v1',
            regNo: 'KA01AA0001',
            status: VehicleStatus.moving,
          ),
        ],
        counts: const {FleetFilter.all: 3, FleetFilter.moving: 1},
      ),
    );
  }
}

/// A summary with the fields the controller tests care about.
class FleetVehicleSummaryStub extends FleetVehicleSummary {
  const FleetVehicleSummaryStub({
    required super.vehicleId,
    required super.regNo,
    required super.status,
  }) : super(model: 'eT 1000');
}

void main() {
  late FakeFleetRepository repository;
  late DatabasePulse pulse;
  late FleetController controller;

  setUp(() {
    repository = FakeFleetRepository();
    pulse = DatabasePulse();
    controller = FleetController(
      getFleetOverview: GetFleetOverview(repository),
      pulse: pulse,
      clock: FakeClock(DateTime.utc(2026, 1, 1, 12)),
      refreshDebounce: const Duration(milliseconds: 10),
    );
  });

  tearDown(() => controller.onClose());

  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('it loads once on init, against the injected clock', () async {
    controller.onInit();
    await settle();

    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.$1, FleetFilter.all);
    expect(repository.calls.single.$2, DateTime.utc(2026, 1, 1, 12));
    expect(controller.isLoading.value, isFalse);
  });

  test('selecting a chip reloads with that filter', () async {
    controller.onInit();
    await settle();

    await controller.select(FleetFilter.moving);

    expect(controller.filter.value, FleetFilter.moving);
    expect(repository.calls.last.$1, FleetFilter.moving);
  });

  test('reselecting the current chip does not re-query', () async {
    controller.onInit();
    await settle();
    final before = repository.calls.length;

    await controller.select(FleetFilter.all);

    expect(repository.calls, hasLength(before));
  });

  test('a burst of writes triggers one reload, not one per write', () async {
    controller.onInit();
    await settle();
    final before = repository.calls.length;

    for (var i = 0; i < 8; i++) {
      pulse.ping();
    }
    await settle();

    expect(
      repository.calls.length - before,
      1,
      reason: 'a backlog dump must not repaint once per batch',
    );
  });

  test('a failure is surfaced and clears on the next good load', () async {
    repository.failure = const DatabaseFailure('query exploded');
    controller.onInit();
    await settle();
    expect(controller.error.value, 'query exploded');

    repository.failure = null;
    await controller.load();

    expect(controller.error.value, isEmpty);
    expect(controller.overview.value.countFor(FleetFilter.all), 3);
  });
}
