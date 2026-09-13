import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/core/utils/result.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_filter.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_overview.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_vehicle_summary.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/fleet/domain/repositories/fleet_repository.dart';
import 'package:byte_beam_project/features/fleet/domain/usecases/get_fleet_overview.dart';
import 'package:byte_beam_project/features/fleet/presentation/controllers/fleet_controller.dart';
import 'package:byte_beam_project/features/fleet/presentation/pages/fleet_page.dart';
import 'package:byte_beam_project/features/fleet/presentation/widgets/fleet_empty_state.dart';
import 'package:byte_beam_project/features/fleet/presentation/widgets/status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// Serves one canned overview, whatever is asked for.
class StubFleetRepository implements FleetRepository {
  StubFleetRepository(this.result);

  FleetOverview result;

  @override
  Future<Result<FleetOverview>> overview(
    FleetFilter filter,
    DateTime now,
  ) async => Ok(result);
}

FleetVehicleSummary summary(
  String regNo,
  VehicleStatus status, {
  double? soc,
  AlertSeverity? alert,
}) {
  return FleetVehicleSummary(
    vehicleId: regNo,
    regNo: regNo,
    model: 'eT 1000',
    status: status,
    soc: soc,
    rangeKm: soc == null ? null : soc * 3.2,
    alertSeverity: alert,
  );
}

void main() {
  tearDown(Get.reset);

  /// Mounts the page with [overview] already loaded.
  Future<void> pump(WidgetTester tester, FleetOverview overview) async {
    Get.put(
      FleetController(
        getFleetOverview: GetFleetOverview(StubFleetRepository(overview)),
        pulse: DatabasePulse(),
        clock: FakeClock(DateTime.utc(2026)),
      ),
    );
    await tester.pumpWidget(const GetMaterialApp(home: FleetPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('rows show registration, battery, range and a status chip', (
    tester,
  ) async {
    await pump(
      tester,
      FleetOverview(
        filter: FleetFilter.all,
        vehicles: [summary('KA01AA0001', VehicleStatus.moving, soc: 62)],
        counts: const {FleetFilter.all: 1, FleetFilter.moving: 1},
      ),
    );

    expect(find.text('KA01AA0001'), findsOneWidget);
    expect(find.textContaining('SOC 62%'), findsOneWidget);
    expect(find.textContaining('198 km'), findsOneWidget);
    expect(find.widgetWithText(StatusChip, 'Moving'), findsOneWidget);
  });

  testWidgets('a vehicle that never reported shows dashes, not zeroes', (
    tester,
  ) async {
    await pump(
      tester,
      FleetOverview(
        filter: FleetFilter.all,
        vehicles: [summary('KA01ZZ9999', VehicleStatus.offline)],
        counts: const {FleetFilter.all: 1, FleetFilter.offline: 1},
      ),
    );

    expect(find.textContaining('SOC —'), findsOneWidget);
    expect(find.textContaining('Range —'), findsOneWidget);
  });

  testWidgets('every chip renders with its count', (tester) async {
    await pump(
      tester,
      FleetOverview(
        filter: FleetFilter.all,
        vehicles: [summary('KA01AA0001', VehicleStatus.idle)],
        counts: const {
          FleetFilter.all: 12,
          FleetFilter.moving: 5,
          FleetFilter.idle: 3,
          FleetFilter.stopped: 2,
          FleetFilter.offline: 2,
        },
      ),
    );

    expect(find.text('All  12'), findsOneWidget);
    expect(find.text('Moving  5'), findsOneWidget);
    expect(find.text('Idle  3'), findsOneWidget);
    expect(find.text('Stopped  2'), findsOneWidget);
    expect(find.text('Offline  2'), findsOneWidget);
  });

  testWidgets('a critical vehicle shows an alert badge', (tester) async {
    await pump(
      tester,
      FleetOverview(
        filter: FleetFilter.all,
        vehicles: [
          summary(
            'KA01AA0001',
            VehicleStatus.moving,
            soc: 6,
            alert: AlertSeverity.critical,
          ),
        ],
        counts: const {FleetFilter.all: 1, FleetFilter.moving: 1},
      ),
    );

    expect(find.byIcon(Icons.error), findsOneWidget);
  });

  testWidgets('an empty filter explains itself', (tester) async {
    await pump(
      tester,
      const FleetOverview(
        filter: FleetFilter.moving,
        vehicles: [],
        counts: {FleetFilter.all: 9, FleetFilter.moving: 0},
      ),
    );

    expect(find.byType(FleetEmptyState), findsOneWidget);
    expect(find.textContaining('No vehicles are moving'), findsOneWidget);
  });

  testWidgets('an empty fleet says something different', (tester) async {
    await pump(
      tester,
      const FleetOverview(
        filter: FleetFilter.all,
        vehicles: [],
        counts: {FleetFilter.all: 0},
      ),
    );

    expect(find.text('No vehicles yet'), findsOneWidget);
  });

  testWidgets('tapping a chip switches the filter', (tester) async {
    await pump(
      tester,
      FleetOverview(
        filter: FleetFilter.all,
        vehicles: [summary('KA01AA0001', VehicleStatus.moving)],
        counts: const {FleetFilter.all: 1, FleetFilter.offline: 0},
      ),
    );

    await tester.tap(find.text('Offline  0'));
    await tester.pumpAndSettle();

    expect(Get.find<FleetController>().filter.value, FleetFilter.offline);
  });
}
