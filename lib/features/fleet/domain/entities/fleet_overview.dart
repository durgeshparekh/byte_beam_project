import 'fleet_filter.dart';
import 'fleet_vehicle_summary.dart';

/// Everything the fleet screen renders in one value.
///
/// Rows and counts travel together because they are read in the same refresh
/// and must agree: a chip that says "12 moving" beside a list of 9 is worse
/// than either number being slightly stale.
class FleetOverview {
  const FleetOverview({
    required this.filter,
    required this.vehicles,
    required this.counts,
  });

  const FleetOverview.empty()
    : filter = FleetFilter.all,
      vehicles = const [],
      counts = const {};

  /// Which chip produced [vehicles].
  final FleetFilter filter;

  /// The rows matching [filter], already ordered.
  final List<FleetVehicleSummary> vehicles;

  /// Live count per chip, computed in SQL over the whole fleet — not by
  /// counting [vehicles], which only holds the current filter.
  final Map<FleetFilter, int> counts;

  /// Count for one chip, zero when no vehicle is in that state.
  int countFor(FleetFilter filter) => counts[filter] ?? 0;

  /// True when the fleet has vehicles but this filter matched none — the case
  /// that gets an empty state rather than a blank screen.
  bool get isFilteredEmpty => vehicles.isEmpty && countFor(FleetFilter.all) > 0;

  /// True when there is no fleet at all yet.
  bool get isFleetEmpty => countFor(FleetFilter.all) == 0;
}
