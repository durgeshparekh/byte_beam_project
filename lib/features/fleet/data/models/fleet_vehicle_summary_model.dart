import '../../domain/entities/fleet_vehicle_summary.dart';
import '../../domain/entities/vehicle_status.dart';

/// Row-to-entity mapping for the fleet list.
///
/// Kept out of the data source so the SQL file stays SQL, and out of the
/// entity so the domain never learns about column order.
class FleetVehicleSummaryModel extends FleetVehicleSummary {
  const FleetVehicleSummaryModel({
    required super.vehicleId,
    required super.regNo,
    required super.model,
    required super.status,
    super.soc,
    super.rangeKm,
    super.speed,
    super.lastPing,
    super.alertSeverity,
  });

  /// Builds a row in the column order the fleet query selects.
  factory FleetVehicleSummaryModel.fromRow(List<Object?> row) {
    return FleetVehicleSummaryModel(
      vehicleId: row[0]! as String,
      regNo: row[1]! as String,
      model: row[2]! as String,
      status: VehicleStatus.fromSql(row[3]! as String),
      soc: (row[4] as num?)?.toDouble(),
      rangeKm: (row[5] as num?)?.toDouble(),
      speed: (row[6] as num?)?.toDouble(),
      lastPing: row[7] as DateTime?,
      alertSeverity: AlertSeverity.fromSql(row[8] as String?),
    );
  }
}
