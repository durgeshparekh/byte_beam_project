import 'package:flutter/material.dart';

import '../../domain/entities/vehicle_status.dart';

/// The status pill on a fleet row.
///
/// Colour carries meaning here, so it is paired with a label rather than
/// standing alone — a colour-only signal is unreadable to a good fraction of
/// the people who operate a fleet.
class StatusChip extends StatelessWidget {
  const StatusChip({required this.status, super.key});

  final VehicleStatus status;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _colours(Theme.of(context));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Background and text colour for each state.
  ///
  /// OFFLINE is deliberately the flattest of the four: it means "we do not
  /// know", and a loud colour would read as "something is wrong with the
  /// truck" rather than "something is wrong with the link".
  (Color, Color) _colours(ThemeData theme) {
    final scheme = theme.colorScheme;
    return switch (status) {
      VehicleStatus.moving => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      VehicleStatus.idle => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      VehicleStatus.stopped => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      VehicleStatus.offline => (
        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        scheme.outline,
      ),
    };
  }
}

/// The alert badge on a fleet row, or nothing when the vehicle is healthy.
class AlertBadge extends StatelessWidget {
  const AlertBadge({required this.severity, super.key});

  final AlertSeverity? severity;

  @override
  Widget build(BuildContext context) {
    final value = severity;
    if (value == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final critical = value == AlertSeverity.critical;
    return Tooltip(
      message: critical ? 'Critical alert' : 'Warning',
      child: Icon(
        critical ? Icons.error : Icons.warning_amber_rounded,
        size: 18,
        color: critical ? scheme.error : scheme.tertiary,
      ),
    );
  }
}
