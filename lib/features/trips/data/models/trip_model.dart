import '../../domain/entities/trip.dart';

/// Row-to-entity mapping for trips.
class TripModel extends Trip {
  const TripModel({
    required super.tripId,
    required super.vehicleId,
    required super.regNo,
    required super.startedAt,
    required super.isConfident,
    super.origin,
    super.destination,
    super.endedAt,
    super.distanceKm,
  });

  /// Column order is the one both trip queries share — see `_tripColumns` in
  /// `trip_sql.dart`, which exists so this mapping only has to be right once.
  factory TripModel.fromRow(List<Object?> row) => TripModel(
    tripId: row[0]! as String,
    vehicleId: row[1]! as String,
    regNo: row[2]! as String,
    origin: row[3] as String?,
    destination: row[4] as String?,
    startedAt: row[5]! as DateTime,
    endedAt: row[6] as DateTime?,
    distanceKm: (row[8] as num?)?.toDouble(),
    // `status` (row 7) is not carried across: it is `end_ts IS NULL` spelled a
    // second way, and two spellings of one fact can disagree.
    isConfident: row[9] != 'low',
  );
}
