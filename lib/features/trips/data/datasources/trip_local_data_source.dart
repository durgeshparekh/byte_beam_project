import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/trip_sql.dart';
import '../../domain/entities/trip.dart';
import '../models/trip_model.dart';

/// Reads derived trips. There is no write side: trips are rebuilt by the
/// writer on every batch, and nothing a user does can edit one.
abstract class TripLocalDataSource {
  /// The fleet's most recent trips, running ones first.
  Future<List<Trip>> recent(int limit);

  /// One vehicle's most recent trips, newest first.
  Future<List<Trip>> forVehicle(String vehicleId, int limit);
}

/// DuckDB implementation, on the UI isolate's own read connection.
class DuckDbTripLocalDataSource implements TripLocalDataSource {
  const DuckDbTripLocalDataSource(this._read);

  final Connection _read;

  @override
  Future<List<Trip>> recent(int limit) async {
    try {
      final result = await _read.query(fleetTripsQuery(limit));
      return [for (final row in result.fetchAll()) TripModel.fromRow(row)];
    } catch (error) {
      throw LocalDatabaseException('trip list query failed', error);
    }
  }

  @override
  Future<List<Trip>> forVehicle(String vehicleId, int limit) async {
    try {
      final statement = await _read.prepare(vehicleTripsQuery(limit));
      try {
        statement.bindParams([vehicleId]);
        final result = await statement.execute();
        return [for (final row in result.fetchAll()) TripModel.fromRow(row)];
      } finally {
        await statement.dispose();
      }
    } catch (error) {
      throw LocalDatabaseException('vehicle trip query failed', error);
    }
  }
}
