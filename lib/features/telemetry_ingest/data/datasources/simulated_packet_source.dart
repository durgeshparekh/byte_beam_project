import 'dart:async';
import 'dart:math';

import '../../../../core/utils/clock.dart';
import '../../domain/entities/fleet_vehicle.dart';
import '../../domain/entities/telemetry_packet.dart';
import 'simulator_config.dart';
import 'telemetry_packet_source.dart';

/// A fake fleet on a flaky link.
///
/// Two jobs. It models vehicles well enough that the fleet list, the alert
/// thresholds and the geofence logic have realistic material to chew on. And
/// it misbehaves on purpose — duplicating, delaying, dropping and buffering
/// packets — because the pipeline is built for a link that does all four and
/// a well-behaved source would never exercise that.
///
/// Every random decision comes from one seeded generator, so a run is
/// reproducible: a failing test replays exactly.
class SimulatedPacketSource implements TelemetryPacketSource {
  SimulatedPacketSource({
    required Clock clock,
    this.config = const SimulatorConfig(),
  }) : _clock = clock,
       _random = Random(config.seed) {
    _vehicles = List.generate(config.vehicleCount, _buildVehicle);
  }

  final SimulatorConfig config;
  final Clock _clock;
  final Random _random;

  late final List<_SimulatedVehicle> _vehicles;

  /// Packets deliberately held back: late arrivals and duplicates waiting for
  /// their release tick. They keep their original event time.
  final List<_DelayedPacket> _delayed = [];

  StreamController<List<TelemetryPacket>>? _controller;
  Timer? _timer;
  int _tickCount = 0;

  @override
  List<FleetVehicle> get fleet => [
    for (final vehicle in _vehicles)
      FleetVehicle(
        vehicleId: vehicle.id,
        regNo: vehicle.regNo,
        model: vehicle.model,
      ),
  ];

  /// Starts the timer and emits a batch per configured tick.
  ///
  /// Single-subscription: the repository is the only listener, and the
  /// controller pauses the timer when nobody is listening.
  @override
  Stream<List<TelemetryPacket>> stream() {
    final controller = _controller ??= StreamController<List<TelemetryPacket>>(
      onCancel: dispose,
    );
    _timer ??= Timer.periodic(config.tick, (_) {
      if (controller.isClosed) return;
      final batch = generateTick();
      if (batch.isNotEmpty) controller.add(batch);
    });
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller?.close();
    _controller = null;
  }

  /// Produces exactly one tick's worth of arrivals.
  ///
  /// Public and synchronous so tests can drive the simulator without real
  /// timers — the fault injection is the part worth asserting on, and waiting
  /// half a second per tick to observe it would be silly.
  List<TelemetryPacket> generateTick() {
    _tickCount++;
    final now = _clock.nowUtc();
    final arrivals = <TelemetryPacket>[];

    for (final vehicle in _vehicles) {
      _advance(vehicle);
      final packet = _emit(vehicle, now);
      if (packet.isEmpty) continue;
      _route(vehicle, packet, arrivals);
    }

    _releaseDue(arrivals);

    // Arrival order is not emission order on a real link. Shuffling with the
    // seeded generator keeps that true and still reproducible.
    arrivals.shuffle(_random);
    return arrivals;
  }

  // ------------------------------------------------------------- routing --

  /// Decides what the network does to one freshly measured packet: drop it,
  /// buffer it behind a dead link, deliver it now, deliver it late, and/or
  /// deliver it twice.
  void _route(
    _SimulatedVehicle vehicle,
    TelemetryPacket packet,
    List<TelemetryPacket> arrivals,
  ) {
    // A vehicle parked in a basement keeps measuring and keeps nothing
    // flowing. The backlog lands in one burst when the link returns.
    if (vehicle.darkTicks > 0) {
      vehicle.buffer.add(packet);
      vehicle.darkTicks--;
      if (vehicle.darkTicks == 0) {
        arrivals.addAll(vehicle.buffer);
        vehicle.buffer.clear();
      }
      return;
    }
    if (_random.nextDouble() < config.backlogChance) {
      vehicle.darkTicks = config.backlogTicks;
      vehicle.buffer.add(packet);
      return;
    }

    if (_random.nextDouble() < config.dropRate) return;

    if (_random.nextDouble() < config.lateRate) {
      // Held back, but still stamped with when it was measured — this is the
      // out-of-order case, not a fresh reading.
      _delayed.add(_DelayedPacket(packet, _tickCount + 1 + _random.nextInt(4)));
    } else {
      arrivals.add(packet);
    }

    // A retransmit: byte-identical, same event time, so the natural key is
    // what has to reject it. Sent a tick or two later to exercise the
    // cross-batch case rather than the easy within-batch one.
    if (_random.nextDouble() < config.duplicateRate) {
      _delayed.add(_DelayedPacket(packet, _tickCount + 1 + _random.nextInt(3)));
    }
  }

  /// Moves delayed packets into this tick's arrivals once their time is up.
  void _releaseDue(List<TelemetryPacket> arrivals) {
    _delayed.removeWhere((delayed) {
      if (delayed.releaseTick > _tickCount) return false;
      arrivals.add(delayed.packet);
      return true;
    });
  }

  // ------------------------------------------------------------- physics --

  /// Advances one vehicle by one tick.
  ///
  /// Crude on purpose: the pipeline does not care whether the curves are
  /// right, only that values move plausibly, stay in range, and occasionally
  /// cross a threshold.
  void _advance(_SimulatedVehicle vehicle) {
    final hours = config.tick.inMilliseconds / 3600000.0;

    // Ignition flips rarely, so vehicles hold a state long enough to be worth
    // looking at in the fleet list.
    if (_random.nextDouble() < 0.02) vehicle.ignition = !vehicle.ignition;

    if (!vehicle.ignition) {
      vehicle.speed = 0;
      vehicle.batteryTemp = _towards(vehicle.batteryTemp, 28, 0.4);
      return;
    }

    // Speed wanders and is occasionally zero — that is the IDLE case, ignition
    // on and not moving.
    vehicle.speed = _random.nextDouble() < 0.25
        ? 0
        : (vehicle.speed + (_random.nextDouble() - 0.45) * 18).clamp(0, 80);

    final km = vehicle.speed * hours;
    vehicle.odometer += km;
    vehicle.soc = (vehicle.soc - km * vehicle.drainPerKm).clamp(0, 100);

    // Charging: a flat truck plugs in rather than sitting at 0% forever.
    if (vehicle.soc <= 1) vehicle.soc = 100;

    vehicle.batteryTemp = _towards(
      vehicle.batteryTemp,
      28 + vehicle.speed * 0.22 + vehicle.tempBias,
      0.35,
    );

    // Straight-line drift with an occasional turn. Good enough to cross a
    // geofence boundary, which is all the later features need.
    if (_random.nextDouble() < 0.15) {
      vehicle.heading =
          (vehicle.heading + (_random.nextDouble() - 0.5) * 2) % (2 * pi);
    }
    vehicle.lat += km / 111.0 * cos(vehicle.heading);
    vehicle.lon +=
        km / (111.0 * cos(vehicle.lat * pi / 180)) * sin(vehicle.heading);
  }

  /// Exponential approach, so temperatures ramp instead of teleporting.
  double _towards(double current, double target, double rate) =>
      current + (target - current) * rate;

  // ------------------------------------------------------------ emission --

  /// Builds the packet a vehicle emits this tick.
  ///
  /// Signals report at different cadences, so a packet carries a *subset* —
  /// which is exactly why freshness is tracked per signal and not per vehicle.
  TelemetryPacket _emit(_SimulatedVehicle vehicle, DateTime now) {
    final signals = <String, double>{
      'speed': vehicle.speed,
      'ignition': vehicle.ignition ? 1 : 0,
    };
    if (_tickCount % 2 == 0) {
      signals['soc'] = double.parse(vehicle.soc.toStringAsFixed(1));
      signals['range_km'] = double.parse(
        (vehicle.soc * 3.2).toStringAsFixed(1),
      );
    }
    if (_tickCount % 3 == 0) {
      signals['battery_temp'] = double.parse(
        vehicle.batteryTemp.toStringAsFixed(1),
      );
    }
    if (_tickCount % 4 == 0) {
      signals['odometer'] = double.parse(vehicle.odometer.toStringAsFixed(2));
    }

    // Position reports while driving, sparsely while parked. Accuracy is
    // usually good and occasionally terrible — the bad fixes are what the
    // geofence accuracy gate exists to throw away.
    final reportsFix = vehicle.ignition || _tickCount % 6 == 0;
    final fix = reportsFix
        ? GeoFix(
            lat: vehicle.lat,
            lon: vehicle.lon,
            accuracyM: _random.nextDouble() < 0.08
                ? 60 + _random.nextDouble() * 180
                : 4 + _random.nextDouble() * 12,
          )
        : null;

    return TelemetryPacket(
      vehicleId: vehicle.id,
      eventTs: now,
      signals: signals,
      location: fix,
    );
  }

  // --------------------------------------------------------------- fleet --

  /// Builds one truck. Deterministic from its index, so the same seed always
  /// produces the same fleet with the same problem children.
  _SimulatedVehicle _buildVehicle(int index) {
    const models = ['eT 1000', 'eT 1500', 'eHaul 400'];
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    final regNo =
        'KA01'
        '${letters[index % letters.length]}${letters[(index ~/ 24) % letters.length]}'
        '${(1000 + index * 7 % 9000)}';

    return _SimulatedVehicle(
      id: 'v${index.toString().padLeft(3, '0')}',
      regNo: regNo,
      model: models[index % models.length],
      // Every seventh truck starts near the low-battery threshold and every
      // eleventh runs hot, so the alert rules have something to fire on
      // without waiting for a lucky random walk.
      soc: index % 7 == 0
          ? 14 + _random.nextDouble() * 10
          : 35 + _random.nextDouble() * 60,
      drainPerKm: index % 7 == 0 ? 0.55 : 0.22,
      tempBias: index % 11 == 0 ? 16 : 0,
      batteryTemp: 30 + _random.nextDouble() * 5,
      odometer: 12000 + _random.nextDouble() * 90000,
      lat: 12.90 + _random.nextDouble() * 0.14,
      lon: 77.52 + _random.nextDouble() * 0.16,
      heading: _random.nextDouble() * 2 * pi,
      ignition: _random.nextBool(),
    );
  }
}

/// Mutable state for one simulated truck.
class _SimulatedVehicle {
  _SimulatedVehicle({
    required this.id,
    required this.regNo,
    required this.model,
    required this.soc,
    required this.drainPerKm,
    required this.tempBias,
    required this.batteryTemp,
    required this.odometer,
    required this.lat,
    required this.lon,
    required this.heading,
    required this.ignition,
  });

  final String id;
  final String regNo;
  final String model;

  /// How fast this truck eats charge, in % per km.
  final double drainPerKm;

  /// Degrees added to this truck's steady-state battery temperature.
  final double tempBias;

  double soc;
  double batteryTemp;
  double odometer;
  double speed = 0;
  double lat;
  double lon;
  double heading;
  bool ignition;

  /// Ticks left before the link comes back.
  int darkTicks = 0;

  /// Packets measured while the link was down.
  final List<TelemetryPacket> buffer = [];
}

/// A packet the network is sitting on until [releaseTick].
class _DelayedPacket {
  const _DelayedPacket(this.packet, this.releaseTick);

  final TelemetryPacket packet;
  final int releaseTick;
}
