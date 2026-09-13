/// One leg between fences: left somewhere, arrived somewhere, or still going.
///
/// A trip is derived, never reported. Nothing in the packet stream says
/// "departed" — the vehicle only ever says where it is, and this is what falls
/// out of watching that against the fences (ARCHITECTURE.md §7.2).
class Trip {
  const Trip({
    required this.tripId,
    required this.vehicleId,
    required this.regNo,
    required this.startedAt,
    required this.isConfident,
    this.origin,
    this.destination,
    this.endedAt,
    this.distanceKm,
  });

  final String tripId;
  final String vehicleId;
  final String regNo;

  /// The fence the vehicle was last inside, or null when it was outside every
  /// fence we knew about at the time — a departure from nowhere in particular.
  final String? origin;

  /// Event time of the exit that emptied the vehicle's containment, which is
  /// when it actually left rather than when we became sure.
  final DateTime startedAt;

  /// Where it arrived, or null while it is still out there.
  final String? destination;

  /// When it arrived, or null. There is deliberately no timeout: a truck that
  /// never reports again keeps an open trip, because inventing an ending is
  /// worse than admitting we do not have one (§10, ambiguity 12).
  final DateTime? endedAt;

  /// Odometer delta across the leg, or null when the odometer did not report
  /// at one of the ends. For a running trip this is the distance **so far**.
  final double? distanceKm;

  /// False when either end was confirmed across a reporting gap longer than
  /// half an hour. The leg happened; its timing is approximate.
  final bool isConfident;

  bool get isRunning => endedAt == null;

  /// How long the leg took, or has taken so far.
  Duration elapsedAt(DateTime now) => (endedAt ?? now).difference(startedAt);
}
