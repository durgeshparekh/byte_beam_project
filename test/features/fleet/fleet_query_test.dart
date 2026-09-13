import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/fleet/data/datasources/fleet_local_data_source.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_filter.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/fleet_vehicle_summary.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

/// The instant every freshness rule is evaluated against.
final now = DateTime.utc(2026, 1, 1, 12);

/// A timestamp [minutes] before [now].
DateTime ago(num minutes) =>
    now.subtract(Duration(seconds: (minutes * 60).round()));

void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbFleetLocalDataSource source;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    source = DuckDbFleetLocalDataSource(db.read);
  });
  tearDown(() => db.close());

  /// Registers a vehicle with a set of latest readings.
  ///
  /// Writes `vehicle_signal_latest` directly: this is a test of the fleet
  /// query, and routing through ingest would only add ways for it to fail for
  /// reasons that are not the query's fault.
  Future<void> vehicle(
    String id, {
    String regNo = 'KA01AA0001',
    Map<String, (double value, DateTime ts)> signals = const {},
    DateTime? locationAt,
  }) async {
    await db.read.execute(
      "INSERT INTO vehicle VALUES ('$id', '$regNo', 'eT 1000')",
    );
    for (final entry in signals.entries) {
      final (value, ts) = entry.value;
      await db.read.execute(
        "INSERT INTO vehicle_signal_latest VALUES "
        "('$id', '${entry.key}', TIMESTAMP '${ts.toIso8601String()}', $value)",
      );
    }
    if (locationAt != null) {
      await db.read.execute(
        "INSERT INTO location_fix VALUES ('$id', "
        "TIMESTAMP '${locationAt.toIso8601String()}', 12.9, 77.5, 5, now())",
      );
    }
  }

  Future<FleetVehicleSummary> only(FleetFilter filter) async {
    final overview = await source.overview(filter, now);
    expect(overview.vehicles, hasLength(1));
    return overview.vehicles.single;
  }

  group('status ladder', () {
    test('fresh speed above zero is MOVING', () async {
      await vehicle(
        'v1',
        signals: {'speed': (42, ago(1)), 'ignition': (1, ago(1))},
      );

      expect((await only(FleetFilter.all)).status, VehicleStatus.moving);
    });

    test('fresh zero speed with fresh ignition on is IDLE', () async {
      await vehicle(
        'v1',
        signals: {'speed': (0, ago(1)), 'ignition': (1, ago(1))},
      );

      expect((await only(FleetFilter.all)).status, VehicleStatus.idle);
    });

    test('ignition off is STOPPED', () async {
      await vehicle(
        'v1',
        signals: {'speed': (0, ago(1)), 'ignition': (0, ago(1))},
      );

      expect((await only(FleetFilter.all)).status, VehicleStatus.stopped);
    });

    test(
      'no report for over 10 minutes is OFFLINE, outranking speed',
      () async {
        await vehicle(
          'v1',
          signals: {'speed': (60, ago(11)), 'ignition': (1, ago(11))},
        );

        expect((await only(FleetFilter.all)).status, VehicleStatus.offline);
      },
    );

    test('nine minutes of silence is not yet offline', () async {
      await vehicle('v1', signals: {'speed': (60, ago(9))});

      expect((await only(FleetFilter.all)).status, VehicleStatus.moving);
    });

    // The status ladder scores freshness against the 10-minute OFFLINE window,
    // not the 5-minute per-signal one. Otherwise a truck reporting every six
    // minutes would read STOPPED while visibly driving.
    test('a six-minute-old speed still claims MOVING', () async {
      await vehicle('v1', signals: {'speed': (48, ago(6))});

      expect((await only(FleetFilter.all)).status, VehicleStatus.moving);
    });

    // ARCHITECTURE.md §10, ambiguity 1.
    test('a stale speed on an online vehicle cannot claim MOVING', () async {
      await vehicle(
        'v1',
        signals: {
          'speed': (55, ago(40)), // stale: max_age for speed is 300s
          'odometer': (91000, ago(2)), // fresh, so the vehicle is not offline
        },
      );

      final summary = await only(FleetFilter.all);
      expect(
        summary.status,
        VehicleStatus.stopped,
        reason: 'STOPPED is the documented fallback, not MOVING',
      );
      expect(
        summary.speed,
        55,
        reason: 'the value is still shown, just not trusted',
      );
    });

    test('a stale ignition cannot claim IDLE', () async {
      await vehicle(
        'v1',
        signals: {'speed': (0, ago(1)), 'ignition': (1, ago(40))},
      );

      expect((await only(FleetFilter.all)).status, VehicleStatus.stopped);
    });

    test('a position report alone keeps a vehicle online', () async {
      await vehicle(
        'v1',
        signals: {'speed': (0, ago(30)), 'ignition': (0, ago(30))},
        locationAt: ago(2),
      );

      final summary = await only(FleetFilter.all);
      expect(
        summary.status,
        VehicleStatus.stopped,
        reason: 'online, ignition off',
      );
      expect(summary.lastPing, ago(2));
    });

    test(
      'a vehicle that has never reported is OFFLINE with no values',
      () async {
        await vehicle('v1');

        final summary = await only(FleetFilter.all);
        expect(summary.status, VehicleStatus.offline);
        expect(summary.hasNeverReported, isTrue);
        expect(summary.soc, isNull);
        expect(summary.rangeKm, isNull);
      },
    );
  });

  group('alert badge', () {
    /// Opens an alert row directly.
    ///
    /// Whether a reading *should* raise one is the evaluator's business and is
    /// tested in `alert_evaluator_test`. This group asks a narrower question:
    /// given a row in the alert table, what does the fleet list show? The
    /// badge used to recompute thresholds itself, which meant a dismissed
    /// alert kept its red dot on this screen.
    Future<void> alert(
      String id, {
      String type = 'battery_low',
      String severity = 'warning',
      bool dismissed = false,
      bool resolved = false,
    }) {
      final ts = "TIMESTAMP '${ago(2).toIso8601String()}'";
      final dismissedAt = dismissed ? ts : 'NULL';
      final resolvedAt = resolved ? ts : 'NULL';
      return db.read.execute(
        'INSERT INTO alert (alert_id, vehicle_id, alert_type, severity, '
        'raised_at, resolved_at, dismissed_at) VALUES '
        "('$id', 'v1', '$type', '$severity', $ts, $resolvedAt, $dismissedAt)",
      );
    }

    setUp(() => vehicle('v1', signals: {'speed': (0, ago(1))}));

    test('an open warning shows a warning badge', () async {
      await alert('a1');
      expect(
        (await only(FleetFilter.all)).alertSeverity,
        AlertSeverity.warning,
      );
    });

    test('an open critical shows a critical badge', () async {
      await alert('a1', severity: 'critical');
      expect(
        (await only(FleetFilter.all)).alertSeverity,
        AlertSeverity.critical,
      );
    });

    test('critical outranks warning on the same vehicle', () async {
      await alert('a1');
      await alert('a2', type: 'battery_overheat', severity: 'critical');
      expect(
        (await only(FleetFilter.all)).alertSeverity,
        AlertSeverity.critical,
      );
    });

    test('no alerts, no badge', () async {
      expect((await only(FleetFilter.all)).alertSeverity, isNull);
    });

    // The reason the badge reads this table instead of recomputing thresholds.
    test('a dismissed alert takes its badge with it', () async {
      await alert('a1', dismissed: true);
      expect((await only(FleetFilter.all)).alertSeverity, isNull);
    });

    test('a resolved alert leaves no badge behind', () async {
      await alert('a1', resolved: true);
      expect((await only(FleetFilter.all)).alertSeverity, isNull);
    });
  });

  group('chips', () {
    setUp(() async {
      await vehicle(
        'v1',
        regNo: 'KA01AA0001',
        signals: {'speed': (42, ago(1)), 'ignition': (1, ago(1))},
      );
      await vehicle(
        'v2',
        regNo: 'KA01BB0002',
        signals: {'speed': (0, ago(1)), 'ignition': (1, ago(1))},
      );
      await vehicle(
        'v3',
        regNo: 'KA01CC0003',
        signals: {'speed': (0, ago(1)), 'ignition': (0, ago(1))},
      );
      await vehicle(
        'v4',
        regNo: 'KA01DD0004',
        signals: {'speed': (9, ago(30))},
      );
      await vehicle(
        'v5',
        regNo: 'KA01EE0005',
        signals: {'speed': (17, ago(1)), 'ignition': (1, ago(1))},
      );
    });

    test('counts cover the whole fleet and add up', () async {
      final overview = await source.overview(FleetFilter.all, now);

      expect(overview.countFor(FleetFilter.all), 5);
      expect(overview.countFor(FleetFilter.moving), 2);
      expect(overview.countFor(FleetFilter.idle), 1);
      expect(overview.countFor(FleetFilter.stopped), 1);
      expect(overview.countFor(FleetFilter.offline), 1);
    });

    test('a filter narrows the rows but not the counts', () async {
      final overview = await source.overview(FleetFilter.moving, now);

      expect(overview.vehicles.map((v) => v.vehicleId), ['v1', 'v5']);
      expect(
        overview.countFor(FleetFilter.all),
        5,
        reason: 'chips must not count only what is on screen',
      );
    });

    test('rows come back ordered by registration', () async {
      final overview = await source.overview(FleetFilter.all, now);

      final regNos = overview.vehicles.map((v) => v.regNo).toList();
      expect(regNos, List.of(regNos)..sort());
    });

    test('a filter matching nothing is a filtered-empty result', () async {
      await db.read.execute(
        "DELETE FROM vehicle_signal_latest WHERE vehicle_id = 'v1'",
      );
      await db.read.execute(
        "DELETE FROM vehicle_signal_latest WHERE vehicle_id = 'v5'",
      );
      final overview = await source.overview(FleetFilter.moving, now);

      expect(overview.vehicles, isEmpty);
      expect(overview.isFilteredEmpty, isTrue);
      expect(overview.isFleetEmpty, isFalse);
    });

    test('an empty fleet is distinguishable from an empty filter', () async {
      await db.read.execute('DELETE FROM vehicle');
      final overview = await source.overview(FleetFilter.all, now);

      expect(overview.isFleetEmpty, isTrue);
      expect(overview.isFilteredEmpty, isFalse);
    });
  });
}
