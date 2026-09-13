import 'package:byte_beam_project/db/alert_sql.dart';
import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final now = DateTime.utc(2026, 1, 1, 12);

DateTime ago(num minutes) =>
    now.subtract(Duration(seconds: (minutes * 60).round()));

/// The alert lifecycle, driven through the real evaluator.
///
/// Readings are written straight into `vehicle_signal_latest` rather than
/// pushed through the simulator: these are tests of the state machine, and
/// steering a physics model to land on 9.4% SOC would test the model instead.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    conn = db.read;
    await conn.execute("INSERT INTO vehicle VALUES ('v1', 'KA01AA0001', 'eT')");
  });
  tearDown(() => db.close());

  /// Sets a vehicle's latest reading for one signal.
  Future<void> reading(String signal, double value, DateTime at) =>
      conn.execute(
        'INSERT OR REPLACE INTO vehicle_signal_latest VALUES '
        "('v1', '$signal', TIMESTAMP '${at.toIso8601String()}', $value)",
      );

  Future<void> evaluate([DateTime? at]) => evaluateAlerts(conn, at ?? now);

  /// Every alert row ever written, oldest first.
  Future<List<List<Object?>>> rows() async {
    final result = await conn.query(
      'SELECT alert_id, alert_type, severity, raised_at, escalated_at, '
      'resolved_at, dismissed_at, dismiss_reason FROM alert ORDER BY raised_at',
    );
    return result.fetchAll();
  }

  Future<List<Object?>> single() async {
    final all = await rows();
    expect(all, hasLength(1));
    return all.single;
  }

  group('raising', () {
    test('a fresh SOC under 20% raises one warning', () async {
      await reading('soc', 18, ago(1));
      await evaluate();

      final row = await single();
      expect(row[1], 'battery_low');
      expect(row[2], 'warning');
      expect(row[3], now);
      expect(row[4], isNull, reason: 'never escalated');
    });

    test('a fresh SOC under 10% opens straight at critical', () async {
      await reading('soc', 6, ago(1));
      await evaluate();

      final row = await single();
      expect(row[2], 'critical');
      expect(row[4], now, reason: 'escalated_at is stamped on the way in too');
    });

    test('a battery over 45C raises its own critical alert', () async {
      await reading('battery_temp', 51, ago(1));
      await evaluate();

      final row = await single();
      expect(row[1], 'battery_overheat');
      expect(row[2], 'critical');
    });

    test('a reading in the hysteresis band raises nothing', () async {
      await reading('soc', 21, ago(1));
      await evaluate();

      expect(await rows(), isEmpty);
    });

    test('a stale reading raises nothing', () async {
      await reading('soc', 4, ago(40));
      await evaluate();

      expect(await rows(), isEmpty);
    });

    test('a healthy battery raises nothing', () async {
      await reading('soc', 64, ago(1));
      await reading('battery_temp', 31, ago(1));
      await evaluate();

      expect(await rows(), isEmpty);
    });

    test('two conditions on one vehicle are two alerts', () async {
      await reading('soc', 8, ago(1));
      await reading('battery_temp', 51, ago(1));
      await evaluate();

      expect(await rows(), hasLength(2));
    });

    // The property that makes it safe to run after every batch.
    test('re-running on unchanged state changes nothing', () async {
      await reading('soc', 18, ago(1));
      await evaluate();
      final before = await single();

      await evaluate(now.add(const Duration(minutes: 1)));

      expect(await single(), before);
    });
  });

  group('escalation', () {
    test(
      '20% to 8% escalates the same row, it does not raise a second',
      () async {
        await reading('soc', 18, ago(1));
        await evaluate();
        final first = await single();

        final later = now.add(const Duration(minutes: 5));
        await reading('soc', 8, later);
        await evaluate(later);

        final row = await single();
        expect(row[0], first[0], reason: 'same episode, same id');
        expect(row[2], 'critical');
        expect(row[3], now, reason: 'raised when the battery first went low');
        expect(row[4], later, reason: 'escalated when it went critical');
      },
    );

    // Escalation is not hysteretic: the episode already exists either way, so
    // there are no rows to churn.
    test(
      'a dismissed warning that goes critical un-dismisses itself',
      () async {
        await reading('soc', 18, ago(1));
        await evaluate();
        final id = (await single())[0]! as String;
        await execAlertSql(conn, dismissAlert, [id, now, 'on_it']);

        final later = now.add(const Duration(minutes: 5));
        await reading('soc', 8, later);
        await evaluate(later);

        final row = await single();
        expect(row[2], 'critical');
        expect(
          row[6],
          isNull,
          reason: '"I am on it" at 18% is not consent to ignore 8%',
        );
        expect(row[7], isNull);
      },
    );

    test('recovering to 15% de-escalates in place', () async {
      await reading('soc', 6, ago(1));
      await evaluate();
      final first = await single();

      final later = now.add(const Duration(minutes: 5));
      await reading('soc', 15, later);
      await evaluate(later);

      final row = await single();
      expect(row[0], first[0]);
      expect(row[2], 'warning');
      expect(row[5], isNull, reason: 'still low, so still open');
      expect(
        row[4],
        now,
        reason: 'it did go critical once; that is worth keeping',
      );
    });
  });

  group('resolution', () {
    test('charging well above 20% resolves the alert', () async {
      await reading('soc', 8, ago(1));
      await evaluate();

      final later = now.add(const Duration(minutes: 5));
      await reading('soc', 80, later);
      await evaluate(later);

      expect((await single())[5], later);
    });

    // ARCHITECTURE.md §10, ambiguity 6. An episode ends when we watch it end,
    // not when we stop looking — auto-resolving here would quietly drop the
    // alert on a truck that died at 5%.
    test('a reading going quiet leaves the alert open', () async {
      await reading('soc', 8, now);
      await evaluate();

      await evaluate(now.add(const Duration(minutes: 30)));

      final row = await single();
      expect(row[5], isNull, reason: 'no reading is not evidence of recovery');
    });

    // The hysteresis band, which is what stopped one simulated truck opening
    // seven overheat episodes in under two minutes.
    test('a reading wobbling back over the line does not resolve', () async {
      await reading('battery_temp', 46, ago(1));
      await evaluate();

      final later = now.add(const Duration(minutes: 1));
      await reading('battery_temp', 44.5, later);
      await evaluate(later);

      expect((await single())[5], isNull, reason: 'still inside the band');
      expect(await rows(), hasLength(1));
    });

    test('a reading clearly back inside does resolve', () async {
      await reading('battery_temp', 46, ago(1));
      await evaluate();

      final later = now.add(const Duration(minutes: 1));
      await reading('battery_temp', 42, later);
      await evaluate(later);

      expect((await single())[5], later);
    });

    test('a resolved condition that returns opens a new episode', () async {
      await reading('soc', 8, ago(1));
      await evaluate();

      final charged = now.add(const Duration(minutes: 5));
      await reading('soc', 80, charged);
      await evaluate(charged);

      final flat = now.add(const Duration(minutes: 10));
      await reading('soc', 9, flat);
      await evaluate(flat);

      final all = await rows();
      expect(all, hasLength(2));
      expect(all.first[5], charged, reason: 'the first episode stayed closed');
      expect(all.last[5], isNull);
      expect(all.first[0], isNot(all.last[0]));
    });

    test('one condition clearing leaves the other alone', () async {
      await reading('soc', 8, ago(1));
      await reading('battery_temp', 51, ago(1));
      await evaluate();

      final later = now.add(const Duration(minutes: 5));
      await reading('soc', 80, later);
      await reading('battery_temp', 51, later);
      await evaluate(later);

      final all = await rows();
      expect(all.where((r) => r[5] == null).map((r) => r[1]), [
        'battery_overheat',
      ]);
    });
  });

  group('dismissal', () {
    Future<void> dismiss(String id, String reason) =>
        execAlertSql(conn, dismissAlert, [id, now, reason]);

    test(
      'a dismissed alert still resolves when its condition clears',
      () async {
        await reading('soc', 8, ago(1));
        await evaluate();
        await dismiss((await single())[0]! as String, 'on_it');

        final later = now.add(const Duration(minutes: 5));
        await reading('soc', 80, later);
        await evaluate(later);

        final row = await single();
        expect(row[5], later, reason: 'resolution ignores dismissal');
        expect(row[6], now, reason: 'the dismissal is still on the record');
        expect(row[7], 'on_it');
      },
    );

    // Dismissal suppresses the episode, not the rule.
    test(
      'a dismissed alert whose condition persists is not raised again',
      () async {
        await reading('soc', 8, ago(1));
        await evaluate();
        await dismiss((await single())[0]! as String, 'on_it');

        await evaluate(now.add(const Duration(minutes: 5)));

        expect(await rows(), hasLength(1));
      },
    );

    test('but it comes back after the condition clears and returns', () async {
      await reading('soc', 8, ago(1));
      await evaluate();
      await dismiss((await single())[0]! as String, 'on_it');

      final charged = now.add(const Duration(minutes: 5));
      await reading('soc', 80, charged);
      await evaluate(charged);

      final flat = now.add(const Duration(minutes: 10));
      await reading('soc', 9, flat);
      await evaluate(flat);

      final all = await rows();
      expect(all, hasLength(2));
      expect(all.last[6], isNull, reason: 'a new episode is not pre-dismissed');
    });

    test('undo puts it back', () async {
      await reading('soc', 8, ago(1));
      await evaluate();
      final id = (await single())[0]! as String;
      await dismiss(id, 'wrong_alert');

      await execAlertSql(conn, restoreAlert, [id]);

      final row = await single();
      expect(row[6], isNull);
      expect(row[7], isNull);
    });
  });
}
