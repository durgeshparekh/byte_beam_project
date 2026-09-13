import 'package:byte_beam_project/features/geofence/presentation/pages/geofence_editor_page.dart';
import 'package:byte_beam_project/features/geofence/presentation/pages/geofences_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'geofence_doubles.dart';

void main() {
  late StubGeofenceRepository repository;

  setUp(() => repository = StubGeofenceRepository());
  tearDown(Get.reset);

  Future<void> open(WidgetTester tester) async {
    putStubGeofences(repository);
    await tester.pumpWidget(const GetMaterialApp(home: GeofencesPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('a fence shows its size, centre and live count', (tester) async {
    repository.fences = [testFence(vehiclesInside: 3)];
    await open(tester);

    expect(find.text('Whitefield Depot'), findsOneWidget);
    expect(find.textContaining('2.5 km'), findsOneWidget);
    expect(find.textContaining('12.9700, 77.6000'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  // An empty depot does not need a zero shouted at it.
  testWidgets('an empty fence says so rather than showing a zero', (
    tester,
  ) async {
    repository.fences = [testFence()];
    await open(tester);

    expect(find.text('empty'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  // Retained for trip history, so they stay on the list rather than vanishing.
  testWidgets('a deactivated fence is still listed, marked off', (
    tester,
  ) async {
    repository.fences = [testFence(activeTo: DateTime.utc(2026, 6))];
    await open(tester);

    expect(find.text('Whitefield Depot'), findsOneWidget);
    expect(find.text('off'), findsOneWidget);
  });

  testWidgets('deactivating asks first and can be cancelled', (tester) async {
    repository.fences = [testFence()];
    await open(tester);

    await tester.tap(find.byTooltip('Deactivate'));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate Whitefield Depot?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repository.toggled, isEmpty);
  });

  testWidgets('confirming the dialog deactivates it', (tester) async {
    repository.fences = [testFence()];
    await open(tester);

    await tester.tap(find.byTooltip('Deactivate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect(repository.toggled, [('gf1', false)]);
  });

  // Reactivating is not destructive, so it does not interrogate the user.
  testWidgets('reactivating does not ask', (tester) async {
    repository.fences = [testFence(activeTo: DateTime.utc(2026, 6))];
    await open(tester);

    await tester.tap(find.byTooltip('Reactivate'));
    await tester.pumpAndSettle();

    expect(repository.toggled, [('gf1', true)]);
  });

  testWidgets('the new button opens a blank editor', (tester) async {
    await open(tester);

    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    expect(find.text('New geofence'), findsOneWidget);
  });

  testWidgets('tapping a fence opens it for editing', (tester) async {
    repository.fences = [testFence()];
    await open(tester);

    await tester.tap(find.text('Whitefield Depot'));
    await tester.pumpAndSettle();

    expect(find.text('Edit geofence'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Whitefield Depot'),
      findsOneWidget,
    );
  });

  testWidgets('the editor refuses a fence with no name', (tester) async {
    await open(tester);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Give it a name'), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  // Clamping a mistyped longitude to 180 would put a depot in the Pacific and
  // say nothing about it.
  testWidgets('the editor refuses an out-of-range coordinate', (tester) async {
    await open(tester);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Somewhere',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Latitude'),
      '412.0',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Must be between'), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  testWidgets('a valid new fence is saved and confirmed', (tester) async {
    await open(tester);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Yelahanka Pad',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Radius (metres)'),
      '750',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repository.saved.single.name, 'Yelahanka Pad');
    expect(repository.saved.single.radiusM, 750);
    expect(find.text('Yelahanka Pad saved'), findsOneWidget);
  });

  testWidgets('editing keeps the fence id', (tester) async {
    repository.fences = [testFence()];
    await open(tester);
    await tester.tap(find.text('Whitefield Depot'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Whitefield Yard',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repository.saved.single.geofenceId, 'gf1');
    expect(repository.saved.single.name, 'Whitefield Yard');
  });

  testWidgets('the editor warns that a save re-derives history', (
    tester,
  ) async {
    repository.fences = [testFence()];
    await open(tester);
    await tester.tap(find.text('Whitefield Depot'));
    await tester.pumpAndSettle();

    expect(find.textContaining('re-derives every crossing'), findsOneWidget);
  });

  testWidgets('the editor page is never asked to save anything itself', (
    tester,
  ) async {
    repository.fences = [testFence()];
    await open(tester);
    await tester.tap(find.text('Whitefield Depot'));
    await tester.pumpAndSettle();

    // Backing out returns null, and nothing is written.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(repository.saved, isEmpty);
    expect(find.byType(GeofenceEditorPage), findsNothing);
  });
}
