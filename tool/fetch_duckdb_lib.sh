#!/usr/bin/env bash
# dart_duckdb bundles its native library for Android/iOS/macOS app builds, but
# `flutter test` runs on the host Dart VM where nothing has loaded it yet.
# This drops a host dylib in .duckdb/ for test/duckdb_support.dart to point at.
#
# The library is native code loaded into the test process, so it is checked
# against a pinned SHA-256 on every run, including when already present. GitHub
# publishes no digest for these release assets; the macOS pin was taken from a
# copy whose code signature verified as "Developer ID Application: Stichting
# DuckDB Foundation (7NCTQWA3HA)". Bumping VERSION means re-pinning.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="v1.2.1"   # keep in step with dart_duckdb's macos/dart_duckdb.podspec
OUT=".duckdb"
case "$(uname -s)" in
  Darwin)
    ASSET="libduckdb-osx-universal.zip"; LIB="libduckdb.dylib"
    SHA256="007f820901b91cbe0abf54c41462cb7c4f49bbe156c6aee49ee790c16f72a58e" ;;
  Linux)
    ASSET="libduckdb-linux-amd64.zip"; LIB="libduckdb.so"
    SHA256="" ;;  # not yet pinned: verify a download, then record its hash here
  *) echo "unsupported host: $(uname -s)"; exit 1 ;;
esac
[ -n "$SHA256" ] || { echo "no pinned SHA-256 for $LIB; refusing to load unverified native code"; exit 1; }

verify() {
  echo "$SHA256  $OUT/$LIB" | shasum -a 256 -c --status || {
    rm -f "$OUT/$LIB"
    echo "$OUT/$LIB failed SHA-256 verification and was removed"
    exit 1
  }
}

if [ -f "$OUT/$LIB" ]; then
  verify
  echo "$OUT/$LIB already present, verified"
  exit 0
fi
mkdir -p "$OUT"
curl -fsSL --proto '=https' --tlsv1.2 -o "$OUT/$ASSET" \
  "https://github.com/duckdb/duckdb/releases/download/$VERSION/$ASSET"
unzip -oq "$OUT/$ASSET" "$LIB" -d "$OUT" && rm "$OUT/$ASSET"
verify
echo "$OUT/$LIB"
