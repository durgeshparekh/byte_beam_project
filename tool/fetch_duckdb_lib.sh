#!/usr/bin/env bash
# dart_duckdb bundles its native library for Android/iOS/macOS app builds, but
# `flutter test` runs on the host Dart VM where nothing has loaded it yet.
# This drops a host dylib in .duckdb/ for test/duckdb_support.dart to point at.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="v1.2.1"   # keep in step with dart_duckdb's macos/dart_duckdb.podspec
OUT=".duckdb"
case "$(uname -s)" in
  Darwin) ASSET="libduckdb-osx-universal.zip"; LIB="libduckdb.dylib" ;;
  Linux)  ASSET="libduckdb-linux-amd64.zip";   LIB="libduckdb.so" ;;
  *) echo "unsupported host: $(uname -s)"; exit 1 ;;
esac
[ -f "$OUT/$LIB" ] && { echo "$OUT/$LIB already present"; exit 0; }
mkdir -p "$OUT"
curl -fsSL -o "$OUT/$ASSET" "https://github.com/duckdb/duckdb/releases/download/$VERSION/$ASSET"
unzip -oq "$OUT/$ASSET" -d "$OUT" && rm "$OUT/$ASSET"
echo "$OUT/$LIB"
