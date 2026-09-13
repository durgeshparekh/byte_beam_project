import '../../../../core/usecases/usecase.dart';
import '../../../../core/utils/result.dart';
import '../repositories/alert_repository.dart';

/// Reverses a dismissal.
///
/// A separate use case rather than a flag on [DismissAlert] because it is a
/// different intent with a different failure story: a dismissal that fails
/// leaves the alert showing, which is safe, while an undo that fails leaves an
/// alert hidden that the user asked to see again.
class UndoDismissal implements UseCase<void, String> {
  const UndoDismissal(this._repository);

  final AlertRepository _repository;

  @override
  Future<Result<void>> call(String alertId) =>
      _repository.undoDismissal(alertId);
}
