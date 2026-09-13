import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/vehicle_status_sql.dart';
import '../../../fleet/domain/entities/vehicle_status.dart';
import '../../domain/entities/soc_history.dart';
import '../../domain/entities/vehicle_detail.dart';
import '../models/signal_reading_row_model.dart';

/// Reads one vehicle's register and battery history.
abstract class VehicleDetailLocalDataSource {
  /// Header, readings register and SOC history for [vehicleId] at [now].
  ///
  /// Returns null when the vehicle is not in the roster — a screen opened from
  /// a stale link should say "not found", not render an empty register.
  Future<VehicleDetail?> detail(
    String vehicleId,
    DateTime now, {
    Duration window,
    int maxPoints,
  });
}

/// DuckDB implementation.
class DuckDbVehicleDetailLocalDataSource
    implements VehicleDetailLocalDataSource {
  const DuckDbVehicleDetailLocalDataSource(this._read);

  final Connection _read;

  @override
  Future<VehicleDetail?> detail(
    String vehicleId,
    DateTime now, {
    Duration window = const Duration(hours: 24),
    int maxPoints = 180,
  }) async {
    try {
      final header = await _header(vehicleId, now);
      if (header == null) return null;

      return VehicleDetail(
        vehicleId: vehicleId,
        regNo: header.$1,
        model: header.$2,
        status: header.$3,
        lastPing: header.$4,
        readings: await _register(vehicleId, now),
        history: await _socHistory(vehicleId, now, window, maxPoints),
      );
    } catch (error) {
      throw LocalDatabaseException('vehicle detail query failed', error);
    }
  }

  /// Registration, model, status and last ping — the same `scored` CTE the
  /// fleet list uses, narrowed to one row.
  Future<(String, String, VehicleStatus, DateTime?)?> _header(
    String vehicleId,
    DateTime now,
  ) async {
    final result = await _query(
      '$scoredCte SELECT reg_no, model, status, last_ping FROM scored '
      'WHERE vehicle_id = \$2',
      [now, vehicleId],
    );
    final row = result.fetchOne();
    if (row == null) return null;
    return (
      row[0]! as String,
      row[1]! as String,
      VehicleStatus.fromSql(row[2]! as String),
      row[3] as DateTime?,
    );
  }

  /// One row per configured signal, whether or not it has ever reported.
  ///
  /// Driven from `signal_spec` with a LEFT JOIN, so adding a signal to the
  /// config table adds a register row with no code change — and a signal that
  /// has never arrived still gets a row, which is the "—, no pill" case the
  /// brief calls for.
  Future<List<SignalReadingRowModel>> _register(
    String vehicleId,
    DateTime now,
  ) async {
    final result = await _query(
      '''
      SELECT s.signal, s.label, s.unit, s.max_age_sec, l.value, l.event_ts,
             CASE
               WHEN l.event_ts IS NULL THEN NULL
               WHEN l.event_ts < \$1 - to_seconds(s.max_age_sec) THEN 'STALE'
               WHEN (s.crit_lo IS NOT NULL AND l.value < s.crit_lo)
                 OR (s.crit_hi IS NOT NULL AND l.value > s.crit_hi)
                 OR (s.warn_lo IS NOT NULL AND l.value < s.warn_lo)
                 OR (s.warn_hi IS NOT NULL AND l.value > s.warn_hi) THEN 'ALERT'
               ELSE 'NORMAL'
             END AS verdict
      FROM signal_spec s
      LEFT JOIN vehicle_signal_latest l
        ON l.signal = s.signal AND l.vehicle_id = \$2
      ORDER BY list_position($_registerOrder, s.signal)
      ''',
      [now, vehicleId],
    );
    return [
      for (final row in result.fetchAll()) SignalReadingRowModel.fromRow(row),
    ];
  }

  /// Battery history, bucketed down to at most [maxPoints] points.
  ///
  /// This is the one query that touches the multi-million-row event log, and
  /// it is the point of the section: the latest-value table could not answer
  /// it. Bucketing happens in SQL — pulling a day of raw readings into Dart to
  /// thin them there would defeat the exercise.
  Future<SocHistory> _socHistory(
    String vehicleId,
    DateTime now,
    Duration window,
    int maxPoints,
  ) async {
    final from = now.subtract(window);

    // Bucket width comes from the span the data actually covers, not from the
    // requested window. A vehicle with twenty seconds of history inside a
    // 24-hour window would otherwise collapse into a single point.
    final span = await _query(
      '''
      SELECT min(event_ts), max(event_ts)
      FROM signal_reading
      WHERE vehicle_id = \$1 AND signal = 'soc' AND event_ts >= \$2
      ''',
      [vehicleId, from],
    );
    final spanRow = span.fetchOne()!;
    if (spanRow[0] == null) return const SocHistory.empty();

    final start = spanRow[0]! as DateTime;
    final covered = (spanRow[1]! as DateTime).difference(start);
    // Divide by one fewer than the cap, and align buckets to the first reading
    // rather than to absolute epoch: epoch alignment leaves a partial bucket at
    // each end, which puts the point count one over the cap.
    final bucketSeconds =
        (covered.inSeconds / (maxPoints - 1).clamp(1, maxPoints)).ceil().clamp(
          1,
          86400,
        );

    final result = await _query(
      '''
      SELECT min(event_ts) AS at, avg(value) AS value, count(*) AS n
      FROM signal_reading
      WHERE vehicle_id = \$1 AND signal = 'soc' AND event_ts >= \$2
      GROUP BY floor((epoch(event_ts) - epoch(\$3)) / $bucketSeconds)
      ORDER BY at
      ''',
      [vehicleId, from, start],
    );

    final points = <SocPoint>[];
    var readings = 0;
    for (final row in result.fetchAll()) {
      points.add(
        SocPoint(at: row[0]! as DateTime, value: (row[1]! as num).toDouble()),
      );
      readings += (row[2]! as num).toInt();
    }

    return SocHistory(
      points: points,
      readingCount: readings,
      from: points.isEmpty ? null : points.first.at,
      to: points.isEmpty ? null : points.last.at,
    );
  }

  /// Prepares [sql] and binds [params] positionally.
  ///
  /// Positional, because these statements open with a `WITH` clause and
  /// DuckDB 1.2.1 cannot look up a second *named* parameter in one — see the
  /// contract on `scoredCte`. Each statement therefore binds exactly the
  /// parameters it references, in order; binding one it does not reference
  /// fails the same way.
  Future<ResultSet> _query(String sql, List<Object?> params) async {
    final statement = await _read.prepare(sql);
    try {
      statement.bindParams(params);
      return await statement.execute();
    } finally {
      await statement.dispose();
    }
  }
}

/// Register display order.
///
/// A list in SQL rather than a `sort_order` column: ordering is a presentation
/// concern that does not justify a migration, and `list_position` keeps it to
/// one expression. Signals missing from this list sort last.
const _registerOrder =
    "['soc', 'range_km', 'speed', 'battery_temp', 'odometer', 'ignition']";
