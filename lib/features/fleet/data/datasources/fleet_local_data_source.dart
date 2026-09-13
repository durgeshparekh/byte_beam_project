import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/vehicle_status_sql.dart';
import '../../domain/entities/fleet_filter.dart';
import '../../domain/entities/fleet_overview.dart';
import '../../domain/entities/vehicle_status.dart';
import '../models/fleet_vehicle_summary_model.dart';

/// Reads the fleet list out of DuckDB.
///
/// The whole read path is `vehicle` (500 rows) joined to
/// `vehicle_signal_latest` (500 x 6) and `signal_spec` (6). No scan of the
/// multi-million-row log happens here, which is the entire reason
/// `vehicle_signal_latest` is maintained on ingest.
abstract class FleetLocalDataSource {
  /// Rows for [filter] plus the count for every chip, read at instant [now].
  Future<FleetOverview> overview(FleetFilter filter, DateTime now);
}

/// DuckDB implementation.
class DuckDbFleetLocalDataSource implements FleetLocalDataSource {
  const DuckDbFleetLocalDataSource(this._read);

  /// The UI isolate's read connection. Sees an MVCC snapshot, so a commit in
  /// the writer never blocks the list.
  final Connection _read;

  @override
  Future<FleetOverview> overview(FleetFilter filter, DateTime now) async {
    try {
      // Two queries, both over the same CTE: the counts must span the whole
      // fleet while the rows are narrowed to one chip. Counting the returned
      // rows instead would make every chip read "the number you can see".
      final counts = await _counts(now);
      final vehicles = await _vehicles(filter, now);
      return FleetOverview(filter: filter, vehicles: vehicles, counts: counts);
    } catch (error) {
      throw LocalDatabaseException('fleet overview query failed', error);
    }
  }

  /// Count per status, plus the total for the "All" chip.
  Future<Map<FleetFilter, int>> _counts(DateTime now) async {
    final result = await _query(
      '$scoredCte SELECT status, count(*) FROM scored GROUP BY status',
      now,
    );

    final counts = {for (final filter in FleetFilter.values) filter: 0};
    var total = 0;
    for (final row in result.fetchAll()) {
      final status = VehicleStatus.fromSql(row[0]! as String);
      final count = (row[1]! as num).toInt();
      total += count;
      counts[_filterFor(status)] = count;
    }
    counts[FleetFilter.all] = total;
    return counts;
  }

  /// The rows for one chip, ordered by registration so the list is stable
  /// between refreshes — an order that jumps as speeds change is unreadable.
  Future<List<FleetVehicleSummaryModel>> _vehicles(
    FleetFilter filter,
    DateTime now,
  ) async {
    final status = filter.status;
    final where = status == null ? '' : "WHERE status = '${status.sqlName}'";
    final result = await _query(
      '$scoredCte SELECT vehicle_id, reg_no, model, status, soc, range_km, '
      'speed, last_ping, alert_severity FROM scored $where ORDER BY reg_no',
      now,
    );
    return [
      for (final row in result.fetchAll())
        FleetVehicleSummaryModel.fromRow(row),
    ];
  }

  /// Runs a statement built on [scoredCte], binding the instant to compare
  /// freshness against.
  ///
  /// `now` is bound rather than taken from SQL's own `now()` so tests can pin
  /// it — a fleet list whose rules depend on the wall clock is untestable.
  Future<ResultSet> _query(String sql, DateTime now) async {
    final statement = await _read.prepare(sql);
    try {
      statement.bindParams([now]);
      return await statement.execute();
    } finally {
      await statement.dispose();
    }
  }

  /// Maps a status back to the chip that selects it.
  FleetFilter _filterFor(VehicleStatus status) => switch (status) {
    VehicleStatus.moving => FleetFilter.moving,
    VehicleStatus.idle => FleetFilter.idle,
    VehicleStatus.stopped => FleetFilter.stopped,
    VehicleStatus.offline => FleetFilter.offline,
  };
}
