import 'package:byte_beam_project/core/db/database_pulse.dart';
import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulator_config.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/presentation/bindings/ingest_binding.dart';
import 'package:byte_beam_project/features/telemetry_ingest/presentation/controllers/ingest_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../../duckdb_support.dart';

/// The wiring test.
///
/// Every layer has its own unit tests, and they all passed while the running
/// app ingested nothing: the controller was registered but never resolved, so
/// the lifecycle hook that used to start the feed never fired. This asserts
/// the thing those tests could not — that building the binding actually
/// starts the pipeline and rows reach the disk.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    Get.put(DatabasePulse(), permanent: true);
  });

  tearDown(() async {
    await Get.find<TelemetryLocalDataSource>().dispose();
    Get.reset();
    await db.close();
  });

  // A plain `test`, not `testWidgets`: the simulator runs on a real
  // `Timer.periodic` and the writer lives on a real isolate. The widget
  // tester's fake clock drives neither, so `testWidgets` hangs here forever.
  test('building the binding seeds the roster and starts the feed', () async {
    await IngestBinding(
      db: db,
      clock: const SystemClock(),
      config: const SimulatorConfig(
        vehicleCount: 5,
        tick: Duration(milliseconds: 20),
      ),
    ).dependenciesAsync();

    final controller = Get.find<IngestController>();
    expect(
      controller.isRunning.value,
      isTrue,
      reason: 'nobody opened a screen',
    );
    expect(controller.snapshot.value.vehicles, 5);

    // Let a few ticks land.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await controller.stop();

    expect(controller.batchesWritten.value, greaterThan(0));
    final onDisk = await db.read.query('SELECT count(*) FROM signal_reading');
    expect(
      (onDisk.fetchOne()!.first as num).toInt(),
      greaterThan(0),
      reason: 'the feed ran but nothing reached the database',
    );
  });
}
