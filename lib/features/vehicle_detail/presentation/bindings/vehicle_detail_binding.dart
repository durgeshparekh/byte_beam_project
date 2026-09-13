import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../data/datasources/vehicle_detail_local_data_source.dart';
import '../../data/repositories/vehicle_detail_repository_impl.dart';
import '../../domain/repositories/vehicle_detail_repository.dart';
import '../../domain/usecases/get_vehicle_detail.dart';
import '../controllers/vehicle_detail_controller.dart';

/// Wires the vehicle detail feature. Read-only, so nothing async here.
class VehicleDetailBinding extends Bindings {
  VehicleDetailBinding({required this.db, this.clock = const SystemClock()});

  final FleetDb db;
  final Clock clock;

  @override
  void dependencies() {
    Get.put<VehicleDetailLocalDataSource>(
      DuckDbVehicleDetailLocalDataSource(db.read),
      permanent: true,
    );
    Get.put<VehicleDetailRepository>(
      VehicleDetailRepositoryImpl(Get.find<VehicleDetailLocalDataSource>()),
      permanent: true,
    );
    Get.put(
      VehicleDetailController(
        getVehicleDetail: GetVehicleDetail(Get.find<VehicleDetailRepository>()),
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
      ),
      permanent: true,
    );
  }
}
