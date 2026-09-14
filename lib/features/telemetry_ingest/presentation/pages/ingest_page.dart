import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../scale/presentation/pages/scale_page.dart';
import '../controllers/ingest_controller.dart';

/// Ingest monitor.
///
/// A developer screen, not a product one — it exists so the pipeline's
/// behaviour is visible while the real features are built. The two columns
/// matter: session counters are what this run saw, the snapshot is what a
/// fresh query against DuckDB returns. They are shown side by side because a
/// local-first app is only correct if the second one is the truth.
class IngestPage extends GetView<IngestController> {
  const IngestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Telemetry ingest'),
        actions: [
          IconButton(
            tooltip: 'Scale exercise',
            icon: const Icon(Icons.speed_outlined),
            onPressed: () => Get.to(() => const ScalePage()),
          ),
          Obx(
            () => IconButton(
              tooltip: controller.isRunning.value ? 'Stop feed' : 'Start feed',
              icon: Icon(
                controller.isRunning.value ? Icons.pause : Icons.play_arrow,
              ),
              onPressed: () => controller.isRunning.value
                  ? controller.stop()
                  : controller.start(),
            ),
          ),
        ],
      ),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (controller.error.isNotEmpty)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(controller.error.value),
                ),
              ),
            _Section(
              title: 'This session',
              subtitle:
                  'What the feed delivered and what the writer did with it',
              rows: [
                ('Batches written', '${controller.batchesWritten}'),
                ('Packets received', '${controller.packetsReceived}'),
                ('Rows applied', '${controller.rowsApplied}'),
                ('Duplicates rejected', '${controller.duplicatesRejected}'),
                ('Orphans dropped', '${controller.orphansDropped}'),
                ('Late vehicles', '${controller.lateVehicles}'),
                ('Last batch', '${controller.lastBatchMs} ms'),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              title: 'On disk',
              subtitle: 'Read back from DuckDB after every batch',
              rows: [
                ('Vehicles', '${controller.snapshot.value.vehicles}'),
                ('Signal rows', '${controller.snapshot.value.signalRows}'),
                ('Location fixes', '${controller.snapshot.value.locationRows}'),
                (
                  'Newest event',
                  controller.snapshot.value.newestEventTs
                          ?.toIso8601String()
                          .substring(11, 19) ??
                      '—',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled group of label/value rows.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.rows,
  });

  final String title;
  final String subtitle;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
