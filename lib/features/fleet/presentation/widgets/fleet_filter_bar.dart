import 'package:flutter/material.dart';

import '../../domain/entities/fleet_filter.dart';
import '../../domain/entities/fleet_overview.dart';

/// The chip row. Each chip carries its live count, computed in SQL over the
/// whole fleet rather than over the rows currently on screen.
class FleetFilterBar extends StatelessWidget {
  const FleetFilterBar({
    required this.overview,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final FleetOverview overview;
  final FleetFilter selected;
  final ValueChanged<FleetFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final filter in FleetFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: filter == selected,
                onSelected: (_) => onSelected(filter),
                showCheckmark: false,
                label: Text('${filter.label}  ${overview.countFor(filter)}'),
              ),
            ),
        ],
      ),
    );
  }
}
