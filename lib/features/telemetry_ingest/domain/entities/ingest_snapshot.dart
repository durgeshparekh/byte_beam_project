/// A cheap summary of what is actually on disk right now.
///
/// Read straight from DuckDB rather than accumulated in memory: the point of
/// a local-first app is that the database is the source of truth, so the
/// counters on screen have to come from it and not from a running tally that
/// happens to agree (§2 of the brief).
class IngestSnapshot {
  const IngestSnapshot({
    required this.vehicles,
    required this.signalRows,
    required this.locationRows,
    required this.newestEventTs,
  });

  const IngestSnapshot.empty()
    : vehicles = 0,
      signalRows = 0,
      locationRows = 0,
      newestEventTs = null;

  /// Rows in the fleet roster.
  final int vehicles;

  /// Rows in the append-only signal log.
  final int signalRows;

  /// Rows in the location log.
  final int locationRows;

  /// Newest event time anywhere in the log, or null on an empty database.
  final DateTime? newestEventTs;
}
