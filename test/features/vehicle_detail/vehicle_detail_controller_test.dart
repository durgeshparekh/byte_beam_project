import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/error/failures.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/soc_history.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/vehicle_detail.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/repositories/vehicle_detail_repository.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/usecases/get_vehicle_detail.dart';
import 'package:byte_beam_project/features/vehicle_detail/presentation/controllers/vehicle_detail_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeVehicleDetailRepository implements VehicleDetailRepository {
  final calls = <(String, DateTime)>[];

  /// Vehicle ids the roster knows about.
  Set<String> known = {'v1', 'v2'};
  Failure? failure;

  @override
  Future<Result<VehicleDetail?>> detail(String vehicleId, DateTime now) async {
    calls.add((vehicleId, now));
    final f = failure;
    if (f != null) return Err(f);
    if (!known.contains(vehicleId)) return const Ok(null);
    return Ok(
      VehicleDetail(
        vehicleId: vehicleId,
        regNo: 'KA01${vehicleId.toUpperCase()}',
        model: 'eT 1000',
        status: VehicleStatus.idle,
        visits: const [],
        trips: const [],
        readings: const [],
        history: const SocHistory.empty(),
        lastPing: now,
      ),
    );
  }
}

void main() {
  late FakeVehicleDetailRepository repository;
  late DatabasePulse pulse;
  late FakeClock clock;
  late VehicleDetailController controller;

  setUp(() {
    repository = FakeVehicleDetailRepository();
    pulse = DatabasePulse();
    clock = FakeClock(DateTime.utc(2026, 1, 1, 12));
    controller = VehicleDetailController(
      getVehicleDetail: GetVehicleDetail(repository),
      pulse: pulse,
      clock: clock,
      refreshDebounce: const Duration(milliseconds: 10),
    );
    controller.onInit();
  });

  tearDown(() => controller.onClose());

  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('a write before any vehicle is open queries nothing', () async {
    pulse.ping();
    await settle();

    expect(repository.calls, isEmpty);
  });

  test('opening a vehicle loads it and records the instant used', () async {
    await controller.open('v1');

    expect(repository.calls.single.$1, 'v1');
    expect(controller.detail.value!.regNo, 'KA01V1');
    expect(
      controller.evaluatedAt.value,
      DateTime.utc(2026, 1, 1, 12),
      reason: 'ages must render from the clock the verdicts used',
    );
    expect(controller.isLoading.value, isFalse);
  });

  test('an unknown vehicle is not-found, not an error', () async {
    await controller.open('ghost');

    expect(controller.notFound.value, isTrue);
    expect(controller.detail.value, isNull);
    expect(controller.error.value, isEmpty);
  });

  test('switching vehicles clears the previous one first', () async {
    await controller.open('v1');
    repository.known = {};
    await controller.open('v2');

    expect(controller.vehicleId.value, 'v2');
    expect(controller.notFound.value, isTrue);
    expect(
      controller.detail.value,
      isNull,
      reason: 'the old vehicle must not linger under the new header',
    );
  });

  test('reopening the same vehicle re-queries without clearing', () async {
    await controller.open('v1');
    await controller.open('v1');

    expect(repository.calls, hasLength(2));
    expect(controller.detail.value, isNotNull);
  });

  test('a burst of writes refreshes once', () async {
    await controller.open('v1');
    final before = repository.calls.length;

    for (var i = 0; i < 6; i++) {
      pulse.ping();
    }
    await settle();

    expect(repository.calls.length - before, 1);
  });

  test('refreshing re-reads the clock', () async {
    await controller.open('v1');
    clock.advance(const Duration(minutes: 3));
    await controller.refreshNow();

    expect(controller.evaluatedAt.value, DateTime.utc(2026, 1, 1, 12, 3));
  });

  test('a failure is surfaced and clears on the next good load', () async {
    repository.failure = const DatabaseFailure('register query died');
    await controller.open('v1');
    expect(controller.error.value, 'register query died');

    repository.failure = null;
    await controller.refreshNow();

    expect(controller.error.value, isEmpty);
    expect(controller.detail.value, isNotNull);
  });
}
