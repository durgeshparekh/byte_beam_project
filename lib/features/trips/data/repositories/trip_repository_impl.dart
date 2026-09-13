import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/trip.dart';
import '../../domain/repositories/trip_repository.dart';
import '../datasources/trip_local_data_source.dart';

/// Translates data-layer exceptions into domain failures.
class TripRepositoryImpl implements TripRepository {
  const TripRepositoryImpl(this._local);

  final TripLocalDataSource _local;

  @override
  Future<Result<List<Trip>>> recent({int limit = 100}) async {
    try {
      return Ok(await _local.recent(limit));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<List<Trip>>> forVehicle(
    String vehicleId, {
    int limit = 100,
  }) async {
    try {
      return Ok(await _local.forVehicle(vehicleId, limit));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
