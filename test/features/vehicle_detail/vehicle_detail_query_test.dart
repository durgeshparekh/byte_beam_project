import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/fleet/domain/entities/vehicle_status.dart';
import 'package:byte_beam_project/features/vehicle_detail/data/datasources/vehicle_detail_local_data_source.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/reading_verdict.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/signal_reading_row.dart';
import 'package:byte_beam_project/features/vehicle_detail/domain/entities/vehicle_detail.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final now = DateTime.utc(2026, 1, 1, 12);
DateTime ago(num minutes) =>
    now.subtract(Duration(seconds: (minutes * 60).round()));

void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbVehicleDetailLocalDataSource source;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    source = DuckDbVehicleDetailLocalDataSource(db.read);
    await db.read.execute(
      "INSERT INTO vehicle VALUES ('v1', 'KA01AB1234', 'eT 1000')",
    );
  });
  tearDown(() => db.close());

  /// Sets the latest value for one signal.
  Future<void> latest(String signal, double value, DateTime ts) =>
      db.read.execute(
        "INSERT INTO vehicle_signal_latest VALUES "
        "('v1', '$signal', TIMESTAMP '${ts.toIso8601String()}', $value)",
      );

  /// Appends a raw reading to the event log.
  Future<void> logged(String signal, double value, DateTime ts) =>
      db.read.execute(
        "INSERT INTO signal_reading VALUES "
        "('v1', '$signal', TIMESTAMP '${ts.toIso8601String()}', $value, now())",
      );

  Future<VehicleDetail> load() async {
    final detail = await source.detail('v1', now);
    expect(detail, isNotNull);
    return detail!;
  }

  SignalReadingRow rowFor(VehicleDetail detail, String signal) =>
      detail.readings.firstWhere((r) => r.signal == signal);

  test('an unknown vehicle is null, not an empty register', () async {
    expect(await source.detail('nope', now), isNull);
  });

  group('readings register', () {
    test('every configured signal gets a row, in display order', () async {
      final detail = await load();

      expect(detail.readings.map((r) => r.signal), [
        'soc',
        'range_km',
        'speed',
        'battery_temp',
        'odometer',
        'ignition',
      ]);
    });

    test('labels and units come from signal_spec, not from Dart', () async {
      final soc = rowFor(await load(), 'soc');

      expect(soc.label, 'State of charge');
      expect(soc.unit, '%');
      expect(soc.maxAge, const Duration(minutes: 5));
    });

    test(
      'a signal that has never reported shows nothing and claims nothing',
      () async {
        final soc = rowFor(await load(), 'soc');

        expect(soc.value, isNull);
        expect(soc.verdict, isNull, reason: 'no pill, not a fourth verdict');
        expect(soc.hasNeverReported, isTrue);
      },
    );

    test('fresh and inside thresholds is NORMAL', () async {
      await latest('soc', 62, ago(1));

      final soc = rowFor(await load(), 'soc');
      expect(soc.verdict, ReadingVerdict.normal);
      expect(soc.value, 62);
      expect(soc.ageAt(now), const Duration(minutes: 1));
    });

    test('fresh and below the low threshold is ALERT', () async {
      await latest('soc', 12, ago(1));

      expect(rowFor(await load(), 'soc').verdict, ReadingVerdict.alert);
    });

    test('fresh and above the high threshold is ALERT', () async {
      await latest('battery_temp', 51, ago(1));

      expect(
        rowFor(await load(), 'battery_temp').verdict,
        ReadingVerdict.alert,
      );
    });

    test('too old to judge is STALE, whatever the value says', () async {
      await latest('soc', 4, ago(30));

      final soc = rowFor(await load(), 'soc');
      expect(
        soc.verdict,
        ReadingVerdict.stale,
        reason: 'an out-of-range stale reading must not claim ALERT',
      );
      expect(soc.value, 4, reason: 'the value is still shown');
    });

    test(
      'a signal with no thresholds is NORMAL whenever it is fresh',
      () async {
        await latest('odometer', 918273, ago(20));

        expect(
          rowFor(await load(), 'odometer').verdict,
          ReadingVerdict.normal,
          reason: 'odometer allows an hour before it goes stale',
        );
      },
    );

    test('the boundary is inclusive of the freshness window', () async {
      await latest('soc', 55, ago(5)); // max_age_sec is exactly 300

      expect(rowFor(await load(), 'soc').verdict, ReadingVerdict.normal);
    });
  });

  group('header', () {
    test('it reuses the fleet status ladder', () async {
      await latest('speed', 44, ago(1));
      await latest('ignition', 1, ago(1));

      final detail = await load();
      expect(detail.status, VehicleStatus.moving);
      expect(detail.regNo, 'KA01AB1234');
      expect(detail.lastPing, ago(1));
    });

    test('last ping spans signals and position reports', () async {
      await latest('speed', 0, ago(8));
      await db.read.execute(
        "INSERT INTO location_fix VALUES ('v1', "
        "TIMESTAMP '${ago(2).toIso8601String()}', 12.9, 77.5, 5, now())",
      );

      expect((await load()).lastPing, ago(2));
    });
  });

  group('SOC history', () {
    test('an empty log gives an empty history', () async {
      final history = (await load()).history;

      expect(history.isEmpty, isTrue);
      expect(history.readingCount, 0);
    });

    test('it reads the event log, not the latest-value table', () async {
      await latest('soc', 50, ago(1));
      for (var i = 0; i < 40; i++) {
        await logged('soc', 80 - i.toDouble(), ago(120 - i));
      }

      final history = (await load()).history;
      expect(history.readingCount, 40);
      expect(history.points, isNotEmpty);
      expect(history.min, lessThan(history.max));
    });

    test('points are bucketed, never more than the cap', () async {
      for (var i = 0; i < 600; i++) {
        await logged('soc', 90 - (i % 60).toDouble(), ago(600 - i));
      }

      final detail = await source.detail('v1', now, maxPoints: 20);
      expect(detail!.history.points.length, lessThanOrEqualTo(20));
      expect(
        detail.history.readingCount,
        600,
        reason: 'the raw count is reported even though points are thinned',
      );
    });

    test('readings outside the window are excluded', () async {
      await logged('soc', 70, ago(30));
      await logged('soc', 40, ago(60 * 30)); // 30 hours ago

      final detail = await source.detail('v1', now);
      expect(detail!.history.readingCount, 1);
    });

    test('points come back oldest first', () async {
      for (var i = 0; i < 12; i++) {
        await logged('soc', 60 + i.toDouble(), ago(120 - i * 5));
      }

      final points = (await load()).history.points;
      final times = points.map((p) => p.at).toList();
      expect(times, List.of(times)..sort());
    });
  });
}
