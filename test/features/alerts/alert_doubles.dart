import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/alerts/domain/entities/fleet_alert.dart';
import 'package:byte_beam_project/features/alerts/domain/repositories/alert_repository.dart';
import 'package:byte_beam_project/features/alerts/domain/usecases/dismiss_alert.dart';
import 'package:byte_beam_project/features/alerts/domain/usecases/get_open_alerts.dart';
import 'package:byte_beam_project/features/alerts/domain/usecases/undo_dismissal.dart';
import 'package:byte_beam_project/features/alerts/presentation/controllers/alerts_controller.dart';
import 'package:byte_beam_project/core/error/failures.dart';
import 'package:get/get.dart';

/// Serves a canned list and records what was asked of it.
///
/// Shared by the alerts tests and by the two page tests that only need the
/// controller to exist so the app bar and the detail screen can build.
class StubAlertRepository implements AlertRepository {
  StubAlertRepository([this.alerts = const []]);

  List<FleetAlert> alerts;

  /// Every dismissal, as the string that would reach `dismiss_reason`.
  final dismissals = <String>[];
  final restored = <String>[];

  /// When set, every write fails with this message.
  String? failWith;

  @override
  Future<Result<List<FleetAlert>>> openAlerts() async => Ok(alerts);

  @override
  Future<Result<void>> dismiss(
    String alertId,
    DismissReason reason,
    DateTime at, {
    String? note,
  }) async {
    if (failWith case final message?) return Err(DatabaseFailure(message));
    dismissals.add(reason.stored(note));
    alerts = alerts.where((a) => a.alertId != alertId).toList();
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> undoDismissal(String alertId) async {
    if (failWith case final message?) return Err(DatabaseFailure(message));
    restored.add(alertId);
    return const Ok<void>(null);
  }
}

/// Registers a real controller over [repository]. Real, not stubbed, because
/// the escalation getters and the dismiss/undo sequencing are what is under
/// test everywhere this is used.
AlertsController putStubAlerts(StubAlertRepository repository, {Clock? clock}) {
  final pulse = Get.isRegistered<DatabasePulse>()
      ? Get.find<DatabasePulse>()
      : Get.put(DatabasePulse());
  return Get.put(
    AlertsController(
      getOpenAlerts: GetOpenAlerts(repository),
      dismissAlert: DismissAlert(repository),
      undoDismissal: UndoDismissal(repository),
      pulse: pulse,
      clock: clock ?? FakeClock(DateTime.utc(2026, 1, 1, 12)),
      refreshDebounce: Duration.zero,
    ),
  );
}

/// A test alert, defaulting to a plain low-battery warning.
FleetAlert testAlert({
  String alertId = 'a1',
  String vehicleId = 'v1',
  String regNo = 'KA01AA0001',
  AlertType type = AlertType.batteryLow,
  AlertSeverity severity = AlertSeverity.warning,
  DateTime? raisedAt,
  DateTime? escalatedAt,
  double? value = 18,
  String unit = '%',
  Duration maxAge = const Duration(minutes: 5),
  DateTime? readingAt,
}) {
  return FleetAlert(
    alertId: alertId,
    vehicleId: vehicleId,
    regNo: regNo,
    type: type,
    severity: severity,
    raisedAt: raisedAt ?? DateTime.utc(2026, 1, 1, 11, 30),
    escalatedAt: escalatedAt,
    value: value,
    unit: unit,
    maxAge: maxAge,
    readingAt: readingAt ?? DateTime.utc(2026, 1, 1, 11, 59),
  );
}
