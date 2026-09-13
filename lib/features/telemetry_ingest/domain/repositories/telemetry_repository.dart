import '../../../../core/utils/result.dart';
import '../entities/fleet_vehicle.dart';
import '../entities/ingest_receipt.dart';
import '../entities/ingest_snapshot.dart';
import '../entities/telemetry_packet.dart';

/// The domain's view of telemetry. Implemented in the data layer.
///
/// Note what is absent: no DuckDB, no isolates, no simulator. Swapping the
/// simulator for a real MQTT feed, or DuckDB for something else, changes the
/// implementation behind this interface and nothing above it.
abstract class TelemetryRepository {
  /// Installs the fleet roster if the database is empty. Idempotent — calling
  /// it on every launch is expected and costs one `count(*)`.
  Future<Result<int>> seedFleet(List<FleetVehicle> vehicles);

  /// The live packet feed. Packets arrive already batched, because the source
  /// emits bursts (a vehicle leaving a basement dumps a backlog) and writing
  /// them one at a time would mean one transaction per row.
  Stream<List<TelemetryPacket>> watchPackets();

  /// Applies one batch durably and reports what happened.
  ///
  /// Idempotent by construction: re-applying the same batch produces a receipt
  /// with the same row count offered and zero applied.
  Future<Result<IngestReceipt>> ingest(List<TelemetryPacket> packets);

  /// Reads the current on-disk totals.
  Future<Result<IngestSnapshot>> snapshot();
}
