/// Knobs for the packet simulator.
///
/// The fault rates are the point of the whole thing: a feed that behaves
/// perfectly proves nothing about a pipeline built to survive one that does
/// not. Defaults are deliberately nastier than a real fleet so the
/// duplicate/late counters move visibly within seconds.
class SimulatorConfig {
  const SimulatorConfig({
    this.vehicleCount = 40,
    this.tick = const Duration(milliseconds: 500),
    this.duplicateRate = 0.08,
    this.lateRate = 0.10,
    this.dropRate = 0.03,
    this.backlogChance = 0.004,
    this.backlogTicks = 20,
    this.seed = 1337,
    this.groundScale = 30,
  });

  /// Fleet size. 500 for the scale exercise; a few dozen for a readable demo.
  final int vehicleCount;

  /// How often the simulated fleet emits.
  final Duration tick;

  /// Fraction of packets delivered twice — the network retrying, not the
  /// vehicle measuring twice. The duplicate carries an identical event time,
  /// which is what makes the natural key able to reject it.
  final double duplicateRate;

  /// Fraction of packets held back and released a few ticks later, still
  /// stamped with their original event time. This is out-of-order arrival.
  final double lateRate;

  /// Fraction of packets that never arrive at all.
  final double dropRate;

  /// Per-vehicle per-tick chance of going dark (a basement) and buffering.
  final double backlogChance;

  /// How many ticks a dark vehicle stays dark before dumping its backlog.
  final int backlogTicks;

  /// Fixes every random decision, so a test run is reproducible and a failure
  /// can be replayed exactly.
  final int seed;

  /// How much faster a vehicle covers *ground* than its speedometer implies.
  ///
  /// The one deliberate lie in the simulator, and it is confined to the
  /// latitude and longitude. A truck at 60 km/h really does move eight metres
  /// in a 500 ms tick, which means a demo would need twenty minutes to show a
  /// single geofence crossing. Speed, odometer and battery drain stay tied to
  /// each other and to the honest figure; only the position runs ahead.
  ///
  /// Thirty, picked by measurement rather than taste. Heading wanders, so a
  /// vehicle's displacement grows with the square root of the tick count, not
  /// with it: at 15 the fleet covered ground but reached no fence inside a
  /// minute, and the end-to-end test caught that. At 30 a step is ~250 m,
  /// which still lands inside the smallest seeded fence — a 350 m bay — often
  /// enough for the single-decisive-fix rule to confirm it.
  ///
  /// Set to 1 for a physically consistent feed.
  final double groundScale;
}
