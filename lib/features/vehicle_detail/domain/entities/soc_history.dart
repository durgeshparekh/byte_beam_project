/// One plotted point: a time bucket and the mean SOC inside it.
class SocPoint {
  const SocPoint({required this.at, required this.value});

  /// Earliest event time in the bucket.
  final DateTime at;

  /// Mean state of charge across the bucket, %.
  final double value;
}

/// Battery history over the queried window.
///
/// Carries [readingCount] alongside [points] deliberately: the chart is a
/// bucketed summary, and showing how many raw log rows it came from is the
/// honest way to present it — and the visible proof that this screen queries
/// the event log rather than the latest-value table.
class SocHistory {
  const SocHistory({
    required this.points,
    required this.readingCount,
    required this.from,
    required this.to,
  });

  const SocHistory.empty()
    : points = const [],
      readingCount = 0,
      from = null,
      to = null;

  /// Bucketed series, oldest first.
  final List<SocPoint> points;

  /// Raw `signal_reading` rows the buckets were built from.
  final int readingCount;

  /// Oldest and newest event time in the window, or null when empty.
  final DateTime? from;
  final DateTime? to;

  bool get isEmpty => points.isEmpty;

  /// Lowest plotted value, for the chart's axis and the summary line.
  double get min => points.map((p) => p.value).reduce((a, b) => a < b ? a : b);

  /// Highest plotted value.
  double get max => points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
}
