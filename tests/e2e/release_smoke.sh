#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/repo/scripts"
cp "$ROOT/VERSION" "$TMP_DIR/repo/VERSION"
cp "$ROOT/scripts/release.sh" "$TMP_DIR/repo/scripts/release.sh"
chmod +x "$TMP_DIR/repo/scripts/release.sh"

CURRENT_VERSION="$(tr -d '[:space:]' < "$TMP_DIR/repo/VERSION")"
IFS=. read -r major minor patch <<<"$CURRENT_VERSION"
PATCH_VERSION="${major}.${minor}.$((patch + 1))"
EXPLICIT_VERSION="${major}.$((minor + 1)).0"

"$TMP_DIR/repo/scripts/release.sh" patch >"$TMP_DIR/patch.out"
grep -F "Updated VERSION: $CURRENT_VERSION -> $PATCH_VERSION" "$TMP_DIR/patch.out" >/dev/null
grep -Fx -- "$PATCH_VERSION" "$TMP_DIR/repo/VERSION" >/dev/null

"$TMP_DIR/repo/scripts/release.sh" "$EXPLICIT_VERSION" >"$TMP_DIR/explicit.out"
grep -F "Updated VERSION: $PATCH_VERSION -> $EXPLICIT_VERSION" "$TMP_DIR/explicit.out" >/dev/null
grep -Fx -- "$EXPLICIT_VERSION" "$TMP_DIR/repo/VERSION" >/dev/null
