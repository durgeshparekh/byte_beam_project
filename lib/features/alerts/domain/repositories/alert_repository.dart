import '../../../../core/utils/result.dart';
import '../entities/fleet_alert.dart';

/// The domain's view of the alert list and the two things a user can do to it.
abstract class AlertRepository {
  /// Every alert that is neither resolved nor dismissed, worst first.
  Future<Result<List<FleetAlert>>> openAlerts();

  /// Hides [alertId] and records why.
  ///
  /// [at] is passed in rather than read from a clock here for the same reason
  /// as everywhere else in this codebase: the caller owns the instant so a
  /// test can pin it.
  Future<Result<void>> dismiss(
    String alertId,
    DismissReason reason,
    DateTime at, {
    String? note,
  });

  /// Puts a dismissed alert back. The UNDO path.
  Future<Result<void>> undoDismissal(String alertId);
}
