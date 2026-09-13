import '../../../fleet/domain/entities/vehicle_status.dart';

export '../../../fleet/domain/entities/vehicle_status.dart' show AlertSeverity;

/// What the alert is about.
///
/// Two types, both battery. The SOC bands are deliberately *not* two types:
/// "SOC below 20" and "SOC below 10" are one escalating alert, which the
/// evaluator expresses by moving [FleetAlert.severity] on a single row.
enum AlertType {
  batteryLow('battery_low', 'Low battery'),
  batteryOverheat('battery_overheat', 'Battery overheating');

  const AlertType(this.sqlName, this.label);

  /// The token stored in `alert.alert_type`.
  final String sqlName;

  /// Card heading.
  final String label;

  static AlertType fromSql(String value) =>
      values.firstWhere((type) => type.sqlName == value);
}

/// The three answers the dismissal sheet offers, in the order it offers them.
///
/// The order is from the brief and is asserted by a test: "I am on it" is the
/// common case and goes first, "Wrong alert" is the feedback case, and the
/// free-text escape hatch goes last where it will not be picked by accident.
enum DismissReason {
  onIt('on_it', 'I am on it'),
  wrongAlert('wrong_alert', 'Wrong alert'),
  somethingElse('other', 'Something else…');

  const DismissReason(this.code, this.label);

  /// Stored in `alert.dismiss_reason`.
  final String code;

  final String label;

  /// What actually gets written, with [note] appended for [somethingElse].
  ///
  /// One column rather than two: a free-text note is part of the reason, and a
  /// second column would need a migration to hold something the first can.
  String stored([String? note]) =>
      note == null || note.isEmpty ? code : '$code: $note';
}

/// One open alert, as the alerts screen shows it.
///
/// Carries the vehicle's registration and the triggering reading, because an
/// alert that says only "critical" makes the reader open another screen to
/// find out what is wrong.
class FleetAlert {
  const FleetAlert({
    required this.alertId,
    required this.vehicleId,
    required this.regNo,
    required this.type,
    required this.severity,
    required this.raisedAt,
    required this.unit,
    required this.maxAge,
    this.escalatedAt,
    this.value,
    this.readingAt,
  });

  final String alertId;
  final String vehicleId;
  final String regNo;
  final AlertType type;

  /// Current severity. Moves on the same row as the condition worsens or eases.
  final AlertSeverity severity;

  /// When this episode opened — not when it last escalated.
  final DateTime raisedAt;

  /// When it first went critical, kept even if it has since eased back to a
  /// warning. "This one went critical at some point" outlives the recovery.
  final DateTime? escalatedAt;

  /// Unit for [value], read from `signal_spec` rather than hard-coded.
  final String unit;

  /// How old the watched signal may get before it stops being evidence, from
  /// `signal_spec.max_age_sec`.
  final Duration maxAge;

  /// Event time of the latest reading of the watched signal, if there is one.
  final DateTime? readingAt;

  /// The latest value of the signal this alert watches, or null if the vehicle
  /// has since stopped reporting it.
  final double? value;

  /// How long this episode has been open at [now].
  Duration ageAt(DateTime now) => now.difference(raisedAt);

  /// True when the alert eased from critical back to a warning. Worth showing:
  /// it means someone or something already acted.
  bool get hasEasedOff =>
      escalatedAt != null && severity != AlertSeverity.critical;

  /// True when the reading this alert was raised on has gone quiet.
  ///
  /// The episode stays open — no reading is not evidence of recovery — but the
  /// card has to say so, or it is asserting a live fact from data the readings
  /// register is simultaneously refusing to judge.
  bool isStaleAt(DateTime now) =>
      readingAt == null || now.difference(readingAt!) > maxAge;

  /// How long the watched signal has been quiet at [now].
  Duration? silenceAt(DateTime now) =>
      readingAt == null ? null : now.difference(readingAt!);
}
