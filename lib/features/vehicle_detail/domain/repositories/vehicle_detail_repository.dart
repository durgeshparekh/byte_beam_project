import '../../../../core/utils/result.dart';
import '../entities/vehicle_detail.dart';

/// The domain's view of one vehicle.
abstract class VehicleDetailRepository {
  /// Header, register and history for [vehicleId] at [now].
  ///
  /// A null value inside [Ok] means "no such vehicle", which is a normal
  /// answer and not a failure — the caller shows a not-found state rather
  /// than an error.
  Future<Result<VehicleDetail?>> detail(String vehicleId, DateTime now);
}
