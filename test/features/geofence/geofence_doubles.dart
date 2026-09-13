import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/error/failures.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/geofence/domain/entities/geofence.dart';
import 'package:byte_beam_project/features/geofence/domain/repositories/geofence_repository.dart';
import 'package:byte_beam_project/features/geofence/domain/usecases/get_geofences.dart';
import 'package:byte_beam_project/features/geofence/domain/usecases/save_geofence.dart';
import 'package:byte_beam_project/features/geofence/domain/usecases/set_geofence_active.dart';
import 'package:byte_beam_project/features/geofence/presentation/controllers/geofence_controller.dart';
import 'package:get/get.dart';

final fakeNow = DateTime.utc(2026, 1, 1, 12);

/// Serves a canned fence list and records what was written to it.
class StubGeofenceRepository implements GeofenceRepository {
  StubGeofenceRepository([this.fences = const []]);

  List<GeofenceOccupancy> fences;

  /// Every fence handed to [save], in order.
  final saved = <Geofence>[];

  /// Every active toggle, as (id, active).
  final toggled = <(String, bool)>[];

  /// When set, every write fails with this message.
  String? failWith;

  @override
  Future<Result<List<GeofenceOccupancy>>> occupancy() async => Ok(fences);

  @override
  Future<Result<void>> save(Geofence fence, DateTime at) async {
    if (failWith case final message?) return Err(DatabaseFailure(message));
    saved.add(fence);
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> setActive(
    String geofenceId, {
    required bool active,
    required DateTime at,
  }) async {
    if (failWith case final message?) return Err(DatabaseFailure(message));
    toggled.add((geofenceId, active));
    return const Ok<void>(null);
  }
}

/// Registers a real controller over [repository].
GeofenceController putStubGeofences(StubGeofenceRepository repository) {
  final pulse = Get.isRegistered<DatabasePulse>()
      ? Get.find<DatabasePulse>()
      : Get.put(DatabasePulse());
  return Get.put(
    GeofenceController(
      getGeofences: GetGeofences(repository),
      saveGeofence: SaveGeofence(repository),
      setGeofenceActive: SetGeofenceActive(repository),
      pulse: pulse,
      clock: FakeClock(fakeNow),
      refreshDebounce: Duration.zero,
    ),
  );
}

/// A test fence, active by default.
GeofenceOccupancy testFence({
  String geofenceId = 'gf1',
  String name = 'Whitefield Depot',
  double lat = 12.97,
  double lon = 77.60,
  double radiusM = 2500,
  DateTime? activeTo,
  int vehiclesInside = 0,
}) {
  return GeofenceOccupancy(
    fence: Geofence(
      geofenceId: geofenceId,
      name: name,
      lat: lat,
      lon: lon,
      radiusM: radiusM,
      activeFrom: DateTime.utc(2026),
      activeTo: activeTo,
      updatedAt: DateTime.utc(2026),
    ),
    vehiclesInside: vehiclesInside,
  );
}
