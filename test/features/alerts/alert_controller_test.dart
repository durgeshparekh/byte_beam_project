import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/features/alerts/domain/entities/fleet_alert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'alert_doubles.dart';

void main() {
  late StubAlertRepository repository;
  late DatabasePulse pulse;

  setUp(() {
    repository = StubAlertRepository();
    pulse = Get.put(DatabasePulse());
  });
  tearDown(Get.reset);

  test('it loads the open alerts on init', () async {
    repository.alerts = [testAlert()];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.alerts, hasLength(1));
    expect(controller.isLoading.value, isFalse);
  });

  test('the badge counts alerts, not vehicles', () async {
    repository.alerts = [
      testAlert(alertId: 'a1'),
      testAlert(alertId: 'a2', type: AlertType.batteryOverheat),
    ];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.openCount, 2, reason: 'one truck, two things wrong');
    expect(controller.hasCritical, isFalse);
  });

  test('one critical alert colours the whole badge', () async {
    repository.alerts = [
      testAlert(alertId: 'a1'),
      testAlert(alertId: 'a2', severity: AlertSeverity.critical),
    ];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.hasCritical, isTrue);
  });

  test('forVehicle narrows to one truck', () async {
    repository.alerts = [
      testAlert(alertId: 'a1', vehicleId: 'v1'),
      testAlert(alertId: 'a2', vehicleId: 'v2'),
    ];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    expect(controller.forVehicle('v1').map((a) => a.alertId), ['a1']);
    expect(controller.forVehicle('v9'), isEmpty);
  });

  test('dismissing writes the reason and drops it from the list', () async {
    repository.alerts = [testAlert()];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    final ok = await controller.dismiss(
      controller.alerts.single,
      DismissReason.wrongAlert,
    );

    expect(ok, isTrue);
    expect(repository.dismissals, ['wrong_alert']);
    expect(controller.alerts, isEmpty);
  });

  test('a free-text note rides along with the code', () async {
    repository.alerts = [testAlert()];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    await controller.dismiss(
      controller.alerts.single,
      DismissReason.somethingElse,
      note: 'depot has no charger',
    );

    expect(repository.dismissals, ['other: depot has no charger']);
  });

  // The fleet badge listens to the pulse, so a dismissal has to ring it or the
  // list and the badge disagree until the next packet arrives.
  test('a dismissal pulses the database so other screens follow', () async {
    repository.alerts = [testAlert()];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);
    final before = pulse.revision.value;

    await controller.dismiss(controller.alerts.single, DismissReason.onIt);

    expect(pulse.revision.value, greaterThan(before));
  });

  test('undo asks the repository to restore that alert', () async {
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);

    expect(await controller.undo('a1'), isTrue);
    expect(repository.restored, ['a1']);
  });

  test('a failed dismissal surfaces and changes nothing', () async {
    repository.alerts = [testAlert()];
    final controller = putStubAlerts(repository);
    await Future<void>.delayed(Duration.zero);
    repository.failWith = 'disk is full';

    final ok = await controller.dismiss(
      controller.alerts.single,
      DismissReason.onIt,
    );

    expect(ok, isFalse, reason: 'the caller must not offer UNDO');
    expect(controller.error.value, 'disk is full');
    expect(controller.alerts, hasLength(1));
  });

  // The order is from the brief, and the sheet reads it straight off the enum.
  test('the dismissal reasons are offered in the specified order', () {
    expect(DismissReason.values.map((r) => r.label), [
      'I am on it',
      'Wrong alert',
      'Something else…',
    ]);
  });
}
