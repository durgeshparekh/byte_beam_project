import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_vehicle.dart';
import '../../domain/entities/ingest_receipt.dart';
import '../../domain/entities/ingest_snapshot.dart';
import '../../domain/entities/telemetry_packet.dart';
import '../../domain/repositories/telemetry_repository.dart';
import '../datasources/telemetry_local_data_source.dart';
import '../datasources/telemetry_packet_source.dart';
import '../models/telemetry_packet_model.dart';

/// Binds the packet source to local storage.
///
/// This is the only class that knows both exist. Its other job is translation:
/// data-layer exceptions stop here and become `Failure`s, so nothing in the
/// domain or the UI has to catch anything.
class TelemetryRepositoryImpl implements TelemetryRepository {
  const TelemetryRepositoryImpl({
    required TelemetryLocalDataSource local,
    required TelemetryPacketSource source,
    required Clock clock,
  }) : _local = local,
       _source = source,
       _clock = clock;

  final TelemetryLocalDataSource _local;
  final TelemetryPacketSource _source;

  /// Supplies the instant the alert evaluator scores freshness against. The
  /// repository owns it rather than the writer because "now" is a decision
  /// about the read of the world, and the writer should not be making one.
  final Clock _clock;

  @override
  Future<Result<int>> seedFleet(List<FleetVehicle> vehicles) async {
    try {
      return Ok(await _local.seedFleet(vehicles));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  /// Passes the source's batches straight through.
  ///
  /// No extra buffering: the source already emits one batch per tick, which is
  /// the transaction boundary the writer wants. Adding a debounce here would
  /// just delay writes that are already batched.
  @override
  Stream<List<TelemetryPacket>> watchPackets() => _source.stream();

  @override
  Future<Result<IngestReceipt>> ingest(List<TelemetryPacket> packets) async {
    try {
      final batch = [
        for (final packet in packets) TelemetryPacketModel.fromEntity(packet),
      ];
      return Ok(await _local.applyBatch(batch, _clock.nowUtc()));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<IngestSnapshot>> snapshot() async {
    try {
      return Ok(await _local.snapshot());
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
