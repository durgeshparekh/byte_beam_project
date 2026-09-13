import 'dart:io';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:dart_duckdb/open.dart';

/// dart_duckdb loads its native library out of the app bundle on device. Under
/// `flutter test` the host VM has loaded nothing, and the package's own test
/// fallback points at paths inside the dart_duckdb monorepo — so point it at
/// the host copy fetched by `tool/fetch_duckdb_lib.sh`.
///
/// Spawned isolates need no equivalent call: once this isolate has opened the
/// library its symbols are in the process, which is the first thing
/// dart_duckdb looks for.
void useHostDuckDb() {
  final (os, name) = Platform.isMacOS
      ? (OperatingSystem.macOS, 'libduckdb.dylib')
      : (OperatingSystem.linux, 'libduckdb.so');
  final lib = File('.duckdb/$name');
  if (!lib.existsSync()) {
    throw StateError('${lib.path} missing — run tool/fetch_duckdb_lib.sh');
  }
  open.overrideFor(os, lib.absolute.path);
}
