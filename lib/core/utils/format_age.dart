/// Human-readable ages, used wherever the UI says how old something is.
///
/// In `core` rather than beside one widget because the readings register, the
/// alert cards and the fleet list all have to say "4m ago" the same way — two
/// spellings of the same duration on one screen reads as two different facts.
library;

/// Compact duration formatting shared by the register and the header.
String formatAge(Duration age) {
  if (age.inSeconds < 60) return '${age.inSeconds}s';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 48) return '${age.inHours}h';
  return '${age.inDays}d';
}
