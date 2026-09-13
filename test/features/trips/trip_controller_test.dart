import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'trip_doubles.dart';

void main() {
  tearDown(Get.reset);

  test('loads on init and counts the running legs', () async {
    final repository = StubTripRepository([
      testTrip(tripId: 'a', running: true),
      testTrip(tripId: 'b'),
    ]);
    final controller = putStubTrips(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.trips, hasLength(2));
    expect(controller.runningCount, 1);
    expect(controller.isLoading.value, isFalse);
  });

  // Every row on screen has to agree about how long a running trip has been
  // running, which it only does if they all measure from one instant.
  test('stamps the instant the durations were measured against', () async {
    final controller = putStubTrips(StubTripRepository([testTrip()]));
    await Future<void>.delayed(Duration.zero);

    expect(controller.evaluatedAt.value, fakeNow);
  });

  test('a database failure surfaces instead of an empty list', () async {
    final repository = StubTripRepository()..failWith = 'disk on fire';
    final controller = putStubTrips(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.error.value, 'disk on fire');
    expect(controller.isLoading.value, isFalse);
  });

  // Trips are re-derived inside the ingest transaction, so a commit is the
  // only thing that can change this list.
  test('a database commit re-reads the list', () async {
    final repository = StubTripRepository();
    putStubTrips(repository);
    await Future<void>.delayed(Duration.zero);
    final before = repository.loads;

    Get.find<DatabasePulse>().ping();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(repository.loads, greaterThan(before));
  });
}
