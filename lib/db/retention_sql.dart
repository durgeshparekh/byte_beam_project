/// Retention: what gets compacted, what gets dropped, and what is lost.
///
/// An append-only log grows forever. At 500 vehicles reporting six signals
/// every ten seconds that is about 26 million rows a day, so "keep everything"
/// is not a policy, it is a deferred outage.
///
/// The policy: **`signal_reading` keeps [hotWindow] at full resolution.**
/// Anything older is summarised into [bucket]-wide buckets per
/// `(vehicle, signal)` — count, min, max, average and last — and the raw rows
/// are dropped, followed by a `CHECKPOINT` so the space is actually returned
/// rather than left in the WAL.
///
/// What is lost is stated rather than buried: the sub-bucket *shape* of old
/// data, and with it the ability to re-derive geofence transitions or trips
/// outside the hot window. A crossing needs individual fixes; a five-minute
/// average of a latitude is not a position. That is why §10's ambiguity 5
/// rejects a packet older than the window instead of applying it — applying it
/// would produce derived state that no longer follows from the log.
///
/// A bucket holding a **single** reading is left alone. Its rollup row carries
/// four more columns than the raw row it would replace, so "compacting" it
/// makes the database bigger — which the first measurement of this did, by
/// 126 MiB, on a log sparser than the bucket width.
///
/// `location_fix` is **not** compacted. Averaging positions is meaningless,
/// and the honest options are keeping them or deleting them; this drops them
/// on the same horizon as the readings they cannot outlive the usefulness of.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

/// How much raw history stays queryable at full resolution.
const hotWindowDays = 7;

/// [hotWindowDays] as a duration. Both spellings because the constant is used
/// where a `Duration` is wanted and inside a `const` default, and `inMinutes`
/// is not a constant expression.
const hotWindow = Duration(days: hotWindowDays);

/// Bucket width for everything older.
const bucket = Duration(minutes: 5);

/// Summarises and then drops readings older than [now] − [keep].
///
/// Returns what it did: rows dropped, buckets written, and the file size
/// before and after, because a retention policy that does not shrink the file
/// is a claim rather than a measurement.
///
/// Idempotent. Running it twice finds nothing left to compact the second time,
/// and the `ON CONFLICT` makes a re-run over the same window rewrite identical
/// buckets rather than double-count them.
Future<Map<String, int>> compactSignalLog(
  Connection conn, {
  required DateTime now,
  Duration keep = hotWindow,
  Duration width = bucket,
}) async {
  final horizon = "TIMESTAMP '${now.subtract(keep).toIso8601String()}'";
  final bucketOf =
      "time_bucket(INTERVAL '${width.inSeconds} seconds', r.event_ts)";
  final before = await _databaseUse(conn);

  // Summarise and drop in one transaction: a crash between them would leave
  // buckets duplicating rows that are still live. The CHECKPOINT afterwards is
  // outside it, because it cannot run inside a transaction — and it is the
  // step that actually returns the pages rather than parking them in the WAL.
  await conn.execute('BEGIN TRANSACTION');
  final int dropped;
  final int fixes;
  try {
    await conn.execute('''
      INSERT INTO signal_rollup AS r
      SELECT vehicle_id,
             signal,
             time_bucket(INTERVAL '${width.inSeconds} seconds', event_ts),
             count(*),
             min(value),
             max(value),
             avg(value),
             arg_max(value, event_ts)
      FROM signal_reading
      WHERE event_ts < $horizon
      GROUP BY 1, 2, 3
      HAVING count(*) > 1
      ON CONFLICT (vehicle_id, signal, bucket_ts) DO UPDATE
        SET readings = excluded.readings,
            min_value = excluded.min_value,
            max_value = excluded.max_value,
            avg_value = excluded.avg_value,
            last_value = excluded.last_value
    ''');

    // Only the rows a bucket actually replaced. A reading alone in its
    // five-minute bucket is already at the policy's resolution, and its
    // rollup row carries four more columns than it does — summarising it
    // would make the database bigger, which the first measurement of this
    // did, by 126 MiB.
    dropped = await _countOf(conn, '''
      DELETE FROM signal_reading r
      WHERE r.event_ts < $horizon
        AND EXISTS (
          SELECT 1 FROM signal_rollup b
          WHERE b.vehicle_id = r.vehicle_id
            AND b.signal = r.signal
            AND b.bucket_ts = $bucketOf
        )
    ''');
    fixes = await _countOf(
      conn,
      'DELETE FROM location_fix WHERE event_ts < $horizon',
    );
    await conn.execute('COMMIT');
  } catch (_) {
    await conn.execute('ROLLBACK');
    rethrow;
  }

  await conn.execute('CHECKPOINT');

  final buckets = await conn.query('SELECT count(*) FROM signal_rollup');
  final after = await _databaseUse(conn);
  return {
    'readings_dropped': dropped,
    'fixes_dropped': fixes,
    'buckets': (buckets.fetchOne()!.first as num).toInt(),
    'used_before': before.$1,
    'used_after': after.$1,
    'file_after': after.$2,
  };
}

/// Bytes actually in use, and the size of the file holding them.
///
/// Two numbers because they move differently. DuckDB never returns blocks to
/// the operating system, so the *file* only ever grows — deleting a million
/// rows frees blocks for reuse and leaves the file exactly as large. Used
/// bytes is what falls, and it is what "the log stopped growing" means.
/// Reporting only the file size would make a working policy look broken.
///
/// `pragma_database_size` rather than `File.length()`, so this library stays
/// Flutter-free and answers for an in-memory database too.
Future<(int, int)> _databaseUse(Connection conn) async {
  final result = await conn.query('''
    SELECT used_blocks * block_size, database_size
    FROM pragma_database_size()
    WHERE database_name <> 'temp'
  ''');
  final row = result.fetchOne();
  if (row == null) return (0, 0);
  return (_bytesOf(row[0]), _bytesOf(row[1]));
}

/// Turns DuckDB's human-readable size into bytes.
///
/// The pragma returns text — "0 bytes", "12.3 MiB" — so this reads the number
/// and the one letter that scales it. An unrecognised unit reports 0 rather
/// than a wrong number, because a size that is silently off by 1024 is worse
/// than one that is obviously missing.
int _bytesOf(Object? value) {
  if (value is num) return value.toInt();
  final match = RegExp(
    r'^([\d.]+)\s*([KMGT]?)',
  ).firstMatch(value.toString().trim());
  if (match == null) return 0;
  const scale = {'': 1, 'K': 1024, 'M': 1048576, 'G': 1073741824};
  return (double.parse(match.group(1)!) * scale[match.group(2)]!).round();
}

/// Runs a mutating statement and returns the row count DuckDB reports.
Future<int> _countOf(Connection conn, String sql) async {
  final result = await conn.query(sql);
  final row = result.fetchOne();
  return row == null ? 0 : (row.first as num).toInt();
}
