import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/fleet_filter.dart';
import '../../domain/entities/fleet_overview.dart';
import '../../domain/usecases/get_fleet_overview.dart';

/// Drives the fleet home screen.
class FleetController extends GetxController {
  FleetController({
    required GetFleetOverview getFleetOverview,
    required DatabasePulse pulse,
    required Clock clock,
    this.refreshDebounce = const Duration(milliseconds: 250),
  }) : _getFleetOverview = getFleetOverview,
       _pulse = pulse,
       _clock = clock;

  final GetFleetOverview _getFleetOverview;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// How long to wait after a write before re-querying. A backlog dump commits
  /// several batches back to back; the list only needs to land once.
  final Duration refreshDebounce;

  /// Selected chip.
  final filter = FleetFilter.all.obs;

  /// Rows and counts, as of the last query.
  final overview = const FleetOverview.empty().obs;

  /// True until the first query returns. Distinguishes "still loading" from
  /// "genuinely no vehicles", which need different screens.
  final isLoading = true.obs;

  /// Last error, or empty.
  final error = ''.obs;

  @override
  void onInit() {
    super.onInit();
    // Re-query when the writer commits, and once at startup so the screen is
    // populated before any packet arrives.
    debounce<int>(_pulse.revision, (_) => load(), time: refreshDebounce);
    load();
  }

  /// Switches chip and reloads.
  ///
  /// Reloads rather than filtering in memory: the counts are SQL-side and the
  /// row set for a chip is a different query, not a subset of one already held.
  Future<void> select(FleetFilter next) async {
    if (filter.value == next) return;
    filter.value = next;
    await load();
  }

  /// Re-reads rows and counts for the current chip.
  Future<void> load() async {
    final result = await _getFleetOverview(
      FleetOverviewParams(filter: filter.value, now: _clock.nowUtc()),
    );
    switch (result) {
      case Ok(:final FleetOverview value):
        overview.value = value;
        error.value = '';
      case Err(:final failure):
        error.value = failure.message;
    }
    isLoading.value = false;
  }
}
