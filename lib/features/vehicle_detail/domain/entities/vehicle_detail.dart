import '../../../fleet/domain/entities/vehicle_status.dart';
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
    this.lastPing,
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
}
