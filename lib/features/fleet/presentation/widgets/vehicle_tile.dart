import 'package:flutter/material.dart';

import '../../domain/entities/fleet_vehicle_summary.dart';
import 'status_chip.dart';

/// One row of the fleet list: registration and model, battery and range, an
/// alert badge, and the status chip.
class VehicleTile extends StatelessWidget {
  const VehicleTile({required this.summary, this.onTap, super.key});

  final FleetVehicleSummary summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      title: Row(
        children: [
          Expanded(
            child: Text(summary.regNo, style: theme.textTheme.titleMedium),
          ),
          AlertBadge(severity: summary.alertSeverity),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${summary.model} · ${_soc()} · ${_range()}',
          style: theme.textTheme.bodySmall,
        ),
      ),
      trailing: StatusChip(status: summary.status),
    );
  }

  /// A signal that has never reported shows an em dash, never a zero — a
  /// fabricated zero reads as "empty battery".
  String _soc() =>
      summary.soc == null ? 'SOC —' : 'SOC ${summary.soc!.round()}%';

  String _range() =>
      summary.rangeKm == null ? 'Range —' : '${summary.rangeKm!.round()} km';
}
