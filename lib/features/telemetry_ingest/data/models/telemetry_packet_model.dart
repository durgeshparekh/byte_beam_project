import '../../domain/entities/ingest_receipt.dart';
import '../../domain/entities/telemetry_packet.dart';

/// Data-layer representation of a packet.
///
/// Adds nothing to the entity except the flattening the writer needs. It stays
/// a separate type so the domain entity never grows database-shaped methods.
class TelemetryPacketModel extends TelemetryPacket {
  const TelemetryPacketModel({
    required super.vehicleId,
    required super.eventTs,
    super.signals,
    super.location,
  });

  /// Wraps a domain packet for transport to the writer isolate.
  factory TelemetryPacketModel.fromEntity(TelemetryPacket packet) {
    return TelemetryPacketModel(
      vehicleId: packet.vehicleId,
      eventTs: packet.eventTs,
      signals: packet.signals,
      location: packet.location,
    );
  }

  /// Expands this packet into one staging row per signal.
  ///
  /// The log is long-format — one row per (vehicle, signal, timestamp) — so a
  /// packet carrying four signals becomes four rows sharing a timestamp.
  Iterable<List<Object?>> toSignalRows() sync* {
    for (final entry in signals.entries) {
      yield [vehicleId, entry.key, eventTs, entry.value];
    }
  }

  /// The location row for this packet, or null when it carried no fix.
  List<Object?>? toLocationRow() {
    final fix = location;
    if (fix == null) return null;
    return [vehicleId, eventTs, fix.lat, fix.lon, fix.accuracyM];
  }
}

/// Data-layer receipt, built from the counts DuckDB reports.
///
/// Separate from the entity only so the isolate boundary carries a data-layer
/// type; the fields are identical.
class IngestReceiptModel extends IngestReceipt {
  const IngestReceiptModel({
    required super.packets,
    required super.signalRowsOffered,
    required super.signalRowsApplied,
    required super.locationRowsOffered,
    required super.locationRowsApplied,
    required super.lateVehicles,
    super.orphanRows,
    required super.duration,
  });
}
