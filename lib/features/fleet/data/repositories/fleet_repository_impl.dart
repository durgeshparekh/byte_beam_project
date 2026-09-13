import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_filter.dart';
import '../../domain/entities/fleet_overview.dart';
import '../../domain/repositories/fleet_repository.dart';
import '../datasources/fleet_local_data_source.dart';

/// Translates data-layer exceptions into domain failures. Nothing else —
/// the fleet list is a pure read, so there is no orchestration to do here.
class FleetRepositoryImpl implements FleetRepository {
  const FleetRepositoryImpl(this._local);

  final FleetLocalDataSource _local;

  @override
  Future<Result<FleetOverview>> overview(
    FleetFilter filter,
    DateTime now,
  ) async {
    try {
      return Ok(await _local.overview(filter, now));
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
