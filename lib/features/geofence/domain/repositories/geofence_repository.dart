import '../../../../core/utils/result.dart';
import '../entities/geofence.dart';

/// The domain's view of fences and what a user can do to them.
abstract class GeofenceRepository {
  /// Every fence with its live occupancy, active ones first.
  Future<Result<List<GeofenceOccupancy>>> occupancy();

  /// Creates or updates one fence, then re-derives containment.
  ///
  /// [at] is the instant the change is stamped with, passed in rather than
  /// read from a clock here so a test can pin it.
  Future<Result<void>> save(Geofence fence, DateTime at);

  /// Turns a fence on or off without deleting it.
  Future<Result<void>> setActive(
    String geofenceId, {
    required bool active,
    required DateTime at,
  });
}
