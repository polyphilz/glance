#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/repo/scripts"
cp "$ROOT/VERSION" "$TMP_DIR/repo/VERSION"
cp "$ROOT/scripts/release.sh" "$TMP_DIR/repo/scripts/release.sh"
chmod +x "$TMP_DIR/repo/scripts/release.sh"

"$TMP_DIR/repo/scripts/release.sh" patch >"$TMP_DIR/patch.out"
grep -F "Updated VERSION: 0.1.0 -> 0.1.1" "$TMP_DIR/patch.out" >/dev/null
grep -Fx -- "0.1.1" "$TMP_DIR/repo/VERSION" >/dev/null

"$TMP_DIR/repo/scripts/release.sh" 0.2.0 >"$TMP_DIR/explicit.out"
grep -F "Updated VERSION: 0.1.1 -> 0.2.0" "$TMP_DIR/explicit.out" >/dev/null
grep -Fx -- "0.2.0" "$TMP_DIR/repo/VERSION" >/dev/null
