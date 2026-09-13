import 'package:flutter/material.dart';

import '../../domain/entities/geofence.dart';

/// One fence: name, size, where it is, and how many trucks are in it now.
class GeofenceTile extends StatelessWidget {
  const GeofenceTile({
    required this.occupancy,
    required this.onEdit,
    required this.onToggleActive,
    super.key,
  });

  final GeofenceOccupancy occupancy;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fence = occupancy.fence;
    final muted = theme.colorScheme.outline;

    return ListTile(
      onTap: onEdit,
      // Deactivated fences stay on the list rather than disappearing: they are
      // retained so trip history can still name them, and a fence you cannot
      // see is a fence you cannot turn back on.
      leading: Icon(
        fence.isActive ? Icons.my_location : Icons.location_disabled,
        color: fence.isActive ? theme.colorScheme.primary : muted,
      ),
      title: Text(
        fence.name,
        style: theme.textTheme.titleMedium?.copyWith(
          color: fence.isActive ? null : muted,
        ),
      ),
      subtitle: Text(_subtitle(), style: theme.textTheme.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fence.isActive)
            _OccupancyBadge(count: occupancy.vehiclesInside)
          else
            Text(
              'off',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          IconButton(
            tooltip: fence.isActive ? 'Deactivate' : 'Reactivate',
            icon: Icon(
              fence.isActive ? Icons.toggle_on : Icons.toggle_off_outlined,
            ),
            onPressed: onToggleActive,
          ),
        ],
      ),
    );
  }

  /// Radius and centre. Six decimals is about 10 cm — enough to retype a
  /// centre exactly, which is the only reason the numbers are on screen.
  String _subtitle() {
    final fence = occupancy.fence;
    final radius = fence.radiusM >= 1000
        ? '${(fence.radiusM / 1000).toStringAsFixed(1)} km'
        : '${fence.radiusM.round()} m';
    return '$radius · ${fence.lat.toStringAsFixed(4)}, '
        '${fence.lon.toStringAsFixed(4)}';
  }
}

/// How many vehicles are inside, or nothing when the answer is none — an
/// empty depot does not need a zero shouted at it.
class _OccupancyBadge extends StatelessWidget {
  const _OccupancyBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (count == 0) {
      return Text('empty', style: theme.textTheme.labelSmall);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
