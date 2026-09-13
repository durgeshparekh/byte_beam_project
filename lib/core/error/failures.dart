/// Domain-facing error type. The domain layer never sees a `DuckDBException`
/// or a `SocketException` — the data layer translates those into a [Failure]
/// so nothing above it has to know where the data came from.
sealed class Failure {
  const Failure(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Something went wrong writing to or reading from the on-device database.
class DatabaseFailure extends Failure {
  const DatabaseFailure(super.message);
}

/// The packet source (simulator today, MQTT/HTTP later) misbehaved.
class PacketSourceFailure extends Failure {
  const PacketSourceFailure(super.message);
}
