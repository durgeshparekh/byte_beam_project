import '../../domain/entities/geofence.dart';

/// Row-to-entity mapping for fences.
class GeofenceModel extends Geofence {
  const GeofenceModel({
    required super.geofenceId,
    required super.name,
    required super.lat,
    required super.lon,
    required super.radiusM,
    required super.activeFrom,
    required super.updatedAt,
    super.activeTo,
  });

  /// Column order is the table's own, which is also what [toRow] writes back.
  factory GeofenceModel.fromRow(List<Object?> row) => GeofenceModel(
    geofenceId: row[0]! as String,
    name: row[1]! as String,
    lat: (row[2]! as num).toDouble(),
    lon: (row[3]! as num).toDouble(),
    radiusM: (row[4]! as num).toDouble(),
    activeFrom: row[5]! as DateTime,
    activeTo: row[6] as DateTime?,
    updatedAt: row[7]! as DateTime,
  );

  /// The whole fence as parameters for the upsert, in column order.
  static List<Object?> toRow(Geofence fence) => [
    fence.geofenceId,
    fence.name,
    fence.lat,
    fence.lon,
    fence.radiusM,
    fence.activeFrom,
    fence.activeTo,
    fence.updatedAt,
  ];
}
