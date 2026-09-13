import 'package:flutter/material.dart';

import '../../domain/entities/soc_history.dart';

/// Battery history over the retained window.
///
/// Hand-painted rather than pulled from a charting package: one polyline with
/// a fill under it is about forty lines of `CustomPainter`, and a dependency
/// for that would be more code to audit than the code it replaces.
class SocSparkline extends StatelessWidget {
  const SocSparkline({required this.history, super.key});

  final SocHistory history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Text(
          'No battery readings in the retained window.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            // Saying how many raw rows fed how many plotted points is the
            // honest way to present a bucketed chart — and the visible proof
            // that this came out of the event log.
            '${history.readingCount} readings · ${history.points.length} points · '
            '${history.min.round()}–${history.max.round()}%',
            style: theme.textTheme.bodySmall,
          ),
        ),
        SizedBox(
          height: 120,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CustomPaint(
              size: Size.infinite,
              painter: _SparklinePainter(
                values: [for (final point in history.points) point.value],
                line: theme.colorScheme.primary,
                fill: theme.colorScheme.primary.withValues(alpha: 0.12),
                grid: theme.colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws the series against a fixed 0–100% axis.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.values,
    required this.line,
    required this.fill,
    required this.grid,
  });

  final List<double> values;
  final Color line;
  final Color fill;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    // A fixed axis, not one scaled to the data. Auto-scaling would make a
    // battery drifting between 61% and 63% look like a cliff.
    const minValue = 0.0;
    const maxValue = 100.0;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) return;

    final dx = size.width / (values.length - 1);
    double yFor(double value) =>
        size.height * (1 - (value - minValue) / (maxValue - minValue));

    final path = Path()..moveTo(0, yFor(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(dx * i, yFor(values[i]));
    }

    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);

    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.line != line;
}
