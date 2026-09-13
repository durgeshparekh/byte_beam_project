import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/error/failures.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/trips/domain/entities/trip.dart';
import 'package:byte_beam_project/features/trips/domain/repositories/trip_repository.dart';
import 'package:byte_beam_project/features/trips/domain/usecases/get_recent_trips.dart';
import 'package:byte_beam_project/features/trips/presentation/controllers/trips_controller.dart';
import 'package:get/get.dart';

final fakeNow = DateTime.utc(2026, 1, 1, 12);

/// Serves a canned trip list.
class StubTripRepository implements TripRepository {
  StubTripRepository([this.trips = const []]);

  List<Trip> trips;

  /// How many times the controller has re-read the list.
  var loads = 0;

  /// When set, reads fail with this message.
  String? failWith;

  @override
  Future<Result<List<Trip>>> recent({int limit = 100}) async {
    loads++;
    if (failWith case final message?) return Err(DatabaseFailure(message));
    return Ok(trips);
  }

  @override
  Future<Result<List<Trip>>> forVehicle(
    String vehicleId, {
    int limit = 100,
  }) async {
    if (failWith case final message?) return Err(DatabaseFailure(message));
    return Ok(trips.where((trip) => trip.vehicleId == vehicleId).toList());
  }
}

/// Registers a real controller over [repository].
TripsController putStubTrips(StubTripRepository repository) {
  final pulse = Get.isRegistered<DatabasePulse>()
      ? Get.find<DatabasePulse>()
      : Get.put(DatabasePulse());
  return Get.put(
    TripsController(
      getRecentTrips: GetRecentTrips(repository),
      pulse: pulse,
      clock: FakeClock(fakeNow),
      refreshDebounce: Duration.zero,
    ),
  );
}

/// A completed trip, unless [endedAt] is cleared.
Trip testTrip({
  String tripId = 'v1|1',
  String vehicleId = 'v1',
  String regNo = 'KA01AA0001',
  String? origin = 'Whitefield Depot',
  String? destination = 'Electronic City Hub',
  DateTime? startedAt,
  DateTime? endedAt,
  double? distanceKm = 42.5,
  bool isConfident = true,
  bool running = false,
}) {
  final start = startedAt ?? fakeNow.subtract(const Duration(hours: 2));
  return Trip(
    tripId: tripId,
    vehicleId: vehicleId,
    regNo: regNo,
    origin: origin,
    destination: running ? null : destination,
    startedAt: start,
    endedAt: running ? null : (endedAt ?? start.add(const Duration(hours: 1))),
    distanceKm: distanceKm,
    isConfident: isConfident,
  );
}
