import 'dart:isolate';

import 'package:dart_duckdb/dart_duckdb.dart';

import 'schema.dart';

/// The embedded database. One instance per process — DuckDB takes a file lock,
/// so extra isolates attach through [transferable] rather than reopening.
///
/// This library is deliberately Flutter-free so the DB tests run on the plain
/// Dart VM. The app supplies the file path (see `lib/main.dart`).
class FleetDb {
  FleetDb._(this._db, this.read);

  final Database _db;

  /// Read-only-by-convention connection for the UI isolate. DuckDB is MVCC,
  /// so this sees a consistent snapshot while the writer commits.
  final Connection read;

  /// Pass to [inIsolate] to get a connection on another isolate.
  TransferableDatabase get transferable => _db.transferable;

  /// Opens [path] (`:memory:` for a throwaway db) and migrates it forward.
  static Future<FleetDb> open(String path) async {
    final db = await duckdb.open(path);
    final conn = await duckdb.connect(db);
    await _migrate(conn);
    return FleetDb._(db, conn);
  }

  /// Runs [job] on its own isolate with its own connection.
  ///
  /// [job] must be a top-level or static function: it is sent across an
  /// isolate boundary, so anything it closes over has to be sendable too.
  static Future<R> inIsolate<R>(
    TransferableDatabase transferable,
    Future<R> Function(Connection) job,
  ) {
    return Isolate.run(() async {
      final conn = await duckdb.connectWithTransferred(transferable);
      try {
        return await job(conn);
      } finally {
        await conn.dispose();
      }
    });
  }

  Future<void> close() async {
    await read.dispose();
    await _db.dispose();
  }
}

/// Forward-only migrations, applied in one transaction each so a crash
/// mid-upgrade leaves the previous version intact rather than a half-schema.
Future<void> _migrate(Connection conn) async {
  await conn.execute(
    'CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY)',
  );
  final result = await conn.query(
    'SELECT coalesce(max(version), 0) FROM schema_version',
  );
  final applied = (result.fetchOne()!.first as num).toInt();

  for (var version = applied + 1; version <= migrations.length; version++) {
    await conn.execute('BEGIN TRANSACTION');
    try {
      await conn.execute(migrations[version - 1]);
      await conn.execute('INSERT INTO schema_version VALUES ($version)');
      await conn.execute('COMMIT');
    } catch (_) {
      await conn.execute('ROLLBACK');
      rethrow;
    }
  }
}

/// Runs a parameterised statement and discards the result.
///
/// Here rather than beside any one feature's SQL because three of them need
/// it. Parameters rather than interpolation because most of these carry a
/// timestamp, and interpolating one into SQL text is how time zones get lost.
Future<void> execPrepared(
  Connection conn,
  String sql,
  List<Object?> params,
) async {
  final statement = await conn.prepare(sql);
  try {
    statement.bindParams(params);
    await statement.execute();
  } finally {
    await statement.dispose();
  }
}
