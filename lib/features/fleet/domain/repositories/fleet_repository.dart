import '../../../../core/utils/result.dart';
import '../entities/fleet_filter.dart';
import '../entities/fleet_overview.dart';

/// The domain's view of the fleet list.
abstract class FleetRepository {
  /// Rows for [filter] plus every chip's count, evaluated at [now].
  ///
  /// [now] is a parameter rather than something the repository reads from the
  /// clock itself, so the caller owns the instant and a test can pin it.
  Future<Result<FleetOverview>> overview(FleetFilter filter, DateTime now);
}
