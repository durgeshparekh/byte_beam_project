import 'package:flutter/material.dart';

import '../../../../core/utils/format_age.dart';
import '../../domain/entities/fleet_alert.dart';

/// One alert: what is wrong, on which truck, how bad, how long, and the only
/// thing you can do about it from here.
class AlertCard extends StatelessWidget {
  const AlertCard({
    required this.alert,
    required this.now,
    required this.onDismiss,
    this.onOpenVehicle,
    super.key,
  });

  final FleetAlert alert;

  /// The instant every age on the screen is measured against.
  final DateTime now;

  final VoidCallback onDismiss;

  /// Null on the vehicle detail screen — you are already there.
  final VoidCallback? onOpenVehicle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final critical = alert.severity == AlertSeverity.critical;
    final accent = critical ? theme.colorScheme.error : Colors.orange.shade700;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenVehicle,
        child: Container(
          // A left border rather than a tinted card: severity has to be readable
          // at a glance down a long list, and a full tint makes the text
          // underneath worse at exactly the moment it matters most.
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 5)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.type.label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    critical ? 'CRITICAL' : 'WARNING',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${alert.regNo} · ${_reading()}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text(_history(), style: theme.textTheme.bodySmall),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onDismiss,
                  child: const Text('Dismiss'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The triggering value, or an em dash if the vehicle has since stopped
  /// reporting the signal. Never a fabricated zero.
  String _reading() {
    final value = alert.value;
    if (value == null) return '—';
    // Prefixed rather than hidden when quiet: the value is what the alert was
    // raised on and is still the most useful number on the card.
    final rounded = value.abs() < 100
        ? value.toStringAsFixed(1)
        : '${value.round()}';
    final shown = alert.unit.isEmpty ? rounded : '$rounded${alert.unit}';
    return alert.isStaleAt(now) ? 'last known $shown' : shown;
  }

  /// Age, plus the escalation note or the silence note when there is one.
  String _history() {
    final raised = 'raised ${formatAge(alert.ageAt(now))} ago';
    // Silence outranks escalation in the one line available. An alert whose
    // signal has gone quiet is still open — no reading is not evidence of
    // recovery — but saying only "critical for 20m" would claim a live fact
    // from data the readings register is refusing to judge.
    if (alert.isStaleAt(now)) {
      final silence = alert.silenceAt(now);
      return silence == null
          ? '$raised · never reported since'
          : '$raised · no fresh reading for ${formatAge(silence)}';
    }
    final escalated = alert.escalatedAt;
    if (escalated == null) return raised;
    final since = formatAge(now.difference(escalated));
    return alert.hasEasedOff
        ? '$raised · eased off, was critical $since ago'
        : '$raised · critical for $since';
  }
}
