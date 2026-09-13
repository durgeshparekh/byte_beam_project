import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/fleet/presentation/widgets/status_chip.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/reading_verdict.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/signal_reading_row.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/soc_history.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/vehicle_detail.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/repositories/vehicle_detail_repository.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/usecases/get_vehicle_detail.dart';
import 'package:byte_beam_project/features/vehicle_detail/presentation/controllers/vehicle_detail_controller.dart';
import 'package:byte_beam_project/features/vehicle_detail/presentation/pages/vehicle_detail_page.dart';
import 'package:byte_beam_project/features/vehicle_detail/presentation/widgets/verdict_pill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

final now = DateTime.utc(2026, 1, 1, 12);

/// Serves one canned detail.
class StubRepository implements VehicleDetailRepository {
  StubRepository(this.value);

  VehicleDetail? value;

  @override
  Future<Result<VehicleDetail?>> detail(String vehicleId, DateTime at) async =>
      Ok(value);
}

SignalReadingRow reading(
  String signal,
  String label, {
  String unit = '',
  double? value,
  Duration? age,
  ReadingVerdict? verdict,
  Duration maxAge = const Duration(minutes: 5),
}) {
  return SignalReadingRow(
    signal: signal,
    label: label,
    unit: unit,
    maxAge: maxAge,
    value: value,
    eventTs: age == null ? null : now.subtract(age),
    verdict: verdict,
  );
}

VehicleDetail detailWith({
  List<SignalReadingRow> readings = const [],
  SocHistory history = const SocHistory.empty(),
}) {
  return VehicleDetail(
    vehicleId: 'v1',
    regNo: 'KA01AB1234',
    model: 'eT 1000',
    status: VehicleStatus.idle,
    readings: readings,
    history: history,
    lastPing: now.subtract(const Duration(minutes: 2)),
  );
}

void main() {
  tearDown(Get.reset);

  Future<void> pump(WidgetTester tester, VehicleDetail? value) async {
    Get.put(
      VehicleDetailController(
        getVehicleDetail: GetVehicleDetail(StubRepository(value)),
        pulse: DatabasePulse(),
        clock: FakeClock(now),
      ),
    );
    await tester.pumpWidget(
      const GetMaterialApp(home: VehicleDetailPage(vehicleId: 'v1')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the header shows registration, model, status and last ping', (
    tester,
  ) async {
    await pump(tester, detailWith());

    expect(find.text('KA01AB1234'), findsOneWidget);
    expect(find.text('eT 1000'), findsOneWidget);
    expect(find.widgetWithText(StatusChip, 'Idle'), findsOneWidget);
    expect(find.text('Last ping 2m ago'), findsOneWidget);
  });

  testWidgets('a fresh in-range reading shows value, age and NORMAL', (
    tester,
  ) async {
    await pump(
      tester,
      detailWith(
        readings: [
          reading(
            'soc',
            'State of charge',
            unit: '%',
            value: 62,
            age: const Duration(seconds: 30),
            verdict: ReadingVerdict.normal,
          ),
        ],
      ),
    );

    expect(find.text('State of charge'), findsOneWidget);
    expect(find.text('62.0 %'), findsOneWidget);
    expect(find.textContaining('30s ago'), findsOneWidget);
    expect(find.widgetWithText(VerdictPill, 'NORMAL'), findsOneWidget);
  });

  testWidgets('an out-of-range fresh reading shows ALERT', (tester) async {
    await pump(
      tester,
      detailWith(
        readings: [
          reading(
            'soc',
            'State of charge',
            unit: '%',
            value: 8,
            age: const Duration(minutes: 1),
            verdict: ReadingVerdict.alert,
          ),
        ],
      ),
    );

    expect(find.widgetWithText(VerdictPill, 'ALERT'), findsOneWidget);
  });

  testWidgets('a too-old reading shows STALE and still shows its value', (
    tester,
  ) async {
    await pump(
      tester,
      detailWith(
        readings: [
          reading(
            'battery_temp',
            'Battery temperature',
            unit: 'C',
            value: 51,
            age: const Duration(minutes: 40),
            verdict: ReadingVerdict.stale,
          ),
        ],
      ),
    );

    expect(find.widgetWithText(VerdictPill, 'STALE'), findsOneWidget);
    expect(find.text('51.0 C'), findsOneWidget);
    expect(
      find.widgetWithText(VerdictPill, 'ALERT'),
      findsNothing,
      reason: 'a stale reading makes no normal-or-alert claim',
    );
  });

  testWidgets('a signal that never reported shows a dash and no pill', (
    tester,
  ) async {
    await pump(
      tester,
      detailWith(readings: [reading('odometer', 'Odometer', unit: 'km')]),
    );

    expect(find.text('—'), findsOneWidget);
    expect(find.text('never reported'), findsOneWidget);
    expect(find.byType(VerdictPill), findsOneWidget);
    expect(
      tester.widget<VerdictPill>(find.byType(VerdictPill)).verdict,
      isNull,
      reason: 'the pill widget renders nothing when there is no verdict',
    );
  });

  testWidgets('ignition reads On or Off, not 1.0', (tester) async {
    await pump(
      tester,
      detailWith(
        readings: [
          reading(
            'ignition',
            'Ignition',
            value: 1,
            age: const Duration(seconds: 10),
            verdict: ReadingVerdict.normal,
          ),
        ],
      ),
    );

    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('the history says how many log rows it came from', (
    tester,
  ) async {
    await pump(
      tester,
      detailWith(
        history: SocHistory(
          points: [
            SocPoint(at: now.subtract(const Duration(hours: 2)), value: 80),
            SocPoint(at: now.subtract(const Duration(hours: 1)), value: 64),
            SocPoint(at: now, value: 51),
          ],
          readingCount: 1240,
          from: now.subtract(const Duration(hours: 2)),
          to: now,
        ),
      ),
    );

    expect(find.text('1240 readings · 3 points · 51–80%'), findsOneWidget);
  });

  testWidgets('an empty history says so instead of drawing nothing', (
    tester,
  ) async {
    await pump(tester, detailWith());

    expect(find.textContaining('No battery readings'), findsOneWidget);
  });

  testWidgets('an unknown vehicle gets a not-found message', (tester) async {
    await pump(tester, null);

    expect(find.text('No such vehicle in the roster.'), findsOneWidget);
  });
}
