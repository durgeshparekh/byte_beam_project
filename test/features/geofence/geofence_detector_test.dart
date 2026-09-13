import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/db/geofence_sql.dart';
import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

final t0 = DateTime.utc(2026, 1, 1, 8);

DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

/// Fence centre used by every test: one fence, radius 1000 m, so the numbers
/// in the tests are metres from a single point.
const fenceLat = 12.9700;
const fenceLon = 77.6000;
const radius = 1000.0;

/// A latitude [metres] north of the fence centre. Longitude is left alone so
/// the offset is exactly the distance.
double latAt(double metres) => fenceLat + metres / 111320.0;

/// Entry and exit detection, driven through the real detector SQL.
void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late Connection conn;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    conn = db.read;
    await conn.execute('DELETE FROM geofence');
    await conn.execute("INSERT INTO vehicle VALUES ('v1', 'KA01AA0001', 'eT')");
    await conn.execute(
      "INSERT INTO geofence VALUES ('gf', 'Depot', $fenceLat, $fenceLon, "
      "$radius, TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01')",
    );
    await conn.execute(geofenceScopeDdl);
  });
  tearDown(() => db.close());

  /// Records one position fix [metres] from the fence centre.
  Future<void> fix(
    int minute,
    double metres, {
    double accuracy = 5,
    int second = 0,
    String vehicleId = 'v1',
  }) {
    final ts = at(minute).add(Duration(seconds: second));
    return conn.execute(
      "INSERT INTO location_fix VALUES ('$vehicleId', "
      "TIMESTAMP '${ts.toIso8601String()}', ${latAt(metres)}, "
      '$fenceLon, $accuracy, now())',
    );
  }

  /// Runs a derivation pass over everything, the way a fence edit does.
  Future<void> derive() => recomputeAllGeofences(conn);

  /// Every transition, oldest first.
  Future<List<List<Object?>>> transitions() async {
    final result = await conn.query(
      'SELECT kind, event_ts, confidence FROM geofence_transition '
      'ORDER BY event_ts',
    );
    return result.fetchAll();
  }

  Future<List<Object?>> containment() async {
    final result = await conn.query(
      'SELECT zone, pending_zone, pending_ts FROM geofence_containment',
    );
    return result.fetchOne() ?? const [];
  }

  group('establishing a zone', () {
    // We learned where the truck is; we did not watch it go there.
    test('the first confirmation emits nothing', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await derive();

      expect(await transitions(), isEmpty);
      expect((await containment())[0], 'OUT');
    });

    // 40 m outside a 1000 m fence: past the 25 m band, so the fix has an
    // opinion, but not past 2x the band, so it is only a candidate.
    test('a single ambiguous fix establishes nothing on its own', () async {
      await fix(0, 1040);
      await derive();

      final state = await containment();
      expect(
        state[0],
        isNull,
        reason: 'one near-boundary fix is a candidate, not a zone',
      );
      expect(state[1], 'OUT', reason: 'but it is pending');
      expect(state[2], at(0));
    });

    // The same rule from the other side: 1000 m clear of the boundary is not
    // a candidate, it is a fact.
    test('a single unambiguous fix establishes the zone alone', () async {
      await fix(0, 2000);
      await derive();

      expect((await containment())[0], 'OUT');
    });
  });

  group('crossings', () {
    test('two fixes agreeing inside confirm an entry', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 500);
      await fix(3, 400);
      await derive();

      final rows = await transitions();
      expect(rows, hasLength(1));
      expect(rows.single[0], 'ENTRY');
    });

    // Step 5: the crossing happened when the vehicle was first seen inside,
    // not when the second fix made us sure.
    test('the transition is stamped with the first fix of the pair', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 500);
      await fix(3, 400);
      await derive();

      expect((await transitions()).single[1], at(2));
    });

    test('a round trip produces an entry and an exit', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 500);
      await fix(3, 400);
      await fix(4, 3000);
      await fix(5, 3200);
      await derive();

      expect((await transitions()).map((r) => r[0]), ['ENTRY', 'EXIT']);
    });

    // Step 4's escape hatch: a fix well clear of the boundary does not need a
    // second opinion.
    test('one fix far past the boundary confirms alone', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 100);
      await derive();

      final rows = await transitions();
      expect(rows, hasLength(1));
      expect(rows.single[0], 'ENTRY');
      expect(rows.single[1], at(2), reason: 'its own fix, not a pair');
    });
  });

  group('what must not produce a crossing', () {
    // Step 2 and 3. This is the parked-on-the-line case that turns into
    // dozens of phantom trips without a band.
    test('a vehicle sitting in the hysteresis band never crosses', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      for (var i = 2; i < 12; i++) {
        await fix(i, 1000 + (i.isEven ? 10 : -10));
      }
      await derive();

      expect(await transitions(), isEmpty);
    });

    // Step 1. A 200 m accuracy fix cannot say anything about a 1000 m circle.
    test('an inaccurate fix is not evidence', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 300, accuracy: 200);
      await fix(3, 300, accuracy: 200);
      await derive();

      expect(await transitions(), isEmpty);
    });

    // The band scales with the fix: a 60 m fix needs to be 60 m clear.
    test('a mediocre fix widens the band it has to clear', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 960, accuracy: 60);
      await fix(3, 960, accuracy: 60);
      await derive();

      expect(
        await transitions(),
        isEmpty,
        reason: '40 m inside a 1000 m fence is inside a 60 m band',
      );
    });

    // 40 m inside: opinionated, but not clear enough to confirm alone, and
    // never seconded.
    test('a single fix just past the line is not enough', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 960);
      await fix(3, 2000);
      await derive();

      expect(await transitions(), isEmpty);
    });
  });

  group('gaps', () {
    // Step 6. The truck may have gone in and come out while we were not
    // looking; the crossing is still recorded, but it is not trusted.
    test('a confirming pair straddling a long gap is low confidence', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 960);
      await fix(45, 960);
      await derive();

      final rows = await transitions();
      expect(rows.single[0], 'ENTRY');
      expect(rows.single[2], 'low');
    });

    test('an ordinary confirming pair is high confidence', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 960);
      await fix(3, 960);
      await derive();

      expect((await transitions()).single[2], 'high');
    });
  });

  group('fence activation', () {
    // Step 8. Activation is time-versioned, so a recompute asks "was this
    // fence active when the vehicle was there", not "is it active now".
    test('fixes before a fence existed are not its business', () async {
      await conn.execute(
        "UPDATE geofence SET active_from = TIMESTAMP "
        "'${at(3).toIso8601String()}'",
      );
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 400);
      await fix(4, 400);
      await derive();

      expect(
        await transitions(),
        isEmpty,
        reason: 'only one fix falls inside the active window',
      );
    });

    test('a deactivated fence stops judging at its end date', () async {
      await conn.execute(
        "UPDATE geofence SET active_to = TIMESTAMP "
        "'${at(2).toIso8601String()}'",
      );
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(3, 400);
      await fix(4, 400);
      await derive();

      expect(await transitions(), isEmpty);
    });
  });

  group('resuming mid-stream', () {
    /// What the writer does per batch: scope one vehicle from the oldest fix
    /// in the batch, then derive.
    Future<void> deriveFrom(DateTime from) async {
      await conn.execute(clearGeofenceScope);
      await conn.execute(
        "INSERT INTO staging_geo_scope VALUES ('v1', "
        "TIMESTAMP '${from.toIso8601String()}')",
      );
      await deriveGeofences(conn);
    }

    /// The route used by both halves of the equivalence test: out, in, out,
    /// with a spell parked on the boundary in the middle.
    const route = <(int, double)>[
      (0, 2000),
      (1, 2000),
      (2, 1400),
      (3, 960),
      (4, 900),
      (5, 1010),
      (6, 990),
      (7, 1005),
      (8, 300),
      (9, 250),
      (10, 1400),
      (11, 2200),
      (12, 2600),
    ];

    // The claim the whole seed mechanism exists to support. One fix at a time
    // must land exactly where one pass over the finished log lands, or the
    // incremental path is quietly inventing history.
    test('fix-by-fix derivation matches a single full replay', () async {
      for (final (minute, metres) in route) {
        await fix(minute, metres);
        await deriveFrom(at(minute));
      }
      final incremental = await transitions();
      final incrementalState = await containment();

      await derive();

      expect(incremental, isNotEmpty, reason: 'the route does cross');
      expect(await transitions(), incremental);
      expect(await containment(), incrementalState);
    });

    // A fix landing behind the watermark invalidates the seed, so the writer
    // scopes that vehicle to a full replay instead. The claim is not that the
    // answer stays the same — it should change — but that it becomes exactly
    // the answer the completed log deserves.
    test('a late fix is absorbed by replaying the vehicle', () async {
      for (final (minute, metres) in route) {
        await fix(minute, metres);
        await deriveFrom(at(minute));
      }
      expect((await transitions()).map((r) => r[0]), ['ENTRY', 'EXIT']);

      // The truck did leave the yard and come back in the middle; we only
      // find out now. Straight past the boundary, so one fix settles it.
      await fix(6, 1400, second: 30);
      await deriveFrom(DateTime.utc(1000));
      final replayed = await transitions();
      final replayedState = await containment();

      expect(replayed.map((r) => r[0]), [
        'ENTRY',
        'EXIT',
        'ENTRY',
        'EXIT',
      ], reason: 'the missing excursion is now visible');

      // And it is indistinguishable from having had the log in order.
      await derive();
      expect(await transitions(), replayed);
      expect(await containment(), replayedState);
    });

    test('an incremental pass leaves a fence with no fixes alone', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await deriveFrom(at(0));
      final before = await containment();

      await deriveFrom(at(9));

      expect(await containment(), before);
    });
  });

  group('idempotence and replay', () {
    test('re-deriving the same log produces the same rows', () async {
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 400);
      await fix(3, 400);
      await fix(4, 3000);
      await fix(5, 3000);
      await derive();
      final first = await transitions();

      await derive();

      expect(await transitions(), first);
    });

    test('a nested fence is tracked independently', () async {
      await conn.execute(
        "INSERT INTO geofence VALUES ('gf-in', 'Bay', $fenceLat, $fenceLon, "
        "200, TIMESTAMP '2000-01-01', NULL, TIMESTAMP '2000-01-01')",
      );
      await fix(0, 2000);
      await fix(1, 2000);
      await fix(2, 50);
      await fix(3, 50);
      await derive();

      final result = await conn.query(
        'SELECT geofence_id, kind FROM geofence_transition ORDER BY 1',
      );
      expect(result.fetchAll(), [
        ['gf', 'ENTRY'],
        ['gf-in', 'ENTRY'],
      ]);
    });
  });
}
