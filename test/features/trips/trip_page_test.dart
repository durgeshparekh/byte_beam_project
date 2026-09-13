import 'package:byte_beam_project/features/trips/presentation/pages/trips_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'trip_doubles.dart';

void main() {
  tearDown(Get.reset);

  Future<void> pump(WidgetTester tester, StubTripRepository repository) async {
    putStubTrips(repository);
    await tester.pumpWidget(const GetMaterialApp(home: TripsPage()));
    await tester.pumpAndSettle();
  }

  // A fresh database has no trips because nothing has left a fence yet, which
  // is worth saying rather than leaving a blank screen to imply a bug.
  testWidgets('an empty list explains what would make a trip', (tester) async {
    await pump(tester, StubTripRepository());

    expect(find.textContaining('leaves the last geofence'), findsOneWidget);
  });

  testWidgets('a completed leg names both ends and its distance', (
    tester,
  ) async {
    await pump(tester, StubTripRepository([testTrip()]));

    expect(find.text('Whitefield Depot → Electronic City Hub'), findsOneWidget);
    expect(find.textContaining('42.5 km'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
  });

  // An open trip is the only row here anyone can still act on.
  testWidgets('a running leg says so instead of naming a destination', (
    tester,
  ) async {
    await pump(tester, StubTripRepository([testTrip(running: true)]));

    expect(find.text('Whitefield Depot → under way'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('1 running'), findsOneWidget);
  });

  // "We do not know" and "it did not move" are different answers.
  testWidgets('a missing odometer says so rather than showing 0 km', (
    tester,
  ) async {
    await pump(tester, StubTripRepository([testTrip(distanceKm: null)]));

    expect(find.textContaining('distance unknown'), findsOneWidget);
  });

  testWidgets('a leg confirmed across a gap is flagged', (tester) async {
    await pump(tester, StubTripRepository([testTrip(isConfident: false)]));

    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });
}
