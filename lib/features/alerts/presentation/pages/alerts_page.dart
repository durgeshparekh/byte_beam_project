import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../vehicle_detail/presentation/pages/vehicle_detail_page.dart';
import '../../domain/entities/fleet_alert.dart';
import '../controllers/alerts_controller.dart';
import '../widgets/alert_card.dart';
import '../widgets/dismiss_reason_sheet.dart';

/// Everything that needs attention, worst first.
class AlertsPage extends GetView<AlertsController> {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: Obx(() {
        if (controller.error.isNotEmpty) {
          return Center(child: Text(controller.error.value));
        }
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        final alerts = controller.alerts;
        if (alerts.isEmpty) return const _NothingWrong();

        final now = controller.evaluatedAt.value ?? DateTime.now().toUtc();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: alerts.length,
          itemBuilder: (_, index) {
            final alert = alerts[index];
            return AlertCard(
              alert: alert,
              now: now,
              onDismiss: () => dismissWithReason(context, controller, alert),
              onOpenVehicle: () =>
                  Get.to(() => VehicleDetailPage(vehicleId: alert.vehicleId)),
            );
          },
        );
      }),
    );
  }
}

/// Asks why, writes the dismissal, then offers UNDO for five seconds.
///
/// Lives here rather than on the controller because both halves are UI: the
/// sheet needs a `BuildContext` and the undo window is a `SnackBar`. The
/// controller's job ends when the row is on disk.
///
/// Shared with the vehicle detail screen, which offers the same action on the
/// same cards.
Future<void> dismissWithReason(
  BuildContext context,
  AlertsController controller,
  FleetAlert alert,
) async {
  final choice = await showDismissReasonSheet(context, alert);
  if (choice == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final dismissed = await controller.dismiss(
    alert,
    choice.reason,
    note: choice.note,
  );
  if (!dismissed) return;

  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('${alert.type.label} on ${alert.regNo} dismissed'),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () => controller.undo(alert.alertId),
      ),
    ),
  );
}

/// The empty state. Worth a sentence rather than a blank screen: on this
/// screen, empty is the good outcome and should read like one.
class _NothingWrong extends StatelessWidget {
  const _NothingWrong();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text('Nothing needs attention', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Every truck is inside its thresholds.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
