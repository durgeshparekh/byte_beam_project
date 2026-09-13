import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/geofence.dart';

/// Create or edit one fence: name, centre, radius.
///
/// Typed coordinates rather than a map. Picking a point on a tile layer is the
/// better interface and it is a cut, not an oversight — every geofence rule in
/// this app is decided without one, and a map would be the largest dependency
/// in the project (ARCHITECTURE.md §11).
class GeofenceEditorPage extends StatefulWidget {
  const GeofenceEditorPage({
    required this.fence,
    required this.isNew,
    super.key,
  });

  final Geofence fence;
  final bool isNew;

  @override
  State<GeofenceEditorPage> createState() => _GeofenceEditorPageState();
}

class _GeofenceEditorPageState extends State<GeofenceEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.fence.name);
  late final _lat = TextEditingController(
    text: widget.fence.lat.toStringAsFixed(6),
  );
  late final _lon = TextEditingController(
    text: widget.fence.lon.toStringAsFixed(6),
  );
  late final _radius = TextEditingController(
    text: widget.fence.radiusM.round().toString(),
  );

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _radius.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New geofence' : 'Edit geofence'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Give it a name' : null,
            ),
            const SizedBox(height: 16),
            _number(_lat, 'Latitude', min: -90, max: 90),
            const SizedBox(height: 16),
            _number(_lon, 'Longitude', min: -180, max: 180),
            const SizedBox(height: 16),
            _number(_radius, 'Radius (metres)', min: 1, max: 200000),
            const SizedBox(height: 12),
            // The reason a save is not instant, said before it is pressed.
            if (!widget.isNew)
              Text(
                'Moving or resizing a fence re-derives every crossing ever '
                'recorded for it. Renaming does not change the geometry, but '
                'pays for the same pass.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _submit, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  /// A numeric field that rejects anything outside [min]..[max].
  ///
  /// Validated rather than clamped: silently turning a mistyped longitude into
  /// 180 would put a depot in the Pacific and say nothing.
  Widget _number(
    TextEditingController controller,
    String label, {
    required double min,
    required double max,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
      validator: (value) {
        final parsed = double.tryParse((value ?? '').trim());
        if (parsed == null) return 'Numbers only';
        if (parsed < min || parsed > max) {
          return 'Must be between $min and $max';
        }
        return null;
      },
    );
  }

  /// Hands the edited fence back to the caller, which owns the save.
  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      Geofence(
        geofenceId: widget.fence.geofenceId,
        name: _name.text.trim(),
        lat: double.parse(_lat.text.trim()),
        lon: double.parse(_lon.text.trim()),
        radiusM: double.parse(_radius.text.trim()),
        activeFrom: widget.fence.activeFrom,
        activeTo: widget.fence.activeTo,
        updatedAt: widget.fence.updatedAt,
      ),
    );
  }
}
