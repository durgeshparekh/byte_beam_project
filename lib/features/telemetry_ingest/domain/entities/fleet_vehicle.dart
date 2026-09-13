/// A truck's identity. Immutable reference data, seeded once.
class FleetVehicle {
  const FleetVehicle({
    required this.vehicleId,
    required this.regNo,
    required this.model,
  });

  final String vehicleId;

  /// Registration plate as shown in the fleet list.
  final String regNo;

  final String model;
}
