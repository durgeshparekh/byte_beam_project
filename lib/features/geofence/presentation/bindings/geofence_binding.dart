import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../../telemetry_ingest/data/datasources/telemetry_writer_isolate.dart';
import '../../data/datasources/geofence_local_data_source.dart';
import '../../data/repositories/geofence_repository_impl.dart';
import '../../domain/repositories/geofence_repository.dart';
import '../../domain/usecases/get_geofences.dart';
import '../../domain/usecases/save_geofence.dart';
import '../../domain/usecases/set_geofence_active.dart';
import '../controllers/geofence_controller.dart';

/// Wires the geofence feature.
///
/// Must be built after `IngestBinding`, which registers the writer fence saves
/// go through.
class GeofenceBinding extends Bindings {
  GeofenceBinding({required this.db, this.clock = const SystemClock()});

  final FleetDb db;
  final Clock clock;

  @override
  void dependencies() {
    Get.put<GeofenceLocalDataSource>(
      DuckDbGeofenceLocalDataSource(db.read, Get.find<TelemetryWriter>()),
      permanent: true,
    );
    Get.put<GeofenceRepository>(
      GeofenceRepositoryImpl(Get.find<GeofenceLocalDataSource>()),
      permanent: true,
    );
    final repository = Get.find<GeofenceRepository>();
    Get.put(
      GeofenceController(
        getGeofences: GetGeofences(repository),
        saveGeofence: SaveGeofence(repository),
        setGeofenceActive: SetGeofenceActive(repository),
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
      ),
      permanent: true,
    );
  }
}
