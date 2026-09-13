/// Data-layer exceptions. These never escape the repository: it catches them
/// and maps them onto a `Failure` (see `core/error/failures.dart`).
library;

/// A local database operation failed.
class LocalDatabaseException implements Exception {
  const LocalDatabaseException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'LocalDatabaseException: $message${cause == null ? '' : ' ($cause)'}';
}

/// The packet source could not produce packets.
class PacketSourceException implements Exception {
  const PacketSourceException(this.message);

  final String message;

  @override
  String toString() => 'PacketSourceException: $message';
}
