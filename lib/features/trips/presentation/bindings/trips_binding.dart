import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../data/datasources/trip_local_data_source.dart';
import '../../data/repositories/trip_repository_impl.dart';
import '../../domain/repositories/trip_repository.dart';
import '../../domain/usecases/get_recent_trips.dart';
import '../controllers/trips_controller.dart';

/// Wires the trips feature.
///
/// Needs nothing from the writer: trips are read-only on this side, derived
/// inside the ingest transaction and never edited from a screen.
class TripsBinding extends Bindings {
  TripsBinding({required this.db, this.clock = const SystemClock()});

  final FleetDb db;
  final Clock clock;

  @override
  void dependencies() {
    Get.put<TripLocalDataSource>(
      DuckDbTripLocalDataSource(db.read),
      permanent: true,
    );
    Get.put<TripRepository>(
      TripRepositoryImpl(Get.find<TripLocalDataSource>()),
      permanent: true,
    );
    Get.put(
      TripsController(
        getRecentTrips: GetRecentTrips(Get.find<TripRepository>()),
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
      ),
      permanent: true,
    );
  }
}
