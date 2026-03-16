#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

"$ROOT/install.sh" >"$TMP_DIR/install-first.out"
"$ROOT/install.sh" >"$TMP_DIR/install-second.out"

TARGET="$HOME/.local/bin/glance"
if [ ! -L "$TARGET" ]; then
  echo "expected $TARGET to be a symlink" >&2
  exit 1
fi

EXPECTED="$ROOT/bin/glance"
ACTUAL="$(readlink "$TARGET")"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "expected $TARGET -> $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

grep -F "Installed glance -> $TARGET" "$TMP_DIR/install-second.out" >/dev/null
"$TARGET" --version >"$TMP_DIR/version.out"
grep -Fx -- "glance $VERSION" "$TMP_DIR/version.out" >/dev/null
