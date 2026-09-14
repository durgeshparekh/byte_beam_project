import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/scale_controller.dart';

/// The scale exercise, as a debug action (§8).
///
/// A screen rather than a script because the numbers the brief asks for are
/// on-device numbers: cold start, the fleet query warm, and memory with the
/// list open. A script on my laptop measures my laptop.
class ScalePage extends GetView<ScaleController> {
  const ScalePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scale exercise'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Obx(
            () => controller.isBusy.value
                ? const LinearProgressIndicator(minHeight: 4)
                : const SizedBox(height: 4),
          ),
        ),
      ),
      // Said once, at the top, rather than on every button: all three of these
      // stop the simulator feed, because a measurement taken while something
      // else is writing is a measurement of both.
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
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Running any of these stops the telemetry feed. Restart it '
                'from the ingest monitor when you are done.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            _Action(
              title: 'Cold start',
              subtitle:
                  'main() to the first fleet list painted with vehicles, '
                  'stopped in a frame timings callback',
              rows: [
                (
                  'This launch',
                  controller.coldStart == null
                      ? 'not measured'
                      : '${controller.coldStart!.inMilliseconds} ms',
                ),
              ],
            ),
            _Action(
              title: 'Backfill',
              subtitle:
                  '${ScaleController.vehicles} vehicles x '
                  '${ScaleController.ticks} reports x 6 signals, generated '
                  'inside DuckDB at a ten-second cadence',
              button: 'Backfill',
              onPressed: controller.isBusy.value ? null : controller.backfill,
              rows: controller.backfillResult,
            ),
            _Action(
              title: 'Fleet query, warm',
              subtitle:
                  '${ScaleController.benchRuns} runs of both statements one '
                  'refresh issues, timed in the writer isolate',
              button: 'Benchmark',
              onPressed: controller.isBusy.value ? null : controller.benchmark,
              rows: [
                ...controller.benchResult,
                if (controller.csvPath.isNotEmpty)
                  ('CSV', controller.csvPath.value.split('/').last),
              ],
            ),
            _Action(
              title: 'Retention',
              subtitle:
                  'Readings past the window below summarised into five-minute '
                  'buckets, raw rows dropped, then CHECKPOINT',
              button: 'Compact',
              onPressed: controller.isBusy.value ? null : controller.compact,
              rows: controller.compactResult,
            ),
          ],
        ),
      ),
    );
  }
}

/// One measurement: what it is, what it did, and the button that runs it.
class _Action extends StatelessWidget {
  const _Action({
    required this.title,
    required this.subtitle,
    required this.rows,
    this.button,
    this.onPressed,
  });

  final String title;
  final String subtitle;
  final List<(String, String)> rows;
  final String? button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            Text(subtitle, style: theme.textTheme.bodySmall),
            if (rows.isNotEmpty) const Divider(height: 24),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodyMedium),
                    ),
                    Text(
                      value,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            if (button != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onPressed, child: Text(button!)),
            ],
          ],
        ),
      ),
    );
  }
}
