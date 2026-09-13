import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/vehicle_detail.dart';
import '../../domain/repositories/vehicle_detail_repository.dart';
import '../datasources/vehicle_detail_local_data_source.dart';

/// Translates data-layer exceptions into domain failures.
class VehicleDetailRepositoryImpl implements VehicleDetailRepository {
  const VehicleDetailRepositoryImpl(this._local);

  final VehicleDetailLocalDataSource _local;

  @override
  Future<Result<VehicleDetail?>> detail(String vehicleId, DateTime now) async {
    try {
      return Ok(await _local.detail(vehicleId, now));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
