import '../../../../core/utils/result.dart';
import '../entities/trip.dart';

/// The domain's view of derived trips. Read-only: a trip is a conclusion, and
/// there is nothing a user can do to one that would not be a lie about where
/// the truck went.
abstract class TripRepository {
  /// The fleet's most recent trips, running ones first.
  Future<Result<List<Trip>>> recent({int limit});

  /// One vehicle's most recent trips, newest first.
  Future<Result<List<Trip>>> forVehicle(String vehicleId, {int limit});
}
