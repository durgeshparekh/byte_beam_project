import 'package:flutter/material.dart';

import '../../../../core/utils/format_age.dart';
import '../../domain/entities/signal_reading_row.dart';
import 'verdict_pill.dart';

/// One row of the readings register: label, value, its own age, and a verdict.
class ReadingRowTile extends StatelessWidget {
  const ReadingRowTile({required this.row, required this.now, super.key});

  final SignalReadingRow row;

  /// The instant the verdict was computed against. Ages are rendered from the
  /// same reading so a pill and its age can never contradict each other.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.label, style: theme.textTheme.bodyMedium),
                Text(
                  _age(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              _value(),
              textAlign: TextAlign.right,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Align(
              alignment: Alignment.centerRight,
              child: VerdictPill(verdict: row.verdict),
            ),
          ),
        ],
      ),
    );
  }

  /// An em dash, never a zero: a signal that has never reported has no value,
  /// and "0%" would read as an empty battery.
  String _value() {
    final value = row.value;
    if (value == null) return '—';
    // Ignition is a boolean riding in a DOUBLE column; rendering it as "1.0"
    // would be technically true and useless.
    if (row.signal == 'ignition') return value >= 0.5 ? 'On' : 'Off';
    final decimals = row.signal == 'odometer' ? 0 : 1;
    return '${value.toStringAsFixed(decimals)}${row.unit.isEmpty ? '' : ' ${row.unit}'}';
  }

  /// Age of this reading, phrased at the coarsest useful precision.
  String _age() {
    final age = row.ageAt(now);
    if (age == null) return 'never reported';
    return '${formatAge(age)} ago · stale after ${formatAge(row.maxAge)}';
  }
}
