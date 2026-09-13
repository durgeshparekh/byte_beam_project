import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'geofence_doubles.dart';

void main() {
  late StubGeofenceRepository repository;
  late DatabasePulse pulse;

  setUp(() {
    repository = StubGeofenceRepository();
    pulse = Get.put(DatabasePulse());
  });
  tearDown(Get.reset);

  test('it loads fences on init', () async {
    repository.fences = [testFence()];
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.fences, hasLength(1));
    expect(controller.isLoading.value, isFalse);
  });

  test('the active count ignores deactivated fences', () async {
    repository.fences = [
      testFence(geofenceId: 'a'),
      testFence(geofenceId: 'b', activeTo: DateTime.utc(2026, 6)),
    ];
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.fences, hasLength(2), reason: 'both are still listed');
    expect(controller.activeCount, 1);
  });

  // A new fence is active from now, which is why it has no back-history: we
  // will not claim a truck was inside a fence that did not exist.
  test('a blank fence starts active from the injected clock', () {
    final controller = putStubGeofences(repository);

    final fence = controller.blank();

    expect(fence.activeFrom, fakeNow);
    expect(fence.isActive, isTrue);
    expect(fence.name, isEmpty);
    expect(fence.geofenceId, isNotEmpty);
  });

  test('saving passes the fence through and reloads', () async {
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);

    final ok = await controller.save(testFence(name: 'New Pad').fence);

    expect(ok, isTrue);
    expect(repository.saved.single.name, 'New Pad');
    expect(controller.isSaving.value, isFalse);
  });

  // A fence edit rewrites every transition in the database, so every screen
  // reading containment is stale, not just this one.
  test('saving pulses the database so the vehicle screens follow', () async {
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);
    final before = pulse.revision.value;

    await controller.save(testFence().fence);

    expect(pulse.revision.value, greaterThan(before));
  });

  test('the active toggle reaches the repository', () async {
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);

    await controller.setActive('gf1', active: false);

    expect(repository.toggled, [('gf1', false)]);
  });

  test('a failed save surfaces and clears the progress flag', () async {
    final controller = putStubGeofences(repository);
    await Future<void>.delayed(Duration.zero);
    repository.failWith = 'disk is full';

    final ok = await controller.save(testFence().fence);

    expect(ok, isFalse);
    expect(controller.error.value, 'disk is full');
    expect(controller.isSaving.value, isFalse);
  });
}
