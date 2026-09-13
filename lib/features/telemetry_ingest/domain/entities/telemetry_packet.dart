/// One timestamped emission from one vehicle, carrying a subset of signals.
///
/// This is the unit the whole pipeline is built around. It is deliberately a
/// plain value object with no framework types: it crosses an isolate boundary
/// on its way to the writer, so every field has to be sendable.
class TelemetryPacket {
  const TelemetryPacket({
    required this.vehicleId,
    required this.eventTs,
    this.signals = const {},
    this.location,
  });

  /// Which truck emitted this.
  final String vehicleId;

  /// When the vehicle *measured* these values, in UTC — not when we received
  /// them. Every rule in the app keys off event time; arrival time is audit
  /// only (ARCHITECTURE.md §10, ambiguity 3).
  final DateTime eventTs;

  /// Signal name to value, e.g. `{'soc': 54.0, 'speed': 0.0}`. Booleans travel
  /// as 0/1 doubles because `signal_reading.value` is a single DOUBLE column.
  /// A packet carries whatever the vehicle had to say — never all six signals.
  final Map<String, double> signals;

  /// Where the vehicle was, when it reported a position. Location is separate
  /// from [signals] because it is a triple, not a scalar, and pairing lat/lon
  /// rows back together by timestamp would be pointless work (§2).
  final GeoFix? location;

  /// True when this packet carries nothing worth storing — the simulator can
  /// produce these when a vehicle has no fresh readings to report.
  bool get isEmpty => signals.isEmpty && location == null;

  @override
  String toString() =>
      'TelemetryPacket($vehicleId @ ${eventTs.toIso8601String()}, '
      '${signals.length} signals${location == null ? '' : ' + fix'})';
}

/// A single GPS reading.
class GeoFix {
  const GeoFix({required this.lat, required this.lon, this.accuracyM});

  final double lat;
  final double lon;

  /// Reported horizontal accuracy in metres, when the vehicle supplies it.
  ///
  /// Geofence evaluation uses this twice: as a gate (fixes worse than 100 m
  /// are ignored) and as the hysteresis width (§7.1). A null accuracy is
  /// treated as "unknown", not as "perfect".
  final double? accuracyM;
}
