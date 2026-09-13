import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/geofence.dart';
import '../../domain/repositories/geofence_repository.dart';
import '../datasources/geofence_local_data_source.dart';

/// Translates data-layer exceptions into domain failures, and turns the
/// active toggle into the read-modify-write the single upsert expects.
class GeofenceRepositoryImpl implements GeofenceRepository {
  const GeofenceRepositoryImpl(this._local);

  final GeofenceLocalDataSource _local;

  @override
  Future<Result<List<GeofenceOccupancy>>> occupancy() async {
    try {
      return Ok(await _local.occupancy());
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<void>> save(Geofence fence, DateTime at) async {
    try {
      await _local.save(fence);
      return const Ok<void>(null);
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<void>> setActive(
    String geofenceId, {
    required bool active,
    required DateTime at,
  }) async {
    try {
      final existing = await _local.byId(geofenceId);
      if (existing == null) {
        return const Err(DatabaseFailure('no such geofence'));
      }
      await _local.save(existing.withActive(active: active, at: at));
      return const Ok<void>(null);
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
