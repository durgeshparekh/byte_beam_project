import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/alerts/data/datasources/alert_local_data_source.dart';
import 'package:byte_beam_project/features/alerts/domain/entities/fleet_alert.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/fleet_vehicle.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final now = DateTime.utc(2026, 1, 1, 12);

/// The alert data source against a real database and the real writer isolate.
///
/// Worth the isolate: dismissal is the one write in this app that does not
/// come from ingest, and "does it actually reach the disk through the single
/// writer" is precisely what a stub cannot answer.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbTelemetryLocalDataSource ingest;
  late DuckDbAlertLocalDataSource alerts;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    ingest = await DuckDbTelemetryLocalDataSource.create(db);
    alerts = DuckDbAlertLocalDataSource(db.read, ingest.writer);
    conn = db.read;
    await ingest.seedFleet(const [
      FleetVehicle(vehicleId: 'v1', regNo: 'KA01AA0001', model: 'eT'),
      FleetVehicle(vehicleId: 'v2', regNo: 'KA01BB0002', model: 'eT'),
    ]);
  });

  tearDown(() async {
    await ingest.dispose();
    await db.close();
  });

  /// Pushes one reading through the real ingest path, which is also what runs
  /// the evaluator.
  Future<void> report(
    String vehicleId,
    String signal,
    double value, {
    DateTime? at,
    DateTime? evaluatedAt,
  }) => ingest.applyBatch([
    TelemetryPacketModel(
      vehicleId: vehicleId,
      eventTs: at ?? now,
      signals: {signal: value},
    ),
  ], evaluatedAt ?? now);

  group('the evaluator runs as part of ingest', () {
    test('a batch that breaches a threshold raises an alert', () async {
      await report('v1', 'soc', 8);

      final open = await alerts.openAlerts();
      expect(open, hasLength(1));
      expect(open.single.vehicleId, 'v1');
      expect(open.single.type, AlertType.batteryLow);
      expect(open.single.severity, AlertSeverity.critical);
    });

    test('a batch that clears it resolves the alert', () async {
      await report('v1', 'soc', 8);

      final later = now.add(const Duration(minutes: 2));
      await report('v1', 'soc', 70, at: later, evaluatedAt: later);

      expect(await alerts.openAlerts(), isEmpty);
    });

    // The evaluator is fleet-wide, so v1 is re-examined here even though it
    // said nothing — and re-examining it correctly leaves its alert alone.
    // ARCHITECTURE.md §10, ambiguity 6.
    test("a silent vehicle keeps its alert, and says so", () async {
      await report('v1', 'soc', 8);

      final later = now.add(const Duration(minutes: 30));
      await report('v2', 'soc', 90, at: later, evaluatedAt: later);

      final alert = (await alerts.openAlerts()).single;
      expect(alert.vehicleId, 'v1');
      expect(
        alert.isStaleAt(later),
        isTrue,
        reason: 'still open, but the card must not claim it is live',
      );
    });
    // Nothing in the lifecycle moves without a fresh reading, which is why
    // there is no idle re-evaluation timer: raising, escalating and resolving
    // all need evidence, and time alone is not evidence.
    test('time passing on its own changes nothing', () async {
      await report('v1', 'soc', 8);
      final before = await alerts.openAlerts();

      await ingest.applyBatch(const [], now.add(const Duration(hours: 3)));

      final after = await alerts.openAlerts();
      expect(after.single.alertId, before.single.alertId);
      expect(after.single.severity, before.single.severity);
    });
  });

  group('the open list', () {
    test('carries the registration, the reading and its unit', () async {
      await report('v1', 'soc', 8);

      final alert = (await alerts.openAlerts()).single;
      expect(alert.regNo, 'KA01AA0001');
      expect(alert.value, 8);
      expect(alert.unit, '%');
      expect(alert.raisedAt, now);
    });

    test('puts critical before warning', () async {
      await report('v1', 'soc', 15);
      await report('v2', 'soc', 4);

      final open = await alerts.openAlerts();
      expect(open.map((a) => a.vehicleId), ['v2', 'v1']);
    });

    test('hides resolved alerts', () async {
      await report('v1', 'soc', 8);
      final later = now.add(const Duration(minutes: 2));
      await report('v1', 'soc', 70, at: later, evaluatedAt: later);

      expect(await alerts.openAlerts(), isEmpty);
      final all = await conn.query('SELECT count(*) FROM alert');
      expect(
        (all.fetchOne()!.first as num).toInt(),
        1,
        reason: 'hidden, not deleted — the episode is a record',
      );
    });
  });

  group('dismissal through the single writer', () {
    test('a dismissal hides the alert and records the reason', () async {
      await report('v1', 'soc', 8);
      final alert = (await alerts.openAlerts()).single;

      await alerts.dismiss(alert.alertId, DismissReason.onIt.stored(), now);

      expect(await alerts.openAlerts(), isEmpty);
      final row = await conn.query(
        'SELECT dismissed_at, dismiss_reason FROM alert',
      );
      expect(row.fetchOne(), [now, 'on_it']);
    });

    test('a free-text reason is stored alongside its code', () async {
      await report('v1', 'soc', 8);
      final alert = (await alerts.openAlerts()).single;

      await alerts.dismiss(
        alert.alertId,
        DismissReason.somethingElse.stored('charger is broken'),
        now,
      );

      final row = await conn.query('SELECT dismiss_reason FROM alert');
      expect(row.fetchOne()!.first, 'other: charger is broken');
    });

    test('undo brings it straight back', () async {
      await report('v1', 'soc', 8);
      final alert = (await alerts.openAlerts()).single;
      await alerts.dismiss(alert.alertId, 'on_it', now);

      await alerts.restore(alert.alertId);

      expect((await alerts.openAlerts()).single.alertId, alert.alertId);
    });

    // The reason the dismissal is written rather than held in memory for the
    // length of the undo window.
    test('a dismissal survives a restart', () async {
      await report('v1', 'soc', 8);
      await alerts.dismiss(
        (await alerts.openAlerts()).single.alertId,
        'on_it',
        now,
      );

      // A fresh connection is as close as an in-memory database gets to a
      // relaunch; the file-backed version of this is `fleet_db_test`.
      final reopened = DuckDbAlertLocalDataSource(db.read, ingest.writer);
      expect(await reopened.openAlerts(), isEmpty);
    });
  });
}
