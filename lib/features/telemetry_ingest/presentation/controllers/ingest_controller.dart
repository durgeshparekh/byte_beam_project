import 'dart:async';

import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_vehicle.dart';
import '../../domain/entities/ingest_receipt.dart';
import '../../domain/entities/ingest_snapshot.dart';
import '../../domain/entities/telemetry_packet.dart';
import '../../domain/usecases/get_ingest_snapshot.dart';
import '../../domain/usecases/ingest_packet_batch.dart';
import '../../domain/usecases/observe_telemetry.dart';
import '../../domain/usecases/seed_fleet.dart';

/// Drives the ingest screen.
///
/// Depends on use cases only — it has never heard of DuckDB, isolates or the
/// simulator. Swapping the simulator for a real feed changes nothing here.
class IngestController extends GetxController {
  IngestController({
    required SeedFleet seedFleet,
    required ObserveTelemetry observeTelemetry,
    required IngestPacketBatch ingestPacketBatch,
    required GetIngestSnapshot getIngestSnapshot,
    required List<FleetVehicle> roster,
    DatabasePulse? pulse,
  }) : _pulse = pulse,
       _seedFleet = seedFleet,
       _observeTelemetry = observeTelemetry,
       _ingestPacketBatch = ingestPacketBatch,
       _getIngestSnapshot = getIngestSnapshot,
       _roster = roster;

  final SeedFleet _seedFleet;
  final ObserveTelemetry _observeTelemetry;
  final IngestPacketBatch _ingestPacketBatch;
  final GetIngestSnapshot _getIngestSnapshot;
  final List<FleetVehicle> _roster;

  /// Announces commits so read-side screens can refresh. Optional because the
  /// controller's own tests do not need one.
  final DatabasePulse? _pulse;

  StreamSubscription<List<TelemetryPacket>>? _subscription;

  /// True while the feed is connected.
  final isRunning = false.obs;

  /// Last error message, or empty. Shown rather than thrown: a failed batch
  /// should not take the screen down.
  final error = ''.obs;

  /// Running totals since the screen opened. These are *session* counters and
  /// deliberately separate from [snapshot], which is what is actually on disk.
  final packetsReceived = 0.obs;
  final rowsApplied = 0.obs;
  final duplicatesRejected = 0.obs;
  final orphansDropped = 0.obs;
  final lateVehicles = 0.obs;
  final batchesWritten = 0.obs;

  /// Duration of the most recent batch, in milliseconds.
  final lastBatchMs = 0.obs;

  /// What a fresh query against the database returns. Refreshed after every
  /// batch so the screen is showing disk, not a tally kept in memory.
  final snapshot = const IngestSnapshot.empty().obs;

  /// Stops the feed when the screen goes away, so the writer is not fed by a
  /// controller nobody is watching.
  @override
  void onClose() {
    unawaited(_subscription?.cancel());
    super.onClose();
  }

  /// Seeds the roster, reads a first snapshot, then connects the feed.
  ///
  /// Called by the binding at startup, not from `onInit`. GetX only runs
  /// `onInit` when an instance is first *resolved*, so a controller that is
  /// registered but never displayed never initialises — and the ingest
  /// pipeline has to run whether or not anyone is looking at its monitor
  /// screen. Anything that must happen regardless of navigation belongs in
  /// the binding.
  Future<void> bootstrap() async {
    final seeded = await _seedFleet(_roster);
    if (seeded case Err(:final failure)) {
      error.value = failure.message;
      return;
    }
    await refreshSnapshot();
    start();
  }

  /// Connects to the packet feed. Idempotent — pressing start twice is a no-op.
  void start() {
    if (isRunning.value) return;
    error.value = '';
    _subscription = _observeTelemetry(
      const NoParams(),
    ).listen(_onBatch, onError: (Object e) => error.value = e.toString());
    isRunning.value = true;
  }

  /// Disconnects from the feed. Anything already written stays written.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    isRunning.value = false;
  }

  /// Writes one batch and folds its receipt into the session counters.
  Future<void> _onBatch(List<TelemetryPacket> batch) async {
    final result = await _ingestPacketBatch(batch);
    switch (result) {
      case Err(:final failure):
        error.value = failure.message;
      case Ok(:final IngestReceipt value):
        packetsReceived.value += value.packets;
        rowsApplied.value +=
            value.signalRowsApplied + value.locationRowsApplied;
        duplicatesRejected.value += value.duplicateRows;
        orphansDropped.value += value.orphanRows;
        lateVehicles.value += value.lateVehicles;
        batchesWritten.value += 1;
        lastBatchMs.value = value.duration.inMilliseconds;
        // Announce after the write, not before: a screen that re-queries on
        // this bump must find the rows already committed.
        _pulse?.ping();
        await refreshSnapshot();
    }
  }

  /// Re-reads the on-disk totals.
  Future<void> refreshSnapshot() async {
    final result = await _getIngestSnapshot(const NoParams());
    switch (result) {
      case Ok(:final IngestSnapshot value):
        snapshot.value = value;
      case Err(:final failure):
        error.value = failure.message;
    }
  }
}
