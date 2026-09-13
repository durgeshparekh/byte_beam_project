import 'vehicle_status.dart';

/// One row of the fleet list.
///
/// Every value is nullable except identity and status, because a vehicle that
/// has never reported a signal is a real case: it shows "—" rather than a
/// fabricated zero.
class FleetVehicleSummary {
  const FleetVehicleSummary({
    required this.vehicleId,
    required this.regNo,
    required this.model,
    required this.status,
    this.soc,
    this.rangeKm,
    this.speed,
    this.lastPing,
    this.alertSeverity,
  });

  final String vehicleId;
  final String regNo;
  final String model;

  /// First-match-wins status, decided in SQL.
  final VehicleStatus status;

  /// Battery state of charge, %.
  final double? soc;

  /// Estimated range remaining, km.
  final double? rangeKm;

  /// Latest speed, km/h. Carried for the list subtitle, not for the status —
  /// the status was already decided against freshness rules the UI does not
  /// re-implement.
  final double? speed;

  /// Newest event time from any signal or position report.
  final DateTime? lastPing;

  /// Worst live threshold breach, or null when nothing is wrong.
  final AlertSeverity? alertSeverity;

  /// True when the vehicle has never reported anything.
  bool get hasNeverReported => lastPing == null;
}
