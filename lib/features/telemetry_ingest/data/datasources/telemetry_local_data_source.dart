import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/fleet_db.dart';
import '../../domain/entities/fleet_vehicle.dart';
import '../../domain/entities/ingest_snapshot.dart';
import '../models/telemetry_packet_model.dart';
import 'telemetry_writer_isolate.dart';

/// Everything the feature does to local storage.
///
/// Abstract so the repository can be tested against a fake, and so the
/// DuckDB-specific parts stay in one file.
abstract class TelemetryLocalDataSource {
  /// Installs the fleet roster. Returns rows inserted; zero if already seeded.
  Future<int> seedFleet(List<FleetVehicle> vehicles);

  /// Writes one batch durably, scoring alert freshness against [now].
  Future<IngestReceiptModel> applyBatch(
    List<TelemetryPacketModel> batch,
    DateTime now,
  );

  /// Reads current totals off disk.
  Future<IngestSnapshot> snapshot();

  /// Stops the writer.
  Future<void> dispose();
}

/// DuckDB-backed implementation.
///
/// Writes go to the [TelemetryWriter] isolate; reads use the UI isolate's own
/// connection, which sees an MVCC snapshot and is never blocked by a commit
/// in flight.
class DuckDbTelemetryLocalDataSource implements TelemetryLocalDataSource {
  DuckDbTelemetryLocalDataSource._(this._db, this._writer);

  final FleetDb _db;
  final TelemetryWriter _writer;

  /// Read connection, exposed for the feature screens that query directly.
  Connection get read => _db.read;

  /// The process's single writer.
  ///
  /// Exposed so the alerts feature can write dismissals through the same
  /// isolate. DuckDB takes one writer and the alert evaluator runs on this one
  /// every tick, so a second write path would be racing it — see
  /// [TelemetryWriter.dismissAlert].
  TelemetryWriter get writer => _writer;

  /// Spawns the writer against an already-open database.
  static Future<DuckDbTelemetryLocalDataSource> create(FleetDb db) async {
    final writer = await TelemetryWriter.spawn(db.transferable);
    return DuckDbTelemetryLocalDataSource._(db, writer);
  }

  @override
  Future<int> seedFleet(List<FleetVehicle> vehicles) {
    // Flattened to rows here rather than in the writer so the isolate boundary
    // carries plain data and not another domain type.
    final rows = [
      for (final vehicle in vehicles)
        <Object?>[vehicle.vehicleId, vehicle.regNo, vehicle.model],
    ];
    return _writer.seedFleet(rows);
  }

  @override
  Future<IngestReceiptModel> applyBatch(
    List<TelemetryPacketModel> batch,
    DateTime now,
  ) => _writer.applyBatch(batch, now);

  /// One query for all four numbers — four round trips would cost more than
  /// the aggregation does.
  @override
  Future<IngestSnapshot> snapshot() async {
    try {
      final result = await _db.read.query('''
        SELECT (SELECT count(*) FROM vehicle),
               (SELECT count(*) FROM signal_reading),
               (SELECT count(*) FROM location_fix),
               (SELECT max(processed_through) FROM ingest_watermark)
      ''');
      final row = result.fetchOne()!;
      return IngestSnapshot(
        vehicles: (row[0] as num).toInt(),
        signalRows: (row[1] as num).toInt(),
        locationRows: (row[2] as num).toInt(),
        newestEventTs: row[3] as DateTime?,
      );
    } catch (error) {
      throw LocalDatabaseException('snapshot query failed', error);
    }
  }

  @override
  Future<void> dispose() => _writer.dispose();
}
