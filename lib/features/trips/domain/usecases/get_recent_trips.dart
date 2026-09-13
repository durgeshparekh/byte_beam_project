import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/trip.dart';
import '../repositories/trip_repository.dart';

/// Loads the fleet-wide trip list.
class GetRecentTrips implements UseCase<List<Trip>, RecentTripsParams> {
  const GetRecentTrips(this._repository);

  final TripRepository _repository;

  @override
  Future<Result<List<Trip>>> call(RecentTripsParams params) =>
      _repository.recent(limit: params.limit);
}

/// How many rows to fetch. A cap rather than a page cursor: the screen is a
/// recent-activity feed, and anything older is a question for a report.
class RecentTripsParams {
  const RecentTripsParams({this.limit = 100});

  final int limit;
}
