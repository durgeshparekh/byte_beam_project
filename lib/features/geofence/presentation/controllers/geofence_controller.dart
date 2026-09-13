import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/geofence.dart';
import '../../domain/usecases/get_geofences.dart';
import '../../domain/usecases/save_geofence.dart';
import '../../domain/usecases/set_geofence_active.dart';

/// Drives the geofence screen.
class GeofenceController extends GetxController {
  GeofenceController({
    required GetGeofences getGeofences,
    required SaveGeofence saveGeofence,
    required SetGeofenceActive setGeofenceActive,
    required DatabasePulse pulse,
    required Clock clock,
    this.refreshDebounce = const Duration(milliseconds: 250),
  }) : _getGeofences = getGeofences,
       _saveGeofence = saveGeofence,
       _setGeofenceActive = setGeofenceActive,
       _pulse = pulse,
       _clock = clock;

  final GetGeofences _getGeofences;
  final SaveGeofence _saveGeofence;
  final SetGeofenceActive _setGeofenceActive;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// How long to settle after a write before re-querying.
  final Duration refreshDebounce;

  /// Fences with live counts, active ones first.
  final fences = <GeofenceOccupancy>[].obs;

  /// True until the first query returns.
  final isLoading = true.obs;

  /// True while a save is in flight. A save re-derives every transition in the
  /// database, so it is the one action here worth showing progress for.
  final isSaving = false.obs;

  /// Last error, or empty.
  final error = ''.obs;

  /// Count of fences still judging fixes, for the screen's subtitle.
  int get activeCount => fences.where((o) => o.fence.isActive).length;

  @override
  void onInit() {
    super.onInit();
    // Counts move with every ingest batch, since the detector runs inside one.
    debounce<int>(_pulse.revision, (_) => load(), time: refreshDebounce);
    load();
  }

  /// Re-reads fences and their occupancy.
  Future<void> load() async {
    final result = await _getGeofences(const NoParams());
    switch (result) {
      case Ok(:final List<GeofenceOccupancy> value):
        fences.value = value;
        error.value = '';
      case Err(:final failure):
        error.value = failure.message;
    }
    isLoading.value = false;
  }

  /// Builds a blank fence for the editor, centred on the fleet's own patch.
  ///
  /// A new fence is active from *now*, which is why it starts with no history:
  /// claiming a truck was inside it last week would be inventing a fact.
  Geofence blank() {
    final now = _clock.nowUtc();
    return Geofence(
      geofenceId: 'gf-${now.microsecondsSinceEpoch}',
      name: '',
      lat: 12.97,
      lon: 77.60,
      radiusM: 500,
      activeFrom: now,
      updatedAt: now,
    );
  }

  /// Creates or updates a fence. Returns true when it stuck.
  Future<bool> save(Geofence fence) async {
    isSaving.value = true;
    final result = await _saveGeofence(
      SaveGeofenceParams(fence: fence, at: _clock.nowUtc()),
    );
    isSaving.value = false;
    return _settle(result);
  }

  /// Turns a fence on or off. Returns true when it stuck.
  Future<bool> setActive(String geofenceId, {required bool active}) async {
    isSaving.value = true;
    final result = await _setGeofenceActive(
      SetGeofenceActiveParams(
        geofenceId: geofenceId,
        active: active,
        at: _clock.nowUtc(),
      ),
    );
    isSaving.value = false;
    return _settle(result);
  }

  /// Shared tail of both writes: surface the failure, or refresh everything
  /// that reads containment.
  Future<bool> _settle(Result<void> result) async {
    if (result case Err(:final failure)) {
      error.value = failure.message;
      return false;
    }
    error.value = '';
    await load();
    // A fence change rewrites every transition, so the vehicle screens are
    // stale too, not just this one.
    _pulse.ping();
    return true;
  }
}
