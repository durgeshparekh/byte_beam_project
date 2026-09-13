import 'package:get/get.dart';

import '../../../../core/db/database_pulse.dart';
import '../../../../core/utils/clock.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/trip.dart';
import '../../domain/usecases/get_recent_trips.dart';

/// Drives the trips screen.
///
/// Permanent like the alerts controller, and for the same reason: the fleet
/// app bar wants the running count before anyone has opened the screen.
class TripsController extends GetxController {
  TripsController({
    required GetRecentTrips getRecentTrips,
    required DatabasePulse pulse,
    required Clock clock,
    this.refreshDebounce = const Duration(milliseconds: 250),
  }) : _getRecentTrips = getRecentTrips,
       _pulse = pulse,
       _clock = clock;

  final GetRecentTrips _getRecentTrips;
  final DatabasePulse _pulse;
  final Clock _clock;

  /// How long to settle after a write before re-querying.
  final Duration refreshDebounce;

  /// Recent trips, running ones first.
  final trips = <Trip>[].obs;

  /// True until the first query returns.
  final isLoading = true.obs;

  /// Last error, or empty.
  final error = ''.obs;

  /// The instant the visible durations were measured against, so every row on
  /// screen agrees about how long a running trip has been running.
  final evaluatedAt = Rxn<DateTime>();

  /// How many trips are still open. Shown in the app bar, because an open trip
  /// is the only row here anyone can still act on.
  int get runningCount => trips.where((trip) => trip.isRunning).length;

  @override
  void onInit() {
    super.onInit();
    // Trips are re-derived inside the ingest transaction, so a commit is the
    // only thing that can change this list.
    debounce<int>(_pulse.revision, (_) => load(), time: refreshDebounce);
    load();
  }

  /// Re-reads the trip list.
  Future<void> load() async {
    final now = _clock.nowUtc();
    final result = await _getRecentTrips(const RecentTripsParams());
    switch (result) {
      case Ok(:final List<Trip> value):
        trips.value = value;
        evaluatedAt.value = now;
        error.value = '';
      case Err(:final failure):
        error.value = failure.message;
    }
    isLoading.value = false;
  }
}
