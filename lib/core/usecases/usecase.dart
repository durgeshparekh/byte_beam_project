import '../utils/result.dart';

/// Base contract for every use case: one public operation, one parameter
/// object, one `Result`. Keeping the shape uniform is what lets controllers
/// depend on use cases without knowing anything about the data layer.
abstract class UseCase<T, P> {
  /// Runs the use case.
  Future<Result<T>> call(P params);
}

/// Base contract for use cases that expose a continuous stream rather than a
/// single answer (the telemetry feed, for example). Streams carry no `Result`
/// because a broken source terminates the stream with an error instead.
abstract class StreamUseCase<T, P> {
  /// Opens the stream.
  Stream<T> call(P params);
}

/// Parameter object for use cases that take no arguments.
class NoParams {
  const NoParams();
}
