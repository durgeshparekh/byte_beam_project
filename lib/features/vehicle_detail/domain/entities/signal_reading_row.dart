import 'reading_verdict.dart';

/// One row of the readings register.
class SignalReadingRow {
  const SignalReadingRow({
    required this.signal,
    required this.label,
    required this.unit,
    required this.maxAge,
    this.value,
    this.eventTs,
    this.verdict,
  });

  /// Signal key, e.g. `soc`.
  final String signal;

  /// Human label, read from `signal_spec` rather than hard-coded here.
  final String label;

  /// Unit suffix. Empty for dimensionless signals like ignition.
  final String unit;

  /// How old this signal may get before it is [ReadingVerdict.stale].
  final Duration maxAge;

  /// Latest value, or null if this signal has never reported.
  final double? value;

  /// When that value was measured.
  final DateTime? eventTs;

  /// Null when the signal has never reported — that row shows "—" and no pill.
  final ReadingVerdict? verdict;

  /// True when nothing has ever arrived for this signal.
  bool get hasNeverReported => eventTs == null;

  /// Age of the reading at [now].
  Duration? ageAt(DateTime now) =>
      eventTs == null ? null : now.difference(eventTs!);
}
