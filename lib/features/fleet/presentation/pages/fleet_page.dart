import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';

import '../../../alerts/presentation/controllers/alerts_controller.dart';
import '../../../alerts/presentation/pages/alerts_page.dart';
import '../../../geofence/presentation/pages/geofences_page.dart';
import '../../../../core/utils/cold_start.dart';
import '../../../telemetry_ingest/presentation/pages/ingest_page.dart';
import '../../../trips/presentation/pages/trips_page.dart';
import '../../../vehicle_detail/presentation/pages/vehicle_detail_page.dart';
import '../controllers/fleet_controller.dart';
import '../widgets/fleet_empty_state.dart';
import '../widgets/fleet_filter_bar.dart';
import '../widgets/vehicle_tile.dart';

/// Registers a one-shot timings callback that stops the cold-start clock.
///
/// One-shot: it removes itself, and [markFleetPainted] ignores anything after
/// the first call anyway. Two guards because this is called from a build
/// method, which runs far more often than it needs to.
void _stopColdStartAfterThisFrame() {
  if (coldStartElapsed != null || !coldStart.isRunning) return;
  late final TimingsCallback callback;
  callback = (_) {
    markFleetPainted();
    SchedulerBinding.instance.removeTimingsCallback(callback);
  };
  SchedulerBinding.instance.addTimingsCallback(callback);
}

/// Fleet home: where are my vehicles, are they okay, what needs attention.
class FleetPage extends GetView<FleetController> {
  const FleetPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet'),
        actions: [
          const _AlertsAction(),
          IconButton(
            tooltip: 'Geofences',
            icon: const Icon(Icons.map_outlined),
            onPressed: () => Get.to(() => const GeofencesPage()),
          ),
          IconButton(
            tooltip: 'Trips',
            icon: const Icon(Icons.route_outlined),
            onPressed: () => Get.to(() => const TripsPage()),
          ),
          IconButton(
            tooltip: 'Ingest monitor',
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => Get.to(() => const IngestPage()),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Obx(
            () => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FleetFilterBar(
                overview: controller.overview.value,
                selected: controller.filter.value,
                onSelected: controller.select,
              ),
            ),
          ),
        ),
      ),
      body: Obx(() {
        if (controller.error.isNotEmpty) {
          return Center(child: Text(controller.error.value));
        }
        // "Still loading" and "genuinely empty" look identical on screen if
        // they share a widget, and only one of them is worth explaining.
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        final overview = controller.overview.value;
        if (overview.isFleetEmpty) return const FleetEmptyState.noFleet();
        if (overview.isFilteredEmpty) {
          return FleetEmptyState.filtered(
            filterLabel: overview.filter.label.toLowerCase(),
          );
        }

        // Cold start stops here, on the first frame that actually shows
        // vehicles. A timings callback rather than a post-frame one because
        // it fires after the frame is *rasterised*, and "painted" is the word
        // in the brief (§8).
        _stopColdStartAfterThisFrame();

        return ListView.separated(
          itemCount: overview.vehicles.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final summary = overview.vehicles[index];
            return VehicleTile(
              summary: summary,
              onTap: () =>
                  Get.to(() => VehicleDetailPage(vehicleId: summary.vehicleId)),
            );
          },
        );
      }),
    );
  }
}

/// The alerts entry point, carrying the open count.
///
/// Reads the alerts controller rather than the fleet overview: the fleet query
/// knows which vehicles have a badge, not how many alerts there are, and a
/// vehicle can have two.
class _AlertsAction extends StatelessWidget {
  const _AlertsAction();

  @override
  Widget build(BuildContext context) {
    final alerts = Get.find<AlertsController>();
    return Obx(() {
      final count = alerts.openCount;
      final button = IconButton(
        tooltip: 'Alerts',
        icon: const Icon(Icons.notifications_outlined),
        onPressed: () => Get.to(() => const AlertsPage()),
      );
      if (count == 0) return button;
      return Badge.count(
        count: count,
        backgroundColor: alerts.hasCritical
            ? Theme.of(context).colorScheme.error
            : Colors.orange.shade700,
        child: button,
      );
    });
  }
}
