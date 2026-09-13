import '../../../../core/usecases/usecase.dart';
import '../entities/telemetry_packet.dart';
import '../repositories/telemetry_repository.dart';

/// Opens the live packet feed.
///
/// A stream use case rather than a `Future` one: the controller subscribes
/// once and stays subscribed for the life of the screen.
class ObserveTelemetry
    implements StreamUseCase<List<TelemetryPacket>, NoParams> {
  const ObserveTelemetry(this._repository);

  final TelemetryRepository _repository;

  @override
  Stream<List<TelemetryPacket>> call(NoParams params) =>
      _repository.watchPackets();
}
