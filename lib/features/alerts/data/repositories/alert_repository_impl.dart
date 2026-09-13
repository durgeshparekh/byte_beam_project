import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_alert.dart';
import '../../domain/repositories/alert_repository.dart';
import '../datasources/alert_local_data_source.dart';

/// Translates data-layer exceptions into domain failures.
class AlertRepositoryImpl implements AlertRepository {
  const AlertRepositoryImpl(this._local);

  final AlertLocalDataSource _local;

  @override
  Future<Result<List<FleetAlert>>> openAlerts() async {
    try {
      return Ok(await _local.openAlerts());
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<void>> dismiss(
    String alertId,
    DismissReason reason,
    DateTime at, {
    String? note,
  }) async {
    try {
      await _local.dismiss(alertId, reason.stored(note), at);
      return const Ok<void>(null);
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }

  @override
  Future<Result<void>> undoDismissal(String alertId) async {
    try {
      await _local.restore(alertId);
      return const Ok<void>(null);
    } on LocalDatabaseException catch (error) {
      return Err(DatabaseFailure(error.message));
    }
  }
}
