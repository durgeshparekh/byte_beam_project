import 'package:byte_beam_project/core/utils/clock.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulated_packet_source.dart';
import 'package:byte_beam_project/features/telemetry_ingest/data/datasources/simulator_config.dart';
import 'package:byte_beam_project/features/telemetry_ingest/domain/entities/telemetry_packet.dart';
import 'package:flutter_test/flutter_test.dart';

/// One arrival: the tick it showed up on, and the packet itself.
typedef Arrival = (int tick, TelemetryPacket packet);

/// Drives the simulator for [ticks] ticks without real timers.
///
/// The clock the simulator stamps packets with is the same one this advances —
/// an easy thing to get wrong, and if they diverge every packet carries an
/// identical event time and the fault-injection assertions below all pass
/// vacuously.
List<Arrival> drive(int ticks, {int seed = 1337, int vehicles = 20}) {
  final clock = FakeClock(DateTime.utc(2026, 1, 1, 10));
  final source = SimulatedPacketSource(
    clock: clock,
    config: SimulatorConfig(vehicleCount: vehicles, seed: seed),
  );

  final out = <Arrival>[];
  for (var tick = 0; tick < ticks; tick++) {
    for (final packet in source.generateTick()) {
      out.add((tick, packet));
    }
    clock.advance(source.config.tick);
  }
  return out;
}

/// Identity of a packet as the database sees it.
String keyOf(TelemetryPacket packet) =>
    '${packet.vehicleId}@${packet.eventTs.toIso8601String()}';

void main() {
  test('the roster is unique and the right size', () {
    final source = SimulatedPacketSource(
      clock: FakeClock(DateTime.utc(2026)),
      config: const SimulatorConfig(vehicleCount: 20),
    );

    expect(source.fleet, hasLength(20));
    expect(source.fleet.map((v) => v.vehicleId).toSet(), hasLength(20));
    expect(source.fleet.every((v) => v.regNo.startsWith('KA01')), isTrue);
  });

  test('event times advance with the clock', () {
    final feed = drive(10);
    final distinctTimes = feed.map((a) => a.$2.eventTs).toSet();

    expect(
      distinctTimes.length,
      greaterThan(1),
      reason: 'a frozen clock would make every fault assertion vacuous',
    );
  });

  test('the same seed replays exactly', () {
    String fingerprint(List<Arrival> feed) =>
        feed.map((a) => '${a.$1}|${keyOf(a.$2)}|${a.$2.signals}').join('\n');

    expect(fingerprint(drive(25)), fingerprint(drive(25)));
  });

  test('different seeds diverge', () {
    expect(drive(25).length, isNot(drive(25, seed: 99).length));
  });

  test('it redelivers packets — same vehicle, same event time', () {
    final keys = drive(60).map((a) => keyOf(a.$2)).toList();

    expect(
      keys.length - keys.toSet().length,
      greaterThan(0),
      reason: 'no duplicates injected, so the dedupe path is untested',
    );
  });

  test('it delivers packets out of order', () {
    var newestSeen = DateTime.utc(2000);
    var lateArrivals = 0;
    for (final (_, packet) in drive(60)) {
      if (packet.eventTs.isBefore(newestSeen)) lateArrivals++;
      if (packet.eventTs.isAfter(newestSeen)) newestSeen = packet.eventTs;
    }

    expect(
      lateArrivals,
      greaterThan(0),
      reason: 'no out-of-order arrivals, so the late path is untested',
    );
  });

  test('it loses packets', () {
    // A perfect link would deliver one packet per vehicle per tick. Drops and
    // basement buffering have to put distinct deliveries below that.
    final distinct = drive(60).map((a) => keyOf(a.$2)).toSet().length;

    expect(distinct, lessThan(20 * 60));
  });

  test('packets carry a subset of signals, not all of them every tick', () {
    final sizes = drive(12).map((a) => a.$2.signals.length).toSet();

    expect(
      sizes.length,
      greaterThan(1),
      reason: 'per-signal freshness only matters if cadences differ',
    );
  });

  test('values stay physically plausible', () {
    for (final (_, packet) in drive(120)) {
      final soc = packet.signals['soc'];
      final speed = packet.signals['speed'];
      final temp = packet.signals['battery_temp'];
      if (soc != null) expect(soc, inInclusiveRange(0, 100));
      if (speed != null) expect(speed, inInclusiveRange(0, 80));
      if (temp != null) expect(temp, inInclusiveRange(0, 90));
      expect(packet.location?.accuracyM ?? 1, greaterThan(0));
    }
  });
}
