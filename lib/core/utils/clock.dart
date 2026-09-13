/// Wall-clock access, injected rather than called statically.
///
/// Freshness, the OFFLINE rule and alert evaluation all compare event time
/// against "now". Tests need to control that comparison, and the packet
/// simulator needs to generate history relative to it, so nothing in this
/// codebase calls `DateTime.now()` directly.
abstract class Clock {
  /// The current instant, in UTC. Always UTC: DuckDB `TIMESTAMP` columns carry
  /// no zone, so mixing local time in would make comparisons silently wrong.
  DateTime nowUtc();
}

/// The real clock, used everywhere outside tests.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// A clock the caller advances by hand, for deterministic tests.
class FakeClock implements Clock {
  FakeClock(this._now);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  /// Moves the clock forward by [delta].
  void advance(Duration delta) => _now = _now.add(delta);
}
