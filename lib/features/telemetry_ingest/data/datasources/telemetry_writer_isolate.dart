import 'dart:isolate';

import 'package:dart_duckdb/dart_duckdb.dart';

import '../../../../core/error/exceptions.dart';
import '../../../../db/alert_sql.dart';
import '../../../../db/fleet_db.dart';
import '../../../../db/geofence_sql.dart';
import '../models/telemetry_packet_model.dart';

/// The single writer.
///
/// DuckDB allows one writer at a time, so every mutation in the app funnels
/// through this long-lived isolate. It is spawned once and kept: spawning a
/// fresh isolate per batch (as `Isolate.run` would) costs more than the write.
///
/// The UI isolate keeps its own read connection and sees a consistent MVCC
/// snapshot while this one commits, which is what stops a 3-hour backlog dump
/// from freezing the fleet list.
class TelemetryWriter {
  TelemetryWriter._(this._isolate, this._commands);

  final Isolate _isolate;
  final SendPort _commands;

  /// Starts the writer and waits until it has a connection and its staging
  /// tables in place. Returns only once it is ready to accept batches.
  static Future<TelemetryWriter> spawn(
    TransferableDatabase transferable,
  ) async {
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      _writerMain,
      _WriterBoot(handshake.sendPort, transferable),
      debugName: 'telemetry-writer',
    );

    final ready = await handshake.first;
    handshake.close();
    if (ready is _WriterFailed) {
      isolate.kill(priority: Isolate.immediate);
      throw LocalDatabaseException(
        'writer isolate failed to start',
        ready.error,
      );
    }
    return TelemetryWriter._(isolate, ready as SendPort);
  }

  /// Applies one batch durably and returns what the database actually did.
  ///
  /// [now] is the wall-clock instant the alert evaluator judges freshness
  /// against. Passed in rather than read from `now()` inside the isolate so a
  /// test can pin it — and so a backlog dump, whose event times are hours old,
  /// is still scored against the present.
  ///
  /// A fresh reply port per request keeps this free of request-id bookkeeping;
  /// the allocation is noise next to the write itself.
  Future<IngestReceiptModel> applyBatch(
    List<TelemetryPacketModel> batch,
    DateTime now,
  ) async {
    final reply = ReceivePort();
    _commands.send(_WriteRequest(reply.sendPort, batch, now));
    final response = await reply.first as _WriteResponse;
    reply.close();

    final error = response.error;
    if (error != null) {
      throw LocalDatabaseException('ingest batch failed', error);
    }
    return response.receipt!;
  }

  /// Installs the fleet roster, returning how many rows were inserted.
  ///
  /// Goes through the writer like everything else rather than writing from the
  /// UI connection: DuckDB permits one writer, and "it happens to be safe at
  /// startup" is the kind of exception that stops being true later.
  Future<int> seedFleet(List<List<Object?>> vehicleRows) async {
    final reply = ReceivePort();
    _commands.send(_SeedRequest(reply.sendPort, vehicleRows));
    final response = await reply.first as _WriteResponse;
    reply.close();

    final error = response.error;
    if (error != null) {
      throw LocalDatabaseException('fleet seed failed', error);
    }
    return response.inserted ?? 0;
  }

  /// Hides one alert and records why.
  ///
  /// Alert writes come through here for the same reason ingest does: DuckDB
  /// takes one writer, and the evaluator updates these very rows on every
  /// tick. Dismissing from the UI connection would race it, and the failure
  /// mode — an optimistic-concurrency conflict — is a tap that silently does
  /// nothing. This class is the process's single writer; that it lives in the
  /// ingest feature is where it was born, not what it is.
  Future<void> dismissAlert(String alertId, DateTime at, String reason) =>
      _alertCommand(_AlertRequest(alertId: alertId, at: at, reason: reason));

  /// Puts a dismissed alert back, for UNDO.
  Future<void> restoreAlert(String alertId) =>
      _alertCommand(_AlertRequest(alertId: alertId));

  /// Sends one alert command and waits for it to commit.
  ///
  /// Awaited rather than fired and forgotten: UNDO is only honest if the
  /// dismissal it reverses is already on disk.
  Future<void> _alertCommand(_AlertRequest request) async {
    final reply = ReceivePort();
    _commands.send(request.withReply(reply.sendPort));
    final response = await reply.first as _WriteResponse;
    reply.close();

    final error = response.error;
    if (error != null) {
      throw LocalDatabaseException('alert update failed', error);
    }
  }

  /// Writes one fence and re-derives every geofence.
  ///
  /// [row] is the whole fence, in column order, so create / rename / move /
  /// deactivate / reactivate are one call. The recompute is the expensive part
  /// and it is deliberate: see [recomputeAllGeofences].
  Future<void> saveGeofence(List<Object?> row) async {
    final reply = ReceivePort();
    _commands.send(_GeofenceRequest(reply.sendPort, row));
    final response = await reply.first as _WriteResponse;
    reply.close();

    final error = response.error;
    if (error != null) {
      throw LocalDatabaseException('geofence save failed', error);
    }
  }

  /// Closes the writer's connection and stops the isolate.
  Future<void> dispose() async {
    final reply = ReceivePort();
    _commands.send(_Shutdown(reply.sendPort));
    await reply.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => _isolate.kill(priority: Isolate.immediate),
    );
    reply.close();
  }
}

// ---------------------------------------------------------------- isolate --

/// Isolate entry point. Top-level because `Isolate.spawn` cannot take a
/// closure that captures anything unsendable.
Future<void> _writerMain(_WriterBoot boot) async {
  final Connection conn;
  try {
    conn = await duckdb.connectWithTransferred(boot.transferable);
    await _createStagingTables(conn);
  } catch (error) {
    boot.reply.send(_WriterFailed(error.toString()));
    return;
  }

  final commands = ReceivePort();
  boot.reply.send(commands.sendPort);

  await for (final message in commands) {
    if (message is _Shutdown) {
      await conn.dispose();
      commands.close();
      message.reply.send(null);
      return;
    }
    if (message is _GeofenceRequest) {
      try {
        await _saveGeofence(conn, message.row);
        message.reply.send(const _WriteResponse());
      } catch (error) {
        message.reply.send(_WriteResponse(error: error.toString()));
      }
      continue;
    }
    if (message is _AlertRequest) {
      try {
        await _applyAlertCommand(conn, message);
        message.reply!.send(const _WriteResponse());
      } catch (error) {
        message.reply!.send(_WriteResponse(error: error.toString()));
      }
      continue;
    }
    if (message is _SeedRequest) {
      try {
        message.reply.send(
          _WriteResponse(inserted: await _seedFleet(conn, message.vehicles)),
        );
      } catch (error) {
        message.reply.send(_WriteResponse(error: error.toString()));
      }
      continue;
    }
    final request = message as _WriteRequest;
    try {
      request.reply.send(
        _WriteResponse(
          receipt: await _applyBatch(conn, request.batch, request.now),
        ),
      );
    } catch (error) {
      request.reply.send(_WriteResponse(error: error.toString()));
    }
  }
}

/// Staging tables the appender writes into.
///
/// Batches land here first so the real inserts can be set-based: one
/// `INSERT … SELECT` per target table instead of a statement per row, and the
/// intra-batch de-duplication becomes a `DISTINCT ON` rather than a Dart loop.
/// They are TEMP, so they belong to this connection and never touch the file.
Future<void> _createStagingTables(Connection conn) async {
  await conn.execute('''
    CREATE TEMP TABLE staging_signal (
      vehicle_id TEXT, signal TEXT, event_ts TIMESTAMP, value DOUBLE
    );
    CREATE TEMP TABLE staging_location (
      vehicle_id TEXT, event_ts TIMESTAMP, lat DOUBLE, lon DOUBLE, accuracy_m DOUBLE
    );
  ''');
  await conn.execute(geofenceScopeDdl);
}

/// Inserts the fleet roster, skipping vehicles that are already there.
///
/// Idempotent, so the app can call it unconditionally on every launch.
Future<int> _seedFleet(Connection conn, List<List<Object?>> vehicles) async {
  await conn.execute('''
    CREATE TEMP TABLE IF NOT EXISTS staging_vehicle (
      vehicle_id TEXT, reg_no TEXT, model TEXT
    );
    DELETE FROM staging_vehicle;
  ''');

  final appender = await conn.append('staging_vehicle', null);
  try {
    for (final row in vehicles) {
      for (final value in row) {
        appender.append(value);
      }
      appender.endRow();
    }
    appender.flush();
  } finally {
    appender.dispose();
  }

  return _countOf(conn, '''
    INSERT INTO vehicle
    SELECT * FROM (SELECT DISTINCT ON (vehicle_id) * FROM staging_vehicle)
    ON CONFLICT DO NOTHING
  ''');
}

/// One batch, end to end. Mirrors ARCHITECTURE.md §4 step for step.
Future<IngestReceiptModel> _applyBatch(
  Connection conn,
  List<TelemetryPacketModel> batch,
  DateTime now,
) async {
  final stopwatch = Stopwatch()..start();

  await _stage(conn, batch);

  // Transaction 1 — the log and the latest-value table.
  await conn.execute('BEGIN TRANSACTION');
  final int signalsApplied;
  final int locationsApplied;
  try {
    signalsApplied = await _appendSignalLog(conn);
    locationsApplied = await _appendLocationLog(conn);
    await _advanceLatest(conn);
    await conn.execute('COMMIT');
  } catch (_) {
    await conn.execute('ROLLBACK');
    rethrow;
  }

  // Transaction 2 — derivation position. Split from the first so a long
  // recompute never holds a write lock across the whole batch, and so the
  // watermark can only ever lag the log, never lead it (§3.4).
  await conn.execute('BEGIN TRANSACTION');
  final int lateVehicles;
  try {
    lateVehicles = await _countLateVehicles(conn);
    await evaluateAlerts(conn, now);
    await _deriveGeofences(conn);
    // Trips slot in beside the geofence detector, still before the watermark
    // moves. Order matters: the detector reads the *previous* watermark to
    // decide which vehicles have gone backwards and need a full replay.
    await _advanceWatermark(conn);
    await conn.execute('COMMIT');
  } catch (_) {
    await conn.execute('ROLLBACK');
    rethrow;
  }

  final offered = await _stagedCounts(conn);
  return IngestReceiptModel(
    packets: batch.length,
    signalRowsOffered: offered.$1,
    signalRowsApplied: signalsApplied,
    locationRowsOffered: offered.$2,
    locationRowsApplied: locationsApplied,
    lateVehicles: lateVehicles,
    duration: stopwatch.elapsed,
  );
}

/// Empties the staging tables and bulk-appends this batch into them.
///
/// The appender is DuckDB's row-wise bulk path — no SQL text, no parameter
/// binding, no string escaping of vehicle ids.
Future<void> _stage(Connection conn, List<TelemetryPacketModel> batch) async {
  await conn.execute(
    'DELETE FROM staging_signal; DELETE FROM staging_location;',
  );

  final signals = await conn.append('staging_signal', null);
  final locations = await conn.append('staging_location', null);
  try {
    for (final packet in batch) {
      for (final row in packet.toSignalRows()) {
        for (final value in row) {
          signals.append(value);
        }
        signals.endRow();
      }
      final location = packet.toLocationRow();
      if (location != null) {
        for (final value in location) {
          locations.append(value);
        }
        locations.endRow();
      }
    }
    signals.flush();
    locations.flush();
  } finally {
    signals.dispose();
    locations.dispose();
  }
}

/// Appends the batch to the event log.
///
/// `DISTINCT ON` collapses duplicates *within* the batch; `ON CONFLICT DO
/// NOTHING` against the natural primary key collapses duplicates against
/// everything already on disk. Re-delivering a packet is therefore a no-op
/// enforced by the database, not by application code.
Future<int> _appendSignalLog(Connection conn) async {
  return _countOf(conn, '''
    INSERT INTO signal_reading
    SELECT vehicle_id, signal, event_ts, value, CAST(now() AS TIMESTAMP)
    FROM (
      SELECT DISTINCT ON (vehicle_id, signal, event_ts) *
      FROM staging_signal
      ORDER BY vehicle_id, signal, event_ts
    )
    ON CONFLICT DO NOTHING
  ''');
}

/// Same contract as [_appendSignalLog], for position reports.
Future<int> _appendLocationLog(Connection conn) async {
  return _countOf(conn, '''
    INSERT INTO location_fix
    SELECT vehicle_id, event_ts, lat, lon, accuracy_m, CAST(now() AS TIMESTAMP)
    FROM (
      SELECT DISTINCT ON (vehicle_id, event_ts) *
      FROM staging_location
      ORDER BY vehicle_id, event_ts
    )
    ON CONFLICT DO NOTHING
  ''');
}

/// Moves the latest-value table forward.
///
/// The `WHERE excluded.event_ts > l.event_ts` guard is the entire late-packet
/// story for the read path: a packet that arrives late but measures an older
/// moment updates the log and leaves the current value alone.
Future<void> _advanceLatest(Connection conn) async {
  await conn.execute('''
    INSERT INTO vehicle_signal_latest AS l
    SELECT vehicle_id, signal, event_ts, value
    FROM (
      SELECT DISTINCT ON (vehicle_id, signal) *
      FROM staging_signal
      ORDER BY vehicle_id, signal, event_ts DESC
    )
    ON CONFLICT (vehicle_id, signal) DO UPDATE
      SET value = excluded.value, event_ts = excluded.event_ts
      WHERE excluded.event_ts > l.event_ts
  ''');
}

/// Re-derives geofence containment for the vehicles in this batch.
///
/// Runs before [_advanceWatermark] on purpose: the scope query compares the
/// batch's oldest fix against the watermark to tell an ordinary batch from one
/// that reaches backwards, and once the watermark has moved that comparison is
/// always false.
Future<void> _deriveGeofences(Connection conn) async {
  await conn.execute(clearGeofenceScope);
  await conn.execute(insertGeofenceScope);
  await deriveGeofences(conn);
}

/// Writes one fence and re-derives everything that depends on the geometry.
///
/// Its own transaction: a fence edit is a user action and must not be rolled
/// back by an unrelated batch, nor hold the write lock waiting for one.
Future<void> _saveGeofence(Connection conn, List<Object?> row) async {
  await conn.execute('BEGIN TRANSACTION');
  try {
    await execPrepared(conn, upsertGeofence, row);
    await recomputeAllGeofences(conn);
    await conn.execute('COMMIT');
  } catch (_) {
    await conn.execute('ROLLBACK');
    rethrow;
  }
}

/// Applies one dismissal or one undo.
///
/// Its own transaction: a user action must not be rolled back because an
/// unrelated batch failed, and it must not wait for one either.
Future<void> _applyAlertCommand(Connection conn, _AlertRequest request) async {
  final at = request.at;
  await conn.execute('BEGIN TRANSACTION');
  try {
    if (at == null) {
      await execPrepared(conn, restoreAlert, [request.alertId]);
    } else {
      await execPrepared(conn, dismissAlert, [
        request.alertId,
        at,
        request.reason,
      ]);
    }
    await conn.execute('COMMIT');
  } catch (_) {
    await conn.execute('ROLLBACK');
    rethrow;
  }
}

/// Counts vehicles whose batch reaches back behind where derivation already
/// ran. These are the replays that geofence transitions and trips will need.
Future<int> _countLateVehicles(Connection conn) async {
  final result = await conn.query('''
    SELECT count(*) FROM (
      SELECT s.vehicle_id
      FROM staging_signal s JOIN ingest_watermark w USING (vehicle_id)
      WHERE s.event_ts < w.processed_through
      UNION
      SELECT l.vehicle_id
      FROM staging_location l JOIN ingest_watermark w USING (vehicle_id)
      WHERE l.event_ts < w.processed_through
    )
  ''');
  return (result.fetchOne()!.first as num).toInt();
}

/// Records how far each vehicle's log has been processed.
///
/// Guarded the same way as the latest-value table: a late batch must not drag
/// a vehicle's watermark backwards.
Future<void> _advanceWatermark(Connection conn) async {
  await conn.execute('''
    INSERT INTO ingest_watermark AS w
    SELECT vehicle_id, max(event_ts) FROM (
      SELECT vehicle_id, event_ts FROM staging_signal
      UNION ALL
      SELECT vehicle_id, event_ts FROM staging_location
    ) GROUP BY vehicle_id
    ON CONFLICT (vehicle_id) DO UPDATE
      SET processed_through = excluded.processed_through
      WHERE excluded.processed_through > w.processed_through
  ''');
}

/// Staged row counts after intra-batch de-duplication — the denominator the
/// receipt's duplicate count is measured against.
Future<(int, int)> _stagedCounts(Connection conn) async {
  final result = await conn.query('''
    SELECT (SELECT count(*) FROM (SELECT DISTINCT vehicle_id, signal, event_ts FROM staging_signal)),
           (SELECT count(*) FROM (SELECT DISTINCT vehicle_id, event_ts FROM staging_location))
  ''');
  final row = result.fetchOne()!;
  return ((row[0] as num).toInt(), (row[1] as num).toInt());
}

/// Runs a mutating statement and returns the row count DuckDB reports.
Future<int> _countOf(Connection conn, String sql) async {
  final result = await conn.query(sql);
  final row = result.fetchOne();
  return row == null ? 0 : (row.first as num).toInt();
}

// --------------------------------------------------------------- messages --

/// Startup payload: where to reply, and the database handle to attach to.
class _WriterBoot {
  const _WriterBoot(this.reply, this.transferable);

  final SendPort reply;
  final TransferableDatabase transferable;
}

/// Sent back when the writer could not attach to the database.
class _WriterFailed {
  const _WriterFailed(this.error);

  final String error;
}

/// One batch to write, and where to send the receipt.
class _WriteRequest {
  const _WriteRequest(this.reply, this.batch, this.now);

  final SendPort reply;
  final List<TelemetryPacketModel> batch;

  /// Instant the alert evaluator scores freshness against.
  final DateTime now;
}

/// A dismissal, or — when [at] is null — the undo of one.
///
/// Built without a reply port and given one by [TelemetryWriter._alertCommand]
/// so the two public methods stay one-liners.
class _AlertRequest {
  const _AlertRequest({
    required this.alertId,
    this.at,
    this.reason,
    this.reply,
  });

  final String alertId;
  final DateTime? at;
  final String? reason;
  final SendPort? reply;

  _AlertRequest withReply(SendPort port) =>
      _AlertRequest(alertId: alertId, at: at, reason: reason, reply: port);
}

/// Either a receipt or the error string that replaced it.
class _WriteResponse {
  const _WriteResponse({this.receipt, this.inserted, this.error});

  final IngestReceiptModel? receipt;

  /// Row count, for requests that insert rather than ingest.
  final int? inserted;

  final String? error;
}

/// The fleet roster to install, as raw rows.
class _SeedRequest {
  const _SeedRequest(this.reply, this.vehicles);

  final SendPort reply;
  final List<List<Object?>> vehicles;
}

/// One fence to write, as a full row, and where to acknowledge it.
class _GeofenceRequest {
  const _GeofenceRequest(this.reply, this.row);

  final SendPort reply;
  final List<Object?> row;
}

/// Asks the writer to close its connection and stop.
class _Shutdown {
  const _Shutdown(this.reply);

  final SendPort reply;
}
