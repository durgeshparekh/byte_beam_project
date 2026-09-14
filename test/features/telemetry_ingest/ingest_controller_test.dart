import 'dart:async';

import 'package:byte_beam_project/core/error/failures.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/fleet_vehicle.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/ingest_receipt.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/ingest_snapshot.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/telemetry_packet.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/repositories/telemetry_repository.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/usecases/get_ingest_snapshot.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/usecases/ingest_packet_batch.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/usecases/observe_telemetry.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/usecases/seed_fleet.dart';
import 'package:byte_beam_project/features/telemetry_ingest/presentation/controllers/ingest_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the whole data layer.
///
/// The point of the repository interface is that this is possible: the
/// controller can be driven to every state that matters without DuckDB, an
/// isolate or the simulator anywhere in the test.
class FakeTelemetryRepository implements TelemetryRepository {
  final packets = StreamController<List<TelemetryPacket>>.broadcast();

  /// Receipt returned by the next [ingest] call.
  IngestReceipt nextReceipt = const IngestReceipt.empty();

  /// When set, every call fails with it instead.
  Failure? failure;

  int seedCalls = 0;
  int ingestCalls = 0;
  int snapshotCalls = 0;

  @override
  Future<Result<int>> seedFleet(List<FleetVehicle> vehicles) async {
    seedCalls++;
    final f = failure;
    return f != null ? Err(f) : Ok(vehicles.length);
  }

  @override
  Stream<List<TelemetryPacket>> watchPackets() => packets.stream;

  @override
  Future<Result<IngestReceipt>> ingest(List<TelemetryPacket> batch) async {
    ingestCalls++;
    final f = failure;
    return f != null ? Err(f) : Ok(nextReceipt);
  }

  @override
  Future<Result<IngestSnapshot>> snapshot() async {
    snapshotCalls++;
    return Ok(
      IngestSnapshot(
        vehicles: 2,
        signalRows: ingestCalls * 10,
        locationRows: ingestCalls,
        newestEventTs: DateTime.utc(2026, 1, 1, 10),
      ),
    );
  }
}

IngestReceipt receipt({
  int packets = 1,
  int applied = 4,
  int offered = 5,
  int late = 0,
  int orphans = 0,
}) {
  return IngestReceipt(
    packets: packets,
    signalRowsOffered: offered,
    signalRowsApplied: applied,
    locationRowsOffered: 0,
    locationRowsApplied: 0,
    lateVehicles: late,
    orphanRows: orphans,
    duration: const Duration(milliseconds: 7),
  );
}

void main() {
  late FakeTelemetryRepository repository;
  late IngestController controller;

  setUp(() {
    repository = FakeTelemetryRepository();
    controller = IngestController(
      seedFleet: SeedFleet(repository),
      observeTelemetry: ObserveTelemetry(repository),
      ingestPacketBatch: IngestPacketBatch(repository),
      getIngestSnapshot: GetIngestSnapshot(repository),
      roster: const [
        FleetVehicle(vehicleId: 'v1', regNo: 'KA01AB1234', model: 'eT 1000'),
      ],
    );
  });

  tearDown(() {
    controller.onClose();
    repository.packets.close();
  });

  /// Lets the controller's async reaction to a batch settle.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('it seeds the roster and reads a first snapshot on bootstrap', () async {
    await controller.bootstrap();
    await settle();

    expect(repository.seedCalls, 1);
    expect(controller.snapshot.value.vehicles, 2);
    expect(
      controller.isRunning.value,
      isTrue,
      reason: 'the monitor auto-starts',
    );
  });

  test('start is idempotent', () {
    controller.start();
    controller.start();

    expect(controller.isRunning.value, isTrue);
  });

  test('a batch folds its receipt into the session counters', () async {
    repository.nextReceipt = receipt(
      packets: 3,
      applied: 4,
      offered: 6,
      late: 2,
      orphans: 3,
    );
    controller.start();

    repository.packets.add([
      TelemetryPacket(vehicleId: 'v1', eventTs: DateTime.utc(2026)),
    ]);
    await settle();
    await settle();

    expect(controller.batchesWritten.value, 1);
    expect(controller.packetsReceived.value, 3);
    expect(controller.rowsApplied.value, 4);
    expect(
      controller.duplicatesRejected.value,
      2,
      reason: 'offered 6, applied 4',
    );
    expect(controller.lateVehicles.value, 2);
    expect(controller.orphansDropped.value, 3);
    expect(controller.lastBatchMs.value, 7);
  });

  test('the on-disk snapshot is re-read after every batch', () async {
    controller.start();
    repository.packets.add([
      TelemetryPacket(vehicleId: 'v1', eventTs: DateTime.utc(2026)),
    ]);
    await settle();
    await settle();

    expect(repository.snapshotCalls, greaterThan(0));
    expect(controller.snapshot.value.signalRows, 10);
  });

  test('stopping unsubscribes, so later packets are not written', () async {
    controller.start();
    await controller.stop();

    repository.packets.add([
      TelemetryPacket(vehicleId: 'v1', eventTs: DateTime.utc(2026)),
    ]);
    await settle();

    expect(controller.isRunning.value, isFalse);
    expect(repository.ingestCalls, 0);
  });

  test('a failure is surfaced, not thrown', () async {
    repository.failure = const DatabaseFailure('disk on fire');
    controller.start();

    repository.packets.add([
      TelemetryPacket(vehicleId: 'v1', eventTs: DateTime.utc(2026)),
    ]);
    await settle();
    await settle();

    expect(controller.error.value, 'disk on fire');
    expect(
      controller.isRunning.value,
      isTrue,
      reason: 'one bad batch is not fatal',
    );
  });

  test('an empty batch never reaches the repository', () async {
    controller.start();
    repository.packets.add(const []);
    await settle();

    expect(repository.ingestCalls, 0);
  });
}
