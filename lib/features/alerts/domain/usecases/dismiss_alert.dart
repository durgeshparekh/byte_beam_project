import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/fleet_alert.dart';
import '../repositories/alert_repository.dart';

/// Parameters for [DismissAlert].
class DismissAlertParams {
  const DismissAlertParams({
    required this.alertId,
    required this.reason,
    required this.at,
    this.note,
  });

  final String alertId;
  final DismissReason reason;
  final DateTime at;

  /// Free text, only ever set for [DismissReason.somethingElse].
  final String? note;
}

/// Hides one alert and records the reason given.
class DismissAlert implements UseCase<void, DismissAlertParams> {
  const DismissAlert(this._repository);

  final AlertRepository _repository;

  @override
  Future<Result<void>> call(DismissAlertParams params) => _repository.dismiss(
    params.alertId,
    params.reason,
    params.at,
    note: params.note,
  );
}
