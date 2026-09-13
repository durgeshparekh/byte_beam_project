/// The five states a vehicle can be in on the fleet list.
///
/// The rules are first-match-wins, in this order, and they only ever consult
/// *fresh* readings — see `FleetLocalDataSource` for the SQL and
/// ARCHITECTURE.md §10 ambiguity 1 for why a stale speed cannot claim MOVING.
enum VehicleStatus {
  /// Vehicle-level last ping older than 10 minutes. Outranks everything: if we
  /// have not heard from the truck, nothing else we know about it is a claim
  /// worth making.
  offline,

  /// Fresh speed above zero.
  moving,

  /// Fresh speed of zero with fresh ignition on.
  idle,

  /// Ignition off — and the documented fallback when the deciding signals are
  /// too old to judge.
  stopped;

  /// Parses the string the SQL `CASE` produces.
  static VehicleStatus fromSql(String value) => switch (value) {
    'OFFLINE' => VehicleStatus.offline,
    'MOVING' => VehicleStatus.moving,
    'IDLE' => VehicleStatus.idle,
    'STOPPED' => VehicleStatus.stopped,
    _ => throw ArgumentError('unknown status: $value'),
  };

  /// The token used in SQL, so the mapping lives in one place.
  String get sqlName => switch (this) {
    VehicleStatus.offline => 'OFFLINE',
    VehicleStatus.moving => 'MOVING',
    VehicleStatus.idle => 'IDLE',
    VehicleStatus.stopped => 'STOPPED',
  };

  /// Label for the status chip.
  String get label => switch (this) {
    VehicleStatus.offline => 'Offline',
    VehicleStatus.moving => 'Moving',
    VehicleStatus.idle => 'Idle',
    VehicleStatus.stopped => 'Stopped',
  };
}

/// Severity of the worst live threshold breach on a vehicle.
///
/// Drives the badge on the fleet list. Today it is computed from
/// `signal_spec` thresholds against fresh readings; once the alerts feature
/// owns an alert lifecycle (raise, escalate, dismiss, resolve) the badge reads
/// open alerts from the `alert` table instead. The thresholds themselves stay
/// in `signal_spec` either way, so there is one definition, not two.
enum AlertSeverity {
  warning,
  critical;

  static AlertSeverity? fromSql(String? value) => switch (value) {
    'warning' => AlertSeverity.warning,
    'critical' => AlertSeverity.critical,
    _ => null,
  };
}
