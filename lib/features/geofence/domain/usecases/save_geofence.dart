import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/geofence.dart';
import '../repositories/geofence_repository.dart';

/// Parameters for [SaveGeofence].
class SaveGeofenceParams {
  const SaveGeofenceParams({required this.fence, required this.at});

  final Geofence fence;
  final DateTime at;
}

/// Creates or edits a fence.
///
/// Saving triggers a full re-derivation of containment, because the geometry
/// it changed is an input to every transition ever recorded for it.
class SaveGeofence implements UseCase<void, SaveGeofenceParams> {
  const SaveGeofence(this._repository);

  final GeofenceRepository _repository;

  @override
  Future<Result<void>> call(SaveGeofenceParams params) =>
      _repository.save(params.fence, params.at);
}
