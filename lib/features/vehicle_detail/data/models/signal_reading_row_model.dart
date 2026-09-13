import '../../domain/entities/reading_verdict.dart';
import '../../domain/entities/signal_reading_row.dart';

/// Row-to-entity mapping for the readings register.
class SignalReadingRowModel extends SignalReadingRow {
  const SignalReadingRowModel({
    required super.signal,
    required super.label,
    required super.unit,
    required super.maxAge,
    super.value,
    super.eventTs,
    super.verdict,
  });

  /// Builds a row in the column order the register query selects.
  factory SignalReadingRowModel.fromRow(List<Object?> row) {
    return SignalReadingRowModel(
      signal: row[0]! as String,
      label: row[1]! as String,
      unit: row[2]! as String,
      maxAge: Duration(seconds: (row[3]! as num).toInt()),
      value: (row[4] as num?)?.toDouble(),
      eventTs: row[5] as DateTime?,
      verdict: ReadingVerdict.fromSql(row[6] as String?),
    );
  }
}
