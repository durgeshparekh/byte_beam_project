import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../db/fleet_db.dart';
import '../../data/datasources/simulated_packet_source.dart';
import '../../data/datasources/simulator_config.dart';
import '../../data/datasources/telemetry_local_data_source.dart';
import '../../data/datasources/telemetry_packet_source.dart';
import '../../data/datasources/telemetry_writer_isolate.dart';
import '../../data/repositories/telemetry_repository_impl.dart';
import '../../domain/repositories/telemetry_repository.dart';
import '../../domain/usecases/get_ingest_snapshot.dart';
import '../../domain/usecases/ingest_packet_batch.dart';
import '../../domain/usecases/observe_telemetry.dart';
import '../../domain/usecases/seed_fleet.dart';
import '../../../scale/presentation/controllers/scale_controller.dart';
import '../controllers/ingest_controller.dart';

/// Wires the feature together.
///
/// This is the only place the concrete classes are named. Everything else asks
/// for an interface, which is what makes the dependency arrows in this feature
/// point inwards: presentation to domain, data to domain, never the reverse.
///
/// Registered eagerly rather than lazily because spawning the writer isolate
/// is async and the screen must not build before it is ready.
class IngestBinding extends Bindings {
  IngestBinding({
    required this.db,
    this.config = const SimulatorConfig(),
    this.clock = const SystemClock(),
  });

  final FleetDb db;
  final SimulatorConfig config;
  final Clock clock;

  /// Builds and registers the object graph.
  ///
  /// Async because the writer isolate has to be up before the controller can
  /// write anything; call it and await it before navigating to the page.
  Future<void> dependenciesAsync() async {
    final local = await DuckDbTelemetryLocalDataSource.create(db);
    final source = SimulatedPacketSource(clock: clock, config: config);

    Get.put<TelemetryLocalDataSource>(local, permanent: true);
    // The single writer, registered on its own so the alerts feature can send
    // dismissals through it without going via this feature's repository.
    Get.put<TelemetryWriter>(local.writer, permanent: true);
    Get.put<TelemetryPacketSource>(source, permanent: true);
    Get.put<TelemetryRepository>(
      TelemetryRepositoryImpl(local: local, source: source, clock: clock),
      permanent: true,
    );

    final repository = Get.find<TelemetryRepository>();
    final controller = Get.put(
      IngestController(
        seedFleet: SeedFleet(repository),
        observeTelemetry: ObserveTelemetry(repository),
        ingestPacketBatch: IngestPacketBatch(repository),
        getIngestSnapshot: GetIngestSnapshot(repository),
        roster: source.fleet,
        pulse: Get.find<DatabasePulse>(),
      ),
      permanent: true,
    );

    // The scale exercise's debug actions. Registered by this binding because
    // it owns both the writer they run through and the feed they have to stop
    // first, and permanent because the cold start it reports is a property of
    // the launch rather than of the screen.
    Get.put(
      ScaleController(
        writer: local.writer,
        pulse: Get.find<DatabasePulse>(),
        clock: clock,
        pauseFeed: controller.stop,
      ),
      permanent: true,
    );

    // Start the pipeline here rather than relying on a lifecycle hook: the
    // feed must run even though its monitor screen is not the home screen.
    await controller.bootstrap();
  }

  /// GetX's synchronous hook. The graph is built in [dependenciesAsync] before
  /// the route is pushed, so there is nothing left to do here.
  @override
  void dependencies() {}
}
