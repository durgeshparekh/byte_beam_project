import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/vehicle_detail.dart';
import '../repositories/vehicle_detail_repository.dart';

/// Parameters for [GetVehicleDetail].
class VehicleDetailParams {
  const VehicleDetailParams({required this.vehicleId, required this.now});

  final String vehicleId;

  /// The instant every age and verdict is measured against. Passed in so one
  /// screen refresh judges every row by the same clock reading — deriving
  /// "now" per row would let two rows disagree about the same moment.
  final DateTime now;
}

/// Loads one vehicle's detail screen.
class GetVehicleDetail implements UseCase<VehicleDetail?, VehicleDetailParams> {
  const GetVehicleDetail(this._repository);

  final VehicleDetailRepository _repository;

  @override
  Future<Result<VehicleDetail?>> call(VehicleDetailParams params) =>
      _repository.detail(params.vehicleId, params.now);
}
