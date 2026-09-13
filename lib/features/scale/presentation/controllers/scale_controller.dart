import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/cold_start.dart';
import '../../../../db/retention_sql.dart';
import '../../../telemetry_ingest/data/datasources/telemetry_writer_isolate.dart';

/// Drives the scale exercise screen (§8).
///
/// **This is the one controller that talks to the writer directly**, with no
/// repository, no use case and no entity. That is deliberate rather than
/// sloppy: the domain layer exists to keep business rules independent of
/// storage, and there is no business rule called "generate two million fake
/// rows" or "time the fleet query". Wrapping a debug action in a use case
/// would be ceremony asserting an independence that does not exist — every one
/// of these operations is *about* the database.
class ScaleController extends GetxController {
  ScaleController({
    required TelemetryWriter writer,
    required DatabasePulse pulse,
    required Clock clock,
    required Future<void> Function() pauseFeed,
  }) : _writer = writer,
       _pulse = pulse,
       _clock = clock,
       _pauseFeed = pauseFeed;

  final TelemetryWriter _writer;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// Stops the simulator feed.
  ///
  /// Every action here pauses it first. A benchmark with a live feed writing
  /// underneath measures the feed as well as the query, and a two-million-row
  /// transaction with batches queueing behind it measures the queue.

  /// How many vehicles and reports each the backfill generates.
  ///
  /// 500 × 700 × 6 signals is 2.1 M rows, which is the brief's floor with a
  /// little over. Spread across seven days, so the retention horizon below has
  /// something on both sides of it.
  static const vehicles = 500;
  static const ticks = 700;

  /// Runs of the fleet query the benchmark times.
  static const benchRuns = 100;

  /// How much history the compaction keeps at full resolution.
  ///
  /// The policy is seven days ([hotWindow]). The override exists because a
  /// demonstration database does not have seven days of history in it — the
  /// backfill writes about two hours — and a retention action that always
  /// reports "nothing to do" proves nothing. It is a compile-time constant on
  /// a debug screen, not a setting.
  static const _keepMinutes = int.fromEnvironment(
    'SCALE_KEEP_MINUTES',
    defaultValue: hotWindowDays * 24 * 60,
  );

  /// True while any of the three actions is in flight. One flag rather than
  /// three: they all write, DuckDB takes one writer, and running two at once
  /// would queue anyway while the screen pretended otherwise.
  final isBusy = false.obs;

  /// What the last action did, as label/value rows.
  final backfillResult = <(String, String)>[].obs;
  final benchResult = <(String, String)>[].obs;
  final compactResult = <(String, String)>[].obs;

  /// Where the benchmark CSV was written, or empty.
  final csvPath = ''.obs;

  /// Last error, or empty.
  final error = ''.obs;

  final Future<void> Function() _pauseFeed;

  /// Cold start to the first painted fleet list, or null if that has not
  /// happened yet — which it always has by the time anyone reaches this
  /// screen, since it is three taps past the fleet list.
  Duration? get coldStart => coldStartElapsed;

  /// The brief's "script or debug action", as the script half.
  ///
  /// `flutter run -d macos --release --dart-define=SCALE_BENCH=true` runs the
  /// benchmark once the app has settled and prints the result, so a
  /// measurement is one command rather than a sequence of taps somebody has to
  /// perform identically every time. Compile-time constants, so a build
  /// without the defines contains none of this.
  static const _autoBackfill = bool.fromEnvironment('SCALE_BACKFILL');
  static const _autoBench = bool.fromEnvironment('SCALE_BENCH');
  static const _autoCompact = bool.fromEnvironment('SCALE_COMPACT');

  @override
  void onInit() {
    super.onInit();
    if (_autoBackfill || _autoBench || _autoCompact) unawaited(_autorun());
  }

  /// Runs whichever actions were asked for, in the order that makes sense:
  /// fill the database, measure it, then compact it and measure again.
  ///
  /// Delayed so the fleet list paints first — the cold-start number is the one
  /// measurement that a benchmark stealing the writer isolate would corrupt.
  Future<void> _autorun() async {
    await Future<void>.delayed(const Duration(seconds: 5));
    if (_autoBackfill) {
      await backfill();
      _report('backfill', backfillResult);
    }
    if (_autoBench) {
      await benchmark();
      _report('bench', benchResult);
      debugPrint('[scale] csv ${csvPath.value}');
    }
    if (_autoCompact) {
      await compact();
      _report('compact', compactResult);
    }
    if (error.isNotEmpty) debugPrint('[scale] error ${error.value}');
  }

  void _report(String label, List<(String, String)> rows) {
    for (final (name, value) in rows) {
      debugPrint('[scale] $label $name = $value');
    }
  }

  /// Generates the scale fleet and re-derives everything on top of it.
  Future<void> backfill() => _run(() async {
    final result = await _writer.backfill(
      now: _clock.nowUtc(),
      vehicles: vehicles,
      ticks: ticks,
    );
    backfillResult.value = [
      ('Vehicles', '${result['vehicles']}'),
      ('Signal rows', _thousands(result['signal_rows']!)),
      ('Location fixes', _thousands(result['location_rows']!)),
      ('Log load', '${result['load_ms']} ms'),
      ('Re-derive all', '${result['derive_ms']} ms'),
    ];
    // Everything on every screen just changed.
    _pulse.ping();
  });

  /// Times [benchRuns] fleet-list refreshes and writes every sample to CSV.
  ///
  /// Every sample, not just the percentiles: a p95 with no distribution behind
  /// it is a number nobody can argue with, which is the opposite of useful.
  Future<void> benchmark() => _run(() async {
    final timings = await _writer.benchFleetQuery(
      now: _clock.nowUtc(),
      runs: benchRuns,
    );
    final sorted = [...timings]..sort();
    benchResult.value = [
      ('Runs', '${sorted.length}'),
      ('p50', _ms(_percentile(sorted, 0.50))),
      ('p95', _ms(_percentile(sorted, 0.95))),
      ('p99', _ms(_percentile(sorted, 0.99))),
      ('min', _ms(sorted.first)),
      ('max', _ms(sorted.last)),
    ];
    csvPath.value = await _writeCsv(timings);
  });

  /// Applies the retention policy and reports what it reclaimed.
  Future<void> compact() => _run(() async {
    final result = await _writer.compact(
      now: _clock.nowUtc(),
      keepMinutes: _keepMinutes,
    );
    compactResult.value = [
      ('Kept at full resolution', _window(_keepMinutes)),
      ('Readings dropped', _thousands(result['readings_dropped']!)),
      ('Fixes dropped', _thousands(result['fixes_dropped']!)),
      ('Buckets kept', _thousands(result['buckets']!)),
      ('In use before', _mib(result['used_before']!)),
      ('In use after', _mib(result['used_after']!)),
      // The file itself never shrinks — DuckDB reuses freed blocks rather
      // than handing them back to the OS — so it is shown beside the number
      // that does move, not instead of it.
      ('File size', _mib(result['file_after']!)),
    ];
    _pulse.ping();
  });

  /// Shared tail: one busy flag, one error slot, and never a thrown exception
  /// reaching the widget tree.
  Future<void> _run(Future<void> Function() action) async {
    if (isBusy.value) return;
    isBusy.value = true;
    error.value = '';
    try {
      await _pauseFeed();
      await action();
    } catch (failure) {
      error.value = '$failure';
    }
    isBusy.value = false;
  }

  /// Writes one row per run beside the database file.
  ///
  /// Beside the database rather than in a share sheet because the reader of
  /// this file is me with a terminal, not a user.
  Future<String> _writeCsv(List<int> timings) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'fleet_query_bench.csv'));
    await file.writeAsString(
      [
        'run,micros',
        for (var i = 0; i < timings.length; i++) '$i,${timings[i]}',
      ].join('\n'),
    );
    return file.path;
  }
}

/// Nearest-rank percentile over an already-sorted list.
///
/// Nearest-rank rather than interpolated: with 100 samples the p95 is then an
/// actual observed run rather than a number halfway between two of them, and
/// "one of these hundred took this long" is the claim being made.
int _percentile(List<int> sorted, double fraction) =>
    sorted[((sorted.length * fraction).ceil() - 1).clamp(0, sorted.length - 1)];

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(2)} ms';

String _mib(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MiB';

String _thousands(int value) => value.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+$)'),
  (match) => '${match[1]} ',
);

/// "7 d" / "90 min", for the retention window the run actually used.
String _window(int minutes) =>
    minutes >= 1440 ? '${minutes ~/ 1440} d' : '$minutes min';
