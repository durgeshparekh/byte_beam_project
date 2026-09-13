import 'package:flutter/material.dart';

/// Shown when the list has nothing in it.
///
/// Two distinct cases, because they call for different words: a filter that
/// matched nothing is normal and self-correcting, while an empty fleet means
/// no telemetry has arrived at all.
class FleetEmptyState extends StatelessWidget {
  const FleetEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
  });

  /// No vehicle is currently in the selected state.
  const FleetEmptyState.filtered({Key? key, required String filterLabel})
    : this(
        key: key,
        icon: Icons.filter_alt_off_outlined,
        title: 'No vehicles are $filterLabel',
        message: 'Other filters still have vehicles in them.',
      );

  /// Nothing has been ingested yet.
  const FleetEmptyState.noFleet({Key? key})
    : this(
        key: key,
        icon: Icons.local_shipping_outlined,
        title: 'No vehicles yet',
        message:
            'Telemetry has not arrived. Start the feed from the '
            'ingest monitor.',
      );

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
