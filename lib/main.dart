import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/db/database_pulse.dart';
import 'db/fleet_db.dart';
import 'features/alerts/presentation/bindings/alerts_binding.dart';
import 'features/fleet/presentation/bindings/fleet_binding.dart';
import 'features/fleet/presentation/pages/fleet_page.dart';
import 'features/telemetry_ingest/presentation/bindings/ingest_binding.dart';
import 'features/vehicle_detail/presentation/bindings/vehicle_detail_binding.dart';

/// Opens the database and builds the object graph before the first frame.
///
/// Deliberately not lazy. Opening DuckDB and spawning the writer isolate are
/// both async, and a screen that builds before its writer exists would have to
/// carry a "not ready yet" state that never means anything useful.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await FleetDb.open(await databasePath());
  Get.put<FleetDb>(db, permanent: true);
  Get.put(DatabasePulse(), permanent: true);

  // Ingest first: it spawns the writer the alerts feature dismisses through.
  await IngestBinding(db: db).dependenciesAsync();
  AlertsBinding(db: db).dependencies();
  FleetBinding(db: db).dependencies();
  VehicleDetailBinding(db: db).dependencies();

  runApp(const FleetConsoleApp());
}

/// Where the database lives. Application support, not documents or cache:
/// it is app-private state the OS must not evict.
Future<String> databasePath() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return p.join(dir.path, 'fleet.duckdb');
}

/// Root widget. `GetMaterialApp` rather than `MaterialApp` so routes and
/// bindings go through GetX.
class FleetConsoleApp extends StatelessWidget {
  const FleetConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Fleet Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const FleetPage(),
    );
  }
}
