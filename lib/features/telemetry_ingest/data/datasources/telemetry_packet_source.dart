import '../../domain/entities/fleet_vehicle.dart';
import '../../domain/entities/telemetry_packet.dart';

/// Where packets come from.
///
/// The simulator implements this today. A real MQTT or HTTP feed implements
/// the same three members and nothing above this line changes — that is the
/// seam ARCHITECTURE.md §3.7 describes.
abstract class TelemetryPacketSource {
  /// The roster this source will emit packets for. Known up front because the
  /// fleet is reference data, not telemetry.
  List<FleetVehicle> get fleet;

  /// Batched packet feed. Batched rather than per-packet because real arrivals
  /// are bursty and one transaction per row would be absurd.
  Stream<List<TelemetryPacket>> stream();

  /// Stops emitting and releases timers.
  Future<void> dispose();
}
