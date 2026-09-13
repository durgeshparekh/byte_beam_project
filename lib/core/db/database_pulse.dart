import 'package:get/get.dart';

/// A bump every time the database changes.
///
/// Read-side screens cannot watch DuckDB for changes — there is no change
/// feed — so the writer announces instead. Screens debounce this rather than
/// reacting to every bump: a vehicle leaving a basement dumps hours of backlog
/// in a handful of batches, and repainting the fleet list once per batch would
/// be work nobody can see.
///
/// A counter rather than a stream so GetX's `debounce` worker can watch it
/// directly, and so a screen that arrives late still sees a value.
class DatabasePulse extends GetxService {
  /// Increments on every committed write.
  final revision = 0.obs;

  /// Called by the writer's caller after a batch commits.
  void ping() => revision.value++;
}
