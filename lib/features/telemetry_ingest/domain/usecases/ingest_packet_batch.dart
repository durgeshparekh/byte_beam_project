import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/ingest_receipt.dart';
import '../entities/telemetry_packet.dart';
import '../repositories/telemetry_repository.dart';

/// Writes one batch of packets to disk durably.
///
/// The batch is the transaction boundary. Everything the brief calls hard —
/// duplicates, late arrivals, backlog dumps — is handled inside this one
/// operation so that no caller has to reason about ordering.
class IngestPacketBatch
    implements UseCase<IngestReceipt, List<TelemetryPacket>> {
  const IngestPacketBatch(this._repository);

  final TelemetryRepository _repository;

  /// Skips the round trip entirely for an empty batch — the source emits
  /// those whenever a tick produced no readings.
  @override
  Future<Result<IngestReceipt>> call(List<TelemetryPacket> params) async {
    if (params.isEmpty) return const Ok(IngestReceipt.empty());
    return _repository.ingest(params);
  }
}
