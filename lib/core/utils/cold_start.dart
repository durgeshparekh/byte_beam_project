/// Cold-start measurement for the scale exercise (§8).
///
/// Deliberately global mutable state, and the only such state in the app.
/// Cold start is a property of the process, not of any object in it: the
/// stopwatch has to start before the object graph exists and stop inside a
/// widget that knows nothing about `main()`. Threading a holder between those
/// two points would be more machinery than the measurement.
///
/// A [Stopwatch] rather than two `DateTime.now()` readings, so this does not
/// become the one place that reaches for the wall clock the rest of the
/// codebase injects — and so a clock adjustment mid-launch cannot produce a
/// negative cold start.
library;

import 'package:flutter/foundation.dart';

/// Started as the first statement of `main()`.
final coldStart = Stopwatch();

/// How long from `main()` to the first fleet list painted **with data**, or
/// null until that frame has been rasterised.
///
/// "With data" matters: stopping on the first frame would measure the
/// spinner, which is a number the app can always make small and which tells
/// nobody anything.
Duration? coldStartElapsed;

/// Stops the clock. Ignored after the first call — a later rebuild of the
/// fleet list is not a cold start.
void markFleetPainted() {
  if (coldStartElapsed != null || !coldStart.isRunning) return;
  coldStart.stop();
  coldStartElapsed = coldStart.elapsed;
  // Printed as well as shown on the scale screen: the number is wanted from a
  // terminal during a measurement run, and reading it off a screenshot of the
  // app that is being measured is how a measurement gets transcribed wrong.
  debugPrint('[scale] cold start ${coldStartElapsed!.inMilliseconds} ms');
}
