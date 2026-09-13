import '../../domain/entities/fleet_alert.dart';

/// Row-to-entity mapping for the alert list.
///
/// A subclass rather than a converter so the query result *is* the entity and
/// nothing downstream copies it again.
class FleetAlertModel extends FleetAlert {
  const FleetAlertModel({
    required super.alertId,
    required super.vehicleId,
    required super.regNo,
    required super.type,
    required super.severity,
    required super.raisedAt,
    required super.unit,
    required super.maxAge,
    super.escalatedAt,
    super.value,
    super.readingAt,
  });

  /// Column order is fixed by the SELECT in `AlertLocalDataSource`.
  factory FleetAlertModel.fromRow(List<Object?> row) => FleetAlertModel(
    alertId: row[0]! as String,
    vehicleId: row[1]! as String,
    regNo: row[2]! as String,
    type: AlertType.fromSql(row[3]! as String),
    // Not nullable here, unlike on the fleet summary: a row in this list only
    // exists because the evaluator gave it a severity.
    severity: AlertSeverity.fromSql(row[4] as String?)!,
    raisedAt: row[5]! as DateTime,
    escalatedAt: row[6] as DateTime?,
    value: (row[7] as num?)?.toDouble(),
    unit: (row[8] as String?) ?? '',
    maxAge: Duration(seconds: (row[9] as num?)?.toInt() ?? 0),
    readingAt: row[10] as DateTime?,
  );
}
