import '../error/failures.dart';

/// A success-or-failure wrapper for use-case return values.
///
/// Clean-architecture examples usually reach for `dartz`'s `Either` here. Dart
/// 3 sealed classes plus exhaustive `switch` give the same guarantee — you
/// cannot read the value without handling the failure — without adding a
/// functional-programming dependency for one type.
sealed class Result<T> {
  const Result();

  /// True when this holds a value.
  bool get isOk => this is Ok<T>;

  /// The value, or null when this is a failure. Prefer an exhaustive `switch`
  /// over this at call sites that must handle both branches.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };
}

/// The operation succeeded and produced [value].
class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

/// The operation failed with [failure].
class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}
