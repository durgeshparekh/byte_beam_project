/// What one ingest batch actually did.
///
/// The counts are not cosmetic. `offered` minus `applied` is the duplicate
/// count, which is the visible proof that re-delivering a packet is a no-op —
/// the property the whole late/duplicate/out-of-order story rests on (§0).
class IngestReceipt {
  const IngestReceipt({
    required this.packets,
    required this.signalRowsOffered,
    required this.signalRowsApplied,
    required this.locationRowsOffered,
    required this.locationRowsApplied,
    required this.lateVehicles,
    required this.duration,
  });

  /// An empty receipt, for a batch that contained nothing.
  const IngestReceipt.empty()
    : packets = 0,
      signalRowsOffered = 0,
      signalRowsApplied = 0,
      locationRowsOffered = 0,
      locationRowsApplied = 0,
      lateVehicles = 0,
      duration = Duration.zero;

  /// How many packets were in the batch.
  final int packets;

  /// Signal rows the batch contained after de-duplicating within the batch.
  final int signalRowsOffered;

  /// Signal rows that were genuinely new. The rest collided with the natural
  /// key and were dropped by the database, not by application code.
  final int signalRowsApplied;

  final int locationRowsOffered;
  final int locationRowsApplied;

  /// Vehicles in this batch that reported an event time *behind* the position
  /// derivation had already reached. These are the ones whose geofence
  /// transitions and trips will need replaying once derivation exists (§4
  /// step 4). Counted now so the number is visible from the first commit.
  final int lateVehicles;

  /// Wall-clock time the batch took, measured in the writer isolate.
  final Duration duration;

  /// Rows rejected as duplicates — the difference between what was offered
  /// and what the database accepted.
  int get duplicateRows =>
      (signalRowsOffered - signalRowsApplied) +
      (locationRowsOffered - locationRowsApplied);

  @override
  String toString() =>
      'IngestReceipt($packets packets, '
      '${signalRowsApplied + locationRowsApplied} applied, '
      '$duplicateRows duplicates, $lateVehicles late, ${duration.inMilliseconds}ms)';
}
