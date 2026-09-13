import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/fleet_alert.dart';
import '../repositories/alert_repository.dart';

/// Loads the alert list.
///
/// Takes no instant: unlike the fleet list, nothing here is recomputed against
/// "now". Whether an alert is open was decided by the evaluator when it last
/// ran, and reading it is just reading it.
class GetOpenAlerts implements UseCase<List<FleetAlert>, NoParams> {
  const GetOpenAlerts(this._repository);

  final AlertRepository _repository;

  @override
  Future<Result<List<FleetAlert>>> call(NoParams params) =>
      _repository.openAlerts();
}
