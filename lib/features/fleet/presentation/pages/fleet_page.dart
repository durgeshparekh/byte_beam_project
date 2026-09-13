import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../telemetry_ingest/presentation/pages/ingest_page.dart';
import '../../../vehicle_detail/presentation/pages/vehicle_detail_page.dart';
import '../controllers/fleet_controller.dart';
import '../widgets/fleet_empty_state.dart';
import '../widgets/fleet_filter_bar.dart';
import '../widgets/vehicle_tile.dart';

/// Fleet home: where are my vehicles, are they okay, what needs attention.
class FleetPage extends GetView<FleetController> {
  const FleetPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet'),
        actions: [
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
