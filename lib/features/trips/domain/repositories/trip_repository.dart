import '../../../../core/utils/result.dart';
import '../entities/trip.dart';

/// The domain's view of derived trips. Read-only: a trip is a conclusion, and
/// there is nothing a user can do to one that would not be a lie about where
/// the truck went.
abstract class TripRepository {
  /// The fleet's most recent trips, running ones first.
  ///
  /// The only read here. Vehicle detail shows one truck's legs, but it reads
  /// them through its own data source so the whole screen comes off one
  /// snapshot — see `_trips` there.
  Future<Result<List<Trip>>> recent({int limit});
}
