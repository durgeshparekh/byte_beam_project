import 'package:flutter/material.dart';

import '../../../../core/utils/format_age.dart';
import '../../domain/entities/trip.dart';

/// One leg, as a list row.
///
/// The same widget on the trips screen and on vehicle detail, with the
/// registration hidden on the latter — two spellings of one row is how the
/// same trip ends up looking like two different trips.
class TripTile extends StatelessWidget {
  const TripTile({
    required this.trip,
    required this.now,
    this.showVehicle = true,
    super.key,
  });

  final Trip trip;

  /// The instant durations are measured against, passed in so every row on the
  /// screen agrees rather than each one asking the clock as it builds.
  final DateTime now;

  final bool showVehicle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = trip.isRunning;

    return ListTile(
      leading: Icon(
        running ? Icons.local_shipping_outlined : Icons.route_outlined,
        color: running ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              // "Open road" rather than "unknown": departing from outside
              // every fence is a normal thing for a truck to do, not a gap in
              // the data. An unfinished leg has no destination yet, and saying
              // so beats naming one we have not seen.
              '${trip.origin ?? 'Open road'} → '
              '${trip.destination ?? (running ? 'under way' : 'open road')}',
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!trip.isConfident)
            Tooltip(
              message:
                  'One end was confirmed across a reporting gap — the '
                  'timing is approximate',
              child: Icon(
                Icons.help_outline,
                size: 15,
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
      subtitle: Text(
        [
          if (showVehicle) trip.regNo,
          running
              ? 'running ${formatAge(trip.elapsedAt(now))}'
              : 'took ${formatAge(trip.elapsedAt(now))}',
          // Null rather than 0 when the odometer did not report at an end:
          // "we do not know" and "it did not move" are different answers.
          if (trip.distanceKm != null)
            '${trip.distanceKm!.toStringAsFixed(1)} km'
          else
            'distance unknown',
          // Only once the leg is over. For a running trip "started 2h ago" and
          // "running 2h" are the same number, and a row that says it twice
          // reads as though one of them means something else.
          if (!running) '${formatAge(now.difference(trip.startedAt))} ago',
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: running
          ? Chip(
              label: const Text('Running'),
              visualDensity: VisualDensity.compact,
              backgroundColor: theme.colorScheme.primaryContainer,
              side: BorderSide.none,
            )
          : null,
    );
  }
}
