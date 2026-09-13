import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../fleet/presentation/widgets/status_chip.dart';
import '../controllers/vehicle_detail_controller.dart';
import '../widgets/reading_row_tile.dart';
import '../widgets/soc_sparkline.dart';

/// One vehicle: status header, readings register, battery history.
///
/// Stateful so the subject is set once in `initState` rather than as a side
/// effect of `build`, which can run many times.
class VehicleDetailPage extends StatefulWidget {
  const VehicleDetailPage({required this.vehicleId, super.key});

  final String vehicleId;

  @override
  State<VehicleDetailPage> createState() => _VehicleDetailPageState();
}

class _VehicleDetailPageState extends State<VehicleDetailPage> {
  final _controller = Get.find<VehicleDetailController>();

  @override
  void initState() {
    super.initState();
    _controller.open(widget.vehicleId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(_controller.detail.value?.regNo ?? widget.vehicleId),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _controller.refreshNow,
          ),
        ],
      ),
      body: Obx(() {
        if (_controller.error.isNotEmpty) {
          return Center(child: Text(_controller.error.value));
        }
        if (_controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_controller.notFound.value) {
          return const Center(child: Text('No such vehicle in the roster.'));
        }

        final detail = _controller.detail.value!;
        final now = _controller.evaluatedAt.value!;

        return ListView(
          children: [
            _Header(
              model: detail.model,
              statusChip: StatusChip(status: detail.status),
              lastPing: detail.lastPing,
              now: now,
            ),
            const Divider(height: 1),
            _SectionTitle(
              title: 'Readings',
              subtitle: 'Each signal ages on its own clock',
            ),
            for (final row in detail.readings) ...[
              ReadingRowTile(row: row, now: now),
              const Divider(height: 1, indent: 16, endIndent: 16),
            ],
            _SectionTitle(
              title: 'Battery history',
              subtitle: 'Queried from the event log, bucketed in SQL',
            ),
            SocSparkline(history: detail.history),
            const SizedBox(height: 24),
          ],
        );
      }),
    );
  }
}

/// Model, status chip and vehicle-level last ping.
class _Header extends StatelessWidget {
  const _Header({
    required this.model,
    required this.statusChip,
    required this.lastPing,
    required this.now,
  });

  final String model;
  final Widget statusChip;
  final DateTime? lastPing;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(model, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  // Last ping is a register row in its own right, but it gets
                  // no verdict pill: the status chip beside it already makes
                  // the liveness claim, and two of them could disagree.
                  lastPing == null
                      ? 'Never reported'
                      : 'Last ping ${formatAge(now.difference(lastPing!))} ago',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          statusChip,
        ],
      ),
    );
  }
}

/// A section heading inside the scroll view.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
