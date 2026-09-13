import 'package:flutter/material.dart';

import '../../domain/entities/fleet_alert.dart';

/// What the user picked, once both steps are done.
class DismissChoice {
  const DismissChoice(this.reason, [this.note]);

  final DismissReason reason;

  /// Free text, only ever present for [DismissReason.somethingElse].
  final String? note;
}

/// Asks why, then returns the answer — or null if the user backed out.
///
/// Two steps rather than one, because "Something else…" ends in an ellipsis
/// and an ellipsis promises a follow-up. Backing out of the note step cancels
/// the whole dismissal: a user who opened the text field and changed their
/// mind did not mean "dismiss with no reason".
Future<DismissChoice?> showDismissReasonSheet(
  BuildContext context,
  FleetAlert alert,
) async {
  final reason = await showModalBottomSheet<DismissReason>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Dismiss ${alert.type.label.toLowerCase()} on ${alert.regNo}?',
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          // Order comes from DismissReason itself, so the sheet cannot drift
          // from the order the brief specifies.
          for (final reason in DismissReason.values)
            ListTile(
              title: Text(reason.label),
              onTap: () => Navigator.of(sheetContext).pop(reason),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (reason == null) return null;
  if (reason != DismissReason.somethingElse) return DismissChoice(reason);
  if (!context.mounted) return null;

  final note = await _askForNote(context);
  return note == null ? null : DismissChoice(reason, note);
}

/// The follow-up behind "Something else…".
Future<String?> _askForNote(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('What is going on?'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Optional note'),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Dismiss'),
        ),
      ],
    ),
  );
}
