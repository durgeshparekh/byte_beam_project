import 'package:byte_beam_project/db/fleet_db.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/telemetry_local_data_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/models/telemetry_packet_model.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/fleet_vehicle.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/telemetry_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../duckdb_support.dart';

DateTime _at(int minute, [int second = 0]) =>
    DateTime.utc(2026, 1, 1, 10, minute, second);

/// A packet carrying a single signal, which keeps the assertions readable.
TelemetryPacketModel _packet(
  String vehicleId,
  DateTime eventTs, {
  Map<String, double> signals = const {'soc': 50},
  GeoFix? location,
}) {
  return TelemetryPacketModel(
    vehicleId: vehicleId,
    eventTs: eventTs,
    signals: signals,
    location: location,
  );
}

void main() {
  setUpAll(useHostDuckDb);

  late FleetDb db;
  late DuckDbTelemetryLocalDataSource local;

  setUp(() async {
    db = await FleetDb.open(':memory:');
    local = await DuckDbTelemetryLocalDataSource.create(db);
    await local.seedFleet(const [
      FleetVehicle(vehicleId: 'v1', regNo: 'KA01AB1234', model: 'eT 1000'),
      FleetVehicle(vehicleId: 'v2', regNo: 'KA01CD5678', model: 'eT 1500'),
    ]);
  });

  tearDown(() async {
    await local.dispose();
    await db.close();
  });

  /// The full derived + logged state, as a comparable value. Two runs that
  /// produce the same thing here are indistinguishable to every screen.
  Future<Map<String, Object?>> stateFingerprint() async {
    final log = await db.read.query(
      'SELECT vehicle_id, signal, event_ts, value FROM signal_reading '
      'ORDER BY vehicle_id, signal, event_ts',
    );
    final latest = await db.read.query(
      'SELECT vehicle_id, signal, event_ts, value FROM vehicle_signal_latest '
      'ORDER BY vehicle_id, signal',
    );
    final fixes = await db.read.query(
      'SELECT vehicle_id, event_ts, lat, lon FROM location_fix '
      'ORDER BY vehicle_id, event_ts',
    );
    final watermark = await db.read.query(
      'SELECT vehicle_id, processed_through FROM ingest_watermark ORDER BY vehicle_id',
    );
    return {
      'log': log.fetchAll(),
      'latest': latest.fetchAll(),
      'fixes': fixes.fetchAll(),
      'watermark': watermark.fetchAll(),
    };
  }

  test('seeding the fleet twice inserts nothing the second time', () async {
    final inserted = await local.seedFleet(const [
      FleetVehicle(vehicleId: 'v1', regNo: 'KA01AB1234', model: 'eT 1000'),
    ]);
    expect(inserted, 0);
    expect((await local.snapshot()).vehicles, 2);
  });

  test('a batch is written and reported accurately', () async {
    final receipt = await local.applyBatch([
      _packet('v1', _at(0), signals: {'soc': 55, 'speed': 0}),
      _packet(
        'v1',
        _at(1),
        signals: {'soc': 54},
        location: const GeoFix(lat: 12.9, lon: 77.5, accuracyM: 6),
      ),
    ]);

    expect(receipt.packets, 2);
    expect(receipt.signalRowsOffered, 3);
    expect(receipt.signalRowsApplied, 3);
    expect(receipt.locationRowsApplied, 1);
    expect(receipt.duplicateRows, 0);

    final snapshot = await local.snapshot();
    expect(snapshot.signalRows, 3);
    expect(snapshot.locationRows, 1);
  });

  test('a redelivered packet applies nothing (§0)', () async {
    final batch = [
      _packet('v1', _at(0), signals: {'soc': 55}),
    ];

    final first = await local.applyBatch(batch);
    final second = await local.applyBatch(batch);

    expect(first.signalRowsApplied, 1);
    expect(second.signalRowsOffered, 1);
    expect(second.signalRowsApplied, 0, reason: 'the natural key rejects it');
    expect(second.duplicateRows, 1);
    expect((await local.snapshot()).signalRows, 1);
  });

  test(
    'duplicates inside one batch collapse before they reach the log',
    () async {
      final receipt = await local.applyBatch([
        _packet('v1', _at(0), signals: {'soc': 55}),
        _packet('v1', _at(0), signals: {'soc': 55}),
        _packet('v1', _at(0), signals: {'soc': 55}),
      ]);

      expect(receipt.packets, 3);
      expect(
        receipt.signalRowsOffered,
        1,
        reason: 'DISTINCT ON collapses them',
      );
      expect(receipt.signalRowsApplied, 1);
    },
  );

  test(
    'a late packet lands in the log but never clobbers the latest value',
    () async {
      await local.applyBatch([
        _packet('v1', _at(5), signals: {'soc': 40}),
      ]);
      await local.applyBatch([
        _packet('v1', _at(1), signals: {'soc': 99}),
      ]);

      final latest = await db.read.query(
        "SELECT event_ts, value FROM vehicle_signal_latest "
        "WHERE vehicle_id = 'v1' AND signal = 'soc'",
      );
      expect(latest.fetchOne(), [_at(5), 40.0]);

      // The late reading is still in the log — it is history, not garbage.
      final log = await db.read.query(
        "SELECT count(*) FROM signal_reading WHERE vehicle_id = 'v1'",
      );
      expect((log.fetchOne()!.first as num).toInt(), 2);
    },
  );

  test('a batch reaching behind the watermark is counted as late', () async {
    await local.applyBatch([_packet('v1', _at(5))]);
    final late = await local.applyBatch([_packet('v1', _at(2))]);

    expect(late.lateVehicles, 1);
  });

  test('the watermark never moves backwards', () async {
    await local.applyBatch([_packet('v1', _at(9))]);
    await local.applyBatch([_packet('v1', _at(3))]);

    final watermark = await db.read.query(
      "SELECT processed_through FROM ingest_watermark WHERE vehicle_id = 'v1'",
    );
    expect(watermark.fetchOne()!.first, _at(9));
  });

  // The invariant the whole design rests on. If this holds, the duplicate,
  // out-of-order and backlog stories all hold with it.
  test(
    'final state is identical however the stream is shuffled or repeated',
    () async {
      List<TelemetryPacketModel> feed() => [
        for (var minute = 0; minute < 12; minute++)
          _packet(
            minute.isEven ? 'v1' : 'v2',
            _at(minute),
            signals: {'soc': 90.0 - minute, 'speed': minute.toDouble()},
            location: GeoFix(
              lat: 12.9 + minute / 1000,
              lon: 77.5 + minute / 1000,
              accuracyM: 8,
            ),
          ),
      ];

      // In order, once each.
      for (final packet in feed()) {
        await local.applyBatch([packet]);
      }
      final ordered = await stateFingerprint();

      // Same feed, reversed, delivered in ragged batches, with every third
      // packet delivered twice.
      await local.dispose();
      await db.close();
      db = await FleetDb.open(':memory:');
      local = await DuckDbTelemetryLocalDataSource.create(db);

      final shuffled = feed().reversed.toList();
      final messy = <TelemetryPacketModel>[
        ...shuffled,
        ...shuffled.where((p) => shuffled.indexOf(p) % 3 == 0),
      ];
      for (var i = 0; i < messy.length; i += 5) {
        await local.applyBatch(
          messy.sublist(i, (i + 5).clamp(0, messy.length)),
        );
      }
      final scrambled = await stateFingerprint();

      expect(scrambled['log'], ordered['log']);
      expect(scrambled['latest'], ordered['latest']);
      expect(scrambled['fixes'], ordered['fixes']);
      expect(scrambled['watermark'], ordered['watermark']);
    },
  );
}
