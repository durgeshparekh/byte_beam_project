import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/trips_controller.dart';
import '../widgets/trip_tile.dart';

/// Every leg the fleet has driven, running ones first.
class TripsPage extends GetView<TripsController> {
  const TripsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trips'),
        actions: [
          Obx(
            () => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text('${controller.runningCount} running')),
            ),
          ),
        ],
      ),
      body: Obx(() {
        if (controller.error.isNotEmpty) {
          return Center(child: Text(controller.error.value));
        }
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.trips.isEmpty) {
          // Says what has to happen rather than just that nothing has. A trip
          // needs a vehicle to leave every fence it was in, which on a fresh
          // database has genuinely not happened yet.
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No trips yet. One starts when a vehicle leaves the last '
                'geofence it was inside.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final now = controller.evaluatedAt.value ?? DateTime.now().toUtc();
        return ListView.separated(
          itemCount: controller.trips.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) =>
              TripTile(trip: controller.trips[index], now: now),
        );
      }),
    );
  }
}
