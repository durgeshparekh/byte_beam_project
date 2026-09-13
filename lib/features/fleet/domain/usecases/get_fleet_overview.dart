import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/fleet_filter.dart';
import '../entities/fleet_overview.dart';
import '../repositories/fleet_repository.dart';

/// Parameters for [GetFleetOverview].
class FleetOverviewParams {
  const FleetOverviewParams({required this.filter, required this.now});

  final FleetFilter filter;

  /// The instant to evaluate freshness against.
  final DateTime now;
}

/// Loads the fleet list for one chip.
class GetFleetOverview implements UseCase<FleetOverview, FleetOverviewParams> {
  const GetFleetOverview(this._repository);

  final FleetRepository _repository;

  @override
  Future<Result<FleetOverview>> call(FleetOverviewParams params) =>
      _repository.overview(params.filter, params.now);
}
