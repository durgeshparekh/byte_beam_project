/// A circular fence: where it is, how big, and when it counted.
///
/// Activation is **time-versioned** and geometry is not. Asking "was this
/// fence active at the fix's event time" keeps a recompute pure, so
/// deactivating a fence never rewrites the history it was part of. Moving one
/// does — see `recomputeAllGeofences` — which is the trade documented as
/// ARCHITECTURE.md §10, ambiguity 9.
class Geofence {
  const Geofence({
    required this.geofenceId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusM,
    required this.activeFrom,
    required this.updatedAt,
    this.activeTo,
  });

  final String geofenceId;
  final String name;
  final double lat;
  final double lon;
  final double radiusM;

  /// From when this fence starts judging fixes.
  final DateTime activeFrom;

  /// When it stopped, or null while it is live. Deactivated fences are kept,
  /// not deleted: a trip that ended at a depot has to be able to name it long
  /// after the depot closed.
  final DateTime? activeTo;

  final DateTime updatedAt;

  bool get isActive => activeTo == null;

  /// A copy with [activeTo] set or cleared, for the deactivate toggle.
  Geofence withActive({required bool active, required DateTime at}) => Geofence(
    geofenceId: geofenceId,
    name: name,
    lat: lat,
    lon: lon,
    radiusM: radiusM,
    // Reactivating starts a *new* active window rather than resuming the old
    // one, so the period it was off stays genuinely off in any recompute.
    activeFrom: active ? at : activeFrom,
    activeTo: active ? null : at,
    updatedAt: at,
  );
}

/// A fence plus how many vehicles are inside it right now.
class GeofenceOccupancy {
  const GeofenceOccupancy({required this.fence, required this.vehiclesInside});

  final Geofence fence;

  /// Counted from `geofence_containment`, not from the log.
  final int vehiclesInside;
}

/// One crossing, as the vehicle screen shows it.
class GeofenceVisit {
  const GeofenceVisit({
    required this.geofenceName,
    required this.isEntry,
    required this.at,
    required this.isConfident,
  });

  final String geofenceName;

  /// Entry when true, exit when false.
  final bool isEntry;

  /// Event time of the first fix of the confirming pair — when the vehicle
  /// crossed, not when we became sure.
  final DateTime at;

  /// False when the confirming pair straddled a reporting gap longer than
  /// half an hour. The crossing happened; its timing is a guess.
  final bool isConfident;
}
