import 'package:byte_beam_project/features/alerts/domain/entities/fleet_alert.dart';
import 'package:byte_beam_project/features/alerts/presentation/pages/alerts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'alert_doubles.dart';

final now = DateTime.utc(2026, 1, 1, 12);

void main() {
  late StubAlertRepository repository;

  setUp(() => repository = StubAlertRepository());
  tearDown(Get.reset);

  Future<void> open(WidgetTester tester) async {
    putStubAlerts(repository);
    await tester.pumpWidget(const GetMaterialApp(home: AlertsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty list reads as good news, not as a blank screen', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Nothing needs attention'), findsOneWidget);
  });

  testWidgets('a card names the fault, the truck and the reading', (
    tester,
  ) async {
    repository.alerts = [testAlert(severity: AlertSeverity.critical, value: 8)];
    await open(tester);

    expect(find.text('Low battery'), findsOneWidget);
    expect(find.text('CRITICAL'), findsOneWidget);
    expect(find.textContaining('KA01AA0001'), findsOneWidget);
    expect(find.textContaining('8.0%'), findsOneWidget);
  });

  testWidgets('an eased-off alert says it was critical', (tester) async {
    repository.alerts = [
      testAlert(
        raisedAt: now.subtract(const Duration(minutes: 30)),
        escalatedAt: now.subtract(const Duration(minutes: 10)),
      ),
    ];
    await open(tester);

    expect(find.textContaining('eased off'), findsOneWidget);
  });

  // The episode stays open when its signal goes quiet, so the card has to
  // carry the caveat the readings register would.
  testWidgets('an alert whose signal has gone quiet says so', (tester) async {
    repository.alerts = [
      testAlert(readingAt: now.subtract(const Duration(minutes: 20))),
    ];
    await open(tester);

    expect(find.textContaining('no fresh reading for 20m'), findsOneWidget);
    expect(find.textContaining('last known 18.0%'), findsOneWidget);
  });

  testWidgets('dismiss opens the sheet with the three reasons in order', (
    tester,
  ) async {
    repository.alerts = [testAlert()];
    await open(tester);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    final labels = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(labels, ['I am on it', 'Wrong alert', 'Something else…']);
  });

  testWidgets('picking a reason removes the alert and offers UNDO', (
    tester,
  ) async {
    repository.alerts = [testAlert()];
    await open(tester);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I am on it'));
    await tester.pumpAndSettle();

    expect(repository.dismissals, ['on_it']);
    expect(find.text('Low battery'), findsNothing);
    expect(find.text('UNDO'), findsOneWidget);
  });

  // Five seconds is from the brief. The row is already on disk, so this is the
  // window in which the user can change their mind, not a window in which the
  // write is still pending.
  testWidgets('the UNDO offer lasts five seconds', (tester) async {
    repository.alerts = [testAlert()];
    await open(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I am on it'));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('UNDO'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('UNDO'), findsNothing);
  });

  testWidgets('UNDO restores the alert', (tester) async {
    repository.alerts = [testAlert()];
    await open(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I am on it'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('UNDO'));
    await tester.pumpAndSettle();

    expect(repository.restored, ['a1']);
  });

  testWidgets('"Something else…" asks what, and cancelling cancels all of it', (
    tester,
  ) async {
    repository.alerts = [testAlert()];
    await open(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Something else…'));
    await tester.pumpAndSettle();
    expect(find.text('What is going on?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      repository.dismissals,
      isEmpty,
      reason: 'backing out of the note is backing out of the dismissal',
    );
    expect(find.text('Low battery'), findsOneWidget);
  });

  testWidgets('a note typed there is stored with the reason', (tester) async {
    repository.alerts = [testAlert()];
    await open(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else…'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'charger is broken');
    await tester.tap(find.widgetWithText(FilledButton, 'Dismiss'));
    await tester.pumpAndSettle();

    expect(repository.dismissals, ['other: charger is broken']);
  });

  testWidgets('a failed dismissal offers no UNDO', (tester) async {
    repository.alerts = [testAlert()];
    await open(tester);
    repository.failWith = 'disk is full';

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I am on it'));
    await tester.pumpAndSettle();

    expect(find.text('UNDO'), findsNothing);
  });
}
