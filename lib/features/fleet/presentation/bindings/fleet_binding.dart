import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../data/datasources/fleet_local_data_source.dart';
import '../../data/repositories/fleet_repository_impl.dart';
import '../../domain/repositories/fleet_repository.dart';
import '../../domain/usecases/get_fleet_overview.dart';
import '../controllers/fleet_controller.dart';

/// Wires the fleet feature.
///
/// Synchronous, unlike the ingest binding: the fleet list only reads, so it
/// needs the existing connection and nothing spawned.
class FleetBinding extends Bindings {
  FleetBinding({required this.db, this.clock = const SystemClock()});

  final FleetDb db;
  final Clock clock;

  @override
  void dependencies() {
    Get.put<FleetLocalDataSource>(
      DuckDbFleetLocalDataSource(db.read),
      permanent: true,
    );
    Get.put<FleetRepository>(
      FleetRepositoryImpl(Get.find<FleetLocalDataSource>()),
      permanent: true,
    );
    Get.put(
      FleetController(
        getFleetOverview: GetFleetOverview(Get.find<FleetRepository>()),
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
      ),
      permanent: true,
    );
  }
}
