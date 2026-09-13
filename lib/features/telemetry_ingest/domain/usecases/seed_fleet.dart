import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/fleet_vehicle.dart';
import '../repositories/telemetry_repository.dart';

/// Ensures the fleet roster exists before any telemetry is ingested.
///
/// Runs on every launch. The repository makes it a no-op when the roster is
/// already there, so there is no "first run" branch anywhere in the UI.
class SeedFleet implements UseCase<int, List<FleetVehicle>> {
  const SeedFleet(this._repository);

  final TelemetryRepository _repository;

  /// Returns the number of vehicles inserted — zero on every launch but the
  /// first.
  @override
  Future<Result<int>> call(List<FleetVehicle> params) =>
      _repository.seedFleet(params);
}
