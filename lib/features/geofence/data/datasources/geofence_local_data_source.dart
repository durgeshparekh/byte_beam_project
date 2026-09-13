import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/geofence_sql.dart';
import '../../../telemetry_ingest/data/datasources/telemetry_writer_isolate.dart';
import '../../domain/entities/geofence.dart';
import '../models/geofence_model.dart';

/// Reads fences and occupancy; writes fences through the single writer.
abstract class GeofenceLocalDataSource {
  /// Every fence with its live count, active ones first.
  Future<List<GeofenceOccupancy>> occupancy();

  /// One fence by id, or null. Used for the read-modify-write behind the
  /// active toggle.
  Future<Geofence?> byId(String geofenceId);

  /// Writes one fence and re-derives containment.
  Future<void> save(Geofence fence);
}

/// DuckDB implementation.
///
/// Same split as alerts: reads on the UI isolate's own connection, writes
/// through [TelemetryWriter]. A fence save also re-derives every transition,
/// which is emphatically a write and emphatically not something to run on two
/// connections at once.
class DuckDbGeofenceLocalDataSource implements GeofenceLocalDataSource {
  const DuckDbGeofenceLocalDataSource(this._read, this._writer);

  final Connection _read;
  final TelemetryWriter _writer;

  @override
  Future<List<GeofenceOccupancy>> occupancy() async {
    try {
      final result = await _read.query(geofenceOccupancyQuery);
      return [
        for (final row in result.fetchAll())
          GeofenceOccupancy(
            fence: GeofenceModel.fromRow(row),
            vehiclesInside: (row[8]! as num).toInt(),
          ),
      ];
    } catch (error) {
      throw LocalDatabaseException('geofence occupancy query failed', error);
    }
  }

  @override
  Future<Geofence?> byId(String geofenceId) async {
    try {
      final statement = await _read.prepare(
        r'SELECT * FROM geofence WHERE geofence_id = $1',
      );
      try {
        statement.bindParams([geofenceId]);
        final row = (await statement.execute()).fetchOne();
        return row == null ? null : GeofenceModel.fromRow(row);
      } finally {
        await statement.dispose();
      }
    } catch (error) {
      throw LocalDatabaseException('geofence lookup failed', error);
    }
  }

  @override
  Future<void> save(Geofence fence) =>
      _writer.saveGeofence(GeofenceModel.toRow(fence));
}
