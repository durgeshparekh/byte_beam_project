import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_alert.dart';
import '../../domain/usecases/dismiss_alert.dart';
import '../../domain/usecases/get_open_alerts.dart';
import '../../domain/usecases/undo_dismissal.dart';

/// Drives the alerts screen, and the alert count in the fleet app bar.
///
/// Permanent and loaded at startup rather than when the alerts screen opens,
/// because the fleet app bar shows the open count before anyone has been
/// there.
class AlertsController extends GetxController {
  AlertsController({
    required GetOpenAlerts getOpenAlerts,
    required DismissAlert dismissAlert,
    required UndoDismissal undoDismissal,
    required DatabasePulse pulse,
    required Clock clock,
    this.refreshDebounce = const Duration(milliseconds: 250),
  }) : _getOpenAlerts = getOpenAlerts,
       _dismissAlert = dismissAlert,
       _undoDismissal = undoDismissal,
       _pulse = pulse,
       _clock = clock;

  final GetOpenAlerts _getOpenAlerts;
  final DismissAlert _dismissAlert;
  final UndoDismissal _undoDismissal;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// How long to settle after a write before re-querying.
  final Duration refreshDebounce;

  /// Open alerts, worst first.
  final alerts = <FleetAlert>[].obs;

  /// True until the first query returns.
  final isLoading = true.obs;

  /// Last error, or empty.
  final error = ''.obs;

  /// The instant the visible ages were measured against, so every card on
  /// screen agrees about how old things are.
  final evaluatedAt = Rxn<DateTime>();

  /// Badge count for the fleet app bar.
  int get openCount => alerts.length;

  /// Whether anything on the list is critical — decides the badge colour.
  bool get hasCritical =>
      alerts.any((alert) => alert.severity == AlertSeverity.critical);

  /// The alerts for one vehicle, for the detail screen. A filter over the list
  /// already in memory rather than a second query: it is at most a few hundred
  /// rows and the two screens must not disagree.
  List<FleetAlert> forVehicle(String vehicleId) =>
      alerts.where((alert) => alert.vehicleId == vehicleId).toList();

  @override
  void onInit() {
    super.onInit();
    // The evaluator runs inside ingest, so a commit is the only thing that can
    // change this list — apart from the user's own dismissals, which reload
    // directly.
    debounce<int>(_pulse.revision, (_) => load(), time: refreshDebounce);
    load();
  }

  /// Re-reads the open alerts.
  Future<void> load() async {
    final result = await _getOpenAlerts(const NoParams());
    switch (result) {
      case Ok(:final List<FleetAlert> value):
        alerts.value = value;
        evaluatedAt.value = _clock.nowUtc();
        error.value = '';
      case Err(:final failure):
        error.value = failure.message;
    }
    isLoading.value = false;
  }

  /// Hides [alert] and records [reason]. Returns true when it stuck.
  ///
  /// The dismissal is on disk before this returns. It is deliberately not held
  /// in memory for the length of the undo window: local-first means the
  /// database is the truth, and if the app dies during those five seconds the
  /// user's explicit action should survive, not evaporate.
  Future<bool> dismiss(
    FleetAlert alert,
    DismissReason reason, {
    String? note,
  }) async {
    final result = await _dismissAlert(
      DismissAlertParams(
        alertId: alert.alertId,
        reason: reason,
        at: _clock.nowUtc(),
        note: note,
      ),
    );
    return _settle(result);
  }

  /// Puts a dismissed alert back. Returns true when it stuck.
  Future<bool> undo(String alertId) async =>
      _settle(await _undoDismissal(alertId));

  /// Shared tail of both actions: surface the failure or refresh everything
  /// that reads this table.
  Future<bool> _settle(Result<void> result) async {
    if (result case Err(:final failure)) {
      error.value = failure.message;
      return false;
    }
    error.value = '';
    // Reload before the pulse so this screen is right immediately, and pulse
    // so the fleet badge follows.
    await load();
    _pulse.ping();
    return true;
  }
}
