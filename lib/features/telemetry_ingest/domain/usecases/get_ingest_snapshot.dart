import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../entities/ingest_snapshot.dart';
import '../repositories/telemetry_repository.dart';

/// Reads the on-disk totals.
///
/// Called after each batch so the numbers on screen are what a fresh query
/// returns, not what the app believes it wrote.
class GetIngestSnapshot implements UseCase<IngestSnapshot, NoParams> {
  const GetIngestSnapshot(this._repository);

  final TelemetryRepository _repository;

  @override
  Future<Result<IngestSnapshot>> call(NoParams params) =>
      _repository.snapshot();
}
