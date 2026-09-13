import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/db/geofence_sql.dart';
import 'package:byte_beam_project/db/trip_sql.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final t0 = DateTime.utc(2026, 1, 1, 8);

DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

/// Trip derivation, driven through the real SQL.
///
/// Fed with crossings rather than position fixes on purpose: a trip is a
/// reading of `geofence_transition` and of nothing else, so these tests can
/// state a crossing sequence and say exactly what it means. Whether the
/// detector produces that sequence from a position log is
/// `geofence_detector_test.dart`'s question, asked once.
///
/// The fences are migration v2's own, so `gf-bay3` (350 m) really does sit
/// inside `gf-depot` (2500 m).
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    conn = db.read;
    await conn.execute("INSERT INTO vehicle VALUES ('v1', 'KA01AA0001', 'eT')");
    await conn.execute(geofenceScopeDdl);
  });
  tearDown(() => db.close());

  /// Records one confirmed crossing.
  Future<void> crossing(
    String fence,
    int minute,
    String kind, {
    String confidence = 'high',
  }) => conn.execute(
    "INSERT INTO geofence_transition VALUES ('v1', '$fence', "
    "TIMESTAMP '${at(minute).toIso8601String()}', '$kind', '$confidence')",
  );

  /// States which fences the vehicle is inside **now**.
  ///
  /// Not decoration: the derivation recovers where the vehicle started from
  /// this minus the net of every crossing since, because the detector emits no
  /// transition for the zone it establishes on a cold start.
  Future<void> endsInside(List<String> fences) async {
    await conn.execute('DELETE FROM geofence_containment');
    for (final fence in fences) {
      await conn.execute(
        "INSERT INTO geofence_containment VALUES ('v1', '$fence', 'IN', "
        'NULL, NULL)',
      );
    }
  }

  Future<void> odometer(int minute, double km) => conn.execute(
    "INSERT INTO signal_reading VALUES ('v1', 'odometer', "
    "TIMESTAMP '${at(minute).toIso8601String()}', $km, now())",
  );

  /// One derivation pass over every vehicle, as a fence edit would run it.
  Future<void> derive() async {
    await conn.execute(clearGeofenceScope);
    await conn.execute(insertGeofenceScopeAll);
    await deriveTrips(conn);
  }

  /// Every trip, oldest first.
  Future<List<List<Object?>>> trips() async {
    final result = await conn.query(
      'SELECT origin_geofence_id, start_ts, dest_geofence_id, end_ts, '
      'status, distance_km, confidence FROM trip ORDER BY start_ts',
    );
    return result.fetchAll();
  }

  group('starting and finishing', () {
    test(
      'leaving the last fence starts a trip that is still running',
      () async {
        await crossing('gf-depot', 10, 'EXIT');
        await endsInside([]);
        await derive();

        expect(await trips(), [
          ['gf-depot', at(10), null, null, 'IN_PROGRESS', null, 'high'],
        ]);
      },
    );

    test('arriving anywhere completes it', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-ecity', 40, 'ENTRY');
      await endsInside(['gf-ecity']);
      await derive();

      expect(await trips(), [
        ['gf-depot', at(10), 'gf-ecity', at(40), 'COMPLETED', null, 'high'],
      ]);
    });

    // Not a special case in the code, and that is the point: the rule is
    // "containment reached zero", which knows nothing about which fence.
    test('coming back to where it started is an ordinary completion', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-depot', 90, 'ENTRY');
      await endsInside(['gf-depot']);
      await derive();

      final all = await trips();
      expect(all, hasLength(1));
      expect(all.single[0], 'gf-depot');
      expect(all.single[2], 'gf-depot');
    });

    // We never watched it leave, so there is no departure to complete. The
    // alternative is inventing a start time.
    test('an arrival with no departure makes nothing', () async {
      await crossing('gf-depot', 10, 'ENTRY');
      await endsInside(['gf-depot']);
      await derive();

      expect(await trips(), isEmpty);
    });
  });

  group('nested fences', () {
    // The case the whole containment-count design exists for.
    test('leaving a bay inside the depot starts nothing', () async {
      await crossing('gf-bay3', 10, 'EXIT');
      await endsInside(['gf-depot']);
      await derive();

      expect(await trips(), isEmpty);
    });

    test('leaving the bay and the depot is one trip from the depot', () async {
      // Both crossings confirmed off the same fix — the outer fence is the one
      // the truck departed from.
      await crossing('gf-bay3', 10, 'EXIT');
      await crossing('gf-depot', 10, 'EXIT');
      await endsInside([]);
      await derive();

      final all = await trips();
      expect(all, hasLength(1));
      expect(all.single[0], 'gf-depot');
      expect(all.single[1], at(10));
    });

    test('arriving into a depot and its bay names the depot', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-depot', 60, 'ENTRY');
      await crossing('gf-bay3', 60, 'ENTRY');
      await endsInside(['gf-depot', 'gf-bay3']);
      await derive();

      expect((await trips()).single[2], 'gf-depot');
    });
  });

  group('the starting containment count', () {
    // A truck that was already in the depot when we started watching has an
    // EXIT with no matching ENTRY. Counting from zero would take it to -1 and
    // lose the trip entirely.
    test('a cold start inside a fence still produces the trip', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-hebbal', 50, 'ENTRY');
      await crossing('gf-hebbal', 80, 'EXIT');
      await endsInside([]);
      await derive();

      final all = await trips();
      expect(all, hasLength(2));
      expect(
        all[0][3],
        at(50),
        reason:
            'the first leg ends where the second '
            'begins',
      );
      expect(all[1][1], at(80));
      expect(all[1][4], 'IN_PROGRESS');
    });
  });

  group('distance', () {
    test('is the odometer delta across the leg', () async {
      await odometer(5, 1000);
      await odometer(38, 1042.5);
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-ecity', 40, 'ENTRY');
      await endsInside(['gf-ecity']);
      await derive();

      expect((await trips()).single[5], 42.5);
    });

    // Distance so far, not a blank: the truck is still out there and the
    // odometer is still reporting.
    test('a running trip measures to the latest reading', () async {
      await odometer(5, 1000);
      await odometer(70, 1030);
      await crossing('gf-depot', 10, 'EXIT');
      await endsInside([]);
      await derive();

      expect((await trips()).single[5], 30);
    });

    // "We do not know" and "it did not move" are different answers.
    test('is null when the odometer never reported', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-ecity', 40, 'ENTRY');
      await endsInside(['gf-ecity']);
      await derive();

      expect((await trips()).single[5], isNull);
    });
  });

  group('confidence', () {
    test('a leg inherits a low-confidence crossing at either end', () async {
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-ecity', 40, 'ENTRY', confidence: 'low');
      await endsInside(['gf-ecity']);
      await derive();

      expect((await trips()).single[6], 'low');
    });
  });

  group('replay', () {
    // The property that lets this run after every batch without bookkeeping.
    test('deriving twice changes nothing', () async {
      await odometer(5, 1000);
      await odometer(38, 1042.5);
      await crossing('gf-depot', 10, 'EXIT');
      await crossing('gf-ecity', 40, 'ENTRY');
      await endsInside(['gf-ecity']);

      await derive();
      final first = await trips();
      await derive();

      expect(await trips(), first);
    });
  });
}
