import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/alert_sql.dart';
import '../../../telemetry_ingest/data/datasources/telemetry_writer_isolate.dart';
import '../models/alert_model.dart';

/// Reads the alert list and writes the two user actions.
abstract class AlertLocalDataSource {
  /// Open, undismissed alerts, worst first.
  Future<List<FleetAlertModel>> openAlerts();

  /// Records a dismissal.
  Future<void> dismiss(String alertId, String reason, DateTime at);

  /// Clears a dismissal.
  Future<void> restore(String alertId);
}

/// DuckDB implementation.
///
/// Reads on the UI isolate's own connection; writes through the process's
/// single writer. The split is not cosmetic — the alert evaluator updates
/// these same rows on every ingest tick, so writing them from this connection
/// would be two writers racing for the same rows, and losing that race looks
/// to the user like a button that did nothing.
class DuckDbAlertLocalDataSource implements AlertLocalDataSource {
  const DuckDbAlertLocalDataSource(this._read, this._writer);

  final Connection _read;
  final TelemetryWriter _writer;

  @override
  Future<List<FleetAlertModel>> openAlerts() async {
    try {
      // The signal map supplies the current value, its unit and the threshold
      // label from `signal_spec`, so the card can say "SOC 8%" without this
      // layer knowing that low battery is about SOC.
      final result = await _read.query('''
        SELECT a.alert_id, a.vehicle_id, v.reg_no, a.alert_type, a.severity,
               a.raised_at, a.escalated_at, l.value, sp.unit,
               sp.max_age_sec, l.event_ts
        FROM alert a
        JOIN vehicle v USING (vehicle_id)
        JOIN $alertSignalMap ON m.alert_type = a.alert_type
        LEFT JOIN signal_spec sp ON sp.signal = m.signal
        LEFT JOIN vehicle_signal_latest l
          ON l.vehicle_id = a.vehicle_id AND l.signal = m.signal
        WHERE a.$openAlertPredicate
        ORDER BY CASE a.severity WHEN 'critical' THEN 0 ELSE 1 END,
                 a.raised_at DESC
      ''');
      return [
        for (final row in result.fetchAll()) FleetAlertModel.fromRow(row),
      ];
    } catch (error) {
      throw LocalDatabaseException('alert list query failed', error);
    }
  }

  @override
  Future<void> dismiss(String alertId, String reason, DateTime at) =>
      _writer.dismissAlert(alertId, at, reason);

  @override
  Future<void> restore(String alertId) => _writer.restoreAlert(alertId);
}
