import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/vehicle_detail.dart';
import '../../domain/usecases/get_vehicle_detail.dart';

/// Drives the vehicle detail screen.
///
/// One permanent controller rather than one per vehicle keyed by tag: only one
/// detail screen is open at a time, so [open] switching the subject is simpler
/// than a tagged instance per vehicle and leaves nothing to dispose.
class VehicleDetailController extends GetxController {
  VehicleDetailController({
    required GetVehicleDetail getVehicleDetail,
    required DatabasePulse pulse,
    required Clock clock,
    this.refreshDebounce = const Duration(milliseconds: 250),
  }) : _getVehicleDetail = getVehicleDetail,
       _pulse = pulse,
       _clock = clock;

  final GetVehicleDetail _getVehicleDetail;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// How long to settle after a write before re-querying.
  final Duration refreshDebounce;

  /// Vehicle currently on screen, or empty before the first [open].
  final vehicleId = ''.obs;

  /// Loaded detail, or null while loading or when the vehicle is unknown.
  final detail = Rxn<VehicleDetail>();

  /// True until the first query for the current vehicle returns.
  final isLoading = true.obs;

  /// True when the roster has no such vehicle.
  final notFound = false.obs;

  /// Last error, or empty.
  final error = ''.obs;

  /// The instant the visible ages and verdicts were measured against.
  ///
  /// Held so the UI renders ages from the same reading the verdicts used. A
  /// row whose pill says STALE while its age reads "2s ago" is worse than a
  /// clock that ticks only on refresh.
  final evaluatedAt = Rxn<DateTime>();

  @override
  void onInit() {
    super.onInit();
    debounce<int>(_pulse.revision, (_) => _reload(), time: refreshDebounce);
  }

  /// Switches the screen to [id] and loads it.
  Future<void> open(String id) async {
    if (vehicleId.value != id) {
      vehicleId.value = id;
      detail.value = null;
      isLoading.value = true;
      notFound.value = false;
      error.value = '';
    }
    await _reload();
  }

  /// Re-queries the current vehicle. Does nothing before the first [open].
  Future<void> _reload() async {
    final id = vehicleId.value;
    if (id.isEmpty) return;

    final now = _clock.nowUtc();
    final result = await _getVehicleDetail(
      VehicleDetailParams(vehicleId: id, now: now),
    );
    switch (result) {
      case Ok(:final VehicleDetail? value):
        detail.value = value;
        notFound.value = value == null;
        evaluatedAt.value = now;
        error.value = '';
      case Err(:final failure):
        error.value = failure.message;
    }
    isLoading.value = false;
  }

  /// Pull-to-refresh and the retry button.
  Future<void> refreshNow() => _reload();
}
