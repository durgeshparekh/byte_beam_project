import 'vehicle_status.dart';

/// The chip row above the fleet list.
///
/// [all] is deliberately part of the same enum rather than a nullable status:
/// the UI needs a fifth chip with its own count, and modelling it as "no
/// filter" would mean a special case at every call site.
enum FleetFilter {
  all,
  moving,
  idle,
  stopped,
  offline;

  /// The status this filter selects, or null for [all].
  VehicleStatus? get status => switch (this) {
    FleetFilter.all => null,
    FleetFilter.moving => VehicleStatus.moving,
    FleetFilter.idle => VehicleStatus.idle,
    FleetFilter.stopped => VehicleStatus.stopped,
    FleetFilter.offline => VehicleStatus.offline,
  };

  /// Chip label.
  String get label => switch (this) {
    FleetFilter.all => 'All',
    FleetFilter.moving => 'Moving',
    FleetFilter.idle => 'Idle',
    FleetFilter.stopped => 'Stopped',
    FleetFilter.offline => 'Offline',
  };
}
