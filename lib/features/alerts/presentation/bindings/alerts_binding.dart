import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../../telemetry_ingest/data/datasources/telemetry_writer_isolate.dart';
import '../../data/datasources/alert_local_data_source.dart';
import '../../data/repositories/alert_repository_impl.dart';
import '../../domain/repositories/alert_repository.dart';
import '../../domain/usecases/dismiss_alert.dart';
import '../../domain/usecases/get_open_alerts.dart';
import '../../domain/usecases/undo_dismissal.dart';
import '../controllers/alerts_controller.dart';

/// Wires the alerts feature.
///
/// Must be built after [IngestBinding], which registers the writer this
/// feature sends dismissals through.
class AlertsBinding extends Bindings {
  AlertsBinding({required this.db, this.clock = const SystemClock()});

  final FleetDb db;
  final Clock clock;

  @override
  void dependencies() {
    Get.put<AlertLocalDataSource>(
      DuckDbAlertLocalDataSource(db.read, Get.find<TelemetryWriter>()),
      permanent: true,
    );
    Get.put<AlertRepository>(
      AlertRepositoryImpl(Get.find<AlertLocalDataSource>()),
      permanent: true,
    );
    final repository = Get.find<AlertRepository>();
    Get.put(
      AlertsController(
        getOpenAlerts: GetOpenAlerts(repository),
        dismissAlert: DismissAlert(repository),
        undoDismissal: UndoDismissal(repository),
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
      ),
      permanent: true,
    );
  }
}
