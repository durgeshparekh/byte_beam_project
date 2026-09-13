import 'package:flutter/material.dart';

import '../../domain/entities/reading_verdict.dart';

/// The verdict pill on a register row, or nothing when the signal has never
/// reported.
///
/// STALE is grey on purpose. It is not a milder alert — it is a refusal to
/// judge, and giving it a warning colour would make "we do not know" look like
/// "something is slightly wrong".
class VerdictPill extends StatelessWidget {
  const VerdictPill({required this.verdict, super.key});

  final ReadingVerdict? verdict;

  @override
  Widget build(BuildContext context) {
    final value = verdict;
    if (value == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (value) {
      ReadingVerdict.normal => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ReadingVerdict.alert => (scheme.errorContainer, scheme.onErrorContainer),
      ReadingVerdict.stale => (scheme.surfaceContainerHighest, scheme.outline),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        value.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
