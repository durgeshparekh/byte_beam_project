import 'package:flutter/material.dart';

import '../../../../core/utils/format_age.dart';
import '../../domain/entities/geofence.dart';

/// Where a vehicle is, and where it has been.
///
/// Two facts from two tables that must agree: the current fence comes from
/// containment, the crossings from the transition log, and containment is
/// nothing but the log folded up. If this panel ever contradicts itself the
/// detector has a bug, which is a reason to show them together.
class ZonePanel extends StatelessWidget {
  const ZonePanel({
    required this.currentGeofence,
    required this.visits,
    required this.now,
    super.key,
  });

  final String? currentGeofence;
  final List<GeofenceVisit> visits;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fence = currentGeofence;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                fence == null ? Icons.explore_outlined : Icons.my_location,
                size: 18,
                color: fence == null
                    ? theme.colorScheme.outline
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // "On the road" rather than "none": not being in a fence is
                  // a normal place for a truck to be, not missing data.
                  fence ?? 'On the road',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: fence == null ? theme.colorScheme.outline : null,
                  ),
                ),
              ),
            ],
          ),
          if (visits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'No crossings recorded yet.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (final visit in visits)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      visit.isEntry ? Icons.login : Icons.logout,
                      size: 15,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${visit.isEntry ? 'Entered' : 'Left'} '
                        '${visit.geofenceName}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      '${formatAge(now.difference(visit.at))} ago',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    // A crossing whose confirming pair straddled a reporting
                    // gap: it happened, but we are guessing when.
                    if (!visit.isConfident) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message:
                            'Confirmed across a reporting gap — the time '
                            'is approximate',
                        child: Icon(
                          Icons.help_outline,
                          size: 14,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
