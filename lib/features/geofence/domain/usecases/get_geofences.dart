import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/geofence.dart';
import '../repositories/geofence_repository.dart';

/// Loads the fence list with live counts.
class GetGeofences implements UseCase<List<GeofenceOccupancy>, NoParams> {
  const GetGeofences(this._repository);

  final GeofenceRepository _repository;

  @override
  Future<Result<List<GeofenceOccupancy>>> call(NoParams params) =>
      _repository.occupancy();
}
