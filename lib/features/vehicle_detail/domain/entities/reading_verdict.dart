/// What the app is willing to claim about one reading.
///
/// The three-way split is the point. A threshold comparison is only meaningful
/// on a value we still trust; once a reading is too old, saying "normal" is a
/// lie and saying "alert" is a different lie. [stale] refuses to make either
/// claim, which is why it is a verdict rather than a flag on the other two.
enum ReadingVerdict {
  /// Fresh, and inside its thresholds.
  normal,

  /// Fresh, and outside its thresholds.
  alert,

  /// Too old to judge. No normal-or-alert claim is made.
  stale;

  /// Parses the token the SQL `CASE` produces. Null means the signal has never
  /// reported, which gets no pill at all rather than a fourth verdict.
  static ReadingVerdict? fromSql(String? value) => switch (value) {
    'NORMAL' => ReadingVerdict.normal,
    'ALERT' => ReadingVerdict.alert,
    'STALE' => ReadingVerdict.stale,
    _ => null,
  };

  /// Pill label.
  String get label => switch (this) {
    ReadingVerdict.normal => 'NORMAL',
    ReadingVerdict.alert => 'ALERT',
    ReadingVerdict.stale => 'STALE',
  };
}
