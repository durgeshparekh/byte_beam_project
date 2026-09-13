import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../repositories/geofence_repository.dart';

/// Parameters for [SetGeofenceActive].
class SetGeofenceActiveParams {
  const SetGeofenceActiveParams({
    required this.geofenceId,
    required this.active,
    required this.at,
  });

  final String geofenceId;
  final bool active;
  final DateTime at;
}

/// Deactivates or reactivates a fence.
///
/// Separate from [SaveGeofence] because it is a different intent with a
/// different meaning: nothing is deleted, and the fence keeps every transition
/// it earned while it was live.
class SetGeofenceActive implements UseCase<void, SetGeofenceActiveParams> {
  const SetGeofenceActive(this._repository);

  final GeofenceRepository _repository;

  @override
  Future<Result<void>> call(SetGeofenceActiveParams params) => _repository
      .setActive(params.geofenceId, active: params.active, at: params.at);
}
