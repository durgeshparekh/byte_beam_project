import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../domain/entities/geofence.dart';
import '../controllers/geofence_controller.dart';
import '../widgets/geofence_tile.dart';
import 'geofence_editor_page.dart';

/// The fences, with how many vehicles are in each right now.
class GeofencesPage extends GetView<GeofenceController> {
  const GeofencesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geofences'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Obx(
            () => controller.isSaving.value
                ? const LinearProgressIndicator(minHeight: 4)
                : const SizedBox(height: 4),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, controller.blank(), isNew: true),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('New'),
      ),
      body: Obx(() {
        if (controller.error.isNotEmpty) {
          return Center(child: Text(controller.error.value));
        }
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.fences.isEmpty) {
          return const Center(child: Text('No geofences yet.'));
        }

        return ListView.separated(
          itemCount: controller.fences.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final occupancy = controller.fences[index];
            return GeofenceTile(
              occupancy: occupancy,
              onEdit: () => _edit(context, occupancy.fence, isNew: false),
              onToggleActive: () => _toggle(context, occupancy.fence),
            );
          },
        );
      }),
    );
  }

  /// Opens the editor and saves what comes back.
  ///
  /// The editor is a pure form — it returns a fence and owns no writes — so
  /// the save, its progress and its failure all live on one side of the
  /// boundary.
  Future<void> _edit(
    BuildContext context,
    Geofence fence, {
    required bool isNew,
  }) async {
    final edited = await Navigator.of(context).push<Geofence>(
      MaterialPageRoute(
        builder: (_) => GeofenceEditorPage(fence: fence, isNew: isNew),
      ),
    );
    if (edited == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    if (await controller.save(edited)) {
      messenger.showSnackBar(SnackBar(content: Text('${edited.name} saved')));
    }
  }

  /// Deactivating asks first. It is reversible and deletes nothing, but it
  /// stops a fence judging fixes from this moment on, and that gap stays in
  /// the history afterwards.
  Future<void> _toggle(BuildContext context, Geofence fence) async {
    if (fence.isActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Deactivate ${fence.name}?'),
          content: const Text(
            'It stops tracking entries and exits from now on. Crossings '
            'already recorded are kept, and you can turn it back on.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Deactivate'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await controller.setActive(fence.geofenceId, active: !fence.isActive);
  }
}
