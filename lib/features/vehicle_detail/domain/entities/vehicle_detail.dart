import '../../../fleet/domain/entities/vehicle_status.dart';
import '../../../geofence/domain/entities/geofence.dart';
import '../../../trips/domain/entities/trip.dart';
import 'signal_reading_row.dart';
import 'soc_history.dart';

/// Everything the vehicle detail screen renders.
class VehicleDetail {
  const VehicleDetail({
    required this.vehicleId,
    required this.regNo,
    required this.model,
    required this.status,
    required this.readings,
    required this.history,
    required this.visits,
    required this.trips,
    this.lastPing,
    this.currentGeofence,
  });

  final String vehicleId;
  final String regNo;
  final String model;

  /// Decided by the same SQL ladder the fleet list uses, so the chip here and
  /// the chip on the previous screen can never disagree.
  final VehicleStatus status;

  /// Newest event time from any signal or position report. Rendered as its own
  /// register row, with an age but no verdict pill: the status chip above
  /// already makes the liveness claim, and a second one could contradict it.
  final DateTime? lastPing;

  /// The register, in display order.
  final List<SignalReadingRow> readings;

  /// Battery history over the retained window.
  final SocHistory history;

  /// The fence the vehicle is in, or null when it is not in one.
  ///
  /// A single name for something that is genuinely a set: containment is
  /// tracked per fence, and a truck in a bay inside a depot is inside two.
  /// This is the most specific true answer — the smallest fence containing it
  /// (ARCHITECTURE.md §10, ambiguity 10).
  final String? currentGeofence;

  /// Recent crossings, newest first. The visible evidence that the detector
  /// runs at all; the containment above is only its latest conclusion.
  final List<GeofenceVisit> visits;

  /// Recent legs, newest first, running one at the top when there is one.
  ///
  /// A second reading of the same crossings the panel above lists — trips are
  /// derived from `geofence_transition` and nothing else — so the two sections
  /// are a free consistency check on each other.
  final List<Trip> trips;
}
